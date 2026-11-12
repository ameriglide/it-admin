import { test, expect } from "bun:test";
import { planSonarAgent, resolveExistingExtension } from "../src/onboard/steps/sonar";

const callCenters = [
  { id: 1, name: "Main" },
  { id: 2, name: "Overflow" },
];

const base = {
  ext: "9001",
  taken: undefined,
  callCenters,
  callCenterName: "Main",
  sales: undefined,
  pbxEnabled: true as boolean | null,
};

test("resolveExistingExtension keeps the existing key when --extension is absent", () => {
  expect(resolveExistingExtension("9001", undefined)).toBe("9001");
});

test("resolveExistingExtension accepts a matching --extension", () => {
  expect(resolveExistingExtension("9001", "9001")).toBe("9001");
});

test("resolveExistingExtension throws naming both values on a mismatch", () => {
  expect(() => resolveExistingExtension("9001", "9002", "test.user@example.com")).toThrow(
    /test\.user@example\.com.*9001.*--extension 9002/,
  );
});

test("planSonarAgent builds a paused, unlocked sales agent by default", () => {
  expect(planSonarAgent(base)).toEqual({
    key: "9001",
    callCenter: { id: 1, name: "Main" },
    sales: true,
    paused: true,
    locked: false,
  });
});

test("planSonarAgent honors sales=false", () => {
  expect(planSonarAgent({ ...base, sales: false }).sales).toBe(false);
});

test("planSonarAgent throws naming the holder when the key is taken", () => {
  expect(() =>
    planSonarAgent({ ...base, taken: { firstname: "Test", lastname: "Holder" } }),
  ).toThrow(/9001 already belongs to Test Holder/);
});

test("planSonarAgent throws listing options for an unknown call center", () => {
  expect(() => planSonarAgent({ ...base, callCenterName: "Nowhere" })).toThrow(
    /Unknown call center "Nowhere".*Main, Overflow/,
  );
});

test("planSonarAgent throws when no call center was chosen", () => {
  expect(() => planSonarAgent({ ...base, callCenterName: undefined })).toThrow(
    /Unknown call center/,
  );
});

test("planSonarAgent throws when there are no call centers", () => {
  expect(() => planSonarAgent({ ...base, callCenters: [] })).toThrow(/No call centers/);
});

test("planSonarAgent refuses an extension disabled on the PBX", () => {
  expect(() => planSonarAgent({ ...base, pbxEnabled: false })).toThrow(
    /9001 is disabled on the PBX.*PBX admin.*IAI-35/,
  );
});

test("planSonarAgent proceeds when PBX enablement is unknown", () => {
  expect(planSonarAgent({ ...base, pbxEnabled: null }).key).toBe("9001");
});

test("planSonarAgent rejects an invalid extension", () => {
  expect(() => planSonarAgent({ ...base, ext: "901" })).toThrow(/not four digits/);
});
