#!/usr/bin/env bash
# Behavior tests for the opt-in worker sandbox in fm-spawn.sh
# (config/worker-sandbox, bin/fm-sbx-lib.sh).
#
# Each case drives the real fm-spawn.sh through the shared fake tmux, which
# records the launch command, with a fake sbx on PATH. Nothing here starts a
# microVM; tests/fm-sbx-live.test.sh owns the live guard.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-sandbox)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
fm_git_identity 'Captain Tests' 'captain@example.invalid'

# new_case <name> <sandbox-config|-> [sbx-daemon: up|down|none]
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  : >"$CASE/launch.log"
  [ "$2" = - ] || printf '%s\n' "$2" >"$HOME_DIR/config/worker-sandbox"
  local daemon=${3:-up}
  case "$daemon" in
  none) ;;
  *)
    cat >"$FAKEBIN/sbx" <<SH
#!/usr/bin/env bash
case "\$1" in
daemon) [ "$daemon" = down ] && { echo "Status: stopped"; exit 1; }; echo "Status: running" ;;
esac
exit 0
SH
    chmod +x "$FAKEBIN/sbx"
    ;;
  esac
}

# spawn_task <id> [fm-spawn args...]
spawn_task() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

assert_refused_cleanly() { # <id> <out> <needle>
  assert_contains "$2" "$3" "the refusal should say: $3"
  assert_absent "$HOME_DIR/state/$1.meta" "a refused spawn must not publish a task record"
  assert_absent "$HOME_DIR/state/$1.sbx-clone" "a refused spawn must not leave a clone"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
}

test_absent_config_keeps_the_launch_unchanged() {
  local out rc
  new_case off -  none
  out=$(spawn_task sbx-off); rc=$?
  expect_code 0 "$rc" "an unconfigured spawn should succeed: $out"
  assert_no_grep "claude-sbx" "$CASE/launch.log" "the launch stays a bare claude"
  assert_no_grep "sandbox=" "$HOME_DIR/state/sbx-off.meta" "the task record carries no sandbox"
  assert_absent "$HOME_DIR/state/sbx-off.sbx" "no channel is created"
  pass "worker-sandbox absent leaves spawn exactly as before"
}

test_explicit_off_is_the_same_as_absent() {
  local out rc
  new_case explicit-off off none
  out=$(spawn_task sbx-eoff); rc=$?
  expect_code 0 "$rc" "off should spawn: $out"
  assert_no_grep "claude-sbx" "$CASE/launch.log" "off launches bare claude"
  pass "worker-sandbox off launches bare claude"
}

test_sbx_rewrites_the_launch_and_records_the_sandbox() {
  local out rc
  new_case on 'sbx cpus=2 memory=3g allow=example.org nm=v1.79.0'
  out=$(spawn_task sbx-on); rc=$?
  expect_code 0 "$rc" "sbx should spawn: $out"
  assert_grep "bin/claude-sbx" "$CASE/launch.log" "the launch goes through the wrapper"
  assert_grep "--nm" "$CASE/launch.log" "a no-mistakes ship asks for the in-VM pipeline"
  assert_grep "--cpus 2 --memory 3g" "$CASE/launch.log" "the resources reach the wrapper"
  assert_grep "--allow 'example.org'" "$CASE/launch.log" "the extra host reaches the wrapper"
  assert_grep "--nm-pin 'v1.79.0'" "$CASE/launch.log" "the version pin reaches the wrapper"
  assert_grep "sandbox=sbx" "$HOME_DIR/state/sbx-on.meta" "the task record names the sandbox"
  assert_grep "sandbox_name=fm-sbx-" "$HOME_DIR/state/sbx-on.meta" "the task record names the sandbox instance"
  assert_present "$HOME_DIR/state/sbx-on.sbx-clone/.git" "the standalone clone exists"
  assert_present "$HOME_DIR/state/sbx-on.sbx" "the channel exists"
  assert_present "$HOME_DIR/state/sbx-on.sbx-clone/.claude/settings.local.json" "the clone carries the channel hooks"
  assert_contains "$(cat "$HOME_DIR/state/sbx-on.sbx-clone/.claude/settings.local.json")" "sbx-on.sbx/events" "hooks write the channel"
  pass "sbx launches through the wrapper with a clone, a channel, and a sandbox record"
}

test_a_scout_is_sandboxed_without_the_pipeline() {
  local out rc
  new_case scout sbx
  fm_test_spawn_brief "$HOME_DIR" sbx-scout
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" sbx-scout "$PROJ" --scout); rc=$?
  expect_code 0 "$rc" "a scout should spawn: $out"
  assert_grep "--kind scout" "$CASE/launch.log" "a scout is told it is one"
  assert_no_grep "--nm" "$CASE/launch.log" "a scout has no pipeline"
  pass "a scout runs sandboxed without fetch-back or the pipeline"
}

test_unsupported_launches_refuse_before_any_side_effect() {
  local out rc
  new_case refuse sbx
  out=$(spawn_task sbx-codex --harness codex); rc=$?
  expect_code 1 "$rc" "a non-claude harness must refuse"
  assert_refused_cleanly sbx-codex "$out" "supports only the claude harness"
  out=$(spawn_task sbx-raw --harness "claude --print raw"); rc=$?
  expect_code 1 "$rc" "a raw launch must refuse"
  assert_refused_cleanly sbx-raw "$out" "not a raw command"
  mkdir -p "$CASE/acct"
  printf '{}\n' >"$CASE/acct/.credentials.json"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKEBIN/claude"
  chmod +x "$FAKEBIN/claude"
  printf '%s\n' "$CASE/acct" >"$HOME_DIR/config/claude-account"
  out=$(spawn_task sbx-acct); rc=$?
  expect_code 1 "$rc" "an account pin must refuse"
  assert_refused_cleanly sbx-acct "$out" "worker account pin"
  pass "a harness, a raw command, or an account pin refuses under sbx"
}

test_a_missing_or_stopped_daemon_refuses() {
  local out rc
  new_case down sbx down
  out=$(spawn_task sbx-down); rc=$?
  expect_code 1 "$rc" "a stopped daemon must refuse"
  assert_refused_cleanly sbx-down "$out" "daemon is not running"
  pass "a stopped daemon refuses before anything is created (a missing sbx is covered by tests/fm-sbx-lib.test.sh)"
}

test_malformed_config_refuses() {
  local out rc
  new_case bad 'sbx cpus=99999'
  out=$(spawn_task sbx-bad); rc=$?
  expect_code 1 "$rc" "a malformed config must refuse"
  assert_refused_cleanly sbx-bad "$out" "worker-sandbox"
  pass "a malformed worker-sandbox refuses"
}

# local_server <up|down>: a host curl standing in for llama-server, and a lock
# file private to the case.
local_server() {
  cat >"$FAKEBIN/curl" <<SH
#!/usr/bin/env bash
[ "$1" = up ] || exit 7
echo '{"data":[{"id":"qwen3.8-27b-gsq-rco"}]}'
SH
  chmod +x "$FAKEBIN/curl"
  export FM_LOCAL_LLM_LOCK="$CASE/llm.lock"
}

# release_slot: what the task wrapper's exit does to the spawn's claim.
release_slot() {
  exec 6<>"$FM_LOCAL_LLM_LOCK.handoff"
  exec 6>&-
}

# slot_free: 0 once nothing holds the local slot (a released holder may take a
# moment to exit).
slot_free() {
  local _
  for _ in $(seq 1 50); do
    flock -n "$FM_LOCAL_LLM_LOCK" true 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

test_the_local_model_profile_launches_through_the_wrapper() {
  local out rc
  new_case llm 'sbx'
  local_server up
  out=$(spawn_task sbx-llm --model qwen3.8-27b-gsq-rco --effort high); rc=$?
  expect_code 0 "$rc" "the local profile should spawn: $out"
  assert_grep "bin/claude-sbx" "$CASE/launch.log" "the launch goes through the wrapper"
  assert_grep "--local-llm" "$CASE/launch.log" "the wrapper is asked for the local profile"
  assert_grep "--model 'qwen3.8-27b-gsq-rco'" "$CASE/launch.log" "the local model is the worker's model"
  assert_no_grep "--effort" "$CASE/launch.log" "the local server fixes its own effort"
  assert_grep "sandbox=sbx" "$HOME_DIR/state/sbx-llm.meta" "the task is a sandboxed task"
  assert_equals "sbx-llm" "$(head -n 1 "$FM_LOCAL_LLM_LOCK")" "the claim names the spawned task"
  ! flock -n "$FM_LOCAL_LLM_LOCK" true || fail "the claim must outlive the spawn for its wrapper to take over"
  release_slot
  slot_free || fail "the claim must end once its wrapper is gone"
  pass "the local-model profile claims the slot and launches the sandboxed wrapper with the local model and no effort flag"
}

test_an_ordinary_sandboxed_spawn_is_not_the_local_profile() {
  local out rc
  new_case llm-not sbx
  local_server down
  out=$(spawn_task sbx-plain --model claude-fable-5-1 --effort high); rc=$?
  expect_code 0 "$rc" "an ordinary model must not need the local server: $out"
  assert_grep "--effort" "$CASE/launch.log" "an ordinary model keeps its effort flag"
  assert_no_grep "--local-llm" "$CASE/launch.log" "no local flag for another model"
  pass "a non-local model neither needs the server nor gets the local flag"
}

test_the_local_profile_refuses_before_any_side_effect() {
  local out rc
  new_case llm-refuse sbx
  local_server down
  out=$(spawn_task llm-down --model qwen3.8-27b-gsq-rco); rc=$?
  expect_code 1 "$rc" "a silent server must refuse"
  assert_refused_cleanly llm-down "$out" "local model server is not answering"
  local_server up
  exec 7>"$CASE/llm.lock"
  flock -n 7 || fail "test could not take the lock"
  out=$(spawn_task llm-busy --model qwen3.8-27b-gsq-rco); rc=$?
  exec 7>&-
  expect_code 1 "$rc" "a running local worker must refuse a second"
  assert_refused_cleanly llm-busy "$out" "only one local-model worker runs at a time"
  out=$(spawn_task llm-codex --model qwen3.8-27b-gsq-rco --harness codex); rc=$?
  expect_code 1 "$rc" "another harness must refuse"
  assert_refused_cleanly llm-codex "$out" "supports only the claude harness"
  pass "a silent server, a busy server slot, or another harness refuses before anything is created"
}

# Two spawns close together: the first holds the slot until its wrapper takes
# it over, so the second is refused at spawn and leaves nothing behind.
test_a_second_close_local_spawn_leaves_no_worktree_or_record() {
  local out rc
  new_case llm-race sbx
  local_server up
  out=$(spawn_task llm-a --model qwen3.8-27b-gsq-rco); rc=$?
  expect_code 0 "$rc" "the first local spawn should succeed: $out"
  git -C "$PROJ" worktree add --quiet -b wt-llm-b "$CASE/wt-b"
  fm_test_spawn_brief "$HOME_DIR" llm-b
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch-b.log" fm_test_run_spawn "$HOME_DIR" "$CASE/wt-b" "$FAKEBIN" llm-b "$PROJ" \
    --mode no-mistakes --yolo off --model qwen3.8-27b-gsq-rco 2>&1); rc=$?
  expect_code 1 "$rc" "the second local spawn must refuse: $out"
  assert_contains "$out" "only one local-model worker runs at a time" "the refusal names the rule"
  assert_absent "$HOME_DIR/state/llm-b.meta" "the refused spawn leaves no task record"
  assert_absent "$HOME_DIR/state/llm-b.sbx-clone" "the refused spawn leaves no clone"
  [ ! -s "$CASE/launch-b.log" ] || fail "the refused spawn must not launch a worker: $(cat "$CASE/launch-b.log")"
  assert_equals "llm-a" "$(head -n 1 "$FM_LOCAL_LLM_LOCK")" "the first task keeps the claim"
  release_slot
  slot_free || fail "the first claim must end once its wrapper is gone"
  pass "a second close-together local spawn is refused at spawn and leaves no worktree, clone or record"
}

test_a_failed_local_spawn_releases_the_slot() {
  local out rc
  new_case llm-fail sbx
  local_server up
  printf 'not a clone\n' >"$HOME_DIR/state/llm-fail.sbx-clone"
  out=$(spawn_task llm-fail --model qwen3.8-27b-gsq-rco 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn whose clone cannot be made must fail: $out"
  assert_absent "$HOME_DIR/state/llm-fail.meta" "the failed spawn leaves no task record"
  slot_free || fail "a failed spawn must release its claim"
  pass "a local spawn that fails before its launch releases the slot"
}

test_the_local_profile_needs_the_sandbox() {
  local out rc
  new_case llm-bare - none
  local_server up
  out=$(spawn_task llm-nosbx --model qwen3.8-27b-gsq-rco); rc=$?
  expect_code 1 "$rc" "no sandbox must refuse"
  assert_refused_cleanly llm-nosbx "$out" "runs only inside the worker sandbox"
  pass "the local profile refuses to run outside the sandbox"
}

test_absent_config_keeps_the_launch_unchanged
test_explicit_off_is_the_same_as_absent
test_sbx_rewrites_the_launch_and_records_the_sandbox
test_a_scout_is_sandboxed_without_the_pipeline
test_unsupported_launches_refuse_before_any_side_effect
test_a_missing_or_stopped_daemon_refuses
test_malformed_config_refuses
test_the_local_model_profile_launches_through_the_wrapper
test_an_ordinary_sandboxed_spawn_is_not_the_local_profile
test_the_local_profile_refuses_before_any_side_effect
test_the_local_profile_needs_the_sandbox
test_a_second_close_local_spawn_leaves_no_worktree_or_record
test_a_failed_local_spawn_releases_the_slot

echo "# all fm-spawn-sandbox tests passed"
