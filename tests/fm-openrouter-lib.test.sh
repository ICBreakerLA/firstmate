#!/usr/bin/env bash
# Behavior tests for bin/fm-openrouter-lib.sh: the profile selector, the key
# file, the alias chain, the zero-retention probe and its fallthrough, the worker
# environment, and the usage reading. A fake curl stands in for OpenRouter;
# nothing here touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-openrouter-lib.sh
. "$ROOT/bin/fm-openrouter-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-openrouter-lib)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_KEY=sk-or-v1-FAKE-TEST-KEY-0123456789
export FM_OPENROUTER_KEY_FILE="$TMP_ROOT/key"
CFG="$TMP_ROOT/config"
PATH="$FAKEBIN:$PATH"
mkdir -p "$CFG" "$TMP_ROOT/status"

# A fake curl that reads the config curl is given on stdin. A probe is answered
# with the status file named after the model id (200 when there is none); the
# key route answers with the usage file. The log holds the arguments and the
# config with the key redacted, so a test can see where the key travelled.
cat >"$FAKEBIN/curl" <<SH
#!/usr/bin/env bash
cfg=\$(cat)
printf 'ARGS: %s\\n' "\$*" >>"$TMP_ROOT/curl.log"
printf '%s\\n' "\$cfg" | sed "s/$FAKE_KEY/<KEY>/g" >>"$TMP_ROOT/curl.log"
case "\$cfg" in
*"/v1/key"*)
  [ -f "$TMP_ROOT/usage" ] || { printf '\\n500'; exit 0; }
  printf '{"data":{"label":"x","usage":%s,"limit":10}}\\n200' "\$(cat "$TMP_ROOT/usage")" ;;
*)
  id=\$(printf '%s' "\$cfg" | sed -n 's/.*\\\\"model\\\\":\\\\"\\([^\\\\]*\\)\\\\".*/\\1/p' | tr '/' '_')
  [ ! -f "$TMP_ROOT/curl.down" ] || exit 7
  printf '\\n%s' "\$(cat "$TMP_ROOT/status/\$id" 2>/dev/null || echo 200)" ;;
esac
SH
chmod +x "$FAKEBIN/curl"

reset() {
  printf '%s\n' "$FAKE_KEY" >"$FM_OPENROUTER_KEY_FILE"
  rm -rf "$TMP_ROOT/status" "$TMP_ROOT/curl.down" "$TMP_ROOT/usage"
  mkdir -p "$TMP_ROOT/status"
  : >"$TMP_ROOT/curl.log"
  printf '# the chains\nqwen: qwen/qwen3.8-27b, qwen/qwen3-coder,  other/model:nitro\nsolo: vendor/one\nfree: vendor/model:free\n' >"$CFG/openrouter-models.list"
}
status_of() { printf '%s' "$2" >"$TMP_ROOT/status/$(printf '%s' "$1" | tr '/' '_')"; }

test_the_or_prefix_alone_selects_the_profile() {
  fm_openrouter_is_model or:qwen || fail "or:<alias> selects the profile"
  fm_openrouter_is_model or:qwen/qwen3.8-27b || fail "or:<id> selects the profile"
  ! fm_openrouter_is_model qwen/qwen3.8-27b || fail "a bare id is not the profile"
  ! fm_openrouter_is_model claude-fable-5-1 || fail "a Claude model is not the profile"
  ! fm_openrouter_is_model '' || fail "an empty model is not the profile"
  pass "only an or: model id selects the profile"
}

test_the_key_file_is_required_and_never_a_symlink() {
  local out
  reset
  rm -f "$FM_OPENROUTER_KEY_FILE"
  out=$(fm_openrouter_resolve "$CFG" or:qwen 2>&1) && fail "a missing key must refuse"
  assert_contains "$out" "needs its key in $FM_OPENROUTER_KEY_FILE" "the refusal names the file"
  assert_not_contains "$(cat "$TMP_ROOT/curl.log")" "ARGS" "nothing is requested without a key"
  : >"$FM_OPENROUTER_KEY_FILE"
  out=$(fm_openrouter_resolve "$CFG" or:qwen 2>&1) && fail "an empty key must refuse"
  assert_contains "$out" "is empty" "the refusal says the file is empty"
  printf '%s\n' "$FAKE_KEY" >"$TMP_ROOT/real-key"
  ln -sf "$TMP_ROOT/real-key" "$FM_OPENROUTER_KEY_FILE"
  out=$(fm_openrouter_resolve "$CFG" or:qwen 2>&1) && fail "a symlinked key must refuse"
  assert_contains "$out" "needs its key in" "a symlink is not a key file"
  rm -f "$FM_OPENROUTER_KEY_FILE"
  pass "a missing, empty or symlinked key file refuses before any request"
}

test_free_models_are_refused_before_any_request() {
  local out
  reset
  out=$(fm_openrouter_resolve "$CFG" or:vendor/model:free 2>&1) && fail "a :free id must refuse"
  assert_contains "$out" ":free" "the refusal names the rule"
  assert_contains "$out" "zero-retention" "the refusal says why"
  out=$(fm_openrouter_resolve "$CFG" or:free 2>&1) && fail "a chain holding a :free id must refuse"
  assert_contains "$out" "vendor/model:free is a :free" "the chain's free id is named"
  assert_not_contains "$(cat "$TMP_ROOT/curl.log")" "ARGS" "no request is made for a free model"
  pass ":free ids are refused, direct or through a chain, before any request"
}

test_an_alias_resolves_to_the_first_answering_id() {
  local out
  reset
  out=$(fm_openrouter_resolve "$CFG" or:qwen) || fail "a healthy first id must resolve"
  assert_equals "$(printf 'qwen\tqwen/qwen3.8-27b')" "$out" "the alias and the first id are returned"
  assert_equals 1 "$(grep -c '^ARGS' "$TMP_ROOT/curl.log")" "only the first id is probed"
  pass "an alias resolves to its first answering id"
}

test_the_probe_demands_a_zero_retention_endpoint_and_hides_the_key() {
  local log
  reset
  fm_openrouter_resolve "$CFG" or:qwen >/dev/null || fail "resolve"
  log=$(cat "$TMP_ROOT/curl.log")
  assert_contains "$log" 'zdr\":true,\"data_collection\":\"deny' "the request demands a zero-retention endpoint"
  assert_contains "$log" 'max_tokens\":1' "the probe is one token"
  assert_contains "$log" "Authorization: Bearer <KEY>" "the key is sent as the bearer token"
  assert_contains "$log" "ARGS: --config -" "the request is configured on stdin"
  assert_not_contains "$log" "$FAKE_KEY" "the key is in no argument"
  pass "the probe asks for zdr and data_collection deny and the key never reaches an argument"
}

test_a_failing_id_skips_to_the_next_in_the_chain() {
  local out code
  for code in 402 429 500 503 404 000; do
    reset
    status_of qwen/qwen3.8-27b "$code"
    out=$(fm_openrouter_resolve "$CFG" or:qwen) || fail "HTTP $code must skip to the next id"
    assert_equals "$(printf 'qwen\tqwen/qwen3-coder')" "$out" "HTTP $code skips to the second id"
  done
  reset
  status_of qwen/qwen3.8-27b 402
  status_of qwen/qwen3-coder 429
  out=$(fm_openrouter_resolve "$CFG" or:qwen) || fail "the third id must answer"
  assert_equals "$(printf 'qwen\tother/model:nitro')" "$out" "skips accumulate down the chain"
  pass "402, 429, 5xx, no endpoint and a timeout each skip to the next id"
}

test_a_chain_where_nothing_answers_refuses_and_lists_each_id() {
  local out
  reset
  status_of qwen/qwen3.8-27b 404
  status_of qwen/qwen3-coder 402
  status_of other/model:nitro 503
  out=$(fm_openrouter_resolve "$CFG" or:qwen 2>&1) && fail "an unanswered chain must refuse"
  assert_contains "$out" "qwen/qwen3.8-27b (HTTP 404)" "the first failure is named"
  assert_contains "$out" "other/model:nitro (HTTP 503)" "the last failure is named"
  assert_contains "$out" "zero-retention" "the refusal names the missing endpoint"
  pass "a chain where nothing answers refuses with each id's status"
}

test_a_direct_id_never_falls_through() {
  local out
  reset
  fm_openrouter_resolve "$CFG" or:vendor/direct >/dev/null || fail "an answering direct id resolves"
  assert_equals "$(printf '\tvendor/direct')" "$(fm_openrouter_resolve "$CFG" or:vendor/direct)" "no alias is returned"
  status_of vendor/direct 429
  out=$(fm_openrouter_resolve "$CFG" or:vendor/direct 2>&1) && fail "a failing direct id must refuse"
  assert_contains "$out" "vendor/direct (HTTP 429)" "the refusal names the status"
  pass "a direct id is probed alone and refuses when it fails"
}

test_a_rejected_key_stops_the_chain() {
  local out
  reset
  status_of qwen/qwen3.8-27b 401
  out=$(fm_openrouter_resolve "$CFG" or:qwen 2>&1) && fail "a rejected key must refuse"
  assert_contains "$out" "rejected the worker key (HTTP 401)" "the refusal names the key"
  assert_equals 1 "$(grep -c '^ARGS' "$TMP_ROOT/curl.log")" "the rest of the chain is not tried"
  assert_not_contains "$out" "$FAKE_KEY" "the key is not printed"
  pass "a rejected key refuses at once and never prints the key"
}

test_an_unknown_alias_or_bad_id_refuses() {
  local out
  reset
  out=$(fm_openrouter_resolve "$CFG" or:nope 2>&1) && fail "an unknown alias must refuse"
  assert_contains "$out" "no alias 'nope'" "the refusal names the alias"
  rm -f "$CFG/openrouter-models.list"
  out=$(fm_openrouter_resolve "$CFG" or:qwen 2>&1) && fail "a missing chain file must refuse"
  assert_contains "$out" "no alias 'qwen'" "an absent file has no aliases"
  out=$(fm_openrouter_resolve "$CFG" 'or:' 2>&1) && fail "an empty model must refuse"
  assert_contains "$out" "needs a model after or:" "the refusal says what is missing"
  out=$(fm_openrouter_resolve "$CFG" 'or:a/b;rm' 2>&1) && fail "an odd id must refuse"
  assert_contains "$out" "not a usable OpenRouter model id" "the refusal names the id"
  assert_not_contains "$(cat "$TMP_ROOT/curl.log")" "ARGS" "nothing is requested for a bad model"
  pass "an unknown alias, an empty model and an odd id refuse before any request"
}

test_the_environment_maps_every_tier_and_leaves_the_key_out() {
  local env k
  env=$(ANTHROPIC_API_KEY=host-key CLAUDE_CODE_OAUTH_TOKEN=host-oauth fm_openrouter_env qwen/qwen3.8-27b)
  for k in ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
    ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL; do
    assert_contains "$env" "$k=qwen/qwen3.8-27b" "$k maps to the OpenRouter model"
  done
  assert_contains "$env" "ANTHROPIC_BASE_URL=https://openrouter.ai/api" "the base URL is OpenRouter"
  assert_contains "$env" "ANTHROPIC_API_KEY=" "the API key variable is set"
  assert_equals "ANTHROPIC_API_KEY=" "$(printf '%s\n' "$env" | grep '^ANTHROPIC_API_KEY')" "the API key variable is empty"
  assert_contains "$env" "CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000" "auto-compact is 200000"
  assert_contains "$env" "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" "nonessential traffic is off"
  assert_contains "$env" "CLAUDE_CODE_ATTRIBUTION_HEADER=0" "the attribution header is off"
  assert_not_contains "$env" "ANTHROPIC_AUTH_TOKEN" "the token is added by the wrapper, not this list"
  assert_not_contains "$env" "$FAKE_KEY" "the key is not in the list"
  assert_not_contains "$env" "host-key" "a host API key is never in the environment"
  assert_not_contains "$env" "host-oauth" "a host login token is never in the environment"
  pass "the environment maps every tier to the model and carries no key or host secret"
}

test_usage_reads_the_keys_spend() {
  reset
  fm_openrouter_usage && fail "an unreadable usage must report nothing"
  printf '1.2345' >"$TMP_ROOT/usage"
  assert_equals "1.2345" "$(fm_openrouter_usage)" "the usage is the key's lifetime spend"
  assert_not_contains "$(cat "$TMP_ROOT/curl.log")" "$FAKE_KEY" "the key stays out of the arguments"
  rm -f "$FM_OPENROUTER_KEY_FILE"
  fm_openrouter_usage && fail "no key means no usage reading"
  pass "usage is read from /v1/key without exposing the key"
}

test_the_or_prefix_alone_selects_the_profile
test_the_key_file_is_required_and_never_a_symlink
test_free_models_are_refused_before_any_request
test_an_alias_resolves_to_the_first_answering_id
test_the_probe_demands_a_zero_retention_endpoint_and_hides_the_key
test_a_failing_id_skips_to_the_next_in_the_chain
test_a_chain_where_nothing_answers_refuses_and_lists_each_id
test_a_direct_id_never_falls_through
test_a_rejected_key_stops_the_chain
test_an_unknown_alias_or_bad_id_refuses
test_the_environment_maps_every_tier_and_leaves_the_key_out
test_usage_reads_the_keys_spend

echo "# all fm-openrouter-lib tests passed"
