import type { Context } from "../types";

const LINE = "══════════════════════════════════════════";

// A newly inserted Sonar agent starts paused, and the pause does not lift on
// its own: the agent clicks "Start taking calls" in Sonar. An agent that
// already existed is left as it was, so its state is not ours to report.
function takingCalls(ctx: Context): string {
  if (!ctx.sonarAgentKey) return "n/a";
  if (ctx.sonarAgentCreated === true) {
    return 'no - paused; agent clicks "Start taking calls" once the phone registers';
  }
  return "unchanged (agent already existed)";
}

export function printSummary(ctx: Context): void {
  console.log(`
${LINE}
  New Employee: ${ctx.firstName} ${ctx.lastName}
  Email: ${ctx.email}
${LINE}

  Google Workspace
    Temp Password: ${ctx.googlePassword ?? "already existed"}

  Google Groups
    Joined: ${ctx.groupsJoined?.length ? ctx.groupsJoined.join(", ") : "skipped"}

  Amberjack
    Employee ID: ${ctx.amberjackEmployeeId ?? "skipped"}

  Phenix
    Agent ID: ${ctx.phenixAgentId ?? "skipped"}

  Sonar
    Agent Key: ${ctx.sonarAgentKey ?? "skipped"}
    Taking calls: ${takingCalls(ctx)}

  Twilio
    Worker SID: ${ctx.twilioWorkerSid ?? "skipped"}
    SIP Username: ${ctx.sipUsername ?? "skipped"}
    SIP Password: ${ctx.sipPassword ?? "already existed"}

  Direct Line
    Phone: ${ctx.phoneNumber ?? "none"}

  Zoiper
    Config: ${ctx.zoiperConfigPath ?? "not generated"}
    Activation: handled by setup-workstation.ps1 (ZOIPER_USERNAME/PASSWORD in .env)

  PBX (Sonar PBX, MicroSIP)
    Extension: ${ctx.extension ?? "skipped"}
    Account sheet: ${ctx.pbxAccountSheetPath ?? "not generated"}${
      ctx.pbxPasswordMissing
        ? "\n    Password: MISSING - fill it in from 1Password before handing over the sheet"
        : ""
    }

${LINE}
  Next: set up the workstation (you'll be prompted), or use bin/copy for one-offs
${LINE}
`);
}
