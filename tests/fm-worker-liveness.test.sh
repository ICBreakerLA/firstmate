#!/usr/bin/env bash
# tests/fm-worker-liveness.test.sh - bin/fm-worker-liveness.sh and the sandbox
# clone leg of crew_worktree_written_since. The endpoint probe is a stand-in
# executable and `sbx` is a stub on PATH; everything else is real files.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

LIVE="$ROOT/bin/fm-worker-liveness.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-liveness-tests)

new_case() { # <name> -> dir with a probe stub (answers $FM_TEST_AGENT_STATE), an sbx stub and a crew-state stub
  local dir
  dir=$(make_case "$1")
  cat > "$dir/probe.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_AGENT_STATE:-dead}"
SH
  cat > "$dir/fakebin/sbx" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = ls ] && { printf '%s\n' ${FM_TEST_SBX_LIST:-}; exit 0; }
exit 0
SH
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_CREW_STATE:-state: idle · source: pane}"
SH
  chmod +x "$dir/probe.sh" "$dir/fakebin/sbx" "$dir/fakebin/fm-crew-state.sh"
  printf '%s\n' "$dir"
}

add_task() { # <dir> <id> [extra meta lines...]
  local dir=$1 id=$2; shift 2
  mkdir -p "$dir/wt-$id"
  { printf 'backend=tmux\nwindow=fm-%s\nworktree=%s\n' "$id" "$dir/wt-$id"; printf '%s\n' "$@"; } > "$dir/state/$id.meta"
}

live() { # <dir> [args...]
  local dir=$1; shift
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_WORKER_LIVENESS_STATE_BIN="$dir/probe.sh" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    bash "$LIVE" "$@"
}

age_file() { touch -d "@$(( $(date +%s) - $2 ))" "$1"; }

test_help_and_usage() {
  local dir out rc
  dir=$(new_case wl-help)
  out=$(live "$dir" --help) || fail "--help should exit 0"
  printf '%s\n' "$out" | grep -F 'usage:' >/dev/null || fail "no usage line"
  live "$dir" --bogus >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown argument should exit 2, got $rc"
  FM_LIVENESS_ACTIVE_SECS=abc live "$dir" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "a non-numeric bound should exit 2, got $rc"
  pass "help, unknown argument and a bad bound are refused with usage"
}

test_alive_and_unproven_states_are_silent() {
  local dir out s
  dir=$(new_case wl-alive); add_task "$dir" t1
  for s in alive ambiguous unreadable unverified; do
    out=$(FM_TEST_AGENT_STATE=$s live "$dir") || fail "check failed for $s"
    [ -z "$out" ] || fail "state $s must stay silent, got: $out"
  done
  pass "only a dead or missing endpoint can raise; every other probe answer is silent"
}

test_dead_plain_worker_raises_once() {
  local dir out
  dir=$(new_case wl-dead); add_task "$dir" t1
  out=$(FM_TEST_AGENT_STATE=dead live "$dir") || fail "check failed"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] || fail "expected one alarm line: $out"
  printf '%s\n' "$out" | grep -F 'worker-liveness: t1 agent process gone' >/dev/null || fail "wrong alarm: $out"
  out=$(FM_TEST_AGENT_STATE=missing live "$dir" --task nope) || fail "check failed"
  [ -z "$out" ] || fail "--task for another id should be silent: $out"
  pass "a dead worker with no wait and no run raises one alarm line, and --task narrows it"
}

test_secondmate_and_remote_are_skipped() {
  local dir out
  dir=$(new_case wl-skip)
  add_task "$dir" mate kind=secondmate
  add_task "$dir" far remote_host=box
  out=$(FM_TEST_AGENT_STATE=dead live "$dir") || fail "check failed"
  [ -z "$out" ] || fail "a secondmate or remote task must not raise here: $out"
  pass "secondmates and remote tasks are left to their own liveness paths"
}

test_declared_wait_and_active_run_suppress_with_bound() {
  local dir out
  dir=$(new_case wl-wait); add_task "$dir" t1
  printf 'paused [at=1]: waiting on CI\n' > "$dir/state/t1.status"
  out=$(FM_TEST_AGENT_STATE=dead live "$dir") || fail "check failed"
  [ -z "$out" ] || fail "a fresh declared wait must suppress: $out"
  age_file "$dir/state/t1.status" 7200
  out=$(FM_TEST_AGENT_STATE=dead live "$dir") || fail "check failed"
  printf '%s\n' "$out" | grep -F 'worker-liveness: t1' >/dev/null || fail "a forgotten wait must resurface"
  : > "$dir/state/t1.status"
  out=$(FM_TEST_AGENT_STATE=dead FM_TEST_CREW_STATE='state: working · source: run-step · running ci' live "$dir") || fail "check failed"
  [ -z "$out" ] || fail "an active pipeline run must suppress: $out"
  out=$(FM_TEST_AGENT_STATE=dead FM_TEST_CREW_STATE='state: idle · source: pane' live "$dir" --explain) || fail "check failed"
  printf '%s\n' "$out" | grep -P '^t1\traise\t' >/dev/null || fail "explain should show the raise: $out"
  pass "a declared wait (bounded) or an active run keeps a pane-less worker from alarming"
}

test_sandboxed_worker() {
  local dir out
  dir=$(new_case wl-sbx)
  add_task "$dir" t1 sandbox=sbx sandbox_name=fm-t1-vm
  mkdir -p "$dir/state/t1.sbx-clone"
  # VM gone: raised.
  out=$(FM_TEST_AGENT_STATE=dead FM_TEST_SBX_LIST='' live "$dir") || fail "check failed"
  printf '%s\n' "$out" | grep -F 'is not listed' >/dev/null || fail "an unlisted VM must raise: $out"
  # VM listed, clone written now: accounted.
  : > "$dir/state/t1.sbx-clone/work.txt"
  out=$(FM_TEST_AGENT_STATE=dead FM_TEST_SBX_LIST='fm-t1-vm' live "$dir") || fail "check failed"
  [ -z "$out" ] || fail "a listed VM with a fresh clone write must stay silent: $out"
  out=$(FM_TEST_AGENT_STATE=dead FM_TEST_SBX_LIST='fm-t1-vm' live "$dir" --explain)
  printf '%s\n' "$out" | grep -P '^t1\taccounted\tsandboxed' >/dev/null || fail "explain should account for it: $out"
  # VM listed, everything old, no report: raised.
  age_file "$dir/state/t1.sbx-clone/work.txt" 7200; age_file "$dir/state/t1.sbx-clone" 7200
  out=$(FM_TEST_AGENT_STATE=dead FM_TEST_SBX_LIST='fm-t1-vm' live "$dir") || fail "check failed"
  printf '%s\n' "$out" | grep -F 'no clone write or report' >/dev/null || fail "a silent listed VM must raise: $out"
  # VM listed, clone quiet but a fresh status line: accounted.
  printf 'working [at=1]: x\n' > "$dir/state/t1.status"
  out=$(FM_TEST_AGENT_STATE=dead FM_TEST_SBX_LIST='fm-t1-vm' live "$dir") || fail "check failed"
  [ -z "$out" ] || fail "a recent status report must account for a listed VM: $out"
  pass "a sandboxed worker is accounted for only while its VM is listed and still active"
}

test_write_probe_sees_the_sbx_clone() {
  local case_dir anchor
  case_dir=$(new_case wl-probe); add_task "$case_dir" t1 sandbox=sbx sandbox_name=fm-t1-vm
  mkdir -p "$case_dir/state/t1.sbx-clone"
  anchor="$case_dir/anchor"; : > "$anchor"; age_file "$anchor" 60
  ( . "$ROOT/bin/fm-wake-lib.sh"; . "$ROOT/bin/fm-classify-lib.sh"
    crew_worktree_written_since t1 "$case_dir/state" "$anchor" ) \
    && fail "a quiet host worktree and quiet clone must read as no write"
  : > "$case_dir/state/t1.sbx-clone/edit.txt"
  ( . "$ROOT/bin/fm-wake-lib.sh"; . "$ROOT/bin/fm-classify-lib.sh"
    crew_worktree_written_since t1 "$case_dir/state" "$anchor" ) \
    || fail "a write inside the sandbox clone must count as write evidence"
  # A task that is not sandboxed ignores a stray clone directory.
  add_task "$case_dir" t2; mkdir -p "$case_dir/state/t2.sbx-clone"; : > "$case_dir/state/t2.sbx-clone/x"
  ( . "$ROOT/bin/fm-wake-lib.sh"; . "$ROOT/bin/fm-classify-lib.sh"
    crew_worktree_written_since t2 "$case_dir/state" "$anchor" ) \
    && fail "a non-sandboxed task must not read a stray clone directory"
  pass "the write probe counts the sandbox clone for sandboxed tasks only"
}

test_slow_run_read_does_not_suppress_other_alarms() {
  local dir out start
  dir=$(new_case wl-slow); add_task "$dir" slow; add_task "$dir" fast
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = slow ] && exec sleep 20
printf 'state: idle · source: pane\n'
SH
  start=$(date +%s)
  out=$(FM_TEST_AGENT_STATE=dead FM_LIVENESS_READ_TIMEOUT=1 live "$dir") || fail "check failed"
  [ $(( $(date +%s) - start )) -lt 10 ] || fail "the slow run read was not bounded"
  printf '%s\n' "$out" | grep -F 'worker-liveness: fast agent process gone' >/dev/null || fail "the other worker's alarm was lost: $out"
  if printf '%s\n' "$out" | grep -F 'worker-liveness: slow' >/dev/null; then fail "a timed-out read must not raise: $out"; fi
  out=$(FM_TEST_AGENT_STATE=dead FM_LIVENESS_READ_TIMEOUT=1 live "$dir" --task slow --explain) || fail "check failed"
  printf '%s\n' "$out" | grep -P '^slow\tsilent\t.*timed out' >/dev/null || fail "explain should show the timed-out read: $out"
  pass "a run read that times out stays silent for that worker and keeps the other workers' alarms"
}

test_help_and_usage
test_alive_and_unproven_states_are_silent
test_dead_plain_worker_raises_once
test_secondmate_and_remote_are_skipped
test_declared_wait_and_active_run_suppress_with_bound
test_sandboxed_worker
test_write_probe_sees_the_sbx_clone
test_slow_run_read_does_not_suppress_other_alarms
