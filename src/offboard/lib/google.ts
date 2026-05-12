import { google } from "googleapis";

const SCOPES = [
  "https://www.googleapis.com/auth/admin.directory.user",
  "https://www.googleapis.com/auth/admin.directory.group",
  "https://www.googleapis.com/auth/admin.directory.group.member",
  "https://www.googleapis.com/auth/apps.groups.settings",
  "https://www.googleapis.com/auth/admin.datatransfer",
];

function getAuth() {
  const keyPath = process.env.GOOGLE_SERVICE_ACCOUNT_KEY;
  const adminEmail = process.env.GOOGLE_ADMIN_EMAIL;
  if (!keyPath) throw new Error("GOOGLE_SERVICE_ACCOUNT_KEY not set");
  if (!adminEmail) throw new Error("GOOGLE_ADMIN_EMAIL not set");
  return new google.auth.GoogleAuth({
    keyFile: keyPath,
    scopes: SCOPES,
    clientOptions: { subject: adminEmail },
  });
}

export function getDirectory() {
  return google.admin({ version: "directory_v1", auth: getAuth() });
}

export function getGroupsSettings() {
  return google.groupssettings({ version: "v1", auth: getAuth() });
}

export function getDataTransfer() {
  return google.admin({ version: "datatransfer_v1", auth: getAuth() });
}

export type AddressKind = "user" | "group" | "absent";

function isNotFound(err: any): boolean {
  const status = err?.code ?? err?.response?.status;
  // Directory API sometimes returns 403 when a key exists as a different
  // resource type (e.g. groups.get on an address that's actually a user).
  // Treat 403 the same as 404 for classification purposes; real auth
  // errors will still surface elsewhere on the first attempted op.
  return status === 404 || status === 403;
}

function isSoftDeletedSignal(err: any): boolean {
  const status = err?.code ?? err?.response?.status;
  const msg = String(err?.message ?? "");
  // Google returns 400 "Type not supported: userKey" for users that are
  // in the 20-day soft-delete trash window — they can't be fetched by
  // userKey on the live endpoint, only via users.list with showDeleted.
  return status === 400 && /Type not supported: userKey/i.test(msg);
}

export interface DeletedUser {
  id: string;
  primaryEmail: string;
  deletionTime?: string | null;
}

export async function findDeletedUser(
  email: string,
  domain: string,
): Promise<DeletedUser | null> {
  const dir = getDirectory();
  let pageToken: string | undefined;
  do {
    const res = await dir.users.list({
      domain,
      showDeleted: "true",
      maxResults: 500,
      pageToken,
    });
    for (const u of res.data.users ?? []) {
      if ((u.primaryEmail ?? "").toLowerCase() === email.toLowerCase()) {
        return {
          id: u.id!,
          primaryEmail: u.primaryEmail!,
          deletionTime: u.deletionTime ?? null,
        };
      }
    }
    pageToken = res.data.nextPageToken ?? undefined;
  } while (pageToken);
  return null;
}

export async function classifyAddress(email: string): Promise<AddressKind> {
  const dir = getDirectory();
  let userLookupError: any = null;

  // Try users.get first — the common case during offboarding is that the
  // user still exists. This also dodges the groups.get-on-a-user 403 quirk.
  try {
    await dir.users.get({ userKey: email });
    return "user";
  } catch (err: any) {
    if (!isSoftDeletedSignal(err) && !isNotFound(err)) throw err;
    userLookupError = err;
  }

  // No active user. A group may exist at this address even if the user is
  // in soft-delete trash (Google treats group+trashed-user as co-existing
  // namespaces, so prior runs may have already created the archive group).
  try {
    await dir.groups.get({ groupKey: email });
    return "group";
  } catch (err: any) {
    if (!isNotFound(err)) throw err;
  }

  // No active user and no group. Whether the user is in soft-delete trash
  // or fully gone doesn't matter — the next-step flow is the same.
  void userLookupError;
  return "absent";
}

export async function hardDeleteUser(userId: string): Promise<void> {
  const dir = getDirectory();
  // For users in the soft-delete trash, calling users.delete with the
  // user's ID (not the email — that path returns 400) frees the address.
  await dir.users.delete({ userKey: userId });
}

async function getUserId(email: string): Promise<string> {
  const dir = getDirectory();
  const res = await dir.users.get({ userKey: email });
  const id = res.data.id;
  if (!id) throw new Error(`No id for user ${email}`);
  return id;
}

async function getDriveApplicationId(): Promise<string> {
  const dt = getDataTransfer();
  const res = await dt.applications.list();
  const apps = res.data.applications ?? [];
  const drive = apps.find((a) => a.name === "Drive and Docs");
  if (!drive?.id) {
    throw new Error(
      `Could not find "Drive and Docs" in datatransfer applications: ${apps
        .map((a) => a.name)
        .join(", ")}`,
    );
  }
  return drive.id;
}

export async function transferDriveOwnership(
  fromEmail: string,
  toEmail: string,
): Promise<string> {
  const dt = getDataTransfer();
  const [fromId, toId, driveAppId] = await Promise.all([
    getUserId(fromEmail),
    getUserId(toEmail),
    getDriveApplicationId(),
  ]);
  const res = await dt.transfers.insert({
    requestBody: {
      oldOwnerUserId: fromId,
      newOwnerUserId: toId,
      applicationDataTransfers: [
        {
          applicationId: driveAppId,
          applicationTransferParams: [
            { key: "PRIVACY_LEVEL", value: ["PRIVATE", "SHARED"] },
            { key: "RELEASE_RESOURCES", value: ["TRUE"] },
          ],
        },
      ],
    },
  });
  const id = res.data.id;
  if (!id) throw new Error("Drive transfer returned no id");
  return id;
}

export async function deleteUser(userEmail: string): Promise<void> {
  const dir = getDirectory();
  await dir.users.delete({ userKey: userEmail });
}

export async function waitForUserDeleted(
  email: string,
  timeoutMs = 30_000,
): Promise<void> {
  const dir = getDirectory();
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      await dir.users.get({ userKey: email });
    } catch (err: any) {
      const status = err?.code ?? err?.response?.status;
      // 404 = fully removed; 400 "Type not supported: userKey" = soft-deleted.
      // Either state means the live directory no longer resolves this email.
      if (status === 404 || isSoftDeletedSignal(err)) return;
      throw err;
    }
    await Bun.sleep(2_000);
  }
  throw new Error(
    `Timed out waiting for ${email} to be deleted from Workspace`,
  );
}

export async function createGroup(
  email: string,
  name: string,
): Promise<void> {
  const dir = getDirectory();
  await dir.groups.insert({
    requestBody: { email, name },
  });
}

export async function configureArchiveGroup(email: string): Promise<void> {
  const settings = getGroupsSettings();
  await settings.groups.update({
    groupUniqueId: email,
    requestBody: {
      whoCanPostMessage: "ANYONE_CAN_POST",
      whoCanJoin: "CAN_REQUEST_TO_JOIN",
      whoCanViewMembership: "ALL_MEMBERS_CAN_VIEW",
      whoCanViewGroup: "ALL_MEMBERS_CAN_VIEW",
      whoCanModerateMembers: "OWNERS_AND_MANAGERS",
      archiveOnly: "false",
      messageModerationLevel: "MODERATE_NONE",
    },
  });
}

export async function addGroupOwner(
  groupEmail: string,
  memberEmail: string,
): Promise<void> {
  const dir = getDirectory();
  try {
    await dir.members.insert({
      groupKey: groupEmail,
      requestBody: { email: memberEmail, role: "OWNER" },
    });
  } catch (err: any) {
    const status = err?.code ?? err?.response?.status;
    const msg = String(err?.message ?? "");
    // 409 / duplicate => member already present. Idempotent.
    if (status === 409 || /duplicate|already a member|memberKey/i.test(msg)) {
      return;
    }
    throw err;
  }
}

export async function groupHasOwner(groupEmail: string): Promise<boolean> {
  const dir = getDirectory();
  try {
    const res = await dir.members.list({ groupKey: groupEmail, roles: "OWNER" });
    return (res.data.members ?? []).length > 0;
  } catch (err: any) {
    if (err?.code === 404 || err?.response?.status === 404) return false;
    throw err;
  }
}
