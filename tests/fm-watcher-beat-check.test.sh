#!/usr/bin/env bash
# tests/fm-watcher-beat-check.test.sh - bin/fm-watcher-beat-check.sh against real
# beacon files of controlled age.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

CHECK="$ROOT/bin/fm-watcher-beat-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-watcher-beat-tests)

beat_check() { # <dir> [args...]; prints stdout, returns the check's exit code
  local dir=$1; shift
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" env -u FM_GUARD_GRACE bash "$CHECK" "$@"
}

set_beat_age() { : > "$1/state/.last-watcher-beat"; touch -d "@$(( $(date +%s) - $2 ))" "$1/state/.last-watcher-beat"; }

test_blocking_wait_keeps_beacon_fresh() {
  local dir out maxage age beat i rc
  dir=$(make_case wb-wait); beat="$dir/state/.last-watcher-beat"
  : > "$beat"
  out=$(
    export FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" FM_WATCHER_BEACON_INTERVAL=1
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-watch.sh"
    watcher_run_with_beacon bash -c 'sleep 7; echo waited; exit 3' &
    wpid=$!
    maxage=0
    for i in $(seq 1 12); do
      sleep 0.5
      age=$(( $(date +%s) - $(stat -c %Y "$beat" 2>/dev/null || stat -f %m "$beat") ))
      [ "$age" -le "$maxage" ] || maxage=$age
    done
    wait "$wpid"; rc=$?
    echo "maxage=$maxage rc=$rc"
  ) || fail "the wait fixture failed: $out"
  printf '%s\n' "$out" | grep -F 'waited' >/dev/null || fail "the wrapped wait's own output was lost: $out"
  printf '%s\n' "$out" | grep -E 'maxage=[0-2] rc=3' >/dev/null || fail "beacon aged past the interval during a blocking wait, or the exit status was lost: $out"
  pass "a blocking wait keeps the beacon fresh and preserves the wait's status"
}

test_usage() {
  local dir rc
  dir=$(make_case wb-usage)
  beat_check "$dir" --help | grep -F 'usage:' >/dev/null || fail "no usage line"
  beat_check "$dir" --bogus >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "unknown argument should exit 2, got $rc"
  beat_check "$dir" --grace 0 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "a zero grace should exit 2, got $rc"
  pass "help, an unknown argument and a bad grace are handled with usage"
}

test_idle_home_is_quiet() {
  local dir out rc
  dir=$(make_case wb-idle)
  out=$(beat_check "$dir"); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || fail "a home with no work must be silent and exit 0: rc=$rc out=$out"
  out=$(beat_check "$dir" --always)
  printf '%s\n' "$out" | grep -F 'watcher-idle:' >/dev/null || fail "--always should say idle: $out"
  pass "a home with nothing in flight needs no watcher and stays quiet"
}

test_fresh_beat_is_healthy() {
  local dir out rc
  dir=$(make_case wb-fresh); printf 'worktree=/x\n' > "$dir/state/t1.meta"; set_beat_age "$dir" 20
  out=$(beat_check "$dir"); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || fail "a fresh beat must be silent: rc=$rc out=$out"
  out=$(beat_check "$dir" --always)
  printf '%s\n' "$out" | grep -F 'watcher-ok:' >/dev/null || fail "--always should say ok: $out"
  pass "a beat inside the grace is healthy"
}

test_stale_beat_alarms() {
  local dir out rc
  dir=$(make_case wb-stale); printf 'worktree=/x\n' > "$dir/state/t1.meta"; set_beat_age "$dir" 4000
  out=$(beat_check "$dir"); rc=$?
  [ "$rc" -eq 1 ] || fail "a stale beat must exit 1, got $rc"
  printf '%s\n' "$out" | grep -E '^watcher-down: the primary watcher beat is 40[0-9][0-9]s old \(grace 300s\) with 1 task' >/dev/null \
    || fail "the alarm line is wrong: $out"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] || fail "the alarm must be one line: $out"
  out=$(beat_check "$dir" --grace 10000); rc=$?
  [ "$rc" -eq 0 ] || fail "--grace 10000 should accept a 4000s beat, got $rc"
  out=$(FM_GUARD_GRACE=100 FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash "$CHECK"); rc=$?
  [ "$rc" -eq 1 ] || fail "FM_GUARD_GRACE should be honoured, got $rc"
  pass "a beat older than the grace raises one clear alarm and honours --grace and FM_GUARD_GRACE"
}

test_missing_beat_alarms_when_work_exists() {
  local dir out rc
  dir=$(make_case wb-never); printf 'worktree=/x\n' > "$dir/state/t1.meta"
  out=$(beat_check "$dir"); rc=$?
  [ "$rc" -eq 1 ] || fail "a missing beat with work in flight must exit 1, got $rc"
  printf '%s\n' "$out" | grep -F 'has never beaten' >/dev/null || fail "wrong alarm for a missing beat: $out"
  pass "work in flight with no beacon at all raises the never-beaten alarm"
}

test_usage
test_idle_home_is_quiet
test_fresh_beat_is_healthy
test_stale_beat_alarms
test_missing_beat_alarms_when_work_exists
test_blocking_wait_keeps_beacon_fresh
