#!/usr/bin/env bash
# fm-gate-park-lib.sh - the single owner of parked-gate detection: a worker
# sitting idle while its no-mistakes run is parked at a gate that needs action.
#
# Sourced by bin/fm-watch.sh, never executed. Requires fm-classify-lib.sh and
# fm-timeout-lib.sh to be sourced first, and the caller's STATE, SCRIPT_DIR,
# FM_HOME and FM_CREW_STATE_BIN.
#
# WHY. A run that parks at an approval or ask-user gate waits for a human-owed
# answer, but the worker's own bounded drive wait can expire first. The worker
# then sits idle, nothing it does will ever notice the gate, and the only thing
# watching is the wedge timer, which fires minutes later and only on a quiet
# pane. This check reads the run state the moment the worker is idle, so the gap
# is the poll cadence rather than the wedge window.
#
# THE RULE. For one idle task, read the authoritative current state
# ($FM_CREW_STATE_BIN). Only a `parked` verdict from a run step is a gate. For
# a task not nudged within the last FM_GATE_PARK_NUDGE_SECS (default 300):
#   - when the task's own status log holds no open needs-decision bound to that
#     run, nobody has been told: send the worker the reattach nudge (read the
#     gate with `no-mistakes axi run` and report it as its brief says) and wake
#     firstmate;
#   - when the worker already reported it, firstmate was already woken by that
#     status line, so nothing is added.
# The nudge is the one mechanical reaction and carries no decision: it never
# answers, approves, merges or discards, and tells the worker so. It is sent at
# most once per interval per task, the last-nudge time being the only record, so
# a worker idle at the same gate (or parked at an identical gate again) is
# nudged again once the interval passes; the caller never asks about a
# secondmate. A failed or bounded-out send does not stop the wake, which says so.
#
# CADENCE. The state read is the costly one (it may make a bounded no-mistakes
# call), so it runs for an idle task when its turn-ended touch is newer than the
# last read (a turn just ended: the moment a drive wait expires) or the last
# read is FM_GATE_PARK_SECS old (default 30). FM_GATE_PARK_SECS=0 turns the
# check off. FM_GATE_PARK_READ_TIMEOUT (default 10) bounds the state read, with
# its forge fallback skipped (a parked verdict never needs it), so an idle task
# never stalls the poll; FM_GATE_PARK_SEND_TIMEOUT (default 12) bounds the nudge.
set -u

# shellcheck disable=SC2034 # output read by the sourcing script
GATE_PARK_REASON=''
# shellcheck disable=SC2034 # output read by the sourcing script
GATE_PARK_KEY=''
FM_GATE_PARK_SECS=${FM_GATE_PARK_SECS:-30}
FM_GATE_PARK_NUDGE_SECS=${FM_GATE_PARK_NUDGE_SECS:-300}
FM_GATE_PARK_SEND_TIMEOUT=${FM_GATE_PARK_SEND_TIMEOUT:-12}
FM_GATE_PARK_READ_TIMEOUT=${FM_GATE_PARK_READ_TIMEOUT:-10}

# shellcheck disable=SC2016 # literal backticks name a command for the worker
FM_GATE_PARK_NUDGE='Your no-mistakes run is parked at a gate and you are idle. Reattach now with `no-mistakes axi run` (no flags) to read the gate and its findings, then follow your brief: report any ask-user finding as needs-decision with the findings file and stop. Do not answer, approve, merge or discard anything on behalf of firstmate.'

gate_park_enabled() {
  case "$FM_GATE_PARK_SECS" in ''|*[!0-9]*|0) return 1 ;; esac
  return 0
}

# Whether this idle task is due a state read now (0) or not (1): never inside
# the nudge interval, else after a turn end or the read cadence.
gate_park_due() { # <task> <key>
  local task=$1 key=$2 eval_marker now last turn_at
  # shellcheck disable=SC2153 # STATE is set by the sourcing script
  eval_marker="$STATE/.gate-park-eval-$key"
  now=$(date +%s)
  if last=$(fm_path_mtime "$STATE/.gate-park-nudged-$key"); then
    [ $((now - last)) -ge "$FM_GATE_PARK_NUDGE_SECS" ] || return 1
  fi
  [ -e "$eval_marker" ] || return 0
  last=$(fm_path_mtime "$eval_marker") || return 0
  turn_at=$(fm_path_mtime "$STATE/$task.turn-ended") || turn_at=0
  [ "$turn_at" -le "$last" ] || return 0
  [ $((now - last)) -ge "$FM_GATE_PARK_SECS" ]
}

# gate_park_check <task> <key>: for an idle non-secondmate task. Returns 0 with
# the wake reason in GATE_PARK_REASON and the wake key in GATE_PARK_KEY (set, not
# printed, so a caller needs no subshell) when firstmate is owed a wake for a
# parked gate; returns 1 otherwise.
gate_park_check() {
  local task=$1 key=$2 line state src rest part gate='' run='' human='' detail
  local statusf="$STATE/$task.status"
  local nudge rc=0
  gate_park_enabled || return 1
  [ -n "$task" ] || return 1
  gate_park_due "$task" "$key" || return 1
  : > "$STATE/.gate-park-eval-$key" 2>/dev/null || true

  line=$(FM_CREW_STATE_NO_FORGE=1 fm_run_timed "$FM_GATE_PARK_READ_TIMEOUT" \
    "$FM_CREW_STATE_BIN" "$task" 2>/dev/null) || line=
  case "$line" in state:*) ;; *) return 1 ;; esac
  state=${line#state: }; state=${state%% *}
  src=${line#*source: }; src=${src%% *}
  [ "$state" = parked ] && [ "$src" = run-step ] || return 1
  rest="$line · "
  while [ -n "$rest" ]; do
    part=${rest%% · *}
    rest=${rest#* · }
    case "$part" in
      "parked at "*) gate=${part#parked at } ;;
      "run: "?*) run=${part#run: } ;;
    esac
    [ "$part" = "$FM_GATE_HUMAN_DECISION" ] && human=1
  done
  case "$run" in ''|*[[:space:]]*) return 1 ;; esac
  [ -n "$gate" ] || gate=gate
  if status_has_open_needs_decision "$statusf" "$run"; then
    return 1
  fi
  : > "$STATE/.gate-park-nudged-$key" || return 1
  FM_HOME="$FM_HOME" fm_run_timed "$FM_GATE_PARK_SEND_TIMEOUT" \
    "${FM_GATE_PARK_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}" "$task" "$FM_GATE_PARK_NUDGE" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    nudge="reattach nudge sent to the worker"
    fm_hj_record nudge 0 check "gate-parked:$task:$run" "$(date +%s)" "$task"
  elif fm_timed_out "$rc"; then
    nudge="reattach nudge timed out (nothing confirmed delivered)"
  else
    nudge="reattach nudge failed (exit $rc)"
  fi
  detail="parked at $gate${human:+, ask-user finding owed by firstmate}"
  # shellcheck disable=SC2034 # output read by the sourcing script
  GATE_PARK_REASON="gate-parked: $task $detail; worker idle and has not reported it ($nudge); you own any decision, approval or ask-user answer"
  # shellcheck disable=SC2034 # output read by the sourcing script
  GATE_PARK_KEY="gate-parked:$task:$run"
  return 0
}
