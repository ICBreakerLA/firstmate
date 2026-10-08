#!/usr/bin/env bash
# Live guard for the local-model worker profile (bin/fm-local-llm-lib.sh).
#
# Opt-in: it creates one real microVM and talks to the real llama-server, so it
# runs only with FM_LOCAL_LLM_LIVE=1, an installed `sbx`, and a server already
# answering on the host (start it with `local-llm up`; this test never starts
# or stops it).
#
# What it proves against the real tools:
#   - a sandbox created with the profile's environment and one sandbox-scoped
#     allow reaches the host server through host.docker.internal;
#   - Claude Code in that sandbox completes one small tool-using turn against
#     the local model, with no Claude login and no host secret in the sandbox;
#   - the global sbx policy is unchanged and the sandbox is removed afterwards.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_LOCAL_LLM_LIVE sbx curl
# shellcheck source=bin/fm-local-llm-lib.sh
. "$ROOT/bin/fm-local-llm-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-local-llm-live)
NAME="fm-local-smoke-$$"
WORK="$TMP_ROOT/work"
POLICY_BEFORE=$(sbx policy ls 2>&1)

cleanup() {
  sbx rm --force "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fm_local_llm_health || fail "the local server must already be running (local-llm up)"
mkdir -p "$WORK"
printf 'smoke\n' >"$WORK/marker.txt"

env_args=()
while IFS= read -r kv; do env_args+=(-e "$kv"); done < <(fm_local_llm_env)

test_the_sandbox_reaches_the_server_only_through_its_own_rule() {
  sbx create --name "$NAME" --pull missing --cpus 2 --memory 4g "${env_args[@]}" claude "$WORK" >/dev/null 2>&1 ||
    fail "the sandbox could not be created"
  ! sbx exec "$NAME" curl -fsS --max-time 10 "$FM_LOCAL_LLM_VM_URL/v1/models" >/dev/null 2>&1 ||
    fail "the server must be unreachable before the sandbox's own rule exists"
  sbx policy allow network --sandbox "$NAME" "$FM_LOCAL_LLM_POLICY_HOST" >/dev/null 2>&1 ||
    fail "the sandbox-scoped rule was not accepted"
  sbx exec "$NAME" curl -fsS --max-time 10 "$FM_LOCAL_LLM_VM_URL/v1/models" 2>&1 | grep -q "$FM_LOCAL_LLM_MODEL" ||
    fail "the sandbox cannot see the model through its rule"
  pass "the sandbox reaches the host server only after its own rule"
}

test_claude_completes_a_tool_turn_on_the_local_model() {
  local out
  out=$(cd "$WORK" && sbx exec -w "$WORK" "${env_args[@]}" "$NAME" claude -p \
    'Use the Bash tool to run: cat marker.txt . Then reply with the single word it printed.' \
    --model "$FM_LOCAL_LLM_MODEL" --allowedTools Bash --max-turns 6 2>&1)
  assert_contains "$out" "smoke" "the turn used a tool and answered from its output"
  pass "Claude Code completes a tool-using turn against the local model"
}

test_no_host_login_or_secret_is_in_the_sandbox() {
  local vars
  vars=$(sbx exec "${env_args[@]}" "$NAME" env 2>&1)
  assert_contains "$vars" "ANTHROPIC_AUTH_TOKEN=local-llm-no-credential" "the token is the placeholder"
  assert_not_contains "$vars" "CLAUDE_CODE_OAUTH_TOKEN" "no host login token"
  assert_not_contains "$vars" "ANTHROPIC_API_KEY=sk-" "no real API key"
  pass "the sandbox environment holds only the placeholder token"
}

test_nothing_is_left_behind() {
  sbx rm --force "$NAME" >/dev/null 2>&1 || fail "the sandbox was not removed"
  assert_equals "$POLICY_BEFORE" "$(sbx policy ls 2>&1)" "the global sbx policy is unchanged"
  pass "the sandbox is gone and the global policy is unchanged"
}

test_the_sandbox_reaches_the_server_only_through_its_own_rule
test_claude_completes_a_tool_turn_on_the_local_model
test_no_host_login_or_secret_is_in_the_sandbox
test_nothing_is_left_behind

echo "# all fm-local-llm-live tests passed"
