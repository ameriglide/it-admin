import type { Step, Context } from "../types";
import { getSonar } from "../lib/db";
import { choose, input } from "../lib/prompt";
import { assertValidExtension, isPbxEnabled } from "../lib/extension";

// Sonar is the IAI CRM. Its agent record lives in the `agent` table (database
// `cg2`) and is the counterpart to Phenix's, with one structural difference
// that drives this whole step: the primary key is `key varchar(4)` -- the
// agent's four-digit extension -- not a serial id. There is no password
// column; Sonar authenticates through Google OAuth, so the Google step is what
// actually grants access.

export interface CallCenter {
  id: number;
  name: string;
}

export interface SonarAgentHolder {
  firstname: string;
  lastname: string;
}

export interface SonarAgentInput {
  ext: string;
  taken: SonarAgentHolder | undefined; // existing agent holding `ext`, if any
  callCenters: CallCenter[];
  callCenterName: string | undefined; // --call-center, or the interactive pick
  sales: boolean | undefined;
  pbxEnabled: boolean | null; // null = enabled list unknown, not "no"
}

export interface SonarAgentPlan {
  key: string;
  callCenter: CallCenter;
  sales: boolean;
  paused: true;
  locked: false;
}

// An existing Sonar agent's key IS its extension. If the operator also passed
// --extension, the two must agree, or the PBX step would build the softphone
// sheet for a different number than Sonar hands Asterisk as the caller id.
export function resolveExistingExtension(
  existingKey: string,
  requested: string | undefined,
  email?: string,
): string {
  if (requested === undefined || requested === existingKey) return existingKey;
  const who = email ? `Sonar agent for ${email}` : "The existing Sonar agent";
  throw new Error(
    `${who} already has key ${existingKey}; you passed --extension ${requested}. ` +
      `Drop --extension or pass ${existingKey}.`,
  );
}

function takenMessage(ext: string, holder: SonarAgentHolder): string {
  return (
    `Extension ${ext} already belongs to ${holder.firstname} ${holder.lastname}. ` +
    `Pick a free one -- agent.key is the primary key, so this would collide.`
  );
}

// Everything that can be refused before asking the operator to pick a call
// center. Throws; returns nothing.
export function preflightSonarAgent(
  input: Omit<SonarAgentInput, "callCenterName" | "sales">,
): void {
  const { ext, taken, callCenters, pbxEnabled } = input;
  assertValidExtension(ext);
  if (taken) throw new Error(takenMessage(ext, taken));
  if (pbxEnabled === false) {
    throw new Error(
      `Extension ${ext} is disabled on the PBX (not in PBX_ENABLED_EXTENSIONS), so its ` +
        `softphone cannot register. Refusing to write it into Sonar's primary key. ` +
        `Ask the PBX admin to enable it first, or pick an enabled extension (see IAI-35).`,
    );
  }
  if (!callCenters.length) {
    throw new Error("No call centers found in Sonar; cannot place the agent.");
  }
}

// Pure decision for a new Sonar agent row. run() gathers the inputs and does
// the INSERT; everything that can be refused is refused here.
export function planSonarAgent(input: SonarAgentInput): SonarAgentPlan {
  preflightSonarAgent(input);
  const { ext, callCenters, callCenterName } = input;
  const callCenter = callCenters.find((c) => c.name === callCenterName);
  if (!callCenter) {
    throw new Error(
      `Unknown call center "${callCenterName ?? ""}". ` +
        `Options: ${callCenters.map((c) => c.name).join(", ")}`,
    );
  }
  return {
    key: ext,
    callCenter,
    // IAI agents are sales agents; --no-sales is the exception.
    sales: input.sales ?? true,
    paused: true,
    locked: false,
  };
}

function isUniqueViolation(err: unknown): boolean {
  return (
    typeof err === "object" && err !== null && (err as { code?: unknown }).code === "23505"
  );
}

export const sonarStep: Step = {
  name: "Sonar",

  async check(ctx: Context): Promise<boolean> {
    const sql = getSonar();
    const rows = await sql<{ key: string }[]>`
      SELECT key FROM agent WHERE lower(email) = lower(${ctx.email})
    `;
    if (rows.length > 1) {
      throw new Error(
        `More than one Sonar agent has email ${ctx.email} (keys: ` +
          `${rows.map((r) => r.key).join(", ")}). Resolve the duplicate in Sonar first.`,
      );
    }
    const [row] = rows;
    if (!row) return false;

    ctx.extension = resolveExistingExtension(row.key, ctx.extension, ctx.email);
    ctx.sonarAgentKey = row.key;
    ctx.sonarAgentCreated = false;

    const ignored: string[] = [];
    if (ctx.sonarCallCenter) ignored.push(`--call-center "${ctx.sonarCallCenter}"`);
    if (ctx.sales === false) ignored.push("--no-sales");
    if (ignored.length) {
      console.log(
        `  Warning: Sonar agent ${row.key} already exists; ${ignored.join(" and ")} ` +
          `not applied. Change it in Sonar if needed.`,
      );
    }
    return true;
  },

  async run(ctx: Context): Promise<void> {
    const sql = getSonar();

    const ext = ctx.extension ?? (await input("Sonar extension (4 digits)"));
    assertValidExtension(ext);

    const [taken] = await sql<SonarAgentHolder[]>`
      SELECT firstname, lastname FROM agent WHERE key = ${ext}
    `;
    const callCenters = await sql<CallCenter[]>`
      SELECT id, name FROM callcenter ORDER BY "position", name
    `;
    const base = {
      ext,
      taken,
      callCenters: [...callCenters],
      pbxEnabled: isPbxEnabled(ext),
    };

    // Refuse before prompting, so the operator is not asked to pick a call
    // center for an agent that cannot be created.
    preflightSonarAgent(base);

    let callCenterName = ctx.sonarCallCenter;
    if (!callCenterName) {
      console.log("\nSelect call center:");
      callCenterName = await choose(base.callCenters.map((c) => c.name));
    }

    const plan = planSonarAgent({ ...base, callCenterName, sales: ctx.sales });
    console.log(`  Call center: ${plan.callCenter.name}`);

    // paused=true on purpose: a brand-new agent should not be handed live
    // calls before their softphone registers. Sonar's "Start taking calls"
    // button is what clears it, and that click is also what adds them to the
    // Asterisk queue (see the mem0 note under domain=iai-phones on queue
    // membership).
    try {
      await sql`
        INSERT INTO agent (
          key, firstname, lastname, email,
          callcenter, sales, locked, paused, forwarded, penalizedforwarding
        ) VALUES (
          ${plan.key}, ${ctx.firstName}, ${ctx.lastName}, ${ctx.email},
          ${plan.callCenter.id}, ${plan.sales}, ${plan.locked}, ${plan.paused}, false, false
        )
      `;
    } catch (err) {
      // The taken-check above and this INSERT are not atomic; if someone
      // claimed the key in between, report it the same way.
      if (isUniqueViolation(err)) {
        const [holder] = await sql<SonarAgentHolder[]>`
          SELECT firstname, lastname FROM agent WHERE key = ${plan.key}
        `;
        throw new Error(
          holder
            ? takenMessage(plan.key, holder)
            : `Sonar agent INSERT for ${plan.key} hit a unique violation: ` +
                `${(err as { detail?: string }).detail ?? String(err)}`,
        );
      }
      throw err;
    }

    ctx.sonarAgentKey = plan.key;
    ctx.sonarAgentCreated = true;
    ctx.extension = plan.key;

    console.log(
      `  Created Sonar agent ${plan.key} (${ctx.firstName} ${ctx.lastName}) in ` +
        `${plan.callCenter.name}, sales=${plan.sales}, paused.`,
    );
    console.log(
      `  Skills: add them in Sonar (skilledagent) once the phone is registered.`,
    );
  },
};
