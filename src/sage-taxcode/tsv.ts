// Parses the TSV sections written by scripts/sage-taxcode-dump.ps1.

export interface Table {
  name: string;
  columns: string[];
  rows: Record<string, string>[];
  error?: string;
}

const MARKER = "##### ";

export function parseDump(text: string): Map<string, Table> {
  const tables = new Map<string, Table>();
  let current: Table | undefined;
  const lines = text.split(/\r?\n/);
  for (const line of lines) {
    if (line.startsWith(MARKER)) {
      current = { name: line.slice(MARKER.length).trim(), columns: [], rows: [] };
      tables.set(current.name, current);
      continue;
    }
    if (line === "") continue;
    if (!current) throw new Error("sage-taxcode dump: data before the first ##### marker");
    // error set => rows empty; a mid-table failure discards what was read before it
    if (line.startsWith("!ERROR\t")) {
      current.error = line.slice("!ERROR\t".length);
      current.rows = [];
      continue;
    }
    const cells = line.split("\t");
    if (current.columns.length === 0) {
      current.columns = cells;
      continue;
    }
    const row: Record<string, string> = {};
    current.columns.forEach((c, i) => {
      row[c] = cells[i] ?? "";
    });
    current.rows.push(row);
  }
  return tables;
}
