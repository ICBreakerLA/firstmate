#!/usr/bin/env bash
# Behavior tests for bin/fm-sbx-npm-seed.sh: the seed installs from copies of
# the manifests into the given cache, never from or into the project.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEED="$ROOT/bin/fm-sbx-npm-seed.sh"
TMP_ROOT=$(fm_test_tmproot fm-sbx-npm-seed)

# A fake npm that records where and how it ran, and fills the cache it is given.
make_fake_npm() { # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat >"$fb/npm" <<SH
#!/usr/bin/env bash
{ pwd; printf '%s\n' "\$*"; } >"$1/npm.log"
while [ \$# -gt 0 ]; do
  [ "\$1" != --cache ] || { mkdir -p "\$2/_cacache"; : >"\$2/_cacache/entry"; }
  shift
done
[ -z "\${FM_FAKE_NPM_FAIL:-}" ] || exit 1
exit 0
SH
  chmod +x "$fb/npm"
  printf '%s\n' "$fb"
}

new_project() { # <dir>
  mkdir -p "$1/proj"
  printf '{"name":"p","version":"1.0.0"}\n' >"$1/proj/package.json"
  printf '{"lockfileVersion":3}\n' >"$1/proj/package-lock.json"
}

test_seeds_from_copies_into_the_cache() {
  local d="$TMP_ROOT/ok" fb out rc
  mkdir -p "$d"
  fb=$(make_fake_npm "$d")
  new_project "$d"
  out=$(PATH="$fb:$PATH" "$SEED" "$d/proj" "$d/cache" 2>&1); rc=$?
  expect_code 0 "$rc" "seeding should succeed: $out"
  assert_present "$d/cache/_cacache/entry" "the cache is filled"
  assert_grep "ci --ignore-scripts" "$d/npm.log" "no lifecycle script may run"
  assert_grep "--cache $d/cache" "$d/npm.log" "the install targets the seed cache"
  assert_no_grep "$d/proj" "$d/npm.log" "the install does not run inside the project"
  assert_absent "$d/proj/node_modules" "the project is never written"
  pass "the seed installs from scratch copies into the cache and leaves the project alone"
}

test_defaults_to_the_home_data_dir() {
  local d="$TMP_ROOT/default" fb out rc
  mkdir -p "$d/home/data"
  fb=$(make_fake_npm "$d")
  new_project "$d"
  out=$(PATH="$fb:$PATH" FM_HOME="$d/home" "$SEED" "$d/proj" 2>&1); rc=$?
  expect_code 0 "$rc" "seeding should succeed: $out"
  assert_present "$d/home/data/sbx-npm-cache/_cacache/entry" "the default cache is data/sbx-npm-cache"
  pass "the default cache is the home's data/sbx-npm-cache"
}

test_refuses_without_a_lockfile_or_on_install_failure() {
  local d="$TMP_ROOT/refuse" fb out rc
  mkdir -p "$d/nolock"
  fb=$(make_fake_npm "$d")
  printf '{}\n' >"$d/nolock/package.json"
  out=$(PATH="$fb:$PATH" "$SEED" "$d/nolock" "$d/cache" 2>&1); rc=$?
  expect_code 1 "$rc" "a missing lockfile must refuse"
  assert_contains "$out" "package-lock.json" "the refusal names the lockfile"
  new_project "$d"
  out=$(PATH="$fb:$PATH" FM_FAKE_NPM_FAIL=1 "$SEED" "$d/proj" "$d/cache2" 2>&1); rc=$?
  expect_code 1 "$rc" "a failed install must refuse"
  assert_contains "$out" "npm ci failed" "the failure is reported"
  pass "a missing lockfile or a failed install refuses with the reason"
}

test_seeds_from_copies_into_the_cache
test_defaults_to_the_home_data_dir
test_refuses_without_a_lockfile_or_on_install_failure

echo "# all fm-sbx-npm-seed tests passed"
