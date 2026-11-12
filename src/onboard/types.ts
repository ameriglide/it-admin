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
  sonarCallCenter?: string; // call center name as stored in the `callcenter` table (database cg2)

  // Sonar agent.sales. undefined means the default, which is true -- IAI
  // agents are sales agents (decided 2026-11-02). Pass --no-sales for a
  // non-selling account.
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
  // sonarAgentKey and sonarAgentCreated are always set together by the Sonar
  // step (check() for an existing agent, run() after the INSERT); neither set
  // means the step did not complete.
  sonarAgentKey?: string; // Sonar `agent.key` (database cg2) — the 4-digit extension
  sonarAgentCreated?: boolean; // true = this run inserted the Sonar agent; false = it already existed
  sonarAgentPaused?: boolean; // agent.paused as read or written by the Sonar step
  pbxAccountSheetPath?: string; // softphone settings written for the operator
  pbxPasswordMissing?: boolean; // true = the account sheet carries a placeholder password
}

export interface Step {
  name: string;
  // true = already done. check() may populate ctx as a side effect (e.g. the
  // Sonar step sets ctx.extension from an existing agent's key). The runner
  // always calls check() before run(), so run() may rely on what it set.
  check(ctx: Context): Promise<boolean>;
  run(ctx: Context): Promise<void>;
}
