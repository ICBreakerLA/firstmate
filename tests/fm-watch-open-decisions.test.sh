#!/usr/bin/env bash
# Opt-in record-age reminders through the watcher's real queue interface.
# No endpoint, harness process, model call, or remote host is needed.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-open-decisions)
export FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

FM_OPEN_DECISION_OVERDUE_SECS=100
FM_OPEN_DECISION_BACKOFF_MAX_SECS=400

reset_case() {
  rm -f -- "$STATE"/* "$STATE"/.[!.]* "$CONFIG"/*
  OPEN_DECISION_REMINDER=
}

count_wakes() {
  if [ -f "$FM_WAKE_QUEUE" ]; then wc -l < "$FM_WAKE_QUEUE" | tr -d ' '; else printf 0; fi
}

test_disabled() {
  reset_case
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 0 ] || fail "disabled flag queued a reminder"
  [ ! -e "$STATE/.worker.open-decisions-cursor.timed" ] || fail "disabled flag folded status"
  pass "absent flag emits nothing and does not fold status"
}

test_oldest_and_backoff() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=older]: choose\nworking: continuing\n' > "$STATE/z-worker.status"
  printf 'blocked [at=1050] [key=newer]: help\n' > "$STATE/a-worker.status"
  open_decision_reminder_tick 1099
  [ "$(count_wakes)" = 0 ] || fail "not-yet-overdue key queued a reminder"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 1 ] || fail "oldest overdue key did not queue exactly one wake"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: z-worker key=older age=200s' ] \
    || fail "reminder did not select the oldest durable record: $OPEN_DECISION_REMINDER"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 2 ] || fail "another overdue key inherited the oldest key's backoff"
  open_decision_reminder_tick 1299
  [ "$(count_wakes)" = 2 ] || fail "same key repeated before its first backoff"
  open_decision_reminder_tick 1300
  [ "$(count_wakes)" = 3 ] || fail "first repeat did not become due"
  open_decision_reminder_tick 1300
  [ "$(count_wakes)" = 4 ] || fail "second key did not repeat independently"
  open_decision_reminder_tick 1499
  [ "$(count_wakes)" = 4 ] || fail "repeat interval did not double"
  open_decision_reminder_tick 1500
  open_decision_reminder_tick 1500
  [ "$(count_wakes)" = 6 ] || fail "doubled backoff did not expire"
  open_decision_reminder_tick 1899
  [ "$(count_wakes)" = 6 ] || fail "capped interval fired early"
  open_decision_reminder_tick 1900
  open_decision_reminder_tick 1900
  open_decision_reminder_tick 2300
  open_decision_reminder_tick 2300
  [ "$(count_wakes)" = 10 ] || fail "backoff did not stay bounded at the cap"
  pass "oldest key surfaces once, and independent per-key backoff doubles up to its cap"
}

assert_distinct_reminder_identities() {  # <older-task> <older-key> <newer-task> <newer-key>
  local older_task=$1 older_key=$2 newer_task=$3 newer_key=$4 now count=0
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=%s]: choose\n' "$older_key" > "$STATE/$older_task.status"
  printf 'blocked [at=1050] [key=%s]: help\n' "$newer_key" >> "$STATE/$newer_task.status"
  for now in 1200 1300 1500 1900 2300; do
    if [ "$count" -gt 0 ]; then
      open_decision_reminder_tick "$((now - 1))"
      [ "$(count_wakes)" = "$count" ] || fail "numeric-looking identity repeated before its backoff"
    fi
    open_decision_reminder_tick "$now"
    count=$((count + 1))
    [ "$(count_wakes)" = "$count" ] || fail "older numeric-looking identity did not become due"
    [ "$OPEN_DECISION_REMINDER" = "check: open decision overdue: $older_task key=$older_key age=$((now - 1000))s" ] \
      || fail "older numeric-looking identity was not selected: $OPEN_DECISION_REMINDER"
    open_decision_reminder_tick "$((now + 1))"
    count=$((count + 1))
    [ "$(count_wakes)" = "$count" ] || fail "distinct numeric-looking identity inherited another identity's backoff"
    [ "$OPEN_DECISION_REMINDER" = "check: open decision overdue: $newer_task key=$newer_key age=$((now + 1 - 1050))s" ] \
      || fail "newer numeric-looking identity was not selected: $OPEN_DECISION_REMINDER"
    open_decision_reminder_tick "$((now + 1))"
    [ "$(count_wakes)" = "$count" ] || fail "numeric-looking identity repeated without waiting"
  done
}

test_numeric_keys_are_distinct() {
  assert_distinct_reminder_identities worker 1 worker 01
  pass "keys 1 and 01 receive separate reminders and retain independent bounded backoff"
}

test_numeric_tasks_are_distinct() {
  assert_distinct_reminder_identities 1 api 01 api
  pass "tasks 1 and 01 receive separate reminders and retain independent bounded backoff"
}

test_resolution_and_reopen() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  printf 'resolved [at=1201] [key=api]: answered\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1600
  [ "$(count_wakes)" = 1 ] || fail "resolved key kept generating reminders"
  printf 'blocked [at=1600] [key=api]: new episode\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1700
  [ "$(count_wakes)" = 2 ] || fail "reopened key inherited the resolved episode's backoff"
  pass "resolution stops reminders immediately and a later episode starts fresh"
}

test_wait_exemptions() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\npaused [at=1050]: validation in flight\n' > "$STATE/paused.status"
  printf 'needs-decision [at=1000] [key=api]: choose\ncaptain-held [at=1050] [key=api]: transferred\n' > "$STATE/transferred.status"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/backlog-held.status"
  # The watcher already delegates backlog ownership to this predicate.
  task_captain_call_open() { [ "$1" = backlog-held ]; }
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 0 ] || fail "a declared wait or captain hold queued a reminder"
  printf 'working [at=1201]: resumed\n' >> "$STATE/paused.status"
  open_decision_reminder_tick 1201
  [ "$(count_wakes)" = 1 ] || fail "ending a pause hid the still-open key"
  pass "paused waits, verified transfers, and backlog captain holds are exempt"
}

test_unknown_times_and_keyless() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [key=missing]: choose\nblocked [at=bad] [key=bad]: help\nblocked [at=1000]: legacy\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 0 ] || fail "unknown emission time or keyless record was inferred overdue"
  pass "only explicitly keyed records with valid source timestamps are aged"
}

test_timed_fold_is_incremental() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  export FM_OPEN_DECISIONS_READ_PROBE="$TMP_ROOT/fold.reads"
  : > "$FM_OPEN_DECISIONS_READ_PROBE"
  open_decision_reminder_tick 1200
  open_decision_reminder_tick 1201
  [ "$(wc -l < "$FM_OPEN_DECISIONS_READ_PROBE" | tr -d ' ')" = 1 ] \
    || fail "unchanged poll reread the task's history"
  printf 'resolved [key=api]: answered\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1202
  [ "$(tail -1 "$FM_OPEN_DECISIONS_READ_PROBE" | cut -f2)" = 29 ] \
    || fail "resolution poll folded more than newly appended bytes"
  [ "$(count_wakes)" = 1 ] || fail "incremental resolution left a reminder live"
  unset FM_OPEN_DECISIONS_READ_PROBE
  pass "quiet polls reuse the timed fold and only new status bytes are folded"
}

test_invalid_settings() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  if FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_tick 1200; then
    fail "zero threshold enabled an unbounded reminder loop"
  fi
  if FM_OPEN_DECISION_BACKOFF_MAX_SECS=99 open_decision_reminder_tick 1200; then
    fail "cap below the threshold was accepted"
  fi
  [ "$(count_wakes)" = 0 ] || fail "invalid settings queued a reminder"
  pass "invalid settings refuse the tick without queueing reminders"
}

test_timed_cursor_retirement() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  status_retire_presentation_task "$STATE" worker
  [ ! -e "$STATE/.worker.open-decisions-cursor.timed" ] || fail "task retirement left its timed cursor"
  open_decision_reminder_tick 1600
  [ "$(count_wakes)" = 1 ] || fail "retired task kept generating reminders"
  pass "task retirement removes the timed cursor and ends reminders"
}

test_watcher_loop() {
  local dir="$TMP_ROOT/watcher-loop" pid i=0
  mkdir -p "$dir/state" "$dir/config"
  fm_test_track_watcher_state "$dir/state"
  touch "$dir/config/open-decision-reminders" "$dir/state/home-summary.json"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$dir/state/worker.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_OPEN_DECISION_OVERDUE_SECS=100 FM_OPEN_DECISION_BACKOFF_MAX_SECS=400 \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" &
  pid=$!
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "real watcher failed to wake on an overdue record"
  fi
  wait "$pid" || fail "real watcher exited unsuccessfully: $(cat "$dir/err")"
  grep -F 'check: open decision overdue: worker key=api age=' "$dir/out" >/dev/null \
    || fail "real watcher did not print the reminder wake"
  [ "$(wc -l < "$dir/state/.wake-queue" | tr -d ' ')" = 1 ] \
    || fail "real watcher did not durably queue exactly one reminder"
  pass "the actual watcher wakes and exits on an overdue key without any recorded pane"
}

# settle_wakes <dir>: replay the case's durable queue through the real drain and
# post the acknowledgement it names, the same handling boundary a firstmate
# applies between supervision cycles, so the next cycle sees a settled handoff
# and exercises its scan instead of exiting on the downtime re-arm wake.
settle_wakes() {
  local dir=$1 seq gen
  FM_ROOT_OVERRIDE="$TMP_ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    "$ROOT/bin/fm-wake-drain.sh" > /dev/null 2> "$dir/drain.err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\).*$/\1/p' "$dir/drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\).*$/\1/p' "$dir/drain.err")
  [ -n "$seq" ] && [ -n "$gen" ] || return 0
  FM_ROOT_OVERRIDE="$TMP_ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" \
    > /dev/null 2>&1 || true
}

# The watcher exits 0 on its first emitted wake; that is a completed cycle,
# not supervision ending - in production the arm starts the next cycle. So this
# test runs whole cycles to completion, with a drain+ack between them the way
# supervision handles every cycle: surviving means each cycle exits 0 on its
# wake and keeps surfacing new status while a failing ledger alarms on a
# bounded cadence, never one line per poll. The quiet middle cycle counts the
# guard's alarm markers - touched once per raise - so the drain cost between
# cycles can never drift an expectation against a wall clock.
test_watcher_loop_survives_ledger_failure() {
  local dir="$TMP_ROOT/watcher-ledger-failure" rc alarm marker touches last m i pid
  mkdir -p "$dir/state" "$dir/config"
  fm_test_track_watcher_state "$dir/state"
  touch "$dir/config/open-decision-reminders" "$dir/state/home-summary.json"
  ln -s "$TMP_ROOT/not-a-ledger" "$dir/state/.open-decision-reminders"
  marker="$dir/state/.tick-alarm-open-decision"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$dir/state/worker.status"
  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_POLL=1 FM_WATCH_TICK_ALARM_SECS=3 \
    FM_OPEN_DECISION_OVERDUE_SECS=100 FM_OPEN_DECISION_BACKOFF_MAX_SECS=400 \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/cycle1.out" 2> "$dir/cycle1.err" || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "the poll loop died on a failing reminder ledger (rc=$rc): $(cat "$dir/cycle1.err")"
  [ "$(grep -c -F 'watcher: open-decision reminder check failed' "$dir/cycle1.err")" -eq 1 ] \
    || fail "one ledger failure episode did not alarm exactly once: $(cat "$dir/cycle1.err")"
  grep -F "signal: $dir/state/worker.status" "$dir/cycle1.out" >/dev/null \
    || fail "the cycle beside a ledger failure did not surface the seeded status: $(cat "$dir/cycle1.out" "$dir/cycle1.err")"
  settle_wakes "$dir"
  # A quiet cycle has no new status to wake on, so the failing reminder tick
  # repeats every poll: the watcher must survive a full cadence of failures
  # and raise once per elapsed cadence. Counting marker touches bounds the
  # cycle by alarms, not time, so startup and drain cost cannot skew it.
  touches=0
  last=$(stat_mtime "$marker")
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_POLL=1 FM_WATCH_TICK_ALARM_SECS=3 \
    FM_OPEN_DECISION_OVERDUE_SECS=100 FM_OPEN_DECISION_BACKOFF_MAX_SECS=400 \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/cycle2.out" 2> "$dir/cycle2.err" &
  pid=$!
  i=0
  while [ "$touches" -lt 3 ] && [ "$i" -lt 150 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
    m=$(stat_mtime "$marker" 2>/dev/null || true)
    if [ "$m" != "$last" ]; then
      touches=$((touches + 1))
      last=$m
    fi
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "the poll loop died on a repeated reminder ledger failure: $(cat "$dir/cycle2.err")"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$touches" -eq 3 ] \
    || fail "a failing ledger at a 3s cadence survived 15s without raising three bounded alarms (got $touches)"
  alarm=$(grep -c -F 'watcher: open-decision reminder check failed' "$dir/cycle2.err" || true)
  [ "$alarm" -eq "$touches" ] \
    || fail "the quiet cycle printed $alarm alarm lines for $touches bounded raises: $(cat "$dir/cycle2.err")"
  settle_wakes "$dir"
  # Stretching the cadence past the gap between cycles keeps the alarm raised
  # at the killed cycle suppressed, and supervision keeps surfacing new status.
  printf 'blocked [at=900000000] [key=live]: help\n' > "$dir/state/mate.status"
  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_POLL=1 FM_WATCH_TICK_ALARM_SECS=300 \
    FM_OPEN_DECISION_OVERDUE_SECS=100 FM_OPEN_DECISION_BACKOFF_MAX_SECS=400 \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/cycle3.out" 2> "$dir/cycle3.err" || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a suppressed-cadence cycle beside the ledger failure died (rc=$rc): $(cat "$dir/cycle3.err")"
  grep -F "signal: $dir/state/mate.status" "$dir/cycle3.out" >/dev/null \
    || fail "supervision stopped surfacing new status after repeated ledger failures: $(cat "$dir/cycle3.out" "$dir/cycle3.err")"
  ! grep -Fq 'watcher: open-decision reminder check failed' "$dir/cycle3.err" \
    || fail "the ledger alarm re-raised inside its cadence: $(cat "$dir/cycle3.err")"
  alarm=$(cat "$dir/cycle1.err" "$dir/cycle2.err" "$dir/cycle3.err" \
    | grep -c -F 'watcher: open-decision reminder check failed' || true)
  [ "$alarm" -eq 4 ] \
    || fail "the ledger alarm over three failing cycles was $alarm lines, expected 4: one per elapsed cadence, never one per poll"
  pass "a failing reminder ledger alarms once per elapsed cadence while surviving cycles keep surfacing new status"
}

test_watcher_loop_invalid_settings_refusal() {
  local dir="$TMP_ROOT/watcher-invalid-settings" pid i=0 rc
  mkdir -p "$dir/state" "$dir/config"
  fm_test_track_watcher_state "$dir/state"
  touch "$dir/config/open-decision-reminders" "$dir/state/home-summary.json"
  printf 'blocked [at=1000] [key=api]: help\n' > "$dir/state/worker.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_OPEN_DECISION_OVERDUE_SECS=0 \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "watcher kept polling with an invalid reminder threshold"
  fi
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 1 ] || fail "invalid settings did not keep the watcher-stopping refusal: rc=$rc"
  grep -F 'watcher: invalid open-decision reminder settings' "$dir/err" >/dev/null \
    || fail "the invalid-settings refusal did not name the settings: $(cat "$dir/err")"
  pass "invalid reminder settings keep their watcher-stopping refusal at the poll loop"
}

fm_test_run test_disabled test_oldest_and_backoff test_numeric_keys_are_distinct \
  test_numeric_tasks_are_distinct test_resolution_and_reopen \
  test_wait_exemptions test_unknown_times_and_keyless test_timed_fold_is_incremental \
  test_invalid_settings test_timed_cursor_retirement test_watcher_loop \
  test_watcher_loop_survives_ledger_failure test_watcher_loop_invalid_settings_refusal
