import { parseCsv } from "./lib/csv";
import { allocate, rowsToLineItems } from "./lib/allocate";
import { renderCsv, renderMarkdown } from "./lib/report";
import { fetchInvoiceCsv, listInvoices } from "./lib/invoice";
import type { EntityMap, RatioConfig, ResourceRule } from "./types";

const DIR = new URL(".", import.meta.url).pathname;

export interface RunOptions {
  /** Path to a manually-downloaded invoice CSV (fallback when no billing PAT). */
  csv?: string;
  /** Specific invoice UUID. */
  uuid?: string;
  /** Invoice period, "YYYY-MM". */
  period?: string;
  /** Output directory (defaults to the repo's gitignored output/). */
  outDir?: string;
}

export async function run(opts: RunOptions = {}): Promise<void> {
  const entityMap = (await Bun.file(`${DIR}do-entity-map.json`).json()) as EntityMap;
  const ratio = (await Bun.file(`${DIR}allocation-ratio.json`).json()) as RatioConfig;
  const resourceRules = (await Bun.file(`${DIR}resource-map.json`).json()) as ResourceRule[];

  let csvText: string;
  let period: string;

  if (opts.csv) {
    csvText = await Bun.file(opts.csv).text();
    period = opts.period ?? opts.csv.replace(/.*?(\d{4}-\d{2}).*/, "$1");
  } else {
    const invoices = await listInvoices();
    if (invoices.length === 0) throw new Error("no invoices found on this account");
    const target = opts.uuid
      ? invoices.find((i) => i.invoice_uuid === opts.uuid)
      : opts.period
        ? invoices.find((i) => i.invoice_period === opts.period)
        : invoices[0];
    if (!target) {
      throw new Error(
        `no invoice matched (uuid=${opts.uuid ?? "-"} period=${opts.period ?? "-"})`,
      );
    }
    period = target.invoice_period;
    console.log(`Fetching invoice ${target.invoice_period} (${target.invoice_uuid})...`);
    csvText = await fetchInvoiceCsv(target.invoice_uuid);
  }

  const { headers, rows } = parseCsv(csvText);
  const result = allocate(
    rowsToLineItems(rows, headers),
    entityMap,
    ratio,
    period,
    resourceRules,
  );

  const md = renderMarkdown(result);
  console.log("\n" + md);

  const outDir = opts.outDir ?? `${DIR}../../output`;
  const base = `${outDir}/do-cost-allocation-${period}`;
  await Bun.write(`${base}.md`, md);
  await Bun.write(`${base}.csv`, renderCsv(result));
  console.log(`Wrote ${base}.md and ${base}.csv`);

  if (!result.reconciled) {
    console.error(
      `\n⚠ ${result.unmapped.total.toFixed(2)} USD in unmapped line items — ` +
        `update do-entity-map.json before trusting these numbers.`,
    );
    process.exit(2);
  }
}
