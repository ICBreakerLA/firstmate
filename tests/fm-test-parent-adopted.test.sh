#!/usr/bin/env bash
# Behavior tests for the fm_test_parent_adopted helper in tests/lib.sh.
#
# The helper answers "has this process been adopted away from the tree it was
# spawned in", the assertion the reparenting suites share. The answer is
# ancestry-based: the parent chain must reach pid 1 before it touches the
# launching session's own ancestry. The host's adopter is the launching
# session's subreaper, here a WSL relay (comm Relay(<pid>)) under /init, on a
# systemd user session a PR_SET_CHILD_SUBREAPER manager, in a plain sandbox
# pid 1 itself, and under OpenSSH >= 7.6 the session leader itself, which
# carries the flag and sits inside the ancestry, where being a flagged
# adopter outranks being an anchor; the adopters that sit above the
# session's ancestry edge let a released orphan's chain walk to pid 1, while
# a process that never moved walks straight back into its launcher, daemon,
# or session. These cases
# drive real processes through every adopter shape the helper accepts and
# every attached-parent shape it must reject, so the shared assertion can
# never go vacuous: the launcher-parented and daemon-parented cases are the
# regression that keeps a process which never moved red.
#
# Real processes and no vendor harness. The subreaper case needs Linux (the
# Child_subreaper flag is Linux-only) and python3 (prctl through ctypes,
# because no C compiler is a test dependency); it names its skip when either
# is absent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-parent-adopted)

TRACKED_PIDS=()

# kill_children <ppid>: SIGKILL every live child of <ppid>. The fixture
# parents (python Popen, bash -c) own children the suite never sees directly,
# and a reparented child that survives teardown can hold the caller's output
# pipe open long after the suite exits.
kill_children() { # <ppid>
  case "$(uname -s)" in
    Linux) pkill -KILL -P "$1" 2>/dev/null || true ;;
    Darwin) pkill -KILL -p "$1" 2>/dev/null || true ;;
  esac
}

adopted_cleanup() {
  local pid
  kill_children "$$"
  for pid in "${TRACKED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill_children "$pid"
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap adopted_cleanup EXIT

track() { TRACKED_PIDS+=("$1"); }

pid_is_numeric() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

ppid_of() { ps -o ppid= -p "$1" 2>/dev/null | tr -d '[:space:]'; }

comm_of() { ps -o comm= -p "$1" 2>/dev/null | tr -d '[:space:]'; }

# live_parent_child <program> <tag>: run <program> as a live looping parent of
# a `sleep 300` child, launched as a direct child of this script, and write
# "<parent-pid> <child-pid>" to "$TMP_ROOT/<tag>.pair" for the caller to
# read. Callers must not wrap this in command substitution: the substitution
# subshell is the launch parent, and a parent started in it is orphaned away
# from this script the moment the subshell exits, so its child's chain would
# leave the session tree through the parent's own adoption, not through the
# child moving. In the -c script, $1 is the parent's report file ($0 is the
# launcher name). The fixture's descriptors go to /dev/null so it never
# holds a caller's pipe open.
live_parent_child() { # <program> <tag>
  local parent child i
  # shellcheck disable=SC2016 # intentional: the inner shell expands $$, $!, $1, $2
  "$1" -c 'echo "$$" > "$1"; sleep 300 >/dev/null 2>&1 & echo "$!" > "$2"; while :; do sleep 0.2; done' \
    launcher "$TMP_ROOT/$2.parent" "$TMP_ROOT/$2.child" >/dev/null 2>&1 &
  parent=""
  child=""
  i=0
  while [ "$i" -lt 100 ]; do
    if [ -s "$TMP_ROOT/$2.parent" ] && [ -s "$TMP_ROOT/$2.child" ]; then
      parent=$(tr -d '[:space:]' < "$TMP_ROOT/$2.parent")
      child=$(tr -d '[:space:]' < "$TMP_ROOT/$2.child")
      pid_is_numeric "$parent" && pid_is_numeric "$child" && break
    fi
    sleep 0.05
    i=$((i + 1))
  done
  pid_is_numeric "$parent" || fail "the $2 fixture parent did not report a pid"
  pid_is_numeric "$child" || fail "the $2 fixture parent never reported its child pid"
  printf '%s %s\n' "$parent" "$child" > "$TMP_ROOT/$2.pair"
}

test_a_a_process_still_parented_to_its_launcher_is_not_adopted() {
  local child
  sleep 300 >/dev/null 2>&1 &
  child=$!
  track "$child"
  fm_test_parent_adopted "$child" "$$" &&
    fail "the helper called a process parented by its launcher (pid $$) adopted"
  fm_test_parent_adopted "$child" &&
    fail "the no-hint form called a process parented by its launcher adopted (ppid $(ppid_of "$child"))"
  pass "a process still parented to its launcher is not adopted"
}

test_b_a_process_parented_by_a_plain_live_daemon_is_not_adopted() {
  local pair parent child
  live_parent_child "$(command -v bash)" daemon
  pair=$(cat "$TMP_ROOT/daemon.pair")
  parent=${pair% *}
  child=${pair#* }
  track "$parent"
  track "$child"
  # The no-hint form is also the control for every adopter branch: the
  # child's chain walks from its daemon parent into this script's ancestry
  # (an anchor), and the daemon's comm is bash, it is not pid 1, and it
  # carries no subreaper flag.
  fm_test_parent_adopted "$child" "$parent" &&
    fail "the hint form called a daemon-parented process adopted"
  fm_test_parent_adopted "$child" &&
    fail "the no-hint form called a plain-daemon-parented process adopted (ppid $(ppid_of "$child"), parent comm $(comm_of "$parent"))"
  pass "a process parented by a plain live daemon is not adopted"
}

test_c_an_orphan_released_by_its_launcher_exit_is_adopted() {
  local orphan i
  # The launcher backgrounds the child, reports its pid, and exits: the child
  # is reparented to the host's adopter, pid 1 on a plain host, a session
  # relay or a subreaper on the host shapes this helper exists for.
  orphan=$(bash -c 'sleep 300 >/dev/null 2>&1 & echo "$!"')
  pid_is_numeric "$orphan" || fail "the orphan fixture did not report its pid"
  track "$orphan"
  i=0
  while [ "$i" -lt 100 ] && ! fm_test_parent_adopted "$orphan"; do
    sleep 0.05
    i=$((i + 1))
  done
  fm_test_parent_adopted "$orphan" ||
    fail "an orphan released by its launcher's exit was not reported adopted (ppid $(ppid_of "$orphan"))"
  pass "an orphan released by its launcher's exit is adopted"
}

test_d_a_process_parented_by_an_init_named_adopter_is_adopted() {
  local pair parent child
  # The host's WSL2 /init is not pid 1, so this copy pins the command-name
  # secondary fallback alone: ps reports a comm basename on Linux and a full
  # path on macOS, and the helper normalizes both to the name.
  cp "$(command -v bash)" "$TMP_ROOT/init"
  live_parent_child "$TMP_ROOT/init" init
  pair=$(cat "$TMP_ROOT/init.pair")
  parent=${pair% *}
  child=${pair#* }
  track "$parent"
  track "$child"
  [ "$parent" -eq 1 ] &&
    fail "the init-named fixture parent became pid 1, so the case proves nothing"
  fm_test_parent_adopted "$child" ||
    fail "a process parented by a live init-named adopter was not reported adopted (parent comm $(comm_of "$parent"), ppid $(ppid_of "$child"))"
  pass "a process parented by an init-named adopter that is not pid 1 is adopted"
}

test_e_a_process_parented_by_a_relay_named_adopter_is_adopted() {
  local pair child
  # The measured host relay: an orphan's parent 603294 reported comm
  # Relay(603296), and the relay itself sat under /init. The relay sits
  # above the launching session's ancestry edge, so the chain walk adopts
  # it; this copy pins the Relay( prefix fallback too, tolerant of Linux's
  # 15-character comm truncation.
  cp "$(command -v bash)" "$TMP_ROOT/Relay(603296)"
  live_parent_child "$TMP_ROOT/Relay(603296)" relay
  pair=$(cat "$TMP_ROOT/relay.pair")
  child=${pair#* }
  track "$child"
  track "${pair% *}"
  fm_test_parent_adopted "$child" ||
    fail "a process parented by a live Relay(<pid>)-named adopter was not reported adopted (parent comm $(comm_of "${pair% *}"))"
  pass "a process parented by a Relay-named adopter is adopted"
}

test_f_a_subreaper_parent_adopts_and_a_plain_parent_does_not() {
  local sub ctrl sub_child ctrl_child sub_parent i
  if [ "$(uname -s)" != Linux ]; then
    pass "skipped: the Child_subreaper check is Linux-only (uname $(uname -s))"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    pass "skipped: the subreaper fixture needs python3 to call prctl through ctypes"
    return
  fi
  # PR_SET_CHILD_SUBREAPER (36): this python process adopts the children of
  # any of its own children that die, exactly like the systemd user manager
  # that adopts orphans one hop below init on a live host. The fixture's
  # descriptors go to /dev/null so its child processes can never hold the
  # suite caller's output pipe open.
  python3 - "$TMP_ROOT/sub.child" >/dev/null 2>&1 <<'PY' &
import ctypes, subprocess, sys, time
libc = ctypes.CDLL("libc.so.6")
if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
    sys.exit(1)
child = subprocess.Popen(["sleep", "300"])
with open(sys.argv[1], "w") as fh:
    fh.write(str(child.pid))
time.sleep(600)
PY
  sub=$!
  track "$sub"
  # The control: the same child shape under a python3 that set no flag, so
  # the verdict cannot ride on the interpreter name.
  python3 - "$TMP_ROOT/ctrl.child" >/dev/null 2>&1 <<'PY' &
import subprocess, sys, time
child = subprocess.Popen(["sleep", "300"])
with open(sys.argv[1], "w") as fh:
    fh.write(str(child.pid))
time.sleep(600)
PY
  ctrl=$!
  track "$ctrl"
  sub_child=""
  ctrl_child=""
  i=0
  while [ "$i" -lt 100 ]; do
    [ -s "$TMP_ROOT/sub.child" ] && [ -s "$TMP_ROOT/ctrl.child" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  # Track whatever started, before any skip return, so teardown owns it.
  if [ -s "$TMP_ROOT/sub.child" ]; then
    sub_child=$(cat "$TMP_ROOT/sub.child")
    pid_is_numeric "$sub_child" && track "$sub_child"
  fi
  if [ -s "$TMP_ROOT/ctrl.child" ]; then
    ctrl_child=$(cat "$TMP_ROOT/ctrl.child")
    pid_is_numeric "$ctrl_child" && track "$ctrl_child"
  fi
  # Mechanism gate: the helper reads the flag only from /proc/<pid>/status,
  # and stripped kernels can omit that field entirely. A live control parent
  # that set no flag reports the field exactly when the kernel exposes it, so
  # its absence is a capability skip, not a verdict on the helper.
  if ! grep -q '^Child_subreaper:' "/proc/$ctrl/status" 2>/dev/null; then
    pass "skipped: this kernel exposes no Child_subreaper field in /proc/<pid>/status, so the flag check cannot run"
    return
  fi
  if [ ! -s "$TMP_ROOT/sub.child" ] && [ -s "$TMP_ROOT/ctrl.child" ]; then
    pass "skipped: this kernel refused PR_SET_CHILD_SUBREAPER, so the adopter case cannot run"
    return
  fi
  pid_is_numeric "$sub_child" ||
    fail "the subreaper fixture reported no child pid, so the adopter case cannot be asserted"
  pid_is_numeric "$ctrl_child" ||
    fail "the plain-parent control fixture reported no child pid"
  # The fixture is only meaningful if the child really hangs under the
  # process that set the flag, and the flag is read from that live parent
  # rather than assumed from python3.
  sub_parent=$(ppid_of "$sub_child")
  [ "$sub_parent" = "$sub" ] ||
    fail "the subreaper child is not parented by its subreaper fixture (ppid $sub_parent, fixture $sub)"
  grep -q '^Child_subreaper:[[:space:]]*1$' "/proc/$sub_parent/status" 2>/dev/null ||
    fail "the subreaper fixture parent does not report Child_subreaper: 1"
  fm_test_parent_adopted "$sub_child" ||
    fail "a process parented by a PR_SET_CHILD_SUBREAPER process was not reported adopted (parent comm $(comm_of "$sub_parent"))"
  fm_test_parent_adopted "$ctrl_child" &&
    fail "the plain python3 control parent was reported as an adopter"
  pass "a subreaper parent adopts and a plain parent does not"
}

test_h_an_anchor_parent_flagged_as_a_subreaper_is_adopted() {
  local sub ctrl sub_child ctrl_child i
  if [ "$(uname -s)" != Linux ]; then
    pass "skipped: the Child_subreaper check is Linux-only (uname $(uname -s))"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    pass "skipped: the subreaper fixture needs python3 to call prctl through ctypes"
    return
  fi
  # The measured ssh-launched shape: OpenSSH >= 7.6 runs PR_SET_CHILD_SUBREAPER
  # on the session leader, so the host's adopter sits inside the launching
  # ancestry and is an anchor by the helper's own definition. A test process
  # is never spawned directly by the session's leader, so a child hanging on
  # that parent has been released by definition: the flag must outrank anchor
  # membership, exactly as it does for the ssh session leader and as pinned
  # here by naming the fixture parent as an anchor hint. The control is the
  # same launched anchor parent with no flag, which must stay attached.
  python3 - "$TMP_ROOT/h.subchild" >/dev/null 2>&1 <<'PY' &
import ctypes, subprocess, sys, time
libc = ctypes.CDLL("libc.so.6")
if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
    sys.exit(1)
child = subprocess.Popen(["sleep", "300"])
with open(sys.argv[1], "w") as fh:
    fh.write(str(child.pid))
time.sleep(600)
PY
  sub=$!
  track "$sub"
  python3 - "$TMP_ROOT/h.ctrlchild" >/dev/null 2>&1 <<'PY' &
import subprocess, sys, time
child = subprocess.Popen(["sleep", "300"])
with open(sys.argv[1], "w") as fh:
    fh.write(str(child.pid))
time.sleep(600)
PY
  ctrl=$!
  track "$ctrl"
  sub_child=""
  ctrl_child=""
  i=0
  while [ "$i" -lt 100 ]; do
    [ -s "$TMP_ROOT/h.subchild" ] && [ -s "$TMP_ROOT/h.ctrlchild" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  # Track whatever started, before any skip return, so teardown owns it.
  if [ -s "$TMP_ROOT/h.subchild" ]; then
    sub_child=$(cat "$TMP_ROOT/h.subchild")
    pid_is_numeric "$sub_child" && track "$sub_child"
  fi
  if [ -s "$TMP_ROOT/h.ctrlchild" ]; then
    ctrl_child=$(cat "$TMP_ROOT/h.ctrlchild")
    pid_is_numeric "$ctrl_child" && track "$ctrl_child"
  fi
  # Capability skips, read from the live control parent the same way test_f
  # reads them: a stripped kernel that exposes no field, and a kernel that
  # refuses the prctl, are skips, not verdicts on the helper.
  if ! grep -q '^Child_subreaper:' "/proc/$ctrl/status" 2>/dev/null; then
    pass "skipped: this kernel exposes no Child_subreaper field in /proc/<pid>/status, so the flag check cannot run"
    return
  fi
  if [ ! -s "$TMP_ROOT/h.subchild" ] && [ -s "$TMP_ROOT/h.ctrlchild" ]; then
    pass "skipped: this kernel refused PR_SET_CHILD_SUBREAPER, so the adopter case cannot run"
    return
  fi
  pid_is_numeric "$sub_child" ||
    fail "the subreaper fixture reported no child pid, so the anchor case cannot be asserted"
  pid_is_numeric "$ctrl_child" ||
    fail "the plain-anchor control fixture reported no child pid"
  # The shape is only meaningful if each child really hangs under its fixture
  # parent, and that parent is the one carrying (or not carrying) the flag.
  [ "$(ppid_of "$sub_child")" = "$sub" ] ||
    fail "the subreaper child is not parented by its subreaper fixture (ppid $(ppid_of "$sub_child"), fixture $sub)"
  [ "$(ppid_of "$ctrl_child")" = "$ctrl" ] ||
    fail "the control child is not parented by its plain fixture (ppid $(ppid_of "$ctrl_child"), fixture $ctrl)"
  grep -q '^Child_subreaper:[[:space:]]*1$' "/proc/$sub/status" 2>/dev/null ||
    fail "the subreaper fixture parent does not report Child_subreaper: 1"
  fm_test_parent_adopted "$sub_child" "$sub" &&
    fail "an anchor parent flagged Child_subreaper was reported attached (ppid $(ppid_of "$sub_child"))"
  fm_test_parent_adopted "$ctrl_child" "$ctrl" &&
    fail "a plain anchor parent was reported adopted"
  pass "an anchor parent flagged as a subreaper adopts; a plain anchor parent stays attached"
}

test_g_a_child_attached_to_a_live_daemon_is_adopted_when_that_daemon_exits() {
  local daemon child i
  # The session-lock shape in miniature, and the exact reason the answer is a
  # chain walk and not a one-hop parent test: the child hangs under a live
  # daemon two hops below the launcher, so its parent alone names no anchor,
  # and only the walk from daemon up into the launcher's ancestry reports it
  # attached. When the suite releases the daemon, the kernel reparents the
  # child to the session's adopter and the same walk reports it adopted.
  # shellcheck disable=SC2016 # intentional: the inner shell expands $! and $1
  bash -c 'sleep 300 >/dev/null 2>&1 & echo "$!" > "$1"; while [ ! -e "$2" ]; do sleep 0.05; done' \
    daemon "$TMP_ROOT/g.child" "$TMP_ROOT/g.halt" >/dev/null 2>&1 &
  daemon=$!
  track "$daemon"
  child=''
  i=0
  while [ "$i" -lt 100 ]; do
    if [ -s "$TMP_ROOT/g.child" ]; then
      child=$(cat "$TMP_ROOT/g.child")
      pid_is_numeric "$child" && break
    fi
    kill -0 "$daemon" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  pid_is_numeric "$child" || fail "the intermediate daemon never reported its child pid"
  track "$child"
  fm_test_parent_adopted "$child" &&
    fail "a child parented by its live intermediate daemon (ppid $(ppid_of "$child"), daemon $(ppid_of "$daemon") away from the launcher) was reported adopted"
  : > "$TMP_ROOT/g.halt"
  i=0
  while [ "$i" -lt 100 ] && ! fm_test_parent_adopted "$child"; do
    sleep 0.05
    i=$((i + 1))
  done
  fm_test_parent_adopted "$child" ||
    fail "the child was not reported adopted after the intermediate daemon exited (ppid $(ppid_of "$child"))"
  pass "a child attached to its live daemon is adopted only when that daemon exits"
}

fm_test_run \
  test_a_a_process_still_parented_to_its_launcher_is_not_adopted \
  test_b_a_process_parented_by_a_plain_live_daemon_is_not_adopted \
  test_c_an_orphan_released_by_its_launcher_exit_is_adopted \
  test_d_a_process_parented_by_an_init_named_adopter_is_adopted \
  test_e_a_process_parented_by_a_relay_named_adopter_is_adopted \
  test_f_a_subreaper_parent_adopts_and_a_plain_parent_does_not \
  test_g_a_child_attached_to_a_live_daemon_is_adopted_when_that_daemon_exits \
  test_h_an_anchor_parent_flagged_as_a_subreaper_is_adopted
