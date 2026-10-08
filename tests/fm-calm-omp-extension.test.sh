#!/usr/bin/env bash
# tests/fm-calm-omp-extension.test.sh - the portable regression for the partial omp Calm
# extension (.omp/extensions/fm-calm-omp.ts), driven over a fake omp API by plain Node.
#
# Whether a real omp then hides the rows, hides thinking, and reaches the settings registry is
# HARNESS-DEPENDENT; tests/fm-calm-omp-live-e2e.test.sh is the live guard for that. This suite
# pins the extension's own logic: the shared config/calm contract, the /calm toggle, which native
# settings it drives and with what, working-row reapplication, and honest degradation.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-calm-omp-extension)
export NODE_NO_WARNINGS=1

# A repo copy of the extension with a stand-in for omp's settings registry, so the real
# loader path runs: the stub records every override and clearOverride it receives.
install_fixture() {  # <repo>
  local repo=$1
  mkdir -p "$repo/.omp/extensions" "$repo/node_modules/@oh-my-pi/pi-coding-agent/config"
  cp "$ROOT/.omp/extensions/fm-calm-omp.ts" "$repo/.omp/extensions/"
  printf '{"name":"@oh-my-pi/pi-coding-agent","type":"module","exports":{"./config/registry":"./config/registry.js"}}\n' \
    > "$repo/node_modules/@oh-my-pi/pi-coding-agent/package.json"
  cat > "$repo/node_modules/@oh-my-pi/pi-coding-agent/config/registry.js" <<'JS'
export const calls = [];
const known = new Set(["display.hideToolActivity", "hideThinkingBlock"]);
export function lookup(id) {
  if (!known.has(id) || globalThis.__ompRegistryMissing === id) return undefined;
  return {
    override(scope, value) { calls.push({ id, op: "override", scope, value }); },
    clearOverride(scope) { calls.push({ id, op: "clearOverride", scope }); },
  };
}
JS
}

run_node() {  # <repo> <config-dir> ; script on stdin
  local repo=$1 config=$2 registry="$1/node_modules/@oh-my-pi/pi-coding-agent/config/registry.js"
  [ -f "$registry" ] || registry=
  EXT="$repo/.omp/extensions/fm-calm-omp.ts" FM_CONFIG_OVERRIDE="$config" REGISTRY="$registry" \
    node --input-type=module 2>&1
}

PRELUDE='
import { pathToFileURL } from "node:url";
import { readFileSync, existsSync } from "node:fs";
const handlers = new Map();
let command;
const settings = { sentinel: "omp-settings" };
const pi = { pi: { Settings: { instance: settings } }, on(e, h) { handlers.set(e, h); }, registerCommand(n, c) { if (n === "calm") command = c; } };
const messages = [];
const notices = [];
const ctx = { ui: { setWorkingMessage(m) { messages.push(m); }, notify(m, t) { notices.push({ m, t }); } } };
const mod = await import(pathToFileURL(process.env.EXT).href);
const preference = () => existsSync(`${process.env.FM_CONFIG_OVERRIDE}/calm`) ? readFileSync(`${process.env.FM_CONFIG_OVERRIDE}/calm`, "utf8") : null;
const registry = process.env.REGISTRY ? await import(pathToFileURL(process.env.REGISTRY).href) : null;
const must = (cond, msg) => { if (!cond) throw new Error(msg); };
'

test_toggle_persists_and_drives_native_settings() {
  local repo="$TMP_ROOT/toggle/repo" config="$TMP_ROOT/toggle/config" out status
  install_fixture "$repo"
  out=$(run_node "$repo" "$config" <<EOF
$PRELUDE
mod.default(pi);
must(command && command.description, "the /calm command was not registered");
for (const name of ["session_start", "agent_start", "turn_start", "tool_execution_start", "tool_execution_end"]) {
  must(handlers.has(name), name + " handler was not registered");
}
await handlers.get("session_start")({}, ctx);
must(preference() === null, "an absent preference must not be written by session start");
must(registry.calls.length === 2 && registry.calls.every((c) => c.op === "clearOverride" && c.scope === settings), "Calm off must clear both overrides against the omp settings: " + JSON.stringify(registry.calls));
must(messages.at(-1) === undefined, "Calm off must restore the stock working message");
registry.calls.length = 0; messages.length = 0;

await command.handler("", ctx);
must(preference() === "on\n", "first toggle must save on, got " + JSON.stringify(preference()));
const ids = registry.calls.map((c) => c.id).sort().join(",");
must(ids === "display.hideToolActivity,hideThinkingBlock", "Calm on must drive tool activity and thinking, drove " + ids);
must(registry.calls.every((c) => c.op === "override" && c.value === true && c.scope === settings), "Calm on must override both to true: " + JSON.stringify(registry.calls));
must(messages.at(-1) === mod.CALM_WORKING_MESSAGE && mod.CALM_WORKING_MESSAGE.length > 0, "Calm on must set the plain working message");
registry.calls.length = 0; messages.length = 0;

for (const name of ["agent_start", "turn_start", "tool_execution_start", "tool_execution_end"]) {
  messages.length = 0;
  await handlers.get(name)({}, ctx);
  must(messages.at(-1) === mod.CALM_WORKING_MESSAGE, name + " must reapply the plain working message while on");
}

await command.handler("", ctx);
must(preference() === "off\n", "second toggle must save off, got " + JSON.stringify(preference()));
must(registry.calls.length === 2 && registry.calls.every((c) => c.op === "clearOverride"), "Calm off must clear the overrides, not set false: " + JSON.stringify(registry.calls));
must(messages.at(-1) === undefined, "Calm off must restore the stock working message");
messages.length = 0;
await handlers.get("tool_execution_start")({}, ctx);
must(messages.length === 0, "Calm off must not touch the working message on tool events");
must(notices.length === 0, "a healthy toggle must not notify: " + JSON.stringify(notices));
EOF
)
  status=$?
  expect_code 0 "$status" "omp Calm toggle: $out"
  [ -z "$out" ] || fail "omp Calm toggle test printed output: $out"
  pass ".omp calm: /calm saves on and off, overrides then clears the two native settings, and manages the working message"
}

test_preference_is_restored_on_session_start() {
  local repo="$TMP_ROOT/restore/repo" config="$TMP_ROOT/restore/config" out status value
  install_fixture "$repo"
  mkdir -p "$config"
  for value in on max off garbage ""; do
    printf '%s\n' "$value" > "$config/calm"
    out=$(CALM_VALUE="$value" run_node "$repo" "$config" <<EOF
$PRELUDE
mod.default(pi);
await handlers.get("session_start")({}, ctx);
const expectedOn = ["on", "max"].includes(process.env.CALM_VALUE);
const overridden = registry.calls.every((c) => c.op === "override");
must(expectedOn ? overridden && registry.calls.length === 2 : registry.calls.every((c) => c.op === "clearOverride"), "value '$value' restored the wrong state: " + JSON.stringify(registry.calls));
must(expectedOn ? messages.at(-1) === mod.CALM_WORKING_MESSAGE : messages.at(-1) === undefined, "value '$value' restored the wrong working message");
EOF
)
    status=$?
    expect_code 0 "$status" "omp Calm restore of '$value': $out"
    [ -z "$out" ] || fail "omp Calm restore test printed output for '$value': $out"
  done
  pass ".omp calm: session start reads on and the legacy max as on, and off, junk, or empty as off"
}

test_failed_save_leaves_the_choice_unchanged() {
  local repo="$TMP_ROOT/failsave/repo" config="$TMP_ROOT/failsave/blocker/config" out status
  install_fixture "$repo"
  mkdir -p "$TMP_ROOT/failsave/blocker"
  : > "$TMP_ROOT/failsave/blocker/config"
  out=$(run_node "$repo" "$config" <<EOF
$PRELUDE
mod.default(pi);
await handlers.get("session_start")({}, ctx);
registry.calls.length = 0; messages.length = 0;
await command.handler("", ctx);
must(registry.calls.length === 0, "a failed save must not change visibility: " + JSON.stringify(registry.calls));
must(messages.length === 0, "a failed save must not change the working message");
must(notices.length === 1 && notices[0].t === "error" && notices[0].m.includes("stays off"), "a failed save must be reported as an error that keeps Calm off: " + JSON.stringify(notices));
EOF
)
  status=$?
  expect_code 0 "$status" "omp Calm failed save: $out"
  [ -z "$out" ] || fail "omp Calm failed-save test printed output: $out"
  pass ".omp calm: a failed preference write keeps the current choice and says so"
}

test_home_resolution_without_config_override() {
  local repo="$TMP_ROOT/home/repo" home="$TMP_ROOT/home/fmhome" out status
  install_fixture "$repo"
  mkdir -p "$home/config"
  printf 'on\n' > "$home/config/calm"
  out=$(EXT="$repo/.omp/extensions/fm-calm-omp.ts" FM_HOME="$home" REGISTRY="$repo/node_modules/@oh-my-pi/pi-coding-agent/config/registry.js" \
    env -u FM_CONFIG_OVERRIDE node --input-type=module 2>&1 <<EOF
$PRELUDE
mod.default(pi);
await handlers.get("session_start")({}, ctx);
must(registry.calls.length === 2 && registry.calls.every((c) => c.op === "override"), "FM_HOME/config/calm must be read when no config override is set: " + JSON.stringify(registry.calls));
await command.handler("", ctx);
must(readFileSync(process.env.FM_HOME + "/config/calm", "utf8") === "off\n", "the toggle must write FM_HOME/config/calm");
EOF
)
  status=$?
  expect_code 0 "$status" "omp Calm home resolution: $out"
  [ -z "$out" ] || fail "omp Calm home-resolution test printed output: $out"
  pass ".omp calm: the preference resolves under FM_HOME/config when FM_CONFIG_OVERRIDE is unset"
}

test_unreachable_registry_degrades_with_one_notice() {
  local repo="$TMP_ROOT/degrade/repo" config="$TMP_ROOT/degrade/config" out status
  # No stand-in registry: the real loader's import must fail the way an omp build without it would.
  mkdir -p "$repo/.omp/extensions"
  cp "$ROOT/.omp/extensions/fm-calm-omp.ts" "$repo/.omp/extensions/"
  mkdir -p "$config"
  printf 'on\n' > "$config/calm"
  out=$(run_node "$repo" "$config" <<EOF
$PRELUDE
mod.default(pi);
await handlers.get("session_start")({}, ctx);
must(notices.length === 1 && notices[0].t === "warning" && notices[0].m.includes("tool rows and thinking stay visible"), "an unreachable registry must produce one warning: " + JSON.stringify(notices));
must(messages.at(-1) === mod.CALM_WORKING_MESSAGE, "the working message must still apply when hiding is unavailable");
await command.handler("", ctx);
must(preference() === "off\n", "the preference must still save when hiding is unavailable");
await command.handler("", ctx);
must(preference() === "on\n" && notices.length === 1, "the warning must not repeat within a session: " + JSON.stringify(notices));
EOF
)
  status=$?
  expect_code 0 "$status" "omp Calm degraded registry: $out"
  [ -z "$out" ] || fail "omp Calm degraded-registry test printed output: $out"
  pass ".omp calm: an unreachable settings registry warns once and keeps the preference and working message"
}

test_missing_setting_degrades_instead_of_half_hiding() {
  local repo="$TMP_ROOT/missing/repo" config="$TMP_ROOT/missing/config" out status
  install_fixture "$repo"
  mkdir -p "$config"
  printf 'on\n' > "$config/calm"
  out=$(run_node "$repo" "$config" <<EOF
$PRELUDE
globalThis.__ompRegistryMissing = "hideThinkingBlock";
mod.default(pi);
await handlers.get("session_start")({}, ctx);
must(registry.calls.length === 0, "an unregistered setting must stop all hiding, not hide half: " + JSON.stringify(registry.calls));
must(notices.length === 1 && notices[0].m.includes("hideThinkingBlock"), "the warning must name the missing setting: " + JSON.stringify(notices));
EOF
)
  status=$?
  expect_code 0 "$status" "omp Calm missing setting: $out"
  [ -z "$out" ] || fail "omp Calm missing-setting test printed output: $out"
  pass ".omp calm: a setting omp does not register stops hiding entirely and is named in the warning"
}

test_toggle_persists_and_drives_native_settings
test_preference_is_restored_on_session_start
test_failed_save_leaves_the_choice_unchanged
test_home_resolution_without_config_override
test_unreachable_registry_degrades_with_one_notice
test_missing_setting_degrades_instead_of_half_hiding
