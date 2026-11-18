#!/usr/bin/env bash
# Targeted driver for the local-model slot-release cases of tests/fm-pr-merge.test.sh.
#
# The full fm-pr-merge suite runs hundreds of sequential gh-mock cases and (on hosts
# missing the pinned forge tooling) aborts long before the slot-release cases at the
# tail. This driver runs ONLY the three committed slot-release regression cases
# (test_merge_success_releases_the_local_model_slot, test_merge_failure_keeps_the_slot_claim,
# test_merge_leaves_another_tasks_slot_claim_untouched) through the suite's own helpers:
#   - lines 1..795   : suite header (lib.sh, local-llm lib, fixture globals) + shared
#                      fixture helpers (make_case, add_gh_mocks, add_gh_mocks_merge_fails,
#                      run_pr_merge, ...)
#   - lines 5765..5844: the three committed slot-release test function definitions
#   - lines 5852..5854: their invocations
# The lib.sh source line is rewritten to an absolute path because the extracted
# script no longer lives in tests/.
set -u
REPO="$1"
[ -f "$REPO/tests/fm-pr-merge.test.sh" ] || { echo "driver: suite not found at $REPO/tests/fm-pr-merge.test.sh" >&2; exit 2; }
DRIVER_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-merge-slot.XXXXXX")
sed -n '1,795p' "$REPO/tests/fm-pr-merge.test.sh" \
  | sed "13c . \\\"$REPO/tests/lib.sh\\\"" \
  > "$DRIVER_DIR/suite.sh"
sed -n '5765,5844p' "$REPO/tests/fm-pr-merge.test.sh" >> "$DRIVER_DIR/suite.sh"
sed -n '5852,5854p' "$REPO/tests/fm-pr-merge.test.sh" >> "$DRIVER_DIR/suite.sh"
bash "$DRIVER_DIR/suite.sh"
rc=$?
rm -rf "$DRIVER_DIR"
exit $rc
