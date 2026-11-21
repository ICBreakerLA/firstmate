#!/usr/bin/env bash
# Contract: .github/workflows/macos-bash.yml keeps exactly the stock macOS Bash
# job, triggered only by a path-filtered pull request and by hand, so it cannot
# grow into a second full CI and never runs on a push to main.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/macos-bash.yml"

test_macos_workflow_is_only_the_stock_bash_job() {
  assert_present "$WORKFLOW" ".github/workflows/macos-bash.yml is missing"
  command -v python3 >/dev/null 2>&1 \
    || fail "python3 is required to run the macOS workflow contract"
  python3 - "$WORKFLOW" <<'PY' || fail "macOS workflow contract"
import re
import sys


class YamlSubsetError(Exception):
    pass


def fail(message):
    sys.stderr.write(message + "\n")
    sys.exit(1)


# A minimal parser for the block YAML subset this workflow uses: indentation
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


try:
    with open(sys.argv[1]) as handle:
        doc = load_yaml(handle.read())
except YamlSubsetError as exc:
    fail(".github/workflows/macos-bash.yml is not parseable as YAML: " + str(exc))
doc = doc or {}

jobs = doc["jobs"]
if list(jobs.keys()) != ["macos-stock-bash"]:
    fail("the macOS workflow must carry only macos-stock-bash, got " + ", ".join(jobs.keys()))
triggers = doc.get("on") or {}
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
