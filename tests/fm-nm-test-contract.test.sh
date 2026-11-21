#!/usr/bin/env bash
# Contract: .no-mistakes.yaml's commands.test, the local gate's work-in-progress suite (hosted ci.yml owns the broad suite), walks the deterministic portable
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
  python3 - "$NM" "$ROOT" <<'PY' || fail "no-mistakes commands.test contract"
import os
import re
import shlex
import subprocess
import sys

doc_path, root = sys.argv[1], sys.argv[2]


class YamlSubsetError(Exception):
    pass


def fail(message):
    sys.stderr.write(message + "\n")
    sys.exit(1)


# A minimal parser for the block YAML subset .no-mistakes.yaml uses: indentation
# maps and sequences, quoted and plain scalars, and literal block scalars. It
# needs no packages, so the contract runs on a stock python3.
def _strip_comment(raw):
    out = []
    quote = None
    index = 0
    while index < len(raw):
        char = raw[index]
        if quote:
            out.append(char)
            if quote == "'" and char == "'" and index + 1 < len(raw) and raw[index + 1] == "'":
                out.append("'")
                index += 2
                continue
            if char == quote:
                quote = None
        else:
            if char in "'\"":
                quote = char
                out.append(char)
            elif char == "#" and (index == 0 or raw[index - 1] in " \t"):
                break
            else:
                out.append(char)
        index += 1
    return "".join(out).rstrip()


def _indent(raw):
    return len(raw) - len(raw.lstrip(" "))


def _split_key(content):
    quote = None
    index = 0
    while index < len(content):
        char = content[index]
        if quote:
            if quote == "'" and char == "'" and index + 1 < len(content) and content[index + 1] == "'":
                index += 2
                continue
            if char == quote:
                quote = None
        elif char in "'\"":
            quote = char
        elif char == ":" and (index + 1 == len(content) or content[index + 1] in " \t"):
            return content[:index].strip(), content[index + 1:].strip()
        index += 1
    return None, None


def _scalar(text):
    if len(text) >= 2 and text.startswith("'") and text.endswith("'"):
        return text[1:-1].replace("''", "'")
    if len(text) >= 2 and text.startswith('"') and text.endswith('"'):
        return text[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    if text in ("true", "True", "TRUE"):
        return True
    if text in ("false", "False", "FALSE"):
        return False
    if text in ("null", "Null", "NULL", "~"):
        return None
    if re.fullmatch(r"-?[0-9]+", text):
        return int(text)
    return text


def load_yaml(text):
    lines = text.splitlines()
    position = [0]

    def skip_blank():
        while position[0] < len(lines):
            stripped = lines[position[0]].strip()
            if not stripped or stripped.startswith("#") or stripped in ("---", "..."):
                position[0] += 1
            else:
                return

    def block(indent):
        skip_blank()
        if position[0] >= len(lines):
            return None
        content = _strip_comment(lines[position[0]].strip())
        if content == "-" or content.startswith("- "):
            return sequence(indent)
        return mapping(indent)

    def sequence(indent):
        items = []
        while True:
            skip_blank()
            if position[0] >= len(lines):
                break
            raw = lines[position[0]]
            current = _indent(raw)
            if current < indent:
                break
            content = _strip_comment(raw.strip())
            if not (content == "-" or content.startswith("- ")):
                break
            if current > indent:
                raise YamlSubsetError("unexpected indent at line %d" % (position[0] + 1))
            rest = content[1:].strip()
            if rest == "":
                position[0] += 1
                skip_blank()
                if position[0] < len(lines) and _indent(lines[position[0]]) > indent:
                    items.append(block(_indent(lines[position[0]])))
                else:
                    items.append(None)
            elif _split_key(rest)[0] is not None:
                lines[position[0]] = " " * (indent + 2) + rest
                items.append(mapping(indent + 2))
            else:
                position[0] += 1
                items.append(_scalar(rest))
        return items

    def mapping(indent):
        result = {}
        while True:
            skip_blank()
            if position[0] >= len(lines):
                break
            raw = lines[position[0]]
            current = _indent(raw)
            if current < indent:
                break
            if current > indent:
                raise YamlSubsetError("unexpected indent at line %d" % (position[0] + 1))
            key, rest = _split_key(_strip_comment(raw.strip()))
            if key is None:
                raise YamlSubsetError("expected a mapping entry at line %d" % (position[0] + 1))
            position[0] += 1
            if rest in ("|", "|-", "|+", ">", ">-", ">+"):
                result[key] = block_scalar(indent, rest)
            elif rest == "":
                skip_blank()
                if position[0] < len(lines) and _indent(lines[position[0]]) > indent:
                    result[key] = block(_indent(lines[position[0]]))
                else:
                    result[key] = None
            else:
                result[key] = _scalar(rest)
        return result

    def block_scalar(parent_indent, style):
        collected = []
        while position[0] < len(lines):
            raw = lines[position[0]]
            if raw.strip() == "":
                collected.append("")
                position[0] += 1
                continue
            if _indent(raw) <= parent_indent:
                break
            collected.append(raw)
            position[0] += 1
        while collected and collected[-1] == "":
            collected.pop()
        nonblank = [line for line in collected if line.strip()]
        if not nonblank:
            return ""
        cut = min(_indent(line) for line in nonblank)
        dedented = [line[cut:] if line.strip() else "" for line in collected]
        if style.startswith(">"):
            return " ".join(part for part in dedented if part)
        return "\n".join(dedented)

    skip_blank()
    if position[0] >= len(lines):
        return None
    document = block(_indent(lines[position[0]]))
    skip_blank()
    if position[0] < len(lines):
        raise YamlSubsetError("unexpected content at line %d" % (position[0] + 1))
    return document


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


try:
    with open(doc_path) as handle:
        doc = load_yaml(handle.read())
except YamlSubsetError as exc:
    fail(".no-mistakes.yaml is not parseable as YAML: " + str(exc))
doc = doc or {}
commands = doc.get("commands")
command = commands.get("test") if isinstance(commands, dict) else None
if command is None or command is False or not str(command).strip():
    fail("commands.test must be present: the local no-mistakes gate keeps its work-in-progress portable suite")

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
