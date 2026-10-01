#!/usr/bin/env bash
# fm-sbx-relay.sh - mirror a sandboxed worker's channel into the host's real
# task records.
#
# A sandboxed worker (bin/fm-sbx-run.sh) cannot write the host's state
# directory, so it gets one writable channel directory instead and everything
# it says to the fleet arrives there as plain bytes.
# This script runs on the host, treats the channel as untrusted input, and is
# the only thing that turns those bytes into state/<id>.status lines and
# busy-state events.
#
# Usage:
#   fm-sbx-relay.sh --id ID --state DIR --config DIR --channel DIR --relay DIR
#       [--busy-gen GEN] [--wt DIR --clone DIR] [--sandbox NAME]
#       [--once | --interval SECS]
#
#   --channel DIR   the directory the VM writes: `status` (status lines exactly
#                   as the brief's status command appends them) and `events`
#                   (one hook event name per line).
#   --relay DIR     host-only relay state (byte offsets), never mounted.
#   --busy-gen GEN  the busy-state incarnation to bind events to; without it
#                   events are not mirrored.
#   --wt, --clone   when both are given, a `done` line is mirrored only after
#                   bin/fm-sbx-bridge.sh fetch-back has brought the clone's
#                   branches to the worktree; if that fails the line becomes a
#                   `blocked` line naming the refusal, so a worker is never
#                   reported ready while its commits exist only in the VM.
#   --sandbox NAME  a no-mistakes ship's sandbox: before each fetch-back the
#                   relay runs `no-mistakes axi sync` inside it, so fix commits
#                   the in-VM pipeline made reach the clone's branch first.
#                   Best effort: a failed sync is left to the fetch-back to
#                   report, because the unbridged commits are then simply not
#                   there.
#   --once          drain what is there now and exit; otherwise poll until
#                   terminated, with one final drain on SIGTERM or SIGINT.
#
# Mirrored status lines must match `state [k=v]...: text`, lose control
# characters, and are capped in length, in bytes read per pass, and in total
# bytes mirrored.
# FM_SBX_RELAY_MAX_TOTAL overrides the total cap (bytes) for tests.
# A symlink or non-regular file in place of the channel files is ignored.
# Event names outside user-prompt-submit, stop, stop-failure and session-end
# are ignored; `stop` also touches state/<id>.turn-ended like the host hook.
# When config/fleet-ledger exists each mirrored line also goes through
# bin/fm-fleet-ledger.sh appended, as the brief's status command does.
set -u
# Offsets and caps count bytes, so every length below is taken in the C locale.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
ID='' STATE='' CONFIG='' CHANNEL='' RELAY='' BUSY_GEN='' WT='' CLONE='' SANDBOX='' ONCE=0 INTERVAL=1
MAX_LINE=1000
MAX_PASS_BYTES=65536
MAX_TOTAL_BYTES=${FM_SBX_RELAY_MAX_TOTAL:-1048576}

die() {
  echo "error: $*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --id) ID=${2:-}; shift 2 ;;
  --state) STATE=${2:-}; shift 2 ;;
  --config) CONFIG=${2:-}; shift 2 ;;
  --channel) CHANNEL=${2:-}; shift 2 ;;
  --relay) RELAY=${2:-}; shift 2 ;;
  --busy-gen) BUSY_GEN=${2:-}; shift 2 ;;
  --wt) WT=${2:-}; shift 2 ;;
  --clone) CLONE=${2:-}; shift 2 ;;
  --sandbox) SANDBOX=${2:-}; shift 2 ;;
  --once) ONCE=1; shift ;;
  --interval) INTERVAL=${2:-}; shift 2 ;;
  *) die "unknown argument '$1' (see the script header)" ;;
  esac
done
[ -n "$ID" ] && [ -n "$STATE" ] && [ -n "$CHANNEL" ] && [ -n "$RELAY" ] || die "--id, --state, --channel and --relay are required"
mkdir -p "$RELAY" || die "cannot create $RELAY"

offset_get() { # <name>
  local v
  v=$(cat "$RELAY/$1.off" 2>/dev/null) || v=0
  case "$v" in '' | *[!0-9]*) v=0 ;; esac
  printf '%s\n' "$v"
}

offset_set() { printf '%s\n' "$2" >"$RELAY/$1.off"; }

# read_new <name>: print up to MAX_PASS_BYTES of complete new lines from the
# channel file and record how far was consumed in $RELAY/<name>.next.
read_new() {
  local name=$1 file="$CHANNEL/$1" off size chunk complete
  : >"$RELAY/$name.next"
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  off=$(offset_get "$name")
  size=$(wc -c <"$file" 2>/dev/null) || return 0
  size=${size//[[:space:]]/}
  # A channel file that shrank was replaced: start over rather than skip.
  [ "$size" -ge "$off" ] || off=0
  [ "$size" -gt "$off" ] || return 0
  chunk=$(tail -c +"$((off + 1))" "$file" 2>/dev/null | head -c "$MAX_PASS_BYTES"; printf x)
  chunk=${chunk%x}
  case "$chunk" in
  *$'\n'*) ;;
  *)
    # One unterminated line longer than a whole pass would stall the relay
    # forever, so it is skipped rather than waited on.
    [ "$((size - off))" -le "$MAX_PASS_BYTES" ] || printf '%s\n' "$((off + MAX_PASS_BYTES))" >"$RELAY/$name.next"
    return 0
    ;;
  esac
  complete=${chunk%"${chunk##*$'\n'}"}
  printf '%s' "$complete"
  printf '%s\n' "$((off + ${#complete}))" >"$RELAY/$name.next"
}

commit_offset() { # <name>
  local n
  n=$(cat "$RELAY/$1.next" 2>/dev/null) || return 0
  [ -z "$n" ] || offset_set "$1" "$n"
}

sanitize_line() {
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\013-\037\177' | cut -c1-"$MAX_LINE"
}

append_status() { # <line>
  printf '%s\n' "$1" >>"$STATE/$ID.status" || return 1
  if [ -n "$CONFIG" ] && [ -e "$CONFIG/fleet-ledger" ]; then
    "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$STATE/$ID.status" >/dev/null 2>&1 || true
  fi
}

bridge_ok() {
  [ -n "$WT" ] && [ -n "$CLONE" ] || return 0
  if [ -n "$SANDBOX" ] && fm_nm_sandbox_bind "$WT" "$SANDBOX" "$CLONE"; then
    fm_nm_run_bounded "$WT" 120 axi sync >/dev/null 2>&1 || true
  fi
  "$SCRIPT_DIR/fm-sbx-bridge.sh" fetch-back "$WT" "$CLONE" 2>"$RELAY/bridge.err"
}

total_get() { cat "$RELAY/status.total" 2>/dev/null || echo 0; }

relay_status() {
  local data line clean total reason
  data=$(read_new status; printf x)
  data=${data%x}
  total=$(total_get)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    clean=$(sanitize_line "$line")
    case "$clean" in
    [a-z]*) ;;
    *) continue ;;
    esac
    # shellcheck disable=SC2016
    printf '%s\n' "$clean" | grep -Eq '^[a-z][a-z-]*( \[[^]]*\])*:( |$)' || continue
    total=$((total + ${#clean} + 1))
    if [ "$total" -gt "$MAX_TOTAL_BYTES" ]; then
      [ -e "$RELAY/status.capped" ] || {
        : >"$RELAY/status.capped"
        append_status "blocked [at=$(date +%s)]: the sandboxed worker exceeded the status size cap; further status lines are not mirrored"
      }
      continue
    fi
    case "$clean" in
    done[\ :]*)
      if ! bridge_ok; then
        reason=$(head -n 1 "$RELAY/bridge.err" 2>/dev/null | cut -c1-300)
        clean="blocked [at=$(date +%s)]: the sandbox branch could not be brought back to the worktree (${reason:-fetch-back failed})"
      fi
      ;;
    esac
    append_status "$clean" || return 1
  done <<<"$data"
  printf '%s\n' "$total" >"$RELAY/status.total"
  commit_offset status
}

relay_events() {
  local data line
  [ -n "$BUSY_GEN" ] || return 0
  data=$(read_new events; printf x)
  data=${data%x}
  while IFS= read -r line; do
    case "$line" in
    user-prompt-submit)
      "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" busy --gen "$BUSY_GEN" --source claude-hook --event "$line" >/dev/null 2>&1 || true
      ;;
    stop)
      touch "$STATE/$ID.turn-ended" 2>/dev/null || true
      "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" idle --gen "$BUSY_GEN" --source claude-hook --event "$line" >/dev/null 2>&1 || true
      ;;
    stop-failure | session-end)
      "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" idle --gen "$BUSY_GEN" --source claude-hook --event "$line" >/dev/null 2>&1 || true
      ;;
    esac
  done <<<"$data"
  commit_offset events
}

drain() {
  # Events first, so a turn's idle event is not applied after the status line
  # that follows it has already woken the supervisor.
  relay_events
  relay_status
}

if [ "$ONCE" = 1 ]; then
  drain
  exit 0
fi

STOP=0
trap 'STOP=1' TERM INT HUP
while [ "$STOP" = 0 ]; do
  drain
  sleep "$INTERVAL" &
  wait $! 2>/dev/null || true
done
drain
