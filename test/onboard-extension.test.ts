import { describe, expect, it, afterEach } from "bun:test";
import {
  assertValidExtension,
  enabledExtensions,
  isPbxEnabled,
} from "../src/onboard/lib/extension";

const original = process.env.PBX_ENABLED_EXTENSIONS;
afterEach(() => {
  if (original === undefined) delete process.env.PBX_ENABLED_EXTENSIONS;
  else process.env.PBX_ENABLED_EXTENSIONS = original;
});

describe("assertValidExtension", () => {
  it("accepts a four-digit extension", () => {
    expect(() => assertValidExtension("7407")).not.toThrow();
  });

  // agent.key is varchar(4): anything longer is silently truncated or rejected
  // by Postgres, and the PBX endpoint is named after the same number.
  it.each(["740", "74077", "", "74o7", "7407 "])(
    "rejects %p",
    (bad) => {
      expect(() => assertValidExtension(bad)).toThrow(/four digits/);
    },
  );
});

describe("enabledExtensions", () => {
  it("is null when unset, so the caller treats it as unknown not empty", () => {
    delete process.env.PBX_ENABLED_EXTENSIONS;
    expect(enabledExtensions()).toBeNull();
    expect(isPbxEnabled("7407")).toBeNull();
  });

  it("is null when set to only whitespace or commas", () => {
    process.env.PBX_ENABLED_EXTENSIONS = " , ,";
    expect(enabledExtensions()).toBeNull();
  });

  it("trims entries", () => {
    process.env.PBX_ENABLED_EXTENSIONS = "7014, 7230 ,7401";
    expect(enabledExtensions()).toEqual(["7014", "7230", "7401"]);
  });

  it("distinguishes enabled from disabled", () => {
    process.env.PBX_ENABLED_EXTENSIONS = "7014,7407";
    expect(isPbxEnabled("7407")).toBe(true);
    expect(isPbxEnabled("7415")).toBe(false);
  });
});
