import { getPhenix } from "../../onboard/lib/db";

export interface AgentSidRow {
  id: number;
  sid: string | null;
}

// What TaskRouter says about agent.sid when the email lookup did not return
// that same worker: gone (404), a live worker that matches the email, or a
// live worker that belongs to someone else.
export type AgentWorkerState = "absent" | "ours" | "foreign";

export interface WorkerTeardownPlan {
  // TaskRouter workers to delete, in order.
  deleteSids: string[];
  // The agent row whose sid to clear once every deleteSids entry is gone.
  clear: AgentSidRow | null;
  // agent.sid that TaskRouter already reports as gone, so it is cleared
  // without a delete.
  alreadyGone: string | null;
  // Set when the state is ambiguous: nothing is cleared and the operator must
  // resolve it by hand. The worker found by email is still deleted.
  problem: string | null;
}

function withSids(rows: AgentSidRow[]): AgentSidRow[] {
  return rows.filter((r) => r.sid);
}

// The agent.sid that must be looked up in TaskRouter before planning: the one
// sid the email lookup did not already return. null when there is nothing to
// verify (no sid, the email lookup found it, or several rows are ambiguous).
export function sidToVerify(workerByEmail: string | null, rows: AgentSidRow[]): string | null {
  const sids = withSids(rows);
  if (sids.length !== 1) return null;
  return sids[0]!.sid === workerByEmail ? null : sids[0]!.sid;
}

// Decides how to tear down the departing agent's TaskRouter worker. agent.sid
// is cleared only once that exact worker is known to be gone, either deleted
// here or reported absent by TaskRouter. A live worker for someone else is
// never deleted, and agentWorker is re-read on every run, so a refusal stays
// in force until someone fixes it by hand. An empty sid counts as no sid.
export function planWorkerTeardown(
  email: string,
  workerByEmail: string | null,
  rows: AgentSidRow[],
  agentWorker: AgentWorkerState | null,
): WorkerTeardownPlan {
  const sids = withSids(rows);
  const byEmail = workerByEmail ? [workerByEmail] : [];
  const none = { deleteSids: byEmail, clear: null, alreadyGone: null };

  if (sids.length > 1) {
    return {
      ...none,
      problem:
        `${sids.length} Phenix agent rows for ${email} carry a sid ` +
        `(${sids.map((r) => `agent ${r.id}: ${r.sid}`).join(", ")}); ` +
        `check each worker in TaskRouter, then clear the right agent.sid by hand`,
    };
  }

  const row = sids[0] ?? null;
  if (!row || row.sid === workerByEmail) {
    return { deleteSids: byEmail, clear: row, alreadyGone: null, problem: null };
  }

  switch (agentWorker) {
    case "absent":
      return { deleteSids: byEmail, clear: row, alreadyGone: row.sid, problem: null };
    case "ours":
      return { deleteSids: [...byEmail, row.sid!], clear: row, alreadyGone: null, problem: null };
    case "foreign":
      return {
        ...none,
        problem:
          `Phenix agent ${row.id} has sid ${row.sid}, a live TaskRouter worker that does not ` +
          `match ${email}; check it and clear agent.sid by hand`,
      };
    case null:
      throw new Error(`planWorkerTeardown: agent.sid ${row.sid} was not looked up in TaskRouter`);
  }
}

// The step is done once nothing is left to delete or clear and nothing needs a
// person; a problem keeps it not-done so every run re-surfaces it.
export function teardownDone(plan: WorkerTeardownPlan, credentialPresent: boolean): boolean {
  return (
    !credentialPresent &&
    plan.deleteSids.length === 0 &&
    plan.clear === null &&
    plan.problem === null
  );
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
