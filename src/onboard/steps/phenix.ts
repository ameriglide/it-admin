import type { Step, Context } from "../types";
import { getPhenix } from "../lib/db";
import { choose, chooseMulti } from "../lib/prompt";

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

    // Query available options from DB
    // channel: id, name, abbreviation (e.g. 1, "Phone", "PHONE")
    const channels = await sql`SELECT id, name, abbreviation FROM channel ORDER BY name`;
    // skill: value, attribute (e.g. "SALES", null) — primary key is "value"
    const skills = await sql`SELECT value, attribute FROM skill ORDER BY value`;
    // productline: id, name, abbreviation (e.g. 1, "Stairlifts", "SL")
    const products = await sql`SELECT id, name, abbreviation FROM productline ORDER BY name`;

    // Interactive selection
    console.log("\nSelect channel:");
    const channelName = await choose(channels.map((c) => c.name));
    const channel = channels.find((c) => c.name === channelName)!;

    console.log("\nSelect skill/role:");
    const skillValue = await choose(skills.map((s) => s.value));

    console.log("\nSelect products (space to toggle, enter to confirm):");
    const productItems = ["all", ...products.map((p) => p.name)];
    const selectedNames = await chooseMulti(productItems);

    let selectedProducts = products;
    if (!selectedNames.includes("all")) {
      selectedProducts = products.filter((p) => selectedNames.includes(p.name));
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

      // Add product skills (productskill table, composite PK: agent + product)
      // One row per product for the selected skill, backup=false
      for (const product of selectedProducts) {
        await tx`
          INSERT INTO productskill (agent, product, skill, backup)
          VALUES (${agent.id}, ${product.id}, ${skillValue}, false)
        `;
      }

      // Add to team 8
      await tx`
        INSERT INTO teammember (team, agent)
        VALUES (8, ${agent.id})
      `;

      ctx.phenixAgentId = agent.id;
    });
  },
};
