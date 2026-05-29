import type { AllocationResult } from "../types";

const fmt = (n: number) => `$${n.toFixed(2)}`;

export function renderMarkdown(r: AllocationResult): string {
  const lines: string[] = [];
  lines.push(`# DigitalOcean Cost Allocation — ${r.period}`);
  lines.push("");
  lines.push(`Invoice total: **${fmt(r.invoiceTotal)}**`);
  lines.push("");
  lines.push("## Per-entity totals");
  lines.push("");
  lines.push("| Entity | Direct | Shared share | Total |");
  lines.push("|---|--:|--:|--:|");
  for (const entity of Object.keys(r.totals).sort()) {
    const shared = r.sharedSplit[entity] ?? 0;
    // Direct shown = total - shared so the columns always reconcile, even after
    // a rollup folded another bucket (e.g. ATC) into this entity's total.
    const directShown = r.totals[entity] - shared;
    lines.push(
      `| ${entity} | ${fmt(directShown)} | ${fmt(shared)} | ${fmt(r.totals[entity])} |`,
    );
  }
  lines.push("");
  lines.push(
    `Shared bucket: ${fmt(r.sharedTotal)} — split per \`allocation-ratio.json\`.`,
  );

  // Surface any rolled-up direct spend (e.g. ATC included under IAI).
  const rolledNotes = Object.entries(r.direct).filter(
    ([entity]) => r.totals[entity] == null,
  );
  if (rolledNotes.length > 0) {
    lines.push("");
    for (const [entity, usd] of rolledNotes) {
      lines.push(`- ${entity} direct spend ${fmt(usd)} is rolled into another entity's total.`);
    }
  }

  lines.push("");
  if (r.unmapped.total > 0.005) {
    lines.push("## ⚠ Unmapped line items (NOT allocated — fix `do-entity-map.json`)");
    lines.push("");
    lines.push("| Project | USD |");
    lines.push("|---|--:|");
    for (const [proj, usd] of Object.entries(r.unmapped.projects).sort(
      (a, b) => b[1] - a[1],
    )) {
      lines.push(`| ${proj} | ${fmt(usd)} |`);
    }
    lines.push("");
  } else {
    lines.push("✓ Every line item mapped to an entity.");
    lines.push("");
  }
  return lines.join("\n");
}

export function renderCsv(r: AllocationResult): string {
  const rows: string[][] = [["entity", "direct_usd", "shared_usd", "total_usd"]];
  for (const entity of Object.keys(r.totals).sort()) {
    const shared = r.sharedSplit[entity] ?? 0;
    rows.push([
      entity,
      (r.totals[entity] - shared).toFixed(2),
      shared.toFixed(2),
      r.totals[entity].toFixed(2),
    ]);
  }
  return rows.map((row) => row.join(",")).join("\n") + "\n";
}
