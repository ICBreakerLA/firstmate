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
  command -v python3 >/dev/null 2>&1 \
    || fail "python3 is required to run the macOS workflow contract"
  command -v node >/dev/null 2>&1 \
    || fail "node with js-yaml is required to parse .github/workflows/macos-bash.yml as YAML"
  node -e 'require("js-yaml")' >/dev/null 2>&1 \
    || fail "node with js-yaml is required to parse .github/workflows/macos-bash.yml as YAML"
  python3 - "$WORKFLOW" <<'PY' || fail "macOS workflow contract"
import json
import subprocess
import sys


def fail(message):
    sys.stderr.write(message + "\n")
    sys.exit(1)


def load_yaml(path):
    # Parse with a real YAML consumer rather than matching source text. The gate
    # host ships js-yaml for node; PyYAML is not installed.
    script = (
        "const fs=require('fs');"
        "const yaml=require('js-yaml');"
        "process.stdout.write(JSON.stringify(yaml.load(fs.readFileSync(process.argv[1],'utf8'))));"
    )
    proc = subprocess.run(
        ["node", "-e", script, path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if proc.returncode != 0:
        fail("node with js-yaml is required to parse the workflow as YAML: " + proc.stderr.strip())
    try:
        return json.loads(proc.stdout)
    except ValueError as exc:
        fail("node with js-yaml did not produce a YAML document: " + str(exc))


doc = load_yaml(sys.argv[1]) or {}

jobs = doc["jobs"]
if list(jobs.keys()) != ["macos-stock-bash"]:
    fail("the macOS workflow must carry only macos-stock-bash, got " + ", ".join(jobs.keys()))
triggers = doc.get(True) or doc.get("on") or {}
if "push" in triggers:
    fail("a push trigger would spend hosted minutes on every main merge")
if "workflow_dispatch" not in triggers:
    fail("the stock Bash job must be dispatchable by hand")
concurrency = doc.get("concurrency")
if not isinstance(concurrency, dict):
    fail("the workflow needs a concurrency group so a superseded pull request cancels its in-flight run")
group = concurrency.get("group")
if not isinstance(group, str) or not group.strip():
    fail("concurrency.group must be non-empty, got {!r}".format(group))
if concurrency.get("cancel-in-progress") is not True:
    fail("concurrency.cancel-in-progress must be true, got {!r}".format(concurrency.get("cancel-in-progress")))
paths = triggers["pull_request"]["paths"]
expected = ["bin/**", "tests/**", ".github/workflows/**"]
if sorted(paths) != sorted(expected):
    fail("pull_request paths must be {}, got {}".format(", ".join(expected), ", ".join(paths)))
job = jobs["macos-stock-bash"]
timeout = job.get("timeout-minutes")
if not isinstance(timeout, int) or isinstance(timeout, bool) or timeout <= 0:
    fail("macos-stock-bash must keep a finite timeout, got {!r}".format(timeout))
steps = job["steps"]
if not any(str(step.get("shell", "")).startswith("/bin/bash") for step in steps):
    fail("macos-stock-bash must keep its stock Bash step")
PY
  pass "the macOS workflow keeps only the path-filtered stock Bash job, with no push trigger"
}

test_macos_workflow_is_only_the_stock_bash_job
