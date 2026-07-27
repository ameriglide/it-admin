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
