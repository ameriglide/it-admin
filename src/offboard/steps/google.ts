import type { Step, OffboardContext } from "../types";
import { pickManager, resolveManager } from "../lib/manager";
import {
  verifyGybInstalled,
  backupMailbox,
  backupPath,
  restoreToGroup,
} from "../lib/gyb";
import {
  classifyAddress,
  transferDriveOwnership,
  deleteUser,
  waitForUserDeleted,
  createGroup,
  configureArchiveGroup,
  addGroupOwner,
} from "../lib/google";

function archivedGroupName(email: string): string {
  const local = email.split("@")[0]!;
  const parts = local.split(".");
  const titled = parts
    .map((p) => p.charAt(0).toUpperCase() + p.slice(1))
    .join(" ");
  return `${titled} (archived)`;
}

export const googleStep: Step = {
  name: "Google",

  async check(ctx: OffboardContext): Promise<boolean> {
    const kind = await classifyAddress(ctx.email);
    if (kind === "group") {
      ctx.groupEmail = ctx.email;
      return true;
    }
    return false;
  },

  async run(ctx: OffboardContext): Promise<void> {
    // Resolve manager (picker or --manager override).
    let manager;
    if (ctx.managerEmail) {
      manager = await resolveManager(ctx.managerEmail);
    } else {
      manager = await pickManager();
      ctx.managerEmail = manager.email;
    }
    console.log(
      `  Drive ownership will transfer to: ${manager.name} <${manager.email}>`,
    );

    if (ctx.dryRun) {
      console.log(`  [dry-run] would gyb backup ${ctx.email}`);
      console.log(`  [dry-run] would delete user ${ctx.email} (transferTo=${manager.email})`);
      console.log(`  [dry-run] would create archive group ${ctx.email}`);
      console.log(`  [dry-run] would configure group settings + add ${manager.email} as owner`);
      console.log(`  [dry-run] would gyb restore-group into ${ctx.email}`);
      return;
    }

    await verifyGybInstalled();

    const kindNow = await classifyAddress(ctx.email);

    if (kindNow === "user") {
      console.log(`  Backing up mailbox via gyb...`);
      ctx.gybBackupPath = await backupMailbox(ctx.email);

      console.log(`  Transferring Drive ownership to ${manager.email}...`);
      const transferId = await transferDriveOwnership(ctx.email, manager.email);
      console.log(`    transfer id: ${transferId} (runs in background)`);

      console.log(`  Deleting Workspace user ${ctx.email}...`);
      await deleteUser(ctx.email);

      console.log(`  Waiting for delete to propagate...`);
      await waitForUserDeleted(ctx.email);
    } else if (kindNow === "absent") {
      // User already gone (manual delete or partial prior run). Backup path
      // may already exist; restore from whatever's on disk.
      ctx.gybBackupPath = backupPath(ctx.email);
      console.log(
        `  User already absent; expecting prior backup at ${ctx.gybBackupPath}`,
      );
    }

    console.log(`  Creating archive group ${ctx.email}...`);
    await createGroup(ctx.email, archivedGroupName(ctx.email));

    console.log(`  Configuring group settings...`);
    await configureArchiveGroup(ctx.email);

    console.log(`  Adding ${manager.email} as group owner...`);
    await addGroupOwner(ctx.email, manager.email);

    if (ctx.gybBackupPath) {
      console.log(`  Loading mail archive into group via gyb...`);
      await restoreToGroup(ctx.email, ctx.gybBackupPath);
    } else {
      console.log(`  No backup path on disk; skipping archive load`);
    }

    ctx.groupEmail = ctx.email;
  },
};
