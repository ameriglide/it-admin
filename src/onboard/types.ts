export interface Context {
  firstName: string;
  lastName: string;
  email: string;
  directLine: boolean | undefined; // true=yes, false=no, undefined=ask
  forceChange?: boolean; // Force Google password change on next sign-in. Default: true.

  // Phenix preselect (skip prompt when set):
  phenixChannel?: string; // channel name, e.g. "Phone"

  // Role preselect for the Google Groups step (skip prompt when set):
  role?: string; // configured role name, e.g. "Sales Rep"

  // Sonar/PBX preselect (skip prompt when set). One 4-digit number serves as
  // both the Sonar agent key and the PBX extension — they are the same number,
  // not two ids that happen to match. See docs/runbooks/iai-onboarding.md.
  extension?: string; // e.g. "7415"

  // Sonar call center preselect (skip prompt when set):
  sonarCallCenter?: string; // call center name as stored in cg2.callcenter

  // Sonar agent.sales. Defaults to true -- IAI agents are sales agents
  // (Michael, 2026-11-02). Pass --no-sales for a non-selling account.
  sales?: boolean;

  // Populated by steps:
  googlePassword?: string | null; // null = already existed
  amberjackEmployeeId?: number;
  phenixAgentId?: number;
  twilioWorkerSid?: string;
  sipUsername?: string;
  sipPassword?: string | null; // null = already existed
  credentialSid?: string;
  phoneNumber?: string;
  zoiperConfigPath?: string;
  groupsJoined?: string[]; // Google Group addresses the user was added to
  sonarAgentKey?: string; // cg2.agent.key — the 4-digit extension
  pbxAccountSheetPath?: string; // softphone settings written for the operator
  pbxExtensionEnabled?: boolean; // false = endpoint still disabled on the PBX
}

export interface Step {
  name: string;
  check(ctx: Context): Promise<boolean>; // true = already done
  run(ctx: Context): Promise<void>;
}
