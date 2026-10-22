import { getPhenix } from "../../onboard/lib/db";

export interface AgentSidRow {
  id: number;
  sid: string | null;
}

export interface WorkerTeardownPlan {
  // TaskRouter workers to delete, in order. deleteWorker treats a 404 as done.
  deleteSids: string[];
  // The agent row whose sid to clear once every deleteSids entry is gone.
  clear: AgentSidRow | null;
  // Set when the state is ambiguous: nothing is cleared and the operator must
  // resolve it by hand. The worker found by email is still deleted.
  problem: string | null;
}

// Decides how to tear down the departing agent's TaskRouter worker. agent.sid
// is the source of truth for which worker belongs to the agent: the email
// lookup can miss workers with older naming, so a sid is cleared only after
// that exact sid has been deleted. An empty sid counts as no sid.
export function planWorkerTeardown(
  email: string,
  workerByEmail: string | null,
  rows: AgentSidRow[],
): WorkerTeardownPlan {
  const withSid = rows.filter((r) => r.sid);
  const byEmail = workerByEmail ? [workerByEmail] : [];

  if (withSid.length > 1) {
    return {
      deleteSids: byEmail,
      clear: null,
      problem:
        `${withSid.length} Phenix agent rows for ${email} carry a sid ` +
        `(ids ${withSid.map((r) => r.id).join(", ")}); clear the right one by hand`,
    };
  }

  const row = withSid[0] ?? null;
  if (row && workerByEmail && row.sid !== workerByEmail) {
    return {
      deleteSids: byEmail,
      clear: null,
      problem:
        `Twilio worker ${workerByEmail} matched ${email} but Phenix agent ${row.id} ` +
        `has sid ${row.sid}; check ${row.sid} in TaskRouter and clear agent.sid by hand`,
    };
  }

  const sid = workerByEmail ?? row?.sid ?? null;
  return { deleteSids: sid ? [sid] : [], clear: row, problem: null };
}

// The UPDATE is a compare-and-set on the sid we read; anything other than one
// row means the sid changed underneath us, and a re-run re-reads the state.
export function assertOneRowCleared(count: number, row: AgentSidRow): void {
  if (count !== 1) {
    throw new Error(
      `Phenix agent ${row.id}: expected to clear sid ${row.sid}, updated ${count} rows; ` +
        `re-run to re-check`,
    );
  }
}

// Case-insensitive, like findWorkerByEmail: onboard stores the email as typed.
export async function findAgentSids(email: string): Promise<AgentSidRow[]> {
  const sql = getPhenix();
  return sql<AgentSidRow[]>`
    SELECT id, sid FROM agent WHERE lower(email) = lower(${email}) ORDER BY id
  `;
}

// Phenix caches Agent per JVM and invalidates through its own Redis, which
// ag-admin cannot reach, so a Phenix server can keep the old sid until that
// cache entry is reloaded. Phenix does not recreate workers for inactive
// agents, so the stale value is inert.
export async function clearAgentSid(row: AgentSidRow): Promise<void> {
  const sql = getPhenix();
  const result = await sql`UPDATE agent SET sid = NULL WHERE id = ${row.id} AND sid = ${row.sid}`;
  assertOneRowCleared(result.count, row);
}
