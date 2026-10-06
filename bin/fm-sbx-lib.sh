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
#   sbx [cpus=N] [memory=Ng] [allow=HOSTS] [nm=VERSION] [verify=sportsmeet]
#                            run Claude workers in an sbx microVM
# cpus defaults to 4 (1-64) and memory to 4g (a whole number of gigabytes).
# allow= is a comma-separated list of further host names every sandbox of this
# home may reach, added per sandbox and never to the global sbx policy.
# nm=VERSION (for example v1.79.0) pins the no-mistakes version a sandboxed
# validation ship may use, and a host binary of any other version refuses the
# launch; without it the host's own version is used and only has to match the
# copy installed in the VM.
# verify=sportsmeet opts every sandbox of this home into the host-side
# verification broker (bin/fm-sbx-verify-broker.sh, docs/sbx-verify-broker.md);
# sportsmeet is the only accepted value and the token's absence changes nothing.
#
# Every sandbox this tree creates is named fm-sbx-<home-hash>-<id>-<id-hash>,
# so a sweep, a removal, or an operator listing can tell fleet sandboxes from
# any other and two homes never collide.
# This tree never changes the global sbx policy and never signs in to Claude.

FM_SBX_MODE=off
FM_SBX_CPUS=4
FM_SBX_MEMORY=4g
FM_SBX_ALLOW=
FM_SBX_NM_PIN=
FM_SBX_VERIFY=

# fm_sbx_load_config <file>
# Parse the file into FM_SBX_MODE, FM_SBX_CPUS, FM_SBX_MEMORY, FM_SBX_ALLOW,
# FM_SBX_NM_PIN and FM_SBX_VERIFY.
# An absent file is the default (off); a malformed value prints the refusal to
# stderr and returns 1 so the caller can stop before any mutation.
fm_sbx_load_config() {
  local file=$1 raw tok first rest
  FM_SBX_MODE=off FM_SBX_CPUS=4 FM_SBX_MEMORY=4g FM_SBX_ALLOW='' FM_SBX_NM_PIN='' FM_SBX_VERIFY=''
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/worker-sandbox must be a readable regular file holding: off, or sbx with optional cpus=N memory=Ng allow=HOSTS nm=VERSION verify=sportsmeet" >&2
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
    nm=v[0-9]*.[0-9]*.[0-9]*)
      case "${tok#nm=}" in
      *[!A-Za-z0-9.+-]*)
        echo "error: config/worker-sandbox nm= takes a version such as v1.79.0, got '${tok#nm=}'" >&2
        return 1
        ;;
      esac
      FM_SBX_NM_PIN=${tok#nm=}
      ;;
    verify=sportsmeet) FM_SBX_VERIFY=sportsmeet ;;
    verify=*)
      echo "error: config/worker-sandbox verify= only accepts sportsmeet, got '${tok#verify=}'" >&2
      return 1
      ;;
    *)
      echo "error: config/worker-sandbox holds the option '$tok'; accepted options are cpus=N (1-64), memory=Ng, allow=HOSTS, nm=VERSION and verify=sportsmeet" >&2
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

# fm_sbx_nm_version <text>: the version token (v1.79.0) of the `no-mistakes
# --version` line ("no-mistakes version v1.79.0 (<commit>) <date>"), empty when
# the text carries none.
# Only that line counts, so an update banner that names two other versions
# cannot be mistaken for the binary's own.
fm_sbx_nm_version() {
  printf '%s\n' "$1" | grep -E '^no-mistakes version v?[0-9]' | head -n 1 |
    grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.+-]*' | head -n 1
}

# fm_sbx_nm_prepare <name> <clone> <nm-home>
# Make a sandboxed no-mistakes ship's clone look like a real checkout to the
# pipeline that runs in the VM: origin is present, the remote's default branch
# is fetched and recorded as origin/HEAD (a clone whose origin/HEAD names the
# feature branch makes the pipeline refuse to validate it, and it keeps
# refusing until init has run again), and `no-mistakes init` has registered the
# clone.
# Everything runs as the VM's own user, and each failure prints the step that
# failed to stderr and returns 1.
fm_sbx_nm_prepare() {
  local name=$1 clone=$2 nmhome=$3
  _fm_sbx_vm_clone() {
    sbx exec -w "$clone" -e "NM_HOME=$nmhome" -e NO_MISTAKES_NO_UPDATE_CHECK=1 -e NO_MISTAKES_TELEMETRY=off "$name" "$@"
  }
  _fm_sbx_vm_clone git remote get-url origin >/dev/null 2>&1 || {
    echo "error: the clone of this ship has no origin remote, so its sandboxed pipeline has nothing to push to" >&2
    return 1
  }
  _fm_sbx_vm_clone git fetch -q origin >/dev/null 2>&1 || {
    echo "error: could not fetch origin inside $name (is a GitHub token set in config/sbx-github-token and github.com allowed?)" >&2
    return 1
  }
  _fm_sbx_vm_clone git remote set-head origin -a >/dev/null 2>&1 || {
    echo "error: could not set the default branch of origin inside $name" >&2
    return 1
  }
  _fm_sbx_vm_clone no-mistakes init >/dev/null 2>&1 || {
    echo "error: no-mistakes init failed inside $name" >&2
    return 1
  }
}

# fm_sbx_github_slug <url>
# The lowercased owner/repo of a github.com URL (https, ssh:// or scp form, with
# or without credentials or a .git suffix); returns 1 for any other URL.
fm_sbx_github_slug() {
  local u rest
  u=$(printf '%s' "$1" | sed -e 's#^\([A-Za-z][A-Za-z0-9+.-]*://\)[^/@]*@#\1#')
  case "$u" in
  https://github.com/* | http://github.com/*) rest=${u#*://github.com/} ;;
  ssh://github.com/*) rest=${u#ssh://github.com/} ;;
  git@github.com:*) rest=${u#git@github.com:} ;;
  *) return 1 ;;
  esac
  rest=${rest%/}
  rest=${rest%.git}
  case "$rest" in
  *[!A-Za-z0-9._/-]* | */*/* | /* | */ | '' | */.*) return 1 ;;
  */?*) ;;
  *) return 1 ;;
  esac
  printf '%s\n' "$rest" | tr '[:upper:]' '[:lower:]'
}

# fm_sbx_fork_repo / fm_sbx_fork_token_file
# The Firstmate fork a sandboxed ship may deliver to, and the host file holding
# the token that is valid for that fork only.
# FM_SBX_FORK_REPO and FM_SBX_FORK_TOKEN_FILE override the defaults for a home
# that runs a different fork; the token file is never inside a sandbox mount.
fm_sbx_fork_repo() { printf '%s\n' "${FM_SBX_FORK_REPO:-ICBreakerLA/firstmate}"; }
fm_sbx_fork_token_file() { printf '%s\n' "${FM_SBX_FORK_TOKEN_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/firstmate/fork-gh-token}"; }

# fm_sbx_fork_url <worktree>
# Prints https://github.com/<fork> when any remote of the worktree's repository
# names the Firstmate fork, so the swap below applies to that fork's work only;
# prints nothing and returns 1 for every other repository.
fm_sbx_fork_url() {
  local wt=$1 fork want r u
  fork=$(fm_sbx_fork_repo)
  want=$(printf '%s' "$fork" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    u=$(git -C "$wt" remote get-url "$r" 2>/dev/null) || continue
    [ "$(fm_sbx_github_slug "$u" 2>/dev/null)" = "$want" ] || continue
    printf 'https://github.com/%s\n' "$fork"
    return 0
  done < <(git -C "$wt" remote 2>/dev/null)
  return 1
}

# fm_sbx_fork_secret <name>
# Replace one sandbox's github secret with the fork-only token.
# sbx runs the --command on the host and reads the token from its output, so the
# value is never held in a variable, an argument or the environment; only the
# file's path is an argument.
# Returns 0 when stored, 3 when the token file is absent, a symlink, unreadable
# or empty (the sandbox keeps whatever credential it started with), and 1 when
# sbx refused the secret.
fm_sbx_fork_secret() {
  local name=$1 file
  file=$(fm_sbx_fork_token_file)
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 3
  [ -n "$(tr -d '[:space:]' <"$file" 2>/dev/null | head -c 1)" ] || return 3
  sbx secret rm github --sandbox "$name" -f </dev/null >/dev/null 2>&1 || true
  sbx secret set github --sandbox "$name" --command "tr -d '[:space:]' <$(printf '%q' "$file")" </dev/null >/dev/null 2>&1
}

# fm_sbx_lint_tools <name> <code-root>
# Give a sandboxed ship's pipeline the lint tools it cannot download: the host's
# ShellCheck and actionlint, each only when it reports exactly the version the
# lint owners pin, are copied into the VM beside no-mistakes and gh.
# The copy is not a mount and widens no network rule, and bin/fm-lint.sh and
# bin/fm-lint-workflows.sh still verify the version of whatever is on the VM's
# PATH, so the lint step stays a real pinned run.
# A tool the host lacks, at another version, or that does not run in the VM is
# left out with a notice, and the lint step then fails naming it as before.
fm_sbx_lint_tools() {
  local name=$1 root=$2 tool pin bin got
  for tool in shellcheck actionlint; do
    case "$tool" in
    shellcheck) pin=$("$root/bin/fm-lint.sh" --required-version 2>/dev/null) || pin= ;;
    actionlint) pin=$("$root/bin/fm-lint-workflows.sh" --required-version 2>/dev/null) || pin= ;;
    esac
    if [ -z "$pin" ]; then
      echo "notice: could not read the pinned $tool version from $root/bin, so $name gets no $tool and its lint step will fail" >&2
      continue
    fi
    bin=$(command -v "$tool" 2>/dev/null || true)
    got=
    if [ -n "$bin" ]; then
      bin=$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")
      got=$(_fm_sbx_tool_version "$tool" "$bin")
    fi
    if [ "$got" != "$pin" ]; then
      echo "notice: the host $tool reports '${got:-nothing}' but $pin is pinned, so $name gets no $tool and its lint step will fail; install it with bin/fm-install-$tool.sh <directory> and put that directory on PATH" >&2
      continue
    fi
    if sbx cp "$bin" "$name:/tmp/fm-$tool" >/dev/null 2>&1 &&
      sbx exec -u root "$name" install -m 755 "/tmp/fm-$tool" "/usr/local/bin/$tool" >/dev/null 2>&1 &&
      [ "$(_fm_sbx_tool_version "$tool" "$tool" "$name")" = "$pin" ]; then
      :
    else
      sbx exec -u root "$name" rm -f "/usr/local/bin/$tool" >/dev/null 2>&1 || true
      echo "notice: the host $tool cannot run inside $name, so its lint step will fail" >&2
    fi
  done
}

# _fm_sbx_tool_version <tool> <binary> [<sandbox>]: the version a lint tool
# reports, on the host or (with a sandbox) inside it; empty when it does not run.
_fm_sbx_tool_version() {
  local tool=$1 bin=$2 name=${3:-} out
  case "$tool" in
  shellcheck)
    if [ -n "$name" ]; then out=$(sbx exec "$name" "$bin" --version 2>/dev/null) || return 0; else out=$("$bin" --version 2>/dev/null) || return 0; fi
    printf '%s\n' "$out" | awk '/^version:/ {print $2; exit}'
    ;;
  actionlint)
    if [ -n "$name" ]; then out=$(sbx exec "$name" "$bin" -version 2>/dev/null) || return 0; else out=$("$bin" -version 2>/dev/null) || return 0; fi
    printf '%s\n' "$out" | awk 'NR==1 {print; exit}'
    ;;
  esac
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
fm_sbx_verify_dir() { printf '%s/%s.sbx-verify\n' "$1" "$2"; }
