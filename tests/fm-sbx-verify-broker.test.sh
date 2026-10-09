#!/usr/bin/env bash
# Behavior tests for bin/fm-sbx-verify-broker.sh: a sandboxed worker's request
# spool is untrusted input, only allowlisted typed steps reach the pinned
# sm-verify command, and the emulator lease is always given back.
# The pinned command is a stub that records its argv and touches nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BROKER="$ROOT/bin/fm-sbx-verify-broker.sh"
TMP_ROOT=$(fm_test_tmproot fm-sbx-verify)
DAEMONS=()

cleanup_daemons() {
  local p
  for p in "${DAEMONS[@]+"${DAEMONS[@]}"}"; do
    kill -TERM "$p" 2>/dev/null || true
  done
}
trap 'cleanup_daemons; fm_test_cleanup' EXIT

make_stub() { # <path>
  cat >"$1" <<'SH'
#!/usr/bin/env bash
{
  printf 'argv:'
  for a in "$@"; do printf ' [%s]' "$a"; done
  printf '\n'
  printf 'cwd: %s\n' "$PWD"
  printf 'env-url: %s\n' "${FM_SBX_VERIFY_BUNDLE_URL:-}"
  printf 'env-evidence: %s\n' "${FM_SBX_VERIFY_EVIDENCE_DIR:-}"
  if [ -n "${1:-}" ] && [ "${1:-}" = flow -o "${1:-}" = do ]; then
    printf 'yaml<<\n'
    cat "$2"
    printf '>>\n'
  fi
} >>"$STUB_LOG"
case "${1:-}" in
shot | do | flow)
  printf '\x89PNG\r\n\x1a\nstub' >"$FM_SBX_VERIFY_EVIDENCE_DIR/real.png"
  printf 'not a png at all' >"$FM_SBX_VERIFY_EVIDENCE_DIR/fake.png"
  ln -s /etc/hostname "$FM_SBX_VERIFY_EVIDENCE_DIR/link.png"
  ;;
tree) printf 'tree\033[31m red\a bell\n' ;;
esac
exit "${STUB_EXIT:-0}"
SH
  chmod +x "$1"
}

# new_world <name> [ttl] [qttl] -> BIN CONFIG LEASE STATE REQ RES HOST LOG
new_world() {
  local d="$TMP_ROOT/$1" ttl=${2:-1200} qttl=${3:-180}
  BIN="$d/host-bin"
  CONFIG="$d/config"
  LEASE="$d/lease"
  STATE="$d/state"
  FAKEBIN="$d/fakebin"
  mkdir -p "$BIN" "$CONFIG" "$STATE" "$FAKEBIN"
  chmod 755 "$STATE"
  make_stub "$BIN/sm-verify"
  printf 'app-id=com.example.app\nsm-verify=%s\nlease-dir=%s\nlease-ttl=%s\nqueue-ttl=%s\nbundle-port=%s\n' "$BIN/sm-verify" "$LEASE" "$ttl" "$qttl" "$(free_port)" >"$CONFIG/sbx-verify"
  LOG="$d/stub.log"
  : >"$LOG"
  export STUB_LOG="$LOG"
  unset STUB_EXIT
  task_dirs t1
}

task_dirs() { # <id>: sets TID REQ RES HOST for another task in the same world
  TID=$1
  "$BROKER" init --id "$TID" --state "$STATE" || fail "init"
  REQ="$STATE/$TID.sbx-verify/req"
  RES="$STATE/$TID.sbx-verify/res"
  HOST="$STATE/$TID.sbx-verify/host"
}

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

broker_once() { "$BROKER" run --id "$TID" --state "$STATE" --config "$CONFIG" --sandbox "sbx-$TID" --once; }

send() { # <n> <json>
  printf '%s' "$2" >"$REQ/.$1.tmp" && mv "$REQ/.$1.tmp" "$REQ/$1.json"
}

result() { cat "$RES/$1.json"; }
field() { result "$1" | jq -r "$2"; }
stub_calls() { grep -c '^argv:' "$LOG" || true; }

start_daemon() { # sets DPID
  PATH="$FAKEBIN:$PATH" "$BROKER" run --id "$TID" --state "$STATE" --config "$CONFIG" --sandbox "sbx-$TID" --interval 0.1 >/dev/null 2>&1 &
  DPID=$!
  DAEMONS+=("$DPID")
  local i
  for i in $(seq 1 50); do
    [ -f "$STATE/$TID.sbx-verify/host/broker.pid" ] && return 0
    sleep 0.1
  done
  fail "the broker did not start"
}

stop_daemon() {
  kill -TERM "$DPID" 2>/dev/null || true
  local i
  for i in $(seq 1 100); do
    kill -0 "$DPID" 2>/dev/null || return 0
    sleep 0.1
  done
  fail "the broker did not exit on TERM"
}

wait_result() { # <n>
  local i
  for i in $(seq 1 150); do
    [ -f "$RES/$1.json" ] && return 0
    sleep 0.1
  done
  fail "no result for request $1"
}

test_malformed_json_is_rejected() {
  new_world malformed
  send 1 '{"verb": "doctor"'
  broker_once
  assert_equals rejected "$(field 1 .status)" "malformed JSON is rejected"
  assert_equals malformed_json "$(field 1 .code)" "with the malformed_json code"
  assert_equals 0 "$(stub_calls)" "sm-verify was never run"
  pass "malformed JSON never reaches sm-verify"
}

test_oversize_request_is_rejected() {
  new_world oversize
  python3 -c 'import sys; sys.stdout.write("{\"verb\":\"doctor\",\"pad\":\"" + "x" * 70000 + "\"}")' >"$REQ/1.json"
  broker_once
  assert_equals request_too_large "$(field 1 .code)" "a request over 64 KiB is refused"
  assert_equals 0 "$(stub_calls)" "sm-verify was never run"
  pass "an oversize request is refused unread"
}

test_symlink_in_spool_is_not_followed() {
  new_world symlink
  printf '{"verb":"doctor"}' >"$TMP_ROOT/outside.json"
  ln -s "$TMP_ROOT/outside.json" "$REQ/1.json"
  mkfifo "$REQ/2.json"
  broker_once
  assert_equals not_regular "$(field 1 .code)" "a symlinked request is refused"
  assert_equals not_regular "$(field 2 .code)" "a FIFO request is refused and cannot hang the broker"
  assert_equals 0 "$(stub_calls)" "sm-verify was never run"
  pass "symlinks and special files in the spool are never read"
}

test_odd_names_are_ignored() {
  new_world names
  printf '{"verb":"doctor"}' >"$REQ/abc.json"
  printf '{"verb":"doctor"}' >"$REQ/1.json.bak"
  printf '{"verb":"doctor"}' >"$REQ/../escape.json"
  printf '{"verb":"doctor"}' >"$REQ/1234567890123.json"
  broker_once
  [ -z "$(ls "$RES")" ] || fail "nothing may be answered for odd names: $(ls "$RES")"
  assert_equals 0 "$(stub_calls)" "sm-verify was never run"
  pass "only <digits>.json names are processed"
}

test_unknown_verb_and_extra_keys_are_rejected() {
  new_world verbs
  send 1 '{"verb":"shell","cmd":"id"}'
  send 2 '{"verb":"doctor","extra":1}'
  send 3 '{"verb":"tab","name":"--help"}'
  send 4 '{"verb":"tab","name":"../x"}'
  broker_once
  assert_equals unknown_verb "$(field 1 .code)" "unknown verb"
  assert_equals bad_request "$(field 2 .code)" "extra key"
  assert_equals bad_request "$(field 3 .code)" "an option-looking tab name"
  assert_equals bad_request "$(field 4 .code)" "a path-looking tab name"
  assert_equals 0 "$(stub_calls)" "sm-verify was never run"
  pass "unknown verbs, extra keys and hostile tab names are rejected"
}

test_step_outside_allowlist_is_rejected() {
  new_world allowlist
  send 1 '{"verb":"do","step":{"wibble":{}}}'
  send 2 '{"verb":"do","step":{"tapOn":{"text":"Home","extra":"x"}}}'
  send 3 '{"verb":"flow","steps":[]}'
  send 4 '{"verb":"do","step":{"extendedWaitUntil":{"visible":{"text":"x"},"timeout":999999}}}'
  broker_once
  assert_equals bad_step "$(field 1 .code)" "an unknown op"
  assert_equals bad_step "$(field 2 .code)" "an unknown step key"
  assert_equals bad_request "$(field 3 .code)" "an empty flow"
  assert_equals bad_step "$(field 4 .code)" "an out-of-range timeout"
  assert_equals 0 "$(stub_calls)" "sm-verify was never run"
  pass "steps outside the allowlist are rejected"
}

test_flow_with_yaml_header_is_rejected() {
  new_world yamlhdr
  send 1 '{"verb":"flow","yaml":"appId: x\n---\n- runScript: evil.js"}'
  send 2 '{"verb":"flow","steps":[{"appId: x":{}}]}'
  send 3 '{"verb":"flow","steps":[{"tapOn":{"text":"Home\n---\n- runScript: evil.js"}}]}'
  send 4 '{"verb":"flow","steps":[{"takeScreenshot":{"name":"a\n- runScript: x"}}]}'
  send 5 '{"verb":"flow","appId":"other.app","steps":[{"back":{}}]}'
  broker_once
  for n in 1 2 3 4 5; do
    assert_equals rejected "$(field $n .status)" "request $n is rejected"
  done
  assert_equals 0 "$(stub_calls)" "sm-verify was never run"
  pass "a worker cannot supply YAML, a header or an appId"
}

test_forbidden_steps_are_rejected() {
  new_world forbidden
  local op n=0
  for op in inputText pressKey runScript evalScript runFlow openLink launchApp stopApp clearState clearKeychain addMedia copyTextFrom setLocation; do
    n=$((n + 1))
    send "$n" "{\"verb\":\"do\",\"step\":{\"$op\":\"hi\"}}"
  done
  send 20 '{"verb":"do","step":{"inputText":"hello"}}'
  send 21 '{"verb":"flow","steps":[{"back":{}},{"pressKey":"Enter"}]}'
  broker_once
  for i in $(seq 1 $n) 20 21; do
    assert_equals forbidden_step "$(field "$i" .code)" "request $i is a forbidden step"
  done
  assert_equals 0 "$(stub_calls)" "sm-verify was never run"
  pass "inputText, Enter and the other forbidden commands are rejected"
}

test_denylisted_selectors_are_rejected() {
  new_world deny
  local i=0 t
  for t in "Sign in" "Sign in with Google" "Continue with Apple" "LIKE" "Pass" "Send" "Join game" "Leave" "Cancel" "Create event" "Save" "Delete account" "Block" "Report" "Join waitlist" "Yes, I'm here" "Yes, I’m here" "No, I'm not" "sign-in" "Sign_in"; do
    i=$((i + 1))
    send "$i" "$(jq -nc --arg t "$t" '{verb:"do",step:{tapOn:{text:$t}}}')"
  done
  send 90 '{"verb":"do","step":{"tapOn":{"id":"btn-send"}}}'
  send 91 '{"verb":"tab","name":"Create"}'
  send 92 '{"verb":"flow","steps":[{"back":{}},{"tapOn":{"text":"Delete"}}]}'
  broker_once
  for n in $(seq 1 $i) 90 91 92; do
    assert_equals denied_selector "$(field "$n" .code)" "request $n names a denylisted selector"
  done
  assert_equals 0 "$(stub_calls)" "sm-verify was never run"
  pass "denylisted selectors are rejected, including tab names and punctuation variants"
}

test_allowed_steps_become_literal_yaml() {
  new_world yaml
  send 1 '{"verb":"flow","id":"f.1","steps":[{"tapOn":{"text":"Home (1)"}},{"assertVisible":{"text":"Games.*"}},{"swipe":{"direction":"UP"}},{"takeScreenshot":{"name":"home1"}}]}'
  broker_once
  assert_equals ok "$(field 1 .status)" "an allowed flow runs"
  assert_equals f.1 "$(field 1 .id)" "the id is echoed"
  local log
  log=$(cat "$LOG")
  assert_contains "$log" 'text: "Home \\(1\\)"' "selector regex characters are escaped to match literally"
  assert_contains "$log" 'text: "Games\\.\\*"' "an assertion selector is escaped too"
  assert_contains "$log" '- swipe:' "swipe is emitted"
  assert_contains "$log" 'appId: com.example.app' "the host config owns the appId"
  assert_not_contains "$log" runScript "no scripting command appears"
  assert_contains "$log" "$HOST/run/1/evidence/home1" "screenshots land in the per-request evidence directory"
  pass "allowed steps become a host-generated flow with literal selectors"
}

test_evidence_is_filtered_and_output_is_cleaned() {
  new_world evidence
  send 1 '{"verb":"shot","name":"a"}'
  send 2 '{"verb":"tree"}'
  broker_once
  assert_equals real.png "$(field 1 '.evidence | map(.name) | join(",")')" "only the real PNG is copied"
  assert_equals 2 "$(field 1 .evidence_skipped)" "the fake PNG and the symlink are skipped"
  head -c 8 "$RES/1/real.png" | grep -q PNG || fail "the copied file keeps its PNG header"
  [ ! -L "$RES/1/link.png" ] && [ ! -e "$RES/1/link.png" ] || fail "a symlinked evidence file must not appear"
  assert_equals "$(sha256sum "$RES/1/real.png" | cut -d' ' -f1)" "$(field 1 '.evidence[0].sha256')" "the reported digest matches the copy"
  assert_not_contains "$(field 2 .stdout)" $'\033' "escape bytes are stripped from text"
  assert_not_contains "$(field 2 .stdout)" $'\a' "bell bytes are stripped from text"
  assert_contains "$(field 2 .stdout)" "red" "the text itself survives"
  pass "evidence is limited to real PNG files and text is control-stripped"
}

test_results_are_written_only_by_the_host_and_atomically() {
  new_world atomic
  send 1 '{"verb":"doctor"}'
  broker_once
  [ -f "$RES/1.json" ] || fail "result written"
  [ -z "$(find "$RES" -mindepth 1 -maxdepth 1 -name '.*')" ] || fail "no temp file is left behind"
  jq -e '.v == 1 and .seq == 1 and .verb == "doctor" and .status == "ok" and .exit == 0' "$RES/1.json" >/dev/null || fail "result shape: $(cat "$RES/1.json")"
  [ "$(stat -c %a "$STATE/t1.sbx-verify/host")" = 700 ] || fail "the host directory is private"
  broker_once
  assert_equals 1 "$(stub_calls)" "a request is answered at most once"
  pass "results are atomic, complete and answered once"
}

test_failed_command_is_reported_not_hidden() {
  new_world failed
  export STUB_EXIT=3
  send 1 '{"verb":"doctor"}'
  broker_once
  assert_equals failed "$(field 1 .status)" "a nonzero exit is a failed result"
  assert_equals 3 "$(field 1 .exit)" "the exit code is reported"
  assert_equals command_failed "$(field 1 .code)" "with the command_failed code"
  unset STUB_EXIT
  pass "a failing sm-verify is reported faithfully"
}

test_rename_race_cannot_change_what_runs() {
  new_world race
  cat >"$TMP_ROOT/race-hook.sh" <<'SH'
#!/usr/bin/env bash
# post-copy: rewrite the worker's file into a forbidden request after the host copied it.
if [ "$1" = post-copy ]; then
  printf '{"verb":"do","step":{"inputText":"x"}}' >"$2"
fi
SH
  chmod +x "$TMP_ROOT/race-hook.sh"
  send 1 '{"verb":"doctor"}'
  FM_SBX_VERIFY_TEST_HOOK="$TMP_ROOT/race-hook.sh" broker_once
  assert_equals ok "$(field 1 .status)" "the validated copy is what runs"
  assert_contains "$(cat "$LOG")" 'argv: [doctor]' "the original request ran, not the rewrite"
  assert_equals 1 "$(stub_calls)" "exactly one command ran"

  cat >"$TMP_ROOT/race-hook2.sh" <<SH
#!/usr/bin/env bash
# pre-copy: swap the file for a symlink to a host file.
if [ "\$1" = pre-copy ]; then
  rm -f "\$2"
  ln -s /etc/hostname "\$2"
fi
SH
  chmod +x "$TMP_ROOT/race-hook2.sh"
  send 2 '{"verb":"doctor"}'
  FM_SBX_VERIFY_TEST_HOOK="$TMP_ROOT/race-hook2.sh" broker_once
  assert_equals not_regular "$(field 2 .code)" "a file swapped for a symlink before the copy is refused"
  assert_equals 1 "$(stub_calls)" "no further command ran"
  [ -z "$(find "$HOST/in" -mindepth 1 -maxdepth 1 ! -name '*.json' ! -name '*.plan')" ] || fail "unexpected files in the host copy directory"
  pass "a rename or symlink swap during the copy cannot change what runs"
}

test_no_worker_path_reaches_sm_verify() {
  new_world paths
  mkdir -p "$REQ/evil"
  printf '#!/bin/sh\ntouch %s/PWNED\n' "$TMP_ROOT" >"$REQ/sm-verify"
  chmod +x "$REQ/sm-verify"
  send 1 "{\"verb\":\"do\",\"step\":{\"tapOn\":{\"text\":\"/etc/shadow ../../x \$(id)\"}}}"
  send 2 '{"verb":"shot","name":"../../escape"}'
  send 3 '{"verb":"flow","steps":[{"takeScreenshot":{"name":"../../escape"}}]}'
  send 4 '{"verb":"doctor","sm-verify":"/bin/true","path":"/bin/true"}'
  broker_once
  assert_equals ok "$(field 1 .status)" "a selector is data, never a path"
  assert_equals bad_request "$(field 2 .code)" "a path-like shot name is rejected"
  assert_equals bad_step "$(field 3 .code)" "a path-like screenshot name is rejected"
  assert_equals bad_request "$(field 4 .code)" "extra keys naming a command are rejected"
  [ ! -e "$TMP_ROOT/PWNED" ] || fail "the spool's sm-verify must never be executed"
  [ ! -e "$TMP_ROOT/escape" ] || fail "no path escape"
  local line
  while IFS= read -r line; do
    case "$line" in
    "argv: [do] [$HOST/run/"*/flow.yaml\]) ;;
    *) fail "unexpected argv line: $line" ;;
    esac
  done < <(grep '^argv:' "$LOG")
  while IFS= read -r line; do
    case "$line" in
    "cwd: $HOST/run/"*) ;;
    *) fail "sm-verify must run in a host directory: $line" ;;
    esac
  done < <(grep '^cwd:' "$LOG")
  assert_not_contains "$(cat "$HOST/audit.log")" "$REQ" "the audit log never records the spool path as an argument"
  pass "no worker-supplied path or string reaches the sm-verify invocation"
}

test_config_refuses_a_worker_reachable_sm_verify() {
  new_world cfg
  mkdir -p "$STATE/t1.sbx-clone/bin"
  cp "$BIN/sm-verify" "$STATE/t1.sbx-clone/bin/sm-verify"
  printf 'app-id=com.example.app\nsm-verify=%s\n' "$STATE/t1.sbx-clone/bin/sm-verify" >"$CONFIG/sbx-verify"
  if "$BROKER" check --config "$CONFIG" --state "$STATE" 2>"$TMP_ROOT/cfg.err"; then fail "a clone path must be refused"; fi
  assert_contains "$(cat "$TMP_ROOT/cfg.err")" "host-owned" "the refusal explains itself"
  printf 'app-id=com.example.app\nsm-verify=%s\n' "$BIN/sm-verify" >"$CONFIG/sbx-verify"
  "$BROKER" check --config "$CONFIG" --state "$STATE" || fail "a host path passes"
  printf 'app-id=com.example.app\nsm-verify=%s\nsm-verify-sha256=%s\n' "$BIN/sm-verify" "$(printf 'a%.0s' $(seq 1 64))" >"$CONFIG/sbx-verify"
  if "$BROKER" check --config "$CONFIG" --state "$STATE" 2>/dev/null; then fail "a wrong pin must be refused"; fi
  printf 'sm-verify=%s\n' "$BIN/sm-verify" >"$CONFIG/sbx-verify"
  if "$BROKER" check --config "$CONFIG" --state "$STATE" 2>"$TMP_ROOT/cfg.err"; then fail "a missing app-id must be refused"; fi
  assert_contains "$(cat "$TMP_ROOT/cfg.err")" "app-id" "the refusal names app-id"
  printf 'app-id=bad id!\nsm-verify=%s\n' "$BIN/sm-verify" >"$CONFIG/sbx-verify"
  if "$BROKER" check --config "$CONFIG" --state "$STATE" 2>"$TMP_ROOT/cfg.err"; then fail "a malformed app-id must be refused"; fi
  assert_contains "$(cat "$TMP_ROOT/cfg.err")" "app-id" "the malformed refusal names app-id"
  rm -f "$CONFIG/sbx-verify"
  if "$BROKER" check --config "$CONFIG" --state "$STATE" 2>/dev/null; then fail "a missing config must be refused"; fi
  pass "the pinned sm-verify must be a host-owned file matching its digest"
}

test_a_changed_sm_verify_is_not_run() {
  new_world pin
  printf 'app-id=com.example.app\nsm-verify=%s\nsm-verify-sha256=%s\nlease-dir=%s\n' "$BIN/sm-verify" "$(sha256sum "$BIN/sm-verify" | cut -d' ' -f1)" "$LEASE" >"$CONFIG/sbx-verify"
  send 1 '{"verb":"doctor"}'
  broker_once
  assert_equals ok "$(field 1 .status)" "the pinned file runs"
  printf '\n# tampered\n' >>"$BIN/sm-verify"
  send 2 '{"verb":"doctor"}'
  "$BROKER" run --id t1 --state "$STATE" --config "$CONFIG" --sandbox s --once 2>/dev/null
  # the config check at start refuses the changed file
  [ ! -f "$RES/2.json" ] || [ "$(field 2 .status)" != ok ] || fail "a changed sm-verify must not run"
  assert_equals 1 "$(stub_calls)" "only the first call ran"
  pass "a modified sm-verify no longer runs"
}

test_status_verb_is_broker_local() {
  new_world status
  send 1 '{"verb":"status"}'
  broker_once
  assert_equals ok "$(field 1 .status)" "status answers"
  assert_equals none "$(field 1 .lease.holder)" "nobody holds the lease"
  assert_equals 0 "$(stub_calls)" "status never runs sm-verify"
  pass "status is answered by the broker without sm-verify or the lease"
}

test_two_clients_queue_and_hand_over() {
  new_world queue
  local a_req a_res
  task_dirs a
  a_req=$REQ a_res=$RES
  start_daemon
  local a_pid=$DPID
  printf '{"verb":"up"}' >"$a_req/1.json"
  RES=$a_res wait_result 1
  assert_equals ok "$(jq -r .status "$a_res/1.json")" "the first holder gets the emulator"

  task_dirs b
  send 1 '{"verb":"doctor"}'
  broker_once
  assert_equals queued "$(field 1 .status)" "a second holder is queued"
  assert_equals 1 "$(field 1 .position)" "at position one"
  assert_equals 1 "$(stub_calls)" "the queued request did not run"
  send 2 '{"verb":"status"}'
  broker_once
  assert_equals other "$(field 2 .lease.holder)" "status shows the lease is held by another task"

  printf '{"verb":"status"}' >"$a_req/2.json"
  RES=$a_res wait_result 2
  assert_equals you "$(jq -r .lease.holder "$a_res/2.json")" "the holder sees itself as the holder"
  assert_equals 1 "$(jq -r .lease.waiting "$a_res/2.json")" "and sees the task waiting behind it"
  printf '{"verb":"down"}' >"$a_req/3.json"
  RES=$a_res wait_result 3
  assert_equals ok "$(jq -r .status "$a_res/3.json")" "the first holder brings the emulator down"
  send 3 '{"verb":"doctor"}'
  broker_once
  assert_equals ok "$(field 3 .status)" "after the hand-over the second holder runs"
  DPID=$a_pid
  stop_daemon
  pass "a second client is queued and gets the emulator after the first lets go"
}

test_queue_is_fair_to_the_first_waiter() {
  new_world fair
  task_dirs a
  local a_req=$REQ a_res=$RES
  start_daemon
  local a_pid=$DPID
  printf '{"verb":"up"}' >"$a_req/1.json"
  RES=$a_res wait_result 1
  task_dirs b
  send 1 '{"verb":"doctor"}'
  broker_once
  sleep 1
  task_dirs c
  send 1 '{"verb":"doctor"}'
  broker_once
  assert_equals 2 "$(field 1 .position)" "the later waiter is second"
  printf '{"verb":"down"}' >"$a_req/2.json"
  RES=$a_res wait_result 2
  send 2 '{"verb":"doctor"}'
  broker_once
  assert_equals queued "$(field 2 .status)" "the later waiter cannot jump the queue"
  task_dirs b
  send 2 '{"verb":"doctor"}'
  broker_once
  assert_equals ok "$(field 2 .status)" "the first waiter gets the lease"
  DPID=$a_pid
  stop_daemon
  pass "waiters are served first come first served"
}

test_lease_expiry_forces_down() {
  new_world expiry 2
  start_daemon
  send 1 '{"verb":"up"}'
  wait_result 1
  assert_equals 1 "$(grep -c '^argv: \[up\]' "$LOG")" "up ran"
  local i
  for i in $(seq 1 100); do
    grep -q '^argv: \[down\]' "$LOG" && break
    sleep 0.1
  done
  grep -q '^argv: \[down\]' "$LOG" || fail "an idle lease must be ended with a forced down"
  for i in $(seq 1 50); do
    grep -q lease-release "$HOST/audit.log" && break
    sleep 0.1
  done
  assert_contains "$(cat "$HOST/audit.log")" lease-release "the release is audited"
  task_dirs other
  send 1 '{"verb":"doctor"}'
  broker_once
  assert_equals ok "$(field 1 .status)" "the lease is free for the next holder"
  task_dirs t1
  stop_daemon
  pass "an idle lease expires with a forced down"
}

test_activity_extends_the_lease() {
  new_world active 3
  start_daemon
  local n
  for n in 1 2 3 4; do
    send "$n" '{"verb":"up"}'
    wait_result "$n"
    sleep 1
  done
  ! grep -q '^argv: \[down\]' "$LOG" || fail "a lease with activity must not expire"
  stop_daemon
  grep -q '^argv: \[down\]' "$LOG" || fail "termination still takes the emulator down"
  pass "requests keep the lease alive"
}

test_teardown_while_holding_the_lease() {
  new_world teardown
  start_daemon
  send 1 '{"verb":"up"}'
  wait_result 1
  "$BROKER" stop --id t1 --state "$STATE" --config "$CONFIG" || fail "stop"
  kill -0 "$DPID" 2>/dev/null && fail "the broker must have exited"
  grep -q '^argv: \[down\]' "$LOG" || fail "stop must force the emulator down"
  assert_absent "$STATE/t1.sbx-verify/host/broker.pid" "the pid record is gone"
  task_dirs other
  send 1 '{"verb":"doctor"}'
  broker_once
  assert_equals ok "$(field 1 .status)" "the lease is free after teardown"
  pass "teardown while holding the lease forces the emulator down and frees it"
}

test_teardown_after_a_killed_broker_still_brings_it_down() {
  new_world killed
  start_daemon
  send 1 '{"verb":"up"}'
  wait_result 1
  kill -KILL "$DPID" 2>/dev/null
  wait "$DPID" 2>/dev/null || true
  "$BROKER" stop --id t1 --state "$STATE" --config "$CONFIG" || fail "stop"
  grep -q '^argv: \[down\]' "$LOG" || fail "stop must recover a killed broker's emulator"
  pass "stop recovers an emulator left up by a killed broker"
}

test_sandbox_removal_forces_down() {
  new_world gone
  cat >"$FAKEBIN/sbx" <<SH
#!/usr/bin/env bash
[ -e "$TMP_ROOT/gone/gone-flag" ] && exit 0
echo sbx-t1
SH
  chmod +x "$FAKEBIN/sbx"
  export FM_SBX_VERIFY_SANDBOX_POLL=1
  start_daemon
  send 1 '{"verb":"up"}'
  wait_result 1
  touch "$TMP_ROOT/gone/gone-flag"
  local i
  for i in $(seq 1 100); do
    kill -0 "$DPID" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$DPID" 2>/dev/null && fail "the broker must exit when its sandbox is gone"
  grep -q '^argv: \[down\]' "$LOG" || fail "a forced down must run when the sandbox is gone"
  unset FM_SBX_VERIFY_SANDBOX_POLL
  pass "removing the sandbox ends the lease with a forced down"
}

test_bundle_is_served_only_for_the_one_file() {
  new_world bundle
  printf 'BUNDLE-BYTES-%s' "$(printf 'z%.0s' $(seq 1 2000))" >"$REQ/index.bundle"
  printf 'secret' >"$REQ/other.txt"
  local port
  port=$(sed -n 's/^bundle-port=//p' "$CONFIG/sbx-verify")
  start_daemon
  send 1 '{"verb":"up","bundle":true}'
  wait_result 1
  assert_equals ok "$(field 1 .status)" "up with a bundle runs: $(cat "$RES/1.json")"
  assert_contains "$(cat "$LOG")" "env-url: http://127.0.0.1:$port/index.bundle" "sm-verify is told the broker URL"
  python3 - "$port" "$(sha256sum "$REQ/index.bundle" | cut -d' ' -f1)" <<'PY' || fail "bundle serving"
import hashlib, http.client, json, sys
port, digest = int(sys.argv[1]), sys.argv[2]
def call(method, path, headers=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.request(method, path, headers=headers or {})
    r = c.getresponse()
    return r.status, r.getheader("Content-Type"), r.read()
st, ct, body = call("HEAD", "/")
assert st == 200 and ct == "application/expo+json", (st, ct)
# the dev client asks / for a manifest whose launch asset is this server, under the Host it used
st, ct, body = call("GET", "/", {"Host": "172.28.1.2:%d" % port, "Accept": "application/expo+json", "expo-platform": "android"})
m = json.loads(body)
assert st == 200 and ct == "application/expo+json", (st, ct)
assert m["launchAsset"]["url"] == "http://172.28.1.2:%d/index.bundle" % port, m["launchAsset"]
assert m["runtimeVersion"].startswith("exposdk:") and m["extra"]["expoGo"]["developer"]["tool"] == "expo-cli", m
st, ct, body = call("GET", "/status")
assert st == 200 and body == b"packager-status:running", (st, body)
st, ct, body = call("GET", "/index.bundle?platform=android&dev=true")
assert st == 200 and hashlib.sha256(body).hexdigest() == digest
for method, path, hdrs in [("GET", "/", {"Host": "evil.example/x y"}), ("GET", "/", {"Host": "a b"}), ("GET", "/other.txt", {}),
                           ("GET", "/../etc/passwd", {}), ("GET", "/index.bundle/x", {}), ("GET", "/index.map", {}),
                           ("POST", "/index.bundle", {}), ("POST", "/", {}), ("POST", "/status", {}), ("HEAD", "/other.txt", {}),
                           ("GET", "/%2e%2e/etc/passwd", {}), ("PUT", "/index.bundle", {})]:
    st, ct, body = call(method, path, hdrs)
    assert st == 404, (method, path, st)
    assert b"secret" not in body
PY
  # the served bytes are a host copy: changing the worker's file changes nothing
  printf 'CHANGED' >"$REQ/index.bundle"
  assert_equals "$(sha256sum "$HOST/bundle/index.bundle" | cut -d' ' -f1)" "$(curl -s "http://127.0.0.1:$port/index.bundle" | sha256sum | cut -d' ' -f1)" "later edits to the spool file are not served"
  send 2 '{"verb":"status"}'
  wait_result 2
  assert_equals "$(sha256sum "$HOST/bundle/index.bundle" | cut -d' ' -f1)" "$(field 2 .bundle.sha256)" "status names the digest of the bundle being served"
  send 3 '{"verb":"down"}'
  wait_result 3
  assert_equals null "$(field 3 '.bundle_url // "null"')" "a down result no longer names a bundle URL"
  assert_equals "http://127.0.0.1:$port/index.bundle" "$(field 1 .bundle_url)" "an up result names the URL it serves"
  local i up=1
  for i in $(seq 1 30); do
    curl -s -m 1 -o /dev/null "http://127.0.0.1:$port/" || { up=0; break; }
    sleep 0.1
  done
  assert_equals 0 "$up" "the server stops with the lease"
  stop_daemon
  pass "exactly one bundle file is served, everything else is a plain 404"
}

test_down_that_exits_nonzero_still_ends_the_lease() {
  new_world downfail
  export STUB_EXIT=1
  start_daemon
  send 1 '{"verb":"doctor"}'
  wait_result 1
  assert_equals failed "$(field 1 .status)" "the stub fails, as sm-verify does with no run"
  send 2 '{"verb":"down"}'
  wait_result 2
  assert_equals failed "$(field 2 .status)" "a nonzero down is still reported as failed"
  send 3 '{"verb":"status"}'
  wait_result 3
  assert_equals none "$(field 3 .lease.holder)" "the lease is released anyway, so the next task is not kept waiting"
  stop_daemon
  unset STUB_EXIT
  pass "a down that exits nonzero still ends the lease"
}

test_bundle_must_be_a_regular_file() {
  new_world bundlebad
  ln -s /etc/hostname "$REQ/index.bundle"
  send 1 '{"verb":"up","bundle":true}'
  broker_once
  assert_equals bundle_not_regular "$(field 1 .code)" "a symlinked bundle is refused"
  rm -f "$REQ/index.bundle"
  send 2 '{"verb":"up","bundle":true}'
  broker_once
  assert_equals bundle_missing "$(field 2 .code)" "a missing bundle is reported"
  assert_equals 0 "$(grep -c '^argv: \[up\]' "$LOG")" "sm-verify up never ran"
  pass "the bundle must be one regular file"
}

test_every_request_is_audited() {
  new_world audit
  send 1 '{"verb":"doctor"}'
  send 2 '{"verb":"do","step":{"inputText":"x"}}'
  broker_once
  local log="$HOST/audit.log"
  [ "$(stat -c %a "$log")" != 777 ] || fail "audit log mode"
  assert_equals 2 "$(jq -s '[.[] | select(.kind == "request")] | length' "$log")" "both requests are audited"
  assert_equals rejected "$(jq -sr '[.[] | select(.kind == "request" and .seq == "2")][0].verdict' "$log")" "with their verdicts"
  jq -se 'all(.[]; .ts != null) and ([.[] | select(.kind == "request")] | all(.[]; (.req_sha256 // "") | length == 64))' "$log" >/dev/null || fail "every request line carries a digest and time"
  assert_contains "$(cat "$log")" smv_sha256 "the pinned command digest is recorded"
  [ -z "$(find "$RES" -mindepth 1 -maxdepth 1 ! -name '*.json')" ] || fail "only result files are left in the result directory"
  pass "every request, verdict and digest is appended to the host audit log"
}

test_default_run_is_unaffected_when_the_token_is_absent() {
  new_world absent
  local d="$TMP_ROOT/absent"
  printf 'sbx cpus=2\n' >"$d/worker-sandbox"
  # shellcheck source=bin/fm-sbx-lib.sh
  ( . "$ROOT/bin/fm-sbx-lib.sh"; fm_sbx_load_config "$d/worker-sandbox"; [ -z "$FM_SBX_VERIFY" ] ) || fail "verify is off by default"
  pass "without the token the sandbox config has no verification broker"
}

# ------------------------------------------------------------------- iOS ----
# The Mac is simulated locally: a stub ssh runs the remote command with sh -c
# against a fake sm-verify, so the exact remote command line is what is tested.

make_ssh_stub() { # <path>
  cat >"$1" <<'SH'
#!/usr/bin/env bash
opts=()
host='' cmd=''
while [ "$#" -gt 0 ]; do
  case "$1" in
  -o) opts+=("$2"); shift 2 ;;
  -T) shift ;;
  --) host=$2 cmd=$3; break ;;
  *) shift ;;
  esac
done
printf '%s\t%s\n' "$host" "$cmd" >>"$SSH_LOG"
printf '%s\n' "${opts[*]}" >>"$SSH_LOG.opts"
case "${STUB_SSH:-ok}" in
unreachable) echo "ssh: Could not resolve hostname $host: Name or service not known" >&2; exit 255 ;;
hostkey) printf '@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.\n' >&2; exit 255 ;;
auth) echo "$host: Permission denied (publickey)." >&2; exit 255 ;;
refused) echo "ssh: connect to host $host port 22: Connection refused" >&2; exit 255 ;;
hang) exec sleep 30 ;;
hang-run) case "$cmd" in *FM_SBX_VERIFY_EVIDENCE_DIR*) exec sleep 30 ;; esac ;;
esac
PATH="$MACBIN:$PATH" exec sh -c "$cmd"
SH
  chmod +x "$1"
}

# new_ios_world <name> [ttl]: an android world plus a Mac simulated under $MAC.
new_ios_world() {
  new_world "$1" "${2:-1200}"
  local d="$TMP_ROOT/$1"
  MAC="$d/mac"
  MACBIN="$d/macbin"
  SSH_LOG="$d/ssh.log"
  mkdir -p "$MAC/work" "$MACBIN"
  : >"$SSH_LOG"
  : >"$SSH_LOG.opts"
  printf '#!/bin/sh\nshift 2\nexec sha256sum "$@"\n' >"$MACBIN/shasum"
  chmod +x "$MACBIN/shasum"
  make_stub "$MAC/real-sm-verify"
  cat >"$MAC/sm-verify" <<SH
#!/usr/bin/env bash
echo "apple: \${SM_IOS_VERIFY_APPLE-unset}" >>"\$STUB_LOG"
"$MAC/real-sm-verify" "\$@"
rc=\$?
if [ "\${1:-}" = shot ] && [ -n "\${STUB_EVIDENCE_EXTRA:-}" ]; then
  d=\$FM_SBX_VERIFY_EVIDENCE_DIR
  for i in 1 2 3 4 5 6 7 8 9 10; do printf '\\x89PNG\\r\\n\\x1a\\nx' >"\$d/e\$i.png"; done
  printf '\\x89PNG\\r\\n\\x1a\\n' >"\$d/big.png"; head -c 6000000 /dev/zero >>"\$d/big.png"
  printf '\\x89PNG\\r\\n\\x1a\\nx' >"\$d/.hidden.png"
  printf '\\x89PNG\\r\\n\\x1a\\nx' >"\$d/bad name.png"
fi
exit \$rc
SH
  chmod +x "$MAC/sm-verify"
  MAC_SHA=$(sha256sum "$MAC/sm-verify" | cut -d' ' -f1)
  printf 'ios-host=fm-mac-worker\nios-sm-verify=%s\nios-sm-verify-sha256=%s\nios-app-id=com.example.ios\nios-work-dir=%s\n' "$MAC/sm-verify" "$MAC_SHA" "$MAC/work" >>"$CONFIG/sbx-verify"
  make_ssh_stub "$FAKEBIN/ssh"
  export SSH_LOG MACBIN
  unset STUB_SSH STUB_EVIDENCE_EXTRA
}

broker_once_ios() { PATH="$FAKEBIN:$PATH" broker_once; }
ssh_calls() { grep -c . "$SSH_LOG" || true; }

test_ios_needs_a_configured_host() {
  new_world iosoff
  send 1 '{"verb":"doctor","platform":"ios"}'
  send 2 '{"verb":"doctor","platform":"windows"}'
  send 3 '{"verb":"doctor","platform":"android"}'
  broker_once
  assert_equals rejected "$(field 1 .status)" "an iOS request without an iOS host is refused"
  assert_equals platform_unavailable "$(field 1 .code)" "with a typed code"
  assert_equals bad_request "$(field 2 .code)" "an unknown platform is a bad request"
  assert_equals ok "$(field 3 .status)" "an explicit android request runs as before"
  assert_equals false "$(field 3 'has("platform")')" "an android result is unchanged by the platform key"
  assert_equals 1 "$(stub_calls)" "only the android request reached sm-verify"
  pass "iOS requests are refused unless config/sbx-verify names an iOS host"
}

test_ios_reuses_the_validator() {
  new_ios_world iosval
  send 1 '{"verb":"do","platform":"ios","step":{"inputText":"hello"}}'
  send 2 '{"verb":"do","platform":"ios","step":{"tapOn":{"text":"Sign in"}}}'
  send 3 '{"verb":"do","platform":"ios","step":{"wibble":{}}}'
  send 4 '{"verb":"flow","platform":"ios","yaml":"appId: x"}'
  send 5 '{"verb":"tab","platform":"ios","name":"../x"}'
  send 6 '{"verb":"up","platform":"ios","bundle":true}'
  send 7 '{"verb":"shot","platform":"ios","name":"a;touch /tmp/x"}'
  send 8 '{"verb":"doctor","platform":"ios","extra":1}'
  broker_once_ios
  assert_equals forbidden_step "$(field 1 .code)" "inputText is forbidden on iOS too"
  assert_equals denied_selector "$(field 2 .code)" "the selector denylist applies on iOS"
  assert_equals bad_step "$(field 3 .code)" "the step allowlist applies on iOS"
  assert_equals bad_request "$(field 4 .code)" "a worker cannot supply YAML on iOS"
  assert_equals bad_request "$(field 5 .code)" "a path-looking tab name is refused"
  assert_equals bad_request "$(field 6 .code)" "a bundle is not served to the Mac"
  assert_equals bad_request "$(field 7 .code)" "a metacharacter in a name is refused"
  assert_equals bad_request "$(field 8 .code)" "an extra key is refused"
  assert_equals 0 "$(ssh_calls)" "no rejected request reached the Mac"
  assert_equals 0 "$(stub_calls)" "and none reached sm-verify"
  pass "iOS requests go through the same validator, allowlists and denylist"
}

test_ios_doctor_runs_the_pinned_command_on_the_mac() {
  new_ios_world iosdoc
  export SM_IOS_VERIFY_APPLE=1
  send 1 '{"verb":"doctor","platform":"ios"}'
  send 2 '{"verb":"tab","platform":"ios","name":"Games"}'
  broker_once_ios
  unset SM_IOS_VERIFY_APPLE
  assert_equals ok "$(field 1 .status)" "doctor runs: $(cat "$RES/1.json")"
  assert_equals ios "$(field 1 .platform)" "the result names its platform"
  assert_equals ok "$(field 2 .status)" "tab runs"
  local log
  log=$(cat "$LOG")
  assert_contains "$log" 'argv: [doctor]' "the Mac's sm-verify got the verb"
  assert_contains "$log" 'argv: [tab] [Games]' "and the validated name"
  assert_not_contains "$log" 'apple: 1' "the Apple verify account is never enabled"
  assert_contains "$log" 'apple: unset' "SM_IOS_VERIFY_APPLE is unset for the run"
  local calls
  calls=$(cat "$SSH_LOG")
  assert_contains "$calls" "$(printf "fm-mac-worker\t'shasum' '-a' '256' '%s'" "$MAC/sm-verify")" "the pin is checked first, on the configured alias"
  assert_contains "$calls" "'env' '-u' 'SM_IOS_VERIFY_APPLE' 'FM_SBX_VERIFY_EVIDENCE_DIR=" "the run unsets the Apple variable on the Mac"
  assert_contains "$calls" "'$MAC/sm-verify' 'tab' 'Games'" "every word is quoted once"
  local o
  o=$(head -n 1 "$SSH_LOG.opts")
  for o in BatchMode=yes StrictHostKeyChecking=yes ClearAllForwardings=yes ForwardAgent=no PermitLocalCommand=no RequestTTY=no ConnectTimeout=10; do
    assert_contains "$(cat "$SSH_LOG.opts")" "$o" "ssh is run with $o"
  done
  assert_equals "" "$(ls "$MAC/work")" "the per-request directory on the Mac is removed"
  pass "an iOS verb runs the pinned command on the Mac, never with the Apple account"
}

test_ios_flow_is_generated_on_the_host_and_evidence_is_filtered() {
  new_ios_world iosflow
  send 1 '{"verb":"flow","platform":"ios","steps":[{"tapOn":{"text":"Home (1)"}},{"takeScreenshot":{"name":"home1"}}]}'
  broker_once_ios
  assert_equals ok "$(field 1 .status)" "an allowed flow runs: $(cat "$RES/1.json")"
  local log
  log=$(cat "$LOG")
  assert_contains "$log" 'appId: com.example.ios' "ios-app-id is the app id"
  assert_contains "$log" 'text: "Home \\(1\\)"' "selectors are still escaped to match literally"
  assert_contains "$log" "$MAC/work/" "screenshots land in the Mac's per-request directory"
  assert_not_contains "$log" "$HOST" "no host path leaks into the Mac flow"
  assert_equals 1 "$(field 1 '.evidence | length')" "only the valid PNG is returned"
  assert_equals real.png "$(field 1 '.evidence[0].name')" "and it is the real one"
  assert_equals 1 "$(field 1 .evidence_skipped)" "the fake PNG is counted as skipped"
  [ ! -e "$RES/1/fake.png" ] && [ ! -e "$RES/1/link.png" ] || fail "invalid evidence reached res/"
  assert_equals "" "$(ls "$MAC/work")" "the per-request directory on the Mac is removed"
  pass "iOS flows are generated on the host and evidence is checked like Android's"
}

test_ios_evidence_limits_hold_over_ssh() {
  new_ios_world iosev
  export STUB_EVIDENCE_EXTRA=1
  send 1 '{"verb":"shot","platform":"ios"}'
  broker_once_ios
  unset STUB_EVIDENCE_EXTRA
  assert_equals ok "$(field 1 .status)" "shot runs"
  local n
  n=$(field 1 '.evidence | length')
  [ "$n" -le 8 ] || fail "at most 8 files may come back, got $n"
  [ ! -e "$RES/1/.hidden.png" ] && [ ! -e "$RES/1/bad name.png" ] && [ ! -e "$RES/1/big.png" ] || fail "hidden, oddly named or oversize files came back: $(ls -a "$RES/1")"
  local f
  for f in "$RES/1"/*; do
    [ "$(head -c 4 "$f" | tail -c 3)" = PNG ] || fail "$f is not a PNG"
    [ "$(stat -c %s "$f")" -le 5242880 ] || fail "$f is over 5 MiB"
  done
  local sk
  sk=$(field 1 .evidence_skipped)
  [ "$sk" -ge 3 ] || fail "skipped files must be counted, got $sk"
  pass "evidence from the Mac keeps the count, size, name and PNG limits"
}

test_ios_remote_words_are_quoted_exactly_once() {
  local out marker="$TMP_ROOT/quote-marker" cmd
  rm -f "$marker"
  # shellcheck source=bin/fm-sbx-verify-lib.sh
  . "$ROOT/bin/fm-sbx-verify-lib.sh"
  # shellcheck disable=SC2016
  local -a words=("plain" "two words" "it's" ";touch $marker" '$(touch '"$marker"')' '`touch '"$marker"'`' "&& touch $marker" "| cat" ".." "../x" "*" "-n" "a\\b" '"q"' "~" "{a,b}" "!" "#c")
  cmd=$(fm_sbxv_remote_cmd printf '%s|' "${words[@]}") || fail "quoting failed"
  out=$(sh -c "$cmd")
  local want
  want=$(printf '%s|' "${words[@]}")
  assert_equals "$want" "$out" "every word survives the remote shell as one argument"
  [ ! -e "$marker" ] || fail "an injected command ran"
  local bad
  for bad in $'a\nb' $'a\tb' $'a\rb' ''; do
    fm_sbxv_remote_cmd printf "$bad" >/dev/null 2>&1 && fail "a control byte or empty word must be refused: $(printf %q "$bad")"
  done
  fm_sbxv_remote_cmd >/dev/null 2>&1 && fail "an empty command must be refused"
  pass "the remote command quotes every word once and refuses control bytes"
}

test_ios_remote_path_checks() {
  # shellcheck source=bin/fm-sbx-verify-lib.sh
  . "$ROOT/bin/fm-sbx-verify-lib.sh"
  local ok bad
  for ok in /opt/sm-verify /Users/w/bin/sm-verify.sh /tmp/fm-sbx-verify; do
    fm_sbxv_remote_path_ok "$ok" || fail "$ok must be accepted"
  done
  # shellcheck disable=SC2016
  for bad in relative/path /a/../b /a//b /a/ "/a b" '/a;b' '/a$b' "/a'b" '' / $'/a\nb'; do
    fm_sbxv_remote_path_ok "$bad" && fail "$(printf %q "$bad") must be refused"
  done
  pass "Mac paths are absolute, plain and free of dot-dot segments"
}

test_ios_config_grammar() {
  new_ios_world iosconf
  "$BROKER" check --config "$CONFIG" --state "$STATE" || fail "a complete iOS config is accepted"
  local good="$CONFIG/sbx-verify.good" err
  cp "$CONFIG/sbx-verify" "$good"
  refuse() { # <expected-substring> <description> <sed-script>
    sed "$3" "$good" >"$CONFIG/sbx-verify"
    if err=$("$BROKER" check --config "$CONFIG" --state "$STATE" 2>&1); then
      fail "must be refused: $2"
    fi
    assert_contains "$err" "$1" "the refusal names the problem: $2"
  }
  refuse ios-host "an alias that starts with a dash" 's#^ios-host=.*#ios-host=-oProxyCommand=x#'
  refuse ios-host "an alias with a space" 's#^ios-host=.*#ios-host=a b#'
  refuse 'without ios-host' "ios keys without the host" '/^ios-host=/d'
  refuse ios-sm-verify-sha256 "a host without its pin" '/^ios-sm-verify-sha256=/d'
  refuse ios-sm-verify "a host without its command" '/^ios-sm-verify=/d'
  refuse ios-sm-verify "a relative Mac path" 's#^ios-sm-verify=.*#ios-sm-verify=relative/sm-verify#'
  refuse ios-sm-verify "a dot-dot Mac path" 's#^ios-sm-verify=.*#ios-sm-verify=/opt/../etc/x#'
  refuse ios-sm-verify-sha256 "a short pin" 's#^ios-sm-verify-sha256=.*#ios-sm-verify-sha256=abc#'
  refuse ios-work-dir "a work dir with a metacharacter" 's#^ios-work-dir=.*#ios-work-dir=/tmp/a;b#'
  cp "$good" "$CONFIG/sbx-verify"
  pass "the iOS config keys are validated and need each other"
}

test_ios_checksum_mismatch_is_not_run() {
  new_ios_world ioschk
  printf '\n# changed\n' >>"$MAC/sm-verify"
  send 1 '{"verb":"doctor","platform":"ios"}'
  broker_once_ios
  assert_equals error "$(field 1 .status)" "a changed Mac command is an error"
  assert_equals sm_verify_changed "$(field 1 .code)" "with the changed code"
  assert_equals ios "$(field 1 .platform)" "naming the platform"
  assert_equals 0 "$(stub_calls)" "sm-verify was never run"
  assert_equals 1 "$(ssh_calls)" "nothing but the checksum reached the Mac"
  rm -f "$MAC/sm-verify"
  send 2 '{"verb":"doctor","platform":"ios"}'
  broker_once_ios
  assert_equals sm_verify_missing "$(field 2 .code)" "a missing Mac command is typed"
  assert_equals 0 "$(stub_calls)" "and still nothing ran"
  pass "a Mac command that does not match its pin is never run"
}

test_ios_ssh_failures_are_typed_and_never_fall_back() {
  new_ios_world iosfail
  local mode code n=0
  for pair in unreachable:mac_unreachable hostkey:ssh_host_key auth:ssh_auth refused:ssh_refused; do
    mode=${pair%%:*} code=${pair##*:}
    n=$((n + 1))
    export STUB_SSH=$mode
    send "$n" '{"verb":"doctor","platform":"ios"}'
    broker_once_ios
    assert_equals error "$(field "$n" .status)" "$mode is an error, not a hang"
    assert_equals "$code" "$(field "$n" .code)" "$mode is typed as $code"
    assert_equals ios "$(field "$n" .platform)" "$mode names the platform"
  done
  unset STUB_SSH
  assert_equals 0 "$(stub_calls)" "nothing ran locally or on the Mac"
  send 9 '{"verb":"doctor","platform":"ios"}'
  broker_once_ios
  assert_equals ok "$(field 9 .status)" "the next request works once ssh does"
  pass "SSH failures are typed errors and never fall back to a local run"
}

test_ios_timeouts() {
  new_ios_world iostime
  export FM_SBX_VERIFY_TIMEOUT=2
  export STUB_SSH=hang
  send 1 '{"verb":"doctor","platform":"ios"}'
  broker_once_ios
  assert_equals error "$(field 1 .status)" "a hung ssh during the check is an error"
  assert_equals timeout "$(field 1 .code)" "typed as a timeout"
  export STUB_SSH=hang-run
  send 2 '{"verb":"doctor","platform":"ios"}'
  broker_once_ios
  assert_equals failed "$(field 2 .status)" "a run that outlives its limit is failed"
  assert_equals timeout "$(field 2 .code)" "typed as a timeout"
  assert_equals 124 "$(field 2 .exit)" "with the timeout exit status"
  unset STUB_SSH FM_SBX_VERIFY_TIMEOUT
  pass "each phase has its own time limit and a hung ssh cannot hold the broker"
}

test_ios_lease_is_separate_from_android() {
  new_ios_world ioslease
  task_dirs a
  local a_req=$REQ a_res=$RES
  start_daemon
  local a_pid=$DPID
  printf '{"verb":"up"}' >"$a_req/1.json"
  RES=$a_res wait_result 1
  task_dirs b
  start_daemon
  local b_pid=$DPID
  send 1 '{"verb":"up","platform":"ios"}'
  wait_result 1
  assert_equals ok "$(field 1 .status)" "an iOS run is not blocked by the Android holder"
  send 2 '{"verb":"doctor"}'
  wait_result 2
  assert_equals queued "$(field 2 .status)" "but an Android request from that task still queues behind the Android holder"
  assert_equals false "$(field 2 'has("platform")')" "the android reply carries no platform"
  send 3 '{"verb":"status","platform":"ios"}'
  wait_result 3
  assert_equals you "$(field 3 .lease.holder)" "status for iOS names this task as holder"
  assert_equals ios "$(field 3 .platform)" "status says which lease it describes"
  assert_equals null "$(field 3 '.bundle')" "and there is no bundle for iOS"
  task_dirs c
  send 1 '{"verb":"doctor","platform":"ios"}'
  send 2 '{"verb":"status","platform":"ios"}'
  broker_once_ios
  assert_equals queued "$(field 1 .status)" "a third task queues for iOS"
  assert_equals busy "$(field 1 .code)" "as busy"
  assert_equals ios "$(field 1 .platform)" "and the queue reply names the platform"
  assert_equals other "$(field 2 .lease.holder)" "status sees the other iOS holder"
  DPID=$b_pid
  stop_daemon
  DPID=$a_pid
  stop_daemon
  pass "iOS has its own lease, queue and status, apart from Android"
}

ios_wait_down() { # <min-count>
  local i
  for i in $(seq 1 100); do
    [ "$(grep -c '^argv: \[down\]' "$LOG")" -ge "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

test_ios_teardown_sends_down_and_frees_the_lease() {
  new_ios_world iosdown
  PATH="$FAKEBIN:$PATH" start_daemon
  send 1 '{"verb":"up","platform":"ios"}'
  wait_result 1
  assert_equals ok "$(field 1 .status)" "iOS up runs"
  PATH="$FAKEBIN:$PATH" "$BROKER" stop --id t1 --state "$STATE" --config "$CONFIG" || fail "stop"
  kill -0 "$DPID" 2>/dev/null && fail "the broker must have exited"
  grep -q '^argv: \[down\]' "$LOG" || fail "stop must send down to the Mac"
  grep -q "'down'" "$SSH_LOG" || fail "the down went over ssh"
  task_dirs other
  send 1 '{"verb":"doctor","platform":"ios"}'
  broker_once_ios
  assert_equals ok "$(field 1 .status)" "the iOS lease is free after teardown"
  pass "teardown while holding the iOS lease sends down and frees it"
}

test_ios_killed_broker_and_vanished_sandbox_and_expiry_send_down() {
  new_ios_world ioskill
  PATH="$FAKEBIN:$PATH" start_daemon
  send 1 '{"verb":"up","platform":"ios"}'
  wait_result 1
  kill -KILL "$DPID" 2>/dev/null
  wait "$DPID" 2>/dev/null || true
  PATH="$FAKEBIN:$PATH" "$BROKER" stop --id t1 --state "$STATE" --config "$CONFIG" || fail "stop"
  ios_wait_down 1 || fail "stop must recover a killed broker's iOS simulator"

  new_ios_world iosgone
  cat >"$FAKEBIN/sbx" <<SH
#!/usr/bin/env bash
[ -e "$TMP_ROOT/iosgone/gone-flag" ] && exit 0
echo sbx-t1
SH
  chmod +x "$FAKEBIN/sbx"
  export FM_SBX_VERIFY_SANDBOX_POLL=1
  PATH="$FAKEBIN:$PATH" start_daemon
  send 1 '{"verb":"up","platform":"ios"}'
  wait_result 1
  touch "$TMP_ROOT/iosgone/gone-flag"
  local i
  for i in $(seq 1 100); do
    kill -0 "$DPID" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$DPID" 2>/dev/null && fail "the broker must exit when its sandbox is gone"
  unset FM_SBX_VERIFY_SANDBOX_POLL
  ios_wait_down 1 || fail "a vanished sandbox must send down to the Mac"

  new_ios_world iosexp 2
  PATH="$FAKEBIN:$PATH" start_daemon
  send 1 '{"verb":"up","platform":"ios"}'
  wait_result 1
  ios_wait_down 1 || fail "an idle iOS lease must end with down"
  stop_daemon
  pass "a killed broker, a vanished sandbox and an idle lease all send down to the Mac"
}

test_ios_audit_names_the_platform() {
  new_ios_world iosaudit
  send 1 '{"verb":"doctor","platform":"ios"}'
  send 2 '{"verb":"doctor"}'
  broker_once_ios
  local log="$HOST/audit.log"
  assert_equals ios "$(jq -sr '[.[] | select(.kind == "exec" and .seq == "1")][0].platform' "$log")" "iOS execution is audited with its platform"
  assert_equals null "$(jq -sr '[.[] | select(.kind == "exec" and .seq == "2")][0].platform' "$log")" "Android lines are unchanged"
  pass "the audit log says which platform each request used"
}


test_malformed_json_is_rejected
test_oversize_request_is_rejected
test_symlink_in_spool_is_not_followed
test_odd_names_are_ignored
test_unknown_verb_and_extra_keys_are_rejected
test_step_outside_allowlist_is_rejected
test_flow_with_yaml_header_is_rejected
test_forbidden_steps_are_rejected
test_denylisted_selectors_are_rejected
test_allowed_steps_become_literal_yaml
test_evidence_is_filtered_and_output_is_cleaned
test_results_are_written_only_by_the_host_and_atomically
test_failed_command_is_reported_not_hidden
test_rename_race_cannot_change_what_runs
test_no_worker_path_reaches_sm_verify
test_config_refuses_a_worker_reachable_sm_verify
test_a_changed_sm_verify_is_not_run
test_status_verb_is_broker_local
test_two_clients_queue_and_hand_over
test_queue_is_fair_to_the_first_waiter
test_lease_expiry_forces_down
test_activity_extends_the_lease
test_teardown_while_holding_the_lease
test_teardown_after_a_killed_broker_still_brings_it_down
test_sandbox_removal_forces_down
test_bundle_is_served_only_for_the_one_file
test_down_that_exits_nonzero_still_ends_the_lease
test_bundle_must_be_a_regular_file
test_every_request_is_audited
test_default_run_is_unaffected_when_the_token_is_absent
test_ios_needs_a_configured_host
test_ios_reuses_the_validator
test_ios_doctor_runs_the_pinned_command_on_the_mac
test_ios_flow_is_generated_on_the_host_and_evidence_is_filtered
test_ios_evidence_limits_hold_over_ssh
test_ios_remote_words_are_quoted_exactly_once
test_ios_remote_path_checks
test_ios_config_grammar
test_ios_checksum_mismatch_is_not_run
test_ios_ssh_failures_are_typed_and_never_fall_back
test_ios_timeouts
test_ios_lease_is_separate_from_android
test_ios_teardown_sends_down_and_frees_the_lease
test_ios_killed_broker_and_vanished_sandbox_and_expiry_send_down
test_ios_audit_names_the_platform

echo "# all fm-sbx-verify-broker tests passed"
