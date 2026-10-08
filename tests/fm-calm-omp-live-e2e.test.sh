#!/usr/bin/env bash
# Opt-in live guard for the partial omp Calm extension. It runs a real omp in its
# JSON-RPC stdio mode inside a throwaway lab checkout and spends no model tokens: it sends
# only the /calm slash command, never a prompt.
#
# It proves what tests/fm-calm-omp-extension.test.sh cannot over a fake omp API:
#   1. omp auto-discovers .omp/extensions/fm-calm-omp.ts and registers /calm;
#   2. with config/calm=on, session start reaches omp's real settings registry, so the
#      "does not expose the settings Calm drives" degrade warning never appears;
#   3. /calm flips config/calm to off and back to on through the live command path.
# Whether the tool rows and thinking blocks actually disappear is a rendering fact that
# only a person at the TUI can see; docs/calm.md lists the recipe.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_OMP_CALM_LIVE omp node jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$ROOT/.omp-calm-live.$$"
PROJECT="$LAB/project"
RPC_IN="$LAB/rpc.in"
RPC_LOG="$LAB/rpc.log"
RPC_ERR="$LAB/rpc.err"
OMP_PID=

cleanup() {
  exec 3>&- 2>/dev/null || true
  [ -z "$OMP_PID" ] || kill -TERM "$OMP_PID" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

wait_for() {  # <attempts> <command...>
  local attempts=$1 i=0
  shift
  while [ "$i" -lt "$attempts" ]; do
    "$@" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}
log_has() { grep -Fq -- "$1" "$RPC_LOG" 2>/dev/null; }
preference_is() { [ "$(cat "$PROJECT/config/calm" 2>/dev/null)" = "$1" ]; }

OMP_VERSION=$(omp --version 2>/dev/null | head -1)

mkdir -p "$LAB" "$PROJECT/.omp/extensions" "$PROJECT/config"
cp "$ROOT/.omp/extensions/fm-calm-omp.ts" "$PROJECT/.omp/extensions/" || fail "could not copy the Calm extension into the lab"
printf 'on\n' > "$PROJECT/config/calm"

mkfifo "$RPC_IN" || fail "could not create the rpc fifo"
: > "$RPC_LOG"
(
  cd "$PROJECT" &&
    env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
      OMP_SKIP_SETUP=1 omp --mode rpc --no-session --cwd "$PROJECT" --auto-approve \
      < "$RPC_IN" > "$RPC_LOG" 2> "$RPC_ERR"
) &
OMP_PID=$!
exec 3> "$RPC_IN"

wait_for 240 log_has '"type":"ready"' || fail "omp $OMP_VERSION did not print its rpc ready frame: $(tail -5 "$RPC_ERR")"
sleep 2
if log_has "does not expose the settings Calm drives" || grep -Fq "does not expose the settings Calm drives" "$RPC_ERR"; then
  fail "omp $OMP_VERSION: the settings registry was unreachable, so Calm could not hide anything: $(grep -h 'Firstmate Calm' "$RPC_LOG" "$RPC_ERR" | head -3)"
fi
pass "omp $OMP_VERSION: the Calm extension loaded and reached the settings registry with no degrade warning"

printf '%s\n' '{"id":"c1","type":"prompt","message":"/calm"}' >&3
wait_for 40 preference_is off || fail "omp $OMP_VERSION: /calm did not save off to config/calm: $(cat "$PROJECT/config/calm")"
printf '%s\n' '{"id":"c2","type":"prompt","message":"/calm"}' >&3
wait_for 40 preference_is on || fail "omp $OMP_VERSION: a second /calm did not save on to config/calm: $(cat "$PROJECT/config/calm")"
pass "omp $OMP_VERSION: /calm toggles config/calm off and back on through the live command path"
