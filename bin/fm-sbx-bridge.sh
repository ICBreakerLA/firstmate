#!/usr/bin/env bash
# fm-sbx-bridge.sh - the host-side git bridge between a task's worktree and the
# standalone clone its sandboxed worker uses.
#
# A sandboxed worker never mounts the host worktree, whose .git file points at
# the project's shared repository, so the VM would see and could rewrite every
# branch and worktree of the project.
# It gets a standalone clone instead (docs/configuration.md "Worker sandbox"),
# and this script moves the worker's commits back to the host worktree on the
# host side, where the clone is treated as untrusted input.
#
# Usage:
#   fm-sbx-bridge.sh clone <worktree> <clone>
#       Create the standalone clone (git clone --local --no-hardlinks), reset
#       its origin to the worktree repository's real remote URL with any
#       credentials stripped (or remove origin when there is none), and copy
#       the worktree's commit identity into the clone's local config.
#       Idempotent: an existing clone is reused as-is, which is what a relaunch
#       needs.
#   fm-sbx-bridge.sh exclude <clone> <path>
#       Add a path to the clone's .git/info/exclude.
#   fm-sbx-bridge.sh fetch-back <worktree> <clone>
#       Bring every local branch of the clone whose tip differs from the
#       worktree repository's into that repository, fast-forward only.
#       The worktree's tracked files must be clean.
#       A branch that diverged is refused and nothing is rewritten.
#       A clone whose HEAD is a branch leaves the worktree on that branch.
#       A push made inside the clone is recorded as the host's own
#       refs/remotes/origin/<branch>, only when the clone's value is contained
#       in the host's fetched branch and fast-forwards any tracking ref there.
#   fm-sbx-bridge.sh check <worktree> <clone>
#       Exit 0 only when the clone has no uncommitted work and every local
#       branch tip is already present in the worktree repository; otherwise
#       print each reason and exit 1.
#
# Exit: 0 success, 1 refusal or failure with the reason on stderr.
set -u

die() {
  echo "error: $*" >&2
  exit 1
}

# Objects come from an untrusted clone, so they are verified on the way in.
host_fetch() { # <wt> <clone> <refspec>
  git -C "$1" -c fetch.fsckObjects=true fetch -q --no-tags --no-recurse-submodules "$2" "$3"
}

strip_url_credentials() {
  sed -e 's#^\([A-Za-z][A-Za-z0-9+.-]*://\)[^/@]*@#\1#'
}

# The clone is the worker's, so nothing in it is trusted to configure a command
# the host runs: a core.fsmonitor or filter driver in its config would execute
# on the host's first `git status` there.
# Before the host reads the clone it therefore regenerates .git/config from
# the host worktree's own values alone, and refuses a clone whose .git is not a
# plain directory.
scrub_clone() { # <wt> <clone>
  local wt=$1 clone=$2 url name email cfg
  if [ ! -d "$clone/.git" ] || [ -L "$clone/.git" ]; then
    die "$clone is not a standalone clone (its .git must be a real directory)"
  fi
  cfg="$clone/.git/config.fm-scrub"
  rm -f "$cfg" "$clone/.git/config.worktree"
  git config --file "$cfg" core.repositoryformatversion 0
  git config --file "$cfg" core.bare false
  url=$(git -C "$wt" remote get-url origin 2>/dev/null | strip_url_credentials) || url=
  if [ -n "$url" ]; then
    git config --file "$cfg" remote.origin.url "$url"
    git config --file "$cfg" remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  fi
  name=$(git -C "$wt" config user.name 2>/dev/null) || name=
  email=$(git -C "$wt" config user.email 2>/dev/null) || email=
  [ -z "$name" ] || git config --file "$cfg" user.name "$name"
  [ -z "$email" ] || git config --file "$cfg" user.email "$email"
  mv -f "$cfg" "$clone/.git/config"
}

# mirror_origin_refs <wt> <clone>
# `git clone` of a local path records the host's LOCAL branches as the clone's
# origin/*, which would make the clone's default branch whatever the host
# happened to have checked out.
# The clone's origin/* are replaced by the host's own remote-tracking refs and
# origin/HEAD is copied, so a tool that asks the clone for the default branch
# (the in-sandbox no-mistakes pipeline) gets the real one.
mirror_origin_refs() {
  local wt=$1 clone=$2 ref head
  while IFS= read -r ref; do
    [ -z "$ref" ] || git -C "$clone" update-ref -d "$ref"
  done < <(git -C "$clone" for-each-ref --format='%(refname)' refs/remotes/origin/)
  git -C "$clone" fetch -q --no-tags "$wt" '+refs/remotes/origin/*:refs/remotes/origin/*' 2>/dev/null || true
  head=$(git -C "$wt" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || head=
  case "$head" in
  refs/remotes/origin/?*) git -C "$clone" symbolic-ref refs/remotes/origin/HEAD "$head" ;;
  esac
}

cmd_clone() {
  local wt=$1 clone=$2 url name email
  [ -d "$wt" ] || die "worktree $wt does not exist"
  if [ -d "$clone/.git" ]; then
    return 0
  fi
  [ ! -e "$clone" ] || die "$clone exists and is not a clone"
  git clone -q --local --no-hardlinks "$wt" "$clone" || die "could not clone $wt"
  url=$(git -C "$wt" remote get-url origin 2>/dev/null | strip_url_credentials) || url=
  if [ -n "$url" ]; then
    git -C "$clone" remote set-url origin "$url"
    mirror_origin_refs "$wt" "$clone"
  else
    git -C "$clone" remote remove origin
  fi
  name=$(git -C "$wt" config user.name 2>/dev/null) || name=
  email=$(git -C "$wt" config user.email 2>/dev/null) || email=
  [ -z "$name" ] || git -C "$clone" config user.name "$name"
  [ -z "$email" ] || git -C "$clone" config user.email "$email"
}

cmd_exclude() {
  local clone=$1 path=$2 file
  file="$clone/.git/info/exclude"
  mkdir -p "$clone/.git/info"
  grep -Fxq -- "$path" "$file" 2>/dev/null || printf '%s\n' "$path" >>"$file"
}

clone_branches() { git -C "$1" for-each-ref --format='%(refname:short)' refs/heads/; }

# record_pushed_heads <wt> <clone>
# A push from inside the sandbox moves only the clone's refs/remotes/origin/<b>.
# The host learns it as its own remote-tracking ref - which is what the done
# gate needs to see that the head left the disposable copy - but only when the
# clone's value is an ancestor of the host's own <b> (so no new object or
# history is trusted) and a fast-forward of the host's existing tracking ref.
record_pushed_heads() {
  local wt=$1 clone=$2 b rsha host_sha old
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || return 0
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    rsha=$(git -C "$clone" rev-parse -q --verify "refs/remotes/origin/$b^{commit}" 2>/dev/null) || continue
    host_sha=$(git -C "$wt" rev-parse -q --verify "refs/heads/$b" 2>/dev/null) || continue
    git -C "$wt" merge-base --is-ancestor "$rsha" "$host_sha" 2>/dev/null || continue
    old=$(git -C "$wt" rev-parse -q --verify "refs/remotes/origin/$b" 2>/dev/null) || old=
    if [ -n "$old" ]; then
      [ "$old" != "$rsha" ] || continue
      git -C "$wt" merge-base --is-ancestor "$old" "$rsha" 2>/dev/null || continue
    fi
    git -C "$wt" update-ref "refs/remotes/origin/$b" "$rsha" "$old" || die "could not record the pushed head of $b"
  done < <(clone_branches "$clone")
}

cmd_fetch_back() {
  local wt=$1 clone=$2 b sha host_sha cur head_branch
  [ -d "$clone/.git" ] || die "no clone at $clone"
  scrub_clone "$wt" "$clone"
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null)" ] ||
    die "worktree $wt has uncommitted tracked changes; the sandbox branch cannot be brought back over them"
  cur=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null) || cur=
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    sha=$(git -C "$clone" rev-parse -q --verify "refs/heads/$b") || continue
    host_sha=$(git -C "$wt" rev-parse -q --verify "refs/heads/$b" 2>/dev/null) || host_sha=
    [ "$sha" != "$host_sha" ] || continue
    host_fetch "$wt" "$clone" "refs/heads/$b" || die "could not fetch branch $b from the sandbox clone"
    if [ -n "$host_sha" ] && ! git -C "$wt" merge-base --is-ancestor "$host_sha" "$sha" 2>/dev/null; then
      # The host already holds everything the clone has: nothing to bring back.
      git -C "$wt" merge-base --is-ancestor "$sha" "$host_sha" 2>/dev/null && continue
      die "branch $b diverged between the worktree and the sandbox clone; refusing to rewrite it"
    fi
    if [ "$b" = "$cur" ]; then
      git -C "$wt" merge -q --ff-only "$sha" >/dev/null || die "could not fast-forward $b"
    elif [ -n "$host_sha" ]; then
      git -C "$wt" update-ref "refs/heads/$b" "$sha" "$host_sha" || die "could not update branch $b"
    else
      git -C "$wt" update-ref "refs/heads/$b" "$sha" "" || die "could not create branch $b"
    fi
  done < <(clone_branches "$clone")
  head_branch=$(git -C "$clone" symbolic-ref -q --short HEAD 2>/dev/null) || head_branch=
  cur=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null) || cur=
  if [ -n "$head_branch" ] && [ "$head_branch" != "$cur" ] &&
    git -C "$wt" rev-parse -q --verify "refs/heads/$head_branch" >/dev/null 2>&1; then
    git -C "$wt" checkout -q "$head_branch" || die "could not check out $head_branch in the worktree"
  fi
  record_pushed_heads "$wt" "$clone"
}

cmd_check() {
  local wt=$1 clone=$2 b sha bad=0
  [ -d "$clone/.git" ] || {
    echo "no sandbox clone at $clone" >&2
    return 1
  }
  scrub_clone "$wt" "$clone"
  if [ -n "$(git -C "$clone" status --porcelain 2>/dev/null)" ]; then
    echo "the sandbox clone has uncommitted changes" >&2
    bad=1
  fi
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    sha=$(git -C "$clone" rev-parse -q --verify "refs/heads/$b") || continue
    if ! git -C "$wt" cat-file -e "$sha^{commit}" 2>/dev/null ||
      ! git -C "$wt" for-each-ref --contains "$sha" refs/heads/ 2>/dev/null | grep -q .; then
      echo "branch $b in the sandbox clone has commits not yet brought back to the worktree" >&2
      bad=1
    fi
  done < <(clone_branches "$clone")
  return "$bad"
}

[ "$#" -ge 1 ] || die "usage: fm-sbx-bridge.sh clone|exclude|fetch-back|check ... (see the script header)"
sub=$1
shift
case "$sub" in
clone | fetch-back | check)
  [ "$#" -eq 2 ] || die "usage: fm-sbx-bridge.sh $sub <worktree> <clone>"
  ;;
exclude)
  [ "$#" -eq 2 ] || die "usage: fm-sbx-bridge.sh exclude <clone> <path>"
  ;;
*) die "unknown subcommand '$sub' (clone, exclude, fetch-back, check)" ;;
esac
case "$sub" in
clone) cmd_clone "$@" ;;
exclude) cmd_exclude "$@" ;;
fetch-back) cmd_fetch_back "$@" ;;
check) cmd_check "$@" ;;
esac
