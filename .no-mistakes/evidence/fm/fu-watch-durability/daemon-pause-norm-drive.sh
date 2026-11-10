#!/usr/bin/env bash
# Adversarial drive of the daemon's pause-resurface cadence normalization
# (bin/fm-supervise-daemon.sh housekeeping, added by this change).
# Drives the REAL housekeeping function against a declared-wait fixture and
# asserts observable escalation output, exercising the octal trap the docs
# contract forbids: 014400 must normalize onto the decimal library default
# (14400), never be accepted as octal 6400 (which would fire the recheck
# early at a 7200s marker age).
set -u
REPO=${REPO:-$(git rev-parse --show-toplevel)}
[ -d "$REPO/tests" ] || { echo "REPO not a firstmate worktree: $REPO" >&2; exit 2; }
# shellcheck source=tests/wake-helpers.sh
. "$REPO/tests/wake-helpers.sh"
# Source the daemon's pure functions (main loop is BASH_SOURCE-guarded out).
export FM_TEST_DAEMON_SOURCED=1
. "$ROOT/bin/fm-supervise-daemon.sh"

TMP_ROOT=$(fm_test_tmproot norm-drive)

dir=$(make_supercase norm-octal)
state="$dir/state"; fakebin="$dir/fakebin"
task=norm-octal-w1; win="sess:fm-$task"; pane="$dir/pane.txt"
key=$(printf '%s' "$task" | tr ':/.' '___')
fm_write_meta "$state/$task.meta" "window=$win" "backend=tmux"
printf 'working: dispatching the long audit\npaused: the audit engine is running to completion\n' > "$state/$task.status"
printf 'idle prompt $\n' > "$pane"

run_house() {  # <cadence-var>
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999999 \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS="$1" housekeeping "$state"
}
stamp() { echo $(( $(date +%s) - $1 )) > "$state/.subsuper-paused-$key"; : > "$state/.subsuper-escalations"; }
count() { [ -s "$state/.subsuper-escalations" ] && wc -l < "$state/.subsuper-escalations" | tr -d ' ' || echo 0; }
reset_route() {
  rm -f "$state/.subsuper-paused-$key" "$state/.subsuper-escalations"
  LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" handle_wake \
    "stale: $win (idle 250s, possible wedge, escalation 2)" "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999999 \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=3600 housekeeping "$state"
  [ -e "$state/.subsuper-paused-$key" ] \
    || fail "route: the declared wait never recorded pause tracking"
}

# Fixture sensitivity control: at the marker's own declared cadence the recheck
# MUST fire exactly once, so "no escalation" in the normalized legs below is
# proof of normalization, not of an inert fixture.
reset_route
stamp 7200
run_house 7200
[ "$(count)" = 1 ] || fail "control: a 7200s marker at a 7200s cadence fired $(count) escalations, expected 1"
grep -F 'awaiting external' "$state/.subsuper-escalations" >/dev/null \
  || fail "control: the fired recheck was not an awaiting-external recheck"
pass "control: a matured declared-wait window re-surfaces exactly once at its own cadence"

# Octal trap: 014400 (octal 6400) must normalize onto 14400; a 7200s marker
# is inside the window, so NOTHING must escalate. The pre-change daemon read
# bash's octal 6400 here and fired the recheck early.
reset_route; stamp 7200; run_house 014400
[ "$(count)" = 0 ] || fail "014400 was accepted as octal 6400: early recheck fired ($(count) escalations)"
pass "FM_PAUSE_RESURFACE_SECS=014400 normalizes onto the decimal default (no early recheck at age 7200)"

# Zero form: 00 must normalize onto 14400 (pre-change: -ge 00 fired every poll).
reset_route; stamp 7200; run_house 00
[ "$(count)" = 0 ] || fail "00 cadence fired every poll: $(count) escalations"
pass "FM_PAUSE_RESURFACE_SECS=00 normalizes onto the decimal default"

# Library default wiring: unset must use 14400 - quiet at age 1440, firing once at age 15000.
reset_route; stamp 1440
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
  FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999999 \
  FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
[ "$(count)" = 0 ] || fail "unset cadence escalated at age 1440: $(count) escalations"
stamp 15000
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
  FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999999 \
  FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
[ "$(count)" = 1 ] || fail "unset cadence did not use the 14400 default (age 15000 fired $(count), expected 1)"
grep -F 'awaiting external' "$state/.subsuper-escalations" >/dev/null \
  || fail "the default-cadence recheck was not an awaiting-external recheck"
pass "unset FM_PAUSE_RESURFACE_SECS uses the library default 14400 (fires once past it)"
