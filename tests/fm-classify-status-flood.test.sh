#!/usr/bin/env bash
# tests/fm-classify-status-flood.test.sh - the status flood cap in the status-span
# fold (bin/fm-classify-lib.sh). More than FM_STATUS_FLOOD_MAX captain-relevant
# lines from one task inside ten minutes fold into ONE noisy event, and a
# terminal line (done, failed, blocked, needs-decision) always surfaces. These
# tests drive the real status_span_first_actionable_record over crafted status
# files and assert the events it returns, never the fold's source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-status-flood-tests)

fold_events() {  # <status-file> [<start-offset>] -> events on stdout, rc of the fold
  local record rc rest
  record=$(status_span_first_actionable_record "$1" "${2:-0}")
  rc=$?
  if [ "$rc" -eq 0 ]; then
    rest=${record#*$'\t'}
    printf '%s' "${rest#*$'\t'}"
  fi
  return "$rc"
}

count_of() {  # <haystack> <needle> -> occurrences of <needle>
  local rest=$1 n=0
  while [ "${rest#*"$2"}" != "$rest" ]; do
    n=$((n + 1))
    rest=${rest#*"$2"}
  done
  printf '%s' "$n"
}

append_lines() {  # <file> <count> <start-epoch> <step-secs> <verb-phrase>
  local f=$1 count=$2 epoch=$3 step=$4 phrase=$5 i
  for i in $(seq 1 "$count"); do
    printf '%s [at=%s]: step %s\n' "$phrase" "$epoch" "$i" >> "$f"
    epoch=$((epoch + step))
  done
}

test_flood_folds_into_one_noisy_event() {
  local f="$TMP_ROOT/flood.status" events
  : > "$f"
  append_lines "$f" 12 1000 5 'checks green'
  events=$(FM_STATUS_FLOOD_MAX=5 fold_events "$f") || fail "a flooded span produced no event"
  [ "$(count_of "$events" 'noisy: flood')" -eq 1 ] || fail "expected exactly one noisy event: $events"
  [ "$(count_of "$events" 'checks green')" -eq 5 ] || fail "expected the first 5 lines to surface: $events"
  case "$events" in *'step 6'*|*'step 12'*) fail "lines past the cap surfaced: $events" ;; esac
  pass "more than N lines in the window fold into one noisy event"
}

test_below_the_cap_is_unchanged() {
  local f="$TMP_ROOT/quiet.status" events
  : > "$f"
  append_lines "$f" 5 1000 5 'checks green'
  events=$(FM_STATUS_FLOOD_MAX=5 fold_events "$f") || fail "a quiet span produced no event"
  [ "$(count_of "$events" 'checks green')" -eq 5 ] || fail "a span at the cap lost lines: $events"
  case "$events" in *noisy*) fail "a span at the cap was called noisy: $events" ;; esac
  pass "a span at the cap surfaces every line and is not noisy"
}

test_terminal_lines_always_surface() {
  local f="$TMP_ROOT/terminal.status" events
  : > "$f"
  append_lines "$f" 10 1000 5 'checks green'
  printf '%s\n' 'needs-decision [key=pick] [at=1060]: which option' \
    'blocked [key=stuck] [at=1061]: need a credential' \
    'failed [at=1062]: tests red' \
    'done [at=1063]: finished' >> "$f"
  events=$(FM_STATUS_FLOOD_MAX=5 fold_events "$f") || fail "no event"
  for want in 'needs-decision [key=pick]' 'blocked [key=stuck]' 'failed [at=1062]' 'done [at=1063]'; do
    case "$events" in *"$want"*) ;; *) fail "terminal line '$want' was swallowed: $events" ;; esac
  done
  [ "$(count_of "$events" 'noisy: terminal')" -eq 1 ] || fail "expected one noisy event: $events"
  pass "needs-decision, blocked, failed and done lines surface through a flood"
}

test_terminal_line_at_the_cap_still_reports_noisy() {
  local f="$TMP_ROOT/terminal-edge.status" events
  : > "$f"
  append_lines "$f" 3 1000 5 'checks green'
  printf '%s\n' 'done [at=1020]: finished' >> "$f"
  printf '%s\n' 'checks green [at=1021]: straggler' >> "$f"
  events=$(FM_STATUS_FLOOD_MAX=3 fold_events "$f") || fail "no event"
  case "$events" in *'done [at=1020]'*) ;; *) fail "the done line was swallowed: $events" ;; esac
  [ "$(count_of "$events" 'noisy: terminal-edge')" -eq 1 ] || fail "a terminal line over the cap hid the noisy event: $events"
  case "$events" in *straggler*) fail "a line after the cap surfaced: $events" ;; esac
  pass "a terminal line that crosses the cap still produces the one noisy event"
}

test_window_resets_after_ten_minutes() {
  local f="$TMP_ROOT/spread.status" events
  : > "$f"
  append_lines "$f" 8 1000 301 'checks green'
  events=$(FM_STATUS_FLOOD_MAX=3 fold_events "$f") || fail "no event"
  case "$events" in *noisy*) fail "lines spread over the window were called noisy: $events" ;; esac
  [ "$(count_of "$events" 'checks green')" -eq 8 ] || fail "spread lines were dropped: $events"
  pass "lines spaced beyond the window never trip the cap"
}

test_verdict_is_independent_of_the_span_start() {
  local f="$TMP_ROOT/offset.status" whole tail_events offset
  : > "$f"
  append_lines "$f" 12 1000 5 'checks green'
  whole=$(FM_STATUS_FLOOD_MAX=5 fold_events "$f") || fail "no event"
  offset=$(head -n 8 "$f" | wc -c | tr -d ' ')
  if tail_events=$(FM_STATUS_FLOOD_MAX=5 fold_events "$f" "$offset"); then
    fail "a later span inside the flood produced an event again: $tail_events"
  fi
  [ "$(count_of "$whole" 'noisy: offset')" -eq 1 ] || fail "the whole-file fold lost its noisy event: $whole"
  pass "a later span start sees the same verdict, so the noisy wake fires once"
}

test_noisy_event_lands_in_the_span_that_crosses_the_cap() {
  local f="$TMP_ROOT/cross.status" events offset
  : > "$f"
  append_lines "$f" 4 1000 5 'checks green'
  offset=$(wc -c < "$f" | tr -d ' ')
  append_lines "$f" 6 1030 5 'checks green'
  events=$(FM_STATUS_FLOOD_MAX=5 fold_events "$f" "$offset") || fail "the crossing span produced no event"
  [ "$(count_of "$events" 'noisy: cross')" -eq 1 ] || fail "the crossing span lost the noisy event: $events"
  [ "$(count_of "$events" 'checks green')" -eq 1 ] || fail "only the line under the cap should surface: $events"
  pass "the span that crosses the cap reports the noisy event once"
}

test_unstamped_lines_are_never_counted() {
  local f="$TMP_ROOT/untimed.status" events i
  : > "$f"
  for i in $(seq 1 12); do printf 'checks green: step %s\n' "$i" >> "$f"; done
  events=$(FM_STATUS_FLOOD_MAX=5 fold_events "$f") || fail "no event"
  case "$events" in *noisy*) fail "lines with unknown time were counted: $events" ;; esac
  [ "$(count_of "$events" 'checks green')" -eq 12 ] || fail "unstamped lines were dropped: $events"
  pass "a line with no usable time stamp is never counted or suppressed"
}

test_zero_disables_the_cap() {
  local f="$TMP_ROOT/off.status" events
  : > "$f"
  append_lines "$f" 30 1000 1 'checks green'
  events=$(FM_STATUS_FLOOD_MAX=0 fold_events "$f") || fail "no event"
  case "$events" in *noisy*) fail "a disabled cap still reported noise: $events" ;; esac
  [ "$(count_of "$events" 'checks green')" -eq 30 ] || fail "a disabled cap dropped lines: $events"
  pass "FM_STATUS_FLOOD_MAX=0 disables the cap"
}

test_default_cap_is_well_above_a_busy_task() {
  local f="$TMP_ROOT/default.status" events
  : > "$f"
  append_lines "$f" 15 1000 20 'checks green'
  events=$(fold_events "$f") || fail "no event"
  case "$events" in *noisy*) fail "a busy task tripped the default cap: $events" ;; esac
  append_lines "$f" 30 1300 2 'checks green'
  events=$(fold_events "$f") || fail "no event"
  [ "$(count_of "$events" 'noisy: default')" -eq 1 ] || fail "a 45-line burst did not trip the default cap: $events"
  pass "the default cap tolerates a busy task and catches a burst"
}

test_invalid_cap_uses_the_default() {
  local f="$TMP_ROOT/bad.status" events
  : > "$f"
  append_lines "$f" 40 1000 1 'checks green'
  events=$(FM_STATUS_FLOOD_MAX=lots fold_events "$f") || fail "no event"
  [ "$(count_of "$events" 'noisy: bad')" -eq 1 ] || fail "an invalid cap did not fall back to the default: $events"
  pass "an invalid cap falls back to the default instead of disabling the guard"
}

test_flood_folds_into_one_noisy_event
test_below_the_cap_is_unchanged
test_terminal_lines_always_surface
test_terminal_line_at_the_cap_still_reports_noisy
test_window_resets_after_ten_minutes
test_verdict_is_independent_of_the_span_start
test_noisy_event_lands_in_the_span_that_crosses_the_cap
test_unstamped_lines_are_never_counted
test_zero_disables_the_cap
test_default_cap_is_well_above_a_busy_task
test_invalid_cap_uses_the_default
