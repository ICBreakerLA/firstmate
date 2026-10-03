#!/usr/bin/env bash
# Behavior tests for bin/fm-sbx-run.sh (invoked as bin/claude-sbx): the sandbox
# it creates has the minimal mount set and an explicit environment, secrets reach
# the VM only through sbx's per-sandbox secret store, and every exit path removes
# the sandbox.
# A fake sbx records its argv; tests/fm-sbx-live.test.sh owns the live guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNSH="$ROOT/bin/claude-sbx"
BRIDGE="$ROOT/bin/fm-sbx-bridge.sh"
TMP_ROOT=$(fm_test_tmproot fm-sbx-run)
fm_git_identity 'Captain Tests' 'captain@example.invalid'
unset FM_SBX_GH_TOKEN GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
NAME=fm-sbx-0123abcd-t1-9999
SECRET='ghp_FAKE_TEST_TOKEN_0123456789'

# new_world <case>
# Builds a fake home, a real worktree plus standalone clone, and a recording sbx.
new_world() {
  W="$TMP_ROOT/$1"
  HOMEDIR="$W/home"
  STATE="$HOMEDIR/state"
  CONFIG="$HOMEDIR/config"
  DATA="$HOMEDIR/data"
  REPO="$W/repo"
  WT="$W/wt"
  CLONE="$STATE/t1.sbx-clone"
  FAKE=$(fm_fakebin "$W")
  LOG="$W/sbx.log"
  LIVE="$W/sbx.live"
  mkdir -p "$STATE" "$CONFIG" "$DATA" "$HOMEDIR/.agents/skills" "$W/userhome"
  fm_git_worktree "$REPO" "$WT" base-branch
  "$BRIDGE" clone "$WT" "$CLONE" || fail "clone"
  : >"$LOG"
  : >"$LIVE"
  cat >"$FAKE/sbx" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$LOG"
case "\$1" in
daemon) echo "Status: running" ;;
ls) cat "$LIVE" ;;
create) printf '%s\\n' "\$3" >>"$LIVE" ;;
rm) grep -Fxv -- "\$3" "$LIVE" >"$LIVE.new"; mv "$LIVE.new" "$LIVE" ;;
secret) cat >"$W/secret.stdin" ;;
exec)
  case "\$*" in
  *"no-mistakes --version"*) cat "$W/vm.nmver" 2>/dev/null; exit 0 ;;
  *"no-mistakes init"*) [ ! -f "$W/init.fail" ] || exit 1 ;;
  *"gh --version"*) [ ! -f "$W/gh.fail" ] || exit 1 ;;
  esac
  ;;
run)
  printf '%s\\n' "ENV-AT-RUN: \$(env | grep -c -F "$SECRET")" >>"$LOG"
  if [ -f "$W/run.hang" ]; then : >"$W/run.started"; sleep 30 & wait \$!; fi
  exit "\$(cat "$W/run.rc" 2>/dev/null || echo 0)"
  ;;
esac
exit 0
SH
  chmod +x "$FAKE/sbx"
}

# fake_nm <world> <version>: a host no-mistakes reporting <version>, with the
# copy in the VM reporting the same.
fake_nm() {
  # shellcheck disable=SC2016 # the script text expands when the fake runs
  printf '#!/usr/bin/env bash\n[ "$1" != --version ] || echo "no-mistakes version %s"\nexit 0\n' "$2" >"$FAKE/no-mistakes"
  chmod +x "$FAKE/no-mistakes"
  printf 'no-mistakes version %s\n' "$2" >"$1/vm.nmver"
}

# wrap [extra wrapper args] -- run the wrapper with the standard world.
wrap() {
  HOME="$W/userhome" PATH="$FAKE:$PATH" "$RUNSH" --id t1 --config "$CONFIG" --state "$STATE" \
    --data "$DATA" --root "$HOMEDIR" --wt "$WT" --clone "$CLONE" --name "$NAME" "$@"
}

log() { cat "$LOG"; }

test_creates_with_minimal_mounts_and_cleans_up() {
  local out rc create
  new_world mounts
  mkdir -p "$STATE/operational-inbox" "$STATE/t1.sbx"
  printf 'brief\n' >"$STATE/operational-inbox/1-abcd.msg"
  printf 'secret sibling\n' >"$STATE/operational-inbox/2-ef01.msg"
  mkdir -p "$DATA/projects-marker" "$HOMEDIR/projects/victim"
  printf '3\n' >"$W/run.rc"
  out=$(wrap --kind scout -- claude --model x ": Firstmate operational input waiting: read '$STATE/operational-inbox/1-abcd.msg' and handle its contents as Firstmate operational input." 2>&1); rc=$?
  expect_code 3 "$rc" "the wrapper returns claude's exit code: $out"
  create=$(grep '^create ' "$LOG")
  assert_contains "$create" "create --name $NAME --pull missing --cpus 4 --memory 4g" "the sandbox is created under the fleet name with default resources"
  assert_contains "$create" " claude $CLONE " "the standalone clone is the first workspace"
  assert_contains "$create" " $DATA/t1 " "the task's own data directory is mounted"
  assert_contains "$create" " $STATE/t1.sbx " "the channel is mounted"
  assert_contains "$create" " $STATE/t1.inbox " "the steering inbox is mounted"
  assert_contains "$create" "$STATE/operational-inbox/1-abcd.msg:ro" "the brief record is mounted read-only"
  assert_not_contains "$create" "2-ef01.msg" "no sibling operational record is mounted"
  assert_contains "$create" "$HOMEDIR/.agents/skills:ro" "the shared skills are mounted read-only"
  assert_not_contains "$create" " $HOMEDIR " "the whole firstmate home is never mounted"
  assert_not_contains "$create" "$HOMEDIR/projects" "nothing under projects/ is mounted"
  assert_not_contains "$create" " $WT" "the host worktree itself is never mounted"
  assert_not_contains "$create" " $REPO" "the project repository is never mounted"
  assert_not_contains "$create" "$W/userhome" "the host home is never mounted"
  assert_contains "$(log)" "run --name $NAME -- claude --model x" "claude runs in the sandbox with its arguments"
  assert_contains "$(log)" "rm --force $NAME" "the sandbox is removed on exit"
  [ ! -s "$LIVE" ] || fail "no sandbox may remain: $(cat "$LIVE")"
  pass "the sandbox gets only the clone, task directories and read-only brief, and is removed on exit"
}

test_environment_is_an_explicit_allowlist() {
  local create
  new_world env
  ANTHROPIC_API_KEY=host-secret AWS_SECRET_ACCESS_KEY=host-aws FM_TASK_ID=t1 SSH_AUTH_SOCK=/tmp/agent \
    wrap --kind scout -- claude >/dev/null 2>&1
  create=$(grep '^create ' "$LOG")
  assert_contains "$create" "-e DISABLE_AUTOUPDATER=1" "the updater is disabled"
  assert_contains "$create" "-e FM_SBX_CHANNEL=$STATE/t1.sbx" "the worker learns its channel"
  assert_contains "$create" "-e FM_TASK_ID=t1" "an allowlisted variable passes"
  assert_not_contains "$create" "host-secret" "a host API key never reaches the sandbox"
  assert_not_contains "$create" "host-aws" "a host cloud credential never reaches the sandbox"
  assert_not_contains "$create" "SSH_AUTH_SOCK" "the host ssh agent is not forwarded"
  assert_not_contains "$create" "NM_HOME" "a scout has no pipeline environment"
  pass "only allowlisted variables reach the sandbox"
}

test_the_commit_identity_reaches_the_sandbox_environment() {
  local create
  new_world ident
  git -C "$REPO" config user.name "Fleet Tests"
  git -C "$REPO" config user.email "fleet@example.invalid"
  wrap --kind scout -- claude >/dev/null 2>&1
  create=$(grep '^create ' "$LOG")
  assert_contains "$create" "-e GIT_AUTHOR_NAME=Fleet Tests" "the author name is passed"
  assert_contains "$create" "-e GIT_AUTHOR_EMAIL=fleet@example.invalid" "the author email is passed"
  assert_contains "$create" "-e GIT_COMMITTER_NAME=Fleet Tests" "the committer name is passed"
  assert_contains "$create" "-e GIT_COMMITTER_EMAIL=fleet@example.invalid" "the committer email is passed"
  git -C "$REPO" config --unset user.email
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null wrap --kind scout -- claude >/dev/null 2>&1
  assert_not_contains "$(grep '^create ' "$LOG" | tail -1)" "GIT_AUTHOR" "no half identity is passed"
  pass "the commit identity the clone carries also reaches the sandbox environment"
}

test_the_token_enters_only_through_the_sandbox_secret_store() {
  local create
  new_world token
  printf '%s\n' "$SECRET" >"$CONFIG/sbx-github-token"
  wrap --kind scout --allow example.org -- claude >/dev/null 2>&1
  create=$(grep '^create ' "$LOG")
  assert_equals "$SECRET" "$(cat "$W/secret.stdin")" "the token reaches sbx on stdin"
  assert_contains "$(log)" "secret set github --sandbox $NAME" "the secret is scoped to this sandbox"
  assert_not_contains "$(log)" "$SECRET" "the token is never in any sbx argument"
  assert_contains "$(log)" "ENV-AT-RUN: 0" "the token is never in the environment claude runs under"
  assert_contains "$(log)" "policy allow network --sandbox $NAME github.com,api.github.com,example.org" "GitHub and the extra host are allowed for this sandbox only"
  assert_not_contains "$create" "$SECRET" "the token is not in the create command"
  assert_not_contains "$(log)" "policy allow network github" "the global policy is never touched"
  pass "a GitHub token is stored as a per-sandbox secret and never appears in argv or the environment"
}

test_no_token_means_no_secret_and_no_network_rule() {
  new_world notoken
  wrap --kind scout -- claude >/dev/null 2>&1
  assert_not_contains "$(log)" "secret set" "no token configured, no secret stored"
  assert_not_contains "$(log)" "policy allow" "no allow list, no network rule"
  pass "without a token or allow list the sandbox gets neither a secret nor a network rule"
}

test_a_symlinked_token_file_is_ignored() {
  new_world symtoken
  printf '%s\n' "$SECRET" >"$W/elsewhere"
  ln -s "$W/elsewhere" "$CONFIG/sbx-github-token"
  wrap --kind scout -- claude >/dev/null 2>&1
  assert_not_contains "$(log)" "secret set" "a symlinked token file is not followed"
  pass "a symlinked token file is never read"
}

test_nm_ship_gets_the_pipeline_environment_and_network() {
  local out create
  new_world nm
  fake_nm "$W" v1.79.0
  printf '%s\n' "$SECRET" >"$CONFIG/sbx-github-token"
  out=$(wrap --nm -- claude 2>&1) || fail "nm ship run failed: $out"
  create=$(grep '^create ' "$LOG")
  assert_contains "$create" "-e NM_HOME=/home/agent/nm" "the pipeline home is VM-local"
  assert_contains "$create" "-e NO_MISTAKES_NO_UPDATE_CHECK=1" "the pipeline does not check for updates"
  assert_contains "$(log)" "cp $FAKE/no-mistakes $NAME:/tmp/fm-no-mistakes" "the host binary is copied into the VM"
  assert_contains "$(log)" "install -m 755 /tmp/fm-no-mistakes /usr/local/bin/no-mistakes" "it is installed as root"
  assert_contains "$(log)" "policy allow network --sandbox $NAME github.com,api.github.com" "GitHub is allowed for this sandbox"
  assert_contains "$(log)" "exec -w $CLONE -e NM_HOME=/home/agent/nm $NAME no-mistakes axi sync" "the pipeline is synced to the clone before the sandbox is removed"
  pass "a no-mistakes ship gets the in-VM pipeline, its network, and a final sync"
}

test_nm_ship_clone_is_prepared_before_the_worker_starts() {
  local out lines
  new_world nmprep
  fake_nm "$W" v1.79.0
  out=$(wrap --nm -- claude 2>&1) || fail "nm ship run failed: $out"
  lines=$(grep -n -e 'exec -w' -e '^run ' -e 'policy allow' "$LOG" | grep -v 'axi sync' | sed 's/^[0-9]*://')
  assert_contains "$lines" "policy allow network" "the network is opened first"
  assert_contains "$lines" "$NAME git remote get-url origin" "the clone's origin is checked inside the VM"
  assert_contains "$lines" "$NAME git fetch -q origin" "origin is fetched inside the VM"
  assert_contains "$lines" "$NAME git remote set-head origin -a" "origin/HEAD is set to the real default branch"
  assert_contains "$lines" "$NAME no-mistakes init" "the pipeline is initialised in the clone"
  [ "$(printf '%s\n' "$lines" | sed -n '1p')" = "$(printf '%s\n' "$lines" | grep -m1 'policy allow')" ] || fail "policy must precede the setup: $lines"
  [ "$(printf '%s\n' "$lines" | grep -n 'no-mistakes init' | cut -d: -f1)" -lt "$(printf '%s\n' "$lines" | grep -n '^run ' | cut -d: -f1)" ] || fail "init must precede the worker: $lines"
  pass "origin is fetched, its default branch set and the pipeline initialised before claude starts"
}

test_nm_ship_gets_the_host_gh_and_survives_one_that_does_not_run() {
  local out
  new_world nmgh
  fake_nm "$W" v1.79.0
  printf '#!/bin/sh\nexit 0\n' >"$FAKE/gh"
  chmod +x "$FAKE/gh"
  out=$(wrap --nm -- claude 2>&1) || fail "nm ship run failed: $out"
  assert_contains "$(log)" "/tmp/fm-gh" "the host gh is copied in"
  assert_contains "$(log)" "install -m 755 /tmp/fm-gh /usr/local/bin/gh" "it is installed ahead of the image's gh"
  : >"$LOG"
  : >"$W/gh.fail"
  out=$(wrap --nm -- claude 2>&1) || fail "a gh that does not run must not stop the worker: $out"
  assert_contains "$out" "does not run inside" "the operator is told CI monitoring keeps the image's gh"
  assert_contains "$(log)" "rm -f /usr/local/bin/gh" "the unusable copy is removed"
  assert_contains "$(log)" "run --name" "claude still starts"
  pass "the host gh is installed for a no-mistakes ship and an unusable copy is dropped"
}

test_nm_version_mismatch_and_pin_refuse() {
  local out rc
  new_world nmver
  fake_nm "$W" v1.79.0
  printf 'no-mistakes version v1.80.1\n' >"$W/vm.nmver"
  out=$(wrap --nm -- claude 2>&1); rc=$?
  expect_code 2 "$rc" "a VM binary of another version must refuse: $out"
  assert_contains "$out" "refusing to run a different pipeline" "the refusal names the mismatch"
  assert_not_contains "$(log)" "run --name" "claude never starts"
  [ ! -s "$LIVE" ] || fail "the sandbox must be removed: $(cat "$LIVE")"
  fake_nm "$W" v1.79.0
  out=$(wrap --nm --nm-pin v1.78.0 -- claude 2>&1); rc=$?
  expect_code 2 "$rc" "a host version other than the pin must refuse: $out"
  assert_contains "$out" "pins no-mistakes v1.78.0 but the host runs v1.79.0" "the refusal names both versions"
  out=$(wrap --nm --nm-pin v1.79.0 -- claude 2>&1) || fail "a matching pin must launch: $out"
  pass "a VM copy that differs from the host, or a host that differs from the pin, refuses before the worker starts"
}

test_nm_init_failure_refuses_and_removes() {
  local out rc
  new_world nminit
  fake_nm "$W" v1.79.0
  : >"$W/init.fail"
  out=$(wrap --nm -- claude 2>&1); rc=$?
  expect_code 2 "$rc" "a failed init must refuse: $out"
  assert_contains "$out" "no-mistakes init failed" "the refusal names the step"
  assert_not_contains "$(log)" "run --name" "claude never starts"
  [ ! -s "$LIVE" ] || fail "the sandbox must be removed: $(cat "$LIVE")"
  pass "a failed in-VM init stops the launch and removes the sandbox"
}

test_nm_without_a_host_binary_refuses_and_still_removes() {
  local out rc
  new_world nobin
  out=$(PATH="$FAKE:/usr/bin:/bin" HOME="$W/userhome" "$RUNSH" --id t1 --config "$CONFIG" --state "$STATE" --data "$DATA" --root "$HOMEDIR" --wt "$WT" --clone "$CLONE" --name "$NAME" --nm -- claude 2>&1); rc=$?
  if PATH=/usr/bin:/bin command -v no-mistakes >/dev/null 2>&1; then
    pass "skipped: a host no-mistakes is on the base PATH"
    return
  fi
  expect_code 2 "$rc" "a ship without the host binary must refuse: $out"
  assert_contains "$out" "no-mistakes is not installed" "the refusal names the missing binary"
  assert_not_contains "$(log)" "run --name" "claude never starts"
  [ ! -s "$LIVE" ] || fail "the half-built sandbox must be removed: $(cat "$LIVE")"
  pass "a missing host no-mistakes refuses and leaves no sandbox"
}

test_npm_cache_is_mounted_read_only_with_offline_settings() {
  local create
  new_world npm
  mkdir -p "$W/cache"
  wrap --kind scout --npm-cache "$W/cache" -- claude >/dev/null 2>&1
  create=$(grep '^create ' "$LOG")
  assert_contains "$create" "$W/cache:ro" "the cache is read-only"
  assert_contains "$create" "-e NPM_CONFIG_CACHE=$W/cache" "npm is pointed at the cache"
  assert_contains "$create" "-e NPM_CONFIG_PREFER_OFFLINE=true" "npm prefers the cache"
  assert_contains "$create" "-e NPM_CONFIG_LOGS_DIR=/tmp/npm-logs" "logs go to a writable place"
  new_world npm-none
  wrap --kind scout -- claude >/dev/null 2>&1
  assert_not_contains "$(grep '^create ' "$LOG")" "NPM_CONFIG" "no cache, no npm settings"
  pass "an npm seed cache is mounted read-only with offline settings, and only when given"
}

test_hooks_path_mount_requires_the_homes_own_state() {
  local create
  new_world hooks
  mkdir -p "$STATE/t1.hooks" "$W/foreign-hooks"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$STATE/t1.hooks" wrap --kind scout -- claude >/dev/null 2>&1
  create=$(grep '^create ' "$LOG")
  assert_contains "$create" "$STATE/t1.hooks:ro" "the home's own hooks directory is mounted read-only"
  assert_contains "$create" "-e GIT_CONFIG_KEY_0=core.hooksPath" "the hooks path is configured in the VM"
  new_world hooks-foreign
  mkdir -p "$W/foreign-hooks"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$W/foreign-hooks" wrap --kind scout -- claude >/dev/null 2>&1
  create=$(grep '^create ' "$LOG")
  assert_not_contains "$create" "foreign-hooks" "a hooks directory outside this home's state is never mounted"
  pass "only this home's own hooks directory is mounted"
}

test_links_resolve_the_brief_paths_inside_the_vm() {
  new_world links
  wrap --kind scout -- claude >/dev/null 2>&1
  assert_contains "$(log)" "exec -u root $NAME sh -c" "the links are made as root"
  assert_contains "$(log)" "t1.sbx/status $STATE/t1.status $CLONE $WT" "the status and worktree paths map to the channel and the clone"
  pass "the brief's status and worktree paths resolve inside the VM"
}

test_refusals_happen_before_any_sandbox_exists() {
  local out rc
  new_world refuse
  out=$(wrap --kind scout --name my-sandbox -- claude 2>&1); rc=$?
  expect_code 2 "$rc" "a non-fleet name must refuse"
  assert_contains "$out" "not a fleet sandbox name" "the refusal names the rule"
  out=$(wrap --kind scout --memory lots -- claude 2>&1); rc=$?
  expect_code 2 "$rc" "a malformed memory must refuse"
  out=$(wrap --kind scout --allow 'a b;rm' -- claude 2>&1); rc=$?
  expect_code 2 "$rc" "a hostile allow list must refuse"
  out=$(wrap --kind scout 2>&1); rc=$?
  expect_code 2 "$rc" "a missing claude command must refuse"
  out=$(wrap --kind other -- claude 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown kind must refuse"
  out=$(wrap --kind scout --bogus -- claude 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown argument must refuse"
  mkdir -p "$W/noclone"
  out=$(HOME="$W/userhome" PATH="$FAKE:$PATH" "$RUNSH" --id t1 --config "$CONFIG" --state "$STATE" --data "$DATA" --root "$HOMEDIR" --wt "$WT" --clone "$W/noclone" --name "$NAME" --kind scout -- claude 2>&1); rc=$?
  expect_code 2 "$rc" "a missing clone must refuse"
  assert_not_contains "$(log)" "create " "no refusal reaches sbx create"
  pass "malformed or unsafe arguments refuse before any sandbox is created"
}

test_a_stopped_daemon_refuses() {
  local out rc
  new_world down
  printf '#!/usr/bin/env bash\necho "Status: stopped"; exit 1\n' >"$FAKE/sbx"
  out=$(wrap --kind scout -- claude 2>&1); rc=$?
  expect_code 1 "$rc" "a stopped daemon must refuse: $out"
  assert_contains "$out" "daemon is not running" "the refusal names the daemon"
  pass "a stopped daemon refuses"
}

test_a_failed_create_removes_nothing_foreign_and_reports() {
  local out rc
  new_world createfail
  sed -i 's/^create) .*/create) exit 1 ;;/' "$FAKE/sbx"
  out=$(wrap --kind scout -- claude 2>&1); rc=$?
  expect_code 2 "$rc" "a failed create must fail: $out"
  assert_contains "$out" "sbx create failed" "the failure is named"
  assert_not_contains "$(log)" "run --name" "claude never starts"
  pass "a failed create stops the launch"
}

# A pane that is killed signals the whole foreground process group, so the test
# does too: bash runs a trap only after its foreground child has ended.
# INT is not covered: a background job starts with SIGINT ignored, which no
# trap can undo, so only an interactive pane delivers it.
test_signals_remove_the_sandbox() {
  local pid sig
  for sig in TERM HUP; do
    new_world "sig-$sig"
    : >"$W/run.hang"
    HOME="$W/userhome" PATH="$FAKE:$PATH" setsid "$RUNSH" --id t1 --config "$CONFIG" --state "$STATE" --data "$DATA" \
      --root "$HOMEDIR" --wt "$WT" --clone "$CLONE" --name "$NAME" --kind scout -- claude >/dev/null 2>&1 &
    pid=$!
    for _ in $(seq 1 100); do [ -e "$W/run.started" ] && break; sleep 0.1; done
    [ -e "$W/run.started" ] || fail "the fake claude never started under $sig"
    kill -"$sig" -- "-$pid" 2>/dev/null
    for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL -- "-$pid" 2>/dev/null
      fail "the wrapper outlived $sig"
    fi
    assert_contains "$(log)" "rm --force $NAME" "$sig removes the sandbox"
    [ ! -s "$LIVE" ] || fail "no sandbox may remain after $sig"
  done
  pass "TERM and HUP each remove the sandbox before the wrapper exits"
}

test_a_ship_brings_its_commits_back_on_exit() {
  new_world shipback
  git -C "$CLONE" checkout -q -b fm/t1
  printf 'work\n' >>"$CLONE/README.md"
  git -C "$CLONE" -c user.name=T -c user.email=t@example.invalid commit -qam work
  wrap -- claude >/dev/null 2>&1
  assert_equals "$(git -C "$CLONE" rev-parse HEAD)" "$(git -C "$REPO" rev-parse refs/heads/fm/t1)" "the clone's commits are on the host after exit"
  assert_not_contains "$(log)" "relay" "the relay is a host process, not an sbx command"
  pass "a ship's commits reach the host worktree repository when the wrapper exits"
}

# verify_world: a host sm-verify stub plus the config/sbx-verify naming it.
verify_world() {
  mkdir -p "$W/hostbin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/smv.log"\n' "$W" >"$W/hostbin/sm-verify"
  chmod +x "$W/hostbin/sm-verify"
  printf 'sm-verify=%s\nlease-dir=%s/lease\n' "$W/hostbin/sm-verify" "$W" >"$CONFIG/sbx-verify"
}

test_verify_flag_mounts_the_spool_and_runs_the_broker() {
  local create out rc
  new_world verify
  verify_world
  out=$(wrap --kind scout --verify sportsmeet -- claude 2>&1); rc=$?
  expect_code 0 "$rc" "the wrapper still returns claude's exit code: $out"
  create=$(grep '^create ' "$LOG")
  assert_contains "$create" " $STATE/t1.sbx-verify/req " "the request spool is mounted writable"
  assert_contains "$create" " $STATE/t1.sbx-verify/res:ro" "the result directory is mounted read-only"
  assert_not_contains "$create" "sbx-verify/host" "the host-only directory is never mounted"
  assert_not_contains "$create" "$W/hostbin" "the pinned sm-verify is never mounted"
  assert_contains "$create" "-e FM_SBX_VERIFY_SPOOL=$STATE/t1.sbx-verify/req" "the worker learns its spool"
  assert_absent "$STATE/t1.sbx-verify/host/broker.pid" "no broker is left running"
  pass "--verify mounts the spool and result directory and names the spool"
}

test_verify_flag_off_changes_nothing() {
  local create
  new_world noverify
  verify_world
  wrap --kind scout -- claude >/dev/null 2>&1
  create=$(grep '^create ' "$LOG")
  assert_not_contains "$create" ".sbx-verify" "no verification mount without the flag"
  assert_not_contains "$create" "FM_SBX_VERIFY_SPOOL" "no verification variable without the flag"
  assert_absent "$STATE/t1.sbx-verify" "no spool is created without the flag"
  pass "without --verify the run is exactly as before"
}

test_verify_refusals_happen_before_any_sandbox_exists() {
  local rc
  new_world verifybad
  wrap --kind scout --verify sportsmeet -- claude >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a missing config/sbx-verify refuses"
  assert_not_contains "$(log)" "create " "nothing was created"
  wrap --kind scout --verify other -- claude >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "an unknown verify value refuses"
  assert_not_contains "$(log)" "create " "nothing was created"
  pass "a bad or missing verification setup refuses before the sandbox is created"
}

test_verify_signal_stops_the_broker_and_forces_down() {
  local pid i
  new_world verifysig
  verify_world
  : >"$W/run.hang"
  HOME="$W/userhome" PATH="$FAKE:$PATH" setsid "$RUNSH" --id t1 --config "$CONFIG" --state "$STATE" --data "$DATA" \
    --root "$HOMEDIR" --wt "$WT" --clone "$CLONE" --name "$NAME" --kind scout --verify sportsmeet -- claude >/dev/null 2>/dev/null &
  pid=$!
  for i in $(seq 1 100); do [ -f "$W/run.started" ] && break; sleep 0.1; done
  [ -f "$W/run.started" ] || fail "the sandbox never started"
  printf '{"verb":"up"}' >"$STATE/t1.sbx-verify/req/1.json"
  for i in $(seq 1 100); do [ -f "$STATE/t1.sbx-verify/res/1.json" ] && break; sleep 0.1; done
  [ -f "$STATE/t1.sbx-verify/res/1.json" ] || fail "the broker never answered"
  kill -TERM -- "-$pid"
  for i in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "$pid" 2>/dev/null || fail "the wrapper outlived TERM"
  assert_contains "$(cat "$W/smv.log")" "down" "the emulator is forced down when the wrapper is terminated"
  sleep 1; assert_contains "$(cat "$STATE/t1.sbx-verify/host/audit.log")" broker-stop "the broker ran and stopped with the sandbox"
  assert_absent "$STATE/t1.sbx-verify/host/broker.pid" "no broker is left running"
  pass "terminating a verifying sandbox stops the broker with a forced emulator shutdown"
}

test_creates_with_minimal_mounts_and_cleans_up
test_environment_is_an_explicit_allowlist
test_the_commit_identity_reaches_the_sandbox_environment
test_the_token_enters_only_through_the_sandbox_secret_store
test_no_token_means_no_secret_and_no_network_rule
test_a_symlinked_token_file_is_ignored
test_nm_ship_gets_the_pipeline_environment_and_network
test_nm_ship_clone_is_prepared_before_the_worker_starts
test_nm_ship_gets_the_host_gh_and_survives_one_that_does_not_run
test_nm_version_mismatch_and_pin_refuse
test_nm_init_failure_refuses_and_removes
test_nm_without_a_host_binary_refuses_and_still_removes
test_npm_cache_is_mounted_read_only_with_offline_settings
test_hooks_path_mount_requires_the_homes_own_state
test_links_resolve_the_brief_paths_inside_the_vm
test_refusals_happen_before_any_sandbox_exists
test_a_stopped_daemon_refuses
test_a_failed_create_removes_nothing_foreign_and_reports
test_signals_remove_the_sandbox
test_a_ship_brings_its_commits_back_on_exit
test_verify_flag_mounts_the_spool_and_runs_the_broker
test_verify_flag_off_changes_nothing
test_verify_refusals_happen_before_any_sandbox_exists
test_verify_signal_stops_the_broker_and_forces_down

echo "# all fm-sbx-run tests passed"
