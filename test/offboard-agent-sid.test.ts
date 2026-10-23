import { test, expect } from "bun:test";
import {
  planWorkerTeardown,
  sidToVerify,
  teardownDone,
  assertOneRowCleared,
} from "../src/offboard/lib/phenix-agent";
import { workerMatchesEmail } from "../src/onboard/lib/twilio";

const email = "test.user@example.com";
const row = { id: 7, sid: "WK123" };

test("planWorkerTeardown deletes the worker and clears the matching sid", () => {
  expect(planWorkerTeardown(email, "WK123", [row], null)).toEqual({
    deleteSids: ["WK123"],
    clear: row,
    alreadyGone: null,
    problem: null,
  });
});

test("planWorkerTeardown deletes agent.sid's worker when TaskRouter says it is ours", () => {
  // The email lookup can miss a worker; agent.sid's worker is looked up directly.
  expect(planWorkerTeardown(email, null, [row], "ours")).toEqual({
    deleteSids: ["WK123"],
    clear: row,
    alreadyGone: null,
    problem: null,
  });
});

test("planWorkerTeardown deletes both workers when the email worker and agent.sid differ but both are ours", () => {
  expect(planWorkerTeardown(email, "WKA", [row], "ours").deleteSids).toEqual(["WKA", "WK123"]);
});

test("planWorkerTeardown clears without deleting when agent.sid is already gone", () => {
  expect(planWorkerTeardown(email, null, [row], "absent")).toEqual({
    deleteSids: [],
    clear: row,
    alreadyGone: "WK123",
    problem: null,
  });
});

test("planWorkerTeardown never deletes or clears a live worker that belongs to someone else", () => {
  const plan = planWorkerTeardown(email, "WKA", [row], "foreign");
  expect(plan.deleteSids).toEqual(["WKA"]);
  expect(plan.clear).toBeNull();
  expect(plan.problem).toMatch(/agent 7.*WK123.*does not match/);
});

test("a refused agent.sid stays refused on the re-run after the email worker is deleted", () => {
  // Run 1 deletes WKA; run 2 finds no email worker but agent.sid still points
  // at the same foreign worker, so the plan must still refuse.
  const rerun = planWorkerTeardown(email, null, [row], "foreign");
  expect(rerun.deleteSids).toEqual([]);
  expect(rerun.clear).toBeNull();
  expect(rerun.problem).not.toBeNull();
  expect(teardownDone(rerun, false)).toBe(false);
});

test("planWorkerTeardown refuses to plan an unverified agent.sid", () => {
  expect(() => planWorkerTeardown(email, null, [row], null)).toThrow(/not looked up/);
});

test("planWorkerTeardown still deletes the worker when the agent row has no sid", () => {
  expect(planWorkerTeardown(email, "WK123", [{ id: 7, sid: null }], null)).toEqual({
    deleteSids: ["WK123"],
    clear: null,
    alreadyGone: null,
    problem: null,
  });
});

test("planWorkerTeardown has nothing to do with no worker, no row, or an empty sid", () => {
  const nothing = { deleteSids: [], clear: null, alreadyGone: null, problem: null };
  expect(planWorkerTeardown(email, null, [], null)).toEqual(nothing);
  expect(planWorkerTeardown(email, null, [{ id: 7, sid: null }], null)).toEqual(nothing);
  expect(planWorkerTeardown(email, null, [{ id: 7, sid: "" }], null)).toEqual(nothing);
});

test("planWorkerTeardown ignores an older row whose sid is already null", () => {
  const rows = [{ id: 3, sid: null }, row];
  expect(planWorkerTeardown(email, "WK123", rows, null).clear).toEqual(row);
});

test("planWorkerTeardown refuses to clear when two rows carry a sid, and lists every sid", () => {
  const rows = [{ id: 3, sid: "WKold" }, row];
  const plan = planWorkerTeardown(email, "WK123", rows, null);
  expect(plan.deleteSids).toEqual(["WK123"]);
  expect(plan.clear).toBeNull();
  expect(plan.problem).toMatch(/agent 3: WKold, agent 7: WK123/);
});

test("sidToVerify returns agent.sid only when the email lookup did not return it", () => {
  expect(sidToVerify(null, [row])).toBe("WK123");
  expect(sidToVerify("WKA", [row])).toBe("WK123");
  expect(sidToVerify("WK123", [row])).toBeNull();
  expect(sidToVerify(null, [{ id: 7, sid: null }])).toBeNull();
  expect(sidToVerify(null, [{ id: 3, sid: "WKold" }, row])).toBeNull();
});

test("teardownDone needs no credential, nothing to delete or clear, and no problem", () => {
  const clean = { deleteSids: [], clear: null, alreadyGone: null, problem: null };
  expect(teardownDone(clean, false)).toBe(true);
  expect(teardownDone(clean, true)).toBe(false);
  expect(teardownDone({ ...clean, deleteSids: ["WK1"] }, false)).toBe(false);
  expect(teardownDone({ ...clean, clear: row }, false)).toBe(false);
  expect(teardownDone({ ...clean, problem: "x" }, false)).toBe(false);
});

test("assertOneRowCleared accepts exactly one updated row", () => {
  expect(() => assertOneRowCleared(1, row)).not.toThrow();
});

test("assertOneRowCleared throws when the compare-and-set matched nothing", () => {
  expect(() => assertOneRowCleared(0, row)).toThrow(/agent 7.*updated 0 rows/);
});

test("workerMatchesEmail matches attributes.email case-insensitively", () => {
  const w = { sid: "WK1", attributes: JSON.stringify({ email: "Test.User@Example.com" }) };
  expect(workerMatchesEmail(w, email)).toBe(true);
  expect(workerMatchesEmail(w, "someone.else@example.com")).toBe(false);
});

test("workerMatchesEmail falls back to friendly_name only when there is no attributes.email", () => {
  expect(workerMatchesEmail({ sid: "WK1", friendly_name: "Test User", attributes: "{}" }, email)).toBe(true);
  const other = { sid: "WK1", friendly_name: "Test User", attributes: JSON.stringify({ email: "x@example.com" }) };
  expect(workerMatchesEmail(other, email)).toBe(false);
});

test("workerMatchesEmail falls back to friendly_name when attributes are missing, not JSON, or null", () => {
  expect(workerMatchesEmail({ sid: "WK1", friendly_name: "Test User" }, email)).toBe(true);
  expect(workerMatchesEmail({ sid: "WK1", friendly_name: "Test User", attributes: "not json" }, email)).toBe(true);
  expect(workerMatchesEmail({ sid: "WK1", friendly_name: "Test User", attributes: "null" }, email)).toBe(true);
  expect(workerMatchesEmail({ sid: "WK1", friendly_name: "Someone Else", attributes: "not json" }, email)).toBe(false);
});

test("workerMatchesEmail ignores a non-string attributes.email instead of throwing", () => {
  const w = { sid: "WK1", friendly_name: "Test User", attributes: JSON.stringify({ email: 42 }) };
  expect(workerMatchesEmail(w, email)).toBe(true);
});
