// Sonar's agent key and the PBX extension are the same 4-digit number: cg2's
// `agent` table is keyed on `key varchar(4)`, and Agent.getCallerId() hands
// that key straight to Asterisk as the caller id. So an onboarding run has to
// settle on one number and use it in both places.

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
// check rather than block on a stale list.
export function enabledExtensions(): string[] | null {
  const raw = process.env.PBX_ENABLED_EXTENSIONS;
  if (!raw) return null;
  const list = raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  return list.length ? list : null;
}

export function isPbxEnabled(ext: string): boolean | null {
  const list = enabledExtensions();
  if (!list) return null; // unknown, not "no"
  return list.includes(ext);
}
