import { test, expect, describe } from "bun:test";
import { preflight } from "../src/onboard/lib/preflight";
import { planAutoSkips } from "../src/onboard/lib/auto-skips";
import { isClientError, orgUnitPath } from "../src/onboard/steps/google";

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

type Flags = { extension?: string; sonarCallCenter?: string; sales?: boolean };

// What run() passes: the user's skip list plus planAutoSkips' additions.
const result = (env: Env, flags: Flags = {}, userSkip: string[] = []) =>
  preflight(env, flags, planAutoSkips(env, userSkip).skip);

// Problems only (most tests).
const check = (env: Env, extension?: string, userSkip: string[] = []) =>
  result(env, { extension }, userSkip).problems;

describe("preflight", () => {
  test.each([
    ["AMBERJACK_DATABASE_URL", "Amberjack"],
    ["PHENIX_DATABASE_URL", "Phenix"],
  ])("AmeriGlide missing %s is a problem", (key) => {
    const problems = check(without(ameriglide, key));
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain(key);
  });

  test.each([
    ["AMBERJACK_DATABASE_URL", "amberjack"],
    ["PHENIX_DATABASE_URL", "phenix"],
  ])("AmeriGlide missing %s is fine when that step is skipped", (key, step) => {
    expect(check(without(ameriglide, key), undefined, [step])).toEqual([]);
  });

  test("PBX runs, Sonar skipped, no --extension: a problem", () => {
    const problems = check(iai, undefined, ["sonar"]);
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain("--extension is required when the Sonar step is skipped");
  });

  test("PBX runs, Sonar skipped, with --extension: fine", () => {
    expect(check(iai, "9001", ["sonar"])).toEqual([]);
  });

  test("Sonar runs without --extension: fine (Sonar settles it)", () => {
    expect(check(iai)).toEqual([]);
  });

  describe("warnings", () => {
    test("none for a clean run", () => {
      expect(result(ameriglide).warnings).toEqual([]);
      expect(result(iai, { extension: "9001" }).warnings).toEqual([]);
    });

    test("Sonar/PBX flags on ameriglide.com have no effect", () => {
      const { problems, warnings } = result(ameriglide, {
        extension: "9001",
        sonarCallCenter: "Main",
        sales: false,
      });
      expect(problems).toEqual([]);
      expect(warnings).toEqual([
        "--extension/--call-center/--no-sales have no effect: Sonar and PBX do not run for ameriglide.com",
      ]);
    });

    test("a single ignored flag uses 'has'", () => {
      expect(result(ameriglide, { sonarCallCenter: "Main" }).warnings).toEqual([
        "--call-center has no effect: Sonar and PBX do not run for ameriglide.com",
      ]);
    });

    test("sales undefined (the default) is not an ignored flag", () => {
      expect(result(ameriglide, { sales: undefined }).warnings).toEqual([]);
    });

    test("no ignored-flag warning when Sonar runs", () => {
      expect(result(iai, { extension: "9001", sonarCallCenter: "Main" }, ["pbx"]).warnings).toEqual(
        [],
      );
    });

    test("Sonar skipped on IAI: --call-center/--no-sales warned, --extension not (PBX uses it)", () => {
      const { problems, warnings } = result(
        iai,
        { extension: "9001", sonarCallCenter: "Main", sales: false },
        ["sonar"],
      );
      expect(problems).toEqual([]);
      expect(warnings).toEqual([
        "--call-center/--no-sales have no effect: the Sonar step is skipped",
      ]);
    });

    test("Sonar and PBX both skipped on IAI: the cause is the skip, not the tenant", () => {
      expect(
        result(iai, { extension: "9001", sonarCallCenter: "Main" }, ["sonar", "pbx"]).warnings,
      ).toEqual(["--extension/--call-center have no effect: the Sonar and PBX steps are skipped"]);
    });

    test("off ameriglide.com, a set TWILIO_ACCOUNT_SID names the Twilio steps that run", () => {
      const env = { ...iai, TWILIO_ACCOUNT_SID: "AC123" };
      const { problems, warnings } = result(env);
      expect(problems).toEqual([]);
      expect(warnings).toHaveLength(1);
      expect(warnings[0]).toContain("inetalliance.net");
      expect(warnings[0]).toContain("Twilio/Direct Line/Zoiper Config (TWILIO_ACCOUNT_SID)");
    });

    test("off ameriglide.com, skipped Twilio steps are left out of the warning", () => {
      const env = { ...iai, TWILIO_ACCOUNT_SID: "AC123" };
      expect(result(env, {}, ["twilio", "zoiper"]).warnings).toEqual([
        "tenant is inetalliance.net, but these AmeriGlide steps will run because their env is set: " +
          "Direct Line (TWILIO_ACCOUNT_SID); if that is a leftover AmeriGlide value, unset it or --skip the step",
      ]);
      expect(result(env, {}, ["twilio", "directline", "zoiper"]).warnings).toEqual([]);
    });

    test("on ameriglide.com, TWILIO_ACCOUNT_SID is not warned about", () => {
      expect(result({ ...ameriglide, TWILIO_ACCOUNT_SID: "AC123" }).warnings).toEqual([]);
    });

    test("off ameriglide.com, a set AMBERJACK/PHENIX URL is named", () => {
      const env = {
        ...iai,
        AMBERJACK_DATABASE_URL: "postgres://amberjack",
        PHENIX_DATABASE_URL: "postgres://phenix",
      };
      const { problems, warnings } = result(env);
      expect(problems).toEqual([]);
      expect(warnings).toHaveLength(1);
      expect(warnings[0]).toContain("inetalliance.net");
      expect(warnings[0]).toContain("Amberjack (AMBERJACK_DATABASE_URL)");
      expect(warnings[0]).toContain("Phenix (PHENIX_DATABASE_URL)");
    });

    test("off ameriglide.com, a skipped Amberjack is not warned about", () => {
      const env = { ...iai, AMBERJACK_DATABASE_URL: "postgres://amberjack" };
      expect(result(env, {}, ["amberjack"]).warnings).toEqual([]);
    });
  });

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
    const mentions = (needle: string) => problems.filter((p) => p.includes(needle)).length;
    expect(mentions("SONAR_DATABASE_URL")).toBe(1);
    expect(mentions("PBX_HOST")).toBe(1);
    expect(mentions("missing: PBX_OP_ITEM")).toBe(1);
    expect(mentions("ONBOARD_ORG_UNIT_PATH")).toBe(1);
    expect(mentions('--extension "12" is not four digits')).toBe(1);
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

  test.each([",", "  ", " , ,"])(
    "PBX_ENABLED_EXTENSIONS %j (set, lists nothing) is a problem",
    (value) => {
      const problems = check({ ...iai, PBX_ENABLED_EXTENSIONS: value }, "9001");
      expect(problems).toEqual(["PBX_ENABLED_EXTENSIONS is set but lists no extensions"]);
    },
  );

  test("empty PBX_ENABLED_EXTENSIONS is unset, not a problem", () => {
    expect(check({ ...iai, PBX_ENABLED_EXTENSIONS: "" }, "9001")).toEqual([]);
  });

  test("blank PBX_ENABLED_EXTENSIONS is not checked when Sonar and PBX do not run", () => {
    expect(check({ ...ameriglide, PBX_ENABLED_EXTENSIONS: "," })).toEqual([]);
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

// The Google step clears the recorded temp password only on a 4xx (no account
// was created); other failures keep it so run() prints it.
describe("isClientError", () => {
  test.each([400, 404, 409, 499, "409"])("%p is a client error", (code) => {
    expect(isClientError({ code })).toBe(true);
  });

  test("response.status is used when code is absent", () => {
    expect(isClientError({ response: { status: 403 } })).toBe(true);
  });

  test.each([
    ["5xx", { code: 503 }],
    ["network error", { code: "ECONNRESET" }],
    ["no status", new Error("boom")],
    ["null", null],
    ["empty string", { code: "" }],
  ])("%s is not a client error", (_name, e) => {
    expect(isClientError(e)).toBe(false);
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
