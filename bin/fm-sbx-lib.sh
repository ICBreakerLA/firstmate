# shellcheck shell=bash
# shellcheck disable=SC2034 # the FM_SBX_* results are read by the sourcing script
# Shared helpers for running Claude workers inside Docker Sandboxes (`sbx`)
# microVMs.
#
# Usage: . bin/fm-sbx-lib.sh   (no FM_* setup required)
#
# This file owns the config/worker-sandbox value grammar, the sandbox name
# derivation, the availability and daemon preflight, and the idempotent
# sandbox removal.
# The operator-facing schema is docs/configuration.md "Worker sandbox".
# bin/fm-sbx-run.sh owns the in-pane lifecycle, bin/fm-sbx-bridge.sh the
# host-side clone and fetch-back bridge, and bin/fm-sbx-relay.sh the
# channel-to-state mirror.
#
# Value grammar of config/worker-sandbox, one line:
#   off                      the default; also an absent file
#   sbx [cpus=N] [memory=Ng] [allow=HOSTS]
#                            run Claude workers in an sbx microVM
# cpus defaults to 4 (1-64) and memory to 4g (a whole number of gigabytes).
# allow= is a comma-separated list of further host names every sandbox of this
# home may reach, added per sandbox and never to the global sbx policy.
#
# Every sandbox this tree creates is named fm-sbx-<home-hash>-<id>-<id-hash>,
# so a sweep, a removal, or an operator listing can tell fleet sandboxes from
# any other and two homes never collide.
# This tree never changes the global sbx policy and never signs in to Claude.

FM_SBX_MODE=off
FM_SBX_CPUS=4
FM_SBX_MEMORY=4g
FM_SBX_ALLOW=

# fm_sbx_load_config <file>
# Parse the file into FM_SBX_MODE, FM_SBX_CPUS, FM_SBX_MEMORY and FM_SBX_ALLOW.
# An absent file is the default (off); a malformed value prints the refusal to
# stderr and returns 1 so the caller can stop before any mutation.
fm_sbx_load_config() {
  local file=$1 raw tok first rest
  FM_SBX_MODE=off FM_SBX_CPUS=4 FM_SBX_MEMORY=4g FM_SBX_ALLOW=
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/worker-sandbox must be a readable regular file holding: off, or sbx with optional cpus=N memory=Ng allow=HOSTS" >&2
    return 1
  fi
  raw=$(tr '\n\t' '  ' <"$file" || true)
  # shellcheck disable=SC2086
  set -- $raw
  first=${1:-}
  [ "$#" -eq 0 ] || shift
  rest=$*
  case "$first" in
  '' | off)
    if [ -n "$rest" ]; then
      echo "error: config/worker-sandbox holds 'off $rest'; options are only accepted after sbx" >&2
      return 1
    fi
    FM_SBX_MODE=off
    return 0
    ;;
  sbx) ;;
  *)
    echo "error: config/worker-sandbox holds '$first'; accepted values are: off (the default when the file is absent), sbx (Claude workers run in a Docker Sandboxes microVM)" >&2
    return 1
    ;;
  esac
  for tok in "$@"; do
    case "$tok" in
    cpus=[1-9] | cpus=[1-5][0-9] | cpus=6[0-4]) FM_SBX_CPUS=${tok#cpus=} ;;
    memory=[1-9]g | memory=[1-9][0-9]g | memory=[1-9][0-9][0-9]g) FM_SBX_MEMORY=${tok#memory=} ;;
    allow=?*)
      case "${tok#allow=}" in
      *[!A-Za-z0-9.,*-]* | ,* | *, | *,,*)
        echo "error: config/worker-sandbox allow= takes comma-separated host names (letters, digits, dot, dash, star), got '${tok#allow=}'" >&2
        return 1
        ;;
      esac
      FM_SBX_ALLOW=${tok#allow=}
      ;;
    *)
      echo "error: config/worker-sandbox holds the option '$tok'; accepted options are cpus=N (1-64), memory=Ng and allow=HOSTS" >&2
      return 1
      ;;
    esac
  done
  FM_SBX_MODE=sbx
}

fm_sbx_hash() { # stdin -> lowercase hex digest
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# fm_sbx_name <fm-home> <task-id>
# fm-sbx-<home-hash8>-<id sanitized to [A-Za-z0-9-], at most 40>-<id-hash4>.
fm_sbx_name() {
  local home=$1 id=$2 hh ih san
  hh=$(printf '%s' "$home" | fm_sbx_hash | cut -c1-8)
  ih=$(printf '%s' "$id" | fm_sbx_hash | cut -c1-4)
  san=$(printf '%s' "$id" | LC_ALL=C tr -c 'A-Za-z0-9-' '-' | cut -c1-40)
  printf 'fm-sbx-%s-%s-%s\n' "$hh" "$san" "$ih"
}

# fm_sbx_is_fleet_name <name>: true only for a name this tree would create.
fm_sbx_is_fleet_name() {
  case "$1" in
  fm-sbx-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[A-Za-z0-9]*) return 0 ;;
  esac
  return 1
}

# fm_sbx_preflight: the sbx CLI is installed and its daemon is running.
# Prints the concrete missing requirement to stderr on failure.
fm_sbx_preflight() {
  local out
  if ! command -v sbx >/dev/null 2>&1; then
    echo "error: config/worker-sandbox is sbx but the sbx CLI is not installed or not on PATH" >&2
    return 1
  fi
  if ! out=$(sbx daemon status 2>&1) || ! printf '%s\n' "$out" | grep -q '^Status: running'; then
    echo "error: config/worker-sandbox is sbx but the sbx daemon is not running; start it with the user unit in docs/configuration.md \"Worker sandbox\" (sbx daemon start --policy deny-all), then spawn again" >&2
    return 1
  fi
}

# fm_sbx_exists <name>: true when sbx lists the sandbox.
fm_sbx_exists() {
  sbx ls -q 2>/dev/null | grep -Fxq -- "$1"
}

# fm_sbx_rm <name>
# Idempotent removal of one fleet sandbox: an absent sandbox is success, a
# name this tree would not have created is refused, and a sandbox that is
# still listed after the removal is a failure the caller must surface.
fm_sbx_rm() {
  local name=$1
  fm_sbx_is_fleet_name "$name" || {
    echo "error: refusing to remove '$name': not a fleet sandbox name" >&2
    return 1
  }
  command -v sbx >/dev/null 2>&1 || {
    echo "error: sbx is not installed; cannot remove sandbox $name" >&2
    return 1
  }
  fm_sbx_exists "$name" || return 0
  sbx rm --force "$name" >/dev/null 2>&1 || true
  if fm_sbx_exists "$name"; then
    echo "error: sandbox $name is still present after sbx rm --force" >&2
    return 1
  fi
}

# Per-task host paths. <state> is the home's state directory.
fm_sbx_channel_dir() { printf '%s/%s.sbx\n' "$1" "$2"; }
fm_sbx_clone_dir() { printf '%s/%s.sbx-clone\n' "$1" "$2"; }
fm_sbx_relay_dir() { printf '%s/%s.sbx-relay\n' "$1" "$2"; }
