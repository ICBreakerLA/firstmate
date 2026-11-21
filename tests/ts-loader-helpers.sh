#!/usr/bin/env bash
# tests/ts-loader-helpers.sh - let node import the tracked .ts sources.
#
# A test that hands a tracked .ts path to node, directly or through a product
# script such as bin/fm-branch-dispatch.mjs, opts in with one line after it
# sources tests/lib.sh (which sources this file on the first call):
#   fm_test_ts_loader || exit 1
#
# Distribution Node builds such as Debian's nodejs 22 are compiled without
# built-in type stripping (process.features.typescript is false) and fail a .ts
# import with ERR_UNKNOWN_FILE_EXTENSION; --experimental-strip-types fails with
# ERR_NO_TYPESCRIPT. On such a node this exports NODE_OPTIONS=--import of a
# module load hook that transpiles .ts with the pinned TypeScript in
# tests/fixtures/ts-loader/package-lock.json and throws on any syntax
# diagnostic, so every node the test spawns inherits it. A node that strips
# types itself is left alone.
#
# The compiler is installed once per lockfile into
# ${FM_TEST_TS_LOADER_CACHE:-${TMPDIR:-/tmp}/fm-test-ts-loader-<uid>} with
# `npm ci --ignore-scripts`; the ambient npm cache is used as given, so a
# sandbox with a read-only offline cache installs without the registry.
# FM_TEST_TS_DIR already naming a directory whose node_modules holds typescript
# (tests/fm-pi-primary-types.test.sh points it at its own pinned install) skips
# the install.
#
# Returns 0 when node can import .ts, 1 with the reason on stderr otherwise.

_fm_ts_loader_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/ts-loader"

fm_test_ts_loader() {
  local native
  native=$(node -p 'String(process.features.typescript)' 2>/dev/null) || {
    echo "not ok - ts loader: node is not runnable" >&2
    return 1
  }
  case "$native" in false | undefined) ;; *) return 0 ;; esac

  if [ -z "${FM_TEST_TS_DIR:-}" ]; then
    local key base final tmp
    key=$(cat "$_fm_ts_loader_dir/package.json" "$_fm_ts_loader_dir/package-lock.json" | cksum | cut -d' ' -f1)
    base=${FM_TEST_TS_LOADER_CACHE:-${TMPDIR:-/tmp}/fm-test-ts-loader-$(id -u)}
    final=$base/$key
    if [ ! -f "$final/node_modules/typescript/package.json" ]; then
      if ! mkdir -p "$base" || [ ! -O "$base" ] || ! chmod 700 "$base"; then
        echo "not ok - ts loader: cannot own cache directory $base" >&2
        return 1
      fi
      tmp=$(mktemp -d "$base/.install.XXXXXX") || return 1
      if ! cp "$_fm_ts_loader_dir/package.json" "$_fm_ts_loader_dir/package-lock.json" "$tmp/" ||
        ! (cd "$tmp" && npm ci --ignore-scripts --no-audit --no-fund >"$tmp/npm.log" 2>&1); then
        echo "not ok - ts loader: npm ci of the pinned TypeScript failed ($tmp/npm.log)" >&2
        sed 's/^/  /' "$tmp/npm.log" >&2
        return 1
      fi
      # A concurrent test may have installed the same lockfile first; the
      # symlink is atomic, so whichever loses discards its copy.
      if [ -L "$final" ] && [ ! -e "$final" ]; then rm -f "$final"; fi
      ln -s "$tmp" "$final" 2>/dev/null || rm -rf "$tmp"
      if [ ! -f "$final/node_modules/typescript/package.json" ]; then
        echo "not ok - ts loader: no TypeScript under $final" >&2
        return 1
      fi
    fi
    FM_TEST_TS_DIR=$final
  fi
  export FM_TEST_TS_DIR

  local register="file://${_fm_ts_loader_dir// /%20}/register.mjs"
  case " ${NODE_OPTIONS:-} " in
    *" --import=$register "*) ;;
    *) export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--import=$register" ;;
  esac
}
