#!/usr/bin/env bash
# Regression: a pane whose foreground command is bin/claude-sbx (the wrapper
# bin/fm-spawn.sh launches under config/worker-sandbox sbx) must still be read as
# a live Claude agent by the shared process classifier, or supervision would
# report every sandboxed worker as an idle shell.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"

test_the_wrapper_name_classifies_as_an_agent() {
  assert_equals agent "$(fm_agent_process_classify_name claude-sbx)" "the bare name is an agent"
  assert_equals agent "$(fm_agent_process_classify_name "$ROOT/bin/claude-sbx")" "the full path is an agent"
  assert_equals agent "$(fm_agent_process_classify claude-sbx claude-sbx '')" "a process named claude-sbx is an agent"
  assert_equals claude "$(fm_control_harness_family claude)" "the recorded harness stays claude"
  pass "claude-sbx is classified as an agent pane"
}

# The live check: a real tmux pane running the real wrapper, with a fake sbx
# whose `run` stays in the foreground. A script's process is named after its
# interpreter, so the wrapper's own argv[0] is what the backend must read.
test_a_live_pane_running_the_wrapper_reads_alive() {
  local tmp fake out i sockdir
  command -v tmux >/dev/null 2>&1 || { pass "skipped: tmux is not installed"; return; }
  tmp=$(fm_test_tmproot fm-sbx-pane-live)
  fake=$(fm_fakebin "$tmp")
  mkdir -p "$tmp/tmux" "$tmp/state" "$tmp/config" "$tmp/data" "$tmp/wt" "$tmp/state/t1.sbx-clone/.git"
  sockdir="$tmp/tmux/tmux-$(id -u)"
  cat >"$fake/sbx" <<SH
#!/usr/bin/env bash
case "\$1" in
daemon) echo "Status: running" ;;
run) echo "\$\$" >"$tmp/running"; exec sleep 30 ;;
esac
exit 0
SH
  chmod +x "$fake/sbx"
  # An operator pane exports TMUX, which tmux prefers over TMUX_TMPDIR, so both
  # calls drop it and the private server lives only under "$tmp/tmux".
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$tmp/tmux" PATH="$fake:$PATH" tmux new-session -d -s sess -n win -x 100 -y 20 -- \
    "$ROOT/bin/claude-sbx" --id t1 --config "$tmp/config" --state "$tmp/state" --data "$tmp/data" --root "$tmp" \
    --wt "$tmp/wt" --clone "$tmp/state/t1.sbx-clone" --name fm-sbx-0123abcd-t1-9999 --kind scout -- claude
  [ -S "$sockdir/default" ] || fail "the private tmux server must live under the test's own TMUX_TMPDIR"
  for i in $(seq 1 100); do [ -s "$tmp/running" ] && break; sleep 0.1; done
  [ -s "$tmp/running" ] || { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$tmp/tmux" tmux kill-session -t sess 2>/dev/null; fail "the wrapper never reached sbx run"; }
  # shellcheck disable=SC2016 # the single-quoted script expands in the child bash, by design
  out=$(env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$tmp/tmux" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$tmp/tmux" tmux kill-session -t sess 2>/dev/null
  kill "$(cat "$tmp/running")" 2>/dev/null
  assert_equals alive "$out" "a pane running the sandbox wrapper must read as a live agent"
  pass "a live tmux pane running bin/claude-sbx is classified as a live agent"
}

test_the_wrapper_name_classifies_as_an_agent
test_a_live_pane_running_the_wrapper_reads_alive

echo "# all fm-sbx-pane-class tests passed"
