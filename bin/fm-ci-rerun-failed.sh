#!/usr/bin/env bash
# fm-ci-rerun-failed.sh - re-run only the failed jobs of a pull request's
# latest failed CI run, then print exactly what was re-run.
#
# Usage:
#   fm-ci-rerun-failed.sh <pr-url>                  e.g. https://github.com/ICBreakerLA/firstmate/pull/12
#   fm-ci-rerun-failed.sh <number> --repo <o/r>     the same PR by number
#   fm-ci-rerun-failed.sh ... --dry-run             print what would be re-run, change nothing
#   fm-ci-rerun-failed.sh --help
#
# For the PR's CURRENT head commit, each workflow's latest run is read through
# `gh`. The request is refused, re-running nothing, when
#   - the PR is not open,
#   - no workflow run exists for the PR's current head (the head moved since the
#     last run, or CI has not started),
#   - any of those latest runs is still queued or in progress (re-running while
#     a sibling run is live races it), or
#   - none of them failed (success, cancelled, skipped, and neutral conclusions
#     are not failures; a cancelled run is deliberately left to a person).
# Otherwise `gh run rerun --failed` is issued once per failed latest run, which
# re-runs that run's failed jobs and the jobs that depend on them, never the
# jobs that already passed. The PR head is read again immediately before each
# re-run and the request is refused if it moved in between.
#
# This is a routine mechanical retry: it reads and re-runs, never merges,
# approves, edits the PR, or answers a pipeline gate. Exit 0 when something was
# re-run (or, under --dry-run, would be), 1 when refused, 2 on a usage or
# tooling error. FM_CI_RERUN_GH overrides the `gh` binary.
set -u

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

GH=${FM_CI_RERUN_GH:-gh}
PR=
REPO=
DRY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --dry-run) DRY=1 ;;
    --repo)
      [ "$#" -ge 2 ] || { echo "error: --repo needs owner/repo" >&2; exit 2; }
      REPO=$2
      shift
      ;;
    -*) echo "error: unknown option $1 (see --help)" >&2; exit 2 ;;
    *)
      [ -z "$PR" ] || { echo "error: one pull request only (see --help)" >&2; exit 2; }
      PR=$1
      ;;
  esac
  shift
done
[ -n "$PR" ] || { echo "error: a pull request URL or number is required (see --help)" >&2; exit 2; }

if [[ $PR =~ ^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+)/?$ ]]; then
  [ -z "$REPO" ] || [ "$REPO" = "${BASH_REMATCH[1]}" ] || { echo "error: --repo $REPO contradicts the pull request URL" >&2; exit 2; }
  REPO=${BASH_REMATCH[1]}
  NUM=${BASH_REMATCH[2]}
elif [[ $PR =~ ^[0-9]+$ ]] && [[ $REPO =~ ^[^/]+/[^/]+$ ]]; then
  NUM=$PR
else
  echo "error: give a https://github.com/<owner>/<repo>/pull/<n> URL, or a number with --repo <owner>/<repo>" >&2
  exit 2
fi
command -v "$GH" >/dev/null 2>&1 || { echo "error: $GH is not installed" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is not installed" >&2; exit 2; }

DONE=0
refuse() { echo "refused: $*" >&2; [ "$DONE" -eq 0 ] && echo "nothing was re-run." >&2 || echo "$DONE run(s) were already re-run." >&2; exit 1; }

pr_json() { "$GH" pr view "$NUM" --repo "$REPO" --json state,headRefOid,headRefName 2>&1; }
read_pr() {
  local out
  out=$(pr_json) || { echo "error: could not read $REPO#$NUM: $out" >&2; exit 2; }
  STATE=$(jq -r '.state' <<<"$out") || exit 2
  HEAD=$(jq -r '.headRefOid' <<<"$out") || exit 2
  BRANCH=$(jq -r '.headRefName' <<<"$out") || exit 2
}
read_pr
[ "$STATE" = OPEN ] || refuse "the pull request is $STATE, not OPEN"
[[ $HEAD =~ ^[0-9a-f]{40}$ ]] || { echo "error: unreadable head commit for $REPO#$NUM" >&2; exit 2; }

runs=$("$GH" run list --repo "$REPO" --branch "$BRANCH" --limit 100 \
  --json databaseId,workflowName,status,conclusion,headSha,createdAt,url 2>&1) \
  || { echo "error: could not list workflow runs: $runs" >&2; exit 2; }
latest=$(jq -c --arg sha "$HEAD" '
  [.[] | select(.headSha == $sha)]
  | group_by(.workflowName)
  | map(sort_by(.createdAt) | last)
  | sort_by(.workflowName)' <<<"$runs") || { echo "error: unreadable run list" >&2; exit 2; }

[ "$(jq 'length' <<<"$latest")" -gt 0 ] \
  || refuse "no workflow run exists for the PR head ${HEAD:0:12}; the head moved since the last run or CI has not started"
live=$(jq -r '.[] | select(.status != "completed") | "\(.workflowName) run \(.databaseId) is \(.status)"' <<<"$latest")
[ -z "$live" ] || refuse "a run for head ${HEAD:0:12} is still live: $(tr '\n' ';' <<<"$live")"
failed=$(jq -c '[.[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure")]' <<<"$latest")
if [ "$(jq 'length' <<<"$failed")" -eq 0 ]; then
  refuse "no failed run for head ${HEAD:0:12} (latest conclusions: $(jq -r 'map("\(.workflowName)=\(.conclusion)") | join(", ")' <<<"$latest"))"
fi

echo "pull request: https://github.com/$REPO/pull/$NUM"
echo "head: $HEAD"
rc=0
while IFS= read -r run; do
  id=$(jq -r '.databaseId' <<<"$run")
  wf=$(jq -r '.workflowName' <<<"$run")
  url=$(jq -r '.url' <<<"$run")
  jobs=$("$GH" run view "$id" --repo "$REPO" --json jobs 2>&1) \
    || { echo "error: could not read jobs of run $id: $jobs" >&2; exit 2; }
  names=$(jq -r '[.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out")] | map(.name) | join(", ")' <<<"$jobs")
  if [ "$DRY" -eq 1 ]; then
    echo "would re-run failed jobs of $wf run $id: ${names:-none listed} ($url)"
    continue
  fi
  read_pr
  [ "$HEAD" = "$(jq -r '.headSha' <<<"$run")" ] || refuse "the PR head moved to ${HEAD:0:12} while re-running; re-check CI for the new head"
  if out=$("$GH" run rerun "$id" --repo "$REPO" --failed 2>&1); then
    DONE=$((DONE + 1))
    echo "re-ran failed jobs of $wf run $id: ${names:-none listed} ($url)"
  else
    echo "error: re-running $wf run $id failed: $out" >&2
    rc=2
  fi
done < <(jq -c '.[]' <<<"$failed")
exit "$rc"
