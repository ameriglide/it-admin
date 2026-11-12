import { mirrorsOrgDirectory } from "../steps/org-directory";

// The key a step is matched by in the --skip list: its name lowercased with
// whitespace stripped ("Google Groups" -> "googlegroups").
export function stepKey(name: string): string {
  return name.toLowerCase().replace(/\s+/g, "");
}

// Decides which steps run() skips on its own, on top of the user's --skip.
//
// One codebase serves two tenants, told apart by DOMAIN (default
// ameriglide.com, as in bin/onboard):
//   - ameriglide.com uses Amberjack and Phenix, never Sonar or the PBX. Those
//     two are always skipped. Amberjack/Phenix are never auto-skipped here: a
//     missing DATABASE_URL must fail loudly in the step's getter, not turn
//     into a silent "skipped".
//   - any other tenant (e.g. inetalliance.net) uses Sonar and the PBX, which
//     are therefore never auto-skipped (missing env fails in the step), and
//     has no Amberjack/Phenix unless its env explicitly provides them.
// Twilio (and the Direct Line / Zoiper steps that consume its SIP
// credentials), Google Groups, and the org-directory mirror are optional for
// every tenant and are skipped when their configuration is absent.
//
// Pure: returns a new skip list (user entries first, no duplicates) and the
// console notes run() prints; userSkip is not modified.
export function planAutoSkips(
  env: Record<string, string | undefined>,
  userSkip: string[],
): { skip: string[]; notes: string[] } {
  const skip = [...new Set(userSkip)];
  const notes: string[] = [];
  const tenant = env.DOMAIN ?? "ameriglide.com";

  const add = (keys: string[], note: string) => {
    const added = keys.filter((k) => !skip.includes(k));
    if (!added.length) return;
    skip.push(...added);
    notes.push(note);
  };
  const addUnlessSet = (envVar: string, keys: string[], why: string) => {
    if (!env[envVar]) add(keys, `  (${envVar} unset - skipping ${why})`);
  };

  if (tenant === "ameriglide.com") {
    add(["sonar", "pbx"], "  (sonar, pbx: not used for ameriglide.com)");
  } else {
    addUnlessSet("AMBERJACK_DATABASE_URL", ["amberjack"], "Amberjack");
    addUnlessSet("PHENIX_DATABASE_URL", ["phenix"], "Phenix");
  }

  // Zoiper here is the Twilio-SIP softphone config, a different thing from
  // the PBX step (IAI's phone system).
  addUnlessSet(
    "TWILIO_ACCOUNT_SID",
    ["twilio", "directline", "zoiper"],
    "Twilio, Direct Line, Zoiper",
  );

  // No role->group config for this tenant: skip rather than prompt with an
  // empty list.
  addUnlessSet("ONBOARD_ROLES", ["googlegroups"], "Google Groups");

  // The org-directory mem0 mirror only covers ameriglide.com, and needs a key.
  if (!mirrorsOrgDirectory(env)) {
    add(
      ["orgdirectory"],
      "  (MEM0_API_KEY unset or tenant is not ameriglide.com - skipping Org directory)",
    );
  }

  return { skip, notes };
}
