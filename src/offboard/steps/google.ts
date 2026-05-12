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
  groupHasOwner,
} from "../lib/google";
import { verifyBackup } from "../lib/gyb";

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
    if (kind !== "group") return false;
    // Group exists, but a prior run may have crashed before configure /
    // owner / archive load completed. Use "has at least one OWNER" as a
    // proxy for "post-create steps ran." If no owner, fall back to
    // re-running so we can finish.
    const hasOwner = await groupHasOwner(ctx.email);
    if (hasOwner) {
      ctx.groupEmail = ctx.email;
      return true;
    }
    console.log(
      `  Group ${ctx.email} exists but has no owner — resuming post-create steps.`,
    );
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
      const verification = await backupMailbox(ctx.email);
      ctx.gybBackupPath = verification.folder;
      console.log(
        `  Backup verified at ${verification.folder} (${verification.emlCount} .eml files)`,
      );
      if (verification.emlCount === 0) {
        throw new Error(
          `gyb backup of ${ctx.email} produced 0 .eml files. ` +
            `Refusing to proceed with destructive Drive transfer + user delete. ` +
            `Investigate manually before re-running.`,
        );
      }

      console.log(`  Transferring Drive ownership to ${manager.email}...`);
      const transferId = await transferDriveOwnership(ctx.email, manager.email);
      console.log(`    transfer id: ${transferId} (runs in background)`);

      console.log(`  Deleting Workspace user ${ctx.email}...`);
      await deleteUser(ctx.email);

      console.log(`  Waiting for delete to propagate...`);
      await waitForUserDeleted(ctx.email);
    } else if (kindNow === "absent" || kindNow === "group") {
      // User already gone (prior partial run, or in soft-delete trash —
      // either way, no live mailbox to back up). Use the prior on-disk
      // backup, verifying it has content before building/finishing the
      // archive group.
      const expected = backupPath(ctx.email);
      const verification = await verifyBackup(expected);
      ctx.gybBackupPath = verification.folder;
      console.log(
        `  Using prior backup at ${verification.folder} (${verification.emlCount} .eml files)`,
      );
      if (verification.emlCount === 0) {
        throw new Error(
          `prior backup at ${expected} has 0 .eml files. ` +
            `Cannot build an empty archive group.`,
        );
      }
    }

    if (kindNow === "group") {
      console.log(`  Archive group ${ctx.email} already exists — resuming.`);
    } else {
      console.log(`  Creating archive group ${ctx.email}...`);
      await createGroup(ctx.email, archivedGroupName(ctx.email));
    }

    console.log(`  Configuring group settings...`);
    await configureArchiveGroup(ctx.email);

    console.log(`  Adding ${manager.email} as group owner...`);
    await addGroupOwner(ctx.email, manager.email);

    if (!ctx.gybBackupPath) {
      throw new Error(
        `No backup path available — refusing to leave the archive group empty.`,
      );
    }
    console.log(`  Loading mail archive into group via gyb...`);
    await restoreToGroup(ctx.email, ctx.gybBackupPath);

    ctx.groupEmail = ctx.email;
  },
};
