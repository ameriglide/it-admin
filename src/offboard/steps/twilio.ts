import type { Step, OffboardContext } from "../types";
import {
  findWorkerByEmail,
  findCredentialByUsername,
  deleteWorker,
  deleteCredential,
} from "../../onboard/lib/twilio";
import { agentSidsToClear, findAgentSids, clearAgentSid } from "../lib/phenix-agent";

function sipUsernameFromEmail(email: string): string {
  return email.split("@")[0]!.toLowerCase();
}

export const twilioStep: Step = {
  name: "Twilio",

  async check(ctx: OffboardContext): Promise<boolean> {
    const worker = await findWorkerByEmail(ctx.email);
    const cred = await findCredentialByUsername(sipUsernameFromEmail(ctx.email));
    const stale = agentSidsToClear(ctx.email, await findAgentSids(ctx.email));
    console.log(`  Twilio worker: ${worker ? worker.sid : "absent"}`);
    console.log(`  SIP credential: ${cred ? cred.sid : "absent"}`);
    console.log(`  Phenix agent.sid: ${stale[0]?.sid ?? "null"}`);
    return worker === null && cred === null && stale.length === 0;
  },

  async run(ctx: OffboardContext): Promise<void> {
    const worker = await findWorkerByEmail(ctx.email);
    const cred = await findCredentialByUsername(sipUsernameFromEmail(ctx.email));
    const stale = agentSidsToClear(ctx.email, await findAgentSids(ctx.email));

    if (worker) {
      if (ctx.dryRun) {
        console.log(`  [dry-run] would delete worker ${worker.sid}`);
      } else {
        await deleteWorker(worker.sid);
        ctx.twilioWorkerSid = worker.sid;
      }
    } else {
      console.log("  Twilio worker: already absent");
    }

    // Reached only once the worker is deleted or already gone: a failed delete
    // throws above and leaves agent.sid pointing at the live worker.
    for (const row of stale) {
      if (ctx.dryRun) {
        console.log(`  [dry-run] would clear agent.sid ${row.sid} on Phenix agent ${row.id}`);
      } else {
        await clearAgentSid(row);
        ctx.clearedAgentSid = row.sid;
        console.log(`  cleared agent.sid ${row.sid} on Phenix agent ${row.id}`);
      }
    }

    if (cred) {
      if (ctx.dryRun) {
        console.log(`  [dry-run] would delete SIP credential ${cred.sid}`);
      } else {
        await deleteCredential(cred.sid);
        ctx.credentialSid = cred.sid;
      }
    } else {
      console.log("  SIP credential: already absent");
    }
  },
};
