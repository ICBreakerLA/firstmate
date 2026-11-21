import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = process.env.FM_TEST_TS_DIR;
if (!root) throw new Error("FM_TEST_TS_DIR must name a directory whose node_modules holds typescript");
const ts = createRequire(join(root, "noop.cjs"))("typescript");

export async function load(url, context, nextLoad) {
  if (!url.startsWith("file:")) return nextLoad(url, context);
  const file = new URL(url);
  if (!file.pathname.endsWith(".ts")) return nextLoad(url, context);
  const fileName = fileURLToPath(file.protocol + "//" + file.pathname);
  const { outputText, diagnostics } = ts.transpileModule(await readFile(fileName, "utf8"), {
    fileName,
    reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ESNext },
  });
  if (diagnostics.length) {
    throw new Error(ts.formatDiagnostics(diagnostics, { getCanonicalFileName: (f) => f, getCurrentDirectory: () => "", getNewLine: () => "\n" }));
  }
  return { format: "module", source: outputText, shortCircuit: true };
}
