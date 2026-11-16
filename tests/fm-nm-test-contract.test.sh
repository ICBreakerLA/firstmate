#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml configures commands.test to run the
# deterministic portable lanes through bin/fm-test-run.sh, and never selects the
# real-Herdr family.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_commands_test_runs_the_portable_lanes() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false) ? "" : val.to_s
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  [ -n "$val" ] \
    || fail "commands.test must be present: the local no-mistakes gate owns broad deterministic regression"
  case "$val" in
    *bin/fm-test-run.sh*) ;;
    *) fail "commands.test must run the lane owner bin/fm-test-run.sh; got: $val" ;;
  esac
  case "$val" in
    *--check-coverage*) ;;
    *) fail "commands.test must run the lane coverage guard; got: $val" ;;
  esac
  local lane
  for lane in portable-parallel-1 portable-parallel-2 portable-serial; do
    case "$val" in
      *"--lane $lane"*) ;;
      *) fail "commands.test must select --lane $lane; got: $val" ;;
    esac
  done
  case "$val" in
    *--all* | *real-herdr-gated*)
      fail "commands.test must never select the real-Herdr family: a gate round must not drive a live Herdr session; got: $val"
      ;;
  esac
  pass "no-mistakes commands.test runs the portable lanes and excludes the real-Herdr family"
}

test_nm_commands_test_runs_the_portable_lanes
