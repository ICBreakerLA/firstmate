#!/usr/bin/env bash
# Contract: .github/workflows/macos-bash.yml is the fork's only hosted workflow
# for the suite. It keeps exactly the stock macOS Bash job, triggered only by a
# path-filtered pull request and by hand, so it cannot grow back into a second
# full CI and never runs on a push to main.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/macos-bash.yml"

test_macos_workflow_is_only_the_stock_bash_job() {
  assert_present "$WORKFLOW" ".github/workflows/macos-bash.yml is missing"
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .github/workflows/macos-bash.yml as YAML"
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
jobs = doc.fetch("jobs")
raise "the macOS workflow must carry only macos-stock-bash, got #{jobs.keys.join(", ")}" \
  unless jobs.keys == ["macos-stock-bash"]
triggers = doc[true] || doc["on"]
raise "a push trigger would spend hosted minutes on every main merge" if triggers.key?("push")
raise "the stock Bash job must be dispatchable by hand" unless triggers.key?("workflow_dispatch")
paths = triggers.fetch("pull_request").fetch("paths")
expected = %w[bin/** tests/** .github/workflows/**]
raise "pull_request paths must be #{expected.join(", ")}, got #{paths.join(", ")}" unless paths.sort == expected.sort
job = jobs.fetch("macos-stock-bash")
timeout = job["timeout-minutes"]
raise "macos-stock-bash must keep a finite timeout, got #{timeout.inspect}" unless timeout.is_a?(Integer) && timeout.positive?
steps = job.fetch("steps")
raise "macos-stock-bash must keep its stock Bash step" \
  unless steps.any? { |s| s["shell"].to_s.start_with?("/bin/bash") }
' "$WORKFLOW" || fail "macOS workflow contract"
  pass "the macOS workflow keeps only the path-filtered stock Bash job, with no push trigger"
}

test_macos_workflow_is_only_the_stock_bash_job
