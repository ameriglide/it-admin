import { describe, expect, test } from "bun:test";
import { parseDump } from "../src/sage-taxcode/tsv";
import { buildPlan, sameValue } from "../src/sage-taxcode/diff";

const HEADER_COLS = "TaxCode\tTaxCodeDesc\tTaxCodeShortDesc\tTaxOnTax\tTaxClassForTaxOnTax\tTaxLimit\tExpenseToVendorItem\tRetentionTaxable";
const LINE_COLS = "TaxCode\tTaxClass\tSalesTaxable\tPurchasesTaxable\tTaxRate\tNonRecoverablePercent";
const VI_COLS = "JobName\tJobType\tLastCompanyCode\tTableName\tJobLongDescription";

function dump(parts: { headers: string[]; lines: string[]; vi?: string[]; viImport?: string[]; viExport?: string[]; viExportSel?: string[]; viImportSel?: string[] | "error" }): string {
  const out = ["##### SY_SalesTaxCode", HEADER_COLS, ...parts.headers,
    "##### SY_SalesTaxCodeDetail", LINE_COLS, ...parts.lines,
    "##### SY_SalesTaxClass", "TaxClass\tTaxClassDesc", "TX\tTaxable", "TF\tTaxable Freight", "NT\tNon Taxable",
    "##### VI_JobHeader", VI_COLS, ...(parts.vi ?? []),
    "##### VI_JobImportElements", "JobName\tSequenceNo", ...(parts.viImport ?? []),
    "##### VI_JobExportElements", "JobName\tSequenceNo", ...(parts.viExport ?? []),
    "##### VI_JobExportSelection", "JobName\tSequenceNo", ...(parts.viExportSel ?? []),
    "##### VI_JobImportSelection"];
  if (parts.viImportSel === "error") out.push("!ERROR\tTable is not accessible");
  else out.push("JobName\tSequenceNo", ...(parts.viImportSel ?? []));
  return out.join("\n") + "\n";
}

const h = (code: string, desc = code) => `${code}\t${desc}\t${code.slice(0, 6)}\tN\t\t0.000000\tN\tN`;
const l = (code: string, cls: string, sales: string, rate: string) => `${code}\t${cls}\t${sales}\tN\t${rate}\t0.000`;

const snapshot = parseDump(dump({
  headers: [h("AL"), h("AZ MESA"), h("TX BELL COUNTY"), h("ZZ ORPHANLESS")],
  lines: [l("AL", "TX", "Y", "4.000000"), l("AZ MESA", "TX", "Y", "2.000000"), l("AZ MESA", "TF", "N", "0.000000"),
    l("TX BELL COUNTY", "TX", "Y", "2.000000"), l("TX BELL COUNTY", "TF", "Y", "2.000000"), l("GHOST", "TX", "Y", "1.000000")],
  vi: ["EXP_TAX\tX\tAD1\tSY_SalesTaxCodeDetail\t", "OLD_JOB\tI\tAD1\tCI_Item\told"],
  viExport: ["EXP_TAX\t1", "EXP_TAX\t2", "EXP_TAX\t3"], viExportSel: ["EXP_TAX\t1"], viImportSel: "error",
}));
const live = parseDump(dump({
  headers: [h("AL"), h("AZ MESA"), h("MO ODESSA")],
  lines: [l("AL", "TX", "Y", "4.000000"), l("AZ MESA", "TX", "Y", "2.000000"), l("AZ MESA", "TF", "Y", "2"), l("MO ODESSA", "TX", "Y", "2.500000")],
  vi: ["OLD_JOB\tI\tAD1\tCI_Item\told"], viImportSel: "error",
}));
const plan = buildPlan(snapshot, live, { snapshotFile: "s.tsv", liveFile: "l.tsv", now: new Date("2026-09-04T18:00:00Z") });

describe("sameValue", () => {
  test("numeric columns compare as numbers", () => {
    expect(sameValue("TaxRate", "2.000000", "2")).toBe(true);
    expect(sameValue("TaxRate", "2.000000", "2.25")).toBe(false);
  });
  test("text columns compare exactly", () => {
    expect(sameValue("SalesTaxable", "Y", "N")).toBe(false);
    expect(sameValue("TaxCodeDesc", "a", "a")).toBe(true);
  });
});

describe("buildPlan", () => {
  test("headers missing on live are added, live-only headers are reported", () => {
    expect(plan.addHeaders.map((x) => x.TaxCode)).toEqual(["TX BELL COUNTY", "ZZ ORPHANLESS"]);
    expect(plan.liveOnlyHeaders.map((x) => x.TaxCode)).toEqual(["MO ODESSA"]);
    expect(plan.changedHeaders).toEqual([]);
  });
  test("lines under an added header are added; lines under a header on neither side are orphans", () => {
    expect(plan.addLines.map((x) => `${x.TaxCode}/${x.TaxClass}`)).toEqual(["TX BELL COUNTY/TF", "TX BELL COUNTY/TX"]);
    expect(plan.orphanLines.map((x) => x.TaxCode)).toEqual(["GHOST"]);
  });
  test("lines on both sides with different values become updates with the changed columns named", () => {
    expect(plan.updateLines).toHaveLength(1);
    const u = plan.updateLines[0];
    expect(u.key).toEqual({ TaxCode: "AZ MESA", TaxClass: "TF" });
    expect(u.changed.sort()).toEqual(["SalesTaxable", "TaxRate"]);
    expect(u.to.TaxRate).toBe("0.000000");
  });
  test("live-only lines are reported", () => {
    expect(plan.liveOnlyLines.map((x) => x.TaxCode)).toEqual(["MO ODESSA"]);
  });
  test("VI jobs missing on live carry element counts; an inaccessible selection table counts as 0", () => {
    expect(plan.viJobsMissing).toHaveLength(1);
    expect(plan.viJobsMissing[0].JobName).toBe("EXP_TAX");
    expect(plan.viJobsMissing[0].elementCounts).toEqual({ VI_JobImportElements: 0, VI_JobExportElements: 3, VI_JobExportSelection: 1, VI_JobImportSelection: 0 });
  });
  test("stamps metadata", () => {
    expect(plan.generatedAt).toBe("2026-09-04T18:00:00.000Z");
    expect(plan.snapshotFile).toBe("s.tsv");
  });
  test("throws when a required table failed to dump", () => {
    const broken = parseDump("##### SY_SalesTaxCode\n!ERROR\tboom\n##### SY_SalesTaxCodeDetail\n" + LINE_COLS + "\n##### VI_JobHeader\n" + VI_COLS + "\n");
    expect(() => buildPlan(broken, live, { snapshotFile: "s", liveFile: "l" })).toThrow(/SY_SalesTaxCode/);
  });
  test("throws when a required table is absent", () => {
    const missing = parseDump("##### SY_SalesTaxCode\n" + HEADER_COLS + "\n");
    expect(() => buildPlan(missing, live, { snapshotFile: "s", liveFile: "l" })).toThrow(/SY_SalesTaxCodeDetail/);
  });
  test("throws when a required VI element table failed on the live side", () => {
    const brokenLive = parseDump(dump({ headers: [h("AL")], lines: [l("AL", "TX", "Y", "4.000000")] }).replace("##### VI_JobExportElements\nJobName\tSequenceNo", "##### VI_JobExportElements\n!ERROR\tboom"));
    expect(() => buildPlan(snapshot, brokenLive, { snapshotFile: "s", liveFile: "l" })).toThrow(/live dump: VI_JobExportElements/);
  });
  test("a header on both sides with a different description is reported, never planned", () => {
    const liveChanged = parseDump(dump({ headers: [h("AL", "ALABAMA STATE"), h("AZ MESA"), h("MO ODESSA")], lines: [l("AL", "TX", "Y", "4.000000")] }));
    const p = buildPlan(snapshot, liveChanged, { snapshotFile: "s", liveFile: "l" });
    expect(p.changedHeaders).toHaveLength(1);
    expect(p.changedHeaders[0].key).toEqual({ TaxCode: "AL" });
    expect(p.changedHeaders[0].changed).toEqual(["TaxCodeDesc"]);
    expect(p.changedHeaders[0].to.TaxCodeDesc).toBe("AL");
    expect(p.addHeaders.map((x) => x.TaxCode)).not.toContain("AL");
  });
});
