import type { Step, OffboardContext } from "../types";
import {
  findWorkerByEmail,
  findCredentialByUsername,
  deleteWorker,
  deleteCredential,
} from "../../onboard/lib/twilio";
import { planWorkerTeardown, findAgentSids, clearAgentSid } from "../lib/phenix-agent";

function sipUsernameFromEmail(email: string): string {
  return email.split("@")[0]!.toLowerCase();
}

export const twilioStep: Step = {
  name: "Twilio",

  async check(ctx: OffboardContext): Promise<boolean> {
    const worker = await findWorkerByEmail(ctx.email);
    const cred = await findCredentialByUsername(sipUsernameFromEmail(ctx.email));
    const rows = await findAgentSids(ctx.email);
    const plan = planWorkerTeardown(ctx.email, worker?.sid ?? null, rows);
    console.log(`  Twilio worker: ${worker ? worker.sid : "absent"}`);
    console.log(`  SIP credential: ${cred ? cred.sid : "absent"}`);
    if (rows.length === 0) {
      console.log(`  Phenix agent.sid: no agent row for ${ctx.email}`);
    } else {
      console.log(`  Phenix agent.sid: ${rows.map((r) => `${r.id}=${r.sid || "null"}`).join(", ")}`);
    }
    if (plan.problem) console.log(`  ⚠ ${plan.problem}`);
    // A problem keeps the step not-done so every run re-surfaces it in the summary.
    return cred === null && plan.deleteSids.length === 0 && plan.clear === null && plan.problem === null;
  },

  async run(ctx: OffboardContext): Promise<void> {
    const worker = await findWorkerByEmail(ctx.email);
    const cred = await findCredentialByUsername(sipUsernameFromEmail(ctx.email));
    const rows = await findAgentSids(ctx.email);
    const plan = planWorkerTeardown(ctx.email, worker?.sid ?? null, rows);

    // The credential does not depend on the worker or agent.sid, so revoke it
    // first: an ambiguous agent row must not leave a departing user's SIP login live.
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

    if (plan.deleteSids.length === 0) console.log("  Twilio worker: already absent");
    for (const sid of plan.deleteSids) {
      if (ctx.dryRun) {
        console.log(`  [dry-run] would delete worker ${sid}`);
      } else {
        await deleteWorker(sid);
        ctx.twilioWorkerSid = sid;
      }
    }

    // After the deletes on purpose: if deleteWorker throws, agent.sid keeps
    // pointing at the still-live worker and a re-run picks it up again.
    if (plan.clear) {
      if (ctx.dryRun) {
        console.log(`  [dry-run] would clear agent.sid ${plan.clear.sid} on Phenix agent ${plan.clear.id}`);
      } else {
        await clearAgentSid(plan.clear);
        ctx.clearedAgentSid = plan.clear.sid;
        console.log(`  cleared agent.sid ${plan.clear.sid} on Phenix agent ${plan.clear.id}`);
      }
    }

    // Reported, not thrown, so the remaining steps (Amberjack, Google) still run.
    if (plan.problem) {
      console.warn(`  ⚠ ${plan.problem}`);
      ctx.agentSidProblem = plan.problem;
    }
  },
};
