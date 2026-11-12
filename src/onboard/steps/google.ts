import type { Step, Context } from "../types";
import { getDirectoryClient } from "../lib/google";
import { generateTempPassword } from "../lib/password";
import { isAmeriGlide, tenantDomain } from "../lib/tenant";

// Org units are per-tenant, and users.insert fails outright against an OU
// that does not exist. AmeriGlide's default is "/Exempt from MFA"; any other
// tenant must name its OU in ONBOARD_ORG_UNIT_PATH rather than silently
// inherit AmeriGlide's MFA exemption.
export function orgUnitPath(
  env: Record<string, string | undefined> = process.env,
): string {
  const configured = env.ONBOARD_ORG_UNIT_PATH?.trim();
  if (configured) return configured;
  if (isAmeriGlide(env)) return "/Exempt from MFA";
  throw new Error(`ONBOARD_ORG_UNIT_PATH must be set for tenant ${tenantDomain(env)}`);
}

export const googleStep: Step = {
  name: "Google Workspace",

  async check(ctx: Context): Promise<boolean> {
    const admin = await getDirectoryClient();
    try {
      await admin.users.get({ userKey: ctx.email });
      ctx.googlePassword = null;
      return true;
    } catch (e: any) {
      if (e.code === 404) return false;
      throw e;
    }
  },

  async run(ctx: Context): Promise<void> {
    const admin = await getDirectoryClient();
    const password = generateTempPassword();

    await admin.users.insert({
      requestBody: {
        primaryEmail: ctx.email,
        name: { givenName: ctx.firstName, familyName: ctx.lastName },
        password,
        changePasswordAtNextLogin: true,
        orgUnitPath: orgUnitPath(),
      },
    });

    ctx.googlePassword = password;
  },
};
