// Post-provisioning workstation walkthrough.
//
// After bin/onboard provisions the cloud accounts, this walks the technician
// through the workstation-side steps, copying the right PowerShell one-liner
// to the clipboard at each step. It reuses the in-memory Context (names, email,
// SIP creds) so there is no second lookup, and gum for the prompts/pauses.

import { confirm, input } from "./lib/prompt";
import type { Context } from "./types";

async function copyToClipboard(text: string): Promise<void> {
  const proc = Bun.spawn(["pbcopy"], { stdin: "pipe" });
  proc.stdin.write(text);
  await proc.stdin.end();
  await proc.exited;
}

// Single-quote a value for safe embedding in a PowerShell command.
function psq(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

// Build the standard "download from main and run" PowerShell one-liner.
function psOneLiner(script: string, args: string): string {
  return [
    "Set-ExecutionPolicy Bypass -Scope Process -Force",
    `irm https://raw.githubusercontent.com/ameriglide/it-admin/main/scripts/${script} -OutFile $env:TEMP\\${script}`,
    `& $env:TEMP\\${script} ${args}`,
  ].join("; ");
}

async function pause(): Promise<void> {
  await input("Press Enter when this step is done");
}

export async function walkWorkstationSetup(ctx: Context): Promise<void> {
  const domain = process.env.DOMAIN ?? "ameriglide.com";
  const brand = process.env.BRAND ?? "AmeriGlide";
  const marketingUrl = process.env.MARKETING_URL ?? "https://www.ameriglide.com";
  const tsKey = process.env.TAILSCALE_AUTH_KEY ?? "<paste-key-here>";
  const zUser = process.env.ZOIPER_USERNAME;
  const zPass = process.env.ZOIPER_PASSWORD;
  const user = `${ctx.firstName}.${ctx.lastName}`.toLowerCase();

  console.log(
    "\n──────────────────────────────────────────────────────────────",
  );
  console.log("Workstation setup");
  console.log(
    "Each step copies a one-liner to your clipboard. Paste it into an",
  );
  console.log("ELEVATED PowerShell on the workstation, then come back here.\n");

  // --- GCPW new-machine setup (only if the machine doesn't already have it) ---
  if (
    await confirm(
      "Is this a brand-new machine that does NOT already have GCPW?",
    )
  ) {
    await copyToClipboard(
      psOneLiner("deploy-gcpw.ps1", `-NewMachine -Domain ${domain}`),
    );
    console.log(
      "  ✓ Copied GCPW new-machine one-liner. Installs GCPW + the 'localadmin'",
    );
    console.log("    break-glass admin, and sets the Google sign-in domain.");
    await pause();
  }

  // --- setup-workstation: apps + Tailscale + Zoiper (+ SIP into Default) ---
  let args =
    `-Domain ${domain} -Brand ${psq(brand)} -MarketingUrl ${psq(marketingUrl)}` +
    ` -TailscaleAuthKey ${psq(tsKey)}`;
  if (zUser && zPass) {
    args += ` -ZoiperUsername ${psq(zUser)} -ZoiperPassword ${psq(zPass)}`;
  }

  let sipNote: string;
  if (ctx.sipUsername && ctx.sipPassword) {
    args += ` -SipUser ${psq(ctx.sipUsername)} -SipPassword ${psq(ctx.sipPassword)}`;
    sipNote = `Includes ${ctx.firstName}'s SIP login (written into the Default profile).`;
  } else {
    // sipPassword is null when the SIP credential already existed (resume) and
    // we don't hold the plaintext, or telephony was skipped. Fall back to the
    // standalone Zoiper entry in bin/copy, which decrypts it from the DB.
    sipNote =
      "No SIP creds in this run — configure Zoiper separately via bin/copy if the phone is needed.";
  }

  await copyToClipboard(psOneLiner("setup-workstation.ps1", args));
  console.log("  ✓ Copied setup-workstation one-liner (idempotent — safe to re-run).");
  console.log(`    Installs apps, joins Tailscale, installs Zoiper. ${sipNote}`);
  await pause();

  // --- Optional: Sage AMG user onboarding (also standalone in bin/copy) ---
  if (await confirm("Onboard this user into Sage (AMG)?")) {
    // Sage wants the Windows SAM name + the password set on the Google account.
    // We reuse the password captured earlier in this run so it isn't retyped.
    let sagePass = ctx.googlePassword ?? undefined;
    if (!sagePass) {
      // null when the Google account already existed (resume) — we don't hold
      // the plaintext, so ask for the password that was set on Google.
      console.log("  No Google password captured this run (account already existed).");
      sagePass = await input("Password set on their Google account");
    }
    if (sagePass) {
      await copyToClipboard(
        psOneLiner("onboard-sage-amg-user.ps1", `-SamName ${user} -Password ${psq(sagePass)}`),
      );
      console.log("  ✓ Copied Sage AMG onboarding one-liner. Provisions the Sage");
      console.log("    account using their Google password.");
      await pause();
    } else {
      console.log("  ⚠  No password — skipping Sage onboarding.");
    }
  }

  // --- Verify ---
  console.log("  Verify: confirm the device appears in Google Admin Console >");
  console.log(`    Devices, and that ${ctx.firstName} can sign in with their Google`);
  console.log("    credentials. The forced password change is already armed.");
  await pause();

  // --- Optional re-arm (copy only; do NOT auto-run, it would re-randomize the
  //     password we just set and printed in the summary) ---
  console.log("  Optional: if you TEST-signed-in on the machine yourself, re-arm a");
  console.log("  clean first-login for the employee. Copied to your clipboard:");
  console.log(`      bin/reset-user --user ${user}`);
  await copyToClipboard(`bin/reset-user --user ${user}`);

  console.log("\n✓ Workstation walkthrough complete.\n");
}
