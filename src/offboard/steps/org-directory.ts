import type { Step, OffboardContext } from "../types";
import { orgDirectoryMemoryIds, deleteMemory } from "../lib/mem0";

// Deletes the departing user's org-directory mem0 mirror entry so the directory
// drops them immediately. The next seed reseed is the backstop, but this makes it
// prompt. Failure is fatal (propagates to run.ts) like every other offboard step.
export const orgDirectoryStep: Step = {
  name: "Org directory",

  async check(ctx: OffboardContext): Promise<boolean> {
    const ids = await orgDirectoryMemoryIds(ctx.email);
    return ids.length === 0; // already absent -> done
  },

  async run(ctx: OffboardContext): Promise<void> {
    const ids = await orgDirectoryMemoryIds(ctx.email);
    if (ids.length === 0) {
      console.log(`  no org-directory mirror entry for ${ctx.email}`);
      return;
    }
    if (ctx.dryRun) {
      const noun = ids.length === 1 ? "entry" : "entries";
      console.log(`  [dry-run] would remove ${ids.length} org-directory mirror ${noun} for ${ctx.email}`);
      return;
    }
    for (const id of ids) await deleteMemory(id);
    console.log(`  removed org-directory mirror entry for ${ctx.email}`);
  },
};
