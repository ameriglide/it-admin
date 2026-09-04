// Turns a Plan (Task 4) into the human-readable summary printed by
// bin/sage-taxcode-diff. See it-admin-docs/specs/2026-09-04-sage-taxcode-merge-design.md.
import type { Plan, LineUpdate } from "./diff";

const state = (code: string) => code.slice(0, 2);

function tally(keys: string[]): string {
  const m = new Map<string, number>();
  for (const k of keys) m.set(k, (m.get(k) ?? 0) + 1);
  return [...m.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([k, n]) => `${k} ${n}`).join(", ") || "none";
}

function describeUpdate(u: LineUpdate): string {
  const parts = u.changed.map((c) => `${c} ${(u.from as any)[c]} -> ${(u.to as any)[c]}`);
  return `  ${u.key.TaxCode} / ${u.key.TaxClass}: ${parts.join("; ")}`;
}

export function summarize(plan: Plan): string {
  const out: string[] = [];
  out.push(`sage-taxcode plan  (snapshot: ${plan.snapshotFile}, live: ${plan.liveFile}, generated ${plan.generatedAt})`);
  out.push(`headers: add ${plan.addHeaders.length}, live-only ${plan.liveOnlyHeaders.length}, changed ${plan.changedHeaders.length}   lines: add ${plan.addLines.length}, update ${plan.updateLines.length}, live-only ${plan.liveOnlyLines.length}, orphan ${plan.orphanLines.length}   VI jobs missing: ${plan.viJobsMissing.length}`);
  out.push(`add headers by state: ${tally(plan.addHeaders.map((h) => state(h.TaxCode)))}`);
  out.push(`update lines by state/class: ${tally(plan.updateLines.map((u) => `${state(u.key.TaxCode)} ${u.key.TaxClass}`))}`);
  const shown = plan.updateLines.length <= 50 ? plan.updateLines : plan.updateLines.slice(0, 10);
  for (const u of shown) out.push(describeUpdate(u));
  if (shown.length < plan.updateLines.length) out.push(`  ... ${plan.updateLines.length - shown.length} more`);
  out.push(`changed headers (NOT planned): ${plan.changedHeaders.length ? plan.changedHeaders.map((c) => `${c.key.TaxCode} [${c.changed.join(", ")}]`).join("; ") : "none"}`);
  if (plan.orphanLines.length) out.push(`orphan lines (NOT planned): ${plan.orphanLines.map((l) => `${l.TaxCode}/${l.TaxClass}`).join(", ")}`);
  out.push(`VI jobs missing: ${plan.viJobsMissing.length ? plan.viJobsMissing.map((j) => `${j.JobName} (${j.JobType}, ${j.LastCompanyCode}, ${j.TableName}) elements ${Object.entries(j.elementCounts).filter(([, n]) => n > 0).map(([t, n]) => `${t}=${n}`).join(" ")}`).join("\n                 ") : "none"}`);
  return out.join("\n");
}
