#!/usr/bin/env bash
# Behavior tests for bin/fm-sbx-lib.sh: the config/worker-sandbox grammar, the
# sandbox name derivation, the preflight, and the guarded idempotent removal.
# A fake `sbx` on PATH records its calls; the real CLI is covered by the live
# guard in tests/fm-sbx-live.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-sbx-lib.sh
. "$ROOT/bin/fm-sbx-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-sbx-lib)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SBX_LOG="$TMP_ROOT/sbx.log"
SBX_LIVE="$TMP_ROOT/sbx.live"

cat >"$FAKEBIN/sbx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SBX_LOG"
case "$1" in
daemon) printf 'Status: %s\n' "${SBX_DAEMON_STATE:-running}"; [ "${SBX_DAEMON_STATE:-running}" = running ] ;;
ls) cat "$SBX_LIVE" 2>/dev/null; exit 0 ;;
rm)
  [ "${SBX_RM_STICKS:-0}" = 1 ] && exit 0
  shift; [ "$1" = --force ] && shift
  grep -Fxv -- "$1" "$SBX_LIVE" >"$SBX_LIVE.new" 2>/dev/null; mv "$SBX_LIVE.new" "$SBX_LIVE"
  ;;
esac
SH
chmod +x "$FAKEBIN/sbx"
export SBX_LOG SBX_LIVE
PATH="$FAKEBIN:$PATH"

load() { # <content> -> runs the parser on a temp file
  printf '%b' "$1" >"$TMP_ROOT/ws"
  fm_sbx_load_config "$TMP_ROOT/ws"
}

test_absent_and_off_leave_the_default_off() {
  fm_sbx_load_config "$TMP_ROOT/none" || fail "an absent file should be accepted"
  assert_equals off "$FM_SBX_MODE" "absent file is off"
  load 'off\n' || fail "off should be accepted"
  assert_equals off "$FM_SBX_MODE" "off is off"
  pass "absent and off both resolve to off"
}

test_sbx_defaults_and_options() {
  load 'sbx\n' || fail "bare sbx should be accepted"
  assert_equals "sbx 4 4g" "$FM_SBX_MODE $FM_SBX_CPUS $FM_SBX_MEMORY" "sbx defaults"
  load 'sbx cpus=8 memory=16g\n' || fail "sbx with options should be accepted"
  assert_equals "sbx 8 16g" "$FM_SBX_MODE $FM_SBX_CPUS $FM_SBX_MEMORY" "sbx options"
  assert_equals "" "$FM_SBX_ALLOW" "no extra hosts by default"
  load 'sbx allow=registry.npmjs.org,*.example.org cpus=2\n' || fail "allow= should be accepted"
  assert_equals "registry.npmjs.org,*.example.org 2" "$FM_SBX_ALLOW $FM_SBX_CPUS" "allow hosts are parsed"
  assert_equals "" "$FM_SBX_NM_PIN" "no version pin by default"
  load 'sbx nm=v1.79.0\n' || fail "nm= should be accepted"
  assert_equals "v1.79.0" "$FM_SBX_NM_PIN" "the no-mistakes pin is parsed"
  assert_equals "v1.79.0" "$(fm_sbx_nm_version 'no-mistakes version v1.79.0 (abc)')" "the version token is read from a version line"
  assert_equals "v1.79.0" "$(fm_sbx_nm_version "$(printf 'A new version of no-mistakes is available: v1.79.0 -> v1.84.0\nno-mistakes version v1.79.0 (fc540ac) 2026-09-19T09:34:32Z\n')")" "an update banner is never read as the version"
  assert_equals "" "$(fm_sbx_nm_version 'no version here')" "a line with no version yields nothing"
  pass "sbx resolves its defaults and honours cpus, memory, allow and nm"
}

test_malformed_values_are_refused() {
  local bad err
  for bad in 'docker\n' 'sbx cpus=0\n' 'sbx cpus=65\n' 'sbx memory=4\n' 'sbx memory=0g\n' 'sbx gpus=1\n' 'off cpus=2\n' 'sbx allow=\n' 'sbx allow=a b;c\n' 'sbx allow=a,,b\n' 'sbx allow=host/path\n' 'sbx nm=latest\n' 'sbx nm=v1.2\n' 'sbx nm=v1.2.3;x\n' 'sbx verify=\n' 'sbx verify=other\n' 'sbx verify=sportsmeet,x\n'; do
    err=$(load "$bad" 2>&1) && fail "'$bad' should be refused"
    assert_contains "$err" "config/worker-sandbox" "the refusal names the file for '$bad'"
  done
  mkdir -p "$TMP_ROOT/dirconf"
  fm_sbx_load_config "$TMP_ROOT/dirconf" 2>/dev/null && fail "a directory should be refused"
  pass "an unknown value, a bad option, and a non-file are refused"
}

test_verify_token_is_opt_in_and_strict() {
  load 'sbx\n' || fail "bare sbx should be accepted"
  assert_equals "" "$FM_SBX_VERIFY" "the verification broker is off by default"
  load 'sbx verify=sportsmeet cpus=2\n' || fail "verify=sportsmeet should be accepted"
  assert_equals "sportsmeet 2" "$FM_SBX_VERIFY $FM_SBX_CPUS" "the verify token is parsed beside other options"
  load 'sbx\n' || fail "a later bare sbx should be accepted"
  assert_equals "" "$FM_SBX_VERIFY" "a reload resets the token"
  assert_equals "/s/t.sbx-verify" "$(fm_sbx_verify_dir /s t)" "the per-task verify directory"
  pass "verify=sportsmeet is opt-in, strict, and reset on reload"
}

test_name_is_stable_distinct_and_safe() {
  local a b c
  a=$(fm_sbx_name /home/a task-one)
  b=$(fm_sbx_name /home/b task-one)
  c=$(fm_sbx_name /home/a task-one)
  assert_equals "$a" "$c" "the name is deterministic"
  assert_not_equals "$a" "$b" "two homes never share a name"
  fm_sbx_is_fleet_name "$a" || fail "a derived name is a fleet name"
  a=$(fm_sbx_name /home/a 'we ird/id.with spaces')
  case "$a" in *[!A-Za-z0-9-]*) fail "unsafe characters survived: $a" ;; esac
  a=$(fm_sbx_name /home/a "$(printf 'x%.0s' $(seq 1 120))")
  [ "${#a}" -le 64 ] || fail "a long id must stay bounded: ${#a}"
  [ "$(fm_sbx_name /home/a 'a/b')" != "$(fm_sbx_name /home/a 'a-b')" ] || fail "ids that sanitize alike must still differ"
  pass "names are deterministic, per-home, bounded, and shell-safe"
}

test_only_fleet_names_are_removable() {
  : >"$SBX_LOG"
  fm_sbx_rm my-own-sandbox 2>/dev/null && fail "a foreign sandbox name must be refused"
  fm_sbx_rm 'fm-sbx-nm-a' 2>/dev/null && fail "a name without a home hash must be refused"
  if grep -q '^rm' "$SBX_LOG"; then fail "no sbx rm may be issued for a refused name"; fi
  pass "removal refuses names this tree would not have created"
}

test_removal_is_idempotent_and_verified() {
  local n
  n=$(fm_sbx_name /home/a task-rm)
  printf '%s\n' "$n" >"$SBX_LIVE"
  fm_sbx_rm "$n" || fail "removal of a live sandbox should succeed"
  [ ! -s "$SBX_LIVE" ] || fail "the sandbox should be gone"
  fm_sbx_rm "$n" || fail "removing an absent sandbox is success"
  printf '%s\n' "$n" >"$SBX_LIVE"
  SBX_RM_STICKS=1 fm_sbx_rm "$n" 2>/dev/null && fail "a sandbox that survives the removal is a failure"
  pass "removal is idempotent and reports a sandbox that survives"
}

test_preflight_names_the_missing_requirement() {
  local err
  fm_sbx_preflight || fail "a running daemon passes"
  err=$(SBX_DAEMON_STATE=stopped fm_sbx_preflight 2>&1) && fail "a stopped daemon must fail"
  assert_contains "$err" "daemon is not running" "the stopped-daemon refusal"
  err=$(PATH="$TMP_ROOT/empty" fm_sbx_preflight 2>&1) && fail "a missing CLI must fail"
  assert_contains "$err" "not installed" "the missing-CLI refusal"
  pass "preflight passes on a running daemon and names what is missing otherwise"
}

test_absent_and_off_leave_the_default_off
test_sbx_defaults_and_options
test_malformed_values_are_refused
test_verify_token_is_opt_in_and_strict
test_name_is_stable_distinct_and_safe
test_only_fleet_names_are_removable
test_removal_is_idempotent_and_verified
test_preflight_names_the_missing_requirement

echo "# all fm-sbx-lib tests passed"
