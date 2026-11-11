# shellcheck shell=bash
# Shared helpers for the OpenRouter worker profile: a sandboxed Claude Code
# worker that talks to OpenRouter's Anthropic-compatible API instead of the
# Anthropic API.
#
# Usage: . bin/fm-openrouter-lib.sh   (no FM_* setup required)
#
# The profile is selected per spawn by the model id alone: a Claude worker
# whose model starts with `or:` (--model, or a dispatch profile's model) is an
# OpenRouter worker. `or:<vendor>/<model>` names one OpenRouter model; `or:<alias>`
# names a chain in config/openrouter-models.list ("alias: id1, id2, ...").
# docs/configuration.md "OpenRouter worker profile" owns the operator-facing
# contract; bin/fm-spawn.sh refuses a bad launch before anything is created and
# bin/fm-sbx-run.sh applies the environment and the per-sandbox network rules.
#
# The key is spend-limited and is read on the host only, from the key file. It
# is sent to curl on stdin (never in an argument), never enters the sandbox,
# and is never printed, logged or recorded. Its value must be the OpenRouter
# key charset (A-Za-z0-9._-), because that value is interpolated into the curl
# config. The sandbox holds only
# FM_OPENROUTER_AUTH_PLACEHOLDER, and a sandbox-scoped sbx custom secret lets
# the proxy substitute the real key on requests to openrouter.ai.
#
# Overrides, for tests only:
#   FM_OPENROUTER_KEY_FILE   the key file (default
#                            ~/.config/firstmate/openrouter-worker-key)
#   FM_OPENROUTER_API_URL    the host-side API base (default
#                            https://openrouter.ai/api)
#   FM_OPENROUTER_PROBE_TIMEOUT   seconds one probe is given (default 30)
#   FM_OPENROUTER_CHAIN_BUDGET    seconds the whole chain probe may take
#                                 (default 120)
# This tree never changes the global sbx policy and never passes the key's
# value to any sbx argument; the proxy reads it on demand from the key file.

FM_OPENROUTER_PREFIX='or:'
FM_OPENROUTER_VM_URL=https://openrouter.ai/api
# The host the proxy secret matches is the bare host name: the proxy swaps the
# placeholder on requests to it, and a port suffix would name the host sbx's
# policy rules take, not the proxy's.
# shellcheck disable=SC2034 # Read by the sourcing script (fm-sbx-run.sh).
FM_OPENROUTER_POLICY_HOST=openrouter.ai
# Pinned to the TLS port: the profile needs only HTTPS from OpenRouter, so
# the per-sandbox allow opens just that port and sbx's global deny-all stays
# the floor for every other port.
# shellcheck disable=SC2034 # Read by the sourcing script (fm-sbx-run.sh).
FM_OPENROUTER_ALLOW_HOST=openrouter.ai:443
# The value the worker's ANTHROPIC_AUTH_TOKEN holds inside the sandbox. It is
# not a secret: the sbx proxy swaps it for the real key only on requests to
# FM_OPENROUTER_POLICY_HOST, and OpenRouter refuses it like any wrong key.
# shellcheck disable=SC2034 # Read by the sourcing script (fm-sbx-run.sh).
FM_OPENROUTER_AUTH_PLACEHOLDER='sk-or-placeholder-firstmate'
# The Anthropic API stays closed to an OpenRouter sandbox, so the sbx proxy can
# never attach the captain's sign-in to a request from it.
# shellcheck disable=SC2034 # Read by the sourcing script (fm-sbx-run.sh).
FM_OPENROUTER_ANTHROPIC_HOST=api.anthropic.com
FM_OPENROUTER_COMPACT_WINDOW=200000

# fm_openrouter_is_model <model>: 0 when the model id selects the profile.
fm_openrouter_is_model() {
  case "${1-}" in
  "$FM_OPENROUTER_PREFIX"*) return 0 ;;
  esac
  return 1
}

fm_openrouter_api_url() {
  printf '%s\n' "${FM_OPENROUTER_API_URL:-https://openrouter.ai/api}"
}

fm_openrouter_key_file() {
  printf '%s\n' "${FM_OPENROUTER_KEY_FILE:-${HOME:-/nonexistent}/.config/firstmate/openrouter-worker-key}"
}

# fm_openrouter_key
# Prints the key (whitespace stripped); a clear refusal on stderr and 1 when
# the file is absent, a symlink, empty, or holds a character outside the
# OpenRouter key charset. The key is only ever printed to a command
# substitution that stores it in a variable.
fm_openrouter_key() {
  local f key
  f=$(fm_openrouter_key_file)
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    echo "error: the OpenRouter profile needs its key in $f (a regular file holding the spend-limited worker key)" >&2
    return 1
  fi
  key=$(tr -d '[:space:]' <"$f" 2>/dev/null) || key=
  [ -n "$key" ] || {
    echo "error: the OpenRouter key file $f is empty" >&2
    return 1
  }
  case "$key" in
  *[!A-Za-z0-9._-]*)
    echo "error: the OpenRouter key file $f holds a character outside A-Za-z0-9._-, so the key is refused" >&2
    return 1
    ;;
  esac
  printf '%s\n' "$key"
}

# fm_openrouter_valid_id <id>: 0 for a plain OpenRouter model id.
fm_openrouter_valid_id() {
  case "${1-}" in
  '' | *[!A-Za-z0-9._:/-]* | */ | /* | *//*) return 1 ;;
  */*) return 0 ;;
  esac
  return 1
}

# fm_openrouter_curl <key> <method> <path> [json-body] [max-time]
# One host-side request. The key, URL and body travel as a curl config on
# stdin so nothing secret is in an argument. Prints the HTTP status, or 000.
# A GET prints the response body first, then the status on its own last line.
# max-time defaults to FM_OPENROUTER_PROBE_TIMEOUT.
fm_openrouter_curl() {
  local key=$1 method=$2 path=$3 body=${4-} max_time=${5-} esc cfg
  command -v curl >/dev/null 2>&1 || {
    echo "error: the OpenRouter profile needs curl" >&2
    return 1
  }
  [ -n "$max_time" ] || max_time=${FM_OPENROUTER_PROBE_TIMEOUT:-30}
  cfg=$(printf 'url = "%s%s"\nheader = "Authorization: Bearer %s"\nsilent\nmax-time = %s\nwrite-out = "\\n%%{http_code}"\n' \
    "$(fm_openrouter_api_url)" "$path" "$key" "$max_time")
  if [ "$method" = POST ]; then
    esc=$(printf '%s' "$body" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    cfg=$cfg$(printf '\nheader = "Content-Type: application/json"\ndata = "%s"\noutput = "/dev/null"' "$esc")
  fi
  printf '%s\n' "$cfg" | curl --config - 2>/dev/null || printf '\n000'
}

# fm_openrouter_status <key> <model-id>
# The HTTP status of a 1-token request to the model that only a zero-retention
# endpoint may answer (provider zdr true, data_collection deny).
fm_openrouter_status() {
  local key=$1 id=$2 max_time=${3-} out
  out=$(fm_openrouter_curl "$key" POST /v1/chat/completions \
    "{\"model\":\"$id\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"provider\":{\"zdr\":true,\"data_collection\":\"deny\"}}" \
    "$max_time") || out=
  out=${out##*$'\n'}
  case "$out" in
  [0-9][0-9][0-9]) printf '%s\n' "$out" ;;
  *) printf '000\n' ;;
  esac
}

# fm_openrouter_chain <config-dir> <alias>
# The alias's model ids, one per line, from <config-dir>/openrouter-models.list
# ("alias: id1, id2, ..."; blank and # lines ignored; the first match wins).
fm_openrouter_chain() {
  local f=$1/openrouter-models.list line key rest id
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in *:*) ;; *) continue ;; esac
    key=${line%%:*}
    key=${key%"${key##*[![:space:]]}"}
    [ "$key" = "$2" ] || continue
    rest=${line#*:}
    while [ -n "$rest" ]; do
      id=${rest%%,*}
      if [ "$id" = "$rest" ]; then rest=; else rest=${rest#*,}; fi
      id=${id#"${id%%[![:space:]]*}"}
      id=${id%"${id##*[![:space:]]}"}
      [ -z "$id" ] || printf '%s\n' "$id"
    done
    return 0
  done <"$f"
  return 1
}

# fm_openrouter_resolve <config-dir> <or:model>
# Resolves the spawn's model to one answering OpenRouter id and prints
# "<alias>\t<id>" (the alias is empty for a direct id). Refusals, before
# anything exists: an unusable model id, a :free id, a missing key, no curl,
# an alias with no chain, a key OpenRouter rejects, a spent chain probe
# budget, or no model of the chain answering a 1-token zero-retention request.
# Each chain id is probed in order within FM_OPENROUTER_CHAIN_BUDGET seconds
# and a 402, 429, 5xx, "no endpoint" or timeout skips to the next.
fm_openrouter_resolve() {
  local cfg=$1 arg=${2#"$FM_OPENROUTER_PREFIX"} alias='' ids id key code tried=''
  local budget deadline remaining max_time probe_time budget_spent=''
  if [ -z "$arg" ]; then
    echo "error: the OpenRouter profile needs a model after or: (or:<vendor>/<model>, or an alias from config/openrouter-models.list)" >&2
    return 1
  fi
  case "$arg" in
  */*) ids=$arg ;;
  *)
    alias=$arg
    ids=$(fm_openrouter_chain "$cfg" "$alias") || {
      echo "error: no alias '$alias' in $cfg/openrouter-models.list (lines look like 'alias: vendor/model, vendor/fallback')" >&2
      return 1
    }
    [ -n "$ids" ] || {
      echo "error: the alias '$alias' in $cfg/openrouter-models.list lists no model" >&2
      return 1
    }
    ;;
  esac
  while IFS= read -r id; do
    case "$id" in
    *:free)
      echo "error: $id is a :free OpenRouter model; free models cannot meet the zero-retention requirement and are refused" >&2
      return 1
      ;;
    esac
    fm_openrouter_valid_id "$id" || {
      echo "error: '$id' is not a usable OpenRouter model id (expected vendor/model)" >&2
      return 1
    }
  done <<<"$ids"
  key=$(fm_openrouter_key) || return 1
  command -v curl >/dev/null 2>&1 || {
    echo "error: the OpenRouter profile needs curl to probe the model chain; install it and retry" >&2
    return 1
  }
  budget=${FM_OPENROUTER_CHAIN_BUDGET:-120}
  case "$budget" in '' | *[!0-9]*) budget=120 ;; esac
  [ "$budget" -gt 0 ] || budget=120
  budget=$((10#$budget))
  max_time=${FM_OPENROUTER_PROBE_TIMEOUT:-30}
  case "$max_time" in '' | *[!0-9]*) max_time=30 ;; esac
  [ "$max_time" -gt 0 ] || max_time=30
  deadline=$((SECONDS + budget))
  while IFS= read -r id; do
    remaining=$((deadline - SECONDS))
    if [ "$remaining" -le 0 ]; then
      budget_spent=1
      break
    fi
    if [ "$max_time" -gt "$remaining" ]; then probe_time=$remaining; else probe_time=$max_time; fi
    code=$(fm_openrouter_status "$key" "$id" "$probe_time")
    case "$code" in
    200)
      printf '%s\t%s\n' "$alias" "$id"
      return 0
      ;;
    401 | 403)
      echo "error: OpenRouter rejected the worker key (HTTP $code); check $(fm_openrouter_key_file)" >&2
      return 1
      ;;
    esac
    tried="${tried:+$tried, }$id (HTTP $code)"
  done <<<"$ids"
  if [ -n "$budget_spent" ]; then
    echo "error: the ${budget}s chain probe budget (FM_OPENROUTER_CHAIN_BUDGET) ran out before every id was tried: $tried" >&2
    return 1
  fi
  echo "error: no OpenRouter model answered a 1-token zero-retention request: $tried; a zero-retention endpoint, credit, or capacity is missing" >&2
  return 1
}

# fm_openrouter_env <model-id>
# The environment of an OpenRouter worker, one KEY=VALUE per line, without the
# token (the wrapper adds the placeholder as ANTHROPIC_AUTH_TOKEN itself).
# ANTHROPIC_API_KEY is set empty so Claude Code uses the bearer token. Every
# model tier maps to the one model, and nothing but OpenRouter is contacted by
# the worker's own runtime.
fm_openrouter_env() {
  local m=$1
  printf '%s\n' \
    "ANTHROPIC_BASE_URL=$FM_OPENROUTER_VM_URL" \
    "ANTHROPIC_API_KEY=" \
    "ANTHROPIC_MODEL=$m" \
    "ANTHROPIC_DEFAULT_OPUS_MODEL=$m" \
    "ANTHROPIC_DEFAULT_SONNET_MODEL=$m" \
    "ANTHROPIC_DEFAULT_HAIKU_MODEL=$m" \
    "ANTHROPIC_SMALL_FAST_MODEL=$m" \
    "CLAUDE_CODE_SUBAGENT_MODEL=$m" \
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW=$FM_OPENROUTER_COMPACT_WINDOW" \
    "CLAUDE_CODE_ATTRIBUTION_HEADER=0" \
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
}

# fm_openrouter_usage
# The key's lifetime spend in USD from the top-level data.usage field of
# /api/v1/key, or nothing when it cannot be read. Used before and after a task
# for its cost line.
fm_openrouter_usage() {
  local key out body
  key=$(fm_openrouter_key 2>/dev/null) || return 1
  out=$(fm_openrouter_curl "$key" GET /v1/key) || return 1
  [ "${out##*$'\n'}" = 200 ] || return 1
  body=${out%$'\n'*}
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq -er '.data.usage' 2>/dev/null
    return
  fi
  printf '%s' "$body" | tr -d '\n' | awk '
    {
      if (match($0, /"usage"[[:space:]]*:[[:space:]]*[0-9][0-9.eE+-]*/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^[^:]*:[[:space:]]*/, "", s)
        print s
        found = 1
        exit
      }
    }
    END { exit(found ? 0 : 1) }
  '
}
