// The Workspace tenant this run onboards into, told apart by DOMAIN (default
// ameriglide.com). Normalized so an empty, padded, or differently cased
// DOMAIN in .env cannot silently select the wrong tenant's steps.
//
// Lives in its own module because auto-skips imports steps/org-directory, which
// also needs this; putting it in auto-skips would make an import cycle.

type Env = Record<string, string | undefined>;

export const AMERIGLIDE_DOMAIN = "ameriglide.com";

export function tenantDomain(env: Env = process.env): string {
  return (env.DOMAIN || AMERIGLIDE_DOMAIN).trim().toLowerCase() || AMERIGLIDE_DOMAIN;
}

export function isAmeriGlide(env: Env = process.env): boolean {
  return tenantDomain(env) === AMERIGLIDE_DOMAIN;
}
