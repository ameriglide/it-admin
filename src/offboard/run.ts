import type { OffboardContext, Step } from "./types";
import { phenixStep } from "./steps/phenix";
import { twilioStep } from "./steps/twilio";
import { amberjackStep } from "./steps/amberjack";
import { googleStep } from "./steps/google";
import { closeAll } from "../onboard/lib/db";

const steps: Step[] = [phenixStep, twilioStep, amberjackStep, googleStep];

export async function run(
  ctx: OffboardContext,
  skip: string[] = [],
): Promise<void> {
  if (ctx.dryRun) console.log("(dry-run: no destructive actions will execute)");

  const completed: string[] = [];

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

const LINE = "══════════════════════════════════════════";

function printSummary(ctx: OffboardContext): void {
  console.log(`
${LINE}
  Offboarded: ${ctx.email}
${LINE}

  Phenix
    Status: inactive (via Remix setAgentInactive)

  Twilio
    Worker SID: ${ctx.twilioWorkerSid ?? "already absent"}
    SIP Credential SID: ${ctx.credentialSid ?? "already absent"}

  Amberjack
    Employee ID: ${ctx.amberjackEmployeeId ?? "not present"} (locked = true)

  Google
    Manager (Drive transfer): ${ctx.managerEmail ?? "n/a"}
    Mail backup: ${ctx.gybBackupPath ?? "n/a"}
    Archive group: ${ctx.groupEmail ?? "n/a"}

${LINE}
`);
}
