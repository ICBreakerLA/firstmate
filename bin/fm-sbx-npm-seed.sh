#!/usr/bin/env bash
# fm-sbx-npm-seed.sh - seed the read-only npm cache that sandboxed workers use.
#
# A sandboxed worker (config/worker-sandbox, docs/configuration.md "Worker
# sandbox") has no route to the npm registry through the sandbox proxy at any
# useful scale, so its `npm ci` runs offline against a cache this script fills
# on the host.
#
# Usage: fm-sbx-npm-seed.sh <project-dir> [cache-dir]
#
#   <project-dir>  a directory holding package.json and package-lock.json; it is
#                  only read.
#   [cache-dir]    default $FM_HOME/data/sbx-npm-cache; bin/fm-spawn.sh mounts it
#                  read-only into a sandbox when it exists.
#
# Only the two manifests are copied into a scratch directory and installed there
# with `npm ci --ignore-scripts`, so no lifecycle script runs and the project is
# never written.
# Rerun it whenever a lockfile changes; the cache is additive.
#
# Exit: 0 seeded, 1 refusal or install failure with the reason on stderr.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

die() {
  echo "error: $*" >&2
  exit 1
}

[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: fm-sbx-npm-seed.sh <project-dir> [cache-dir]"
PROJECT=$1
CACHE=${2:-$DATA/sbx-npm-cache}

[ -f "$PROJECT/package.json" ] || die "$PROJECT has no package.json"
[ -f "$PROJECT/package-lock.json" ] || die "$PROJECT has no package-lock.json; the offline install needs a lockfile"
command -v npm >/dev/null 2>&1 || die "npm is not installed"
case "$CACHE" in /*) ;; *) CACHE="$PWD/$CACHE" ;; esac

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-sbx-npm-seed.XXXXXX") || die "could not create a scratch directory"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$CACHE" || die "could not create $CACHE"
cp "$PROJECT/package.json" "$PROJECT/package-lock.json" "$SCRATCH/" || die "could not copy the manifests"
(cd "$SCRATCH" && npm ci --ignore-scripts --no-audit --no-fund --cache "$CACHE") >&2 \
  || die "npm ci failed while seeding $CACHE"
echo "seeded $CACHE from $PROJECT"
