import type { Step, OffboardContext } from "../types";
import { getAgent, setAgentInactive, refreshHud } from "../lib/remix";

export const phenixStep: Step = {
  name: "Phenix",

  async check(ctx: OffboardContext): Promise<boolean> {
    const agent = await getAgent(ctx.email);
    if (!agent) {
      console.log(
        `  Remix returned no agent for ${ctx.email}. ` +
          `If this user has a Phenix agent row, the agent(email) GraphQL ` +
          `query is wrong (field name, case sensitivity, or shape).`,
      );
      return true;
    }
    console.log(`  Phenix agent: email=${agent.email}, active=${agent.active}`);
    const alreadyInactive = agent.active === false;
    if (alreadyInactive) {
      // Even if the DB is already inactive, the HUD cache may be stale
      // from a prior change that didn't refresh it. Always force a
      // refresh so the dial button reflects reality.
      console.log(`  Refreshing HUD cache...`);
      await refreshHud();
    }
    return alreadyInactive;
  },

  async run(ctx: OffboardContext): Promise<void> {
    if (ctx.dryRun) {
      console.log(`  [dry-run] would call setAgentInactive(${ctx.email})`);
      console.log(`  [dry-run] would refresh HUD`);
      return;
    }
    const result = await setAgentInactive(ctx.email);
    if (result.active !== false) {
      throw new Error(
        `setAgentInactive returned active=${result.active} for ${ctx.email}`,
      );
    }
    console.log(`  Refreshing HUD cache...`);
    await refreshHud();
  },
};
