import type { Context, Step } from "./types";
import { googleStep } from "./steps/google";
import { amberjackStep } from "./steps/amberjack";
import { phenixStep } from "./steps/phenix";
import { twilioStep } from "./steps/twilio";
import { directLineStep } from "./steps/direct-line";
import { zoiperStep } from "./steps/zoiper";
import { printSummary } from "./lib/summary";
import { closeAll } from "./lib/db";

const steps: Step[] = [
  googleStep,
  amberjackStep,
  phenixStep,
  twilioStep,
  directLineStep,
  zoiperStep,
];

export async function run(ctx: Context): Promise<void> {
  const completed: string[] = [];

  try {
    for (const step of steps) {
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
