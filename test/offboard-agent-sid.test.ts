import { test, expect } from "bun:test";
import { planWorkerTeardown, assertOneRowCleared } from "../src/offboard/lib/phenix-agent";

const email = "test.user@example.com";

test("planWorkerTeardown deletes the worker and clears the matching sid", () => {
  expect(planWorkerTeardown(email, "WK123", [{ id: 7, sid: "WK123" }])).toEqual({
    deleteSids: ["WK123"],
    clear: { id: 7, sid: "WK123" },
    problem: null,
  });
});

test("planWorkerTeardown deletes agent.sid itself when the email lookup finds no worker", () => {
  // The email lookup can miss a worker with older naming; the sid is cleared
  // only after that exact sid is deleted (a 404 there means already gone).
  expect(planWorkerTeardown(email, null, [{ id: 7, sid: "WK123" }])).toEqual({
    deleteSids: ["WK123"],
    clear: { id: 7, sid: "WK123" },
    problem: null,
  });
});

test("planWorkerTeardown still deletes the worker when the agent row has no sid", () => {
  expect(planWorkerTeardown(email, "WK123", [{ id: 7, sid: null }])).toEqual({
    deleteSids: ["WK123"],
    clear: null,
    problem: null,
  });
});

test("planWorkerTeardown has nothing to do when there is no worker and no sid", () => {
  expect(planWorkerTeardown(email, null, [])).toEqual({ deleteSids: [], clear: null, problem: null });
  expect(planWorkerTeardown(email, null, [{ id: 7, sid: null }])).toEqual({
    deleteSids: [],
    clear: null,
    problem: null,
  });
});

test("planWorkerTeardown treats an empty sid as no sid", () => {
  expect(planWorkerTeardown(email, null, [{ id: 7, sid: "" }])).toEqual({
    deleteSids: [],
    clear: null,
    problem: null,
  });
});

test("planWorkerTeardown ignores an older row whose sid is already null", () => {
  const rows = [
    { id: 3, sid: null },
    { id: 7, sid: "WK123" },
  ];
  expect(planWorkerTeardown(email, "WK123", rows).clear).toEqual({ id: 7, sid: "WK123" });
});

test("planWorkerTeardown refuses to clear when the email worker and agent.sid disagree", () => {
  const plan = planWorkerTeardown(email, "WKA", [{ id: 7, sid: "WKB" }]);
  expect(plan.deleteSids).toEqual(["WKA"]);
  expect(plan.clear).toBeNull();
  expect(plan.problem).toMatch(/WKA.*agent 7.*WKB/);
});

test("planWorkerTeardown refuses to clear when two rows for the email both carry a sid", () => {
  const rows = [
    { id: 3, sid: "WKold" },
    { id: 7, sid: "WK123" },
  ];
  const plan = planWorkerTeardown(email, "WK123", rows);
  expect(plan.deleteSids).toEqual(["WK123"]);
  expect(plan.clear).toBeNull();
  expect(plan.problem).toMatch(/ids 3, 7/);
});

test("assertOneRowCleared accepts exactly one updated row", () => {
  expect(() => assertOneRowCleared(1, { id: 7, sid: "WK123" })).not.toThrow();
});

test("assertOneRowCleared throws when the compare-and-set matched nothing", () => {
  expect(() => assertOneRowCleared(0, { id: 7, sid: "WK123" })).toThrow(/agent 7.*updated 0 rows/);
});
