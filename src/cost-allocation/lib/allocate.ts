import type {
  AllocationResult,
  EntityMap,
  LineItem,
  RatioConfig,
  ResourceRule,
} from "../types";

/** Invoice CSV column names vary slightly across DO formats; resolve by alias. */
const COLUMN_ALIASES: Record<string, string[]> = {
  projectName: ["project_name", "project name", "project"],
  usd: ["USD", "amount", "amount_usd"],
  product: ["product"],
  group: ["group_description", "group"],
  description: ["description"],
  category: ["category"],
};

function resolveColumns(headers: string[]): Record<string, string | null> {
  const lower = new Map(headers.map((h) => [h.toLowerCase(), h]));
  const out: Record<string, string | null> = {};
  for (const [key, aliases] of Object.entries(COLUMN_ALIASES)) {
    out[key] = aliases.map((a) => lower.get(a.toLowerCase())).find(Boolean) ?? null;
  }
  return out;
}

export function rowsToLineItems(
  rows: Record<string, string>[],
  headers: string[],
): LineItem[] {
  const col = resolveColumns(headers);
  if (!col.usd) throw new Error("invoice CSV has no USD/amount column");
  if (!col.projectName) {
    throw new Error(
      "invoice CSV has no project_name column — cannot allocate by project. " +
        "Confirm resources are assigned to projects and that this is the per-resource CSV.",
    );
  }
  return rows.map((r) => ({
    product: col.product ? r[col.product] : "",
    group: col.group ? r[col.group] : "",
    description: col.description ? r[col.description] : "",
    category: col.category ? r[col.category] : "",
    projectName: r[col.projectName!] ?? "",
    usd: parseFloat((r[col.usd!] ?? "0").replace(/[$,]/g, "")) || 0,
  }));
}

/**
 * Resolve a line item's entity: resource-name rules first (stable across project
 * moves), then project_name. Returns undefined when nothing matches.
 */
function classifyEntity(
  item: LineItem,
  resourceRules: ResourceRule[],
  projectMapLower: Map<string, string>,
): string | undefined {
  const haystack = `${item.group} ${item.description}`.toLowerCase();
  for (const rule of resourceRules) {
    if (haystack.includes(rule.match.toLowerCase())) return rule.entity;
  }
  if (item.projectName) return projectMapLower.get(item.projectName.toLowerCase());
  return undefined;
}

export function allocate(
  items: LineItem[],
  entityMap: EntityMap,
  ratio: RatioConfig,
  period: string,
  resourceRules: ResourceRule[] = [],
): AllocationResult {
  const direct: Record<string, number> = {};
  const unmappedProjects: Record<string, number> = {};
  let sharedTotal = 0;
  let invoiceTotal = 0;

  const mapLower = new Map(
    Object.entries(entityMap).map(([k, v]) => [k.toLowerCase(), v]),
  );

  for (const it of items) {
    invoiceTotal += it.usd;
    const entity = classifyEntity(it, resourceRules, mapLower);
    if (!entity) {
      // Never silently drop spend: park it in unmapped and flag loudly.
      const key = it.projectName || it.description || "(no project)";
      unmappedProjects[key] = (unmappedProjects[key] ?? 0) + it.usd;
      continue;
    }
    if (entity === "SHARED") sharedTotal += it.usd;
    else direct[entity] = (direct[entity] ?? 0) + it.usd;
  }

  // Fold direct buckets per the rollup map (e.g. ATC -> IAI).
  const rolledDirect: Record<string, number> = { ...direct };
  for (const [from, to] of Object.entries(ratio.rollup)) {
    if (rolledDirect[from] != null) {
      rolledDirect[to] = (rolledDirect[to] ?? 0) + rolledDirect[from];
      delete rolledDirect[from];
    }
  }

  // Divide the shared bucket by the agreed split.
  const splitSum = Object.values(ratio.shareSplit).reduce((a, b) => a + b, 0);
  if (Math.abs(splitSum - 1) > 1e-6) {
    throw new Error(
      `allocation-ratio.json shareSplit must sum to 1 (got ${splitSum}).`,
    );
  }
  const sharedSplit: Record<string, number> = {};
  for (const [entity, frac] of Object.entries(ratio.shareSplit)) {
    sharedSplit[entity] = round2(sharedTotal * frac);
  }

  const totals: Record<string, number> = {};
  for (const entity of new Set([
    ...Object.keys(rolledDirect),
    ...Object.keys(sharedSplit),
  ])) {
    totals[entity] = round2(
      (rolledDirect[entity] ?? 0) + (sharedSplit[entity] ?? 0),
    );
  }

  const unmappedTotal = Object.values(unmappedProjects).reduce((a, b) => a + b, 0);

  return {
    period,
    invoiceTotal: round2(invoiceTotal),
    direct: Object.fromEntries(
      Object.entries(direct).map(([k, v]) => [k, round2(v)]),
    ),
    sharedTotal: round2(sharedTotal),
    sharedSplit,
    totals,
    unmapped: { total: round2(unmappedTotal), projects: unmappedProjects },
    // Every line lands in exactly one of direct/shared/unmapped, so the books
    // always balance by construction; the meaningful check is "nothing unmapped".
    reconciled: unmappedTotal < 0.005,
  };
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}
