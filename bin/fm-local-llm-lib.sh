# shellcheck shell=bash
# Shared helpers for the local-model worker profile: a sandboxed Claude Code
# worker that talks to a llama.cpp `llama-server` on the host instead of the
# Anthropic API.
#
# Usage: . bin/fm-local-llm-lib.sh   (no FM_* setup required)
#
# The profile is selected per spawn by the model id alone: a Claude worker
# whose model is qwen3.8-27b-gsq-rco (--model, or a dispatch profile's model)
# is a local-model worker.
# docs/configuration.md "Local-model worker profile" owns the operator-facing
# contract; bin/fm-spawn.sh refuses a bad launch before anything is created and
# bin/fm-sbx-run.sh applies the environment, the per-sandbox network rule and
# the host-wide one-at-a-time lock for the life of the sandbox.
#
# Overrides, for tests and for a server on another port:
#   FM_LOCAL_LLM_URL    the server as the host reaches it (default
#                       http://127.0.0.1:8080)
#   FM_LOCAL_LLM_LOCK   the host-wide lock file
# This tree never changes the global sbx policy, never starts or stops the
# server (that is `local-llm up|down|status`), and never passes a host secret.

FM_LOCAL_LLM_MODEL=qwen3.8-27b-gsq-rco
# Seen from inside an sbx microVM the host's loopback is host.docker.internal;
# the sbx proxy names the same resource localhost:<port> in its policy.
FM_LOCAL_LLM_VM_URL=http://host.docker.internal:8080
FM_LOCAL_LLM_POLICY_HOST=localhost:8080
# The server context is 96,256 tokens; compacting at 88,000 leaves room for a
# reply and the compaction call itself.
FM_LOCAL_LLM_COMPACT_WINDOW=88000

# fm_local_llm_is_model <model>: 0 when the model id selects the profile.
fm_local_llm_is_model() {
  [ "${1-}" = "$FM_LOCAL_LLM_MODEL" ]
}

fm_local_llm_url() {
  printf '%s\n' "${FM_LOCAL_LLM_URL:-http://127.0.0.1:8080}"
}

fm_local_llm_lock_file() {
  printf '%s\n' "${FM_LOCAL_LLM_LOCK:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/firstmate/local-llm.lock}"
}

# fm_local_llm_health
# 0 when the host's server answers /v1/models and lists the profile's model;
# otherwise a clear refusal on stderr and 1. Nothing is created.
fm_local_llm_health() {
  local url body
  url=$(fm_local_llm_url)
  command -v curl >/dev/null 2>&1 || {
    echo "error: the local-model profile needs curl to check the server at $url" >&2
    return 1
  }
  body=$(curl -fsS --max-time 5 "$url/v1/models" 2>/dev/null) || {
    echo "error: the local model server is not answering at $url/v1/models; start it with: local-llm up (then local-llm status)" >&2
    return 1
  }
  case "$body" in
  *"\"$FM_LOCAL_LLM_MODEL\""*) return 0 ;;
  esac
  echo "error: the local model server at $url is up but does not list the model $FM_LOCAL_LLM_MODEL; check local-llm status" >&2
  return 1
}

# fm_local_llm_lock_probe
# 0 when no local-model worker holds the lock. It takes and releases the lock
# at once, so it only reports; fm_local_llm_lock_acquire is the real claim.
fm_local_llm_lock_probe() {
  local f
  f=$(fm_local_llm_lock_file)
  command -v flock >/dev/null 2>&1 || {
    echo "error: the local-model profile needs flock to keep one local worker at a time" >&2
    return 1
  }
  mkdir -p "$(dirname "$f")" 2>/dev/null || {
    echo "error: could not create the local-model lock directory for $f" >&2
    return 1
  }
  (
    exec 8>>"$f" || exit 2
    flock -n 8
  )
  case $? in
  0) return 0 ;;
  1)
    echo "error: another local-model worker is already running; the local server has one slot, so only one local-model worker runs at a time (wait for it to finish or use another profile)" >&2
    return 1
    ;;
  *)
    echo "error: could not open the local-model lock $f" >&2
    return 1
    ;;
  esac
}

# fm_local_llm_lock_acquire
# Claim the lock on file descriptor 9 of the calling shell for as long as that
# shell lives (the kernel drops it on any exit). Start background jobs with
# `9>&-` so they do not inherit the claim.
fm_local_llm_lock_acquire() {
  local f
  f=$(fm_local_llm_lock_file)
  command -v flock >/dev/null 2>&1 || {
    echo "error: the local-model profile needs flock to keep one local worker at a time" >&2
    return 1
  }
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  exec 9>>"$f" || return 1
  flock -n 9 || {
    exec 9>&-
    echo "error: another local-model worker is already running; the local server has one slot, so only one local-model worker runs at a time" >&2
    return 1
  }
}

# fm_local_llm_env
# The complete environment of a local-model worker, one KEY=VALUE per line.
# The token is a placeholder the server ignores: no host credential is ever
# part of it. Every model tier maps to the one local model so no request names
# a model the server does not have, and nothing but the model server is
# contacted by the worker's own runtime.
fm_local_llm_env() {
  local m=$FM_LOCAL_LLM_MODEL
  printf '%s\n' \
    "ANTHROPIC_BASE_URL=$FM_LOCAL_LLM_VM_URL" \
    "ANTHROPIC_AUTH_TOKEN=local-llm-no-credential" \
    "ANTHROPIC_MODEL=$m" \
    "ANTHROPIC_DEFAULT_OPUS_MODEL=$m" \
    "ANTHROPIC_DEFAULT_SONNET_MODEL=$m" \
    "ANTHROPIC_DEFAULT_HAIKU_MODEL=$m" \
    "ANTHROPIC_SMALL_FAST_MODEL=$m" \
    "CLAUDE_CODE_SUBAGENT_MODEL=$m" \
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW=$FM_LOCAL_LLM_COMPACT_WINDOW" \
    "CLAUDE_CODE_ATTRIBUTION_HEADER=0" \
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
}
