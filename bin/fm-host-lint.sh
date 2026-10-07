#!/usr/bin/env bash
# fm-host-lint.sh - answer a sandboxed worker's parked lint gate from host-lint
# evidence, in one command.
#
# A sandboxed worker's no-mistakes pipeline cannot run ShellCheck, so it parks at
# the lint step. This script lints the worker's clone on the host with the
# repository's own bin/fm-lint.sh, one `--partition KofN` per partition, runs the
# partitions in parallel, and prints a short verdict: the head linted, the
# partitions run, every finding as file:line, and the exact answer text to send.
# It NEVER answers, approves, fixes, or skips a gate and never calls
# `no-mistakes`; firstmate decides and sends the printed answer itself.
#
# Usage (host, firstmate):
#   fm-host-lint.sh <task-id> [options]
#     --partitions <N>   split the inventory N ways, 2 to 8 (default 8)
#     --parallel <P>     run P partitions at once (default 4)
#     --jobs <1|2>       ShellCheck workers inside each partition (default 1)
#     --patch <file>     lint this exported pipeline-fix patch applied on the head
#     --no-patch         ignore data/<id>/pipeline-fix.patch and lint the head alone
#     --clone <dir>      lint this clone instead of state/<id>.sbx-clone
#     --keep             keep the scratch checkout and logs (path printed)
#
# What is linted: the clone's committed HEAD, exported into a clean scratch
# checkout (uncommitted clone edits are reported, never linted). When the worker
# exported a pipeline-fix patch (below) at data/<id>/pipeline-fix.patch, it is
# applied on top of that HEAD first, so the lint covers the pipeline's own fix
# commit that lives only inside the sandbox gate repo. A patch whose recorded
# base is not the clone's current HEAD is stale and is refused, not guessed at.
# The scratch checkout's own bin/fm-lint.sh is the linter, so the definition
# linted against is the one the change ships with; nothing else is added.
# Per-partition logs land in data/<id>/host-lint/ (or the --keep scratch dir).
#
# Exit status: 0 every partition clean (verdict APPROVE), 1 findings (verdict
# FIX), 3 a partition could not be judged (verdict INCOMPLETE, answer nothing),
# 2 usage or setup error.
#
# Usage (worker, inside its clone, when its pipeline applied a lint fix that only
# the sandbox gate repo holds):
#   fm-host-lint.sh --export-patch <task-id>
# writes data/<id>/pipeline-fix.patch, the `git diff <head> <pipeline-head>` of
# the current run, with a header line recording both commits. It writes nothing
# and says so when the pipeline head equals HEAD or cannot be read. The worker
# runs it once at the lint park, before reporting the gate.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "fm-host-lint.sh: $*" >&2; exit 2; }

valid_id() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

export_patch() {
  local id=$1 head pipe status out
  valid_id "$id" || die "invalid task id"
  head=$(git rev-parse --verify --quiet HEAD) || die "run this inside the worker's clone"
  command -v no-mistakes >/dev/null 2>&1 || die "no-mistakes is not installed"
  status=$(no-mistakes axi status 2>&1) || die "no-mistakes axi status failed: $status"
  pipe=$(printf '%s\n' "$status" | sed -n 's/^[[:space:]]*head\(_sha\)\{0,1\}:[[:space:]]*"\{0,1\}\([0-9a-f]\{40\}\)"\{0,1\}[[:space:]]*$/\2/p' | head -1)
  out=$DATA/$id/pipeline-fix.patch
  if [ -z "$pipe" ]; then
    echo "no pipeline head readable from 'no-mistakes axi status'; nothing exported" >&2
    return 1
  fi
  if [ "$pipe" = "$head" ]; then
    rm -f "$out"
    echo "pipeline head equals HEAD ${head:0:12}; no pipeline fix to export"
    return 0
  fi
  if ! git cat-file -e "$pipe^{commit}" 2>/dev/null; then
    git fetch -q no-mistakes "$pipe" 2>/dev/null || git fetch -q no-mistakes 2>/dev/null || true
    git cat-file -e "$pipe^{commit}" 2>/dev/null || die "pipeline head ${pipe:0:12} is not fetchable from the no-mistakes remote"
  fi
  mkdir -p "$DATA/$id" || die "cannot create $DATA/$id"
  {
    printf '# fm-pipeline-fix base=%s pipeline=%s\n' "$head" "$pipe"
    git diff "$head" "$pipe"
  } > "$out.tmp" || { rm -f "$out.tmp"; die "git diff failed"; }
  mv "$out.tmp" "$out"
  echo "exported pipeline fix ${head:0:12}..${pipe:0:12} to $out"
}

ID=
PARTS=8
PAR=4
JOBS=1
PATCH=
NOPATCH=0
CLONE=
KEEP=0
EXPORT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --export-patch) EXPORT=1 ;;
    --partitions | --parallel | --jobs | --patch | --clone)
      [ "$#" -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --partitions) PARTS=$2 ;;
        --parallel) PAR=$2 ;;
        --jobs) JOBS=$2 ;;
        --patch) PATCH=$2 ;;
        --clone) CLONE=$2 ;;
      esac
      shift
      ;;
    --no-patch) NOPATCH=1 ;;
    --keep) KEEP=1 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) [ -z "$ID" ] || die "one task id only"; ID=$1 ;;
  esac
  shift
done
[ -n "$ID" ] || ID=${FM_TASK_ID:-}
[ -n "$ID" ] || die "a task id is required (see --help)"
valid_id "$ID" || die "invalid task id"
if [ "$EXPORT" -eq 1 ]; then export_patch "$ID"; exit $?; fi

[[ $PARTS =~ ^[2-8]$ ]] || die "--partitions must be 2 to 8"
[[ $PAR =~ ^[1-9][0-9]*$ ]] || die "--parallel must be a positive number"
[[ $JOBS =~ ^[12]$ ]] || die "--jobs must be 1 or 2"
[ "$NOPATCH" -eq 0 ] || [ -z "$PATCH" ] || die "--patch and --no-patch contradict"
[ -n "$CLONE" ] || CLONE=$STATE/$ID.sbx-clone
[ -d "$CLONE" ] || die "no clone at $CLONE (a sandboxed task's clone is state/<id>.sbx-clone; or pass --clone)"
HEAD=$(git -C "$CLONE" rev-parse --verify --quiet HEAD) || die "$CLONE is not a git clone with a HEAD"
if [ -z "$PATCH" ] && [ "$NOPATCH" -eq 0 ] && [ -f "$DATA/$ID/pipeline-fix.patch" ]; then
  PATCH=$DATA/$ID/pipeline-fix.patch
fi
if [ -n "$PATCH" ]; then
  [ -f "$PATCH" ] || die "patch $PATCH not found"
  base=$(sed -n '1s/^# fm-pipeline-fix base=\([0-9a-f]\{40\}\) .*/\1/p' "$PATCH")
  [ -z "$base" ] || [ "$base" = "$HEAD" ] \
    || die "patch is stale: it was exported against ${base:0:12} but the clone HEAD is ${HEAD:0:12}; ask the worker to re-run --export-patch"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-host-lint.XXXXXX") || die "cannot create scratch dir"
[ "$KEEP" -eq 1 ] || trap 'rm -rf "$WORK"' EXIT
SRC=$WORK/src
if ! git clone -q --no-checkout --no-hardlinks "$CLONE" "$SRC" 2>/dev/null \
  || ! git -C "$SRC" checkout -q --detach "$HEAD" 2>/dev/null; then
  die "could not export HEAD ${HEAD:0:12} of $CLONE"
fi
if [ -n "$PATCH" ]; then
  git -C "$SRC" apply --whitespace=nowarn "$PATCH" 2>/dev/null \
    || die "patch $PATCH does not apply on HEAD ${HEAD:0:12}"
fi
[ -x "$SRC/bin/fm-lint.sh" ] || die "the clone has no bin/fm-lint.sh; this helper lints firstmate's own repository"
DIRTY=$(git -C "$CLONE" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

LOGS=$WORK/logs
mkdir -p "$LOGS"
k=1
while [ "$k" -le "$PARTS" ]; do
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$PAR" ]; do sleep 1; done
  (
    cd "$SRC" || exit 99
    FM_LINT_JOBS=$JOBS bin/fm-lint.sh --partition "${k}of${PARTS}" > "$LOGS/$k.log" 2>&1
    echo $? > "$LOGS/$k.rc"
  ) &
  k=$((k + 1))
done
wait

clean=0
bad=0
unjudged=0
findings=
others=
k=1
while [ "$k" -le "$PARTS" ]; do
  rc=$(cat "$LOGS/$k.rc" 2>/dev/null || echo 99)
  f=$(awk '
    /^In .* line [0-9]+:$/ { file = $2; line = $4; sub(/:$/, "", line); next }
    /SC[0-9]+ \((error|warning|info|style)\):/ {
      s = $0; sub(/^[^S]*/, "", s); printf "%s:%s %s\n", file, line, s
    }' "$LOGS/$k.log")
  case "$rc" in
    0) clean=$((clean + 1)) ;;
    1)
      bad=$((bad + 1))
      if [ -n "$f" ]; then findings="$findings$f"$'\n'
      else others="$others  partition ${k}of${PARTS} failed with no ShellCheck finding: $(grep -v '^[[:space:]]*$' "$LOGS/$k.log" | tail -3 | tr '\n' '|')"$'\n'; fi
      ;;
    *) unjudged=$((unjudged + 1)); others="$others  partition ${k}of${PARTS} could not be judged (exit $rc): $(grep -v '^[[:space:]]*$' "$LOGS/$k.log" | tail -2 | tr '\n' '|')"$'\n' ;;
  esac
  k=$((k + 1))
done

if [ "$KEEP" -eq 1 ]; then
  KEPT=$WORK
else
  mkdir -p "$DATA/$ID/host-lint" 2>/dev/null && cp "$LOGS"/* "$DATA/$ID/host-lint/" 2>/dev/null
  KEPT=$DATA/$ID/host-lint
fi

echo "host lint for task $ID (read-only evidence; this command answers no gate and approves nothing - firstmate decides and sends the answer)"
echo "head: $HEAD"
if [ -n "$PATCH" ]; then echo "pipeline-fix patch applied: $PATCH"; else echo "pipeline-fix patch applied: none"; fi
[ "$DIRTY" -eq 0 ] || echo "note: the clone has $DIRTY uncommitted path(s); only the committed head was linted"
echo "partitions: $PARTS run, $clean clean, $bad with findings, $unjudged not judged (logs: $KEPT)"
if [ -n "$findings" ]; then
  echo "findings (file:line code):"
  printf '%s' "$findings" | sed 's/^/  /'
fi
[ -z "$others" ] || { echo "other failures:"; printf '%s' "$others"; }

if [ "$unjudged" -gt 0 ]; then
  echo "verdict: INCOMPLETE - do not answer the gate; inspect the logs and re-run"
  exit 3
elif [ "$bad" -gt 0 ]; then
  echo "verdict: FIX"
  echo "answer to send (fix): host lint at ${HEAD:0:12} found the findings listed above; fix them: $(printf '%s' "$findings" | sed 's/^/  /' | tr '\n' ';' | sed 's/;$//')$( [ -z "$others" ] || printf ' (also: lint failed outside ShellCheck findings, see %s)' "$KEPT")"
  echo "send with: no-mistakes axi respond --action fix --findings <lint finding ids> --instructions \"<the answer above>\""
  exit 1
else
  echo "verdict: APPROVE"
  echo "answer to send (approve): host lint at ${HEAD:0:12} is clean on all $PARTS partitions; approve the lint gate"
  echo "send with: no-mistakes axi respond --action approve"
  exit 0
fi
