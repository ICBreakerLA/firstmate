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
# connection. curl.delay makes it a slow server; the request's own --max-time
# still wins, exiting the way curl does when the bound lapses.
cat >"$FAKEBIN/curl" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$TMP_ROOT/curl.log"
max= prev=
for a in "\$@"; do
  case "\$prev" in --max-time|-m) max=\$a ;; esac
  prev=\$a
done
if [ -f "$TMP_ROOT/curl.delay" ]; then
  delay=\$(cat "$TMP_ROOT/curl.delay")
  if [ -n "\$max" ] && [ "\$delay" -gt "\$max" ]; then
    exit 28
  fi
  sleep "\$delay"
fi
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

test_health_uses_the_default_timeout_and_an_override() {
  : >"$TMP_ROOT/curl.log"
  rm -f "$TMP_ROOT/curl.delay"
  printf '{"data":[{"id":"qwen3.8-27b-gsq-rco"}]}\n' >"$TMP_ROOT/models.json"
  fm_local_llm_health || fail "a healthy server must pass with the default bound"
  assert_contains "$(tail -n 1 "$TMP_ROOT/curl.log")" "--max-time 5" "the pre-launch check defaults to 5 seconds"
  FM_LOCAL_LLM_HEALTH_TIMEOUT=9 fm_local_llm_health || fail "a healthy server must pass with an override"
  assert_contains "$(tail -n 1 "$TMP_ROOT/curl.log")" "--max-time 9" "the override sets the bound"
  pass "the health check uses 5 seconds by default and honours the override"
}

test_health_refuses_an_invalid_timeout() {
  local out t
  : >"$TMP_ROOT/curl.log"
  rm -f "$TMP_ROOT/curl.delay"
  printf '{"data":[{"id":"qwen3.8-27b-gsq-rco"}]}\n' >"$TMP_ROOT/models.json"
  for t in 0 00 fast 2.5 -1; do
    out=$(FM_LOCAL_LLM_HEALTH_TIMEOUT="$t" fm_local_llm_health 2>&1) && fail "the bound '$t' must be refused"
    assert_contains "$out" "FM_LOCAL_LLM_HEALTH_TIMEOUT must be a positive whole number of seconds, not '$t'" "the refusal names the bad value '$t'"
  done
  assert_equals "" "$(cat "$TMP_ROOT/curl.log")" "an invalid bound makes no request"
  pass "an invalid health bound is refused before any request"
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
  assert_contains "$env" "CLAUDE_CODE_AUTO_COMPACT_WINDOW=130000" "auto-compact sits under the 131,072 context"
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
# The brief settle lets the holder's cat reach the FIFO first: an open/close
# before the cat opens is a transient writer the cat never sees, and the cat
# would then block on its own open forever.
end_holder() {
  sleep 0.2
  exec 6<>"$FM_LOCAL_LLM_LOCK.handoff"
  exec 6>&-
}

# release_gone: 0 only when a released claim left no lock file and no FIFO.
release_gone() {
  [ ! -e "$FM_LOCAL_LLM_LOCK" ] || fail "a released claim must remove the lock file"
  [ ! -e "$FM_LOCAL_LLM_LOCK.handoff" ] || fail "a released claim must remove the handoff FIFO"
}

# release_bg <task-id> <prefix>: run a release in a background subshell so a
# test can act inside its probe and flock windows; $RELEASE_BG is the running
# release, and <prefix>.rc/.out/.err collect its verdict once waited.
release_bg() {
  local id=$1 pre=$2
  (
    fm_local_llm_release "$id" >"$TMP_ROOT/$pre.out" 2>"$TMP_ROOT/$pre.err"
    echo $? >"$TMP_ROOT/$pre.rc"
  ) &
  RELEASE_BG=$!
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

test_a_matching_claim_is_released_and_the_slot_is_claimable_again() {
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  assert_equals "$FM_LOCAL_LLM_HOLDER $(fm_local_llm_proc_start "$FM_LOCAL_LLM_HOLDER")" "$(sed -n 2p "$FM_LOCAL_LLM_LOCK")" "the claim persists its holder's pid beside its start time on the lock file's second line"
  fm_local_llm_claim task-b 2>/dev/null && fail "the claim must refuse a second task until it is released"
  fm_local_llm_release task-a || fail "releasing this task's own claim must succeed"
  wait "$FM_LOCAL_LLM_HOLDER" 2>/dev/null || true
  ! kill -0 "$FM_LOCAL_LLM_HOLDER" 2>/dev/null || fail "the release must end the persisted holder"
  release_gone
  lock_free || fail "a released claim must free the flock"
  fm_local_llm_claim task-b || fail "the slot must be claimable by the next task after a release"
  assert_equals "task-b" "$(head -n 1 "$FM_LOCAL_LLM_LOCK")" "the next task's claim names it"
  end_holder
  lock_free || fail "the next claim must end cleanly"
  pass "a release ends the holder, removes the claim, and frees the slot for the next task"
}

test_release_leaves_another_tasks_claim_running() {
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  fm_local_llm_release task-b || fail "releasing another task's claim must succeed as a no-op"
  assert_equals "task-a" "$(head -n 1 "$FM_LOCAL_LLM_LOCK")" "the other task's claim must keep its name"
  kill -0 "$FM_LOCAL_LLM_HOLDER" 2>/dev/null || fail "a release must never kill a running claim's holder"
  fm_local_llm_claim task-b 2>/dev/null && fail "the running claim must still refuse a second task"
  fm_local_llm_release task-a || fail "releasing the matching claim must succeed"
  wait "$FM_LOCAL_LLM_HOLDER" 2>/dev/null || true
  release_gone
  lock_free || fail "the released claim must free the flock"
  pass "a release leaves another task's running claim untouched"
}

test_releasing_no_claim_is_a_clean_noop() {
  # A lock_free probe opens the lock file with create, so the test sets up
  # its own absence first.
  rm -f "$FM_LOCAL_LLM_LOCK" "$FM_LOCAL_LLM_LOCK.handoff"
  fm_local_llm_release task-none || fail "releasing with no claim file must succeed"
  [ ! -e "$FM_LOCAL_LLM_LOCK" ] || fail "a no-op release must not create the lock file"
  [ ! -e "$FM_LOCAL_LLM_LOCK.handoff" ] || fail "a no-op release must not create the handoff FIFO"
  pass "a release with no claim file is a clean no-op"
}

test_release_is_safe_to_call_twice() {
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  fm_local_llm_release task-a || fail "the first release must succeed"
  wait "$FM_LOCAL_LLM_HOLDER" 2>/dev/null || true
  fm_local_llm_release task-a || fail "a second release must succeed"
  release_gone
  lock_free || fail "the slot must stay free"
  pass "calling a release twice succeeds"
}

test_a_claim_left_by_a_dead_holder_is_cleaned_up() {
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  kill "$FM_LOCAL_LLM_HOLDER" 2>/dev/null || true
  wait "$FM_LOCAL_LLM_HOLDER" 2>/dev/null || true
  [ -e "$FM_LOCAL_LLM_LOCK" ] || fail "a dead holder leaves the claim file in place"
  fm_local_llm_release task-a || fail "a release must clean a claim left by a dead holder"
  release_gone
  lock_free || fail "the flock must be free"
  fm_local_llm_claim task-b || fail "the cleaned slot must be claimable"
  end_holder
  lock_free || fail "the next claim must end cleanly"
  pass "a release cleans the leftover file and FIFO of a claim whose holder is gone"
}

test_a_live_recorded_pid_that_is_not_the_holder_is_never_killed() {
  sleep 30 &
  local victim=$!
  printf 'task-a\n%s %s\n' "$victim" "$(fm_local_llm_proc_start "$victim")" >"$FM_LOCAL_LLM_LOCK"
  rm -f "$FM_LOCAL_LLM_LOCK.handoff"
  mkfifo -m 600 "$FM_LOCAL_LLM_LOCK.handoff"
  fm_local_llm_release task-a || fail "releasing a stale claim must succeed"
  kill -0 "$victim" 2>/dev/null || fail "a release must never kill an unrelated process holding the recorded pid"
  release_gone
  lock_free || fail "the slot must be free"
  fm_local_llm_claim task-b || fail "the slot must be claimable after the stale claim is removed"
  kill "$FM_LOCAL_LLM_HOLDER" 2>/dev/null || true
  wait "$FM_LOCAL_LLM_HOLDER" 2>/dev/null || true
  kill "$victim" 2>/dev/null || true
  wait "$victim" 2>/dev/null || true
  pass "a live pid recorded with its identity is killed only on its holder command line: this one is removed, never killed"
}

test_a_zombie_holder_is_treated_as_gone() {
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  local holder=$FM_LOCAL_LLM_HOLDER
  kill "$holder" 2>/dev/null || true
  kill -0 "$holder" 2>/dev/null || fail "the killed holder must remain a zombie for this test to be meaningful"
  fm_local_llm_release task-a || fail "a release must clean a claim whose holder is a zombie"
  release_gone
  lock_free || fail "a zombied holder must not keep the flock held"
  fm_local_llm_claim task-b || fail "the slot must be claimable"
  end_holder
  lock_free || fail "the next claim must end cleanly"
  wait "$holder" 2>/dev/null || true
  pass "a zombie of the recorded pid is treated as gone: the claim is removed, never held"
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

test_a_worker_running_on_the_handoff_is_never_released() {
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  (
    exec 5<>"$FM_LOCAL_LLM_LOCK.handoff"
    sleep 30
  ) &
  local wrapper=$!
  sleep 0.3
  fm_local_llm_release task-a && fail "a release must refuse while the task's worker is on the handoff"
  [ -e "$FM_LOCAL_LLM_LOCK" ] || fail "a refused release must leave the claim file in place"
  assert_equals "task-a" "$(head -n 1 "$FM_LOCAL_LLM_LOCK")" "the claim must keep its name"
  kill -0 "$FM_LOCAL_LLM_HOLDER" 2>/dev/null || fail "a refused release must not end the holder"
  fm_local_llm_claim task-b 2>/dev/null && fail "the live claim must still refuse a second task"
  kill "$wrapper" 2>/dev/null || true
  wait "$wrapper" 2>/dev/null || true
  end_holder
  lock_free || fail "the claim must free the slot once its worker is gone"
  fm_local_llm_release task-a || fail "the release must succeed after the worker ends"
  release_gone
  pass "a release refuses while the task's worker is on the handoff and succeeds once that worker has ended"
}

test_a_process_holding_the_lock_file_open_is_not_the_holder() {
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  local holder=$FM_LOCAL_LLM_HOLDER
  (
    exec 7<"$FM_LOCAL_LLM_LOCK"
    sleep 30
  ) &
  local bystander=$!
  sleep 0.3
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  lock_free || fail "the ended holder must release the flock"
  # A claim whose recorded pid names a live host process that merely has the
  # lock file open on a descriptor: no holder command line, and no start time
  # recorded to prove the pid is the process the claim named. The release
  # signals nothing, leaves the claim in place, and reports the slot held.
  printf 'task-a\n%s\n' "$bystander" >"$FM_LOCAL_LLM_LOCK"
  local out rc
  out=$(fm_local_llm_release task-a 2>&1)
  rc=$?
  expect_code 1 "$rc" "a release must refuse to signal a live pid whose claim records no start time"
  assert_contains "$out" "$bystander" "the refusal names the pid it refused to signal"
  assert_contains "$out" "left the claim in place" "the refusal says the claim stays claimed"
  kill -0 "$bystander" 2>/dev/null || fail "a live process holding the lock file open must never be signaled"
  [ -e "$FM_LOCAL_LLM_LOCK" ] || fail "a refused release must leave the claim file in place"
  assert_equals "task-a" "$(head -n 1 "$FM_LOCAL_LLM_LOCK")" "the claim must keep its name"
  assert_equals "$bystander" "$(sed -n 2p "$FM_LOCAL_LLM_LOCK")" "the refusal must leave the recorded pid intact"
  kill "$bystander" 2>/dev/null || true
  wait "$bystander" 2>/dev/null || true
  fm_local_llm_release task-a || fail "the release must clean the claim once the recorded pid is gone"
  release_gone
  lock_free || fail "the slot must be free"
  fm_local_llm_claim task-b || fail "the slot must be claimable"
  end_holder
  lock_free || fail "the next claim must end cleanly"
  pass "a release signals nothing for a live pid that is not its recorded holder, and cleans the claim once that pid is gone"
}

test_a_claim_without_a_persisted_pid_is_ended_through_the_handoff() {
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  local holder=$FM_LOCAL_LLM_HOLDER
  # The shape of claims made before holder pids were persisted: the live
  # holder is blocked at the handoff and no pid names it.
  printf 'task-a\n' >"$FM_LOCAL_LLM_LOCK"
  fm_local_llm_release task-a || fail "a release must end a persisted-pid-less claim"
  wait "$holder" 2>/dev/null || true
  ! kill -0 "$holder" 2>/dev/null || fail "the release must end the holder blocked at the handoff"
  release_gone
  lock_free || fail "the slot must be free"
  fm_local_llm_claim task-b || fail "the slot must be claimable"
  end_holder
  lock_free || fail "the next claim must end cleanly"
  pass "a claim with no persisted pid is ended through the handoff's EOF, never by unlinking the lock under a live holder"
}

test_a_wrapper_taking_over_during_a_release_keeps_its_claim() {
  local marker="$TMP_ROOT/takeover.marker" wrapper
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  # The merge/cleanup release races the same task's wrapper. The release's
  # one-second handoff probe and its two-second flock window are the interval
  # the takeover is scheduled into: the wrapper takes the handoff over after
  # the release's entry probe has passed, mid-release.
  release_bg task-a takeover
  sleep 1.3
  (
    fm_local_llm_take_claim task-a || exit 3
    : >"$marker"
    sleep 30
  ) &
  wrapper=$!
  sleep 0.2
  wait "$RELEASE_BG"
  expect_code 1 "$(cat "$TMP_ROOT/takeover.rc")" "a release racing a handoff takeover must refuse"
  assert_contains "$(cat "$TMP_ROOT/takeover.err")" "handoff" "the refusal says the handoff is what it refused on"
  [ -e "$marker" ] || fail "the racing wrapper must have taken over the handoff"
  [ -e "$FM_LOCAL_LLM_LOCK" ] || fail "a release racing a takeover must leave the claim file in place"
  assert_equals "task-a" "$(head -n 1 "$FM_LOCAL_LLM_LOCK")" "the claim racing a takeover must keep its name"
  [ -p "$FM_LOCAL_LLM_LOCK.handoff" ] || fail "the handoff of a claim racing a takeover must stay in place"
  kill -0 "$wrapper" 2>/dev/null || fail "the refused release must leave the live wrapper untouched"
  kill "$wrapper" 2>/dev/null || true
  wait "$wrapper" 2>/dev/null || true
  end_holder
  lock_free || fail "the slot must free once the racing wrapper has ended"
  fm_local_llm_release task-a || fail "the release must succeed once the racing wrapper has ended"
  release_gone
  pass "a release racing a same-task handoff takeover refuses, kills nothing, and never unlinks the takeover's claim"
}

test_a_new_holder_installed_during_a_release_is_never_killed() {
  local new_holder
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  release_bg task-a reholder
  # The release's claim dies mid-release and the same task relaunches,
  # installing a new holder: the release must target only the claim instance
  # it sampled, never the relaunch.
  sleep 0.3
  kill "$FM_LOCAL_LLM_HOLDER" 2>/dev/null || true
  sleep 0.2
  (
    fm_local_llm_claim task-a && printf '%s\n' "$FM_LOCAL_LLM_HOLDER" >"$TMP_ROOT/reholder.pid"
  ) &
  sleep 1.0
  wait "$RELEASE_BG"
  new_holder=$(cat "$TMP_ROOT/reholder.pid")
  expect_code 1 "$(cat "$TMP_ROOT/reholder.rc")" "a release racing a same-task relaunch must refuse"
  assert_contains "$(cat "$TMP_ROOT/reholder.err")" "taken with a new holder" "the refusal names the new holder it refused to touch"
  kill -0 "$new_holder" 2>/dev/null || fail "a racing release must never kill the relaunch's live holder"
  assert_equals "task-a" "$(head -n 1 "$FM_LOCAL_LLM_LOCK")" "the relaunch's claim must keep its name"
  assert_equals "$new_holder $(fm_local_llm_proc_start "$new_holder")" "$(sed -n 2p "$FM_LOCAL_LLM_LOCK")" "the relaunch's claim must keep its own holder pid and start time"
  [ -p "$FM_LOCAL_LLM_LOCK.handoff" ] || fail "the relaunch's handoff must stay in place"
  # The relaunch's own wrapper takes over as any live claim's does.
  ( fm_local_llm_take_claim task-a ) || fail "the relaunch's wrapper must take over its own claim"
  lock_free || fail "the relaunch's claim must free the slot when its wrapper exits"
  fm_local_llm_release task-a || fail "the release must succeed once the relaunch's claim has ended"
  release_gone
  pass "a release whose claim is replaced by a new holder mid-release refuses and leaves the new claim whole"
}

test_a_release_never_kills_a_live_holder_of_a_reclaimed_claim() {
  local lock=$FM_LOCAL_LLM_LOCK holder ident
  # The shape of a live claim: a holder holding the lock under the flock and
  # blocked at the handoff, its pid recorded beside its start time. The
  # task-id line of that claim is then rewritten to name the releasing task
  # while the release runs - a reclaimed slot whose live holder happens to
  # reuse the recorded pid.
  rm -f "$lock" "$lock.handoff"
  mkdir -p "$(dirname "$lock")"
  mkfifo -m 600 "$lock.handoff"
  (
    exec 9>>"$lock"
    flock -n 9
    exec cat "$lock.handoff"
  ) </dev/null >/dev/null 2>&1 &
  holder=$!
  ident=$(fm_local_llm_proc_start "$holder")
  printf 'task-a\n%s %s\n' "$holder" "$ident" >"$lock"
  release_bg task-a reuse
  sleep 1.3
  printf 'task-b\n%s %s\n' "$holder" "$ident" >"$lock"
  sleep 1.9
  wait "$RELEASE_BG"
  expect_code 1 "$(cat "$TMP_ROOT/reuse.rc")" "a release racing a re-claim that reused its holder pid must refuse"
  assert_contains "$(cat "$TMP_ROOT/reuse.err")" "taken with a new holder" "the refusal names the claim whose live holder it refused to kill"
  kill -0 "$holder" 2>/dev/null || fail "a racing release must never kill the reclaimed claim's live holder"
  assert_equals "task-b" "$(head -n 1 "$lock")" "the reclaimed claim must keep its name"
  assert_equals "$holder $ident" "$(sed -n 2p "$lock")" "the reclaimed claim must keep its holder and start time"
  fm_local_llm_claim task-c 2>/dev/null && fail "the reclaimed claim's live lease must still refuse a third task"
  end_holder
  lock_free || fail "the reclaimed claim must free the slot once its handoff is opened"
  fm_local_llm_release task-b || fail "the reclaimed claim must release cleanly"
  release_gone
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "a release racing a re-claim onto the recorded pid refuses, kills the live holder of nothing, and unlinks nothing"
}

test_a_live_holder_without_the_recorded_start_time_is_never_killed() {
  local lock=$FM_LOCAL_LLM_LOCK holder out rc
  # The exact corner of a reused pid value: a live process carries the
  # recorded pid value, and the claim's recorded start time is one this
  # live pid never had. The release may signal only the very process the
  # claim recorded, so it signals nothing and the slot stays claimed.
  rm -f "$lock" "$lock.handoff"
  mkdir -p "$(dirname "$lock")"
  mkfifo -m 600 "$lock.handoff"
  (
    exec cat "$lock.handoff"
  ) </dev/null >/dev/null 2>&1 &
  holder=$!
  printf 'task-a\n%s 0\n' "$holder" >"$lock"
  out=$(fm_local_llm_release task-a 2>&1)
  rc=$?
  expect_code 1 "$rc" "a release must refuse to signal a live pid that does not carry the recorded start time"
  assert_contains "$out" "$holder" "the refusal names the pid it refused to signal"
  assert_contains "$out" "left the claim in place" "the refusal says the claim stays claimed"
  kill -0 "$holder" 2>/dev/null || fail "a live pid that does not carry the recorded start time must never be signaled"
  [ -e "$lock" ] || fail "a refused release must leave the claim file in place"
  assert_equals "task-a" "$(head -n 1 "$lock")" "the claim must keep its name"
  assert_equals "$holder 0" "$(sed -n 2p "$lock")" "a refused release must leave the recorded identity intact"
  [ -p "$lock.handoff" ] || fail "a refused release must leave the handoff FIFO in place"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  fm_local_llm_release task-a || fail "the release must clean the claim once its recorded pid is gone"
  release_gone
  lock_free || fail "the slot must be free for the next task"
  fm_local_llm_claim task-b || fail "the slot must be claimable once the identity refusal is resolved"
  end_holder
  lock_free || fail "the next claim must end cleanly"
  pass "a live pid that does not carry the recorded start time is signaled by nothing and its claim stays in place"
}

test_a_live_holder_without_a_recorded_identity_is_never_killed() {
  local lock=$FM_LOCAL_LLM_LOCK holder out rc
  # A claim line that records no identity for its live pid: the release
  # cannot prove the live pid is the process it recorded, so it signals
  # nothing, keeps the lock file and the FIFO, and reports the slot held
  # for the next dispatch to inspect.
  rm -f "$lock" "$lock.handoff"
  mkdir -p "$(dirname "$lock")"
  mkfifo -m 600 "$lock.handoff"
  (
    exec cat "$lock.handoff"
  ) </dev/null >/dev/null 2>&1 &
  holder=$!
  printf 'task-a\n%s\n' "$holder" >"$lock"
  out=$(fm_local_llm_release task-a 2>&1)
  rc=$?
  expect_code 1 "$rc" "a release must refuse a live pid whose claim records no start time"
  assert_contains "$out" "$holder" "the refusal names the pid it refused to signal"
  assert_contains "$out" "left the claim in place" "the refusal says the claim stays claimed"
  kill -0 "$holder" 2>/dev/null || fail "a live pid with no recorded identity must never be signaled"
  [ -e "$lock" ] || fail "a refused release must leave the claim file in place"
  assert_equals "task-a" "$(head -n 1 "$lock")" "the claim must keep its name"
  assert_equals "$holder" "$(sed -n 2p "$lock")" "a refused release must leave the recorded pid intact"
  [ -p "$lock.handoff" ] || fail "a refused release must leave the handoff FIFO in place"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  fm_local_llm_release task-a || fail "the release must clean the claim once its recorded pid is gone"
  release_gone
  lock_free || fail "the slot must be free for the next task"
  fm_local_llm_claim task-b || fail "the slot must be claimable once the identity refusal is resolved"
  end_holder
  lock_free || fail "the next claim must end cleanly"
  pass "a live pid with no recorded identity is signaled by nothing and its claim stays claimed"
}

test_a_stopped_holder_is_killed_when_its_term_does_not_end_the_lease() {
  local lock=$FM_LOCAL_LLM_LOCK holder out rc
  # The shape of a blocked TERM: a stopped holder keeps the lease's flock
  # on its descriptor, so a TERM it never runs leaves the slot claimed
  # forever. The release escalates its identity-verified kill to SIGKILL,
  # which no process state can block.
  rm -f "$lock" "$lock.handoff"
  mkdir -p "$(dirname "$lock")"
  mkfifo -m 600 "$lock.handoff"
  (
    exec 9>>"$lock"
    flock -n 9
    exec cat "$lock.handoff"
  ) </dev/null >/dev/null 2>&1 &
  holder=$!
  printf 'task-a\n%s %s\n' "$holder" "$(fm_local_llm_proc_start "$holder")" >"$lock"
  kill -STOP "$holder" || fail "the holder must be stoppable"
  out=$(fm_local_llm_release task-a 2>&1)
  rc=$?
  expect_code 0 "$rc" "the release must escalate a stopped holder's kill and free the slot: $out"
  assert_equals "" "$out" "an escalated release that ends the lease says nothing"
  kill -CONT "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  ! kill -0 "$holder" 2>/dev/null || fail "the escalation must end the stopped holder"
  release_gone
  lock_free || fail "the escalated release must free the flock"
  fm_local_llm_claim task-b || fail "the slot must be claimable after the escalation"
  end_holder
  lock_free || fail "the next claim must end cleanly"
  pass "a stopped holder whose TERM is blocked is escalated to SIGKILL, its lease ends, and the slot releases"
}

test_a_release_that_cannot_open_the_lock_file_refuses() {
  if [ "$(id -u)" = 0 ]; then
    pass "the lock-open refusal test skips as root, which bypasses file permissions"
    return
  fi
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  # The claim stands and the lock file cannot be opened for write: the
  # release must say the slot was not freed and leave the claim in place.
  chmod 400 "$FM_LOCAL_LLM_LOCK"
  local out rc
  out=$(fm_local_llm_release task-a 2>&1)
  rc=$?
  chmod 600 "$FM_LOCAL_LLM_LOCK"
  expect_code 1 "$rc" "a release that cannot open the lock file must refuse"
  assert_contains "$out" "could not open the local-model claim lock" "the refusal names the lock file it could not open"
  assert_contains "$out" "task-a" "the refusal names the task whose slot was not freed"
  [ -e "$FM_LOCAL_LLM_LOCK" ] || fail "a refused release must leave the claim file in place"
  assert_equals "task-a" "$(head -n 1 "$FM_LOCAL_LLM_LOCK")" "the claim must keep its name"
  kill -0 "$FM_LOCAL_LLM_HOLDER" 2>/dev/null || fail "a refused release must not end the holder"
  fm_local_llm_claim task-b 2>/dev/null && fail "the live claim must still refuse a second task"
  end_holder
  lock_free || fail "the claim must free the slot once its handoff is opened"
  fm_local_llm_release task-a || fail "the release must succeed once the lock file is openable again"
  release_gone
  pass "a release that cannot open the lock file names it, refuses, and leaves the claim claimed"
}

test_a_release_racing_a_concurrent_unlink_is_silent() {
  local benign
  fm_local_llm_claim task-a || fail "a free slot must be claimed"
  benign=$FM_LOCAL_LLM_HOLDER
  # The benign shape of the open failure: a concurrent release unlinked the
  # claim while this release ran, so its slot is free and nothing is left.
  chmod 400 "$FM_LOCAL_LLM_LOCK"
  ( sleep 0.3; rm -f "$FM_LOCAL_LLM_LOCK" ) &
  release_bg task-a benign-open
  sleep 0.2
  wait "$RELEASE_BG"
  expect_code 0 "$(cat "$TMP_ROOT/benign-open.rc")" "a release racing a concurrent unlink of its claim must report the slot free"
  [ ! -s "$TMP_ROOT/benign-open.err" ] || fail "the benign race must stay silent: $(cat "$TMP_ROOT/benign-open.err")"
  chmod 600 "$FM_LOCAL_LLM_LOCK" 2>/dev/null || true
  kill "$benign" 2>/dev/null || true
  wait "$benign" 2>/dev/null || true
  lock_free || fail "the concurrent unlink must leave the flock free"
  fm_local_llm_claim task-b || fail "the slot must be claimable by the next task after the benign race"
  end_holder
  lock_free || fail "the next claim must end cleanly"
  fm_local_llm_release task-b || fail "the next claim must release cleanly"
  release_gone
  pass "a release whose claim a concurrent release already removed is a silent success leaving a claimable slot"
}

# select_case <sandbox 0|1> [config-dir]: reset the world, then run the
# availability decision in this shell; $OUT holds the notice, $RC the verdict.
SERVER_UP='{"data":[{"id":"qwen3.8-27b-gsq-rco"}]}'
GPU_BUSY=0
fm_local_llm_gpu_conflict() { [ "$GPU_BUSY" = 1 ]; }
CFG="$TMP_ROOT/cfg"
mkdir -p "$CFG"
export FM_LOCAL_LLM_START_POLL=0.1 FM_LOCAL_LLM_START_WAIT=2
select_case() {
  OUT=$(fm_local_llm_select task-s "$1" "$CFG" 2>&1 9>&-)
  RC=$?
  # The subshell claimed the slot with its own holder; release it for the next case.
  if [ "$RC" -eq 0 ]; then
    sleep 0.3
    end_holder
    lock_free || fail "the case must leave the slot free"
  fi
}
reset_world() {
  rm -f "$TMP_ROOT/models.json" "$TMP_ROOT/curl.delay" "$CFG/local-llm-start" "$TMP_ROOT/start.count"
  GPU_BUSY=0
}

test_select_uses_the_local_model_when_every_check_holds() {
  reset_world
  printf '%s\n' "$SERVER_UP" >"$TMP_ROOT/models.json"
  select_case 1
  expect_code 0 "$RC" "a healthy host keeps the local model: $OUT"
  assert_equals "" "$OUT" "no notice when nothing fell back"
  pass "every check holding keeps the local model silently"
}

test_select_names_an_invalid_health_bound_and_falls_back() {
  reset_world
  printf '%s\n' "$SERVER_UP" >"$TMP_ROOT/models.json"
  FM_LOCAL_LLM_HEALTH_TIMEOUT=0 select_case 1
  expect_code 1 "$RC" "an invalid bound falls back"
  assert_contains "$OUT" "FM_LOCAL_LLM_HEALTH_TIMEOUT must be a positive whole number of seconds" "the notice names the variable"
  assert_contains "$OUT" "using claude-haiku-4-5 (effort low) instead" "the notice names the fallback model"
  pass "an invalid health bound is named in the fallback notice"
}

test_select_keeps_the_local_model_when_the_server_is_slow_to_answer() {
  reset_world
  printf '%s\n' "$SERVER_UP" >"$TMP_ROOT/models.json"
  printf '6\n' >"$TMP_ROOT/curl.delay"
  ! fm_local_llm_health 2>/dev/null || fail "a 6s answer must exceed the pre-launch 5s bound"
  select_case 1
  expect_code 0 "$RC" "a server slower than the pre-launch bound is still alive for the dispatch check: $OUT"
  assert_equals "" "$OUT" "a slow but alive server must not print a fallback notice"
  pass "a server slower than the pre-launch health bound keeps its dispatch-chosen model"
}

test_select_starts_a_slow_but_alive_server_without_falling_back() {
  reset_world
  cat >"$CFG/start.sh" <<SH
#!/bin/sh
echo x >> "$TMP_ROOT/start.count"
printf '%s\n' '$SERVER_UP' > "$TMP_ROOT/models.json"
SH
  chmod +x "$CFG/start.sh"
  printf '%s\n' "$CFG/start.sh" >"$CFG/local-llm-start"
  printf '6\n' >"$TMP_ROOT/curl.delay"
  select_case 1
  expect_code 0 "$RC" "a server that answers slower than 5s once started is still alive: $OUT"
  assert_equals "" "$OUT" "a slow but alive started server must not print a fallback notice"
  pass "the start path applies the dispatch health bound, so a slow server does not fall back"
}

test_select_checks_in_order_and_names_the_failed_check() {
  reset_world
  GPU_BUSY=1
  select_case 0
  expect_code 1 "$RC" "no sandbox falls back"
  assert_contains "$OUT" "the home has no sandbox profile" "check (a) wins over a busy GPU and a silent server"
  assert_contains "$OUT" "using claude-haiku-4-5 (effort low) instead" "the notice names the model used"
  select_case 1
  assert_contains "$OUT" "ComfyUI holds the GPU" "the GPU is checked before the server"
  GPU_BUSY=0
  select_case 1
  assert_contains "$OUT" "the server is not answering and no start command is configured" "check (b) names the silent server"
  printf '%s\n' "$SERVER_UP" >"$TMP_ROOT/models.json"
  fm_local_llm_claim holder || fail "could not take the slot"
  select_case 1
  expect_code 1 "$RC" "a taken slot falls back"
  assert_contains "$OUT" "the one local slot is taken" "check (c) names the taken slot"
  end_holder
  lock_free || fail "the slot must free"
  pass "the checks run in order and each failure is named in one notice line"
}

test_select_never_starts_anything_without_the_sandbox() {
  reset_world
  printf '#!/bin/sh\necho x >> "%s"\n' "$TMP_ROOT/start.count" >"$CFG/start.sh"
  chmod +x "$CFG/start.sh"
  printf '%s\n' "$CFG/start.sh" >"$CFG/local-llm-start"
  select_case 0
  expect_code 1 "$RC" "no sandbox falls back"
  [ ! -e "$TMP_ROOT/start.count" ] || fail "a home without the sandbox profile must never run the start command"
  pass "a sandbox-less home falls back without running the start command"
}

test_select_starts_the_server_once_then_rechecks() {
  reset_world
  cat >"$CFG/start.sh" <<SH
#!/bin/sh
echo x >> "$TMP_ROOT/start.count"
sleep 0.3
printf '%s\n' '$SERVER_UP' > "$TMP_ROOT/models.json"
SH
  chmod +x "$CFG/start.sh"
  printf '# the host start command\n\n  %s  \n' "$CFG/start.sh" >"$CFG/local-llm-start"
  select_case 1
  expect_code 0 "$RC" "a started server is used: $OUT"
  assert_equals "1" "$(wc -l <"$TMP_ROOT/start.count" | tr -d ' ')" "the start command runs exactly once"
  pass "a down server is started once and the local model is used"
}

test_select_falls_back_when_the_started_server_never_answers() {
  reset_world
  printf '#!/bin/sh\nexit 0\n' >"$CFG/start.sh"
  chmod +x "$CFG/start.sh"
  printf '%s\n' "$CFG/start.sh" >"$CFG/local-llm-start"
  FM_LOCAL_LLM_START_WAIT=1 select_case 1
  expect_code 1 "$RC" "a start that never answers falls back"
  assert_contains "$OUT" "did not answer within 1s of its start command" "the notice names the timeout"
  printf '#!/bin/sh\nexit 3\n' >"$CFG/start.sh"
  select_case 1
  expect_code 1 "$RC" "a failed start command falls back"
  pass "a start that times out or fails falls back"
}

test_select_does_not_start_the_server_while_comfyui_holds_the_gpu() {
  reset_world
  printf '#!/bin/sh\necho x >> "%s"\n' "$TMP_ROOT/start.count" >"$CFG/start.sh"
  chmod +x "$CFG/start.sh"
  printf '%s\n' "$CFG/start.sh" >"$CFG/local-llm-start"
  GPU_BUSY=1
  select_case 1
  expect_code 1 "$RC" "a busy GPU falls back"
  [ ! -e "$TMP_ROOT/start.count" ] || fail "the server must not be started while ComfyUI holds the GPU"
  printf '%s\n' "$SERVER_UP" >"$TMP_ROOT/models.json"
  select_case 1
  expect_code 1 "$RC" "a running server is not accepted while ComfyUI holds the GPU"
  assert_contains "$OUT" "ComfyUI holds the GPU" "the notice names the GPU"
  pass "ComfyUI holding the GPU blocks both the start and an already-running server"
}

test_the_gpu_probe_reads_powershell_and_fails_closed() {
  local probe_bin=$TMP_ROOT/psbin
  mkdir -p "$probe_bin"
  # probe <path>: the real probe function, in its own shell, with that PATH.
  # shellcheck disable=SC2016 # $1 here is the inner bash -c's own positional arg, not this shell's
  probe() { env PATH="$1" bash -c '. "$1/bin/fm-local-llm-lib.sh"; fm_local_llm_gpu_conflict' _ "$ROOT"; }
  ! probe "$FAKEBIN:/usr/bin:/bin" || fail "no powershell.exe must mean no conflict"
  printf '#!/bin/sh\necho 1\n' >"$probe_bin/powershell.exe"
  chmod +x "$probe_bin/powershell.exe"
  probe "$probe_bin:/usr/bin:/bin" || fail "a ComfyUI python process must be a conflict"
  printf '#!/bin/sh\necho 0\n' >"$probe_bin/powershell.exe"
  ! probe "$probe_bin:/usr/bin:/bin" || fail "no ComfyUI process must be no conflict"
  printf '#!/bin/sh\necho oops\nexit 1\n' >"$probe_bin/powershell.exe"
  probe "$probe_bin:/usr/bin:/bin" || fail "a failing probe must fail closed as a conflict"
  printf '#!/bin/sh\nexit 0\n' >"$probe_bin/powershell.exe"
  probe "$probe_bin:/usr/bin:/bin" || fail "a probe with no number must fail closed as a conflict"
  printf '#!/bin/sh\nsleep 2\necho 0\n' >"$probe_bin/powershell.exe"
  # shellcheck disable=SC2016 # $1 here is the inner bash -c's own positional arg, not this shell's
  env PATH="$probe_bin:/usr/bin:/bin" FM_LOCAL_LLM_GPU_PROBE_TIMEOUT=1 \
    bash -c '. "$1/bin/fm-local-llm-lib.sh"; fm_local_llm_gpu_conflict' _ "$ROOT" \
    || fail "a probe that times out must fail closed as a conflict"
  pass "the GPU probe reads powershell.exe, with no powershell.exe as no conflict and every other probe failure fail-closed as a conflict"
}

test_the_model_id_alone_selects_the_profile
test_health_refuses_when_the_server_is_not_answering
test_health_refuses_a_server_without_the_model
test_health_accepts_a_server_listing_the_model
test_health_uses_the_default_timeout_and_an_override
test_health_refuses_an_invalid_timeout
test_env_maps_every_tier_and_carries_no_host_secret
test_a_claim_refuses_a_second_and_names_its_task
test_the_claiming_task_takes_over_and_its_exit_releases
test_another_task_or_no_claim_is_refused
test_killing_the_holder_releases_the_claim
test_a_matching_claim_is_released_and_the_slot_is_claimable_again
test_release_leaves_another_tasks_claim_running
test_releasing_no_claim_is_a_clean_noop
test_release_is_safe_to_call_twice
test_a_claim_left_by_a_dead_holder_is_cleaned_up
test_a_live_recorded_pid_that_is_not_the_holder_is_never_killed
test_a_zombie_holder_is_treated_as_gone
test_a_background_job_without_the_descriptor_does_not_keep_the_claim
test_a_worker_running_on_the_handoff_is_never_released
test_a_process_holding_the_lock_file_open_is_not_the_holder
test_a_claim_without_a_persisted_pid_is_ended_through_the_handoff
test_a_wrapper_taking_over_during_a_release_keeps_its_claim
test_a_new_holder_installed_during_a_release_is_never_killed
test_a_release_never_kills_a_live_holder_of_a_reclaimed_claim
test_a_live_holder_without_the_recorded_start_time_is_never_killed
test_a_live_holder_without_a_recorded_identity_is_never_killed
test_a_stopped_holder_is_killed_when_its_term_does_not_end_the_lease
test_a_release_that_cannot_open_the_lock_file_refuses
test_a_release_racing_a_concurrent_unlink_is_silent
test_select_uses_the_local_model_when_every_check_holds
test_select_names_an_invalid_health_bound_and_falls_back
test_select_keeps_the_local_model_when_the_server_is_slow_to_answer
test_select_starts_a_slow_but_alive_server_without_falling_back
test_select_checks_in_order_and_names_the_failed_check
test_select_never_starts_anything_without_the_sandbox
test_select_starts_the_server_once_then_rechecks
test_select_falls_back_when_the_started_server_never_answers
test_select_does_not_start_the_server_while_comfyui_holds_the_gpu
test_the_gpu_probe_reads_powershell_and_fails_closed

echo "# all fm-local-llm-lib tests passed"
