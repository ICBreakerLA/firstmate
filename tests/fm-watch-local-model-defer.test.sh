#!/usr/bin/env bash
# tests/fm-watch-local-model-defer.test.sh - the local-model wedge deferral
# built into bin/fm-watch.sh. A local-model worker (bin/fm-local-llm-lib.sh's
# qwen3.8-27b-gsq-rco, served by a single-slot llama.cpp server) spends tens of
# minutes reading one large request after a context compaction: the pane and the
# worktree both sit still while the server is mid-prefill, so the watcher's wedge
# timer would otherwise escalate every STALE_ESCALATE_SECS, each wake costing the
# supervisor a turn. The deferral keeps the pane quiet while the server is
# processing, and is a DEFERRAL, not a cancellation - the idle timer restarts so
# a prefill that ENDS re-escalates within one STALE_ESCALATE_SECS, and the pane
# still re-surfaces once per PAUSE_RESURFACE_SECS. The probe is fail-closed: an
# idle server, an unreachable one, and a non-local-model lane all keep the
# unchanged ladder, so a read that is not positive proof of a busy server never
# takes the wedge away.
#
# Drives wedge_timer_check directly in a child shell (the same harness
# tests/fm-watch-triage.test.sh uses for the wait-record cases) and stubs the
# server's /slots endpoint with a FILE through FM_LOCAL_LLM_SLOTS_URL, so no
# llama.cpp server is needed.

set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"

WINDOW="test:fm-wedge"
KEY="test_fm-wedge"
LOCAL_MODEL="qwen3.8-27b-gsq-rco"

TMP_ROOT=$(fm_test_tmproot fm-watch-local-model-defer-tests)

# The /slots body the stub server would answer with: the profile's single slot,
# whose is_processing is the one wire signal the probe reads.
slots_body() {  # <true|false>
  printf '{"slots":[{"is_processing":%s,"id":"0"}]}\n' "$1"
}

# One wedge-timer round for a lane whose meta names <model> and whose /slots
# endpoint is <slots-url>. Drives wedge_timer_check in a child shell exactly as
# fm-watch-triage.test.sh does: a live agent (so a refused deferral keeps the
# ladder rather than reading a backend this shell has none of) and wake() stubbed
# to a no-op. The lane is provably working (a `working:` status) and writes no
# worktree, so the two cheaper deferrals above it decline and only the local-model
# probe can change the outcome. Prints nothing; asserts on the durable state.
run_local_model_round() {  # <name> <model> <slots-url>
  local name=$1 model=$2 slots_url=$3 dir state out
  dir=$(make_case "$name"); state="$dir/state"
  printf 'working: prefill under way\n' > "$state/wedge.status"
  printf 'window=%s\nmodel=%s\n' "$WINDOW" "$model" > "$state/wedge.meta"
  printf '%s\n' "$(( $(date +%s) - 600 ))" > "$state/.stale-since-$KEY"

  out="$dir/round.out"
  FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_LOCAL_LLM_SLOTS_URL="$slots_url" \
    bash -c '
      # shellcheck disable=SC1090,SC1091
      . "$1"
      wake() { :; }
      fm_backend_agent_state() { printf alive; }
      wedge_timer_check "test:fm-wedge" "$FM_STATE_OVERRIDE/.stale-since-test_fm-wedge" \
        "non-terminal stale" "$FM_STATE_OVERRIDE/.wedge-escalations-test_fm-wedge" wedge \
        local-model-pane
    ' _ "$WATCH" > "$out" 2>&1 \
    || fail "the wedge timer failed on the local-model lane ($name): $(cat "$out")"
  LOCAL_MODEL_STATE=$state
}

# A deferral restarts the idle timer and records its chain marker, and is NOT an
# escalation: no wedge alarm, no moved counter, and the deferral is logged to the
# triage log so the absorption is auditable.
assert_local_model_deferred() {  # <state> <what>
  local state=$1 what=$2
  [ -e "$state/.localmodel-since-$KEY" ] \
    || fail "$what was not recorded as a local-model deferral: $(cat "$state/.wake-queue" 2>/dev/null)"
  [ ! -e "$state/.wedge-escalations-$KEY" ] \
    || fail "$what advanced the wedge escalation counter while deferring"
  grep -F 'possible wedge' "$state/.wake-queue" 2>/dev/null | grep -q . \
    && fail "$what escalated instead of deferring: $(cat "$state/.wake-queue")"
  [ -s "$state/.stale-since-$KEY" ] \
    || fail "$what cleared the idle timer on a deferral, so the next window cannot re-probe"
  grep -F 'local model server processing' "$state/.watch-triage.log" >/dev/null \
    || fail "$what did not log its deferral to the triage log: $(cat "$state/.watch-triage.log" 2>/dev/null)"
}

# An escalation kept the unchanged ladder: the wedge alarm with a moved counter
# and a cleared idle timer, no deferral chain marker, and no deferral log line.
assert_local_model_escalated() {  # <state> <what>
  local state=$1 what=$2
  grep -F 'possible wedge, escalation 1' "$state/.wake-queue" 2>/dev/null | grep -q . \
    || fail "$what did not keep the unchanged ladder: $(cat "$state/.wake-queue" 2>/dev/null)"
  [ "$(cat "$state/.wedge-escalations-$KEY" 2>/dev/null || echo 0)" -eq 1 ] \
    || fail "$what did not count its escalation"
  [ ! -e "$state/.localmodel-since-$KEY" ] \
    || fail "$what recorded a local-model deferral chain it should not have reached"
  [ ! -e "$state/.stale-since-$KEY" ] \
    || fail "$what did not clear the idle timer after a real escalation"
}

# The case the fix exists for: the server is mid-request, so a provably-working
# local-model pane is deferred rather than escalated.
test_local_model_processing_defers() {
  local stub
  stub=$(fm_test_tmproot local-model-stub-processing)
  slots_body true > "$stub/slots"
  run_local_model_round processing "$LOCAL_MODEL" "file://$stub/slots"
  assert_local_model_deferred "$LOCAL_MODEL_STATE" "a local-model lane whose server is mid-request"
  pass "a local-model lane whose server is still processing its request defers the wedge instead of escalating"
}

# Fail-closed, direction one: a healthy server that is NOT busy gives the probe
# no excuse, so the unchanged ladder fires.
test_local_model_idle_server_escalates() {
  local stub
  stub=$(fm_test_tmproot local-model-stub-idle)
  slots_body false > "$stub/slots"
  run_local_model_round idle "$LOCAL_MODEL" "file://$stub/slots"
  assert_local_model_escalated "$LOCAL_MODEL_STATE" "a local-model lane whose server is idle"
  pass "a local-model lane whose server is idle wedge-escalates on the unchanged ladder"
}

# Fail-closed, direction two: the endpoint does not answer at all, so the probe
# declines and the pane is not quietly held just because it cannot be read.
test_local_model_unreachable_server_escalates() {
  local stub
  stub=$(fm_test_tmproot local-model-stub-unreachable)
  # A file:// URL naming a path that does not exist: curl fails with no body, the
  # same fail-closed reading the probe takes for a server that will not answer.
  run_local_model_round unreachable "$LOCAL_MODEL" "file://$stub/absent-slots"
  assert_local_model_escalated "$LOCAL_MODEL_STATE" "a local-model lane whose server is unreachable"
  pass "a local-model lane whose server cannot be reached wedge-escalates on the unchanged ladder"
}

# The model gate, independent of the server: even a BUSY server must not defer a
# lane that is not a local-model worker, so the meta's model id is what decides,
# not the probe. A non-local lane escalates with the server pointed at busy.
test_non_local_model_escalates_despite_busy_server() {
  local stub
  stub=$(fm_test_tmproot local-model-stub-nonlocal)
  slots_body true > "$stub/slots"
  run_local_model_round non-local "claude-haiku-4-5" "file://$stub/slots"
  assert_local_model_escalated "$LOCAL_MODEL_STATE" "a non-local-model lane with a busy server"
  pass "a lane whose model is not the local profile wedge-escalates even while the server reports busy"
}

test_local_model_processing_defers
test_local_model_idle_server_escalates
test_local_model_unreachable_server_escalates
test_non_local_model_escalates_despite_busy_server