import type { Step, Context } from "../types";
import {
  parseRoles,
  resolveGroupAddress,
  addGroupMember,
  getDomain,
} from "../../lib/google-groups";
import { choose, chooseMulti } from "../lib/prompt";

const SKIP = "None (skip groups)";

export const googleGroupsStep: Step = {
  name: "Google Groups",

  // Membership is multi-valued with no clean "already done" signal; the step is
  // interactive and addGroupMember is idempotent, so always run when reached.
  async check(): Promise<boolean> {
    return false;
  },

  async run(ctx: Context): Promise<void> {
    const roles = parseRoles(process.env.ONBOARD_ROLES);
    const roleNames = Object.keys(roles);
    if (roleNames.length === 0) {
      console.log("  (ONBOARD_ROLES has no roles - nothing to do)");
      ctx.groupsJoined = [];
      return;
    }

    const domain = getDomain();
    let role = ctx.role;
    if (role && !roleNames.includes(role)) {
      console.log(`  --role "${role}" is not a configured role; ignoring.`);
      role = undefined;
    }
    if (!role) {
      role = await choose([...roleNames, SKIP]);
    }
    if (role === SKIP) {
      ctx.groupsJoined = [];
      return;
    }

    const addresses = roles[role].map((t) => resolveGroupAddress(t, domain));
    const selected = await chooseMulti(addresses, { selected: addresses });
    if (selected.length === 0) {
      ctx.groupsJoined = [];
      return;
    }

    const joined: string[] = [];
    for (const group of selected) {
      const result = await addGroupMember(group, ctx.email);
      console.log(`    ${result === "added" ? "+" : "="} ${group}`);
      joined.push(group);
    }
    ctx.groupsJoined = joined;
  },
};
