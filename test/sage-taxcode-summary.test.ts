import { describe, expect, test } from "bun:test";
import { readFileSync } from "fs";
import { parseDump } from "../src/sage-taxcode/tsv";
import { buildPlan } from "../src/sage-taxcode/diff";
import { summarize } from "../src/sage-taxcode/summary";

const snapshot = parseDump(readFileSync("test/fixtures/sage-taxcode/snapshot.tsv", "utf8"));
const live = parseDump(readFileSync("test/fixtures/sage-taxcode/live.tsv", "utf8"));
const plan = buildPlan(snapshot, live, { snapshotFile: "s.tsv", liveFile: "l.tsv", now: new Date("2026-09-04T18:00:00Z") });

describe("fixture counts", () => {
  test("match the synthetic fixture", () => {
    expect(plan.addHeaders).toHaveLength(2);
    expect(plan.addLines).toHaveLength(4);
    expect(plan.updateLines).toHaveLength(2);
    expect(plan.liveOnlyHeaders).toHaveLength(1);
    expect(plan.viJobsMissing).toHaveLength(1);
  });
});

describe("summarize", () => {
  const text = summarize(plan);
  test("first line names the inputs", () => {
    expect(text.split("\n")[0]).toBe("sage-taxcode plan  (snapshot: s.tsv, live: l.tsv, generated 2026-09-04T18:00:00.000Z)");
  });
  test("second line tallies every bucket", () => {
    expect(text.split("\n")[1]).toBe("headers: add 2, live-only 1, changed 0   lines: add 4, update 2, live-only 3, orphan 0   VI jobs missing: 1");
  });
  test("tallies adds by state and updates by state/class", () => {
    expect(text).toContain("add headers by state: TX 1, WA 1");
    expect(text).toContain("update lines by state/class: CA TF 2");
  });
  test("lists each update with the changed columns", () => {
    expect(text).toContain("  CA FRESNO / TF: SalesTaxable Y -> N; TaxRate 0.375 -> 0.000000");
  });
  test("names missing VI jobs with element counts", () => {
    expect(text).toContain("VI jobs missing: IMP_TAX_TF (I, AD1, SY_SalesTaxCodeDetail) elements VI_JobImportElements=4");
  });
  test("says none when nothing changed", () => {
    expect(text).toContain("changed headers (NOT planned): none");
  });
  test("names VI jobs present only on live, or none", () => {
    expect(text).toContain("VI jobs only on live (would be DESTROYED by a file copy): none");
  });
  test("truncates update lines past 50, showing the first 10 and a count of the rest", () => {
    const bigPlan = {
      ...plan,
      updateLines: Array.from({ length: 51 }, (_, i) => ({
        ...plan.updateLines[0],
        key: { TaxCode: `ZZ CODE ${String(i).padStart(2, "0")}`, TaxClass: "TF" },
      })),
    };
    const bigText = summarize(bigPlan);
    const shownLines = bigText.split("\n").filter((l) => l.startsWith("  ZZ CODE "));
    expect(shownLines).toHaveLength(10);
    expect(bigText).toContain("  ... 41 more");
  });
});
