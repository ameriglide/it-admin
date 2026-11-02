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
import { orgDirectoryStep, mirrorsOrgDirectory } from "./steps/org-directory";
import { printSummary } from "./lib/summary";
import { closeAll } from "./lib/db";

const steps: Step[] = [
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

  // Which steps apply is decided by which credentials this checkout has, so one
  // codebase serves both tenants: AmeriGlide's .env has Phenix/Twilio and no
  // Sonar; IAI's has Sonar/PBX and no Twilio.
  const skipUnlessSet = (envVar: string, keys: string[], why: string) => {
    if (process.env[envVar]) return;
    const added = keys.filter((k) => !skip.includes(k));
    skip.push(...added);
    if (added.length) console.log(`  (${envVar} unset - skipping ${why})`);
  };

  skipUnlessSet("AMBERJACK_DATABASE_URL", ["amberjack"], "Amberjack");
  skipUnlessSet("PHENIX_DATABASE_URL", ["phenix"], "Phenix");
  skipUnlessSet("SONAR_DATABASE_URL", ["sonar"], "Sonar");

  // Tenants without Twilio (e.g. inetalliance.net) leave TWILIO_ACCOUNT_SID
  // unset; auto-skip Twilio and the steps that consume its SIP credentials
  // so the run stays quiet about telephony rather than failing on a missing
  // env var. Zoiper here is the Twilio-SIP softphone config, which is a
  // different thing from the IAI PBX step below.
  skipUnlessSet(
    "TWILIO_ACCOUNT_SID",
    ["twilio", "directline", "zoiper"],
    "Twilio, Direct Line, Zoiper",
  );

  // IAI's phone is the new Sonar PBX; AmeriGlide has no PBX step at all.
  skipUnlessSet("PBX_HOST", ["pbx"], "PBX softphone");

  // No role->group config for this tenant: skip the Google Groups step rather
  // than prompt with an empty list. (Step key = "Google Groups" lowercased,
  // whitespace stripped = "googlegroups".)
  skipUnlessSet("ONBOARD_ROLES", ["googlegroups"], "Google Groups");

  // The org-directory mem0 mirror only covers ameriglide.com, and needs a key.
  if (!mirrorsOrgDirectory()) {
    if (!skip.includes("orgdirectory")) skip.push("orgdirectory");
    console.log(
      "  (MEM0_API_KEY unset or tenant is not ameriglide.com - skipping Org directory)",
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
