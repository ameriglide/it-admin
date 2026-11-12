import type { Context } from "../types";
import { isSkipped, stepKey } from "./auto-skips";
import { isAmeriGlide, tenantDomain } from "./tenant";
import { EXTENSION_RE, isPbxEnabled } from "./extension";

type Env = Record<string, string | undefined>;

const PBX_OP_VARS = ["PBX_OP_ITEM", "PBX_OP_VAULT", "PBX_OP_ACCOUNT"] as const;

export interface PreflightResult {
  // Mistakes that would fail the run part-way: run() refuses to start.
  problems: string[];
  // Surprising but runnable configurations: run() prints them and carries on.
  warnings: string[];
}

// Configuration mistakes that would otherwise surface only part-way through a
// run, after Google has already created the account (and shown its temp
// password once). run() calls this before any step and refuses to start if
// `problems` is non-empty; `warnings` are printed and the run proceeds.
//
// Problems (each checked only when the step that needs it runs):
//   - ameriglide.com: AMBERJACK_DATABASE_URL (Amberjack), PHENIX_DATABASE_URL
//     (Phenix).
//   - any other tenant: SONAR_DATABASE_URL (Sonar); PBX_HOST, and
//     PBX_OP_ITEM/PBX_OP_VAULT/PBX_OP_ACCOUNT all-or-none (PBX);
//     ONBOARD_ORG_UNIT_PATH (Google Workspace).
//   - --extension, when Sonar or PBX runs: four digits, and listed in
//     PBX_ENABLED_EXTENSIONS when that list is set.
//   - PBX runs, Sonar is skipped and there is no --extension (the PBX step
//     takes the extension from the Sonar step or from --extension).
// Warnings:
//   - --extension / --call-center / --no-sales given while neither Sonar nor
//     PBX runs, so they have no effect.
//   - off ameriglide.com, Amberjack/Phenix will run because their
//     DATABASE_URL is set (possibly a leftover AmeriGlide value).
// Nothing else is checked: Twilio, Google Groups and the org directory are
// auto-skipped by planAutoSkips when unconfigured.
//
// Pure: reads only `env`, the picked ctx fields and `skip` (the full skip
// list, user entries plus planAutoSkips', matched as run() matches them).
// Returns everything found, so one run reports it all.
export function preflight(
  env: Env,
  ctx: Pick<Context, "extension" | "sonarCallCenter" | "sales">,
  skip: string[],
): PreflightResult {
  const problems: string[] = [];
  const warnings: string[] = [];
  const runs = (stepName: string) => !isSkipped(stepKey(stepName), skip);
  const sonar = runs("Sonar");
  const pbx = runs("PBX");
  const google = runs("Google Workspace");
  const amberjack = runs("Amberjack");
  const phenix = runs("Phenix");
  const domain = tenantDomain(env);

  if (isAmeriGlide(env)) {
    if (amberjack && !env.AMBERJACK_DATABASE_URL) {
      problems.push("AMBERJACK_DATABASE_URL is not set (needed by the Amberjack step)");
    }
    if (phenix && !env.PHENIX_DATABASE_URL) {
      problems.push("PHENIX_DATABASE_URL is not set (needed by the Phenix step)");
    }
  } else {
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
    // planAutoSkips runs these on any tenant whose env provides the URL.
    const agSteps: string[] = [];
    if (amberjack && env.AMBERJACK_DATABASE_URL) agSteps.push("Amberjack (AMBERJACK_DATABASE_URL)");
    if (phenix && env.PHENIX_DATABASE_URL) agSteps.push("Phenix (PHENIX_DATABASE_URL)");
    if (agSteps.length) {
      warnings.push(
        `tenant is ${domain}, but ${agSteps.join(" and ")} will run because the URL is set; ` +
          `if that is a leftover AmeriGlide value, unset it or --skip the step`,
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

  if (pbx && !sonar && ext === undefined) {
    problems.push("--extension is required when the Sonar step is skipped (the PBX step needs it)");
  }

  if (!sonar && !pbx) {
    const ignored: string[] = [];
    if (ext !== undefined) ignored.push("--extension");
    if (ctx.sonarCallCenter !== undefined) ignored.push("--call-center");
    if (ctx.sales === false) ignored.push("--no-sales");
    if (ignored.length) {
      warnings.push(
        `${ignored.join("/")} ${ignored.length > 1 ? "have" : "has"} no effect: ` +
          `Sonar and PBX do not run for ${domain}`,
      );
    }
  }

  return { problems, warnings };
}
