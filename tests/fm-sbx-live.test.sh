#!/usr/bin/env bash
# Live guard for the worker sandbox's in-VM no-mistakes pipeline
# (bin/fm-sbx-lib.sh fm_sbx_nm_prepare, bin/fm-nm-run-lib.sh's sandbox seam).
#
# Opt-in: it creates one real microVM, so it runs only with FM_SBX_LIVE=1 and
# an installed `sbx`, `no-mistakes` and `git`. It touches no model: the
# worker CLI inside the VM is a stub and every pipeline step but lint is
# skipped.
#
# What it proves against the real tools:
#   - the host's no-mistakes binary installs into the VM and reports the same
#     version, with the update check off;
#   - fm_sbx_nm_prepare leaves origin/HEAD on the default branch and the
#     clone initialised, so a pipeline run starts from the right base;
#   - a lint command edited on the task branch is ignored (the default
#     branch's config wins), so the worker cannot make its own pipeline run
#     arbitrary commands by editing .no-mistakes.yaml;
#   - the host reads the VM's pipeline through the exec seam, also after the
#     sandbox was stopped and started again;
#   - the sandbox is removed and the global sbx policy is unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_SBX_LIVE sbx no-mistakes git
# shellcheck source=bin/fm-sbx-lib.sh
. "$ROOT/bin/fm-sbx-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$ROOT/bin/fm-nm-run-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-sbx-live)
fm_git_identity fmtest fmtest@example.invalid

NAME=$(fm_sbx_name "$TMP_ROOT" live-guard)
CLONE="$TMP_ROOT/clone"
NMHOME=/home/agent/nm
SBX_BEFORE=$(sbx ls -q 2>/dev/null | sort)
POLICY_BEFORE=$(sbx policy ls 2>&1)

cleanup() {
  fm_sbx_rm "$NAME" >/dev/null 2>&1 || sbx rm --force "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# vm <args...>: run in the clone inside the sandbox, as the pipeline does.
vm() {
  sbx exec -w "$CLONE" -e NM_HOME="$NMHOME" -e NO_MISTAKES_NO_UPDATE_CHECK=1 \
    -e NO_MISTAKES_TELEMETRY=off "$NAME" "$@"
}

test_the_host_binary_installs_with_the_same_version() {
  local nm host_ver vm_ver
  git init -q -b main "$TMP_ROOT/repo"
  echo hi >"$TMP_ROOT/repo/a.txt"
  git -C "$TMP_ROOT/repo" add a.txt
  git -C "$TMP_ROOT/repo" commit -q -m base
  git clone -q --local --no-hardlinks "$TMP_ROOT/repo" "$CLONE"
  git -C "$CLONE" checkout -q -b fm/live
  sbx create --name "$NAME" --pull missing --cpus 2 --memory 2g shell "$CLONE" >/dev/null 2>&1 ||
    fail "the sandbox could not be created"
  nm=$(readlink -f "$(command -v no-mistakes)")
  sbx cp "$nm" "$NAME:/tmp/fm-no-mistakes" >/dev/null 2>&1 || fail "the binary did not copy in"
  sbx exec -u root "$NAME" install -m 755 /tmp/fm-no-mistakes /usr/local/bin/no-mistakes ||
    fail "the binary did not install"
  host_ver=$(fm_sbx_nm_version "$(NO_MISTAKES_NO_UPDATE_CHECK=1 no-mistakes --version 2>&1)")
  vm_ver=$(fm_sbx_nm_version "$(vm no-mistakes --version 2>&1)")
  [ -n "$host_ver" ] || fail "the host version was not read"
  assert_equals "$host_ver" "$vm_ver" "the VM runs the host's no-mistakes version"
  pass "the host no-mistakes binary installs into the VM at the same version"
}

test_prepare_points_origin_head_at_the_default_branch() {
  local head
  # A VM-local bare origin stands in for GitHub: the clone's own origin is the
  # host path, which the VM does not have.
  vm sh -c 'git init -q --bare -b main /home/agent/origin.git &&
    git config user.name t && git config user.email t@t &&
    git push -q /home/agent/origin.git main &&
    git remote set-url origin /home/agent/origin.git' || fail "the VM origin was not set up"
  fm_sbx_nm_prepare "$NAME" "$CLONE" "$NMHOME" || fail "fm_sbx_nm_prepare failed"
  head=$(vm git symbolic-ref refs/remotes/origin/HEAD 2>&1)
  assert_equals "refs/remotes/origin/main" "$head" "origin/HEAD names the default branch"
  pass "prepare leaves origin/HEAD on the default branch and the clone initialised"
}

test_a_branch_edited_lint_command_is_ignored() {
  local out
  vm sh -c 'mkdir -p /home/agent/bin && printf "#!/bin/sh\nexit 0\n" >/home/agent/bin/claude && chmod +x /home/agent/bin/claude'
  vm sh -c 'git checkout -q main &&
    printf "commands:\n  lint: \"true\"\n" >.no-mistakes.yaml &&
    git add -A && git commit -qm cfg && git push -q origin main &&
    git checkout -q fm/live && git rebase -q main &&
    printf "commands:\n  lint: \"touch /tmp/fm-live-canary\"\n" >.no-mistakes.yaml &&
    echo x >b.txt && git add -A && git commit -qm change' || fail "the canary commit was not made"
  out=$(vm env PATH=/home/agent/bin:/usr/local/bin:/usr/bin:/bin no-mistakes axi run --intent canary \
    --skip intent,rebase,review,test,document,push,pr,ci --wait 90s 2>&1)
  if vm test -e /tmp/fm-live-canary; then
    fail "the branch's own lint command ran inside the pipeline: $out"
  fi
  pass "a lint command edited on the task branch is not run by the pipeline"
}

test_the_host_reads_the_pipeline_through_the_seam() {
  local out
  fm_nm_sandbox_bind "$CLONE" "$NAME" "$CLONE" || fail "the sandbox was not bindable"
  out=$(fm_nm_run_bounded "$CLONE" 30 axi status 2>&1)
  assert_contains "$out" "run" "the seam returns the pipeline's status"
  sbx stop "$NAME" >/dev/null 2>&1 || fail "the sandbox did not stop"
  # `sbx exec` starts a stopped sandbox, so the seam answers again afterwards.
  fm_nm_sandbox_bind "$CLONE" "$NAME" "$CLONE" || fail "the stopped sandbox was not bindable"
  out=$(fm_nm_run_bounded "$CLONE" 60 axi status 2>&1)
  assert_contains "$out" "run" "the pipeline state survives a stop"
  pass "the host reads the in-VM pipeline through the exec seam, across a stop"
}

test_nothing_is_left_behind() {
  fm_sbx_rm "$NAME" || fail "the sandbox was not removed"
  assert_equals "$SBX_BEFORE" "$(sbx ls -q 2>/dev/null | sort)" "the sandbox list is as before"
  assert_equals "$POLICY_BEFORE" "$(sbx policy ls 2>&1)" "the global sbx policy is unchanged"
  pass "the sandbox is gone and the global policy is unchanged"
}

test_the_host_binary_installs_with_the_same_version
test_prepare_points_origin_head_at_the_default_branch
test_a_branch_edited_lint_command_is_ignored
test_the_host_reads_the_pipeline_through_the_seam
test_nothing_is_left_behind

echo "# all fm-sbx-live tests passed"
