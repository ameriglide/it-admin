export interface OffboardContext {
  email: string;
  managerEmail?: string;
  dryRun: boolean;

  amberjackEmployeeId?: number;
  twilioWorkerSid?: string | null;
  credentialSid?: string | null;
  gybBackupPath?: string;
  groupEmail?: string;
}

export interface Step {
  name: string;
  check(ctx: OffboardContext): Promise<boolean>;
  run(ctx: OffboardContext): Promise<void>;
}
