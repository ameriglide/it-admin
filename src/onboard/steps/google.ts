import type { Step, Context } from "../types";
import { getDirectoryClient } from "../lib/google";
import { generateTempPassword } from "../lib/password";

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
        orgUnitPath: "/Exempt from MFA",
      },
    });

    ctx.googlePassword = password;
  },
};
