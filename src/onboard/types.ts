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
}

export interface Step {
  name: string;
  check(ctx: Context): Promise<boolean>; // true = already done
  run(ctx: Context): Promise<void>;
}
