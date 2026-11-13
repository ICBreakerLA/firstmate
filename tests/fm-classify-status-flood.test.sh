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

test_seed_window_crossing_folds_the_span() {
  local f="$TMP_ROOT/seed-window.status" events offset pad i
  : > "$f"
  pad=$(printf 'x%.0s' $(seq 1 2000))
  for i in $(seq 1 20); do printf 'working: filler %s %s\n' "$i" "$pad" >> "$f"; done
  offset=$(wc -c < "$f" | tr -d ' ')
  [ "$offset" -gt 32768 ] || fail "fixture prelude is not past the seed window: $offset"
  append_lines "$f" 8 1000 5 'checks green'
  events=$(FM_STATUS_FLOOD_MAX=3 fold_events "$f" "$offset") || fail "a span past the seed window produced no event"
  [ "$(count_of "$events" 'noisy: seed-window')" -eq 1 ] || fail "expected one noisy event: $events"
  [ "$(count_of "$events" 'checks green')" -eq 3 ] || fail "expected the first 3 span lines to surface: $events"
  case "$events" in *'step 4'*) fail "a span line past the cap surfaced: $events" ;; esac
  pass "a span past the 32 KiB seed window still folds its own lines past the cap"
}

test_episode_dedupe_survives_a_seed_past_32_kib() {
  local f="$TMP_ROOT/seed-episode.status" whole tail_events offset pad i
  : > "$f"
  pad=$(printf 'x%.0s' $(seq 1 5500))
  for i in 1 2 3 4 5 6; do
    printf 'checks green [at=%s]: step %s %s\n' "$((1000 + i * 5))" "$i" "$pad" >> "$f"
  done
  whole=$(FM_STATUS_FLOOD_MAX=5 fold_events "$f") || fail "the flood episode produced no noisy event"
  [ "$(count_of "$whole" 'noisy: seed-episode')" -eq 1 ] || fail "expected exactly one noisy event: $whole"
  offset=$(wc -c < "$f" | tr -d ' ')
  [ "$offset" -gt 32768 ] || fail "fixture prelude is not past the seed window: $offset"
  for i in 7 8 9 10; do
    printf 'checks green [at=%s]: step %s %s\n' "$((1000 + i * 5))" "$i" "$pad" >> "$f"
  done
  tail_events=$(FM_STATUS_FLOOD_MAX=5 fold_events "$f" "$offset") || true
  case "$tail_events" in
    *noisy*) fail "the same flood episode was announced twice; the second span replayed a truncated seed: $tail_events" ;;
  esac
  pass "a later span inside a flood whose seed prefix exceeds 32 KiB stays folded"
}

test_seed_growth_stops_at_the_flood_window() {
  local f="$TMP_ROOT/window-bound.status" reader="$TMP_ROOT/window-bound-reader" reads="$TMP_ROOT/window-bound-reads"
  local offset pad i start length seed_reads=0
  : > "$f"; : > "$reads"
  pad=$(printf 'x%.0s' $(seq 1 2000))
  for i in $(seq 1 100); do
    printf 'checks green [at=%s]: step %s %s\n' "$((1000 + i * 60))" "$i" "$pad" >> "$f"
  done
  offset=$(wc -c < "$f" | tr -d ' ')
  [ "$offset" -gt "$FM_STATUS_FLOOD_SEED_BYTES" ] || fail "fixture prelude is not past the seed window: $offset"
  printf 'checks green [at=%s]: span\n' "$((1000 + 101 * 60))" >> "$f"
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$2" "$3" >> "$FM_TEST_SPAN_READS"
exec perl -e 'open my $f, "<", $ARGV[0] or exit 1; seek $f, $ARGV[1], 0 or exit 1; defined(read $f, my $b, $ARGV[2]) or exit 1; print $b or exit 1' "$1" "$2" "$3"
SH
  chmod +x "$reader"
  FM_STATUS_SPAN_READER="$reader" FM_TEST_SPAN_READS="$reads" fold_events "$f" "$offset" >/dev/null || true
  [ -s "$reads" ] || fail "the classification made no read through the span reader"
  while IFS=$(printf '\t') read -r start length; do
    [ "$start" -lt "$offset" ] && seed_reads=$((seed_reads + 1))
    [ "$length" -le "$FM_STATUS_FLOOD_SEED_BYTES" ] \
      || fail "a non-flooding span replayed ${length} bytes from offset ${start}, past the ${FM_STATUS_FLOOD_SEED_BYTES}-byte start window"
  done < "$reads"
  [ "$seed_reads" -gt 0 ] || fail "the seed was never replayed, so the window bound was not exercised"
  pass "seed growth for a non-flooding span stops at the flood window"
}

test_zero_seed_bytes_replays_from_the_file_start() {
  local f="$TMP_ROOT/zero-seed.status" driver="$TMP_ROOT/zero-seed-driver.sh"
  local seed out done_marker offset events fold_rc pid i
  : > "$f"
  append_lines "$f" 8 1000 5 'checks green'
  offset=$(head -n 6 "$f" | wc -c | tr -d ' ')
  append_lines "$f" 1 1040 1 'checks green'
  cat > "$driver" <<'SH'
#!/usr/bin/env bash
set -u
. "$1/bin/fm-classify-lib.sh"
FM_STATUS_FLOOD_SEED_BYTES=$5
FM_STATUS_FLOOD_MAX=4
record=$(status_span_first_actionable_record "$2" "$3")
fold_rc=$?
if [ "$fold_rc" -eq 0 ]; then
  rest=${record#*$'\t'}
  printf '%s' "${rest#*$'\t'}"
fi
printf '%s' "$fold_rc" > "$4"
SH
  chmod +x "$driver"
  for seed in 0 00 000; do
    out="$TMP_ROOT/zero-seed-$seed.out"
    done_marker="$TMP_ROOT/zero-seed-$seed.done"
    rm -f "$done_marker"; i=0
    "$driver" "$ROOT" "$f" "$offset" "$done_marker" "$seed" > "$out" 2>&1 &
    pid=$!
    while [ ! -e "$done_marker" ] && kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
      sleep 0.1; i=$((i + 1))
    done
    if [ ! -e "$done_marker" ]; then
      kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      fail "seed '$seed' hung the classification instead of replaying from the file start"
    fi
    wait "$pid" || fail "seed '$seed' failed to classify the span"
    events=$(cat "$out")
    fold_rc=$(cat "$done_marker")
    [ "$fold_rc" -eq 1 ] || fail "seed '$seed' did not rank the span past the cap (fold rc $fold_rc): $events"
    [ -z "$events" ] || fail "seed '$seed' surfaced span lines instead of replaying the whole prefix: $events"
  done
  pass "zero-valued seed spellings replay from the file start and terminate"
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
test_seed_window_crossing_folds_the_span
test_episode_dedupe_survives_a_seed_past_32_kib
test_seed_growth_stops_at_the_flood_window
test_zero_seed_bytes_replays_from_the_file_start
test_unstamped_lines_are_never_counted
test_zero_disables_the_cap
test_default_cap_is_well_above_a_busy_task
test_invalid_cap_uses_the_default
