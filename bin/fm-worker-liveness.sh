#!/usr/bin/env bash
# fm-worker-liveness.sh - the tracked worker-liveness check: one line per worker
# whose agent process is really gone, silence for everyone else.
#
# Usage:
#   fm-worker-liveness.sh [--task <id>] [--explain]
#   fm-worker-liveness.sh --help
#
# This is the logic behind the "agent process gone" alarm. The local, gitignored
# state/worker-liveness.check.sh is only a shim that runs this script and prints
# its output, so the rules live here, reviewed and tested. As a custom check, any
# stdout line is a wake reason; silence means every worker is accounted for.
#
# For every recorded ship or scout task (a secondmate has its own liveness path
# and a remote task is probed through its host) the endpoint is classified by the
# owning backend (fm_backend_agent_state in bin/fm-backend.sh): alive, dead,
# missing, ambiguous, unreadable or unverified. Only dead and missing prove the
# agent is not running, so every other answer stays silent. A dead or missing
# endpoint is then weighed against the two ways a healthy worker looks dead:
#
#   sandboxed   A task recorded sandbox=sbx runs its agent inside a microVM, so
#               the host-side process check sees only the launch wrapper. The
#               worker is accounted for while its VM is listed and it is still
#               producing evidence: a file written in its clone
#               (<state>/<id>.sbx-clone), or a fresh status line, turn-end or busy
#               record, within FM_LIVENESS_ACTIVE_SECS (default 900). A VM that is
#               gone, or listed but silent past that bound, is raised.
#   waiting     A worker that declared a wait (a paused or captain-held status
#               line) is parked on purpose, and one whose no-mistakes run is
#               still working (bin/fm-crew-state.sh) is waiting on that run or its
#               CI. Both are accounted for, the declared wait only for
#               FM_LIVENESS_WAIT_MAX_SECS (default 3600), so a forgotten wait
#               still surfaces.
#
# Anything left is raised as:
#   worker-liveness: <id> agent process gone (<state>; <what was checked>)
#
# --explain prints one line per worker instead (id, verdict, reason), including
# the workers it accounted for and why, for diagnosing a false alarm. --task
# narrows either form to one task id. The check is read-only and always exits 0
# after a successful read; exit 2 is a usage error. FM_WORKER_LIVENESS_STATE_BIN
# replaces the backend probe with an executable taking <backend> <target>, for
# tests.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_LIVENESS_ACTIVE_SECS=${FM_LIVENESS_ACTIVE_SECS:-900}
FM_LIVENESS_WAIT_MAX_SECS=${FM_LIVENESS_WAIT_MAX_SECS:-3600}

usage() {
  printf 'usage: fm-worker-liveness.sh [--task ID] [--explain]\n'
  printf 'Prints one line per worker whose agent process is really gone, and nothing when every worker is alive, sandboxed and active, or in a declared wait.\n'
  printf 'example: bin/fm-worker-liveness.sh --explain\n'
}

TASK=
EXPLAIN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --explain) EXPLAIN=1; shift ;;
    --task) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; TASK=$2; shift 2 ;;
    *) printf 'fm-worker-liveness: unknown argument "%s"\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
for _v in FM_LIVENESS_ACTIVE_SECS FM_LIVENESS_WAIT_MAX_SECS; do
  case "${!_v}" in
    ''|*[!0-9]*) printf 'fm-worker-liveness: %s must be a whole number of seconds, got "%s"\n' "$_v" "${!_v}" >&2; exit 2 ;;
  esac
done

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-sbx-lib.sh
. "$SCRIPT_DIR/fm-sbx-lib.sh"

NOW=$(date +%s)

# The newest of the evidence files that show a worker is still doing something:
# prints its age in seconds, or nothing when none exists.
freshest_age() { # <id>
  local id=$1 f m best=''
  for f in "$STATE/$id.status" "$STATE/$id.turn-ended" "$STATE/$id.busy-state"; do
    m=$(fm_path_mtime "$f") || continue
    if [ -z "$best" ] || [ "$m" -gt "$best" ]; then best=$m; fi
  done
  [ -n "$best" ] || return 0
  printf '%s\n' "$((NOW - best))"
}

# 0 when something was written in <id>'s sandbox clone within the active window.
clone_active() { # <id>
  local id=$1 anchor rc=1
  [ -d "$STATE/$id.sbx-clone" ] || return 1
  anchor=$(mktemp "${TMPDIR:-/tmp}/fm-liveness-anchor.XXXXXX") || return 1
  touch -d "@$((NOW - FM_LIVENESS_ACTIVE_SECS))" "$anchor" 2>/dev/null \
    || touch -t "$(date -r "$((NOW - FM_LIVENESS_ACTIVE_SECS))" +%Y%m%d%H%M.%S 2>/dev/null)" "$anchor" 2>/dev/null \
    || { rm -f "$anchor"; return 1; }
  crew_worktree_written_since "$id" "$STATE" "$anchor" && rc=0
  rm -f "$anchor"
  return "$rc"
}

# 0 when <id> holds a declared wait (paused or captain-held) younger than the bound.
declared_wait() { # <id> -> reason on stdout
  local id=$1 line m age
  line=$(status_declared_wait_line "$STATE/$id.status" 2>/dev/null || true)
  [ -n "$line" ] || return 1
  m=$(fm_path_mtime "$STATE/$id.status") || return 1
  age=$((NOW - m))
  [ "$age" -le "$FM_LIVENESS_WAIT_MAX_SECS" ] || return 1
  printf 'declared wait %s old: %s\n' "$(printf '%ss' "$age")" "$(printf '%s' "$line" | cut -c1-60)"
}

# 0 when the task's no-mistakes run is still working (waiting on its steps or CI).
run_active() { # <id> -> reason on stdout
  local id=$1 line
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || return 1
  case "$line" in
    "state: working · source: run-step"*) printf 'pipeline run still working\n'; return 0 ;;
  esac
  return 1
}

# verdict <id> <meta>: sets V_KIND (alive|silent|accounted|raise) and V_WHY.
verdict() {
  local id=$1 meta=$2 backend target state sbx name age why
  V_KIND=silent V_WHY=''
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || { V_WHY='remote task, probed through its host'; return 0; }
  case "$(fm_meta_get "$meta" kind)" in
    secondmate) V_WHY='secondmate, covered by its own liveness path'; return 0 ;;
  esac
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || { V_WHY='no recorded endpoint'; return 0; }
  if [ -n "${FM_WORKER_LIVENESS_STATE_BIN:-}" ]; then
    state=$("$FM_WORKER_LIVENESS_STATE_BIN" "$backend" "$target" 2>/dev/null) || state=unreadable
  else
    state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || state=unreadable
  fi
  state=${state%%$'\n'*}
  case "$state" in
    alive) V_KIND=alive; V_WHY='agent process alive'; return 0 ;;
    dead|missing) ;;
    *) V_WHY="endpoint state is ${state:-unknown}; only dead or missing proves the agent is gone"; return 0 ;;
  esac

  sbx=$(fm_meta_get "$meta" sandbox)
  if [ "$sbx" = sbx ]; then
    name=$(fm_meta_get "$meta" sandbox_name)
    if ! command -v sbx >/dev/null 2>&1; then
      V_WHY='sandboxed task but sbx is not installed here, so the VM cannot be checked'; return 0
    fi
    if [ -n "$name" ] && fm_sbx_exists "$name"; then
      age=$(freshest_age "$id")
      if clone_active "$id"; then
        V_KIND=accounted; V_WHY="sandboxed: VM $name listed and its clone was written in the last ${FM_LIVENESS_ACTIVE_SECS}s"; return 0
      fi
      if [ -n "$age" ] && [ "$age" -le "$FM_LIVENESS_ACTIVE_SECS" ]; then
        V_KIND=accounted; V_WHY="sandboxed: VM $name listed and the worker reported ${age}s ago"; return 0
      fi
      why="sandbox VM $name listed but no clone write or report within ${FM_LIVENESS_ACTIVE_SECS}s"
    else
      why="sandbox VM ${name:-unrecorded} is not listed"
    fi
  else
    why='host process check found no agent'
  fi

  if why_wait=$(declared_wait "$id"); then V_KIND=accounted; V_WHY=$why_wait; return 0; fi
  if why_wait=$(run_active "$id"); then V_KIND=accounted; V_WHY=$why_wait; return 0; fi
  V_KIND=raise
  V_WHY="$state; $why; no declared wait and no active pipeline run"
}

found=0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=${meta##*/}; id=${id%.meta}
  [ -z "$TASK" ] || [ "$id" = "$TASK" ] || continue
  found=1
  verdict "$id" "$meta"
  if [ "$EXPLAIN" -eq 1 ]; then
    printf '%s\t%s\t%s\n' "$id" "$V_KIND" "$V_WHY"
  elif [ "$V_KIND" = raise ]; then
    printf 'worker-liveness: %s agent process gone (%s)\n' "$id" "$V_WHY"
  fi
done
if [ "$EXPLAIN" -eq 1 ] && [ "$found" -eq 0 ]; then
  printf 'no recorded workers%s\n' "${TASK:+ named $TASK}"
fi
exit 0
