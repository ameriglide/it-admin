import type { Context } from "../types";
import { isAmeriGlide } from "./tenant";

const LINE = "══════════════════════════════════════════";

// A Sonar agent that is paused takes no calls, and the pause does not lift on
// its own: the agent clicks "Start taking calls" in Sonar. The Sonar step
// records agent.paused on every path that sets sonarAgentKey, so the two
// sonarAgentCreated branches below are not reached today. They are defensive:
// should a future path set the key without paused, fall back to what we know
// from whether this run inserted the agent (new agents start paused; an
// existing one was left as it was) rather than report "yes" or "n/a".
function takingCalls(ctx: Context): string {
  if (!ctx.sonarAgentKey) return "n/a";
  if (ctx.sonarAgentPaused === true) {
    return 'no - paused; agent clicks "Start taking calls" once the phone registers';
  }
  if (ctx.sonarAgentPaused === false) return "yes";
  if (ctx.sonarAgentCreated === true) {
    return 'no - paused; agent clicks "Start taking calls" once the phone registers';
  }
  return "unchanged (agent already existed)";
}

// Sonar and the PBX exist only in the IAI tenant; an AmeriGlide summary leaves
// both sections out rather than showing them as "skipped".
function sonarSection(ctx: Context): string {
  return `
  Sonar
    Agent Key: ${ctx.sonarAgentKey ?? "skipped"}
    Taking calls: ${takingCalls(ctx)}
`;
}

function pbxSection(ctx: Context): string {
  return `
  PBX (IAI softphone, MicroSIP)
    Extension: ${ctx.pbxAccountSheetPath ? (ctx.extension ?? ctx.sonarAgentKey) : "skipped"}
    Account sheet: ${ctx.pbxAccountSheetPath ?? "not generated"}${
      ctx.pbxPasswordMissing
        ? "\n    Password: MISSING - fill it in from 1Password before handing over the sheet"
        : ""
    }
`;
}

export function printSummary(ctx: Context): void {
  const iai = !isAmeriGlide();
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
${iai ? sonarSection(ctx) : ""}
  Twilio
    Worker SID: ${ctx.twilioWorkerSid ?? "skipped"}
    SIP Username: ${ctx.sipUsername ?? "skipped"}
    SIP Password: ${ctx.sipPassword ?? "already existed"}

  Direct Line
    Phone: ${ctx.phoneNumber ?? "none"}

  Zoiper
    Config: ${ctx.zoiperConfigPath ?? "not generated"}
    Activation: handled by setup-workstation.ps1 (ZOIPER_USERNAME/PASSWORD in .env)
${iai ? pbxSection(ctx) : ""}
${LINE}
  Next: set up the workstation (you'll be prompted), or use bin/copy for one-offs
${LINE}
`);
}
