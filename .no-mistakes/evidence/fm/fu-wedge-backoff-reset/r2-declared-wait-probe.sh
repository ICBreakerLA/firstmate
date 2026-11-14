#!/usr/bin/env bash
# Behavioural probe of the real R2 predicate in bin/fm-wake-triage-lib.sh.
# Each case writes a status log into a throwaway state dir and asks the library
# (the same code fm-watch.sh runs) whether the task stands in a declared wait.
set -u
ROOT=${1:?usage: probe.sh <repo-root>}
cd "$ROOT" || exit 1
WORK=$(mktemp -d "${TMPDIR:-/tmp}/r2-probe.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
STATE=$WORK/state; CONFIG=$WORK/config; mkdir -p "$STATE" "$CONFIG"
# shellcheck source=/dev/null
. tests/watch-triage-helpers.sh
# shellcheck source=/dev/null
. bin/fm-wake-triage-lib.sh
wake_triage_init

probe() { # <name> <expected:wait|answered> <status-file-content...>
  local name=$1 expect=$2 f="$STATE/$1.status" got
  shift 2
  printf '%s\n' "$@" > "$f"
  if wake_triage_declared_wait "$f"; then got=wait; else got=answered; fi
  printf '%-46s declared-wait=%s (expected %s) %s\n' "$name" "$got" "$expect" \
    "$([ "$got" = "$expect" ] && echo PASS || echo FAIL)"
  [ "$got" = "$expect" ]
}

rc=0
# The exact state from the recorded review decision: two holds on keys k1/k2,
# then firstmate answers only k1. The k2 hold is still standing.
probe reported-k2-hold 'wait' \
  'captain-held [key=k1]: tracked by k1,k2' \
  'captain-held [key=k2]: tracked by k1,k2' \
  'resolved [key=k1]: answered' || rc=1
# The originally reported bug: a delivered green PR, then an answer to an
# unrelated older decision. The delivery is still the newest worker word.
probe done-under-unrelated-resolve 'wait' \
  'done [at=1794000000]: PR https://example.test/pr/200 checks green' \
  'resolved [at=1794000100] [key=older-decision]: answered by firstmate' || rc=1
# An answer that closes the done's own (keyless) phase does end the wait.
probe done-under-own-resolve 'answered' \
  'done [at=1794000000]: PR https://example.test/pr/200 checks green' \
  'resolved [at=1794000100]: answered by firstmate' || rc=1
# A pause keeps standing across an answer to a different key.
probe paused-under-unrelated-resolve 'wait' \
  'paused: waiting on upstream consent' \
  'resolved [key=older-decision]: answered by firstmate' || rc=1
# And its own resolve retracts it.
probe paused-under-own-resolve 'answered' \
  'paused: waiting on upstream consent' \
  'resolved: continued' || rc=1

# End-to-end through the gate: the reported held delivery emits once, then the
# next stale inside the R2 window is suppressed and the marker is written.
printf 'window=probe:held\n' > "$STATE/gate.meta"
printf '%s\n' \
  'done [at=1794000000]: PR https://example.test/pr/200 checks green' \
  'resolved [at=1794000100] [key=older-decision]: answered by firstmate' > "$STATE/gate.status"
wake_triage_gate stale gate probe-key 'stale: x' 240
first=$WAKE_TRIAGE_ACTION
marker=$([ -e "$STATE/.wake-backoff-gate" ] && echo written || echo missing)
wake_triage_gate stale gate probe-key 'stale: x' 240
second=$WAKE_TRIAGE_ACTION
printf '%-46s first=%s marker=%s second=%s %s\n' gate-emit-then-back-off "$first" "$marker" "$second" \
  "$([ "$first" = emit ] && [ "$marker" = written ] && [ "$second" = suppress ] && echo PASS || echo FAIL)"
[ "$first" = emit ] && [ "$marker" = written ] && [ "$second" = suppress ] || rc=1
exit "$rc"
