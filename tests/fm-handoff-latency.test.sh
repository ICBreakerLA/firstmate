#!/usr/bin/env bash
# tests/fm-handoff-latency.test.sh - behavior tests for the handoff journal the
# wake drain writes and the read-only report bin/fm-handoff-latency.sh prints.
# The drain runs for real; the report is checked over journals and inbox files
# whose timestamps the test fixes, so every gap is deterministic.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
LATENCY="$ROOT/bin/fm-handoff-latency.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-latency-tests)

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

test_drain_journals_presented_and_acked_rows() {
  local dir state err journal
  dir=$(make_case drain-journal)
  state="$dir/state"
  err="$dir/drain.err"
  journal="$state/.handoff-journal"
  append_wake "$state" signal 'alpha.status' 'signal: alpha.status' || fail "could not queue a wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>"$err" || fail "drain failed"
  awk -F '\t' '$1 == "v1" && $3 == "presented" && $4 == "alpha" && $6 == "signal" && $7 == "alpha.status"' "$journal" | grep . >/dev/null \
    || fail "the drain did not journal the presented row: $(cat "$journal" 2>&1)"
  if awk -F '\t' '$3 == "acked"' "$journal" 2>/dev/null | grep . >/dev/null; then
    fail "a row was journaled as acknowledged before it was acknowledged"
  fi
  ack_drain_err "$state" "$err" || fail "could not acknowledge the drain"
  awk -F '\t' '$1 == "v1" && $3 == "acked" && $4 == "alpha" && $5 == "1"' "$journal" | grep . >/dev/null \
    || fail "the acknowledgement did not journal the consumed row: $(cat "$journal")"
  pass "the drain journals a presented row at presentation and an acked row at acknowledgement"
}

test_report_orders_gaps_worst_first_by_stage() {
  local dir state now out
  dir=$(make_case report-gaps)
  state="$dir/state"
  out="$dir/report.out"
  now=$(date +%s)
  printf 'blocked [at=%s]: parked at a gate\n' $((now - 700)) > "$state/beta.status"
  {
    printf 'v1\t%s000\tpresented\tbeta\t7\tsignal\tbeta.status\t%s\n' $((now - 500)) $((now - 600))
    printf 'v1\t%s000\tacked\tbeta\t7\tsignal\tbeta.status\t%s\n' $((now - 440)) $((now - 600))
  } > "$state/.handoff-journal"
  FM_STATE_OVERRIDE="$state" "$LATENCY" > "$out" || fail "report failed"
  grep -E "^ +1m40s +event->wake +beta " "$out" >/dev/null || fail "event->wake gap (700s to 600s) is wrong: $(cat "$out")"
  grep -E "^ +1m40s +wake->shown +beta " "$out" >/dev/null || fail "wake->shown gap (600s to 500s) is wrong: $(cat "$out")"
  grep -E "^ +1m00s +shown->handled +beta " "$out" >/dev/null || fail "shown->handled gap (500s to 440s) is wrong: $(cat "$out")"
  grep -E '^ +event->wake +1 ' "$out" >/dev/null || fail "the per-stage summary is missing"
  pass "the report derives each stage's gap from the status log and the journal"
}

test_report_lists_worst_gap_first() {
  local dir state now out first
  dir=$(make_case report-order)
  state="$dir/state"
  out="$dir/report.out"
  now=$(date +%s)
  {
    printf 'v1\t%s000\tpresented\tgamma\t1\tcheck\tk1\t%s\n' $((now - 90)) $((now - 100))
    printf 'v1\t%s000\tacked\tgamma\t1\tcheck\tk1\t%s\n' $((now - 20)) $((now - 100))
    printf 'v1\t%s000\tpresented\tgamma\t2\tcheck\tk2\t%s\n' $((now - 300)) $((now - 900))
    printf 'v1\t%s000\tacked\tgamma\t2\tcheck\tk2\t%s\n' $((now - 290)) $((now - 900))
  } > "$state/.handoff-journal"
  FM_STATE_OVERRIDE="$state" "$LATENCY" > "$out" || fail "report failed"
  first=$(awk '/^WORST GAPS/ { go = 1; next } go && /^  [0-9]/ { print; exit }' "$out")
  case "$first" in
    *wake-\>shown*gamma*k2*) ;;
    *) fail "the worst gap (10m00s wake->shown for k2) did not lead: $first" ;;
  esac
  pass "the worst gap leads the list"
}

test_report_covers_steering_messages_and_open_gaps() {
  local dir state now out inbox
  dir=$(make_case report-steer)
  state="$dir/state"
  out="$dir/report.out"
  inbox="$state/delta.inbox"
  now=$(date +%s)
  mkdir -p "$inbox/handled"
  printf 'schema=fm-task-inbox.v1\nat=%s\n--\nfirst steer\n' "$(iso $((now - 400)))" > "$inbox/handled/001.msg"
  printf 'schema=fm-task-inbox.v1\nat=%s\n--\nsecond steer\n' "$(iso $((now - 250)))" > "$inbox/002.msg"
  printf '%s\t5\tsignal\tdelta.status\tsignal: delta.status\n' $((now - 120)) > "$state/.wake-queue"
  FM_STATE_OVERRIDE="$state" "$LATENCY" > "$out" || fail "report failed"
  grep -E '^ +[0-9]+m[0-9]+s +steer->worker-ack +delta .*001.msg' "$out" >/dev/null || fail "an acknowledged steer is missing: $(cat "$out")"
  grep -E '^ +4m1[0-9]s +steer-unacked +delta .*002.msg' "$out" >/dev/null || fail "a waiting steer is missing: $(cat "$out")"
  grep -E '^ +2m0[0-9]s +wake-unhandled +delta ' "$out" >/dev/null || fail "an unacknowledged wake is missing: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$LATENCY" --task other > "$out" || fail "report with --task failed"
  grep -q 'steer-unacked' "$out" && fail "--task did not narrow the report"
  pass "steering messages and still-waiting wakes appear, and --task narrows them"
}

test_report_axi_surface() {
  local dir state out rc
  dir=$(make_case report-axi)
  state="$dir/state"
  out=$(FM_STATE_OVERRIDE="$state" "$LATENCY") || fail "report on an empty home failed"
  printf '%s' "$out" | grep -F 'no handoff records yet' >/dev/null || fail "no definitive empty state: $out"
  printf '%s' "$out" | grep -F 'watcher beat: never seen' >/dev/null || fail "the watcher beat line is missing: $out"
  touch "$state/.last-watcher-beat"
  out=$("$LATENCY" --help) || fail "--help failed"
  printf '%s' "$out" | grep -F 'usage: fm-handoff-latency.sh' >/dev/null || fail "--help has no usage"
  out=$("$LATENCY" --since soon 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "a bad --since exited $rc"
  printf '%s' "$out" | grep -F 'whole number' >/dev/null || fail "a bad --since gave no reason: $out"
  out=$("$LATENCY" --bogus 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown flag exited $rc"
  pass "the report has --help, a definitive empty state and refuses bad arguments with a reason"
}

test_report_labels_window_and_gate_keys_with_their_task() {
  local dir state out now
  dir=$(make_case report-task-keys)
  state="$dir/state"
  out="$dir/report.out"
  now=$(date +%s)
  printf 'window=test:fm-echo\nkind=ship\n' > "$state/echo.meta"
  printf '%s\t7\tstale\ttest:fm-echo\tstale: test:fm-echo\n' $((now - 120)) > "$state/.wake-queue"
  printf '%s\t8\tcheck\tgate-parked:echo:run-7\tcheck: gate-parked\n' $((now - 120)) >> "$state/.wake-queue"
  FM_STATE_OVERRIDE="$state" "$LATENCY" --task echo > "$out" || fail "report failed"
  [ "$(grep -cE '^ +2m0[0-9]s +wake-unhandled +echo ' "$out")" -eq 2 ] || fail "stale and gate-parked wakes were not labeled with their task: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || fail "drain failed"
  [ "$(awk -F '\t' '$3 == "presented" && $4 == "echo"' "$state/.handoff-journal" | wc -l)" -eq 2 ] \
    || fail "the journal did not record the task for stale and gate-parked wakes: $(cat "$state/.handoff-journal")"
  pass "stale window names and gate-parked keys are reported under their task"
}

test_journal_stays_bounded() {
  local dir state i lines
  dir=$(make_case journal-trim)
  state="$dir/state"
  for i in $(seq 1 25); do
    STATE="$state" FM_HANDOFF_JOURNAL_KEEP=5 bash -c '. "$1"; fm_hj_record presented "$2" signal t.status 1' _ "$ROOT/bin/fm-handoff-journal-lib.sh" "$i"
  done
  lines=$(awk 'END { print NR }' "$state/.handoff-journal")
  [ "$lines" -le 10 ] && [ "$lines" -ge 5 ] || fail "the journal was not trimmed to its bound: $lines lines"
  tail -n 1 "$state/.handoff-journal" | awk -F '\t' '$5 == 25 { ok = 1 } END { exit !ok }' || fail "trimming dropped the newest record"
  pass "the journal is trimmed to its bound and keeps the newest record"
}

test_drain_journals_presented_and_acked_rows
test_report_orders_gaps_worst_first_by_stage
test_report_lists_worst_gap_first
test_report_covers_steering_messages_and_open_gaps
test_report_axi_surface
test_report_labels_window_and_gate_keys_with_their_task
test_journal_stays_bounded
