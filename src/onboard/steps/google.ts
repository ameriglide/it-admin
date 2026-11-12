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
    const ou = orgUnitPath();

    // Record the password before the insert, not after: if the request
    // reaches Google but the run is interrupted (Ctrl-C, timeout, network
    // drop) before the response arrives, the account may exist, and a re-run
    // only reports it as "already existed". Setting it first lets run() print
    // it on any failure path. A 4xx means Google rejected the request and no
    // account was created, so the password is cleared rather than printed as
    // if it were live; anything else (5xx, network error) leaves it, since
    // the account may or may not exist.
    ctx.googlePassword = password;
    try {
      await admin.users.insert({
        requestBody: {
          primaryEmail: ctx.email,
          name: { givenName: ctx.firstName, familyName: ctx.lastName },
          password,
          changePasswordAtNextLogin: true,
          orgUnitPath: ou,
        },
      });
    } catch (e) {
      if (isClientError(e)) ctx.googlePassword = undefined;
      throw e;
    }
  },
};

// True for a 4xx response from the Google API. googleapis sets `code` to the
// HTTP status (a string such as "ECONNRESET" for network errors);
// response.status is checked too in case `code` is absent.
export function isClientError(e: unknown): boolean {
  const err = e as { code?: unknown; response?: { status?: unknown } } | null;
  return [err?.code, err?.response?.status].some((c) => {
    const n = typeof c === "string" && c.trim() !== "" ? Number(c) : c;
    return typeof n === "number" && Number.isInteger(n) && n >= 400 && n <= 499;
  });
}
