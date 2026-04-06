import type { Context, Step } from "./types";
import { googleStep } from "./steps/google";
import { amberjackStep } from "./steps/amberjack";
import { phenixStep } from "./steps/phenix";
import { twilioStep } from "./steps/twilio";
import { directLineStep } from "./steps/direct-line";
import { zoiperStep } from "./steps/zoiper";

export async function run(ctx: Context): Promise<void> {
  const steps: Step[] = [
    googleStep,
    amberjackStep,
    phenixStep,
    twilioStep,
    directLineStep,
    zoiperStep,
  ];

  for (const step of steps) {
    console.log(`\nChecking ${step.name}...`);
    const done = await step.check(ctx);
    if (done) {
      console.log(`  ✓ ${step.name} — already done, skipping`);
      continue;
    }
    console.log(`Running ${step.name}...`);
    await step.run(ctx);
    console.log(`  ✓ ${step.name} — done`);
  }
}
