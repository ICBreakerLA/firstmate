# fm-test-slice-gate.sh - runs one slice of a test script's top-level test_* calls.
# bin/fm-test-run.sh points BASH_ENV at this file for exactly one sliced script
# (FM_TEST_SLICE_SCRIPT) with FM_TEST_SLICE=<k[,k]...>of<n>. Every top-level bare
# test_* call is numbered in call order and runs only when its position falls in
# the listed slices; the others are replaced by a no-op before they execute, so
# the n slices together run every call exactly once. Each decision is appended
# to FM_TEST_SLICE_LOG so the runner can refuse a slice that ran nothing.
# The gate disarms itself in child shells by unsetting BASH_ENV.
if [ -n "${FM_TEST_SLICE:-}" ] && [ "${0:-}" = "${FM_TEST_SLICE_SCRIPT:-}" ]; then
  unset BASH_ENV
  FM_SLICE_WANT=",${FM_TEST_SLICE%of*},"
  FM_SLICE_COUNT=${FM_TEST_SLICE#*of}
  FM_SLICE_SEEN=0
  fm_slice_decide() {
    local cmd=$1 slot
    case "$cmd" in
      test_*) ;;
      *) return 0 ;;
    esac
    case "$cmd" in
      *[!A-Za-z0-9_]*) return 0 ;;
    esac
    FM_SLICE_SEEN=$((FM_SLICE_SEEN + 1))
    slot=$(((FM_SLICE_SEEN - 1) % FM_SLICE_COUNT + 1))
    case "$FM_SLICE_WANT" in
      *",$slot,"*)
        [ -z "${FM_TEST_SLICE_LOG:-}" ] || printf 'ran %s\n' "$cmd" >>"$FM_TEST_SLICE_LOG"
        ;;
      *)
        [ -z "${FM_TEST_SLICE_LOG:-}" ] || printf 'skipped %s\n' "$cmd" >>"$FM_TEST_SLICE_LOG"
        eval "$cmd() { return 0; }"
        ;;
    esac
    return 0
  }
  trap 'fm_slice_decide "$BASH_COMMAND"' DEBUG
fi
