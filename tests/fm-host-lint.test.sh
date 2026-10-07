#!/usr/bin/env bash
# Behavior tests for bin/fm-host-lint.sh (parked-lint-gate evidence) and
# bin/fm-ci-rerun-failed.sh (re-run only the failed jobs of a PR's latest failed
# CI run).
#
# The host-lint cases run the REAL bin/fm-lint.sh, real ShellCheck, and real git
# clones against a tiny fixture repository; only `no-mistakes` (a vendor CLI the
# export path asks for the run's head) and `gh` are stubs, and the stubs return
# the documented JSON/TOON shapes rather than anything derived from source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOST_LINT="$ROOT/bin/fm-host-lint.sh"
RERUN="$ROOT/bin/fm-ci-rerun-failed.sh"
TMP=$(fm_test_tmproot fm-host-lint)
fm_git_identity

have_lint_tools() {
  command -v shellcheck >/dev/null 2>&1 && command -v actionlint >/dev/null 2>&1 \
    && [ "$(shellcheck --version | sed -n 's/^version: //p')" = "$("$ROOT/bin/fm-lint.sh" --required-version)" ]
}

# make_fixture <dir>: a firstmate-shaped repository whose lint inventory is
# small, so every partition runs in about a second, with one clean commit.
make_fixture() {
  local d=$1
  mkdir -p "$d/bin/backends" "$d/tests" "$d/.github/workflows"
  cp "$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-lint-workflows.sh" "$ROOT/bin/fm-timeout-lib.sh" "$d/bin/"
  printf '#!/usr/bin/env bash\necho ok\n' > "$d/bin/ok.sh"
  printf '#!/usr/bin/env bash\necho ok\n' > "$d/bin/backends/b.sh"
  printf '#!/usr/bin/env bash\necho ok\n' > "$d/tests/t.sh"
  printf 'name: ci\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' > "$d/.github/workflows/ci.yml"
  git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" commit -qm init
}

# write_bad_script <path>: a script with one SC2154 finding on line 2.
write_bad_script() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
echo $x
SH
}

# --- fm-host-lint.sh ---------------------------------------------------------

test_help_describes_both_commands() {
  local out
  out=$("$HOST_LINT" --help) || fail "fm-host-lint --help exits 0"
  assert_contains "$out" "NEVER answers" "host-lint help states it never answers a gate"
  assert_contains "$out" "--export-patch" "host-lint help documents the worker export"
  out=$("$RERUN" --help) || fail "fm-ci-rerun-failed --help exits 0"
  assert_contains "$out" "gh run rerun --failed" "rerun help states what it runs"
  pass "both commands are self-describing"
}

run_host_lint() {  # <id> [args...]; env FIX_HOME names the fake home
  FM_HOME=$FIX_HOME "$HOST_LINT" "$@"
}

test_clean_head_yields_approve_text_and_changes_nothing_else() {
  have_lint_tools || { pass "skipped clean-head (pinned ShellCheck/actionlint not installed)"; return; }
  FIX_HOME=$TMP/clean-home
  mkdir -p "$FIX_HOME/state"
  make_fixture "$FIX_HOME/state/t1.sbx-clone"
  local out rc head
  out=$(run_host_lint t1 --partitions 2 --parallel 2 2>&1); rc=$?
  expect_code 0 "$rc" "clean head"
  head=$(git -C "$FIX_HOME/state/t1.sbx-clone" rev-parse HEAD)
  assert_contains "$out" "head: $head" "verdict names the linted head"
  assert_contains "$out" "partitions: 2 run, 2 clean, 0 with findings, 0 not judged" "partition tally"
  assert_contains "$out" "verdict: APPROVE" "clean verdict"
  assert_contains "$out" "answers no gate and approves nothing" "output says the command approves nothing"
  assert_contains "$out" "answer to send (approve):" "approve answer text"
  assert_present "$FIX_HOME/data/t1/host-lint/1.log" "partition logs are kept for evidence"
  pass "a clean head prints the approve answer and the evidence"
}

test_findings_yield_fix_text_with_file_and_line() {
  have_lint_tools || { pass "skipped findings (pinned ShellCheck/actionlint not installed)"; return; }
  FIX_HOME=$TMP/bad-home
  mkdir -p "$FIX_HOME/state"
  local clone=$FIX_HOME/state/t2.sbx-clone out rc
  make_fixture "$clone"
  write_bad_script "$clone/bin/bad.sh"
  git -C "$clone" add -A
  git -C "$clone" commit -qm bad
  out=$(run_host_lint t2 --partitions 2 --parallel 2 2>&1); rc=$?
  expect_code 1 "$rc" "findings"
  assert_contains "$out" "bin/bad.sh:2 SC2154" "finding carries file and line"
  assert_contains "$out" "verdict: FIX" "fix verdict"
  assert_contains "$out" "answer to send (fix):" "fix answer text"
  assert_not_contains "$out" "verdict: APPROVE" "never approves a failing head"
  pass "findings print the fix answer with file:line"
}

test_uncommitted_edits_are_reported_not_linted() {
  have_lint_tools || { pass "skipped uncommitted (pinned ShellCheck/actionlint not installed)"; return; }
  FIX_HOME=$TMP/dirty-home
  mkdir -p "$FIX_HOME/state"
  local clone=$FIX_HOME/state/t3.sbx-clone out rc
  make_fixture "$clone"
  write_bad_script "$clone/bin/bad.sh"
  out=$(run_host_lint t3 --partitions 2 --parallel 2 2>&1); rc=$?
  expect_code 0 "$rc" "uncommitted edit is not part of the head"
  assert_contains "$out" "uncommitted path" "dirty clone is called out"
  pass "uncommitted clone edits are reported but not linted"
}

# fake_no_mistakes <fakebin> <pipeline-head> [<stale-flat-head-sha>]
# Emits the real `axi status` shape: a flat run.head_sha scalar alongside the
# nested branch_sync.pipeline.current_head the pipeline advances to on its own
# fix commits. Defaults the flat field to the same value as the nested one;
# pass a third arg to make the flat field lag behind, as it does whenever the
# pipeline committed a fix round the task worktree never fetched.
fake_no_mistakes() {
  local fakebin=$1 pipe=$2 flat=${3:-$2}
  mkdir -p "$fakebin"
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2" = "axi status" ]; then
  printf 'run:\n  id: "01RUN"\n  branch: fm/x\n  status: running\n  head_sha: "$flat"\n  findings: none\nbranch_sync:\n  state: pipeline_owned\n  pipeline:\n    current_head: "$pipe"\n'
  exit 0
fi
exit 9
SH
  chmod +x "$fakebin/no-mistakes"
}

test_exported_pipeline_patch_is_linted_on_top_of_the_head() {
  have_lint_tools || { pass "skipped patch flow (pinned ShellCheck/actionlint not installed)"; return; }
  FIX_HOME=$TMP/patch-home
  mkdir -p "$FIX_HOME/state"
  local clone=$FIX_HOME/state/t4.sbx-clone gate=$TMP/gate4.git work=$TMP/gatework4 pipe out rc
  make_fixture "$clone"
  git init -q --bare "$gate"
  git -C "$clone" push -q "$gate" HEAD:refs/heads/fm/x
  # The pipeline's fix commit exists only in the gate repo, never in the clone.
  git clone -q -b fm/x "$gate" "$work"
  write_bad_script "$work/bin/fixed-by-pipeline.sh"
  git -C "$work" add -A
  git -C "$work" commit -qm "pipeline fix"
  git -C "$work" push -q origin HEAD:refs/heads/fm/x
  pipe=$(git -C "$work" rev-parse HEAD)
  git -C "$clone" remote add no-mistakes "$gate"
  fake_no_mistakes "$TMP/fakebin4" "$pipe"
  out=$( (cd "$clone" && PATH="$TMP/fakebin4:$PATH" FM_HOME=$FIX_HOME "$HOST_LINT" --export-patch t4) 2>&1) \
    || fail "export-patch should succeed: $out"
  assert_contains "$out" "exported pipeline fix" "export reports what it wrote"
  assert_present "$FIX_HOME/data/t4/pipeline-fix.patch" "patch is written under data/<id>"
  assert_contains "$(head -1 "$FIX_HOME/data/t4/pipeline-fix.patch")" "base=$(git -C "$clone" rev-parse HEAD) pipeline=$pipe" "patch header records both commits"

  out=$(run_host_lint t4 --partitions 2 --parallel 2 2>&1); rc=$?
  expect_code 1 "$rc" "patched lint finds the pipeline's own regression"
  assert_contains "$out" "bin/fixed-by-pipeline.sh:2 SC2154" "finding comes from the exported pipeline-fix commit"
  assert_contains "$out" "pipeline-fix patch applied: $FIX_HOME/data/t4/pipeline-fix.patch" "evidence names the patch"

  out=$(run_host_lint t4 --partitions 2 --parallel 2 --no-patch 2>&1); rc=$?
  expect_code 0 "$rc" "--no-patch lints the head alone"
  assert_contains "$out" "pipeline-fix patch applied: none" "evidence says no patch"

  git -C "$clone" commit -q --allow-empty -m "worker moved"
  out=$(run_host_lint t4 --partitions 2 2>&1); rc=$?
  expect_code 2 "$rc" "stale patch"
  assert_contains "$out" "patch is stale" "a patch exported against another head is refused"
  pass "an exported pipeline-fix patch is linted, and a stale one is refused"
}

test_export_with_nothing_to_export_says_so() {
  FIX_HOME=$TMP/none-home
  mkdir -p "$FIX_HOME/state"
  local clone=$TMP/noneclone out head
  make_fixture "$clone"
  head=$(git -C "$clone" rev-parse HEAD)
  fake_no_mistakes "$TMP/fakebin5" "$head"
  out=$( (cd "$clone" && PATH="$TMP/fakebin5:$PATH" FM_HOME=$FIX_HOME "$HOST_LINT" --export-patch t5) 2>&1) \
    || fail "export-patch with no fix should succeed"
  assert_contains "$out" "no pipeline fix to export" "no-op export is explicit"
  assert_absent "$FIX_HOME/data/t5/pipeline-fix.patch" "no patch is written"
  pass "export reports when the pipeline made no fix"
}

test_export_prefers_pipeline_current_head_over_stale_flat_head_sha() {
  FIX_HOME=$TMP/precedence-home
  mkdir -p "$FIX_HOME/state"
  local clone=$FIX_HOME/state/t6.sbx-clone gate=$TMP/gate6.git work=$TMP/gatework6 pipe head out
  make_fixture "$clone"
  git init -q --bare "$gate"
  git -C "$clone" push -q "$gate" HEAD:refs/heads/fm/x
  # The pipeline's fix commit exists only in the gate repo, never in the clone.
  git clone -q -b fm/x "$gate" "$work"
  write_bad_script "$work/bin/fixed-by-pipeline.sh"
  git -C "$work" add -A
  git -C "$work" commit -qm "pipeline fix"
  git -C "$work" push -q origin HEAD:refs/heads/fm/x
  pipe=$(git -C "$work" rev-parse HEAD)
  head=$(git -C "$clone" rev-parse HEAD)
  git -C "$clone" remote add no-mistakes "$gate"
  # The flat head_sha field lags at the clone's own HEAD (as it can in a
  # parked-lint-gate state); only branch_sync.pipeline.current_head names the
  # pipeline's actual fix commit.
  fake_no_mistakes "$TMP/fakebin6" "$pipe" "$head"
  out=$( (cd "$clone" && PATH="$TMP/fakebin6:$PATH" FM_HOME=$FIX_HOME "$HOST_LINT" --export-patch t6) 2>&1) \
    || fail "export-patch should succeed: $out"
  assert_contains "$out" "exported pipeline fix" "export follows the nested pipeline head, not the stale flat one"
  assert_present "$FIX_HOME/data/t6/pipeline-fix.patch" "patch is written despite a stale flat head_sha"
  pass "export-patch prefers branch_sync.pipeline.current_head over a stale flat head_sha"
}

test_missing_clone_and_bad_options_are_usage_errors() {
  FIX_HOME=$TMP/err-home
  mkdir -p "$FIX_HOME/state"
  local out rc
  out=$(run_host_lint nope 2>&1); rc=$?
  expect_code 2 "$rc" "missing clone"
  assert_contains "$out" "no clone at" "missing clone is named"
  out=$(run_host_lint nope --partitions 9 2>&1); rc=$?
  expect_code 2 "$rc" "partition range"
  out=$("$HOST_LINT" ../evil 2>&1); rc=$?
  expect_code 2 "$rc" "path-shaped task id"
  pass "usage errors exit 2 without linting"
}

# --- fm-ci-rerun-failed.sh ---------------------------------------------------

HEAD_A=$(printf 'a%.0s' $(seq 40))
HEAD_B=$(printf 'b%.0s' $(seq 40))

# fake_gh <dir>: reads RUNS_JSON/PR_STATE/PR_HEAD from the environment and logs
# every rerun it is asked to perform.
fake_gh() {
  mkdir -p "$1"
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    printf '{"state":"%s","headRefOid":"%s","headRefName":"fm/x"}\n' "${PR_STATE:-OPEN}" "$PR_HEAD" ;;
  "run list") printf '%s\n' "$RUNS_JSON" ;;
  "run view") printf '{"jobs":[{"name":"lint (3)","conclusion":"failure"},{"name":"unit","conclusion":"success"}]}\n' ;;
  "run rerun") printf '%s\n' "$*" >> "$RERUN_LOG" ;;
  *) exit 9 ;;
esac
SH
  chmod +x "$1/gh"
}

run_rerun() {  # <runs-json> <pr-head> [args...]
  local runs=$1 head=$2
  shift 2
  RUNS_JSON=$runs PR_HEAD=$head RERUN_LOG=$TMP/rerun.log FM_CI_RERUN_GH=$TMP/ghbin/gh "$RERUN" \
    https://github.com/ICBreakerLA/firstmate/pull/12 "$@" 2>&1
}

run_row() {  # <id> <workflow> <status> <conclusion> <sha> <created>
  printf '{"databaseId":%s,"workflowName":"%s","status":"%s","conclusion":"%s","headSha":"%s","createdAt":"%s","url":"https://github.com/ICBreakerLA/firstmate/actions/runs/%s"}' "$1" "$2" "$3" "$4" "$5" "$6" "$1"
}

test_rerun_only_failed_jobs_of_latest_failed_run() {
  fake_gh "$TMP/ghbin"
  : > "$TMP/rerun.log"
  local old new runs out rc
  old=$(run_row 100 CI completed failure "$HEAD_A" 2026-01-01T00:00:00Z)
  new=$(run_row 101 CI completed failure "$HEAD_A" 2026-01-01T01:00:00Z)
  runs="[$old,$new]"
  out=$(run_rerun "$runs" "$HEAD_A"); rc=$?
  expect_code 0 "$rc" "failed latest run is re-run"
  assert_contains "$out" "re-ran failed jobs of CI run 101: lint (3)" "prints the run and the failed job it re-ran"
  assert_not_contains "$out" "unit" "passed jobs are not listed as re-run"
  assert_equals "run rerun 101 --repo ICBreakerLA/firstmate --failed" "$(cat "$TMP/rerun.log")" "only the latest run was re-run, with --failed"
  : > "$TMP/rerun.log"
  out=$(run_rerun "$runs" "$HEAD_A" --dry-run); rc=$?
  expect_code 0 "$rc" "dry run"
  assert_contains "$out" "would re-run failed jobs of CI run 101" "dry run says what it would do"
  assert_equals "" "$(cat "$TMP/rerun.log")" "dry run re-runs nothing"
  pass "only the failed jobs of the latest failed run are re-run"
}

test_rerun_refuses_unsafe_states() {
  fake_gh "$TMP/ghbin"
  : > "$TMP/rerun.log"
  local out rc
  out=$(run_rerun "[$(run_row 1 CI in_progress "" "$HEAD_A" 2026-01-01T00:00:00Z)]" "$HEAD_A"); rc=$?
  expect_code 1 "$rc" "running"
  assert_contains "$out" "still live" "a running run is refused"
  out=$(run_rerun "[$(run_row 1 CI completed success "$HEAD_A" 2026-01-01T00:00:00Z)]" "$HEAD_A"); rc=$?
  expect_code 1 "$rc" "green"
  assert_contains "$out" "no failed run" "a green run is refused"
  out=$(run_rerun "[$(run_row 1 CI completed cancelled "$HEAD_A" 2026-01-01T00:00:00Z)]" "$HEAD_A"); rc=$?
  expect_code 1 "$rc" "cancelled"
  out=$(run_rerun "[$(run_row 1 CI completed failure "$HEAD_A" 2026-01-01T00:00:00Z)]" "$HEAD_B"); rc=$?
  expect_code 1 "$rc" "head moved"
  assert_contains "$out" "no workflow run exists for the PR head" "a run for an older head is refused"
  out=$(PR_STATE=MERGED run_rerun "[$(run_row 1 CI completed failure "$HEAD_A" 2026-01-01T00:00:00Z)]" "$HEAD_A"); rc=$?
  expect_code 1 "$rc" "merged"
  assert_equals "" "$(cat "$TMP/rerun.log")" "no refusal re-ran anything"
  pass "running, green, cancelled, moved-head, and closed PRs are refused"
}

test_rerun_leaves_other_green_workflows_alone() {
  fake_gh "$TMP/ghbin"
  : > "$TMP/rerun.log"
  local runs out rc
  runs="[$(run_row 7 CI completed failure "$HEAD_A" 2026-01-01T00:00:00Z),$(run_row 8 Docs completed success "$HEAD_A" 2026-01-01T00:05:00Z)]"
  out=$(run_rerun "$runs" "$HEAD_A"); rc=$?
  expect_code 0 "$rc" "one failed workflow among green ones"
  assert_equals "run rerun 7 --repo ICBreakerLA/firstmate --failed" "$(cat "$TMP/rerun.log")" "the green workflow is untouched"
  pass "green workflows are not re-run"
}

test_help_describes_both_commands
test_clean_head_yields_approve_text_and_changes_nothing_else
test_findings_yield_fix_text_with_file_and_line
test_uncommitted_edits_are_reported_not_linted
test_exported_pipeline_patch_is_linted_on_top_of_the_head
test_export_with_nothing_to_export_says_so
test_export_prefers_pipeline_current_head_over_stale_flat_head_sha
test_missing_clone_and_bad_options_are_usage_errors
test_rerun_only_failed_jobs_of_latest_failed_run
test_rerun_refuses_unsafe_states
test_rerun_leaves_other_green_workflows_alone
