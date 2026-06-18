import { describe, expect, test } from "bun:test";
import { parseRoles, resolveGroupAddress } from "../src/lib/google-groups";

describe("resolveGroupAddress", () => {
  test("bare token expands to localpart@domain", () => {
    expect(resolveGroupAddress("sales-staff", "ameriglide.com")).toBe(
      "sales-staff@ameriglide.com",
    );
  });
  test("trailing-@ token expands to localpart@domain", () => {
    expect(resolveGroupAddress("sales-staff@", "ameriglide.com")).toBe(
      "sales-staff@ameriglide.com",
    );
  });
  test("full address passes through unchanged", () => {
    expect(
      resolveGroupAddress("marketing@ameriglide-lexington-ky.com", "ameriglide.com"),
    ).toBe("marketing@ameriglide-lexington-ky.com");
  });
  test("honors an alternate domain", () => {
    expect(resolveGroupAddress("staff@", "inetalliance.net")).toBe(
      "staff@inetalliance.net",
    );
  });
  test("trims surrounding whitespace", () => {
    expect(resolveGroupAddress("  staff@  ", "ameriglide.com")).toBe(
      "staff@ameriglide.com",
    );
  });
});

describe("parseRoles", () => {
  test("parses a valid role map", () => {
    const r = parseRoles('{"Sales Rep":["staff@","sales-staff@"]}');
    expect(r).toEqual({ "Sales Rep": ["staff@", "sales-staff@"] });
  });
  test("undefined returns empty object", () => {
    expect(parseRoles(undefined)).toEqual({});
  });
  test("whitespace-only returns empty object", () => {
    expect(parseRoles("   ")).toEqual({});
  });
  test("invalid JSON throws", () => {
    expect(() => parseRoles("{not json")).toThrow(/not valid JSON/);
  });
  test("non-object (array) throws", () => {
    expect(() => parseRoles('["a","b"]')).toThrow();
  });
  test("non-string-array value throws", () => {
    expect(() => parseRoles('{"Role":[1,2]}')).toThrow();
  });
});
