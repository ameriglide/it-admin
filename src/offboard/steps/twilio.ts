import type { Step, OffboardContext } from "../types";
import {
  findWorkerByEmail,
  findCredentialByUsername,
  deleteWorker,
  deleteCredential,
} from "../../onboard/lib/twilio";

function sipUsernameFromEmail(email: string): string {
  return email.split("@")[0]!.toLowerCase();
}

export const twilioStep: Step = {
  name: "Twilio",

  async check(ctx: OffboardContext): Promise<boolean> {
    const worker = await findWorkerByEmail(ctx.email);
    const cred = await findCredentialByUsername(sipUsernameFromEmail(ctx.email));
    console.log(`  Twilio worker: ${worker ? worker.sid : "absent"}`);
    console.log(`  SIP credential: ${cred ? cred.sid : "absent"}`);
    return worker === null && cred === null;
  },

  async run(ctx: OffboardContext): Promise<void> {
    const worker = await findWorkerByEmail(ctx.email);
    const cred = await findCredentialByUsername(sipUsernameFromEmail(ctx.email));

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
