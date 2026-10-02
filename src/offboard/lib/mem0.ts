const BASE = "https://api.mem0.ai";
const USER_ID = "ameriglide-team";
const APP_ID = "org-directory";
const SOURCE = "gws-directory";

function authHeaders(): Record<string, string> {
  const key = process.env.MEM0_API_KEY;
  if (!key) throw new Error("MEM0_API_KEY is not set (expected in the repo .env).");
  return { Authorization: `Token ${key}`, "Content-Type": "application/json" };
}

export function isOrgPersonForEmail(
  memory: { metadata?: Record<string, unknown> },
  email: string,
): boolean {
  const md = memory.metadata ?? {};
  if (md.source !== SOURCE) return false;
  const memEmail = typeof md.email === "string" ? md.email.toLowerCase() : null;
  return memEmail !== null && memEmail === email.toLowerCase();
}

export function buildListFilters(): object {
  return {
    AND: [
      { user_id: USER_ID },
      { app_id: APP_ID },
      { metadata: { source: SOURCE } },
    ],
  };
}

export async function orgDirectoryMemoryIds(email: string): Promise<string[]> {
  const res = await fetch(`${BASE}/v2/memories/search/`, {
    method: "POST",
    headers: authHeaders(),
    body: JSON.stringify({ query: email, filters: buildListFilters(), top_k: 25 }), // top_k=25 is a completeness cap; exact-email query ranks the person first, so 25 is ample
  });
  if (!res.ok) throw new Error(`mem0 search failed ${res.status}: ${await res.text()}`);
  const body = await res.json();
  const items: Array<{ id: string; metadata?: Record<string, unknown> }> = Array.isArray(body)
    ? body
    : (body.results ?? []);
  return items.filter((m) => isOrgPersonForEmail(m, email)).map((m) => m.id);
}

export async function deleteMemory(id: string): Promise<void> {
  const res = await fetch(`${BASE}/v1/memories/${id}/`, {
    method: "DELETE",
    headers: authHeaders(),
  });
  if (!res.ok && res.status !== 404) {
    throw new Error(`mem0 delete failed ${res.status}: ${await res.text()}`);
  }
}

// Everything below writes a mirror entry (bin/onboard). The shapes are a port
// of ameriglide-claude-config's scripts/lib/{gws,mem0}.mjs and must stay
// identical to them: seed-org diffs on the metadata fields, so an entry that
// drifts is rewritten on the next reseed, and text that drifts is never fixed.

export interface OrgPerson {
  email: string;
  name: string;
  title: string | null;
  department: string | null;
  orgUnit: string | null;
  manager: string | null;
  pronouns: string | null;
}

// The subset of an Admin SDK User resource the mirror reads.
export interface DirectoryUser {
  primaryEmail?: string | null;
  name?: { fullName?: string | null } | null;
  orgUnitPath?: string | null;
  organizations?: Array<{
    primary?: boolean | null;
    title?: string | null;
    department?: string | null;
  }> | null;
  relations?: Array<{ type?: string | null; value?: string | null }> | null;
  gender?: { addressMeAs?: string | null } | null;
}

export function personFromDirectoryUser(user: DirectoryUser): OrgPerson {
  const orgs = user.organizations ?? [];
  const org = orgs.find((o) => o.primary) ?? orgs[0];
  const pronouns = user.gender?.addressMeAs?.trim();
  const email = user.primaryEmail ?? "";
  return {
    email,
    name: user.name?.fullName ?? email,
    title: org?.title ?? null,
    department: org?.department ?? null,
    orgUnit: user.orgUnitPath ?? null,
    manager: user.relations?.find((r) => r.type === "manager")?.value ?? null,
    pronouns: pronouns ? pronouns : null,
  };
}

export function memoryContent(person: OrgPerson, managerName?: string | null): string {
  const parts = [person.name];
  const role = [person.title, person.department && `${person.department} department`]
    .filter(Boolean)
    .join(", ");
  if (role) parts.push(` — ${role}`);
  if (person.orgUnit) parts.push(` (org unit ${person.orgUnit})`);
  parts.push(`. Email ${person.email}.`);
  if (person.manager) {
    parts.push(` Manager: ${managerName ? `${managerName} (${person.manager})` : person.manager}.`);
  }
  if (person.pronouns) parts.push(` Pronouns: ${person.pronouns}.`);
  return parts.join("");
}

export function memoryMetadata(person: OrgPerson, reviewed: boolean): Record<string, unknown> {
  return {
    type: "org-person",
    source: SOURCE,
    email: person.email,
    name: person.name,
    title: person.title,
    department: person.department,
    orgUnit: person.orgUnit,
    manager: person.manager,
    pronouns: person.pronouns,
    reviewed,
  };
}

export async function addOrgPerson(person: OrgPerson, managerName?: string | null): Promise<void> {
  const res = await fetch(`${BASE}/v1/memories/`, {
    method: "POST",
    headers: authHeaders(),
    body: JSON.stringify({
      messages: [{ role: "user", content: memoryContent(person, managerName) }],
      user_id: USER_ID,
      app_id: APP_ID,
      infer: false,
      metadata: memoryMetadata(person, false),
    }),
  });
  if (!res.ok) throw new Error(`mem0 add failed ${res.status}: ${await res.text()}`);
}
