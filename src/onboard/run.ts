import type { Context, Step } from "./types";
import { googleStep } from "./steps/google";
import { googleGroupsStep } from "./steps/google-groups";
import { amberjackStep } from "./steps/amberjack";
import { phenixStep } from "./steps/phenix";
import { sonarStep } from "./steps/sonar";
import { twilioStep } from "./steps/twilio";
import { directLineStep } from "./steps/direct-line";
import { zoiperStep } from "./steps/zoiper";
import { pbxStep } from "./steps/pbx";
import { orgDirectoryStep } from "./steps/org-directory";
import { isSkipped, planAutoSkips, stepKey } from "./lib/auto-skips";
import { preflight } from "./lib/preflight";
import { printSummary } from "./lib/summary";
import { closeAll } from "./lib/db";

export const steps: Step[] = [
  googleStep,
  googleGroupsStep,
  amberjackStep,
  phenixStep,
  sonarStep,
  twilioStep,
  directLineStep,
  zoiperStep,
  pbxStep,
  orgDirectoryStep,
];

export async function run(
  ctx: Context,
  skip: string[] = [],
): Promise<void> {
  const completed: string[] = [];

  // Which steps apply depends on the tenant (DOMAIN): AmeriGlide never runs
  // Sonar/PBX, other tenants (IAI) never auto-skip them; optional steps are
  // skipped when unconfigured. See planAutoSkips for the full model.
  const plan = planAutoSkips(process.env, skip);
  for (const note of plan.notes) console.log(note);

  // A --skip entry matches by prefix, so "google" skips both Google steps.
  // Say so, rather than leave the operator to notice a step went missing.
  for (const s of new Set(skip)) {
    const matched = steps.filter((st) => isSkipped(stepKey(st.name), [s]));
    if (matched.length > 1) {
      console.log(`  (--skip "${s}" matches ${matched.length} steps: ${matched.map((st) => st.name).join(", ")})`);
    }
  }

  // Catch configuration mistakes before anything is written: without this, a
  // missing PBX_HOST or bad --extension would fail after Google had already
  // created the account. Runs before the try, so no DB connection is open.
  const problems = preflight(process.env, ctx, plan.skip);
  if (problems.length) {
    console.error(`\nConfiguration problems - nothing has been changed:`);
    for (const p of problems) console.error(`  - ${p}`);
    process.exit(1);
  }

  try {
    for (const step of steps) {
      const key = stepKey(step.name);
      if (isSkipped(key, plan.skip)) {
        console.log(`\n  ⏭ ${step.name} — skipped`);
        continue;
      }
      console.log(`\nChecking ${step.name}...`);
      const done = await step.check(ctx);
      if (done) {
        console.log(`  ✓ ${step.name} — already done, skipping`);
        completed.push(step.name);
        continue;
      }
      console.log(`Running ${step.name}...`);
      await step.run(ctx);
      console.log(`  ✓ ${step.name} — done`);
      completed.push(step.name);
    }

    printSummary(ctx);
  } catch (err) {
    console.error(`\n✗ Failed during step execution\n`);
    console.error(err);
    console.error(`\nCompleted steps: ${completed.join(", ") || "none"}`);
    // printSummary never ran, and on re-run Google reports the account as
    // already existing, so this is the only chance to see the password.
    if (typeof ctx.googlePassword === "string") {
      console.error(`\nGoogle temp password for ${ctx.email}: ${ctx.googlePassword}`);
      console.error(`(it will NOT be shown again on re-run - record it now)`);
    }
    console.error(`Re-run the same command to resume from where it failed.`);
    process.exit(1);
  } finally {
    await closeAll();
  }
}
