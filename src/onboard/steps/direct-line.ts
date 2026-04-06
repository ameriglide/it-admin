import type { Step, Context } from "../types";
import { getPhenix } from "../lib/db";
import { input, choose, confirm } from "../lib/prompt";
import { searchLocalNumbers, buyNumber } from "../lib/twilio";

export const directLineStep: Step = {
  name: "Direct Line",

  async check(ctx: Context): Promise<boolean> {
    if (ctx.directLine === false) return true;

    const sql = getPhenix();
    const [row] = await sql`
      SELECT phone_number FROM verified_caller_id WHERE direct = ${ctx.phenixAgentId}
    `;
    if (row) {
      ctx.phoneNumber = row.phone_number;
      return true;
    }
    return false;
  },

  async run(ctx: Context): Promise<void> {
    if (ctx.directLine === undefined) {
      const yes = await confirm("Buy a direct line for this agent?");
      if (!yes) {
        ctx.directLine = false;
        return;
      }
    }

    const locality = await input("City or area code");

    const isAreaCode = /^\d{3}$/.test(locality);
    const numbers = await searchLocalNumbers(
      isAreaCode ? locality : undefined,
      isAreaCode ? undefined : locality,
    );

    if (numbers.length === 0) {
      console.error(`  No numbers found for "${locality}". Skipping direct line.`);
      return;
    }

    const labels = numbers.map(
      (n) => `${n.friendlyName}  (${n.locality}, ${n.region})`,
    );
    console.log("\nSelect a phone number:");
    const selected = await choose(labels);
    const idx = labels.indexOf(selected);
    const number = numbers[idx];

    const numberSid = await buyNumber(number.phoneNumber);

    const sql = getPhenix();
    await sql`
      INSERT INTO verified_caller_id (sid, phone_number, friendly_name, direct, default_outbound)
      VALUES (${numberSid}, ${number.phoneNumber}, ${number.friendlyName}, ${ctx.phenixAgentId}, false)
    `;

    ctx.phoneNumber = number.phoneNumber;
  },
};
