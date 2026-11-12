import { test, expect, describe } from "bun:test";
import { preflight } from "../src/onboard/lib/preflight";
import { planAutoSkips } from "../src/onboard/lib/auto-skips";
import { orgUnitPath } from "../src/onboard/steps/google";

type Env = Record<string, string | undefined>;

// No Sonar/PBX/org-unit config at all: AmeriGlide never needs it.
const ameriglide: Env = {
  AMBERJACK_DATABASE_URL: "postgres://amberjack",
  PHENIX_DATABASE_URL: "postgres://phenix",
};

const iai: Env = {
  DOMAIN: "inetalliance.net",
  SONAR_DATABASE_URL: "postgres://sonar",
  PBX_HOST: "pbx.example",
  PBX_OP_ITEM: "item",
  PBX_OP_VAULT: "vault",
  PBX_OP_ACCOUNT: "account.example",
  ONBOARD_ORG_UNIT_PATH: "/Staff",
};

const without = (env: Env, ...keys: string[]) => {
  const out = { ...env };
  for (const k of keys) delete out[k];
  return out;
};

// What run() passes: the user's skip list plus planAutoSkips' additions.
const check = (env: Env, extension?: string, userSkip: string[] = []) =>
  preflight(env, { extension }, planAutoSkips(env, userSkip).skip);

describe("preflight", () => {
  test("AmeriGlide with no Sonar/PBX/OU vars: no problems", () => {
    expect(check(ameriglide)).toEqual([]);
  });

  test("AmeriGlide ignores --extension (Sonar and PBX are auto-skipped)", () => {
    expect(check(ameriglide, "bad")).toEqual([]);
  });

  test("IAI fully configured: no problems", () => {
    expect(check(iai, "9001")).toEqual([]);
  });

  test("IAI with no PBX_OP_* at all is fine (placeholder password)", () => {
    expect(check(without(iai, "PBX_OP_ITEM", "PBX_OP_VAULT", "PBX_OP_ACCOUNT"))).toEqual([]);
  });

  test.each([
    ["SONAR_DATABASE_URL", "SONAR_DATABASE_URL"],
    ["PBX_HOST", "PBX_HOST"],
    ["ONBOARD_ORG_UNIT_PATH", "ONBOARD_ORG_UNIT_PATH"],
  ])("IAI missing %s is named", (key, expected) => {
    const problems = check(without(iai, key));
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain(expected);
  });

  test("IAI with whitespace-only ONBOARD_ORG_UNIT_PATH is a problem", () => {
    const problems = check({ ...iai, ONBOARD_ORG_UNIT_PATH: "  " });
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain("ONBOARD_ORG_UNIT_PATH");
  });

  test("partial PBX_OP_* names the missing ones", () => {
    const problems = check(without(iai, "PBX_OP_VAULT", "PBX_OP_ACCOUNT"));
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain("missing: PBX_OP_VAULT, PBX_OP_ACCOUNT");
  });

  test("every problem is reported in one pass", () => {
    const problems = check(
      without(iai, "SONAR_DATABASE_URL", "PBX_HOST", "PBX_OP_ITEM", "ONBOARD_ORG_UNIT_PATH"),
      "12",
    );
    expect(problems).toHaveLength(5);
  });

  test.each(["12", "90011", "9a01", ""])("bad --extension %j is a problem", (ext) => {
    const problems = check(iai, ext);
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain("not four digits");
  });

  test("extension not in PBX_ENABLED_EXTENSIONS is a problem", () => {
    const problems = check({ ...iai, PBX_ENABLED_EXTENSIONS: "9001, 9002" }, "9003");
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain("PBX_ENABLED_EXTENSIONS");
  });

  test("extension in PBX_ENABLED_EXTENSIONS is fine", () => {
    expect(check({ ...iai, PBX_ENABLED_EXTENSIONS: "9001, 9002" }, "9002")).toEqual([]);
  });

  test("extension check reads the env argument, not process.env", () => {
    const saved = process.env.PBX_ENABLED_EXTENSIONS;
    process.env.PBX_ENABLED_EXTENSIONS = "9001";
    try {
      expect(check(iai, "9002")).toEqual([]);
    } finally {
      if (saved === undefined) delete process.env.PBX_ENABLED_EXTENSIONS;
      else process.env.PBX_ENABLED_EXTENSIONS = saved;
    }
  });

  test("skipped steps are not checked", () => {
    const bare = { DOMAIN: "inetalliance.net", PBX_OP_ITEM: "item" };
    expect(check(bare, "bad", ["sonar", "pbx", "googleworkspace"])).toEqual([]);
  });

  test("a prefix skip entry covers the step (google -> Google Workspace)", () => {
    expect(check(without(iai, "ONBOARD_ORG_UNIT_PATH"), undefined, ["google"])).toEqual([]);
  });

  test("extension still checked when only one of sonar/pbx runs", () => {
    expect(check(iai, "12", ["sonar"])).toHaveLength(1);
    expect(check(iai, "12", ["pbx"])).toHaveLength(1);
  });
});

describe("orgUnitPath", () => {
  test("defaults to /Exempt from MFA on ameriglide.com", () => {
    expect(orgUnitPath({})).toBe("/Exempt from MFA");
    expect(orgUnitPath({ DOMAIN: "AmeriGlide.com" })).toBe("/Exempt from MFA");
  });

  test("ONBOARD_ORG_UNIT_PATH overrides on any tenant", () => {
    expect(orgUnitPath({ ONBOARD_ORG_UNIT_PATH: "/Sales" })).toBe("/Sales");
    expect(orgUnitPath({ DOMAIN: "inetalliance.net", ONBOARD_ORG_UNIT_PATH: "/Staff" })).toBe(
      "/Staff",
    );
  });

  test("throws for another tenant without ONBOARD_ORG_UNIT_PATH", () => {
    expect(() => orgUnitPath({ DOMAIN: "inetalliance.net" })).toThrow(
      "ONBOARD_ORG_UNIT_PATH must be set for tenant inetalliance.net",
    );
    expect(() => orgUnitPath({ DOMAIN: "inetalliance.net", ONBOARD_ORG_UNIT_PATH: "" })).toThrow();
  });
});
