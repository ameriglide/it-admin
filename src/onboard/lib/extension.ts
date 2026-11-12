// Sonar's agent key and the PBX extension are the same 4-digit number: the
// `agent` table (database `cg2`) is keyed on `key varchar(4)`, and
// Agent.getCallerId() hands that key straight to Asterisk as the caller id. So
// an onboarding run has to settle on one number and use it in both places.

export const EXTENSION_RE = /^\d{4}$/;

export function assertValidExtension(ext: string): void {
  if (!EXTENSION_RE.test(ext)) {
    throw new Error(
      `Extension "${ext}" is not four digits. Sonar stores it in agent.key, ` +
        `which is varchar(4), and the PBX endpoint is named after it.`,
    );
  }
}

// Extensions currently enabled on the PBX. Every other migrated extension sits
// on the disabled endpoint template and cannot register. Set
// PBX_ENABLED_EXTENSIONS in .env as this drifts; leave it unset to skip the
// check rather than block on a stale list. A value that lists nothing (" ",
// ",") also returns null here; preflight() reports that as a problem (see
// enabledExtensionsBlank) so a typo cannot silently disable the check.
export function enabledExtensions(
  env: Record<string, string | undefined> = process.env,
): string[] | null {
  const raw = env.PBX_ENABLED_EXTENSIONS;
  if (!raw) return null;
  const list = raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  return list.length ? list : null;
}

export function isPbxEnabled(
  ext: string,
  env: Record<string, string | undefined> = process.env,
): boolean | null {
  const list = enabledExtensions(env);
  if (!list) return null; // unknown, not "no"
  return list.includes(ext);
}

// True when PBX_ENABLED_EXTENSIONS is set to something that parses to no
// extensions, which enabledExtensions() treats the same as unset.
export function enabledExtensionsBlank(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return !!env.PBX_ENABLED_EXTENSIONS && enabledExtensions(env) === null;
}
