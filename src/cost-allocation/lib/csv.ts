export interface ParsedCsv {
  headers: string[];
  rows: Record<string, string>[];
}

/**
 * Minimal RFC-4180 CSV parser: handles quoted fields, embedded commas/quotes,
 * and CRLF or LF line endings. DO invoice CSVs quote the description fields
 * (which can contain commas), so a naive split on "," corrupts every row.
 */
export function parseCsv(text: string): ParsedCsv {
  const records: string[][] = [];
  let field = "";
  let record: string[] = [];
  let inQuotes = false;

  const pushField = () => {
    record.push(field);
    field = "";
  };
  const pushRecord = () => {
    records.push(record);
    record = [];
  };

  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i++; // escaped quote ("")
        } else {
          inQuotes = false;
        }
      } else {
        field += c;
      }
    } else if (c === '"') {
      inQuotes = true;
    } else if (c === ",") {
      pushField();
    } else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++; // swallow CRLF as one terminator
      pushField();
      pushRecord();
    } else {
      field += c;
    }
  }
  // flush a trailing field/record when the file doesn't end in a newline
  if (field.length > 0 || record.length > 0) {
    pushField();
    pushRecord();
  }

  const nonEmpty = records.filter((r) => r.some((c) => c.trim() !== ""));
  if (nonEmpty.length === 0) return { headers: [], rows: [] };

  const headers = nonEmpty[0].map((h) => h.trim());
  const rows = nonEmpty.slice(1).map((r) => {
    const obj: Record<string, string> = {};
    headers.forEach((h, idx) => (obj[h] = (r[idx] ?? "").trim()));
    return obj;
  });
  return { headers, rows };
}
