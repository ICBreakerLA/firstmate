#!/usr/bin/env bash
# Targeted driver for the local-model slot-release case of tests/fm-teardown.test.sh.
#
# The full teardown suite runs hundreds of sequential cases; this driver runs ONLY
# the committed slot-release regression case test_teardown_releases_the_local_model_slot
# through the suite's own helpers, by extracting:
#   - lines 1..704   : suite header (lib.sh, local-llm lib, fixture globals) + shared
#                      fixture helpers (make_case, write_meta, wt_commit,
#                      add_fork_with_pushed_branch, run_teardown, ...)
#   - lines 6739..6770: the committed slot-release test function and its invocation
# The lib.sh source line is rewritten to an absolute path because the extracted
# script no longer lives in tests/.
set -u
REPO="$1"
[ -f "$REPO/tests/fm-teardown.test.sh" ] || { echo "driver: suite not found at $REPO/tests/fm-teardown.test.sh" >&2; exit 2; }
DRIVER_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-teardown-slot.XXXXXX")
sed -n '1,704p' "$REPO/tests/fm-teardown.test.sh" \
  | sed "84c . \\\"$REPO/tests/lib.sh\\\"" \
  > "$DRIVER_DIR/suite.sh"
sed -n '6739,6770p' "$REPO/tests/fm-teardown.test.sh" >> "$DRIVER_DIR/suite.sh"
bash "$DRIVER_DIR/suite.sh"
rc=$?
rm -rf "$DRIVER_DIR"
exit $rc
