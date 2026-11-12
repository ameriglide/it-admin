import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { makeSonarStep, type SqlLike } from "../src/onboard/steps/sonar";
import { pbxStep } from "../src/onboard/steps/pbx";
import type { Context } from "../src/onboard/types";

// Runs the Sonar step and then the PBX step on the same ctx, the way the
// onboarding runner does, to pin the hand-off between them: the extension
// Sonar settles on (prompted for a new agent, or adopted from an existing
// one) is the one the softphone sheet is built for. Extensions are fake 9xxx
// numbers; no real database or 1Password is touched.

type Response = unknown[] | ((values: unknown[]) => unknown[]);

function fakeSql(routes: [RegExp, Response][]): SqlLike {
  return (async (strings: TemplateStringsArray, ...values: unknown[]) => {
    const text = strings.join("?").replace(/\s+/g, " ").trim();
    const route = routes.find(([re]) => re.test(text));
    if (!route) throw new Error(`fakeSql: no route for: ${text}`);
    const [, res] = route;
    return typeof res === "function" ? res(values) : res;
  }) as SqlLike;
}

const CHECK_RE = /FROM agent a LEFT JOIN callcenter c .* WHERE lower\(a\.email\)/;

function sonar(routes: [RegExp, Response][], inputValue: string) {
  return makeSonarStep({
    sql: () => fakeSql(routes),
    input: async () => inputValue,
    choose: async () => "Main",
    pbxEnabled: () => true,
  });
}

function ctx(): Context {
  return {
    firstName: "Test",
    lastName: "User",
    email: "test.user@example.com",
    directLine: undefined,
  };
}

const ENV_KEYS = [
  "PBX_HOST",
  "PBX_TLS_PORT",
  "PBX_ENABLED_EXTENSIONS",
  "PBX_OP_ITEM",
  "PBX_OP_VAULT",
  "PBX_OP_ACCOUNT",
];
const savedEnv: Record<string, string | undefined> = {};
const savedCwd = process.cwd();
const savedLog = console.log;
let dir = "";

beforeEach(() => {
  for (const k of ENV_KEYS) {
    savedEnv[k] = process.env[k];
    delete process.env[k];
  }
  process.env.PBX_HOST = "pbx.example.com";
  dir = mkdtempSync(join(tmpdir(), "onboard-sonar-pbx-"));
  process.chdir(dir);
  console.log = () => {};
});

afterEach(() => {
  console.log = savedLog;
  process.chdir(savedCwd);
  rmSync(dir, { recursive: true, force: true });
  for (const k of ENV_KEYS) {
    if (savedEnv[k] === undefined) delete process.env[k];
    else process.env[k] = savedEnv[k];
  }
});

test("a prompted extension for a new Sonar agent is the one the PBX sheet is built for", async () => {
  const step = sonar(
    [
      [/^INSERT INTO agent/, []],
      [/SELECT firstname, lastname FROM agent WHERE key/, []],
      [/FROM callcenter/, [{ id: 1, name: "Main" }]],
    ],
    "9005",
  );
  const c = ctx();
  await step.run(c);
  expect(c.extension).toBe("9005");

  await pbxStep.run(c);
  expect(c.pbxAccountSheetPath).toContain("microsip-9005-");
  expect(readFileSync(c.pbxAccountSheetPath!, "utf8")).toContain("Username          9005");
});

test("an existing Sonar agent's adopted key is the one the PBX sheet is built for", async () => {
  const step = sonar(
    [[CHECK_RE, [{ key: "9006", paused: false, sales: true, callcenter_name: "Main" }]]],
    "9999", // must not be used: check() adopts the key without prompting
  );
  const c = ctx();
  expect(await step.check(c)).toBe(true);
  expect(c.extension).toBe("9006");

  await pbxStep.run(c);
  expect(c.pbxAccountSheetPath).toContain("microsip-9006-");
  expect(readFileSync(c.pbxAccountSheetPath!, "utf8")).toContain("Username          9006");
});
