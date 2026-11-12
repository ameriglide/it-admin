import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  accountSheet,
  lookupPassword,
  pbxStep,
  sheetFilename,
} from "../src/onboard/steps/pbx";
import type { Context } from "../src/onboard/types";

const base = {
  firstName: "Nancy",
  lastName: "Example",
  extension: "9015",
  host: "pbx.example.com",
  port: "5061",
};

describe("accountSheet", () => {
  it("carries the settings an agent has to type into MicroSIP", () => {
    const sheet = accountSheet({ ...base, password: "s3cret" });
    expect(sheet).toContain("pbx.example.com:5061");
    expect(sheet).toContain("Nancy Example");
    expect(sheet).toMatch(/Username\s+9015/);
    expect(sheet).toMatch(/Auth ID\s+9015/);
    expect(sheet).toMatch(/Password\s+s3cret/);
    expect(sheet).toMatch(/Transport\s+TLS/);
    expect(sheet).toMatch(/Mandatory SRTP/);
    expect(sheet).toMatch(/Default account\s+No/);
  });

  // A blank password field would look like "no password needed" on a printed
  // sheet, which is exactly the mistake that sends someone to the old PBX
  // secret. Make the gap loud, and name where to get it.
  it("marks a missing password instead of leaving it blank", () => {
    const sheet = accountSheet({ ...base, password: null, opItem: "PBX creds" });
    expect(sheet).toContain("<<<");
    expect(sheet).toContain("PBX creds");
    expect(sheet).toContain("field 9015");
  });

  it("treats an empty password like a missing one", () => {
    const sheet = accountSheet({ ...base, password: "", opItem: "PBX creds" });
    expect(sheet).toMatch(/Password\s+<<< from 1Password/);
  });

  it("still says where to look when no 1Password item is configured", () => {
    const sheet = accountSheet({ ...base, password: null });
    expect(sheet).toContain("PBX_OP_ITEM");
  });

  it("uses the given host as the only server address", () => {
    const sheet = accountSheet({ ...base, password: "x" });
    expect(sheet).toMatch(/Account name\s+pbx\.example\.com\n/);
    expect(sheet).toMatch(/Domain\s+pbx\.example\.com\n/);
    expect(sheet).toMatch(/SIP server\s+pbx\.example\.com:5061\n/);
    expect(sheet).not.toMatch(/\b\d{1,3}(\.\d{1,3}){3}\b/);
  });
});

describe("sheetFilename", () => {
  it("includes the extension so namesakes do not collide", () => {
    expect(sheetFilename("9015", "Nancy", "Example")).toBe(
      "microsip-9015-nancy-example.txt",
    );
    expect(sheetFilename("9016", "Nancy", "Example")).not.toBe(
      sheetFilename("9015", "Nancy", "Example"),
    );
  });

  it("drops apostrophes and path separators", () => {
    const name = sheetFilename("9015", "Pat", "O'Brien/../x\\y");
    expect(name).not.toContain("'");
    expect(name).not.toContain("/");
    expect(name).not.toContain("\\");
    expect(name).not.toContain("..");
    expect(name.startsWith("microsip-9015-pat-obrien")).toBe(true);
  });

  it("keeps accented letters as their base letter", () => {
    expect(sheetFilename("9015", "José", "Núñez")).toBe(
      "microsip-9015-jose-nunez.txt",
    );
  });

  it("never collapses a name part to empty", () => {
    expect(sheetFilename("9015", "李", "Example")).toBe(
      "microsip-9015-x-example.txt",
    );
  });
});

describe("pbxStep.run", () => {
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
  let dir: string;

  beforeEach(() => {
    for (const k of ENV_KEYS) {
      savedEnv[k] = process.env[k];
      delete process.env[k];
    }
    process.env.PBX_HOST = "pbx.example.com";
    dir = mkdtempSync(join(tmpdir(), "onboard-pbx-"));
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

  const ctx = (extra: Partial<Context> = {}): Context => ({
    firstName: "Nancy",
    lastName: "Example",
    email: "nancy@example.com",
    directLine: false,
    ...extra,
  });

  it("refuses an extension that is not enabled on the PBX", async () => {
    process.env.PBX_ENABLED_EXTENSIONS = "9001";
    const c = ctx({ extension: "9002" });
    await expect(pbxStep.run(c)).rejects.toThrow(/not enabled/);
    expect(c.pbxAccountSheetPath).toBeUndefined();
    expect(existsSync(join(dir, "output"))).toBe(false);
  });

  it("refuses when there is no extension at all", async () => {
    const c = ctx();
    await expect(pbxStep.run(c)).rejects.toThrow(/No extension set/);
    expect(c.pbxAccountSheetPath).toBeUndefined();
  });

  it("falls back to the Sonar agent key", async () => {
    const c = ctx({ sonarAgentKey: "9003" });
    await pbxStep.run(c);
    expect(c.pbxAccountSheetPath).toContain("microsip-9003-");
  });

  it("writes the sheet with a placeholder when the enabled list is unset", async () => {
    const c = ctx({ extension: "9002" });
    await pbxStep.run(c);
    expect(c.pbxAccountSheetPath).toBeDefined();
    const sheet = readFileSync(c.pbxAccountSheetPath!, "utf8");
    expect(sheet).toMatch(/Password\s+<<< from 1Password/);
    expect(c.pbxPasswordMissing).toBe(true);
  });

  it("proceeds for an extension on the enabled list", async () => {
    process.env.PBX_ENABLED_EXTENSIONS = "9001, 9002";
    const c = ctx({ extension: "9002" });
    await pbxStep.run(c);
    expect(c.pbxAccountSheetPath).toBeDefined();
  });

  it("reports a missing op binary instead of aborting the run", async () => {
    process.env.PBX_OP_ITEM = "PBX creds";
    process.env.PBX_OP_VAULT = "vault";
    process.env.PBX_OP_ACCOUNT = "account.example.com";
    const savedPath = process.env.PATH;
    process.env.PATH = dir; // empty dir: no `op` on PATH
    try {
      expect(await lookupPassword("9002")).toEqual({
        password: null,
        reason: "1Password CLI (op) not installed",
      });
    } finally {
      process.env.PATH = savedPath;
    }
  });

  it("explains an unconfigured 1Password lookup", async () => {
    expect(await lookupPassword("9002")).toEqual({
      password: null,
      reason: "PBX_OP_ITEM/PBX_OP_VAULT/PBX_OP_ACCOUNT not set",
    });
  });

  it("rejects a partial 1Password config by name", async () => {
    process.env.PBX_OP_ITEM = "PBX creds";
    const c = ctx({ extension: "9002" });
    await expect(pbxStep.run(c)).rejects.toThrow(
      /PBX_OP_VAULT, PBX_OP_ACCOUNT not set/,
    );
  });
});
