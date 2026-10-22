import type { Step, OffboardContext } from "../types";
import {
  findWorkerByEmail,
  findCredentialByUsername,
  getWorker,
  workerMatchesEmail,
  deleteWorker,
  deleteCredential,
} from "../../onboard/lib/twilio";
import {
  type AgentSidRow,
  type AgentWorkerState,
  type WorkerTeardownPlan,
  planWorkerTeardown,
  sidToVerify,
  teardownDone,
  findAgentSids,
  clearAgentSid,
} from "../lib/phenix-agent";

function sipUsernameFromEmail(email: string): string {
  return email.split("@")[0]!.toLowerCase();
}

// Reads the worker, the Phenix agent rows and (when it differs from the email
// lookup) agent.sid's worker afresh, so every run plans from current state.
async function inspectWorker(
  email: string,
): Promise<{ workerSid: string | null; rows: AgentSidRow[]; plan: WorkerTeardownPlan }> {
  const worker = await findWorkerByEmail(email);
  const workerSid = worker?.sid ?? null;
  const rows = await findAgentSids(email);

  let agentWorker: AgentWorkerState | null = null;
  const verify = sidToVerify(workerSid, rows);
  if (verify) {
    const w = await getWorker(verify);
    agentWorker = w === null ? "absent" : workerMatchesEmail(w, email) ? "ours" : "foreign";
  }

  return { workerSid, rows, plan: planWorkerTeardown(email, workerSid, rows, agentWorker) };
}

export const twilioStep: Step = {
  name: "Twilio",

  async check(ctx: OffboardContext): Promise<boolean> {
    const cred = await findCredentialByUsername(sipUsernameFromEmail(ctx.email));
    console.log(`  SIP credential: ${cred ? cred.sid : "absent"}`);

    let inspected;
    try {
      inspected = await inspectWorker(ctx.email);
    } catch (err) {
      // Not done: run() revokes the credential before hitting the same error.
      console.log(`  Twilio worker / Phenix agent.sid: could not check (${err})`);
      return false;
    }
    const { workerSid, rows, plan } = inspected;
    console.log(`  Twilio worker: ${workerSid ?? "absent"}`);
    if (rows.length === 0) {
      console.log(`  Phenix agent.sid: no agent row for ${ctx.email}`);
    } else {
      console.log(`  Phenix agent.sid: ${rows.map((r) => `agent ${r.id}=${r.sid || "null"}`).join(", ")}`);
    }
    if (plan.problem) console.log(`  ⚠ ${plan.problem}`);
    return teardownDone(plan, cred !== null);
  },

  async run(ctx: OffboardContext): Promise<void> {
    // The credential depends on neither the worker nor the Phenix DB, so revoke
    // it before reading either: nothing below may leave a SIP login live.
    const cred = await findCredentialByUsername(sipUsernameFromEmail(ctx.email));
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

    const { plan } = await inspectWorker(ctx.email);

    if (plan.deleteSids.length === 0) console.log("  Twilio worker: already absent");
    const deleted: string[] = [];
    for (const sid of plan.deleteSids) {
      if (ctx.dryRun) {
        console.log(`  [dry-run] would delete worker ${sid}`);
      } else {
        await deleteWorker(sid);
        deleted.push(sid);
      }
    }
    if (deleted.length) ctx.twilioWorkerSid = deleted.join(", ");
    if (plan.alreadyGone) {
      console.log(`  agent.sid ${plan.alreadyGone}: TaskRouter reports no such worker (already gone)`);
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

    // Reported, not thrown, so the remaining steps (Amberjack, Google) still
    // run; run.ts prints it as manual action and exits non-zero.
    if (plan.problem) {
      console.warn(`  ⚠ ${plan.problem}`);
      ctx.agentSidProblem = plan.problem;
    }
  },
};
