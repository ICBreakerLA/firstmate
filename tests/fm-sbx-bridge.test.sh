#!/usr/bin/env bash
# Behavior tests for bin/fm-sbx-bridge.sh: the standalone clone a sandboxed
# worker gets, and the fast-forward-only fetch-back of its commits.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/bin/fm-sbx-bridge.sh"
TMP_ROOT=$(fm_test_tmproot fm-sbx-bridge)
fm_git_identity 'Captain Tests' 'captain@example.invalid'

new_world() { # <name> -> sets REPO WT CLONE
  local d="$TMP_ROOT/$1"
  REPO="$d/repo"
  WT="$d/wt"
  CLONE="$d/clone"
  fm_git_worktree "$REPO" "$WT" base-branch
  git -C "$REPO" remote set-url origin 'https://user:secret-token@example.invalid/org/repo.git'
  git -C "$REPO" config user.name "Captain Tests"
  git -C "$REPO" config user.email "captain@example.invalid"
}

commit_in() { # <dir> <file> <msg>
  printf '%s\n' "$3" >>"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -qm "$3"
}

test_clone_is_standalone_and_has_no_host_credentials() {
  local url
  new_world standalone
  "$BRIDGE" clone "$WT" "$CLONE" || fail "clone should succeed"
  [ -d "$CLONE/.git" ] || fail "the clone must own a real .git directory"
  [ ! -e "$CLONE/.git/objects/info/alternates" ] || fail "the clone must not borrow objects from the host"
  url=$(git -C "$CLONE" remote get-url origin)
  assert_equals "https://example.invalid/org/repo.git" "$url" "origin is the real remote with credentials stripped"
  assert_not_contains "$(cat "$CLONE/.git/config")" "secret-token" "no credential is copied into the clone"
  assert_not_contains "$(cat "$CLONE/.git/config")" "$WT" "the clone does not point back at the host worktree"
  assert_equals "Captain Tests" "$(git -C "$CLONE" config user.name)" "commit identity is carried over"
  pass "the clone is standalone, points at the real remote, and carries no credential"
}

test_clone_without_a_remote_has_no_origin() {
  new_world noremote
  git -C "$REPO" remote remove origin
  "$BRIDGE" clone "$WT" "$CLONE" || fail "clone should succeed without a remote"
  [ -z "$(git -C "$CLONE" remote)" ] || fail "no origin may point back at the host worktree"
  pass "a repository with no remote yields a clone with no origin"
}

test_clone_is_idempotent_for_a_relaunch() {
  new_world idem
  "$BRIDGE" clone "$WT" "$CLONE" || fail "first clone"
  commit_in "$CLONE" README.md "worker commit"
  "$BRIDGE" clone "$WT" "$CLONE" || fail "second clone should reuse"
  assert_contains "$(git -C "$CLONE" log --format=%s -1)" "worker commit" "the existing clone and its work survive"
  pass "an existing clone is reused untouched"
}

test_fetch_back_fast_forwards_the_host_branch() {
  new_world ff
  "$BRIDGE" clone "$WT" "$CLONE" || fail "clone"
  git -C "$CLONE" checkout -q -b fm/task
  commit_in "$CLONE" README.md "feature one"
  "$BRIDGE" fetch-back "$WT" "$CLONE" || fail "fetch-back should succeed"
  assert_equals "$(git -C "$CLONE" rev-parse HEAD)" "$(git -C "$REPO" rev-parse refs/heads/fm/task)" "the host repository holds the branch"
  assert_equals fm/task "$(git -C "$WT" symbolic-ref --short HEAD)" "the worktree follows the clone's branch"
  commit_in "$CLONE" README.md "feature two"
  "$BRIDGE" fetch-back "$WT" "$CLONE" || fail "second fetch-back should fast-forward"
  assert_equals "$(git -C "$CLONE" rev-parse HEAD)" "$(git -C "$WT" rev-parse HEAD)" "the checked-out worktree branch fast-forwards"
  assert_contains "$(cat "$WT/README.md")" "feature two" "the worktree files advance with the branch"
  pass "fetch-back creates the branch, follows it, and fast-forwards later commits"
}

test_fetch_back_refuses_a_diverged_branch() {
  local before
  new_world diverge
  "$BRIDGE" clone "$WT" "$CLONE" || fail "clone"
  git -C "$CLONE" checkout -q -b fm/task
  commit_in "$CLONE" README.md "clone side"
  "$BRIDGE" fetch-back "$WT" "$CLONE" || fail "first bridge"
  git -C "$CLONE" reset -q --hard HEAD~1
  commit_in "$CLONE" README.md "rewritten side"
  before=$(git -C "$REPO" rev-parse refs/heads/fm/task)
  "$BRIDGE" fetch-back "$WT" "$CLONE" 2>"$TMP_ROOT/err" && fail "a diverged branch must be refused"
  assert_contains "$(cat "$TMP_ROOT/err")" "diverged" "the refusal names the divergence"
  assert_equals "$before" "$(git -C "$REPO" rev-parse refs/heads/fm/task)" "the host branch is not rewritten"
  pass "a diverged branch is refused and the host branch is left alone"
}

test_fetch_back_refuses_over_a_dirty_worktree() {
  new_world dirty
  "$BRIDGE" clone "$WT" "$CLONE" || fail "clone"
  git -C "$CLONE" checkout -q -b fm/task
  commit_in "$CLONE" README.md "work"
  printf 'host edit\n' >>"$WT/README.md"
  "$BRIDGE" fetch-back "$WT" "$CLONE" 2>"$TMP_ROOT/err" && fail "a dirty worktree must be refused"
  assert_contains "$(cat "$TMP_ROOT/err")" "uncommitted" "the refusal names the dirty worktree"
  git -C "$REPO" rev-parse -q --verify refs/heads/fm/task >/dev/null && fail "no branch may be created while refusing"
  pass "fetch-back never writes over a dirty worktree"
}

test_a_hostile_clone_cannot_run_code_or_move_other_refs() {
  new_world hostile
  "$BRIDGE" clone "$WT" "$CLONE" || fail "clone"
  git -C "$CLONE" checkout -q -b fm/task
  commit_in "$CLONE" README.md "work"
  printf '* filter=evil\n' >"$CLONE/.gitattributes"
  git -C "$CLONE" add .gitattributes
  git -C "$CLONE" commit -qm attrs
  git -C "$CLONE" config core.fsmonitor "touch $TMP_ROOT/pwned"
  git -C "$CLONE" config uploadpack.packObjectsHook "touch $TMP_ROOT/pwned"
  git -C "$CLONE" config alias.fetch "!touch $TMP_ROOT/pwned"
  mkdir -p "$CLONE/.git/hooks"
  printf '#!/bin/sh\ntouch %s\n' "$TMP_ROOT/pwned" >"$CLONE/.git/hooks/post-commit"
  chmod +x "$CLONE/.git/hooks/post-commit"
  git -C "$CLONE" config filter.evil.clean "touch $TMP_ROOT/pwned; cat"
  printf 'dirty\n' >>"$CLONE/README.md"
  "$BRIDGE" fetch-back "$WT" "$CLONE" || fail "fetch-back should still succeed"
  "$BRIDGE" check "$WT" "$CLONE" 2>/dev/null || true
  [ ! -e "$TMP_ROOT/pwned" ] || fail "configuration or hooks inside the clone ran on the host"
  assert_equals "$(git -C "$REPO" rev-parse main)" "$(git -C "$REPO" rev-parse refs/heads/main)" "other refs are untouched"
  pass "clone-side config and hooks never execute during the bridge"
}

test_a_clone_whose_git_dir_is_redirected_is_refused() {
  new_world redirect
  "$BRIDGE" clone "$WT" "$CLONE" || fail "clone"
  mv "$CLONE/.git" "$TMP_ROOT/elsewhere.git"
  ln -s "$TMP_ROOT/elsewhere.git" "$CLONE/.git"
  "$BRIDGE" check "$WT" "$CLONE" 2>/dev/null && fail "a symlinked .git must be refused"
  "$BRIDGE" fetch-back "$WT" "$CLONE" 2>/dev/null && fail "a symlinked .git must be refused for fetch-back"
  pass "a clone whose .git was redirected is refused"
}

test_check_reports_unbridged_and_dirty_clone_work() {
  local err
  new_world check
  "$BRIDGE" clone "$WT" "$CLONE" || fail "clone"
  "$BRIDGE" check "$WT" "$CLONE" || fail "a pristine clone passes"
  git -C "$CLONE" checkout -q -b fm/task
  commit_in "$CLONE" README.md "unbridged"
  err=$("$BRIDGE" check "$WT" "$CLONE" 2>&1) && fail "an unbridged branch must fail the check"
  assert_contains "$err" "not yet brought back" "the unbridged branch is named"
  "$BRIDGE" fetch-back "$WT" "$CLONE" || fail "bridge"
  "$BRIDGE" check "$WT" "$CLONE" || fail "a bridged clone passes"
  printf 'x\n' >"$CLONE/untracked.txt"
  err=$("$BRIDGE" check "$WT" "$CLONE" 2>&1) && fail "uncommitted clone work must fail the check"
  assert_contains "$err" "uncommitted" "the dirty clone is named"
  pass "check fails on unbridged commits and on uncommitted clone work"
}

test_exclude_hides_the_channel_hooks_file() {
  new_world exclude
  "$BRIDGE" clone "$WT" "$CLONE" || fail "clone"
  "$BRIDGE" exclude "$CLONE" .claude/settings.local.json
  "$BRIDGE" exclude "$CLONE" .claude/settings.local.json
  mkdir -p "$CLONE/.claude"
  printf '{}\n' >"$CLONE/.claude/settings.local.json"
  [ -z "$(git -C "$CLONE" status --porcelain)" ] || fail "the excluded file must not dirty the clone"
  assert_equals 1 "$(grep -c settings.local.json "$CLONE/.git/info/exclude")" "the exclude is written once"
  pass "an excluded path stays out of the clone's status exactly once"
}

test_clone_is_standalone_and_has_no_host_credentials
test_clone_without_a_remote_has_no_origin
test_clone_is_idempotent_for_a_relaunch
test_fetch_back_fast_forwards_the_host_branch
test_fetch_back_refuses_a_diverged_branch
test_fetch_back_refuses_over_a_dirty_worktree
test_a_hostile_clone_cannot_run_code_or_move_other_refs
test_a_clone_whose_git_dir_is_redirected_is_refused
test_check_reports_unbridged_and_dirty_clone_work
test_exclude_hides_the_channel_hooks_file

echo "# all fm-sbx-bridge tests passed"
