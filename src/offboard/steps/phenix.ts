import type { Step, OffboardContext } from "../types";
import { getAgent, setAgentInactive } from "../lib/remix";

export const phenixStep: Step = {
  name: "Phenix",

  async check(ctx: OffboardContext): Promise<boolean> {
    const agent = await getAgent(ctx.email);
    if (!agent) return true; // never in Phenix => nothing to do
    return agent.active === false;
  },

  async run(ctx: OffboardContext): Promise<void> {
    if (ctx.dryRun) {
      console.log(`  [dry-run] would call setAgentInactive(${ctx.email})`);
      return;
    }
    const result = await setAgentInactive(ctx.email);
    if (result.active !== false) {
      throw new Error(
        `setAgentInactive returned active=${result.active} for ${ctx.email}`,
      );
    }
  },
};
