import type { Context } from "../types";

const LINE = "══════════════════════════════════════════";

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
    Taking calls: ${ctx.sonarAgentKey ? "no - paused until the phone registers" : "n/a"}

  Twilio
    Worker SID: ${ctx.twilioWorkerSid ?? "skipped"}
    SIP Username: ${ctx.sipUsername ?? "skipped"}
    SIP Password: ${ctx.sipPassword ?? "already existed"}

  Direct Line
    Phone: ${ctx.phoneNumber ?? "none"}

  Zoiper
    Config: ${ctx.zoiperConfigPath ?? "not generated"}
    Activation: handled by setup-workstation.ps1 (ZOIPER_USERNAME/PASSWORD in .env)

  PBX (new Sonar PBX, MicroSIP)
    Extension: ${ctx.extension ?? "skipped"}
    Account sheet: ${ctx.pbxAccountSheetPath ?? "not generated"}

${LINE}
  Next: set up the workstation (you'll be prompted), or use bin/copy for one-offs
${LINE}
`);
}
