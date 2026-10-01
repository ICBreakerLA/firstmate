#!/usr/bin/env bash
# Behavior tests for bin/fm-sbx-relay.sh: a sandboxed worker's channel is
# untrusted input, and only well-formed status lines and whitelisted hook
# events reach the host's real task records.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

RELAYSH="$ROOT/bin/fm-sbx-relay.sh"
BUSY="$ROOT/bin/fm-busy-event.sh"
BRIDGE="$ROOT/bin/fm-sbx-bridge.sh"
TMP_ROOT=$(fm_test_tmproot fm-sbx-relay)
fm_git_identity 'Captain Tests' 'captain@example.invalid'

new_world() { # <name> -> STATE CHANNEL RELAY GEN
  local d="$TMP_ROOT/$1"
  STATE="$d/state"
  CHANNEL="$STATE/t1.sbx"
  RELAY="$STATE/t1.sbx-relay"
  mkdir -p "$CHANNEL"
  chmod 755 "$STATE"
  GEN=$("$BUSY" arm "$STATE" t1) || fail "could not arm the busy record"
}

relay() { "$RELAYSH" --id t1 --state "$STATE" --config "$STATE/../config" --channel "$CHANNEL" --relay "$RELAY" --busy-gen "$GEN" --once "$@"; }

busy_state() { fm_busy_record_read "$STATE" t1; }

test_wellformed_status_lines_are_mirrored_once() {
  new_world mirror
  printf 'working [at=1]: started\nneeds-decision [at=2] [key=k1]: pick one\n' >"$CHANNEL/status"
  relay
  relay
  assert_equals "$(printf 'working [at=1]: started\nneeds-decision [at=2] [key=k1]: pick one')" "$(cat "$STATE/t1.status")" "both lines arrive exactly once"
  printf 'blocked [at=3]: stuck\n' >>"$CHANNEL/status"
  relay
  assert_equals 3 "$(wc -l <"$STATE/t1.status" | tr -d ' ')" "only the appended line is added on the next pass"
  pass "status lines are mirrored byte-for-byte and never twice"
}

test_malformed_and_hostile_lines_are_dropped_or_cleaned() {
  new_world hostile
  {
    printf 'not a status line\n'
    printf 'WORKING: uppercase\n'
    printf '../../etc: path\n'
    printf 'working [at=1]: bell\a and esc\033[31m here\n'
    printf 'working [at=2]: %s\n' "$(printf 'x%.0s' $(seq 1 5000))"
  } >"$CHANNEL/status"
  relay
  [ "$(wc -l <"$STATE/t1.status" | tr -d ' ')" = 2 ] || fail "only the two well-formed lines may pass: $(cat "$STATE/t1.status")"
  assert_not_contains "$(cat "$STATE/t1.status")" $'\033' "control characters are stripped"
  [ "$(awk '{ if (length($0) > m) m = length($0) } END { print m }' "$STATE/t1.status")" -le 1000 ] || fail "line length is capped"
  pass "malformed lines are dropped and accepted lines lose control characters and excess length"
}

test_partial_line_waits_for_its_newline() {
  new_world partial
  printf 'working [at=1]: half' >"$CHANNEL/status"
  relay
  [ ! -s "$STATE/t1.status" ] || fail "an unterminated line must wait"
  printf ' done\n' >>"$CHANNEL/status"
  relay
  assert_equals 'working [at=1]: half done' "$(cat "$STATE/t1.status")" "the completed line arrives whole"
  pass "an unterminated line is held until it is complete"
}

test_symlinked_channel_files_are_ignored() {
  new_world symlink
  printf 'working [at=1]: secret host file\n' >"$TMP_ROOT/outside"
  ln -s "$TMP_ROOT/outside" "$CHANNEL/status"
  relay
  [ ! -s "$STATE/t1.status" ] || fail "a symlinked status file must not be read"
  pass "a symlink in place of the status file is never followed"
}

test_total_size_is_capped() {
  new_world cap
  local i
  for i in $(seq 1 30); do
    printf 'working [at=%s]: %s\n' "$i" "$(printf 'y%.0s' $(seq 1 900))"
  done >"$CHANNEL/status"
  FM_SBX_RELAY_MAX_TOTAL=5000 relay
  FM_SBX_RELAY_MAX_TOTAL=5000 relay
  [ "$(wc -l <"$STATE/t1.status" | tr -d ' ')" -le 7 ] || fail "output is bounded: $(wc -l <"$STATE/t1.status")"
  assert_equals 1 "$(grep -c 'size cap' "$STATE/t1.status")" "the cap is announced exactly once"
  pass "a flood of lines is cut off at the cap with one blocked notice"
}

test_events_drive_the_busy_record_and_turn_marker() {
  new_world events
  printf 'user-prompt-submit\n' >"$CHANNEL/events"
  relay
  assert_contains "$(busy_state)" busy "a prompt submit opens the turn"
  printf 'stop\n' >>"$CHANNEL/events"
  relay
  assert_contains "$(busy_state)" idle "stop closes the turn"
  assert_present "$STATE/t1.turn-ended" "stop leaves the turn-ended notification"
  pass "whitelisted hook events become busy-state transitions"
}

test_unknown_events_and_stale_gen_are_ignored() {
  new_world stale
  printf 'rm -rf /\nuser-prompt-submit; touch %s/pwned\nuser-prompt-submit\n' "$TMP_ROOT" >"$CHANNEL/events"
  relay
  [ ! -e "$TMP_ROOT/pwned" ] || fail "an event name must never reach a shell"
  assert_contains "$(busy_state)" busy "the one valid event still applies"
  GEN2=$("$BUSY" arm "$STATE" t1) || fail "re-arm"
  printf 'stop\n' >>"$CHANNEL/events"
  relay
  assert_not_contains "$(busy_state)" idle "an event bound to a retired incarnation is refused"
  assert_not_equals "$GEN" "$GEN2" "the re-arm minted a new generation"
  pass "unknown event names are ignored and a stale generation cannot change the record"
}

test_done_waits_for_fetch_back_and_failure_becomes_blocked() {
  local d repo wt clone
  new_world bridged
  d="$TMP_ROOT/bridged"
  repo="$d/repo"
  wt="$d/wt"
  clone="$d/clone"
  fm_git_worktree "$repo" "$wt" base-branch
  "$BRIDGE" clone "$wt" "$clone" || fail "clone"
  git -C "$clone" checkout -q -b fm/t1
  printf 'work\n' >>"$clone/README.md"
  git -C "$clone" -c user.name=T -c user.email=t@example.invalid commit -qam work
  printf 'done [at=9]: ready in branch fm/t1\n' >"$CHANNEL/status"
  relay --wt "$wt" --clone "$clone"
  assert_equals 'done [at=9]: ready in branch fm/t1' "$(cat "$STATE/t1.status")" "done is mirrored after the bridge succeeded"
  assert_equals "$(git -C "$clone" rev-parse HEAD)" "$(git -C "$repo" rev-parse refs/heads/fm/t1)" "the commits were on the host before done appeared"
  : >"$STATE/t1.status"
  rm -f "$RELAY"/*.off
  printf 'host edit\n' >>"$wt/README.md"
  git -C "$clone" -c user.name=T -c user.email=t@example.invalid commit -q --allow-empty -m more
  printf 'done [at=10]: ready again\n' >"$CHANNEL/status"
  relay --wt "$wt" --clone "$clone"
  assert_contains "$(cat "$STATE/t1.status")" "blocked [at=" "a failed bridge turns done into blocked"
  assert_not_contains "$(cat "$STATE/t1.status")" "done [at=10]: ready again" "the worker is not reported ready"
  pass "done is mirrored only after the branch is on the host, otherwise it becomes blocked"
}

test_wellformed_status_lines_are_mirrored_once
test_malformed_and_hostile_lines_are_dropped_or_cleaned
test_partial_line_waits_for_its_newline
test_symlinked_channel_files_are_ignored
test_total_size_is_capped
test_events_drive_the_busy_record_and_turn_marker
test_unknown_events_and_stale_gen_are_ignored
test_done_waits_for_fetch_back_and_failure_becomes_blocked

echo "# all fm-sbx-relay tests passed"
