#!/usr/bin/env bash
# Contract: .no-mistakes.yaml's commands.test walks the deterministic portable
# lanes through bin/fm-test-run.sh, excludes the live-harness and pinned-hc
# families a gate must never drive, keeps the hermetic hc suite, and disables
# every default-on live guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_commands_test_runs_the_portable_lanes() {
  command -v python3 >/dev/null 2>&1 \
    || fail "python3 is required to run the no-mistakes commands.test contract"
  command -v node >/dev/null 2>&1 \
    || fail "node with js-yaml is required to parse .no-mistakes.yaml for this contract"
  node -e 'require("js-yaml")' >/dev/null 2>&1 \
    || fail "node with js-yaml is required to parse .no-mistakes.yaml for this contract"
  python3 - "$NM" "$ROOT" <<'PY' || fail "no-mistakes commands.test contract"
import json
import os
import re
import shlex
import subprocess
import sys

doc_path, root = sys.argv[1], sys.argv[2]


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
        fail("node with js-yaml is required to parse .no-mistakes.yaml as YAML: " + proc.stderr.strip())
    try:
        return json.loads(proc.stdout)
    except ValueError as exc:
        fail("node with js-yaml did not produce a YAML document: " + str(exc))


def split_clauses(command):
    parts = []
    buffer = ""
    quote = None
    index = 0
    while index < len(command):
        char = command[index]
        if quote:
            buffer += char
            if char == quote:
                quote = None
            elif char == "\\" and quote == '"' and index + 1 < len(command):
                index += 1
                buffer += command[index]
        elif char == '"' or char == "'":
            quote = char
            buffer += char
        elif char == "&" and index + 1 < len(command) and command[index + 1] == "&":
            parts.append(buffer.strip())
            buffer = ""
            index += 1
        else:
            buffer += char
        index += 1
    parts.append(buffer.strip())
    return [part for part in parts if part]


def split_clause(clause):
    tokens = shlex.split(clause)
    env = {}
    while tokens and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]):
        name, _, value = tokens[0].partition("=")
        env[name] = value
        tokens.pop(0)
    return env, tokens


def list_selected(runner, args):
    proc = subprocess.run(
        [runner, "--list", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    if proc.returncode != 0:
        fail("{} --list {} failed".format(runner, " ".join(args)))
    return [line for line in proc.stdout.splitlines() if line]


doc = load_yaml(doc_path) or {}
commands = doc.get("commands")
command = commands.get("test") if isinstance(commands, dict) else None
if command is None or command is False or not str(command).strip():
    fail("commands.test must be present: the local no-mistakes gate owns broad deterministic regression")

parsed = [split_clause(clause) for clause in split_clauses(str(command))]
lanes = ["portable-parallel-1", "portable-parallel-2", "portable-serial"]
expected = [["bin/fm-test-run.sh", "--check-coverage"]] + [
    ["bin/fm-test-run.sh", "--lane", lane, "--exclude-family", "live-harness-optin", "--exclude-family", "hc-pinned"]
    for lane in lanes
]
actual = [argv for _env, argv in parsed]
if actual != expected:
    fail("commands.test must run the coverage guard then exactly the three portable lanes in order; got {!r}".format(actual))

for env, argv in parsed:
    if env.get("FM_LIVE") != "0":
        fail("every executing clause must set FM_LIVE=0 so no default-on guard runs: " + " ".join(argv))
    if "--all" in argv:
        fail("commands.test must never select --all: " + " ".join(argv))
    for index in range(len(argv) - 1):
        flag, value = argv[index], argv[index + 1]
        if flag == "--family" and value in ("real-herdr-gated", "live-harness-optin", "hc-pinned"):
            fail("commands.test must never select the {} family: {}".format(value, " ".join(argv)))

runner = os.path.join(root, "bin/fm-test-run.sh")
bad_families = ["live-harness-optin", "real-herdr-gated", "hc-pinned"]
bad_paths = set()
for family in bad_families:
    bad_paths.update(list_selected(runner, ["--family", family]))
selected_all = []

for _env, argv in parsed[1:]:
    lane = argv[argv.index("--lane") + 1]
    selected = list_selected(runner, argv[1:])
    selected_all.extend(selected)
    leaked = [path for path in selected if path in bad_paths]
    if leaked:
        fail("lane {} must not select the live-harness, real-Herdr, or pinned hc families, got: {}".format(lane, ", ".join(leaked)))

hermetic_hc = "tests/fm-backend-hc.test.sh"
if hermetic_hc not in selected_all:
    fail("commands.test must keep the hermetic hc suite gated: {} was not selected".format(hermetic_hc))

witness = "tests/fm-backend-t3code.test.sh"
if witness not in selected_all:
    fail("commands.test must select the default-on guard witness {}".format(witness))

print("commands.test runs the exact portable lane sequence, excludes the live-harness and pinned-hc families while keeping the hermetic hc suite, and disables default-on guards")
PY
  local witness_name=tests/fm-backend-t3code.test.sh witness_out
  # Run the selected suite's own default-on guard; FM_LIVE=0 must short-circuit it.
  witness_out=$(FM_LIVE=0 FM_TEST_ONLY=t3_verify_live_codex_env bash "$ROOT/$witness_name" 2>&1) \
    || fail "$witness_name carries a selected default-on guard that must be inert under FM_LIVE=0"$'\n'"$witness_out"
  case "$witness_out" in
    *"skip: live: disabled by FM_LIVE=0"*) ;;
    *) fail "$witness_name's default-on guard must report the FM_LIVE=0 skip; got: $witness_out" ;;
  esac
  pass "no-mistakes commands.test runs the portable lanes while the selected $witness_name default-on guard skips under FM_LIVE=0"
}

test_nm_commands_test_runs_the_portable_lanes
