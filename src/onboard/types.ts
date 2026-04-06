export interface Context {
  firstName: string;
  lastName: string;
  email: string;
  directLine: boolean | undefined; // true=yes, false=no, undefined=ask

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
