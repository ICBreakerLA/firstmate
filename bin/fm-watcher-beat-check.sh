#!/usr/bin/env bash
# fm-watcher-beat-check.sh - cheap proof that the primary watcher is alive: one
# alarm line when its liveness beacon is older than the grace, silence otherwise.
#
# Usage:
#   fm-watcher-beat-check.sh [--grace SECONDS] [--always]
#   fm-watcher-beat-check.sh --help
#
# The watcher touches state/.last-watcher-beat once per poll cycle, so the beacon
# age is the whole test: a beacon older than the grace (--grace, else
# FM_GUARD_GRACE, else 300 seconds, matching bin/fm-guard.sh) means no watcher has
# polled for that long and nothing is delivering wakes. bin/fm-guard.sh already
# prints a banner, but only when some other guarded command happens to run, so an
# idle session can sit unwatched for hours; this check has no such dependency and
# is meant to be run by something that ticks independently of the watcher (a cron
# entry or the away daemon). A registered state/*.check.sh is not enough, because
# the watcher runs those and cannot report its own absence. It reads the beacon
# and whether this home needs a watcher at all (bin/fm-supervision-lib.sh), so a
# home with nothing in flight stays quiet.
#
# Output, on stdout:
#   watcher-down: the primary watcher beat is <age> old (grace <g>s) ...   alarm
#   watcher-down: the primary watcher has never beaten ...                 alarm
#   with --always, also one `watcher-ok: ...` or `watcher-idle: ...` line.
# Exit 0 when the watcher is healthy or none is needed, 1 when the alarm fired,
# 2 for a usage error. The check is read-only. This is a pure beacon-age test and
# is deliberately not model-aware: under the Claude Stop auto-arm model the watcher
# runs only between turns, so a caller that can run mid-turn should treat an alarm
# there as advisory and consult bin/fm-guard.sh for the model-aware verdict.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}
ALWAYS=0

usage() {
  printf 'usage: fm-watcher-beat-check.sh [--grace SECONDS] [--always]\n'
  printf 'Prints one watcher-down line and exits 1 when the primary watcher beat is older than the grace; silent and exit 0 otherwise.\n'
  printf 'example: bin/fm-watcher-beat-check.sh --grace 120 --always\n'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --always) ALWAYS=1; shift ;;
    --grace) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; GRACE=$2; shift 2 ;;
    *) printf 'fm-watcher-beat-check: unknown argument "%s"\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$GRACE" in
  ''|*[!0-9]*|0) printf 'fm-watcher-beat-check: grace must be a positive whole number of seconds, got "%s"\n' "$GRACE" >&2; exit 2 ;;
esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

fm_supervision_status "$STATE" "$GRACE"
if [ "$FM_SUP_NEEDED" != true ]; then
  [ "$ALWAYS" -eq 0 ] || printf 'watcher-idle: no task, check or source needs a watcher in this home\n'
  exit 0
fi
if [ "$FM_SUP_WATCHER_FRESH" = true ]; then
  [ "$ALWAYS" -eq 0 ] || printf 'watcher-ok: the primary watcher beat is %s (grace %ss)\n' "$FM_SUP_BEACON_DESC" "$GRACE"
  exit 0
fi
case "$FM_SUP_BEACON_DESC" in
  never) printf 'watcher-down: the primary watcher has never beaten in this home while %s task(s) are in flight; no wake can be delivered. Re-arm with bin/fm-watch-arm.sh\n' "$FM_SUP_IN_FLIGHT" ;;
  *) printf 'watcher-down: the primary watcher beat is %s old (grace %ss) with %s task(s) in flight; no wake can be delivered. Re-arm with bin/fm-watch-arm.sh\n' "${FM_SUP_BEACON_DESC% ago}" "$GRACE" "$FM_SUP_IN_FLIGHT" ;;
esac
exit 1
