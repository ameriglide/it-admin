import { google } from "googleapis";

export function getDomain(): string {
  return process.env.DOMAIN ?? "ameriglide.com";
}

// Short tokens ("sales-staff" or "sales-staff@") expand to <localpart>@<domain>,
// so the same ONBOARD_ROLES config works across tenants. A token that already
// carries a domain ("x@foo.com") is used as-is.
export function resolveGroupAddress(token: string, domain: string): string {
  const t = token.trim();
  const at = t.indexOf("@");
  if (at === -1) return `${t}@${domain}`;
  const local = t.slice(0, at);
  const rest = t.slice(at + 1);
  return rest.length > 0 ? t : `${local}@${domain}`;
}

// Parses the ONBOARD_ROLES env var: a JSON object mapping role name -> array of
// group tokens. Unset/empty -> {}. Malformed input throws loudly (never a
// silent skip on bad config).
export function parseRoles(raw: string | undefined): Record<string, string[]> {
  if (!raw || raw.trim() === "") return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (e: any) {
    throw new Error(`ONBOARD_ROLES is not valid JSON: ${e.message}`);
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("ONBOARD_ROLES must be a JSON object of role -> string[]");
  }
  const out: Record<string, string[]> = {};
  for (const [role, value] of Object.entries(parsed as Record<string, unknown>)) {
    if (
      !Array.isArray(value) ||
      value.some((v) => typeof v !== "string" || v.trim() === "")
    ) {
      throw new Error(
        `ONBOARD_ROLES["${role}"] must be an array of non-empty strings`,
      );
    }
    out[role] = value as string[];
  }
  return out;
}

function getAuth() {
  const keyPath = process.env.GOOGLE_SERVICE_ACCOUNT_KEY;
  const adminEmail = process.env.GOOGLE_ADMIN_EMAIL;
  if (!keyPath) throw new Error("GOOGLE_SERVICE_ACCOUNT_KEY not set");
  if (!adminEmail) throw new Error("GOOGLE_ADMIN_EMAIL not set");
  return new google.auth.GoogleAuth({
    keyFile: keyPath,
    scopes: ["https://www.googleapis.com/auth/admin.directory.group.member"],
    clientOptions: { subject: adminEmail },
  });
}

export function getGroupsDirectory() {
  return google.admin({ version: "directory_v1", auth: getAuth() });
}

function statusOf(err: any): number | undefined {
  return err?.code ?? err?.response?.status;
}

// Adds userEmail to groupEmail as a MEMBER. Idempotent: an existing membership
// (409 / duplicate) resolves to "existed" rather than throwing.
export async function addGroupMember(
  groupEmail: string,
  userEmail: string,
): Promise<"added" | "existed"> {
  const dir = getGroupsDirectory();
  try {
    await dir.members.insert({
      groupKey: groupEmail,
      requestBody: { email: userEmail, role: "MEMBER" },
    });
    return "added";
  } catch (err: any) {
    const status = statusOf(err);
    const msg = String(err?.message ?? "");
    if (status === 409 || /duplicate|already a member|memberKey/i.test(msg)) {
      return "existed";
    }
    if (status === 404) {
      throw new Error(`Group not found: ${groupEmail}. Check ONBOARD_ROLES.`);
    }
    if (status === 403) {
      throw new Error(
        `Permission denied adding to ${groupEmail}. The service account may be ` +
          `missing the admin.directory.group.member scope (domain-wide delegation).`,
      );
    }
    throw err;
  }
}

// Returns the lowercased emails of every direct member of groupEmail.
// A missing group (404) yields [] rather than throwing.
export async function listGroupMemberEmails(
  groupEmail: string,
): Promise<string[]> {
  const dir = getGroupsDirectory();
  const emails: string[] = [];
  let pageToken: string | undefined;
  try {
    do {
      const res = await dir.members.list({
        groupKey: groupEmail,
        maxResults: 200,
        pageToken,
      });
      for (const m of res.data.members ?? []) {
        if (m.email) emails.push(m.email.toLowerCase());
      }
      pageToken = res.data.nextPageToken ?? undefined;
    } while (pageToken);
  } catch (err: any) {
    if (statusOf(err) === 404) return [];
    throw err;
  }
  return emails;
}
