#!/usr/bin/env bash
# Behavior tests for the sandbox seam in bin/fm-nm-run-lib.sh: a sandboxed
# task's no-mistakes calls run inside its microVM through `sbx exec`, never on
# the host binary or the host sqlite reader, and never wake a stopped VM.
# Fake `sbx` and `no-mistakes` on PATH record their calls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$ROOT/bin/fm-nm-run-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-run-lib-sbx)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CALLS="$TMP_ROOT/calls.log"
SBX_LIVE="$TMP_ROOT/sbx.live"
WT="$TMP_ROOT/wt"
CLONE="$TMP_ROOT/clone"
mkdir -p "$WT" "$CLONE"

cat >"$FAKEBIN/sbx" <<'SH'
#!/usr/bin/env bash
printf 'sbx %s\n' "$*" >>"$CALLS"
case "$1" in
ls) cat "$SBX_LIVE" 2>/dev/null; exit 0 ;;
exec) echo "in-vm output" ;;
esac
SH
cat >"$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'host no-mistakes %s\n' "$*" >>"$CALLS"
echo "host output"
SH
chmod +x "$FAKEBIN/sbx" "$FAKEBIN/no-mistakes"
export CALLS SBX_LIVE
PATH="$FAKEBIN:$PATH"
: >"$CALLS"

test_unbound_worktree_uses_the_host_binary() {
  : >"$CALLS"
  assert_equals "host output" "$(fm_nm_run_bounded "$WT" 5 axi status)" "the host binary answers"
  assert_not_contains "$(cat "$CALLS")" "sbx exec" "no sandbox call is made"
  pass "an unbound worktree keeps using the host no-mistakes"
}

test_bound_worktree_runs_in_the_sandbox() {
  : >"$CALLS"
  printf 'fm-sbx-aaaaaaaa-t1-0000\n' >"$SBX_LIVE"
  fm_nm_sandbox_bind "$WT" fm-sbx-aaaaaaaa-t1-0000 "$CLONE" || fail "a listed sandbox binds live"
  assert_equals "in-vm output" "$(fm_nm_run_bounded "$WT" 5 axi status)" "the VM answers"
  assert_contains "$(cat "$CALLS")" "sbx exec -w $CLONE -e NM_HOME=/home/agent/nm fm-sbx-aaaaaaaa-t1-0000 no-mistakes axi status" "the exec form names the clone, the VM-local home and the sandbox"
  assert_not_contains "$(cat "$CALLS")" "host no-mistakes" "the host binary is never used for a sandboxed task"
  fm_nm_sandbox_unbind
  pass "a bound worktree's call becomes sbx exec in the clone"
}

test_an_absent_sandbox_is_never_exec_d_or_replaced_by_the_host() {
  : >"$CALLS"
  : >"$SBX_LIVE"
  fm_nm_sandbox_bind "$WT" fm-sbx-aaaaaaaa-t1-0000 "$CLONE" && fail "an unlisted sandbox must not bind live"
  fm_nm_run_bounded "$WT" 5 axi status >/dev/null && fail "the call must fail rather than run anywhere"
  assert_not_contains "$(cat "$CALLS")" "sbx exec" "exec would start a stopped VM"
  assert_not_contains "$(cat "$CALLS")" "host no-mistakes" "no fallback to the host binary"
  assert_equals "" "$(fm_nm_run "$WT" 5 axi status)" "the fail-open query reads as empty"
  fm_nm_sandbox_unbind
  pass "a missing sandbox is unavailable, not exec'd and not answered by the host"
}

test_capped_overview_skips_the_host_sqlite_fallback() {
  local overview out
  printf 'fm-sbx-aaaaaaaa-t1-0000\n' >"$SBX_LIVE"
  fm_nm_sandbox_bind "$WT" fm-sbx-aaaaaaaa-t1-0000 "$CLONE"
  overview=$'repo: /somewhere\ncount: 1 of 5 total\nruns[1]{id,branch,status,head,pr}:\n  "r1","fm/t1","running","abcdef1",""'
  out=$(fm_nm_select_run fm/t1 "$overview" "$WT" 5)
  assert_contains "$out" "unknown|sandboxed task" "a capped inventory stays unknown"
  assert_contains "$out" "r1" "the visible run id is kept"
  fm_nm_sandbox_unbind
  out=$(fm_nm_select_run fm/t1 "$overview" "$WT" 5)
  assert_not_contains "$out" "sandboxed task" "an unbound task still takes the ordinary path"
  pass "a sandboxed task never reads the host sqlite inventory"
}

test_unbound_worktree_uses_the_host_binary
test_bound_worktree_runs_in_the_sandbox
test_an_absent_sandbox_is_never_exec_d_or_replaced_by_the_host
test_capped_overview_skips_the_host_sqlite_fallback

echo "# all fm-nm-run-lib-sbx tests passed"
