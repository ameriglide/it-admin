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

export async function run(
  ctx: Context,
  skip: string[] = [],
): Promise<void> {
  const completed: string[] = [];

  // Tenants without Twilio (e.g. inetalliance.net) leave TWILIO_ACCOUNT_SID
  // unset; auto-skip Twilio and the steps that consume its SIP credentials
  // so the run stays quiet about telephony rather than failing on a missing
  // env var.
  if (!process.env.TWILIO_ACCOUNT_SID) {
    const telephonySkips = ["twilio", "directline", "zoiper"];
    for (const s of telephonySkips) {
      if (!skip.includes(s)) skip.push(s);
    }
    console.log(
      "  (TWILIO_ACCOUNT_SID unset - skipping Twilio, Direct Line, Zoiper)",
    );
  }

  try {
    for (const step of steps) {
      const stepKey = step.name.toLowerCase().replace(/\s+/g, "");
      if (skip.some((s) => stepKey === s || stepKey.startsWith(s))) {
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
