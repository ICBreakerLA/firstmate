# bin/fm-wake-triage-lib.sh - deterministic wake triage for bin/fm-watch.sh.
#
# Sourced by fm-watch.sh after the push-transition lib; it provides no standalone
# entry point. Every decision is bash: no model reads a wake and decides it.
#
# The always-on rules (Step 2) cut the benign majority of stale: rechecks the
# watcher currently re-alarms for a task that is finished, closed, paused, or
# waiting on the captain:
#   R1  never emit a stale: for a task with no state/<task>.meta (torn down).
#       The backbone is meta-backed (recorded_windows), so this guards the
#       teardown race - a meta removed between the window listing and the emit.
#   R2  a stale: for a task whose latest status line is a declared wait
#       (done / paused / blocked-for-captain) backs off exponentially: the next
#       allow is after double the previous gap, starting at the current gap and
#       capped at 2 hours (7200s). A new status line or a changed endpoint
#       (window key) resets the backoff. State:
#         state/.wake-backoff-<task>      "<interval> <next-allowed> <key>"
#         state/.wake-backoff-sig-<task>  the latest status line it was set for
#   R3  a repeated identical check: result for the same key adds no new wake.
#       State: state/.wake-check-seen-<sanitized-key> holds the last reason.
#
# The opt-in batching (Step 3) is inert unless FM_WAKE_BATCH_SECS > 0 (env) or
# the file config/wake-batch-secs names a positive number; default 0 = off. It
# is a no-op on the emit path when off, so turning it off leaves behaviour
# unchanged. When on, a non-urgent wake (a stale: for a declared-wait task - the
# R2 class) is held in state/.wake-batch instead of emitted; an urgent wake
# flushes the held rows with it, and the watcher emits one batch wake when the
# window has elapsed since the first hold.
#
# Every suppression and hold is logged to state/wake-triage.log as one line
# "<time> <kind> <task> <rule> <action>" so a wrongly dropped wake is visible.
# The file is size-capped.

# Resolve the triage state paths and the batch window once, at watcher start.
wake_triage_init() {
  WAKE_TRIAGE_LOG="${WAKE_TRIAGE_LOG:-$STATE/wake-triage.log}"
  WAKE_TRIAGE_LOG_MAX_BYTES=${FM_WAKE_TRIAGE_LOG_MAX_BYTES:-262144}
  WAKE_BATCH_FILE="${WAKE_BATCH_FILE:-$STATE/.wake-batch}"
  WAKE_BATCH_SINCE="${WAKE_BATCH_SINCE:-$STATE/.wake-batch-since}"
  WAKE_BATCH_SECS=0
  if [ -n "${FM_WAKE_BATCH_SECS:-}" ]; then
    case "$FM_WAKE_BATCH_SECS" in *[!0-9]*|'') : ;; *) WAKE_BATCH_SECS=$FM_WAKE_BATCH_SECS ;; esac
  elif [ -f "$CONFIG/wake-batch-secs" ]; then
    WAKE_BATCH_SECS=$(tr -cd '0-9' < "$CONFIG/wake-batch-secs" 2>/dev/null || true)
  fi
  case "${WAKE_BATCH_SECS:-0}" in *[!0-9]*|'') WAKE_BATCH_SECS=0 ;; esac
  FM_WAKE_TRIAGE_BATCH_ON=0
  wake_triage_batch_on && FM_WAKE_TRIAGE_BATCH_ON=1
}

# 0 when batching is enabled (a positive window is configured).
wake_triage_batch_on() {
  [ "${WAKE_BATCH_SECS:-0}" -gt 0 ] 2>/dev/null
}

# Log one triage decision. <kind> <task> <rule> <action>; a missing/blank task
# is recorded as "?". Never fails the caller.
wake_triage_log() {
  local kind=${1:-?} task=${2:-?} rule=${3:-?} action=${4:-?}
  printf '[%s] %s %s %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$kind" "$task" "$rule" "$action" \
    >> "$WAKE_TRIAGE_LOG" 2>/dev/null || return 0
  local size
  size=$(wc -c < "$WAKE_TRIAGE_LOG" 2>/dev/null || echo 0)
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  if [ "$size" -gt "$WAKE_TRIAGE_LOG_MAX_BYTES" ]; then
    local keep tmp
    keep=$(( WAKE_TRIAGE_LOG_MAX_BYTES / 2 ))
    tmp="${WAKE_TRIAGE_LOG}.cap"
    tail -c "$keep" "$WAKE_TRIAGE_LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$WAKE_TRIAGE_LOG" 2>/dev/null \
      || rm -f "$tmp"
  fi
  return 0
}

# R1: 0 iff <task> names a live task (a state/<task>.meta exists).
wake_triage_task_alive() {
  local task=$1
  [ -n "$task" ] || return 1
  [ -e "$STATE/$task.meta" ]
}

# R2 predicate: 0 iff <status-file>'s latest status line is a declared wait -
# done / blocked / needs-decision / failed (captain-relevant) or paused /
# captain-held. A blank or absent log is not a declared wait.
wake_triage_declared_wait() {
  local f=$1 last
  last=$(last_status_line "$f" 2>/dev/null || true)
  [ -n "$last" ] || return 1
  status_is_paused_or_captain_held "$last" && return 0
  status_is_captain_relevant "$last" && return 0
  return 1
}

# R2 backoff: 0 = allow (and advance the per-task marker), 1 = within backoff.
# <task> <key> <current-gap>. The key is the sanitized window, so an endpoint
# change resets the backoff; a new latest status line does the same.
wake_triage_backoff_allow() {
  local task=$1 key=$2 gap=$3 f sf now sig interval next
  local cur_interval= cur_next= cur_key= cur_sig=
  case "$gap" in ''|*[!0-9]*) gap=${STALE_ESCALATE_SECS:-240} ;; esac
  [ "$gap" -gt 0 ] || gap=240
  key=$(printf '%s' "$key" | tr -c 'A-Za-z0-9' '_')
  f="$STATE/.wake-backoff-$task"
  sf="$STATE/.wake-backoff-sig-$task"
  now=$(date +%s)
  sig=$(last_status_line "$STATE/$task.status" 2>/dev/null || true)
  if [ -e "$f" ]; then
    read -r cur_interval cur_next cur_key < "$f" 2>/dev/null || true
    cur_sig=$(cat "$sf" 2>/dev/null || true)
  fi
  # A new status line or a changed endpoint re-arms: allow once, start the gap.
  if [ ! -e "$f" ] || [ "${cur_sig:-}" != "$sig" ] || [ "${cur_key:-}" != "$key" ]; then
    interval=$gap
    next=$(( now + interval ))
    printf '%s %s %s' "$interval" "$next" "$key" > "$f" 2>/dev/null || true
    printf '%s' "$sig" > "$sf" 2>/dev/null || true
    return 0
  fi
  # Same status and endpoint: allow only once the previous gap has elapsed,
  # then double it (capped at 2 hours) for the next interval.
  case "${cur_next:-0}" in ''|*[!0-9]*) cur_next=0 ;; esac
  if [ "$now" -ge "$cur_next" ]; then
    interval=$(( ${cur_interval:-$gap} * 2 ))
    [ "$interval" -gt 7200 ] && interval=7200
    next=$(( now + interval ))
    printf '%s %s %s' "$interval" "$next" "$cur_key" > "$f" 2>/dev/null || true
    return 0
  fi
  return 1
}

# R3 check dedup: 0 = a new check result (record it and allow the wake),
# 1 = the same reason for the same key since the last emit (add no new wake).
wake_triage_check_repeat() {
  local key=$1 reason=$2 f
  f="$STATE/.wake-check-seen-$(printf '%s' "$key" | tr -c 'A-Za-z0-9' '_')"
  [ "$(cat "$f" 2>/dev/null || true)" = "$reason" ] && return 1
  printf '%s' "$reason" > "$f" 2>/dev/null || true
  return 0
}

# R1 guard: 0 = suppress this stale (the task is torn down - no meta), having
# logged the decision and dropped its leaked backoff marker; 1 = proceed. This
# is the single owner of the R1 contract, shared by the gate and the stale sites
# that apply R1 alone.
wake_triage_r1_guard() {
  local task=$1
  [ -n "$task" ] || return 1
  [ -e "$STATE/$task.meta" ] && return 1
  wake_triage_log stale "$task" R1 suppress
  rm -f "$STATE/.wake-backoff-$task" "$STATE/.wake-backoff-sig-$task" 2>/dev/null
  return 0
}

# The gate. <kind> <task> <key> <reason> [current-gap]. Sets WAKE_TRIAGE_ACTION to
# emit (proceed exactly as the caller already would), suppress (R2: do not emit),
# or hold (batching: the row is held for the window). Only stale: wakes are gated;
# signal:, check: and heartbeat are urgent and emit as-is (check dedup is applied
# at its own site). The gate owns the R2 declared-wait backoff only, called from
# the fast repeat path (wedge_timer_check) where the pane re-escalates on a fixed
# gap; the slower declared-wait resurface and the one-shot first-sight sites call
# wake_triage_r1_guard alone so their own cadence is left intact.
# R1 is NOT decided here: wedge_timer_check is a leaf reached only through the
# meta-backed backbone in the real watcher (a torn-down task is never listed), and
# its direct-drive tests exercise no-meta lanes that must still escalate. The R1
# guard therefore lives at the other stale sites, where it owns the teardown race.
wake_triage_gate() {
  local kind=$1 task=$2 key=$3 reason=$4 gap=${5:-${STALE_ESCALATE_SECS:-240}}
  WAKE_TRIAGE_ACTION=emit
  [ "$kind" = stale ] || return 0
  if [ -n "$task" ] && wake_triage_declared_wait "$STATE/$task.status"; then
    if ! wake_triage_backoff_allow "$task" "$key" "$gap"; then
      WAKE_TRIAGE_ACTION=suppress
      wake_triage_log "$kind" "$task" R2 suppress
      return 0
    fi
  fi
  return 0
}
