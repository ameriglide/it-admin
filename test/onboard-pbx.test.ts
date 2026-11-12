import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "fs";
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

const ENV_KEYS = [
  "PATH",
  "PBX_HOST",
  "PBX_TLS_PORT",
  "PBX_ENABLED_EXTENSIONS",
  "PBX_OP_ITEM",
  "PBX_OP_VAULT",
  "PBX_OP_ACCOUNT",
];

// Per-test sandbox: a fresh cwd, the PBX env cleared (PATH kept as is), and
// console.log silenced. Everything is put back in afterEach.
function useSandbox(): { dir: () => string } {
  const savedEnv: Record<string, string | undefined> = {};
  const savedCwd = process.cwd();
  const savedLog = console.log;
  let dir = "";

  beforeEach(() => {
    for (const k of ENV_KEYS) {
      savedEnv[k] = process.env[k];
      if (k !== "PATH") delete process.env[k];
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

  return { dir: () => dir };
}

function setOpConfig(): void {
  process.env.PBX_OP_ITEM = "PBX creds";
  process.env.PBX_OP_VAULT = "vault";
  process.env.PBX_OP_ACCOUNT = "account.example.com";
}

// Put a stub `op` first on PATH. It records its arguments, one per line, to
// <dir>/op-args, then prints/exits as `mode` says. Stdout mimics
// `op item get --fields label=<ext> --format json`: one match is an object,
// several are an array. Returns the args file.
type OpMode =
  | "ok"
  | "fail"
  | "empty"
  | "multi"
  | "tricky"
  | "garbage"
  | "longerr"
  | "silent";

// A password with a comma and both quote characters, which the plain
// (CSV-style) `op --fields` output would have quoted or read as two fields.
const TRICKY = `s3c,r"e't`;

const LONG_ERR = "E".repeat(400);

// Quoted heredoc: the shell expands nothing inside it.
const stdout = (text: string) => `cat <<'OPEOF'\n${text}\nOPEOF`;

const field = (value: string) =>
  JSON.stringify({ id: "f1", type: "CONCEALED", label: "9002", value });

function installOpStub(dir: string, mode: OpMode): string {
  const bin = join(dir, "bin");
  mkdirSync(bin, { recursive: true });
  const argsFile = join(dir, "op-args");
  const body = {
    ok: stdout(field("s3cret")),
    fail: [
      'echo "[ERROR] could not get item" >&2',
      'echo "  hint: sign in with op signin" >&2',
      "exit 1",
    ].join("\n"),
    empty: stdout(field("")),
    multi: stdout(
      JSON.stringify([
        { id: "f1", label: "9002", value: "s3cret" },
        { id: "f2", label: "9002", value: "0ther" },
      ]),
    ),
    tricky: stdout(field(TRICKY)),
    garbage: stdout("not json at all"),
    longerr: `echo "${LONG_ERR}" >&2\nexit 1`,
    silent: "exit 2",
  }[mode];
  const op = join(bin, "op");
  writeFileSync(op, `#!/bin/sh\nprintf '%s\\n' "$@" > "${argsFile}"\n${body}\n`);
  chmodSync(op, 0o755);
  process.env.PATH = `${bin}:${process.env.PATH ?? ""}`;
  return argsFile;
}

const ctx = (extra: Partial<Context> = {}): Context => ({
  firstName: "Nancy",
  lastName: "Example",
  email: "nancy@example.com",
  directLine: false,
  ...extra,
});

describe("lookupPassword", () => {
  const sb = useSandbox();

  it("explains an unconfigured 1Password lookup", async () => {
    expect(await lookupPassword("9002")).toEqual({
      ok: false,
      reason: "PBX_OP_ITEM/PBX_OP_VAULT/PBX_OP_ACCOUNT not set",
    });
  });

  it("rejects a partial 1Password config by name", async () => {
    process.env.PBX_OP_ITEM = "PBX creds";
    await expect(lookupPassword("9002")).rejects.toThrow(
      /PBX_OP_VAULT, PBX_OP_ACCOUNT not set/,
    );
  });

  it("reports a missing op binary instead of aborting the run", async () => {
    setOpConfig();
    process.env.PATH = sb.dir(); // empty dir: no `op` on PATH
    expect(await lookupPassword("9002")).toEqual({
      ok: false,
      reason: "1Password CLI (op) not installed",
    });
  });

  it("reads the extension's field from the configured item, vault and account", async () => {
    setOpConfig();
    const argsFile = installOpStub(sb.dir(), "ok");
    expect(await lookupPassword("9002")).toEqual({ ok: true, password: "s3cret" });
    expect(readFileSync(argsFile, "utf8").trim().split("\n")).toEqual([
      "item", "get", "PBX creds",
      "--vault", "vault",
      "--account", "account.example.com",
      "--fields", "label=9002",
      "--reveal",
      "--format", "json",
    ]);
  });

  it("returns all of op's stderr, on one line, when op fails", async () => {
    setOpConfig();
    installOpStub(sb.dir(), "fail");
    const r = await lookupPassword("9002");
    if (r.ok) throw new Error("expected a failed lookup");
    expect(r.reason).toContain("could not get item");
    expect(r.reason).toContain("sign in with op signin");
    expect(r.reason).not.toContain("\n");
    expect(r.reason.length).toBeLessThanOrEqual(300);
  });

  it("caps a long stderr at 300 characters", async () => {
    setOpConfig();
    installOpStub(sb.dir(), "longerr");
    const r = await lookupPassword("9002");
    if (r.ok) throw new Error("expected a failed lookup");
    expect(r.reason.length).toBe(300);
    expect(r.reason.endsWith("...")).toBe(true);
    expect(r.reason.startsWith("EEE")).toBe(true);
  });

  it("reports the exit code when op fails without a message", async () => {
    setOpConfig();
    installOpStub(sb.dir(), "silent");
    expect(await lookupPassword("9002")).toEqual({ ok: false, reason: "op exited 2" });
  });

  it("passes a password with a comma and quotes through intact", async () => {
    setOpConfig();
    installOpStub(sb.dir(), "tricky");
    expect(await lookupPassword("9002")).toEqual({ ok: true, password: TRICKY });
  });

  it("reports output that is not JSON, quoting the start of it", async () => {
    setOpConfig();
    installOpStub(sb.dir(), "garbage");
    const r = await lookupPassword("9002");
    if (r.ok) throw new Error("expected a failed lookup");
    expect(r.reason).toMatch(/could not parse op output as JSON: not json at all/);
  });

  it("reports an empty field", async () => {
    setOpConfig();
    installOpStub(sb.dir(), "empty");
    expect(await lookupPassword("9002")).toEqual({
      ok: false,
      reason: "field 9002 is empty",
    });
  });

  it("refuses output where the label matched several fields", async () => {
    setOpConfig();
    installOpStub(sb.dir(), "multi");
    expect(await lookupPassword("9002")).toEqual({
      ok: false,
      reason: "label 9002 matched more than one field",
    });
  });
});

describe("pbxStep.run", () => {
  const sb = useSandbox();

  it("refuses an extension that is not enabled on the PBX", async () => {
    process.env.PBX_ENABLED_EXTENSIONS = "9001";
    const c = ctx({ extension: "9002" });
    await expect(pbxStep.run(c)).rejects.toThrow(/not enabled/);
    expect(c.pbxAccountSheetPath).toBeUndefined();
    expect(existsSync(join(sb.dir(), "output"))).toBe(false);
  });

  it("refuses when there is no extension at all", async () => {
    const c = ctx();
    await expect(pbxStep.run(c)).rejects.toThrow(
      /No extension set\. Pass --extension \(the Sonar step was skipped/,
    );
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

  it("writes the password from 1Password into an owner-only sheet", async () => {
    setOpConfig();
    installOpStub(sb.dir(), "ok");
    const c = ctx({ extension: "9002" });
    await pbxStep.run(c);
    expect(c.pbxPasswordMissing).toBe(false);
    const path = c.pbxAccountSheetPath!;
    expect(readFileSync(path, "utf8")).toMatch(/Password\s+s3cret\n/);
    expect(statSync(path).mode & 0o777).toBe(0o600);
  });

  it("tightens the mode of a sheet left by an earlier run", async () => {
    const out = join(process.cwd(), "output"); // cwd is realpath'd; sb.dir() may not be
    mkdirSync(out, { recursive: true });
    const stale = join(out, sheetFilename("9002", "Nancy", "Example"));
    writeFileSync(stale, "old");
    chmodSync(stale, 0o644);
    const c = ctx({ extension: "9002" });
    await pbxStep.run(c);
    expect(c.pbxAccountSheetPath).toBe(stale);
    expect(statSync(stale).mode & 0o777).toBe(0o600);
    expect(readFileSync(stale, "utf8")).not.toBe("old");
  });

  it("uses PBX_TLS_PORT when set", async () => {
    process.env.PBX_TLS_PORT = "5161";
    const c = ctx({ extension: "9002" });
    await pbxStep.run(c);
    const sheet = readFileSync(c.pbxAccountSheetPath!, "utf8");
    expect(sheet).toMatch(/SIP server\s+pbx\.example\.com:5161\n/);
    expect(sheet).not.toContain(":5061");
  });

  it("rejects a partial 1Password config by name, writing nothing", async () => {
    process.env.PBX_OP_ITEM = "PBX creds";
    const c = ctx({ extension: "9002" });
    await expect(pbxStep.run(c)).rejects.toThrow(
      /PBX_OP_VAULT, PBX_OP_ACCOUNT not set/,
    );
    expect(c.pbxAccountSheetPath).toBeUndefined();
    expect(existsSync(join(sb.dir(), "output"))).toBe(false);
  });
});
