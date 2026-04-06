import type { Step, Context } from "../types";
import { getAmberjack } from "../lib/db";

const ACCESS_ASSETS = [2, 3, 4, 5, 6, 21];

export const amberjackStep: Step = {
  name: "Amberjack",

  async check(ctx: Context): Promise<boolean> {
    const sql = getAmberjack();
    const [row] = await sql`SELECT id FROM employee WHERE email = ${ctx.email}`;
    if (row) {
      ctx.amberjackEmployeeId = row.id;
      return true;
    }
    return false;
  },

  async run(ctx: Context): Promise<void> {
    const sql = getAmberjack();
    const name = `${ctx.firstName.toLowerCase()}.${ctx.lastName.toLowerCase()}`;

    await sql.begin(async (tx) => {
      const [emp] = await tx`
        INSERT INTO employee (name, firstname, lastname, email, phone, locked, admin, sudoer, jumpcloudorg)
        VALUES (${name}, ${ctx.firstName}, ${ctx.lastName}, ${ctx.email}, ${name}, false, false, false, 1)
        RETURNING id
      `;

      for (const asset of ACCESS_ASSETS) {
        await tx`
          INSERT INTO access (employee, asset, role, role_policy)
          VALUES (${emp.id}, ${asset}, 2, 2)
        `;
      }

      ctx.amberjackEmployeeId = emp.id;
    });
  },
};
