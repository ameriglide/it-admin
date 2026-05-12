import { homedir } from "node:os";
import { join } from "node:path";
import { mkdir } from "node:fs/promises";

export function archiveRoot(): string {
  return process.env.AG_ARCHIVE_ROOT ?? join(homedir(), "ag-admin-archives");
}

export function backupPath(email: string): string {
  return join(archiveRoot(), email);
}

export async function verifyGybInstalled(): Promise<void> {
  const proc = Bun.spawn(["gyb", "--version"], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const code = await proc.exited;
  if (code !== 0) {
    throw new Error(
      "gyb not found on PATH. Install from https://github.com/GAM-team/got-your-back/wiki",
    );
  }
}

async function spawnGyb(args: string[]): Promise<void> {
  const proc = Bun.spawn(["gyb", ...args], {
    stdout: "inherit",
    stderr: "inherit",
  });
  const code = await proc.exited;
  if (code !== 0) {
    throw new Error(`gyb ${args.join(" ")} exited with code ${code}`);
  }
}

export async function backupMailbox(email: string): Promise<string> {
  const dest = backupPath(email);
  await mkdir(dest, { recursive: true });
  await spawnGyb([
    "--service-account",
    "--email",
    email,
    "--action",
    "backup",
    "--local-folder",
    dest,
  ]);
  return dest;
}

export async function restoreToGroup(
  groupEmail: string,
  localFolder: string,
): Promise<void> {
  const adminEmail = process.env.GOOGLE_ADMIN_EMAIL;
  if (!adminEmail) throw new Error("GOOGLE_ADMIN_EMAIL not set");
  await spawnGyb([
    "--service-account",
    "--use-admin",
    adminEmail,
    "--email",
    groupEmail,
    "--action",
    "restore-group",
    "--local-folder",
    localFolder,
  ]);
}
