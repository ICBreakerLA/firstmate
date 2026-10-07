#!/usr/bin/env bash
# Quota-exhaustion process-event adapter.
#
# Usage:
#   fm-procevent-quota.sh arm [--interval <secs>] [--threshold <percent>] [--provider <provider>]
#   fm-procevent-quota.sh poll [--interval <secs>] [--threshold <percent>] [--provider <provider>] [--timeout <secs>]
#   fm-procevent-quota.sh classify <result-file>
#   fm-procevent-quota.sh terminal <result-file>
#   fm-procevent-quota.sh source-id
#   fm-procevent-quota.sh retire [--provider <provider>]
#
# arm        Register a recurring quota-axi --json poll that wakes firstmate
#            when the tracked provider's effectivePercentRemaining drops below
#            <threshold> (default 10%) or when its runway.status becomes
#            exhausted_now. The condition is deterministic, the action is only
#            the durable `check: procevent:quota:<seq>` wake, and the watch is
#            registered through `bin/fm-procevent.sh register`.
# poll       The blocking child the generic runner executes; never run this
#            directly in a conversational turn. It polls `quota-axi --json`
#            until quota drops below the threshold, quota burns faster than
#            the configured hourly rate, invalid quota data stops the watch,
#            or three consecutive transient command failures stop it. Missing
#            or incompatible tools stop it immediately, and a successful read
#            resets the command-failure streak.
# classify   Print the captured outcome class: low, exhausted, burn, error, or unknown.
# terminal   Every quota poll is terminal because the source fires at most once.
# source-id  Print the canonical source id.
# retire     Stop the aggregate watch, or the matching provider watch when
#            --provider is supplied, and retire the registration.
#
# The canonical source id is `quota` for the aggregate tracked provider.
# A provider named with --provider sets the tracked provider and the source id
# becomes `quota-<provider>`.
#
# Burn-rate alert: every successful read also records each known scope's
# effectivePercentRemaining in $STATE/quota-burn/<source-id>.tsv, pruned to the
# last hour. The percent consumed over that hour is the sum of the positive
# drops between consecutive samples of one provider, account and scope, so a
# window reset never counts as spend, and the largest per-scope total is the
# burn. When it exceeds the limit in config/quota-burn-percent-per-hour
# (percent per hour, default 50, `off` or 0 disables, read on every poll) the
# poll ends with status burn. One wake per episode: an episode marker keeps a
# re-armed poll silent until the burn has fallen back to the limit. The alert
# only wakes firstmate; nothing is approved, answered or stopped. It adds no
# data source beyond the same quota-axi snapshot.
#
# Snapshots may be quota-axi schema 5 or 6 (bin/fm-quota-axi-lib.sh owns the
# validator). Both watches read every matching account row independently,
# without combining quotas. A --provider watch restricts those rows to the
# requested provider; details preserve each row's accountKey when present.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

DEFAULT_INTERVAL=60
DEFAULT_THRESHOLD=10
# Consecutive transient quota-axi read failures before poll goes terminal.
# Missing and incompatible tools bypass this budget. No config knob on purpose.
MAX_CONSECUTIVE_READ_FAILURES=3

# Burn-rate alert: the one-hour window is fixed, the limit is configurable.
BURN_WINDOW_SECS=3600
DEFAULT_BURN_LIMIT=50
BURN_DIR="$STATE/quota-burn"
BURN_CONFIG_FILE="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/quota-burn-percent-per-hour"

SOURCE_ID_BASE=quota

CANONICAL_SOURCE_ID=
PROVIDER=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

resolve_provider() {
  local LC_ALL=C
  PROVIDER=${1:-}
  if [ -n "$PROVIDER" ]; then
    [[ "$PROVIDER" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "invalid provider: $PROVIDER"
    CANONICAL_SOURCE_ID="$SOURCE_ID_BASE-$PROVIDER"
  else
    CANONICAL_SOURCE_ID=$SOURCE_ID_BASE
    PROVIDER=
  fi
  fm_procevent_source_id_valid "$CANONICAL_SOURCE_ID" || die "source id is not path-safe: $CANONICAL_SOURCE_ID"
}

positive_number() {
  local n=${1-}
  local LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [ "$n" != 0 ] && [[ ! "$n" =~ ^0+(\.0+)?$ ]]
}

positive_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) return 0 ;; esac }

valid_percent() {
  local n=${1-}
  local LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  jq -en --arg n "$n" '($n | tonumber) <= 100' >/dev/null 2>&1
}

# quota_json [timeout]
# Run `quota-axi --json` bounded by the given timeout.
# Exit status: 0 prints JSON; 1 timed out; 2 missing; 3 incompatible; 4 other failure.
# A missing or incompatible quota-axi is an error condition, not a signal to fire.
# Callers tolerate a bounded streak of 1/4 before going terminal; 2/3 stay distinct.
# Each path probes --version once, validates that captured text through
# fm_quota_axi_version_compatible, then probes --json once.
# A slow or failing probe stays 1/4; "incompatible" is reserved for an actual
# unsupported or unparseable version string.
quota_json() {
  local timeout=${1:-} output rc=0
  if ! command -v quota-axi >/dev/null 2>&1; then
    return 2
  fi
  if [ -n "$timeout" ]; then
    rc=0
    output=$(fm_run_timed "$timeout" quota-axi --version 2>/dev/null </dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
      if fm_timed_out "$rc"; then
        return 1
      fi
      return 4
    fi
    fm_quota_axi_version_compatible "$output" || return 3
    rc=0
    output=$(fm_run_timed "$timeout" quota-axi --json 2>/dev/null </dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
      if fm_timed_out "$rc"; then
        return 1
      fi
      return 4
    fi
  else
    rc=0
    output=$(quota-axi --version 2>/dev/null </dev/null) || rc=$?
    [ "$rc" -eq 0 ] || return 4
    fm_quota_axi_version_compatible "$output" || return 3
    output=$(quota-axi --json 2>/dev/null </dev/null) || return 4
  fi
  printf '%s\n' "$output"
}

# condition_status <json> [provider] [threshold]
# Print healthy, low, exhausted, or error for the tightest known applicable
# quota scope.
condition_status() {
  local json=$1 provider=${2:-} threshold=${3:-$DEFAULT_THRESHOLD}
  printf '%s\n' "$json" | fm_quota_json_valid || { printf 'error\n'; return; }
  printf '%s\n' "$json" | jq -r --arg provider "$provider" --arg threshold "$threshold" '
    def classify($availability):
      ($availability | map(select(.status == "known"))) as $known |
      if ($availability | length) == 0 then "error"
      elif any($availability[]; (.runway.status // "") == "exhausted_now") then "exhausted"
      elif ($known | length) == 0 then "healthy"
      elif any($known[]; .effectivePercentRemaining < ($threshold | tonumber)) then "low"
      else "healthy"
      end;
    .providers |= map(select($provider == "" or .provider == $provider)) |
    if (.providers | length) == 0 and $provider != "" then "error"
    elif ([.providers[]?.quotaSemantics.effectiveAvailability[]?] | length) == 0 then "healthy"
    else classify([.providers[]?.quotaSemantics.effectiveAvailability[]?])
    end
  ' 2>/dev/null || printf 'error\n'
}

# details <json> [provider]
# Print a one-line summary of the quota state for the result document.
details() {
  local json=$1 provider=${2:-}
  printf '%s\n' "$json" | jq -c --arg provider "$provider" '
    def best_detail($availability):
      ($availability | map(select(.status == "known"))) as $known |
      ($availability | map(select((.runway.status // "") == "exhausted_now"))) as $exhausted |
      if ($exhausted | length) > 0 then ($exhausted | min_by(.effectivePercentRemaining // 101))
      elif ($known | length) > 0 then ($known | min_by(.effectivePercentRemaining))
      else null
      end;
    [.providers[]? | select($provider == "" or .provider == $provider) |
      {provider}
      + (if has("accountKey") then {accountKey} else {} end)
      + {best: best_detail(.quotaSemantics.effectiveAvailability // [])}
    ] as $summary |
    if $provider == "" or ($summary | length) > 1 then
      {
        provider: (if $provider == "" then "aggregate" else $provider end),
        summary: $summary
      }
    else
      $summary[0] // {provider: $provider, best: null}
    end
  ' 2>/dev/null
}

# burn_limit
# Print the configured percent-per-hour limit, or nothing when the alert is off.
# A missing or unreadable file uses the default and a malformed value does too,
# so a typo never silently disables the guard.
burn_limit() {
  local raw=
  if [ -f "$BURN_CONFIG_FILE" ]; then
    IFS= read -r raw < "$BURN_CONFIG_FILE" || true
    raw=${raw//[[:space:]]/}
  fi
  case "$raw" in
    '') printf '%s\n' "$DEFAULT_BURN_LIMIT" ;;
    off|OFF|Off) return 0 ;;
    *) if positive_number "$raw"; then printf '%s\n' "$raw"
       elif [[ "$raw" =~ ^0+(\.0+)?$ ]]; then return 0
       else printf '%s\n' "$DEFAULT_BURN_LIMIT"
       fi ;;
  esac
}

# burn_samples <json> [provider]
# Print one `key<TAB>percent` line per known scope, tightest value per key.
burn_samples() {
  printf '%s\n' "$1" | jq -r --arg provider "${2:-}" '
    [.providers[]? | select($provider == "" or .provider == $provider) as $p
     | $p.quotaSemantics.effectiveAvailability[]?
     | select(.status == "known")
     | {key: ([$p.provider, ($p.accountKey // ""), .scope] | join("|")), pct: .effectivePercentRemaining}]
    | group_by(.key) | map({key: .[0].key, pct: (map(.pct) | min)})[]
    | [.key, (.pct | tostring)] | @tsv
  ' 2>/dev/null
}

# burn_record <source-id> <samples> <now>
# Append this read to the hourly history and prune what has aged out of the
# window. The rewrite is atomic so a killed poll never leaves a torn file.
burn_record() {
  local id=$1 samples=$2 now=$3 file tmp
  file="$BURN_DIR/$id.tsv"
  tmp="$file.tmp.$$"
  mkdir -p "$BURN_DIR" 2>/dev/null || return 1
  {
    [ ! -f "$file" ] || awk -F'\t' -v cutoff=$((now - BURN_WINDOW_SECS)) '
      $1 ~ /^[0-9]+$/ && $1 > cutoff && NF == 3 { print }
    ' "$file"
    [ -z "$samples" ] || printf '%s\n' "$samples" | awk -F'\t' -v now="$now" 'NF == 2 { print now "\t" $1 "\t" $2 }'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# burn_consumed <source-id>
# Print `consumed<TAB>key` for the scope that spent the most over the window.
burn_consumed() {
  local file="$BURN_DIR/$1.tsv"
  [ -f "$file" ] || { printf '0\t\n'; return; }
  awk -F'\t' '
    $1 ~ /^[0-9]+$/ && NF == 3 {
      k = $2
      if ((k in last) && last[k] > $3 + 0) sum[k] += last[k] - $3
      last[k] = $3 + 0
      if (!(k in sum)) sum[k] = sum[k] + 0
    }
    END {
      best = 0; bk = ""
      for (k in sum) if (sum[k] > best) { best = sum[k]; bk = k }
      printf "%.2f\t%s\n", best, bk
    }
  ' "$file"
}

# burn_check <source-id> <json> <provider>
# Return 0 and print the burn detail JSON when this read starts a burn episode.
burn_check() {
  local id=$1 json=$2 provider=$3 limit samples now consumed key marker over
  limit=$(burn_limit)
  [ -n "$limit" ] || return 1
  samples=$(burn_samples "$json" "$provider")
  now=$(date +%s)
  burn_record "$id" "$samples" "$now" || return 1
  IFS=$'\t' read -r consumed key <<<"$(burn_consumed "$id")"
  marker="$BURN_DIR/$id.burn-episode"
  over=$(jq -en --arg c "${consumed:-0}" --arg l "$limit" '($c | tonumber) > ($l | tonumber)' 2>/dev/null) || over=false
  if [ "$over" != true ]; then
    rm -f "$marker"
    return 1
  fi
  [ ! -e "$marker" ] || return 1
  : > "$marker" || return 1
  jq -cn --arg c "$consumed" --arg l "$limit" --arg k "$key" --argjson w "$BURN_WINDOW_SECS" \
    '{consumed: ($c | tonumber), limit: ($l | tonumber), windowSecs: $w, key: $k}'
}

cmd_source_id() {
  resolve_provider "${1-}"
  printf '%s\n' "$CANONICAL_SOURCE_ID"
}

cmd_arm() {
  local interval=$DEFAULT_INTERVAL threshold=$DEFAULT_THRESHOLD
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval)  positive_number "${2-}" || die "--interval needs a positive number"; interval=$2; shift 2 ;;
      --threshold) valid_percent "${2-}" || die "--threshold needs a percent 0-100"; threshold=$2; shift 2 ;;
      --provider)  [ -n "${2-}" ] || die "--provider needs a value"; resolve_provider "$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  resolve_provider "$PROVIDER"
  fm_quota_axi_compatible 5 >/dev/null 2>&1 || die "quota-axi is missing or below the compatibility floor"
  local timeout
  timeout=$(perl -e 'print int($ARGV[0] * 0.8 + 0.5)' "$interval") || timeout=30
  [ "$timeout" -ge 5 ] || timeout=5
  "$SCRIPT_DIR/fm-procevent.sh" register quota "$CANONICAL_SOURCE_ID" \
    -- "$SCRIPT_DIR/fm-procevent-quota.sh" poll --interval "$interval" --threshold "$threshold" --provider "$PROVIDER" --timeout "$timeout" || exit 1
  printf 'armed: %s\n' "$CANONICAL_SOURCE_ID"
  printf 'provider: %s\n' "${PROVIDER:-(aggregate)}"
  printf 'threshold: %s%%\n' "$threshold"
  printf 'interval: %ss\n' "$interval"
}

# For use inside the runner: parse the spec argv and run one condition evaluation.
# This is intentionally not the public `arm` path; the runner calls this command
# directly, so the argv must match the registration.
cmd_poll() {
  local interval=$DEFAULT_INTERVAL threshold=$DEFAULT_THRESHOLD timeout=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval)  [ "$#" -ge 2 ] || die "--interval needs a positive number"; interval=$2; shift 2 ;;
      --threshold) [ "$#" -ge 2 ] || die "--threshold needs a percent 0-100"; threshold=$2; shift 2 ;;
      --provider)  [ "$#" -ge 2 ] || die "--provider needs a value"; PROVIDER=$2; shift 2 ;;
      --timeout)   [ "$#" -ge 2 ] || die "--timeout needs a positive integer"; timeout=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  positive_number "$interval" || die "--interval needs a positive number"
  valid_percent "$threshold" || die "--threshold needs a percent 0-100"
  [ -z "$timeout" ] || positive_int "$timeout" || die "--timeout needs a positive integer"
  resolve_provider "$PROVIDER"
  local json detail status polls=0 consecutive_failures=0 read_rc detail_msg burn_detail
  while :; do
    polls=$((polls + 1))
    json=$(quota_json "${timeout:-}") && read_rc=0 || read_rc=$?
    if [ "$read_rc" -ne 0 ]; then
      consecutive_failures=$((consecutive_failures + 1))
      if [ "$read_rc" -ne 2 ] && [ "$read_rc" -ne 3 ] && \
         [ "$consecutive_failures" -lt "$MAX_CONSECUTIVE_READ_FAILURES" ]; then
        sleep "$interval"
        continue
      fi
      case "$read_rc" in
        1) detail_msg="${consecutive_failures} consecutive read failures; last quota-axi read timed out" ;;
        2) detail_msg="quota-axi is missing" ;;
        3) detail_msg="quota-axi is incompatible" ;;
        *) detail_msg="${consecutive_failures} consecutive read failures; last quota-axi read failed" ;;
      esac
      printf 'quota: %s\n' "$CANONICAL_SOURCE_ID"
      printf 'status: error\n'
      printf 'detail: %s\n' "$detail_msg"
      printf 'condition_polls: %s\n' "$polls"
      exit 0
    fi
    consecutive_failures=0
    status=$(condition_status "$json" "$PROVIDER" "$threshold")
    burn_detail=
    if [ "$status" != error ]; then
      burn_detail=$(burn_check "$CANONICAL_SOURCE_ID" "$json" "$PROVIDER") || burn_detail=
    fi
    case "$status" in
      healthy)
        if [ -z "$burn_detail" ]; then sleep "$interval"; continue; fi
        status=burn ;;
      low|exhausted) : ;;
      *) status=error ;;
    esac
    if [ "$status" = burn ]; then detail=$burn_detail; else detail=$(details "$json" "$PROVIDER"); fi
    printf 'quota: %s\n' "$CANONICAL_SOURCE_ID"
    printf 'status: %s\n' "$status"
    printf 'detail: %s\n' "$detail"
    printf 'condition_polls: %s\n' "$polls"
    exit 0
  done
}

cmd_classify() {
  local file=${1-} status
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(awk '
    $0 == "output:" { exit }
    /^status: / { sub(/^status: /, ""); print; exit }
  ' "$file")
  case "$status" in
    low|exhausted|burn|error) printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" != unknown ]
}

cmd_retire() {
  local id provider=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --provider) [ -n "${2-}" ] || die "--provider needs a value"; provider=$2; shift 2 ;;
      -*) usage ;;
      *) [ -z "$provider" ] || usage; provider=$1; shift ;;
    esac
  done
  resolve_provider "$provider"
  id=$CANONICAL_SOURCE_ID
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id" || return $?
  rm -f "$BURN_DIR/$id.tsv" "$BURN_DIR/$id.burn-episode"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  source-id) shift; cmd_source_id "${1-}" ;;
  retire)    shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
