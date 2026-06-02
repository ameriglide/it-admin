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

  Amberjack
    Employee ID: ${ctx.amberjackEmployeeId ?? "skipped"}

  Phenix
    Agent ID: ${ctx.phenixAgentId ?? "skipped"}

  Twilio
    Worker SID: ${ctx.twilioWorkerSid ?? "skipped"}
    SIP Username: ${ctx.sipUsername ?? "skipped"}
    SIP Password: ${ctx.sipPassword ?? "already existed"}

  Direct Line
    Phone: ${ctx.phoneNumber ?? "none"}

  Zoiper
    Config: ${ctx.zoiperConfigPath ?? "not generated"}
    Activation: handled by setup-workstation.ps1 (ZOIPER_USERNAME/PASSWORD in .env)

${LINE}
  Next: set up the workstation (you'll be prompted), or use bin/copy for one-offs
${LINE}
`);
}
