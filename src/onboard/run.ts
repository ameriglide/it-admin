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
import { planAutoSkips, stepKey } from "./lib/auto-skips";
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

  try {
    for (const step of steps) {
      const key = stepKey(step.name);
      if (plan.skip.some((s) => key === s || key.startsWith(s))) {
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
    console.error(`Re-run the same command to resume from where it failed.`);
    process.exit(1);
  } finally {
    await closeAll();
  }
}
