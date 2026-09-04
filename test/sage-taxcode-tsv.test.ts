import { describe, expect, test } from "bun:test";
import { parseDump } from "../src/sage-taxcode/tsv";

const sample = [
  "##### SY_SalesTaxCode",
  "TaxCode\tTaxCodeDesc\tTaxCodeShortDesc",
  "TX BELL COUNTY\tTX BELL COUNTY\tTX BEL",
  "AZ MESA\tAZ MESA\tAZ MES",
  "##### SY_SalesTaxCodeDetail",
  "TaxCode\tTaxClass\tTaxRate",
  "TX BELL COUNTY\tTX\t2.000000",
  "##### VI_JobImportSelection",
  "!ERROR\t[ProvideX][ODBC Driver][FILEIO]Table is not accessible",
  "",
].join("\r\n");

describe("parseDump", () => {
  test("splits sections by the ##### marker and keys rows by column name", () => {
    const t = parseDump(sample);
    expect([...t.keys()]).toEqual(["SY_SalesTaxCode", "SY_SalesTaxCodeDetail", "VI_JobImportSelection"]);
    const codes = t.get("SY_SalesTaxCode")!;
    expect(codes.columns).toEqual(["TaxCode", "TaxCodeDesc", "TaxCodeShortDesc"]);
    expect(codes.rows).toHaveLength(2);
    expect(codes.rows[1]).toEqual({ TaxCode: "AZ MESA", TaxCodeDesc: "AZ MESA", TaxCodeShortDesc: "AZ MES" });
  });
  test("records a section error instead of rows", () => {
    const t = parseDump(sample);
    const vi = t.get("VI_JobImportSelection")!;
    expect(vi.rows).toEqual([]);
    expect(vi.error).toContain("Table is not accessible");
  });
  test("tolerates LF-only line endings and a trailing blank line", () => {
    const t = parseDump(sample.replace(/\r\n/g, "\n"));
    expect(t.get("SY_SalesTaxCodeDetail")!.rows[0].TaxRate).toBe("2.000000");
  });
  test("pads short rows with empty strings", () => {
    const t = parseDump("##### T\nA\tB\tC\nx\ty\n");
    expect(t.get("T")!.rows[0]).toEqual({ A: "x", B: "y", C: "" });
  });
  test("throws on text before the first marker", () => {
    expect(() => parseDump("garbage\n##### T\nA\n")).toThrow(/before the first/);
  });
});
