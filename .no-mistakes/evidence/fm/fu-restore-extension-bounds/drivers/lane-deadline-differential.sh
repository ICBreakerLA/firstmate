#!/usr/bin/env bash
# Adversarial differential driver for tests/fm-extension-binding.test.sh.
#
# It sources the REAL suite (real run_extension_section_lanes coordinator code)
# with every real section gated out (segment=coordinator-pass), then stubs the
# lane child with a timed sleep and drives the coordinator's deadline and
# concurrency semantics directly. Run it against the base suite and the target
# suite to show the shared-deadline failure mode and the per-lane fix.
#
# Usage: lane-deadline-differential.sh <path-to-suite>
set -u
SUITE=${1:?suite path required}
export FM_EXTENSION_BINDING_SEGMENT=coordinator-pass
# Neutralize the suite's fail()/final exit so control returns to this driver.
exit() { return "${1:-0}"; }
# shellcheck disable=SC1090
. "$SUITE"

# Stub lane: a timed sleep publishing a real lane result through the suite's
# own publisher, so the coordinator drains it exactly as it drains a real lane.
FAKE_LANE_SECONDS=${FAKE_LANE_SECONDS:-12}
run_extension_section_lane() {
  local result_file=$1 section=$2
  trap - EXIT HUP INT TERM
  ( sleep "${FAKE_LANE_SECONDS:-12}" ) &
  local pid=$! rc=0
  printf '%s\n' "$pid" > "${result_file}.pid"
  wait "$pid" || rc=$?
  publish_section_lane_result "$result_file" "$rc"
  return "$rc"
}

echo "== lane bound = $EXTENSION_SECTION_LANE_MAX_SECONDS"

if [ "${MODE:-serialized}" = wide ]; then
  # 16 lanes x 24s at default concurrency 12: twelve start at t=0, the last
  # four queue behind them and start at ~t=24, finishing at ~t=48. Under the
  # base shared deadline (measured from the FIRST launch, t=0+34) the queued
  # lanes are killed at t=34 -> 124. Under per-lane deadlines each queued
  # lane owns 34s from its own launch -> 0.
  echo "== wide: 16 lanes x 24s, 34s bound, default concurrency 12 (last four queue behind the wave)"
  t0=$(date +%s)
  FM_EXTENSION_BINDING_COORDINATOR_TIMEOUT_SECONDS=34 FAKE_LANE_SECONDS=24 \
    run_extension_section_lanes l01 l02 l03 l04 l05 l06 l07 l08 l09 l10 l11 l12 l13 l14 l15 l16
  echo "wide rc=$? elapsed=$(( $(date +%s) - t0 ))s  (base shared deadline expects 124 at ~34s; target per-lane expects 0 at ~48s)"
else
  echo "== chain: 3 lanes x ${FAKE_LANE_SECONDS}s, 34s bound, concurrency 1 (serialized, each lane needs 12s < 34s)"
  t0=$(date +%s)
  FM_EXTENSION_BINDING_LANE_CONCURRENCY=1 \
    FM_EXTENSION_BINDING_COORDINATOR_TIMEOUT_SECONDS=34 \
    run_extension_section_lanes lane-a lane-b lane-c
  echo "chain rc=$? elapsed=$(( $(date +%s) - t0 ))s  (target serialized expects 0; base has no serialization knob so lanes run concurrently)"
fi

echo "== bound cap: request a 120s timeout (the PR 64 tolerance value) against the suite's lane bound"
FM_EXTENSION_BINDING_LANE_CONCURRENCY=1 FAKE_LANE_SECONDS=1 \
  FM_EXTENSION_BINDING_COORDINATOR_TIMEOUT_SECONDS=120 \
  run_extension_section_lanes lane-a
echo "timeout120 rc=$?  (target expects 64 rejection at the 34s cap; base expects 0 acceptance under 120)"

echo "== bound cap boundary: 35s timeout"
FM_EXTENSION_BINDING_LANE_CONCURRENCY=1 FAKE_LANE_SECONDS=1 \
  FM_EXTENSION_BINDING_COORDINATOR_TIMEOUT_SECONDS=35 \
  run_extension_section_lanes lane-a
echo "timeout35 rc=$?  (target expects 64)"

echo "== concurrency knob validation"
FM_EXTENSION_BINDING_LANE_CONCURRENCY=0 run_extension_section_lanes lane-a
echo "concurrency=0 rc=$?  (target expects 64)"
FM_EXTENSION_BINDING_LANE_CONCURRENCY=abc run_extension_section_lanes lane-a
echo "concurrency=abc rc=$?  (target expects 64)"
t0=$(date +%s)
FAKE_LANE_SECONDS=1 FM_EXTENSION_BINDING_LANE_CONCURRENCY=1 run_extension_section_lanes lane-a lane-b lane-c
echo "concurrency=1 valid rc=$? elapsed=$(( $(date +%s) - t0 ))s  (target expects 0)"
