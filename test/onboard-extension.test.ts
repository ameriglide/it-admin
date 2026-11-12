import { describe, expect, it, afterEach } from "bun:test";
import {
  assertValidExtension,
  enabledExtensions,
  enabledExtensionsBlank,
  isPbxEnabled,
} from "../src/onboard/lib/extension";

const original = process.env.PBX_ENABLED_EXTENSIONS;
afterEach(() => {
  if (original === undefined) delete process.env.PBX_ENABLED_EXTENSIONS;
  else process.env.PBX_ENABLED_EXTENSIONS = original;
});

describe("assertValidExtension", () => {
  it("accepts a four-digit extension", () => {
    expect(() => assertValidExtension("9007")).not.toThrow();
  });

  // agent.key is varchar(4), which rejects longer values on insert, and PBX
  // endpoints are all four-digit, so only exactly four digits is valid.
  it.each(["900", "90077", "", "90o7", "9007 "])(
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
    expect(isPbxEnabled("9007")).toBeNull();
  });

  it("is null when set to only whitespace or commas", () => {
    process.env.PBX_ENABLED_EXTENSIONS = " , ,";
    expect(enabledExtensions()).toBeNull();
  });

  it("enabledExtensionsBlank flags a set-but-empty list, not an unset one", () => {
    expect(enabledExtensionsBlank({})).toBe(false);
    expect(enabledExtensionsBlank({ PBX_ENABLED_EXTENSIONS: "" })).toBe(false);
    expect(enabledExtensionsBlank({ PBX_ENABLED_EXTENSIONS: "," })).toBe(true);
    expect(enabledExtensionsBlank({ PBX_ENABLED_EXTENSIONS: "  " })).toBe(true);
    expect(enabledExtensionsBlank({ PBX_ENABLED_EXTENSIONS: "9001" })).toBe(false);
  });

  it("trims entries", () => {
    process.env.PBX_ENABLED_EXTENSIONS = "9001, 9002 ,9003";
    expect(enabledExtensions()).toEqual(["9001", "9002", "9003"]);
  });

  it("distinguishes enabled from disabled", () => {
    process.env.PBX_ENABLED_EXTENSIONS = "9001,9007";
    expect(isPbxEnabled("9007")).toBe(true);
    expect(isPbxEnabled("9015")).toBe(false);
  });
});
