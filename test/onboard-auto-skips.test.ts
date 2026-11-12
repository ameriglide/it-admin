import { test, expect, describe } from "bun:test";
import {
  isAmeriGlide,
  planAutoSkips,
  stepKey,
  tenantDomain,
} from "../src/onboard/lib/auto-skips";
// DB getters are lazy, so importing the step list opens no connections.
import { steps } from "../src/onboard/run";

const ameriglide = {
  AMBERJACK_DATABASE_URL: "postgres://amberjack",
  PHENIX_DATABASE_URL: "postgres://phenix",
  TWILIO_ACCOUNT_SID: "AC123",
  ONBOARD_ROLES: "sales:a@x",
  MEM0_API_KEY: "m0-key",
};

const iai = {
  DOMAIN: "inetalliance.net",
  SONAR_DATABASE_URL: "postgres://sonar",
  PBX_HOST: "pbx.example",
  ONBOARD_ROLES: "sales:a@x",
  MEM0_API_KEY: "m0-key",
};

const without = (env: Record<string, string>, key: string) => {
  const { [key]: _, ...rest } = env;
  return rest;
};

const sorted = (xs: string[]) => [...xs].sort();

describe("planAutoSkips", () => {
  test.each([
    ["AmeriGlide, fully configured", ameriglide, ["pbx", "sonar"]],
    [
      "AmeriGlide, PHENIX_DATABASE_URL missing: phenix still runs (fails loudly)",
      without(ameriglide, "PHENIX_DATABASE_URL"),
      ["pbx", "sonar"],
    ],
    [
      "AmeriGlide, AMBERJACK_DATABASE_URL missing: amberjack still runs (fails loudly)",
      without(ameriglide, "AMBERJACK_DATABASE_URL"),
      ["pbx", "sonar"],
    ],
    [
      "AmeriGlide via explicit DOMAIN",
      { ...ameriglide, DOMAIN: "ameriglide.com" },
      ["pbx", "sonar"],
    ],
    [
      "IAI, fully configured",
      iai,
      ["amberjack", "directline", "orgdirectory", "phenix", "twilio", "zoiper"],
    ],
    [
      "IAI without ONBOARD_ROLES",
      without(iai, "ONBOARD_ROLES"),
      ["amberjack", "directline", "googlegroups", "orgdirectory", "phenix", "twilio", "zoiper"],
    ],
    [
      "IAI, SONAR_DATABASE_URL missing: sonar still runs (fails loudly)",
      without(iai, "SONAR_DATABASE_URL"),
      ["amberjack", "directline", "orgdirectory", "phenix", "twilio", "zoiper"],
    ],
    [
      "IAI, PBX_HOST missing: pbx still runs (fails loudly)",
      without(iai, "PBX_HOST"),
      ["amberjack", "directline", "orgdirectory", "phenix", "twilio", "zoiper"],
    ],
    [
      "IAI with AMBERJACK/PHENIX URLs explicitly set: both run",
      {
        ...iai,
        AMBERJACK_DATABASE_URL: "postgres://amberjack",
        PHENIX_DATABASE_URL: "postgres://phenix",
      },
      ["directline", "orgdirectory", "twilio", "zoiper"],
    ],
    [
      'DOMAIN="" is treated as AmeriGlide',
      { ...ameriglide, DOMAIN: "" },
      ["pbx", "sonar"],
    ],
    [
      'DOMAIN="AmeriGlide.com" (cased) is treated as AmeriGlide',
      { ...ameriglide, DOMAIN: "AmeriGlide.com" },
      ["pbx", "sonar"],
    ],
    [
      'DOMAIN=" ameriglide.com " (padded) is treated as AmeriGlide',
      { ...ameriglide, DOMAIN: " ameriglide.com " },
      ["pbx", "sonar"],
    ],
    [
      "AmeriGlide without MEM0_API_KEY skips orgdirectory",
      without(ameriglide, "MEM0_API_KEY"),
      ["orgdirectory", "pbx", "sonar"],
    ],
  ])("%s", (_name, env, expected) => {
    expect(sorted(planAutoSkips(env, []).skip)).toEqual(sorted(expected));
  });

  test("one note per auto-skip group", () => {
    expect(planAutoSkips(ameriglide, []).notes).toEqual([
      "  (sonar, pbx: not used for ameriglide.com)",
    ]);
    expect(planAutoSkips(iai, []).notes).toEqual([
      "  (AMBERJACK_DATABASE_URL unset - skipping Amberjack)",
      "  (PHENIX_DATABASE_URL unset - skipping Phenix)",
      "  (TWILIO_ACCOUNT_SID unset - skipping Twilio, Direct Line, Zoiper)",
      "  (MEM0_API_KEY unset or tenant is not ameriglide.com - skipping Org directory)",
    ]);
  });

  test("user skip entries are preserved first, without duplicates", () => {
    const { skip } = planAutoSkips(ameriglide, ["google", "sonar", "google"]);
    expect(skip).toEqual(["google", "sonar", "pbx"]);
  });

  test("an already-skipped group adds no note", () => {
    expect(planAutoSkips(ameriglide, ["sonar", "pbx"]).notes).toEqual([]);
  });

  test("does not mutate the input array", () => {
    const userSkip = ["google"];
    const { skip } = planAutoSkips(iai, userSkip);
    expect(userSkip).toEqual(["google"]);
    expect(skip).not.toBe(userSkip);
  });
});

describe("tenantDomain / isAmeriGlide", () => {
  test.each([
    [{}, "ameriglide.com", true],
    [{ DOMAIN: "" }, "ameriglide.com", true],
    [{ DOMAIN: "   " }, "ameriglide.com", true],
    [{ DOMAIN: "AmeriGlide.com" }, "ameriglide.com", true],
    [{ DOMAIN: " inetalliance.net " }, "inetalliance.net", false],
  ])("%j -> %s", (env, domain, ag) => {
    expect(tenantDomain(env)).toBe(domain);
    expect(isAmeriGlide(env)).toBe(ag);
  });
});

test("auto-skip keys match real step keys", () => {
  const keys = new Set(steps.map((s) => stepKey(s.name)));
  const all = new Set([
    ...planAutoSkips({}, []).skip,
    ...planAutoSkips({ DOMAIN: "inetalliance.net" }, []).skip,
  ]);
  for (const k of all) {
    expect([...keys].some((key) => key === k || key.startsWith(k))).toBe(true);
  }
});

test("no step key is a prefix of another (run() matches with startsWith)", () => {
  const keys = steps.map((s) => stepKey(s.name));
  for (const a of keys) {
    for (const b of keys) {
      if (a !== b) expect(b.startsWith(a)).toBe(false);
    }
  }
});
