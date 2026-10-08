#!/usr/bin/env bash
# Behavior tests for bin/fm-local-llm-lib.sh: the profile selector, the server
# health check, the worker environment, and the host-wide one-at-a-time lock.
# A fake curl stands in for the server; tests/fm-local-llm-live.test.sh owns
# the live guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-local-llm-lib.sh
. "$ROOT/bin/fm-local-llm-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-local-llm-lib)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
export FM_LOCAL_LLM_LOCK="$TMP_ROOT/lock/local-llm.lock"
export FM_LOCAL_LLM_URL=http://127.0.0.1:18080
PATH="$FAKEBIN:$PATH"

# A fake curl: a file holds the models answer, and its absence is a refused
# connection.
cat >"$FAKEBIN/curl" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$TMP_ROOT/curl.log"
[ -f "$TMP_ROOT/models.json" ] || exit 7
cat "$TMP_ROOT/models.json"
SH
chmod +x "$FAKEBIN/curl"

test_the_model_id_alone_selects_the_profile() {
  fm_local_llm_is_model qwen3.8-27b-gsq-rco || fail "the local model id selects the profile"
  ! fm_local_llm_is_model claude-fable-5-1 || fail "a Claude model is not the profile"
  ! fm_local_llm_is_model '' || fail "an empty model is not the profile"
  ! fm_local_llm_is_model default || fail "the default model is not the profile"
  pass "only the local model id selects the profile"
}

test_health_refuses_when_the_server_is_not_answering() {
  local out
  rm -f "$TMP_ROOT/models.json"
  out=$(fm_local_llm_health 2>&1) && fail "a silent server must refuse"
  assert_contains "$out" "not answering at http://127.0.0.1:18080/v1/models" "the refusal names the address"
  assert_contains "$out" "local-llm up" "the refusal says how to start it"
  pass "a server that is not answering refuses with a clear message"
}

test_health_refuses_a_server_without_the_model() {
  local out
  printf '{"data":[{"id":"some-other-model"}]}\n' >"$TMP_ROOT/models.json"
  out=$(fm_local_llm_health 2>&1) && fail "a server without the model must refuse"
  assert_contains "$out" "does not list the model qwen3.8-27b-gsq-rco" "the refusal names the missing model"
  pass "a server that lacks the model refuses"
}

test_health_accepts_a_server_listing_the_model() {
  printf '{"data":[{"id":"qwen3.8-27b-gsq-rco"}]}\n' >"$TMP_ROOT/models.json"
  fm_local_llm_health || fail "a healthy server must pass"
  assert_contains "$(cat "$TMP_ROOT/curl.log")" "http://127.0.0.1:18080/v1/models" "the models route is checked"
  pass "a server listing the model passes"
}

test_env_maps_every_tier_and_carries_no_host_secret() {
  local env k
  env=$(ANTHROPIC_API_KEY=host-key CLAUDE_CODE_OAUTH_TOKEN=host-oauth GH_TOKEN=host-gh fm_local_llm_env)
  for k in ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
    ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL; do
    assert_contains "$env" "$k=qwen3.8-27b-gsq-rco" "$k maps to the local model"
  done
  assert_contains "$env" "ANTHROPIC_BASE_URL=http://host.docker.internal:8080" "the base URL is the host alias"
  assert_contains "$env" "ANTHROPIC_AUTH_TOKEN=local-llm-no-credential" "the token is a placeholder"
  assert_contains "$env" "CLAUDE_CODE_AUTO_COMPACT_WINDOW=88000" "auto-compact sits under the 96,256 context"
  assert_contains "$env" "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" "nonessential traffic is off"
  assert_not_contains "$env" "host-key" "a host API key is never in the environment"
  assert_not_contains "$env" "host-oauth" "a host login token is never in the environment"
  assert_not_contains "$env" "host-gh" "a host GitHub token is never in the environment"
  assert_not_contains "$env" "ANTHROPIC_API_KEY" "no API key variable is set"
  pass "the environment maps every tier to the local model and carries no host secret"
}

# lock_free: 0 once nothing holds the lock (a released holder may take a moment
# to exit).
lock_free() {
  local _
  for _ in $(seq 1 50); do
    flock -n "$FM_LOCAL_LLM_LOCK" true 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# end_holder: what a wrapper's exit does to a claim nobody took over.
end_holder() {
  exec 6<>"$FM_LOCAL_LLM_LOCK.handoff"
  exec 6>&-
}

test_a_claim_refuses_a_second_and_names_its_task() {
  local out
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  assert_equals "task-a" "$(head -n 1 "$FM_LOCAL_LLM_LOCK")" "the lock names the claiming task"
  ! flock -n "$FM_LOCAL_LLM_LOCK" true || fail "the claim must stay held after the claiming shell let go of it"
  out=$(fm_local_llm_claim task-b 2>&1) && fail "a second claim must refuse"
  assert_contains "$out" "only one local-model worker runs at a time" "the refusal names the rule"
  assert_equals "task-a" "$(head -n 1 "$FM_LOCAL_LLM_LOCK")" "a refused claim leaves the first task's name"
  end_holder
  lock_free || fail "the claim must end once its handoff is opened and closed"
  pass "a claim holds the slot for its task and refuses a second"
}

test_the_claiming_task_takes_over_and_its_exit_releases() {
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  (
    fm_local_llm_take_claim task-a || exit 3
    flock -n "$FM_LOCAL_LLM_LOCK" true && exit 4
    exit 0
  )
  expect_code 0 "$?" "the claiming task takes over a held claim without taking the lock"
  lock_free || fail "the claim must end when the taking shell exits"
  pass "the claiming task takes over the claim and its exit releases it"
}

test_another_task_or_no_claim_is_refused() {
  local out
  out=$(fm_local_llm_take_claim task-a 2>&1) && fail "no claim must refuse"
  assert_contains "$out" "holds no local-model claim" "the refusal says why"
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  out=$(fm_local_llm_take_claim task-b 2>&1) && fail "another task's claim must refuse"
  assert_contains "$out" "task task-b holds no local-model claim" "the refusal names the task"
  end_holder
  lock_free || fail "the claim must end"
  out=$(fm_local_llm_take_claim task-a 2>&1) && fail "a released claim must not be taken over"
  pass "a wrapper without its own held claim is refused"
}

test_killing_the_holder_releases_the_claim() {
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  kill "$FM_LOCAL_LLM_HOLDER" || fail "the holder must be a live process"
  lock_free || fail "a killed holder must release the slot"
  pass "the spawn releases an untaken claim by killing its holder"
}

test_a_background_job_without_the_descriptor_does_not_keep_the_claim() {
  local pidfile=$TMP_ROOT/bg.pid
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  (
    fm_local_llm_take_claim task-a || exit 3
    sleep 30 9>&- &
    echo $! >"$pidfile"
    exit 0
  )
  lock_free || fail "a child started with 9>&- must not hold the claim"
  kill "$(cat "$pidfile")" 2>/dev/null || true
  pass "a background job started without the descriptor does not keep the claim alive"
}

test_the_model_id_alone_selects_the_profile
test_health_refuses_when_the_server_is_not_answering
test_health_refuses_a_server_without_the_model
test_health_accepts_a_server_listing_the_model
test_env_maps_every_tier_and_carries_no_host_secret
test_a_claim_refuses_a_second_and_names_its_task
test_the_claiming_task_takes_over_and_its_exit_releases
test_another_task_or_no_claim_is_refused
test_killing_the_holder_releases_the_claim
test_a_background_job_without_the_descriptor_does_not_keep_the_claim

echo "# all fm-local-llm-lib tests passed"
