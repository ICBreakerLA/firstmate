#!/usr/bin/env bash
# Behavior tests for the sandbox steps of bin/fm-teardown.sh (config/worker-sandbox,
# bin/fm-sbx-lib.sh, bin/fm-sbx-bridge.sh).
#
# A task whose record says sandbox=sbx keeps its work in a standalone clone.
# Teardown must bring that work to the worktree repository BEFORE the landed-work
# test, keep never-discarding unlanded work ahead of every removal, and remove
# the sandbox before the worktree is returned.
# The fake sbx lists the sandbox until `rm`, and logs every call.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BRIDGE="$ROOT/bin/fm-sbx-bridge.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-sandbox)
SBXNAME=fm-sbx-aaaaaaaa-task-x1-0000

# make_case <name> [kind] [sandbox-name]: a project with a pushed task branch, a
# worktree on it, a clone of the worktree, and a fake sbx and treehouse.
make_case() {
  local name=$1 kind=${2:-ship} sbxname=${3:-$SBXNAME} d fake
  d="$TMP_ROOT/$name"
  fake="$d/fakebin"
  mkdir -p "$d/state" "$d/config" "$d/data" "$fake"
  for t in treehouse tmux; do printf '#!/usr/bin/env bash\nexit 0\n' >"$fake/$t"; done
  cat >"$fake/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  cp "$fake/gh-axi" "$fake/gh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fake/no-mistakes"
  cat >"$fake/sbx" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$d/sbx.log"
case "\$1" in
ls) [ -e "$d/sbx.up" ] && echo "$sbxname" ;;
rm) rm -f "$d/sbx.up" ;;
esac
exit 0
SH
  chmod +x "$fake"/*
  : >"$d/sbx.up"
  git init -q --bare "$d/origin.git"
  git -C "$d/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$d/origin.git" "$d/_seed" 2>/dev/null
  git -C "$d/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$d/_seed" push -q origin main
  rm -rf "$d/_seed"
  git clone -q "$d/origin.git" "$d/project"
  git -C "$d/project" remote set-head origin main 2>/dev/null || true
  git -C "$d/project" worktree add -q -b fm/task-x1 "$d/wt" main
  git -C "$d/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "worker change"
  git -C "$d/wt" push -q origin fm/task-x1
  git -C "$d/project" fetch -q origin
  touch "$d/state/.last-watcher-beat"
  fm_write_meta "$d/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$d/wt" \
    "project=$d/project" "kind=$kind" "mode=no-mistakes" "spawn_gen=teardown-test-task-x1" \
    "sandbox=sbx" "sandbox_name=$sbxname"
  "$BRIDGE" clone "$d/wt" "$d/state/task-x1.sbx-clone" || fail "clone"
  mkdir -p "$d/state/task-x1.sbx" "$d/state/task-x1.sbx-relay"
  printf '%s\n' "$d"
}

run_teardown() {
  local d=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$d/state" FM_DATA_OVERRIDE="$d/data" \
    FM_CONFIG_OVERRIDE="$d/config" PATH="$d/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@" >"$d/stdout" 2>"$d/stderr"
}

clone_commit() { # <case> <message>
  printf '%s\n' "$2" >"$1/state/task-x1.sbx-clone/work.txt"
  git -C "$1/state/task-x1.sbx-clone" add work.txt
  git -C "$1/state/task-x1.sbx-clone" -c user.name=T -c user.email=t@t commit -q -m "$2"
}

test_a_landed_sandboxed_ship_is_removed_in_order_and_its_files_go() {
  local d rc
  d=$(make_case landed)
  run_teardown "$d"; rc=$?
  expect_code 0 "$rc" "teardown should succeed: $(cat "$d/stderr")"
  assert_contains "$(cat "$d/sbx.log")" "rm --force $SBXNAME" "the sandbox was removed"
  assert_absent "$d/state/task-x1.sbx-clone" "the clone is removed"
  assert_absent "$d/state/task-x1.sbx" "the channel is removed"
  assert_absent "$d/state/task-x1.sbx-relay" "the relay offsets are removed"
  assert_absent "$d/state/task-x1.meta" "the task record is retired"
  pass "a landed sandboxed ship is torn down and its sandbox files removed"
}

test_clone_commits_are_brought_back_and_unlanded_work_wins() {
  local d rc
  d=$(make_case unlanded)
  clone_commit "$d" "unpushed worker commit"
  run_teardown "$d"; rc=$?
  expect_code 1 "$rc" "unlanded clone work must refuse"
  assert_contains "$(cat "$d/stderr")" REFUSED "the refusal is the landed-work one"
  assert_equals "$(git -C "$d/state/task-x1.sbx-clone" rev-parse HEAD)" "$(git -C "$d/project" rev-parse refs/heads/fm/task-x1)" "the clone's commit reached the worktree repository, so nothing exists only in the VM"
  assert_not_contains "$(cat "$d/sbx.log")" "rm --force" "an unlanded refusal removes nothing"
  assert_present "$d/state/task-x1.sbx-clone" "the clone is kept"
  assert_present "$d/state/task-x1.meta" "the task record is kept"
  pass "clone commits reach the host before the landed test, and unlanded work refuses before any removal"
}

test_uncommitted_clone_work_refuses() {
  local d rc
  d=$(make_case dirty)
  printf 'wip\n' >"$d/state/task-x1.sbx-clone/wip.txt"
  run_teardown "$d"; rc=$?
  expect_code 1 "$rc" "uncommitted work in the clone must refuse"
  assert_contains "$(cat "$d/stderr")" "clone" "the refusal names the clone"
  assert_not_contains "$(cat "$d/sbx.log")" "rm --force" "nothing is removed"
  assert_present "$d/state/task-x1.sbx-clone/wip.txt" "the work is intact"
  pass "uncommitted work in the sandbox clone refuses teardown"
}

test_force_discards_a_dirty_clone() {
  local d rc
  d=$(make_case force)
  printf 'wip\n' >"$d/state/task-x1.sbx-clone/wip.txt"
  run_teardown "$d" --force; rc=$?
  expect_code 0 "$rc" "--force should proceed: $(cat "$d/stderr")"
  assert_contains "$(cat "$d/sbx.log")" "rm --force $SBXNAME" "the sandbox is removed"
  assert_absent "$d/state/task-x1.sbx-clone" "the clone is discarded on explicit force"
  pass "an explicit --force discards a dirty clone"
}

test_a_scout_skips_the_bridge() {
  local d rc
  d=$(make_case scout scout)
  mkdir -p "$d/data/task-x1"
  printf '# report\n' >"$d/data/task-x1/report.md"
  printf "decisions_reviewed=1\n" >>"$d/state/task-x1.meta"
  printf 'wip\n' >"$d/state/task-x1.sbx-clone/wip.txt"
  run_teardown "$d"; rc=$?
  expect_code 0 "$rc" "a scout's scratch clone does not block: $(cat "$d/stderr")"
  assert_contains "$(cat "$d/sbx.log")" "rm --force $SBXNAME" "the scout's sandbox is removed"
  pass "a scout's sandbox is removed without the fetch-back gate"
}

test_a_forged_sandbox_name_is_refused() {
  local d rc
  d=$(make_case forged ship my-precious-sandbox)
  run_teardown "$d"; rc=$?
  expect_code 1 "$rc" "a non-fleet sandbox name must refuse"
  assert_contains "$(cat "$d/stderr")" "not a fleet sandbox name" "the refusal says why"
  assert_not_contains "$(cat "$d/sbx.log" 2>/dev/null)" "rm" "nothing is removed"
  pass "a task record naming a non-fleet sandbox cannot make teardown remove it"
}

test_the_sandbox_is_queried_before_it_is_removed() {
  local d rc
  d=$(make_case order)
  run_teardown "$d"; rc=$?
  expect_code 0 "$rc" "teardown: $(cat "$d/stderr")"
  [ "$(grep -n '^exec ' "$d/sbx.log" | head -1 | cut -d: -f1)" -lt "$(grep -n '^rm ' "$d/sbx.log" | head -1 | cut -d: -f1)" ] \
    || fail "the pipeline run must be queried through the sandbox before it is removed: $(cat "$d/sbx.log")"
  pass "the in-sandbox pipeline is reached before the sandbox is removed"
}

test_a_landed_sandboxed_ship_is_removed_in_order_and_its_files_go
test_clone_commits_are_brought_back_and_unlanded_work_wins
test_uncommitted_clone_work_refuses
test_force_discards_a_dirty_clone
test_a_scout_skips_the_bridge
test_a_forged_sandbox_name_is_refused
test_the_sandbox_is_queried_before_it_is_removed

echo "# all fm-teardown-sandbox tests passed"
