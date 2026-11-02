import type { Step, Context } from "../types";
import { getSonar } from "../lib/db";
import { choose, input } from "../lib/prompt";
import { assertValidExtension } from "../lib/extension";

// Sonar is the IAI CRM. Its agent record is the counterpart to Phenix's, with
// one structural difference that drives this whole step: the primary key is
// `key varchar(4)` -- the agent's four-digit extension -- not a serial id.
// There is no password column; Sonar authenticates through Google OAuth, so
// the Google step is what actually grants access.

export const sonarStep: Step = {
  name: "Sonar",

  async check(ctx: Context): Promise<boolean> {
    const sql = getSonar();
    const [row] = await sql`SELECT key FROM agent WHERE email = ${ctx.email}`;
    if (row) {
      ctx.sonarAgentKey = row.key;
      ctx.extension ??= row.key;
      return true;
    }
    return false;
  },

  async run(ctx: Context): Promise<void> {
    const sql = getSonar();

    const ext = ctx.extension ?? (await input("Sonar extension (4 digits)"));
    assertValidExtension(ext);

    const [taken] = await sql`
      SELECT key, firstname, lastname FROM agent WHERE key = ${ext}
    `;
    if (taken) {
      throw new Error(
        `Extension ${ext} already belongs to ${taken.firstname} ${taken.lastname}. ` +
          `Pick a free one -- agent.key is the primary key, so this would collide.`,
      );
    }

    const callCenters = await sql`SELECT id, name FROM callcenter ORDER BY "position", name`;
    if (!callCenters.length) {
      throw new Error("No call centers found in Sonar; cannot place the agent.");
    }

    let callCenter: { id: number; name: string };
    if (ctx.sonarCallCenter) {
      const found = callCenters.find((c) => c.name === ctx.sonarCallCenter);
      if (!found) {
        throw new Error(
          `Unknown call center "${ctx.sonarCallCenter}". ` +
            `Options: ${callCenters.map((c) => c.name).join(", ")}`,
        );
      }
      callCenter = found;
      console.log(`  Call center: ${callCenter.name}`);
    } else {
      console.log("\nSelect call center:");
      const name = await choose(callCenters.map((c) => c.name));
      callCenter = callCenters.find((c) => c.name === name)!;
    }

    // paused=true on purpose: a brand-new agent should not be handed live
    // calls before their softphone registers. Sonar's "Start taking calls"
    // button is what clears it, and that click is also what adds them to the
    // Asterisk queue (see the 2026-10-21 queue-membership runbook).
    await sql`
      INSERT INTO agent (
        key, firstname, lastname, email,
        callcenter, sales, locked, paused, forwarded, penalizedforwarding
      ) VALUES (
        ${ext}, ${ctx.firstName}, ${ctx.lastName}, ${ctx.email},
        ${callCenter.id}, false, false, true, false, false
      )
    `;

    ctx.sonarAgentKey = ext;
    ctx.extension = ext;

    console.log(
      `  Created Sonar agent ${ext} (${ctx.firstName} ${ctx.lastName}) in ${callCenter.name}, paused.`,
    );
    console.log(
      `  Skills: add them in Sonar (skilledagent) once the phone is registered.`,
    );
  },
};
