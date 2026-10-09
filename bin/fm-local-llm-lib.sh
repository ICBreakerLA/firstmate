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
# bin/fm-sbx-run.sh applies the environment and the per-sandbox network rules
# and keeps the spawn's host-wide one-at-a-time claim for the life of the
# sandbox.
#
# Overrides, for tests only:
#   FM_LOCAL_LLM_URL    the address the host-side health check asks (default
#                       http://127.0.0.1:8080); the sandbox's base URL and
#                       network rule stay on port 8080
#   FM_LOCAL_LLM_LOCK   the host-wide lock file
#   FM_LOCAL_LLM_START_WAIT   seconds a configured start command is given to make
#                             the server answer (default 120)
#   FM_LOCAL_LLM_START_POLL   seconds between those answers checks (default 2)
# This tree never changes the global sbx policy, never stops the server (that is
# `local-llm down`), and never passes a host secret. It starts the server only
# through the optional config/local-llm-start command, and only for a model that
# arrived through a dispatch rule or profile (fm_local_llm_select).

FM_LOCAL_LLM_MODEL=qwen3.8-27b-gsq-rco
# Seen from inside an sbx microVM the host's loopback is host.docker.internal;
# the sbx proxy names the same resource localhost:<port> in its policy.
FM_LOCAL_LLM_VM_URL=http://host.docker.internal:8080
# shellcheck disable=SC2034 # Read by the sourcing script (fm-sbx-run.sh).
FM_LOCAL_LLM_POLICY_HOST=localhost:8080
# The Anthropic API stays closed to a local-model sandbox, so the sbx proxy can
# never attach the captain's sign-in to a request from it.
# shellcheck disable=SC2034 # Read by the sourcing script (fm-sbx-run.sh).
FM_LOCAL_LLM_ANTHROPIC_HOST=api.anthropic.com
# The server context is 96,256 tokens; compacting at 88,000 leaves room for a
# reply and the compaction call itself.
FM_LOCAL_LLM_COMPACT_WINDOW=88000
# What a dispatch-chosen local model falls back to when it is unavailable.
FM_LOCAL_LLM_FALLBACK_MODEL=claude-haiku-4-5
FM_LOCAL_LLM_FALLBACK_EFFORT=low

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

# fm_local_llm_claim <task-id>
# The spawn's atomic claim of the one local-model slot, taken before anything
# else exists. On success the lock file names the task and the lock is held by
# a detached holder that waits on the lock's handoff FIFO; the claim lasts
# until the task's wrapper has opened that FIFO (fm_local_llm_take_claim) and
# ended, however it ends. FM_LOCAL_LLM_HOLDER is the holder's pid, which the
# spawn kills to release a claim no wrapper will take.
fm_local_llm_claim() {
  local id=$1 f
  f=$(fm_local_llm_lock_file)
  command -v flock >/dev/null 2>&1 || {
    echo "error: the local-model profile needs flock to keep one local worker at a time" >&2
    return 1
  }
  mkdir -p "$(dirname "$f")" 2>/dev/null || {
    echo "error: could not create the local-model lock directory for $f" >&2
    return 1
  }
  exec 9>>"$f" || {
    echo "error: could not open the local-model lock $f" >&2
    return 1
  }
  flock -n 9 || {
    exec 9>&-
    echo "error: another local-model worker is already running; the local server has one slot, so only one local-model worker runs at a time (wait for it to finish or use another profile)" >&2
    return 1
  }
  if ! printf '%s\n' "$id" >"$f" || ! rm -f "$f.handoff" || ! mkfifo -m 600 "$f.handoff"; then
    exec 9>&-
    echo "error: could not prepare the local-model claim at $f" >&2
    return 1
  fi
  (
    trap '' HUP
    exec cat "$f.handoff"
  ) </dev/null >/dev/null 2>&1 &
  # shellcheck disable=SC2034 # Read by the sourcing script (fm-spawn.sh).
  FM_LOCAL_LLM_HOLDER=$!
  exec 9>&-
}

# fm_local_llm_take_claim <task-id>
# The wrapper's side of the handoff: refuses unless the held claim names this
# task, then opens the handoff FIFO on file descriptor 9 of the calling shell so
# the claim lasts exactly as long as that shell (the kernel closes it on any
# exit). It never takes or waits for the lock itself. Start background jobs
# with `9>&-` so they do not keep the claim.
fm_local_llm_take_claim() {
  local id=$1 f
  f=$(fm_local_llm_lock_file)
  if [ ! -p "$f.handoff" ] || [ "$(head -n 1 "$f" 2>/dev/null)" != "$id" ] || flock -n "$f" true 2>/dev/null; then
    echo "error: task $id holds no local-model claim; only the spawn that claimed the one local slot may start a local-model worker" >&2
    return 1
  fi
  exec 9<>"$f.handoff" || {
    echo "error: could not take over the local-model claim for $id" >&2
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

# fm_local_llm_gpu_conflict
# 0 when ComfyUI holds the shared 16 GB GPU: on this PC, a python process whose
# path is under C:\ComfyUI\venv, found through powershell.exe. Replace this one
# function for another machine. No powershell.exe, or a probe that fails or
# gives no number, means no conflict.
fm_local_llm_gpu_conflict() {
  local out
  command -v powershell.exe >/dev/null 2>&1 || return 1
  out=$(timeout 15 powershell.exe -NoProfile -NonInteractive -Command \
    "@(Get-Process python* -ErrorAction SilentlyContinue | Where-Object { \$_.Path -like 'C:\\ComfyUI\\venv\\*' }).Count" \
    2>/dev/null </dev/null | tr -d '[:space:]') || return 1
  case "$out" in
  '' | *[!0-9]*) return 1 ;;
  esac
  [ "$out" -gt 0 ]
}

# fm_local_llm_start_command <config-dir>
# The first non-blank, non-# line of <config-dir>/local-llm-start, or nothing.
fm_local_llm_start_command() {
  local f=$1/local-llm-start
  [ -f "$f" ] || return 0
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$f" | grep -v -e '^$' -e '^#' | head -n 1
}

# fm_local_llm_start_and_wait <command>
# Runs the host-side start command once, detached, then waits up to
# FM_LOCAL_LLM_START_WAIT seconds for the server to answer with the model. 0
# once it does. A start command that exits non-zero ends the wait early.
fm_local_llm_start_and_wait() {
  local cmd=$1 limit poll deadline pid ended=0
  limit=${FM_LOCAL_LLM_START_WAIT:-120}
  poll=${FM_LOCAL_LLM_START_POLL:-2}
  bash -c "$cmd" </dev/null >/dev/null 2>&1 9>&- &
  pid=$!
  deadline=$((SECONDS + limit))
  while :; do
    fm_local_llm_health >/dev/null 2>&1 && return 0
    if [ "$ended" -eq 0 ] && ! kill -0 "$pid" 2>/dev/null; then
      ended=1
      wait "$pid" || return 1
    fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep "$poll"
  done
}

# fm_local_llm_select <task-id> <sandbox-active: 0|1> <config-dir>
# The availability decision for a local model that arrived through a dispatch
# rule or profile, in this order, the first failure deciding:
#   (a) the home supports the sandbox profile -> else fall back, never start;
#   (b) ComfyUI is not holding the GPU, and the server answers with the model
#       (once started through config/local-llm-start when it did not);
#   (c) the one local slot is free, and is claimed here.
# 0: the local model is usable and the slot is claimed (FM_LOCAL_LLM_HOLDER is
# set). 1: unavailable; one notice line names the failed check and the model
# used instead. Nothing is created either way beyond the claim.
fm_local_llm_select() {
  local id=$1 sbx=$2 cfg=$3 why cmd err
  why=
  if [ "$sbx" != 1 ]; then
    why="the home has no sandbox profile (config/worker-sandbox is not sbx or sbx is absent)"
  elif fm_local_llm_gpu_conflict; then
    why="ComfyUI holds the GPU"
  elif ! err=$(fm_local_llm_health 2>&1 >/dev/null); then
    cmd=$(fm_local_llm_start_command "$cfg")
    if [ -z "$cmd" ]; then
      why="the server is not answering and no start command is configured (config/local-llm-start)"
    elif fm_local_llm_start_and_wait "$cmd"; then
      why=
    else
      why="the server did not answer within ${FM_LOCAL_LLM_START_WAIT:-120}s of its start command"
    fi
    [ -n "$why" ] || ! fm_local_llm_gpu_conflict || why="ComfyUI holds the GPU"
  fi
  if [ -z "$why" ]; then
    err=$(fm_local_llm_claim "$id" 2>&1) || why="the one local slot is taken (${err#error: })"
  fi
  [ -z "$why" ] && return 0
  echo "local model $FM_LOCAL_LLM_MODEL unavailable: $why; using $FM_LOCAL_LLM_FALLBACK_MODEL (effort $FM_LOCAL_LLM_FALLBACK_EFFORT) instead" >&2
  return 1
}
