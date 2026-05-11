import type { Step, Context } from "../types";
import { getPhenix } from "../lib/db";
import { encrypt } from "../lib/crypto";
import { generateSipPassword } from "../lib/password";
import {
  findWorkerByEmail,
  createWorker,
  findCredentialByUsername,
  createCredential,
} from "../lib/twilio";

export const twilioStep: Step = {
  name: "Twilio",

  async check(ctx: Context): Promise<boolean> {
    const worker = await findWorkerByEmail(ctx.email);
    if (worker) {
      ctx.twilioWorkerSid = worker.sid;
      ctx.sipUsername = `${ctx.firstName.toLowerCase()}.${ctx.lastName.toLowerCase()}`;
      ctx.sipPassword = null;
      return true;
    }
    return false;
  },

  async run(ctx: Context): Promise<void> {
    const sql = getPhenix();
    const sipUser = `${ctx.firstName.toLowerCase()}.${ctx.lastName.toLowerCase()}`;
    const sipPassword = generateSipPassword();

    // 1. Create or find SIP credential
    let credSid: string;
    const existing = await findCredentialByUsername(sipUser);
    if (existing) {
      console.log(`  SIP credential for ${sipUser} already exists, reusing`);
      credSid = existing.sid;
    } else {
      credSid = await createCredential(sipUser, sipPassword);
    }

    // 2. Encrypt and store SIP secret in Phenix
    const aesKeyB64 = process.env.AES_KEY;
    if (!aesKeyB64) throw new Error("AES_KEY not set");
    const aesKey = Buffer.from(aesKeyB64, "base64");
    const encryptedSecret = encrypt(sipPassword, aesKey);
    // Phenix stores encrypted bytes as uppercase hex in a text column
    const secretHex = encryptedSecret.toString("hex").toUpperCase();

    const pstnDomain =
      process.env.TWILIO_PSTN_DOMAIN ?? "ameriglide.pstn.twilio.com";
    const sipUri = `sip:${sipUser}@${pstnDomain}`;

    await sql`
      UPDATE agent
      SET sipsecret = ${secretHex},
          sipuri = ${sipUri},
          credentialsid = ${credSid},
          callroutingmode = 'SIP'
      WHERE id = ${ctx.phenixAgentId}
    `;

    // 3. Build worker attributes from agent's productskills and channels
    // Uses abbreviations, matching Phenix's Agent.getWorkerAttributes() format:
    // { "roles": ["SALES"], "SALES": { "primary": ["SL", "EL"], "backup": [] }, "channels": ["PHONE"] }
    const productSkills = await sql`
      SELECT ps.skill, ps.backup, pl.abbreviation AS product_abbr
      FROM productskill ps
      JOIN productline pl ON pl.id = ps.product
      WHERE ps.agent = ${ctx.phenixAgentId}
    `;
    const channels = await sql`
      SELECT c.abbreviation FROM agentchannel ac JOIN channel c ON c.id = ac.channel WHERE ac.agent = ${ctx.phenixAgentId}
    `;

    // Group products by skill, split into primary/backup
    const skillMap = new Map<string, { primary: string[]; backup: string[] }>();
    for (const ps of productSkills) {
      if (!skillMap.has(ps.skill)) skillMap.set(ps.skill, { primary: [], backup: [] });
      const entry = skillMap.get(ps.skill)!;
      if (ps.backup) entry.backup.push(ps.product_abbr);
      else entry.primary.push(ps.product_abbr);
    }

    const attributes: Record<string, any> = {
      email: ctx.email,
      roles: [...skillMap.keys()],
      channels: channels.map((c) => c.abbreviation),
    };
    for (const [skill, products] of skillMap) {
      attributes[skill] = products;
    }

    // 4. Create TaskRouter worker
    const workerSid = await createWorker(
      `${ctx.firstName} ${ctx.lastName}`,
      attributes,
    );

    // 5. Store worker SID in Phenix
    await sql`UPDATE agent SET sid = ${workerSid} WHERE id = ${ctx.phenixAgentId}`;

    ctx.sipUsername = sipUser;
    ctx.sipPassword = sipPassword;
    ctx.credentialSid = credSid;
    ctx.twilioWorkerSid = workerSid;
  },
};
