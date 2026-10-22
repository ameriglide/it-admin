import { test, expect } from "bun:test";
import { agentSidsToClear } from "../src/offboard/lib/phenix-agent";

const email = "test.user@example.com";

test("agentSidsToClear returns the one agent row that still has a sid", () => {
  expect(agentSidsToClear(email, [{ id: 7, sid: "WK123" }])).toEqual([{ id: 7, sid: "WK123" }]);
});

test("agentSidsToClear returns nothing when the sid is already null", () => {
  expect(agentSidsToClear(email, [{ id: 7, sid: null }])).toEqual([]);
});

test("agentSidsToClear returns nothing when there is no agent row", () => {
  expect(agentSidsToClear(email, [])).toEqual([]);
});

test("agentSidsToClear ignores an older row whose sid is already null", () => {
  const rows = [
    { id: 3, sid: null },
    { id: 7, sid: "WK123" },
  ];
  expect(agentSidsToClear(email, rows)).toEqual([{ id: 7, sid: "WK123" }]);
});

test("agentSidsToClear refuses when two rows for the email both carry a sid", () => {
  const rows = [
    { id: 3, sid: "WKold" },
    { id: 7, sid: "WK123" },
  ];
  expect(() => agentSidsToClear(email, rows)).toThrow(/ids 3, 7/);
});
