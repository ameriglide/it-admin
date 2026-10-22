import { getPhenix } from "../../onboard/lib/db";

export interface AgentSidRow {
  id: number;
  sid: string | null;
}

// Picks the agent rows whose sid must be cleared once the TaskRouter worker is
// gone. More than one row with a sid for the same email is ambiguous -- refuse
// rather than clear an agent we were not asked to offboard.
export function agentSidsToClear(email: string, rows: AgentSidRow[]): AgentSidRow[] {
  const withSid = rows.filter((r) => r.sid !== null);
  if (withSid.length > 1) {
    throw new Error(
      `${withSid.length} Phenix agent rows for ${email} carry a sid ` +
        `(ids ${withSid.map((r) => r.id).join(", ")}); clear the right one by hand`,
    );
  }
  return withSid;
}

export async function findAgentSids(email: string): Promise<AgentSidRow[]> {
  const sql = getPhenix();
  return sql<AgentSidRow[]>`SELECT id, sid FROM agent WHERE email = ${email} ORDER BY id`;
}

// Phenix caches Agent across JVMs and listens for invalidations on its own
// Redis. ag-admin cannot reach that Redis, so a Phenix server may serve the
// old sid until its cache entry is evicted or reloaded.
export async function clearAgentSid(row: AgentSidRow): Promise<void> {
  const sql = getPhenix();
  await sql`UPDATE agent SET sid = NULL WHERE id = ${row.id} AND sid = ${row.sid}`;
}
