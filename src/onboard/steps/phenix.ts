import type { Step, Context } from "../types";
import { getPhenix } from "../lib/db";
import { choose } from "../lib/prompt";

export const phenixStep: Step = {
  name: "Phenix",

  async check(ctx: Context): Promise<boolean> {
    const sql = getPhenix();
    const [row] = await sql`SELECT id FROM agent WHERE email = ${ctx.email}`;
    if (row) {
      ctx.phenixAgentId = row.id;
      return true;
    }
    return false;
  },

  async run(ctx: Context): Promise<void> {
    const sql = getPhenix();

    // channel: id, name, abbreviation (e.g. 1, "Phone", "PHONE")
    const channels = await sql`SELECT id, name, abbreviation FROM channel ORDER BY name`;

    // Channel: --channel flag, else prompt
    let channel: { id: number; name: string };
    if (ctx.phenixChannel) {
      const found = channels.find((c) => c.name === ctx.phenixChannel);
      if (!found) {
        throw new Error(
          `Unknown channel "${ctx.phenixChannel}". Options: ${channels.map((c) => c.name).join(", ")}`,
        );
      }
      channel = found;
      console.log(`  Channel: ${channel.name}`);
    } else {
      console.log("\nSelect channel:");
      const channelName = await choose(channels.map((c) => c.name));
      channel = channels.find((c) => c.name === channelName)!;
    }

    await sql.begin(async (tx) => {
      const [agent] = await tx`
        INSERT INTO agent (firstname, lastname, email, active)
        VALUES (${ctx.firstName}, ${ctx.lastName}, ${ctx.email}, true)
        RETURNING id
      `;

      // Add channel (agentchannel table, composite PK: agent + channel)
      await tx`
        INSERT INTO agentchannel (agent, channel)
        VALUES (${agent.id}, ${channel.id})
      `;

      // Add to team 8
      await tx`
        INSERT INTO teammember (team, agent)
        VALUES (8, ${agent.id})
      `;

      ctx.phenixAgentId = agent.id;
    });
  },
};
