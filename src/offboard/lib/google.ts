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

export async function classifyAddress(email: string): Promise<AddressKind> {
  const dir = getDirectory();
  // Try users.get first — the common case during offboarding is that the
  // user still exists. This also dodges the groups.get-on-a-user 403 quirk.
  try {
    await dir.users.get({ userKey: email });
    return "user";
  } catch (err: any) {
    if (!isNotFound(err)) throw err;
  }
  try {
    await dir.groups.get({ groupKey: email });
    return "group";
  } catch (err: any) {
    if (isNotFound(err)) return "absent";
    throw err;
  }
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
      if (err?.code === 404 || err?.response?.status === 404) return;
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
  await dir.members.insert({
    groupKey: groupEmail,
    requestBody: { email: memberEmail, role: "OWNER" },
  });
}
