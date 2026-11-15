#!/usr/bin/env bash
# tests/fm-gate-park.test.sh - the parked-gate check in bin/fm-gate-park-lib.sh.
# The unit tests drive gate_park_check directly with a canned current-state
# verdict and a recording stand-in for fm-send; the behavior test runs a real
# fm-watch.sh process over an idle pane whose run is parked and proves the
# actionable wake and the single nudge arrive within a poll.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-gate-park-tests)

PARKED_HUMAN='state: parked · source: run-step · parked at awaiting_approval: 2 finding(s) · ask-user: authority decision · run: run-7'

make_send_stub() { # <dir> -> echo path; records "<task>" lines and the message
  local dir=$1
  cat > "$dir/send-stub.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_TEST_SEND_LOG:?}"
exit "${FM_TEST_SEND_RC:-0}"
SH
  chmod +x "$dir/send-stub.sh"
  printf '%s\n' "$dir/send-stub.sh"
}

# Run gate_park_check in a clean shell so each call sees the files as they are.
run_check() { # <dir> <task> <key> ; env FM_FAKE_CREW_STATE selects the verdict
  local dir=$1 task=$2 key=$3
  STATE="$dir/state" FM_HOME="$dir" SCRIPT_DIR="$ROOT/bin" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_GATE_PARK_SEND_BIN="$dir/send-stub.sh" FM_TEST_SEND_LOG="$dir/send.log" \
    FM_GATE_PARK_SECS="${FM_GATE_PARK_SECS:-30}" FM_GATE_PARK_READ_TIMEOUT="${FM_GATE_PARK_READ_TIMEOUT:-10}" \
    bash -c '
      . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-timeout-lib.sh"
      . "$1/bin/fm-classify-lib.sh"; . "$1/bin/fm-handoff-journal-lib.sh"
      . "$1/bin/fm-gate-park-lib.sh"
      if gate_park_check "$2" "$3"; then printf "%s\n%s\n" "$GATE_PARK_KEY" "$GATE_PARK_REASON"; else exit 1; fi
    ' _ "$ROOT" "$task" "$key"
}

test_new_gate_nudges_once_and_wakes() {
  local dir out
  dir=$(make_case gp-new); make_send_stub "$dir" >/dev/null
  export FM_FAKE_CREW_STATE="$PARKED_HUMAN"
  out=$(run_check "$dir" t1 test_fm-t1) || fail "a new parked gate with no report did not produce a wake"
  printf '%s\n' "$out" | head -n 1 | grep -Fx 'gate-parked:t1:run-7' >/dev/null || fail "wrong wake key: $out"
  printf '%s\n' "$out" | grep -F 'awaiting_approval' | grep -F 'ask-user finding owed by firstmate' | grep -F 'reattach nudge sent' >/dev/null \
    || fail "wake reason is missing the gate, owner or nudge result: $out"
  [ "$(wc -l < "$dir/send.log")" -eq 1 ] || fail "expected exactly one nudge: $(cat "$dir/send.log")"
  grep -F 'no-mistakes axi run' "$dir/send.log" | grep -F 'Do not answer, approve, merge or discard' >/dev/null || fail "nudge carries no reattach or no-decision text"
  awk -F '\t' '$3 == "nudge" && $4 == "t1" && $7 == "gate-parked:t1:run-7"' "$dir/state/.handoff-journal" | grep . >/dev/null \
    || fail "the nudge was not journaled"
  unset FM_FAKE_CREW_STATE
  pass "a new parked gate sends one reattach nudge and wakes firstmate with the gate and owner"
}

test_nudge_is_bounded_to_one_per_interval() {
  local dir
  dir=$(make_case gp-interval); make_send_stub "$dir" >/dev/null
  export FM_FAKE_CREW_STATE="$PARKED_HUMAN"
  run_check "$dir" t1 test_fm-t1 >/dev/null || fail "first check should wake"
  [ "$(wc -l < "$dir/send.log")" -eq 1 ] || fail "the first park was not nudged once"
  touch -d '5 seconds ago' "$dir/state/.gate-park-eval-test_fm-t1"
  touch "$dir/state/t1.turn-ended"
  run_check "$dir" t1 test_fm-t1 >/dev/null && fail "a second wake came inside the nudge interval"
  [ "$(wc -l < "$dir/send.log")" -eq 1 ] || fail "the worker was nudged again inside the interval"
  touch -d '10 minutes ago' "$dir/state/.gate-park-nudged-test_fm-t1"
  run_check "$dir" t1 test_fm-t1 >/dev/null || fail "a worker still idle at the gate was not nudged after the interval"
  [ "$(wc -l < "$dir/send.log")" -eq 2 ] || fail "no second nudge after the interval"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  touch -d '10 minutes ago' "$dir/state/.gate-park-nudged-test_fm-t1"
  touch "$dir/state/t1.turn-ended"
  run_check "$dir" t1 test_fm-t1 >/dev/null && fail "a working run produced a wake"
  FM_FAKE_CREW_STATE="$PARKED_HUMAN"
  touch -d '5 seconds ago' "$dir/state/.gate-park-eval-test_fm-t1"
  touch "$dir/state/t1.turn-ended"
  run_check "$dir" t1 test_fm-t1 >/dev/null || fail "a re-park at an identical gate after the interval was not nudged"
  [ "$(wc -l < "$dir/send.log")" -eq 3 ] || fail "the identical re-park was not nudged"
  unset FM_FAKE_CREW_STATE
  pass "a parked gate is nudged once per interval, again after it, and an identical re-park after it is nudged"
}

test_slow_state_read_is_bounded() {
  local dir start elapsed
  dir=$(make_case gp-slow); make_send_stub "$dir" >/dev/null
  printf '#!/usr/bin/env bash\nsleep 30\necho "%s"\n' "$PARKED_HUMAN" > "$dir/fakebin/fm-crew-state.sh"
  start=$(date +%s)
  FM_GATE_PARK_READ_TIMEOUT=1 run_check "$dir" t1 test_fm-t1 >/dev/null && fail "a timed-out state read produced a wake"
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 10 ] || fail "the state read was not bounded: ${elapsed}s"
  [ ! -s "$dir/send.log" ] || fail "a timed-out state read nudged the worker"
  pass "a slow current-state read is bounded and never wakes or nudges"
}

test_reported_gate_is_left_alone() {
  local dir
  dir=$(make_case gp-reported); make_send_stub "$dir" >/dev/null
  export FM_FAKE_CREW_STATE="$PARKED_HUMAN"
  printf 'needs-decision [at=%s] [key=nm-run-7-awaiting_approval]: ask-user findings=a file=/x\n' "$(date +%s)" > "$dir/state/t1.status"
  run_check "$dir" t1 test_fm-t1 >/dev/null && fail "a gate the worker already reported produced a second wake"
  [ ! -s "$dir/send.log" ] || fail "a worker that already reported the gate was nudged"
  printf 'needs-decision [at=%s] [key=nm-run-3-review]: other run\n' "$(date +%s)" > "$dir/state/t2.status"
  rm -f "$dir/state/.gate-park-eval-test_fm-t2"
  run_check "$dir" t2 test_fm-t2 >/dev/null || fail "a decision for a different run was read as reporting this gate"
  unset FM_FAKE_CREW_STATE
  pass "a gate whose run the worker already reported is left alone; another run's decision does not count"
}

test_answered_and_reported_gate_is_left_alone() {
  local dir now
  dir=$(make_case gp-answered); make_send_stub "$dir" >/dev/null
  now=$(date +%s)
  export FM_FAKE_CREW_STATE="$PARKED_HUMAN"

  # firstmate answered this run's gate: fm-send --resolve-key appended the
  # closing resolved line. The run-step snapshot still says parked because the
  # worker has not touched the run, so the stale verdict must not wake.
  printf 'needs-decision [at=%s] [key=nm-run-7-awaiting_approval]: ask-user findings=a file=/x\n' "$now" > "$dir/state/t1.status"
  printf 'resolved [at=%s] [key=nm-run-7-awaiting_approval]: approved: your answer\n' "$now" >> "$dir/state/t1.status"
  run_check "$dir" t1 test_fm-t1 >/dev/null && fail "an answered gate produced a wake for a stale snapshot"
  [ ! -s "$dir/send.log" ] || fail "an answered gate nudged the worker"

  # A blocked report for this same gate step is the worker's own report:
  # firstmate was already woken by that line, so the check adds nothing.
  printf 'blocked [at=%s] [key=nm-run-7-awaiting_approval]: lint gate parked, host lint needed\n' "$now" > "$dir/state/t2.status"
  run_check "$dir" t2 test_fm-t2 >/dev/null && fail "a gate-step-blocked run produced a second wake"
  [ ! -s "$dir/send.log" ] || fail "a run-blocked worker was nudged"

  # An answer or report for a different step of the same run is not evidence
  # about this parked gate: it is a live gate and must still wake. The same
  # holds for an open decision at another step.
  printf 'resolved [at=%s] [key=nm-run-7-review]: approved: earlier step\n' "$now" > "$dir/state/t3.status"
  run_check "$dir" t3 test_fm-t3 >/dev/null || fail "a resolved answer for another step silenced a live gate"
  [ "$(wc -l < "$dir/send.log")" -eq 1 ] || fail "the gate with a different-step answer was not nudged exactly once"
  printf 'blocked [at=%s] [key=nm-run-7-lint]: an earlier step was blocked\n' "$now" > "$dir/state/t4.status"
  run_check "$dir" t4 test_fm-t4 >/dev/null || fail "a blocked report for another step silenced a live gate"
  [ "$(wc -l < "$dir/send.log")" -eq 2 ] || fail "the gate with a different-step report was not nudged exactly once"
  printf 'needs-decision [at=%s] [key=nm-run-7-review]: question at another step\n' "$now" > "$dir/state/t5.status"
  run_check "$dir" t5 test_fm-t5 >/dev/null || fail "an open decision for another step silenced a live gate"
  [ "$(wc -l < "$dir/send.log")" -eq 3 ] || fail "the gate with a different-step decision was not nudged exactly once"

  # Genuinely unanswered: no report and no answer for this gate still wakes.
  printf 'working [at=%s]: validating\n' "$now" > "$dir/state/t6.status"
  run_check "$dir" t6 test_fm-t6 >/dev/null || fail "a genuinely unanswered gate did not wake"
  [ "$(wc -l < "$dir/send.log")" -eq 4 ] || fail "the unanswered gate was not nudged exactly once"
  unset FM_FAKE_CREW_STATE
  pass "a gate firstmate already answered or the worker already reported is left alone; a different-step answer, report or open decision and a genuinely unanswered gate still wake"
}

test_same_key_repark_reads_the_latest_transition() {
  local dir now verb
  dir=$(make_case gp-repark); make_send_stub "$dir" >/dev/null
  now=$(date +%s)
  export FM_FAKE_CREW_STATE="$PARKED_HUMAN"

  # Round one: the worker reported this gate and firstmate answered it.
  printf 'needs-decision [at=%s] [key=nm-run-7-awaiting_approval]: ask-user findings=a file=/x\n' "$now" > "$dir/state/t7.status"
  printf 'resolved [at=%s] [key=nm-run-7-awaiting_approval]: approved: your answer\n' "$now" >> "$dir/state/t7.status"
  run_check "$dir" t7 test_fm-t7 >/dev/null && fail "an answered gate produced a wake for a stale snapshot"
  [ ! -s "$dir/send.log" ] || fail "an answered gate nudged the worker"

  # A re-park after that round reopens the same key. The fold reports the fresh
  # opening as the key's latest transition, so the earlier close cannot answer
  # the new park; the fresh report itself is the wake firstmate already got, so
  # the gate check adds nothing.
  printf 'needs-decision [at=%s] [key=nm-run-7-awaiting_approval]: ask-user findings=b file=/y\n' "$now" >> "$dir/state/t7.status"
  verb=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_key_closing_verb "$2" nm-run-7-awaiting_approval' _ "$ROOT" "$dir/state/t7.status")
  [ "$verb" = needs-decision ] || fail "the earlier close still read as the key's latest transition: '$verb'"
  run_check "$dir" t7 test_fm-t7 >/dev/null && fail "the re-park's fresh report was read as answered or produced a second wake"
  [ ! -s "$dir/send.log" ] || fail "the re-park's fresh report produced a nudge"

  # Answered again: the same key's latest transition is a close once more.
  printf 'resolved [at=%s] [key=nm-run-7-awaiting_approval]: approved: second answer\n' "$now" >> "$dir/state/t7.status"
  verb=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_key_closing_verb "$2" nm-run-7-awaiting_approval' _ "$ROOT" "$dir/state/t7.status")
  [ "$verb" = resolved ] || fail "the same key answered again did not report its close: '$verb'"
  run_check "$dir" t7 test_fm-t7 >/dev/null && fail "the same key answered again produced a wake"
  [ ! -s "$dir/send.log" ] || fail "the same key answered again nudged the worker"
  unset FM_FAKE_CREW_STATE
  pass "a same-key re-park reads the fresh opening, not the earlier resolved round, and its second answer answers it again"
}

test_unseen_historical_close_cannot_answer_a_repark() {
  local dir now
  dir=$(make_case gp-stale-close); make_send_stub "$dir" >/dev/null
  now=$(date +%s)
  export FM_FAKE_CREW_STATE="$PARKED_HUMAN"

  # A closing line the fold cannot see follow an opening is not positive
  # evidence about the current park: the gate stays live and wakes.
  printf 'resolved [at=%s] [key=nm-run-7-awaiting_approval]: approved: an earlier round\n' "$now" > "$dir/state/t8.status"
  run_check "$dir" t8 test_fm-t8 >/dev/null || fail "a same-key historical close silenced a re-parked gate"
  [ "$(wc -l < "$dir/send.log")" -eq 1 ] || fail "the re-parked gate was not nudged exactly once"

  # An earlier round under another run id is another decision key, so its
  # close cannot answer this park either.
  printf 'resolved [at=%s] [key=nm-run-6-awaiting_approval]: approved: earlier run\n' "$now" > "$dir/state/t9.status"
  run_check "$dir" t9 test_fm-t9 >/dev/null || fail "an earlier run's close silenced a re-parked gate"
  [ "$(wc -l < "$dir/send.log")" -eq 2 ] || fail "the re-park after an earlier run's close was not nudged exactly once"
  unset FM_FAKE_CREW_STATE
  pass "a close the fold cannot see follow its opening, or one under an earlier run, does not answer a re-parked gate"
}

test_cadence_and_non_gate_states() {
  local dir
  dir=$(make_case gp-cadence); make_send_stub "$dir" >/dev/null
  export FM_FAKE_CREW_STATE_LOG="$dir/reads.log"
  export FM_FAKE_CREW_STATE='state: parked · source: pane · parked at prompt · run: r1'
  run_check "$dir" t1 test_fm-t1 >/dev/null && fail "a pane-sourced parked verdict was treated as a run gate"
  run_check "$dir" t1 test_fm-t1 >/dev/null && fail "unexpected wake"
  [ "$(wc -l < "$dir/reads.log")" -eq 1 ] || fail "the costly state read ran again inside the cadence window"
  touch -d '1 minute ago' "$dir/state/.gate-park-eval-test_fm-t1"
  run_check "$dir" t1 test_fm-t1 >/dev/null
  [ "$(wc -l < "$dir/reads.log")" -eq 2 ] || fail "the read did not run once the cadence elapsed"
  touch -d '5 seconds ago' "$dir/state/.gate-park-eval-test_fm-t1"
  touch "$dir/state/t1.turn-ended"
  run_check "$dir" t1 test_fm-t1 >/dev/null
  [ "$(wc -l < "$dir/reads.log")" -eq 3 ] || fail "a fresh turn end did not make the read due"
  FM_GATE_PARK_SECS=0 run_check "$dir" t9 test_fm-t9 >/dev/null && fail "FM_GATE_PARK_SECS=0 did not turn the check off"
  [ "$(wc -l < "$dir/reads.log")" -eq 3 ] || fail "a disabled check still read state"
  unset FM_FAKE_CREW_STATE FM_FAKE_CREW_STATE_LOG
  pass "only a run-step parked verdict is a gate, and the state read follows its cadence, turn ends and kill switch"
}

test_failed_send_still_wakes_and_says_so() {
  local dir out
  dir=$(make_case gp-sendfail); make_send_stub "$dir" >/dev/null
  export FM_FAKE_CREW_STATE="$PARKED_HUMAN"
  out=$(FM_TEST_SEND_RC=7 run_check "$dir" t1 test_fm-t1) || fail "a failed nudge suppressed the wake"
  printf '%s\n' "$out" | grep -F 'reattach nudge failed (exit 7)' >/dev/null || fail "wake did not report the failed nudge: $out"
  if awk -F '\t' '$3 == "nudge"' "$dir/state/.handoff-journal" 2>/dev/null | grep . >/dev/null; then
    fail "an undelivered nudge was journaled as sent"
  fi
  unset FM_FAKE_CREW_STATE
  pass "a failed nudge still wakes firstmate, says so, and is not journaled as sent"
}

test_watcher_wakes_on_idle_parked_worker() {
  local dir state fakebin out capture window key pid drain_out
  dir=$(make_case gp-watch); make_send_stub "$dir" >/dev/null
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  drain_out="$dir/drain.out"
  window="test:fm-t1"
  printf 'idle prompt, finished' > "$capture"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/t1.meta"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE="$PARKED_HUMAN" FM_GATE_PARK_SEND_BIN="$dir/send-stub.sh" FM_TEST_SEND_LOG="$dir/send.log" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "the watcher did not wake for a worker idle at a parked gate"
  grep -F 'check: gate-parked: t1 parked at awaiting_approval' "$out" >/dev/null || fail "the wake line is wrong: $(cat "$out")"
  [ "$(wc -l < "$dir/send.log")" -eq 1 ] || fail "the watcher did not nudge exactly once: $(cat "$dir/send.log" 2>&1)"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$drain_out" 2>/dev/null || fail "drain failed"
  grep "$(printf '\tcheck\tgate-parked:t1:run-7\t')" "$drain_out" >/dev/null || fail "the wake was not queued under its gate key: $(cat "$drain_out")"
  [ -n "$key" ] || fail "no window key"
  pass "a real watcher wakes within a poll for an idle worker parked at a gate and nudges it once"
}

test_watcher_ignores_a_busy_worker_at_a_gate() {
  local dir state fakebin out capture window pid gen
  dir=$(make_case gp-busy); make_send_stub "$dir" >/dev/null
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  window="test:fm-t1"
  printf 'Working... (12.3s)' > "$capture"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/t1.meta"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" t1)
  "$ROOT/bin/fm-busy-event.sh" apply "$state" t1 busy --gen "$gen" --source pi-ext --event agent-start
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE="$PARKED_HUMAN" FM_GATE_PARK_SEND_BIN="$dir/send-stub.sh" FM_TEST_SEND_LOG="$dir/send.log" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$WATCH" > "$out" &
  pid=$!
  sleep 4
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "the watcher woke for a worker that is still busy: $(cat "$out")"
  fi
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$dir/send.log" ] || fail "a busy worker was nudged"
  pass "a worker that is still busy is never nudged or reported as parked"
}

test_new_gate_nudges_once_and_wakes
test_nudge_is_bounded_to_one_per_interval
test_slow_state_read_is_bounded
test_reported_gate_is_left_alone
test_answered_and_reported_gate_is_left_alone
test_same_key_repark_reads_the_latest_transition
test_unseen_historical_close_cannot_answer_a_repark
test_cadence_and_non_gate_states
test_failed_send_still_wakes_and_says_so
test_watcher_wakes_on_idle_parked_worker
test_watcher_ignores_a_busy_worker_at_a_gate
