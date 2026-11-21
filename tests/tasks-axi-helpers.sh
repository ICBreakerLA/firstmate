#!/usr/bin/env bash
# tests/tasks-axi-helpers.sh - the pinned tasks-axi for the test suites.
#
# fm_test_provide_tasks_axi <parent-dir>: give the caller its own real
# tasks-axi, the pin in bin/sbx-tasks-axi (package.json + package-lock.json),
# installed with `npm ci --offline --ignore-scripts` from a writable copy of the
# mounted NPM_CONFIG_CACHE (the same recipe as fm_sbx_tasks_axi; with no cache
# mounted the install uses the real registry, as tests/fm-pi-primary-types.test.sh
# does), then prepends its node_modules/.bin to PATH. It never reads an ambient
# tasks-axi and never skips: a failed install or a version other than the pin
# returns 1 with a "not ok" line, and the caller exits. The install is exported
# as FM_TEST_TASKS_AXI_BIN so child test runs reuse it instead of reinstalling.
#
# Who calls it: bin/fm-test-run.sh once per run when the host has no tasks-axi,
# tests/lib.sh at source time when the host has none and no run provided one,
# and any suite that wants the pin regardless of the host. Sourcing this file
# defines the function and nothing else, so the runner can use it without
# tests/lib.sh's traps and fixture roots. It reads $ROOT, the repository root.

fm_test_provide_tasks_axi() {
  local parent=${1:?parent dir} pin seed dst bindir log
  local -a offline=()
  if [ -n "${FM_TEST_TASKS_AXI_BIN:-}" ] && [ -x "$FM_TEST_TASKS_AXI_BIN/tasks-axi" ]; then
    PATH="$FM_TEST_TASKS_AXI_BIN:$PATH"; export PATH
    return 0
  fi
  pin=$(sed -n 's/.*"tasks-axi": *"\([^"]*\)".*/\1/p' "$ROOT/bin/sbx-tasks-axi/package.json" | head -n 1)
  [ -n "$pin" ] || { echo "not ok - tasks-axi pin not found in bin/sbx-tasks-axi/package.json"; return 1; }
  command -v npm >/dev/null 2>&1 || { echo "not ok - npm is required to install the pinned tasks-axi $pin"; return 1; }
  dst=$(mktemp -d "${parent%/}/tasks-axi.XXXXXX") || { echo "not ok - could not create the tasks-axi install dir"; return 1; }
  log="$dst/install.log"
  seed=${NPM_CONFIG_CACHE:-}
  mkdir -p "$dst/pkg" "$dst/logs"
  cp "$ROOT/bin/sbx-tasks-axi/package.json" "$ROOT/bin/sbx-tasks-axi/package-lock.json" "$dst/pkg/" ||
    { echo "not ok - could not copy the tasks-axi fixture"; return 1; }
  if [ -n "$seed" ] && [ -d "$seed" ]; then
    if ! cp -a "$seed" "$dst/npm-cache" || ! chmod -R u+w "$dst/npm-cache"; then
      echo "not ok - could not copy the seeded npm cache"
      return 1
    fi
    offline=(--offline)
  else
    mkdir -p "$dst/npm-cache"
  fi
  if ! (cd "$dst/pkg" && NPM_CONFIG_CACHE="$dst/npm-cache" NPM_CONFIG_LOGS_DIR="$dst/logs" \
    npm ci ${offline[@]+"${offline[@]}"} --ignore-scripts --no-audit --no-fund) >"$log" 2>&1; then
    echo "not ok - could not install tasks-axi $pin from the npm cache: $(tail -n 5 "$log" | tr '\n' ' ')"
    return 1
  fi
  bindir="$dst/pkg/node_modules/.bin"
  [ "$("$bindir/tasks-axi" --version 2>/dev/null)" = "$pin" ] ||
    { echo "not ok - the installed tasks-axi does not report the pinned $pin"; return 1; }
  FM_TEST_TASKS_AXI_BIN=$bindir; export FM_TEST_TASKS_AXI_BIN
  PATH="$bindir:$PATH"; export PATH
}
