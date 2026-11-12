import type { Step, Context } from "../types";
import { getDirectoryClient } from "../lib/google";
import { isAmeriGlide } from "../lib/tenant";
import {
  orgDirectoryMemoryIds,
  personFromDirectoryUser,
  addOrgPerson,
} from "../../offboard/lib/mem0";

const RESEED_HINT =
  "re-run bin/onboard, or run scripts/seed-org.mjs in ameriglide-claude-config";

// The mirror is AmeriGlide-only (seed-org refuses any other tenant), and a
// checkout without a mem0 key has nothing to write with.
export function mirrorsOrgDirectory(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return Boolean(env.MEM0_API_KEY) && isAmeriGlide(env);
}

// Adds the new hire to the org-directory mem0 mirror so /who resolves them
// straight away instead of after the next manual reseed (the counterpart of
// the offboard step that removes them).
//
// Unlike every other step, a failure here only warns. It is the last step and
// a convenience mirror, not provisioning: by the time it runs every account
// exists, so its failure should not turn the run into a failure (exit 1, no
// printSummary) - the operator would lose the full summary over a cache that
// the next reseed fixes anyway. (run() prints the temp password on failure
// too, so the password is not at stake.)
export const orgDirectoryStep: Step = {
  name: "Org directory",

  async check(ctx: Context): Promise<boolean> {
    try {
      return (await orgDirectoryMemoryIds(ctx.email)).length > 0;
    } catch {
      return false; // let run() retry and report
    }
  },

  async run(ctx: Context): Promise<void> {
    try {
      const admin = await getDirectoryClient();
      const { data } = await admin.users.get({ userKey: ctx.email, projection: "full" });
      const person = personFromDirectoryUser(data);

      let managerName: string | null = null;
      if (person.manager) {
        try {
          const manager = await admin.users.get({ userKey: person.manager });
          managerName = manager.data.name?.fullName ?? null;
        } catch {
          // unresolvable manager: the entry falls back to the bare email
        }
      }

      await addOrgPerson(person, managerName);
      console.log(`  added org-directory mirror entry for ${ctx.email}`);
    } catch (err) {
      console.warn(`  ! org-directory mirror not updated: ${err instanceof Error ? err.message : err}`);
      console.warn(`    (${RESEED_HINT})`);
    }
  },
};
