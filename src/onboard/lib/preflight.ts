import type { Context } from "../types";
import { isSkipped, stepKey } from "./auto-skips";
import { isAmeriGlide } from "./tenant";
import { EXTENSION_RE, isPbxEnabled } from "./extension";

type Env = Record<string, string | undefined>;

const PBX_OP_VARS = ["PBX_OP_ITEM", "PBX_OP_VAULT", "PBX_OP_ACCOUNT"] as const;

// Configuration mistakes that would otherwise surface only part-way through a
// run, after Google has already created the account (and shown its temp
// password once). run() calls this before any step and refuses to start if it
// returns anything.
//
// Pure: reads only `env`, `ctx.extension` and `skip` (the full skip list,
// user entries plus planAutoSkips', matched as run() matches them). Returns
// every problem found, so one run reports them all; empty means OK.
export function preflight(
  env: Env,
  ctx: Pick<Context, "extension">,
  skip: string[],
): string[] {
  const problems: string[] = [];
  const runs = (stepName: string) => !isSkipped(stepKey(stepName), skip);
  const sonar = runs("Sonar");
  const pbx = runs("PBX");
  const google = runs("Google Workspace");

  if (!isAmeriGlide(env)) {
    if (sonar && !env.SONAR_DATABASE_URL) {
      problems.push("SONAR_DATABASE_URL is not set (needed by the Sonar step)");
    }
    if (pbx) {
      if (!env.PBX_HOST) problems.push("PBX_HOST is not set (needed by the PBX step)");
      const missing = PBX_OP_VARS.filter((v) => !env[v]);
      if (missing.length && missing.length < PBX_OP_VARS.length) {
        problems.push(
          `PBX_OP_ITEM, PBX_OP_VAULT and PBX_OP_ACCOUNT must be set together or not at all; ` +
            `missing: ${missing.join(", ")}`,
        );
      }
    }
    if (google && !env.ONBOARD_ORG_UNIT_PATH?.trim()) {
      problems.push(
        "ONBOARD_ORG_UNIT_PATH is not set (the Google Workspace step needs this tenant's org unit)",
      );
    }
  }

  const ext = ctx.extension;
  if (ext !== undefined && (sonar || pbx)) {
    if (!EXTENSION_RE.test(ext)) {
      problems.push(`--extension "${ext}" is not four digits`);
    } else if (isPbxEnabled(ext, env) === false) {
      problems.push(
        `--extension ${ext} is not enabled on the PBX (not in PBX_ENABLED_EXTENSIONS)`,
      );
    }
  }

  return problems;
}
