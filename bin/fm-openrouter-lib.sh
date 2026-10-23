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
# is sent to curl on stdin (never in an argument), goes into the sandbox only
# as the worker's ANTHROPIC_AUTH_TOKEN, and is never printed, logged or
# recorded.
#
# Overrides, for tests only:
#   FM_OPENROUTER_KEY_FILE   the key file (default
#                            ~/.config/firstmate/openrouter-worker-key)
#   FM_OPENROUTER_API_URL    the host-side API base (default
#                            https://openrouter.ai/api)
#   FM_OPENROUTER_PROBE_TIMEOUT   seconds one probe is given (default 30)
# This tree never changes the global sbx policy and never passes a host secret
# other than the OpenRouter key.

FM_OPENROUTER_PREFIX='or:'
FM_OPENROUTER_VM_URL=https://openrouter.ai/api
# shellcheck disable=SC2034 # Read by the sourcing script (fm-sbx-run.sh).
FM_OPENROUTER_POLICY_HOST=openrouter.ai
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
# the file is absent, a symlink, or empty. The key is only ever printed to a
# command substitution that stores it in a variable.
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

# fm_openrouter_curl <key> <method> <path> [json-body]
# One host-side request. The key, URL and body travel as a curl config on
# stdin so nothing secret is in an argument. Prints the HTTP status, or 000.
# A GET prints the response body first, then the status on its own last line.
fm_openrouter_curl() {
  local key=$1 method=$2 path=$3 body=${4-} esc cfg
  command -v curl >/dev/null 2>&1 || {
    echo "error: the OpenRouter profile needs curl" >&2
    return 1
  }
  cfg=$(printf 'url = "%s%s"\nheader = "Authorization: Bearer %s"\nsilent\nmax-time = %s\nwrite-out = "\\n%%{http_code}"\n' \
    "$(fm_openrouter_api_url)" "$path" "$key" "${FM_OPENROUTER_PROBE_TIMEOUT:-30}")
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
  local key=$1 id=$2 out
  out=$(fm_openrouter_curl "$key" POST /v1/chat/completions \
    "{\"model\":\"$id\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"provider\":{\"zdr\":true,\"data_collection\":\"deny\"}}") || out=
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
# anything exists: an unusable model id, a :free id, a missing key, an alias
# with no chain, a key OpenRouter rejects, or no model of the chain answering a
# 1-token zero-retention request. Each chain id is probed in order and a 402,
# 429, 5xx, "no endpoint" or timeout skips to the next.
fm_openrouter_resolve() {
  local cfg=$1 arg=${2#"$FM_OPENROUTER_PREFIX"} alias='' ids id key code tried=''
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
  while IFS= read -r id; do
    code=$(fm_openrouter_status "$key" "$id")
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
  echo "error: no OpenRouter model answered a 1-token zero-retention request: $tried; a zero-retention endpoint, credit, or capacity is missing" >&2
  return 1
}

# fm_openrouter_env <model-id>
# The environment of an OpenRouter worker, one KEY=VALUE per line, without the
# key (the wrapper adds ANTHROPIC_AUTH_TOKEN itself). ANTHROPIC_API_KEY is set
# empty so Claude Code uses the bearer token. Every model tier maps to the one
# model, and nothing but OpenRouter is contacted by the worker's own runtime.
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
# The key's lifetime spend in USD from /api/v1/key, or nothing when it cannot
# be read. Used before and after a task for its cost line.
fm_openrouter_usage() {
  local key out
  key=$(fm_openrouter_key 2>/dev/null) || return 1
  out=$(fm_openrouter_curl "$key" GET /v1/key) || return 1
  [ "${out##*$'\n'}" = 200 ] || return 1
  printf '%s\n' "$out" | tr -d '\n' | sed -n 's/.*"usage"[[:space:]]*:[[:space:]]*\([0-9][0-9.eE+-]*\).*/\1/p' | head -n 1 | grep . || return 1
}
