export type Entity = "AMG" | "IAI" | "ATC" | "SHARED";

/** project_name (exactly as it appears in the DO invoice CSV) -> entity bucket. */
export type EntityMap = Record<string, Entity>;

export interface RatioConfig {
  /**
   * How the SHARED bucket is divided across final entities.
   * Keys are final entity codes (post-rollup); values MUST sum to 1.
   */
  shareSplit: Record<string, number>;
  /**
   * Direct buckets folded into another entity for the final statement,
   * e.g. { ATC: "IAI" } reports ATC Distributors spend under Internet Alliance.
   */
  rollup: Record<string, string>;
}

export interface LineItem {
  product: string;
  group: string;
  description: string;
  category: string;
  projectName: string;
  usd: number;
}

/**
 * Classifies a line item by resource name (case-insensitive substring tested
 * against `group_description + description`), taking precedence over project_name.
 * Lets the tool allocate invoices from before the 2026-05 project restructure,
 * and stays correct through the transition when project_name is in flux.
 * Order matters: first match wins, so list more-specific patterns first.
 */
export interface ResourceRule {
  match: string;
  entity: Entity;
}

export interface AllocationResult {
  period: string;
  invoiceTotal: number;
  /** Raw per-entity direct spend BEFORE rollup, keyed by the entity-map code. */
  direct: Record<string, number>;
  sharedTotal: number;
  /** Shared dollars assigned to each final entity by shareSplit. */
  sharedSplit: Record<string, number>;
  /** Final per-entity totals after rollup + shared split. */
  totals: Record<string, number>;
  /** Line items whose project_name was missing or unmapped. Never silently dropped. */
  unmapped: { total: number; projects: Record<string, number> };
  /** True when every dollar mapped to a real entity (no unmapped spend). */
  reconciled: boolean;
}
