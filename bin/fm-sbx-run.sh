#!/usr/bin/env bash
# fm-sbx-run.sh - run one Claude task worker inside a Docker Sandboxes (`sbx`)
# microVM, in place of the bare `claude` command of its launch.
#
# bin/fm-spawn.sh launches this script, through the tracked symlink
# bin/claude-sbx so the pane's foreground command still names a Claude launch,
# when config/worker-sandbox is `sbx` (docs/configuration.md "Worker sandbox"
# owns the schema, the mounts, the network posture and the operator steps).
# It is not an operator command.
#
# Usage:
#   claude-sbx --id ID --config DIR --state DIR --data DIR
#       --root DIR --wt DIR --clone DIR --name SANDBOX [--cpus N] [--memory Ng]
#       [--busy-gen GEN] [--kind ship|scout] [--nm] [--allow HOSTS]
#       [--npm-cache DIR] -- CLAUDE_ARGS...
#
#   --wt, --clone   the host worktree and the standalone clone bin/fm-sbx-bridge.sh
#                   made of it; only the clone is mounted, and the VM sees a
#                   symlink from the worktree path to the clone path so the
#                   brief's paths resolve unchanged.
#   --kind scout    no fetch-back; a scout's deliverable is its report.
#   --nm            a no-mistakes ship: the host's no-mistakes binary is copied
#                   into the VM and github.com and api.github.com are allowed
#                   for this one sandbox.
#   --allow HOSTS   further per-sandbox allowed hosts (comma separated).
#   --npm-cache DIR a read-only npm seed cache (bin/fm-sbx-npm-seed.sh).
#   CLAUDE_ARGS     the claude command line, exactly as the launch built it.
#
# What this script does, in order: remove any sandbox of the same name, create
# the sandbox with the minimal mount set and an explicit environment
# allowlist, remove the instruction file sbx plants, link the brief's status
# path and worktree path into the VM, copy the user-level skills, apply the
# optional per-sandbox GitHub secret and network rules, start the host relay
# (bin/fm-sbx-relay.sh), and run claude in the sandbox.
# It runs as a child of the pane shell, never exec'd over it, so that its EXIT,
# HUP, TERM and INT traps always remove the sandbox, stop the relay with a
# final drain, and bring the clone's commits back to the worktree.
#
# Credentials: the host's credentials are never mounted or copied.
# The only secret is a GitHub token read on the host, from FM_SBX_GH_TOKEN or
# else the file config/sbx-github-token, which is stored as a per-sandbox sbx secret that the sbx proxy injects on allowed
# GitHub hosts; the token never enters the VM.
# This script never changes the global sbx policy and never signs in to Claude.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-sbx-lib.sh
. "$SCRIPT_DIR/fm-sbx-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

ID='' CONFIG='' STATE='' DATA='' ROOT='' WT='' CLONE='' NAME=''
CPUS=4 MEMORY=4g BUSY_GEN='' KIND=ship NM=0 ALLOW='' NPM_CACHE=''
RELAY_PID='' CLEANED=0
CLAUDE_USER_HOME=/home/agent

die() {
  echo "error: $*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --id) ID=${2:-}; shift 2 ;;
  --config) CONFIG=${2:-}; shift 2 ;;
  --state) STATE=${2:-}; shift 2 ;;
  --data) DATA=${2:-}; shift 2 ;;
  --root) ROOT=${2:-}; shift 2 ;;
  --wt) WT=${2:-}; shift 2 ;;
  --clone) CLONE=${2:-}; shift 2 ;;
  --name) NAME=${2:-}; shift 2 ;;
  --cpus) CPUS=${2:-}; shift 2 ;;
  --memory) MEMORY=${2:-}; shift 2 ;;
  --busy-gen) BUSY_GEN=${2:-}; shift 2 ;;
  --kind) KIND=${2:-}; shift 2 ;;
  --nm) NM=1; shift ;;
  --allow) ALLOW=${2:-}; shift 2 ;;
  --npm-cache) NPM_CACHE=${2:-}; shift 2 ;;
  --) shift; break ;;
  *) die "unknown argument '$1' (see the script header)" ;;
  esac
done
for v in ID CONFIG STATE DATA ROOT WT CLONE NAME; do
  [ -n "${!v}" ] || die "--$(printf '%s' "$v" | tr 'A-Z_' 'a-z-') is required"
done
[ "$#" -gt 0 ] || die "the claude arguments must follow --"
case "$KIND" in ship | scout) ;; *) die "--kind must be ship or scout" ;; esac
case "$ID" in *[!A-Za-z0-9._-]* | '') die "task id '$ID' is not a bare slug" ;; esac
fm_sbx_is_fleet_name "$NAME" || die "sandbox name '$NAME' is not a fleet sandbox name"
case "$CPUS" in '' | *[!0-9]*) die "--cpus must be a number" ;; esac
case "$MEMORY" in [1-9]*g) ;; *) die "--memory must look like 4g" ;; esac
case "$ALLOW" in *[!A-Za-z0-9.,*-]*) die "--allow takes comma-separated host names only" ;; esac
for d in "$STATE" "$DATA" "$ROOT" "$WT" "$CLONE"; do
  case "$d" in /*) ;; *) die "paths must be absolute: $d" ;; esac
done
[ -d "$CLONE/.git" ] || die "no standalone clone at $CLONE (bin/fm-spawn.sh creates it with fm-sbx-bridge.sh clone)"
fm_sbx_preflight || exit 1

CHANNEL=$(fm_sbx_channel_dir "$STATE" "$ID")
RELAY=$(fm_sbx_relay_dir "$STATE" "$ID")
INBOX="$STATE/$ID.inbox"
mkdir -p "$CHANNEL" "$RELAY" "$INBOX/handled" "$DATA/$ID" || die "could not create the task channel directories"
chmod 755 "$CHANNEL"

sbx_quiet() { "$@" >/dev/null 2>&1; }

# shellcheck disable=SC2329 # reached through the cleanup trap
bridge_back() {
  [ "$KIND" = ship ] || return 0
  "$SCRIPT_DIR/fm-sbx-bridge.sh" fetch-back "$WT" "$CLONE" || {
    echo "notice: the sandbox branch could not be brought back to the worktree yet; teardown retries and refuses to discard it" >&2
    return 1
  }
}

# Runs once on any exit path.
# The sandbox goes first so nothing writes the channel while it is drained.
# shellcheck disable=SC2329 # reached through the EXIT/HUP/TERM/INT traps
cleanup() {
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  trap - EXIT HUP TERM INT
  # The in-VM pipeline's fix commits live in its own gate repository until a
  # sync lands them on the clone's branch, and removing the sandbox ends them.
  if [ "$NM" = 1 ] && [ "$KIND" = ship ] && fm_nm_sandbox_bind "$WT" "$NAME" "$CLONE"; then
    fm_nm_run_bounded "$WT" 120 axi sync >/dev/null 2>&1 || true
  fi
  fm_sbx_rm "$NAME" || echo "notice: sandbox $NAME could not be removed; run: sbx rm --force $NAME" >&2
  if [ -n "$RELAY_PID" ]; then
    kill -TERM "$RELAY_PID" 2>/dev/null || true
    wait "$RELAY_PID" 2>/dev/null || true
  fi
  bridge_back || true
}
trap 'cleanup' EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 130' INT

# The launch-brief record the doorbell argument names, if any, is mounted as a
# single read-only file: the worker reads its brief and nothing else in
# state/operational-inbox.
BRIEF_RECORD=''
for a in "$@"; do
  rec=''
  if fm_operational_doorbell_path "$a" rec 2>/dev/null && [ -f "$rec" ]; then
    case "$rec" in "$STATE"/operational-inbox/*) BRIEF_RECORD=$rec ;; esac
  fi
done

fm_sbx_rm "$NAME" || exit 1

env_args=()
add_env() { env_args+=(-e "$1=$2"); }
for n in CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_CODE_SEND_FEEDBACK FM_TASK_INBOX COMPACT_ADVISER_DISABLE FM_TASK_ID; do
  [ -z "${!n+x}" ] || add_env "$n" "${!n}"
done
add_env DISABLE_AUTOUPDATER 1
add_env FM_SBX_CHANNEL "$CHANNEL"
if [ "$NM" = 1 ]; then
  add_env NM_HOME "$CLAUDE_USER_HOME/nm"
  add_env NO_MISTAKES_NO_UPDATE_CHECK 1
  add_env NO_MISTAKES_TELEMETRY off
fi

mounts=("$CLONE" "$DATA/$ID" "$CHANNEL" "$INBOX")
[ -z "$BRIEF_RECORD" ] || mounts+=("$BRIEF_RECORD:ro")
[ ! -d "$ROOT/.agents/skills" ] || mounts+=("$ROOT/.agents/skills:ro")
if [ "${GIT_CONFIG_COUNT:-}" = 1 ] && [ "${GIT_CONFIG_KEY_0:-}" = core.hooksPath ] &&
  [ -d "${GIT_CONFIG_VALUE_0:-}" ] && [ "$(dirname "${GIT_CONFIG_VALUE_0}")" = "$STATE" ]; then
  mounts+=("$GIT_CONFIG_VALUE_0:ro")
  strip="$ROOT/bin/fm-git-strip-ai-trailers.sh"
  [ ! -f "$strip" ] || mounts+=("$strip:ro")
  add_env GIT_CONFIG_COUNT 1
  add_env GIT_CONFIG_KEY_0 core.hooksPath
  add_env GIT_CONFIG_VALUE_0 "$GIT_CONFIG_VALUE_0"
fi
if [ -n "$NPM_CACHE" ] && [ -d "$NPM_CACHE" ]; then
  mounts+=("$NPM_CACHE:ro")
  add_env NPM_CONFIG_CACHE "$NPM_CACHE"
  add_env NPM_CONFIG_LOGS_DIR /tmp/npm-logs
  add_env NPM_CONFIG_PREFER_OFFLINE true
fi

sbx create --name "$NAME" --pull missing --cpus "$CPUS" --memory "$MEMORY" "${env_args[@]}" claude "${mounts[@]}" >/dev/null ||
  die "sbx create failed for $NAME"

vm_root() { sbx exec -u root "$NAME" "$@"; }

# sbx plants an instruction file next to the first workspace; the worker's own
# brief is the only instruction channel, so it is deleted before claude starts.
sbx_quiet sbx exec -u root "$NAME" rm -f "$(dirname "$CLONE")/CLAUDE.md"
# The brief's status command and host paths resolve unchanged inside the VM.
# shellcheck disable=SC2016 # the positional parameters expand in the VM shell
vm_root sh -c 'mkdir -p "$1" "$2" && ln -sfn "$3" "$4" && ln -sfn "$5" "$6"' sh \
  "$STATE" "$(dirname "$WT")" "$ID.sbx/status" "$STATE/$ID.status" "$CLONE" "$WT" >/dev/null 2>&1 ||
  die "could not link the status path and worktree path into $NAME"

# User-level skills and the model table the host session relies on; these are
# optional, so a failed copy never blocks the launch.
if [ -d "${HOME:-/nonexistent}/.claude/skills" ]; then
  sbx_quiet sbx exec "$NAME" mkdir -p "$CLAUDE_USER_HOME/.claude"
  sbx_quiet sbx cp "$HOME/.claude/skills" "$NAME:$CLAUDE_USER_HOME/.claude/"
fi
if [ -f "${HOME:-/nonexistent}/.agents/pstack-models.md" ]; then
  sbx_quiet sbx exec "$NAME" mkdir -p "$CLAUDE_USER_HOME/.agents"
  sbx_quiet sbx cp "$HOME/.agents/pstack-models.md" "$NAME:$CLAUDE_USER_HOME/.agents/"
fi

if [ "$NM" = 1 ]; then
  nm_bin=$(command -v no-mistakes 2>/dev/null || true)
  [ -n "$nm_bin" ] || die "this is a no-mistakes ship but no-mistakes is not installed on the host"
  nm_bin=$(readlink -f "$nm_bin" 2>/dev/null || printf '%s' "$nm_bin")
  sbx cp "$nm_bin" "$NAME:/tmp/fm-no-mistakes" >/dev/null 2>&1 || die "could not copy no-mistakes into $NAME"
  vm_root install -m 755 /tmp/fm-no-mistakes /usr/local/bin/no-mistakes >/dev/null 2>&1 || die "could not install no-mistakes into $NAME"
  sbx exec "$NAME" mkdir -p "$CLAUDE_USER_HOME/nm" >/dev/null 2>&1 || true
  ALLOW="github.com,api.github.com${ALLOW:+,$ALLOW}"
fi
GH_TOKEN_VALUE=${FM_SBX_GH_TOKEN:-}
if [ -z "$GH_TOKEN_VALUE" ] && [ -f "$CONFIG/sbx-github-token" ] && [ ! -L "$CONFIG/sbx-github-token" ]; then
  GH_TOKEN_VALUE=$(tr -d '[:space:]' <"$CONFIG/sbx-github-token" 2>/dev/null || true)
fi
if [ -n "$GH_TOKEN_VALUE" ]; then
  printf '%s' "$GH_TOKEN_VALUE" | sbx secret set github --sandbox "$NAME" >/dev/null 2>&1 ||
    die "could not store the per-sandbox GitHub secret for $NAME"
  case ",$ALLOW," in *,github.com,*) ;; *) ALLOW="github.com,api.github.com${ALLOW:+,$ALLOW}" ;; esac
elif [ "$NM" = 1 ]; then
  echo "notice: no GitHub token (FM_SBX_GH_TOKEN or config/sbx-github-token) is set, so the in-sandbox pipeline cannot push or open the pull request" >&2
fi
if [ -n "$ALLOW" ]; then
  sbx policy allow network --sandbox "$NAME" "$ALLOW" >/dev/null 2>&1 ||
    die "could not add the per-sandbox network rules ($ALLOW) for $NAME"
fi

relay_args=(--id "$ID" --state "$STATE" --config "$CONFIG" --channel "$CHANNEL" --relay "$RELAY")
[ -z "$BUSY_GEN" ] || relay_args+=(--busy-gen "$BUSY_GEN")
[ "$KIND" != ship ] || relay_args+=(--wt "$WT" --clone "$CLONE")
[ "$NM" != 1 ] || [ "$KIND" != ship ] || relay_args+=(--sandbox "$NAME")
"$SCRIPT_DIR/fm-sbx-relay.sh" "${relay_args[@]}" &
RELAY_PID=$!

sbx run --name "$NAME" -- "$@"
rc=$?
exit "$rc"
