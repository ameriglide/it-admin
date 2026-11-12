import { test, expect, describe, afterEach, beforeEach, spyOn } from "bun:test";
// DB getters are lazy, so importing the runner opens no connections.
import { failureReport, run, steps } from "../src/onboard/run";
import type { Context } from "../src/onboard/types";

const baseCtx = (): Context => ({
  firstName: "Test",
  lastName: "Person",
  email: "test.person@example.com",
  directLine: false,
});

describe("failureReport", () => {
  test("lists completed steps and the temp password when one was issued", () => {
    const lines = failureReport({ ...baseCtx(), googlePassword: "Temp-9001-pw" }, [
      "Google Workspace",
      "Sonar",
    ]);
    const text = lines.join("\n");
    expect(text).toContain("Completed steps: Google Workspace, Sonar");
    expect(text).toContain("Google temp password for test.person@example.com: Temp-9001-pw");
    expect(text).toContain("NOT be shown again");
    expect(text).toContain("Re-run the same command");
  });

  test.each([
    ["null (account already existed)", null],
    ["undefined (Google step never ran)", undefined],
  ])("no password line when googlePassword is %s", (_name, pw) => {
    const text = failureReport({ ...baseCtx(), googlePassword: pw }, []).join("\n");
    expect(text).not.toContain("temp password");
    expect(text).toContain("Completed steps: none");
    expect(text).toContain("Re-run the same command");
  });
});

describe("run() preflight", () => {
  const savedEnv = { ...process.env };
  const realExit = process.exit;
  let errSpy: ReturnType<typeof spyOn>;
  let logSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    errSpy = spyOn(console, "error").mockImplementation(() => {});
    logSpy = spyOn(console, "log").mockImplementation(() => {});
  });

  afterEach(() => {
    for (const k of Object.keys(process.env)) {
      if (!(k in savedEnv)) delete process.env[k];
    }
    Object.assign(process.env, savedEnv);
    process.exit = realExit;
    errSpy.mockRestore();
    logSpy.mockRestore();
  });

  test("a configuration problem exits 1 before any step is checked", async () => {
    process.env.DOMAIN = "inetalliance.net";
    process.env.SONAR_DATABASE_URL = "postgres://sonar";
    process.env.ONBOARD_ORG_UNIT_PATH = "/Staff";
    delete process.env.PBX_HOST;
    delete process.env.PBX_OP_ITEM;
    delete process.env.PBX_OP_VAULT;
    delete process.env.PBX_OP_ACCOUNT;
    delete process.env.PBX_ENABLED_EXTENSIONS;

    process.exit = ((code?: number) => {
      throw new Error(`exit ${code}`);
    }) as typeof process.exit;

    const checkSpies = steps.map((s) => spyOn(s, "check"));
    try {
      await expect(run({ ...baseCtx(), extension: "9001" })).rejects.toThrow("exit 1");
      for (const spy of checkSpies) expect(spy).not.toHaveBeenCalled();
      const errors = errSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(errors).toContain("nothing has been changed");
      expect(errors).toContain("PBX_HOST");
    } finally {
      for (const spy of checkSpies) spy.mockRestore();
    }
  });
});
