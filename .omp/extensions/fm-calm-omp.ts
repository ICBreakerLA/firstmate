// Firstmate's partial Calm for the omp (Oh My Pi) primary: a /calm toggle that persists to
// the shared config/calm preference and, while on, hides built-in and Firstmate tool rows,
// hides thinking blocks, and keeps the working row's text plain.
//
// docs/calm.md owns the user-facing behavior and the known gaps, and docs/configuration.md
// owns the config/calm contract. The mechanism differs from the Pi extension on purpose:
// omp already has native runtime settings for tool activity (display.hideToolActivity) and
// thinking (hideThinkingBlock), and the interactive mode applies a runtime override of
// either live, so this file overrides those two settings for the process instead of
// re-registering the built-in tools with empty renderers. A runtime override is never
// written to the user's omp config, and clearing it restores whatever they configured.
// Reaching the setting handles needs omp's settings registry, which the extension API does
// not expose; if that deep import is unavailable on a given omp build the hiding degrades
// with one notice and the preference and working-row behavior keep working.
//
// Verified from the omp 18.8.4 source only; docs/verification/runtime-backends.md records
// that this is not yet live-verified.
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// The omp extension API surface this file uses, declared locally: omp ships no separately
// installable type package.
type CalmUi = {
  notify?: (message: string, type?: "info" | "warning" | "error") => void;
  setWorkingMessage?: (message?: string) => void;
};
type CalmContext = { ui?: CalmUi };
type OmpApi = {
  on: (event: string, handler: (event: any, ctx: CalmContext) => unknown) => void;
  registerCommand: (
    name: string,
    command: { description: string; handler: (args: string, ctx: CalmContext) => Promise<void> | void },
  ) => void;
  pi?: { Settings?: { instance?: unknown } };
};

export type NativeVisibility = { apply: (active: boolean) => void };

// The two native omp settings Calm drives, by registry id.
const NATIVE_SETTING_IDS = ["display.hideToolActivity", "hideThinkingBlock"] as const;

// Plain text for the working row; omp replaces it with tool-intent text between events, so
// it is re-applied on each turn and tool event.
export const CALM_WORKING_MESSAGE = "Working…";

const REAPPLY_WORKING_EVENTS = ["agent_start", "turn_start", "tool_execution_start", "tool_execution_end"];

async function loadNativeVisibility(pi: OmpApi): Promise<NativeVisibility> {
  const registry = await import("@oh-my-pi/pi-coding-agent/config/registry");
  const settings = pi.pi?.Settings?.instance;
  if (!settings) throw new Error("omp settings are not initialised");
  const handles = NATIVE_SETTING_IDS.map((id) => {
    const handle = registry.lookup(id);
    if (!handle) throw new Error(`omp setting ${id} is not registered`);
    return handle;
  });
  return {
    apply(active) {
      for (const handle of handles) {
        if (active) handle.override(settings, true);
        else handle.clearOverride(settings);
      }
    },
  };
}

export default function (pi: OmpApi): void {
  const extensionDir = dirname(fileURLToPath(import.meta.url));
  const root = resolve(extensionDir, "../..");
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const configDirectory = process.env.FM_CONFIG_OVERRIDE || resolve(fmHome, "config");
  const preferencePath = resolve(configDirectory, "calm");

  let active = false;
  let visibility: Promise<NativeVisibility> | undefined;
  let degradedReported = false;

  // "max" is the legacy value of the removed third presentation level, now ordinary Calm.
  const loadPreference = (): boolean => {
    try {
      const stored = readFileSync(preferencePath, "utf8").trim();
      return stored === "on" || stored === "max";
    } catch {
      return false;
    }
  };

  const persistPreference = (value: boolean): void => {
    mkdirSync(dirname(preferencePath), { recursive: true });
    const temporaryPath = `${preferencePath}.${process.pid}.${randomUUID()}.tmp`;
    try {
      writeFileSync(temporaryPath, value ? "on\n" : "off\n", { encoding: "utf8", flag: "wx", mode: 0o600 });
      renameSync(temporaryPath, preferencePath);
    } finally {
      rmSync(temporaryPath, { force: true });
    }
  };

  const applyNativeVisibility = async (ctx: CalmContext): Promise<void> => {
    try {
      visibility ??= loadNativeVisibility(pi);
      (await visibility).apply(active);
    } catch (error) {
      visibility = undefined;
      // Nothing was hidden, so there is nothing to report when turning Calm off.
      if (!active || degradedReported) return;
      degradedReported = true;
      const reason = error instanceof Error ? error.message : String(error);
      const message = `Firstmate Calm: this omp build does not expose the settings Calm drives, so tool rows and thinking stay visible. ${reason}`;
      if (ctx.ui?.notify) ctx.ui.notify(message, "warning");
      else console.error(message);
    }
  };

  const applyWorkingMessage = (ctx: CalmContext): void => {
    ctx.ui?.setWorkingMessage?.(active ? CALM_WORKING_MESSAGE : undefined);
  };

  pi.on("session_start", async (_event, ctx) => {
    active = loadPreference();
    degradedReported = false;
    await applyNativeVisibility(ctx);
    applyWorkingMessage(ctx);
  });

  for (const event of REAPPLY_WORKING_EVENTS) {
    pi.on(event, (_event, ctx) => {
      if (active) applyWorkingMessage(ctx);
    });
  }

  pi.registerCommand("calm", {
    description: "Toggle Firstmate's partial conversation-only transcript presentation.",
    handler: async (_args, ctx) => {
      const next = !active;
      try {
        persistPreference(next);
      } catch (error) {
        const reason = error instanceof Error ? error.message : String(error);
        ctx.ui?.notify?.(`Firstmate Calm: could not save the preference, so Calm stays ${active ? "on" : "off"}. ${reason}`, "error");
        return;
      }
      active = next;
      await applyNativeVisibility(ctx);
      applyWorkingMessage(ctx);
    },
  });
}
