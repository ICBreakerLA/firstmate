#!/usr/bin/env bash
# Behavior tests for bin/fm-output-scan.sh and its fm-x-reply.sh call site.
#
# Every synthetic secret is assembled at run time from fragments so this file
# never carries a real-looking secret literal and the --diff scan of this very
# branch stays quiet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN="$ROOT/bin/fm-output-scan.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-output-scan-tests)

# run_scan <home> <stdin-text>: sets OUT and RC; scanner output is stdout+stderr.
run_scan() {
  local home=$1 text=$2
  mkdir -p "$home/config"
  OUT=$(printf '%s\n' "$text" | FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" "$SCAN" - 2>&1)
  RC=$?
}

# Synthetic values, one per shape. Fragments are joined here, never in one literal.
t_aws() { printf '%s%s' "AK" "IAABCDEFGHIJKLMNOP"; }
t_gh() { printf '%s%s' "gh" "p_abcdefghijklmnopqrstuvwxyz0123456789"; }
t_ant() { printf '%s%s' "sk-" "ant-api03-abcdefghijklmnopqrstuvwxyz"; }
t_oai() { printf '%s%s' "sk-" "proj1234567890abcdefghijklmnopqrstuvwxyz"; }
t_slack() { printf '%s%s' "xo" "xb-1234567890-abcdefghijkl"; }
t_pem() { printf '%s%s' "-----BEGIN RSA PRIV" "ATE KEY-----"; }
t_jwt() { printf '%s%s%s' "ey" "JhbGciOiJIUzI1NiJ9" ".eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghij0123456789"; }
t_bearer() { printf '%s%s' "Bear" "er abcdefghijklmnopqrstuvwxyz012345"; }
t_assign() { printf '%s%s' "api_" "key=abcd1234efgh5678ijkl"; }

assert_hit() {  # <shape> <value> <line>
  local shape=$1 value=$2 line=$3
  run_scan "$TMP_ROOT/h-$shape" $'clean line\n'"prefix $value suffix"
  expect_code 1 "$RC" "$shape exit"
  assert_equals "$shape line $line" "$OUT" "$shape output must name only the shape and line"
  assert_not_contains "$OUT" "$value" "$shape output must never contain the matched value"
}

test_secret_shapes_hit() {
  assert_hit aws-key-id "$(t_aws)" 2
  assert_hit github-token "$(t_gh)" 2
  assert_hit anthropic-key "$(t_ant)" 2
  assert_hit openai-key "$(t_oai)" 2
  assert_hit slack-token "$(t_slack)" 2
  assert_hit private-key "$(t_pem)" 2
  assert_hit jwt "$(t_jwt)" 2
  assert_hit bearer-header "$(t_bearer)" 2
  assert_hit secret-assignment "$(t_assign)" 2
  pass "every secret shape is reported by shape and line without its value"
}

test_clean_text_exits_zero() {
  run_scan "$TMP_ROOT/clean" $'Plain status text.\nsecret_handling = documented\ntoken: none\nPR landed at https://example.test/pr/1'
  expect_code 0 "$RC" "clean exit"
  [ -z "$OUT" ] || fail "clean text must print nothing (got: $OUT)"
  pass "clean text exits 0 silently"
}

test_secret_assignment_needs_digit_value() {
  run_scan "$TMP_ROOT/assign-nodigit" "api_key=abcdefghijklmnopqrstuvwx"
  expect_code 0 "$RC" "digitless value exit"
  pass "key=value with a word-only value is not a secret hit"
}

test_openai_shape_skips_anthropic_keys() {
  run_scan "$TMP_ROOT/ant-only" "$(t_ant)"
  expect_code 1 "$RC" "anthropic exit"
  assert_equals "anthropic-key line 1" "$OUT" "an sk-ant key must not also report as openai-key"
  pass "an anthropic key reports once"
}

test_multiple_hits_listed_in_line_order() {
  run_scan "$TMP_ROOT/multi" "$(t_gh)"$'\nok\n'"$(t_aws)"
  expect_code 1 "$RC" "multi exit"
  assert_equals $'github-token line 1\naws-key-id line 3' "$OUT" "hits must be listed in line order"
  pass "multiple hits are listed in line order"
}

test_personal_shapes_off_without_deny_list() {
  local home="$TMP_ROOT/no-deny"
  rm -f "$home/config/output-scan-deny.txt"
  run_scan "$home" $'jane@example.test\n+1 415 555 0100\n/home/jane/work\nJane Doe'
  expect_code 0 "$RC" "no deny-list exit"
  [ -z "$OUT" ] || fail "no deny-list must mean no personal rules (got: $OUT)"
  pass "an absent deny-list leaves personal-data rules off"
}

test_deny_list_shapes() {
  local home="$TMP_ROOT/deny" value
  mkdir -p "$home/config"
  cat >"$home/config/output-scan-deny.txt" <<'EOF'
# captain-maintained
Jane@Example.Test
+1 (415) 555-0100
/home/jane/
Acme Rocketry

EOF
  for value in "mail JANE@example.test now" "call 415.555.0100" "see /home/jane/notes" "at acme rocketry hq"; do
    run_scan "$home" "$value"
    expect_code 1 "$RC" "deny-list exit for '$value'"
  done
  run_scan "$home" "jane@example.test"
  assert_equals "email line 1" "$OUT" "email entry shape"
  run_scan "$home" "call 4155550100"
  assert_equals "phone line 1" "$OUT" "phone entry shape"
  run_scan "$home" "/home/jane/x"
  assert_equals "home-path line 1" "$OUT" "home-path entry shape"
  run_scan "$home" "Acme Rocketry"
  assert_equals "personal-term line 1" "$OUT" "personal-term entry shape"
  assert_not_contains "$OUT" "Acme" "deny-list hit must not print the term"
  run_scan "$home" "other@example.test and /home/bob/ and 415 555 0199"
  expect_code 0 "$RC" "non-listed personal data exit"
  pass "deny-list entries drive the email, phone, home-path and personal-term shapes"
}

test_deny_list_errors_exit_two() {
  local home="$TMP_ROOT/deny-bad"
  mkdir -p "$home/config"
  printf 'ab\n' >"$home/config/output-scan-deny.txt"
  run_scan "$home" "anything"
  expect_code 2 "$RC" "short entry exit"
  assert_contains "$OUT" "shorter than three characters" "short entry must be named"
  printf '123\n' >"$home/config/output-scan-deny.txt"
  run_scan "$home" "anything"
  expect_code 2 "$RC" "short phone entry exit"
  rm -f "$home/config/output-scan-deny.txt"
  mkdir "$home/config/output-scan-deny.txt"
  run_scan "$home" "anything"
  expect_code 2 "$RC" "unreadable deny-list exit"
  rmdir "$home/config/output-scan-deny.txt"
  pass "a malformed or unreadable deny-list is exit 2, never a silent pass"
}

test_usage_errors_exit_two() {
  local out rc
  out=$("$SCAN" 2>&1); rc=$?
  expect_code 2 "$rc" "no-arg exit"
  out=$("$SCAN" "$TMP_ROOT/does-not-exist" 2>&1); rc=$?
  expect_code 2 "$rc" "missing-file exit"
  out=$("$SCAN" --bogus 2>&1); rc=$?
  expect_code 2 "$rc" "unknown-flag exit"
  out=$("$SCAN" --help 2>&1); rc=$?
  expect_code 0 "$rc" "help exit"
  assert_contains "$out" "usage:" "help must show usage"
  pass "usage and file errors exit 2"
}

test_file_input() {
  local f="$TMP_ROOT/report.md"
  printf 'line one\n%s\n' "$(t_slack)" >"$f"
  OUT=$("$SCAN" "$f" 2>&1); RC=$?
  expect_code 1 "$RC" "file exit"
  assert_equals "slack-token line 2" "$OUT" "file scan output"
  pass "a file argument is scanned like stdin"
}

test_diff_scans_added_lines_only() {
  local repo="$TMP_ROOT/diff-repo" out rc
  rm -rf "$repo"; mkdir -p "$repo"
  git -C "$repo" init -q -b main
  fm_git_identity "$repo"
  printf 'keep %s\n' "$(t_aws)" >"$repo/old.txt"
  git -C "$repo" add old.txt
  git -C "$repo" commit -q -m base
  git -C "$repo" checkout -q -b work
  printf 'safe\nsecond\n%s\n' "$(t_gh)" >"$repo/new.txt"
  git -C "$repo" add new.txt
  git -C "$repo" commit -q -m add

  out=$(cd "$repo" && FM_HOME="$TMP_ROOT/diff-home" "$SCAN" --diff main 2>&1); rc=$?
  expect_code 1 "$rc" "diff exit"
  assert_equals "github-token new.txt:3" "$out" "diff must report path:line of added lines only"
  out=$(cd "$repo" && FM_HOME="$TMP_ROOT/diff-home" "$SCAN" --diff 2>&1); rc=$?
  expect_code 1 "$rc" "diff default-base exit"
  assert_equals "github-token new.txt:3" "$out" "default base is the merge-base with main"

  git -C "$repo" checkout -q main
  git -C "$repo" checkout -q -b clean
  printf 'plain\n' >"$repo/ok.txt"
  git -C "$repo" add ok.txt
  git -C "$repo" commit -q -m ok
  out=$(cd "$repo" && FM_HOME="$TMP_ROOT/diff-home" "$SCAN" --diff main 2>&1); rc=$?
  expect_code 0 "$rc" "diff clean exit"
  [ -z "$out" ] || fail "a clean diff must print nothing (got: $out)"

  out=$(cd "$TMP_ROOT" && "$SCAN" --diff main 2>&1); rc=$?
  expect_code 2 "$rc" "diff outside a repo exit"
  pass "--diff scans only added lines and reports path:line"
}

# The shipped docs and skills describe secrets in prose; the always-on secret
# shapes must stay quiet over them. Personal-data shapes are off (no deny-list).
test_false_positive_census_is_quiet() {
  local home="$TMP_ROOT/census" out rc dir
  mkdir -p "$home/config"
  for dir in docs .agents/skills; do
    [ -d "$ROOT/$dir" ] || continue
    out=$(find "$ROOT/$dir" -type f \( -name '*.md' -o -name '*.json' \) -print0 \
      | xargs -0 cat | FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" "$SCAN" - 2>&1); rc=$?
    expect_code 0 "$rc" "census over $dir"
    [ -z "$out" ] || fail "secret shapes fired over $dir: $out"
  done
  pass "secret shapes stay quiet over docs/ and .agents/skills/"
}

test_x_reply_refuses_on_hit() {
  local home="$TMP_ROOT/reply-hit" out rc err
  mkdir -p "$home"
  err="$home/err.txt"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-reply.sh" req-scan "here is the token $(t_gh) ok" 2>"$err"); rc=$?
  expect_code 7 "$rc" "reply with a secret exit"
  [ -z "$out" ] || fail "a refused reply must not echo the request_id (got: $out)"
  assert_grep "github-token line 1" "$err" "refusal must name the shape and line"
  assert_no_grep "$(t_gh)" "$err" "refusal must never echo the matched value"
  assert_absent "$home/state/x-outbox/req-scan.json" "a refused reply must not record an outbox preview"

  out=$(PATH="$BASE_PATH" FM_HOME="$home" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-reply.sh" req-ok "all good, nothing sensitive" 2>"$err"); rc=$?
  expect_code 0 "$rc" "clean reply exit"
  assert_present "$home/state/x-outbox/req-ok.json" "a clean dry-run reply must still be recorded"
  pass "fm-x-reply refuses a hit before posting and still posts clean text"
}

test_x_reply_refuses_on_deny_list_hit() {
  local home="$TMP_ROOT/reply-deny" out rc err
  mkdir -p "$home/config"
  err="$home/err.txt"
  printf 'Acme Rocketry\n' >"$home/config/output-scan-deny.txt"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-reply.sh" req-deny "shipping for Acme Rocketry" 2>"$err"); rc=$?
  expect_code 7 "$rc" "reply with a deny-list term exit"
  assert_grep "personal-term line 1" "$err" "refusal must name the shape and line"
  assert_absent "$home/state/x-outbox/req-deny.json" "a refused reply must not record an outbox preview"
  pass "fm-x-reply honors the deny-list"
}

# The scout completion gate runs the scan over the report. A copy of bin/ with a
# stubbed captain-hold verify isolates that step from the backlog backend.
test_scout_teardown_refuses_report_with_a_hit() {
  local dir="$TMP_ROOT/scout-gate" home out rc
  home="$dir/home"
  rm -rf "$dir"
  mkdir -p "$home/state" "$home/data/scout-a" "$home/config" "$home/projects" "$dir/project" "$dir/worktree"
  cp -R "$ROOT/bin" "$dir/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/bin/fm-captain-hold.sh"
  git -C "$dir/project" init -q -b main
  fm_write_meta "$home/state/scout-a.meta" \
    "window=isolated:fm-scout-a" "endpoint_task_id=scout-a" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  printf 'findings\n%s\n' "$(t_gh)" >"$home/data/scout-a/report.md"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$dir/bin/fm-teardown.sh" scout-a 2>&1); rc=$?
  expect_code 1 "$rc" "scout teardown with a secret in the report"
  assert_contains "$out" "did not pass the output scan" "refusal must name the scan"
  assert_contains "$out" "github-token line 2" "refusal must name the shape and line"
  assert_not_contains "$out" "$(t_gh)" "refusal must never echo the matched value"
  assert_present "$home/state/scout-a.meta" "a refused scout teardown must keep its state"
  pass "scout teardown holds a report that fails the output scan"
}

test_secret_shapes_hit
test_clean_text_exits_zero
test_secret_assignment_needs_digit_value
test_openai_shape_skips_anthropic_keys
test_multiple_hits_listed_in_line_order
test_personal_shapes_off_without_deny_list
test_deny_list_shapes
test_deny_list_errors_exit_two
test_usage_errors_exit_two
test_file_input
test_diff_scans_added_lines_only
test_false_positive_census_is_quiet
test_x_reply_refuses_on_hit
test_x_reply_refuses_on_deny_list_hit
test_scout_teardown_refuses_report_with_a_hit
