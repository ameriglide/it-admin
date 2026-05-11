import type { Step, OffboardContext } from "../types";
import { getAmberjack } from "../../onboard/lib/db";

export const amberjackStep: Step = {
  name: "Amberjack",

  async check(ctx: OffboardContext): Promise<boolean> {
    const sql = getAmberjack();
    const [row] = await sql`
      SELECT id, locked FROM employee WHERE email = ${ctx.email}
    `;
    if (!row) return true; // not present => nothing to lock
    ctx.amberjackEmployeeId = row.id;
    return row.locked === true;
  },

  async run(ctx: OffboardContext): Promise<void> {
    if (ctx.dryRun) {
      console.log(
        `  [dry-run] would UPDATE employee SET locked = true WHERE email = ${ctx.email}`,
      );
      return;
    }
    const sql = getAmberjack();
    await sql`
      UPDATE employee SET locked = true WHERE email = ${ctx.email}
    `;
  },
};
