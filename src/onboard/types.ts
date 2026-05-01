export interface Context {
  firstName: string;
  lastName: string;
  email: string;
  directLine: boolean | undefined; // true=yes, false=no, undefined=ask
  forceChange?: boolean; // Force Google password change on next sign-in. Default: true.

  // Phenix preselect (skip prompt when set):
  phenixChannel?: string; // channel name, e.g. "Phone"

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
}

export interface Step {
  name: string;
  check(ctx: Context): Promise<boolean>; // true = already done
  run(ctx: Context): Promise<void>;
}
