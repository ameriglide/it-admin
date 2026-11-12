import { mkdirSync } from "fs";
import { join } from "path";
import type { Step, Context } from "../types";
import { assertValidExtension, isPbxEnabled } from "../lib/extension";

// Softphone setup for the IAI PBX: SIP-TLS over the public internet, mandatory
// SRTP, one registered contact per extension. Reaching it over the tailnet is
// deliberately not supported -- taking Tailscale out of the phone path is the
// point of the current PBX. Host, port and the 1Password item that holds the
// per-extension secrets all come from .env; this repo is public, so no
// hostnames or addresses are hardcoded here.
//
// This step does not write MicroSIP.ini. MicroSIP rewrites that file on start
// and on exit, so a config dropped underneath a running client is lost; the
// account is meant to be added through its UI. What we generate instead is the
// field-by-field sheet to type in.

function pbxHost(): string {
  const host = process.env.PBX_HOST;
  if (!host) throw new Error("PBX_HOST not set");
  return host;
}

// "No" only until cutover from the retired PBX: until then agents keep their
// old account as the default (see docs/runbooks/iai-onboarding.md, "Until
// cutover, agents get two accounts"). Flip this to "Yes" at cutover.
const DEFAULT_ACCOUNT = "No";

// One sheet per agent and extension. The extension is in the name so two
// agents who share a name (or a re-run for a new extension) do not overwrite
// each other. Names are reduced to ASCII letters, digits and dashes: accents
// are stripped (José -> jose) rather than the whole letter dropped, and
// anything else -- apostrophes, spaces, path separators -- is removed.
export function sheetFilename(ext: string, firstName: string, lastName: string): string {
  const clean = (s: string) =>
    s
      .normalize("NFKD")
      .replace(/[\u0300-\u036f]/g, "")
      .toLowerCase()
      .replace(/[^a-z0-9-]/g, "");
  const parts = [ext, firstName, lastName].map(clean).map((p) => p || "x");
  return `microsip-${parts.join("-")}.txt`;
}

export function accountSheet(opts: {
  firstName: string;
  lastName: string;
  extension: string;
  password: string | null; // null or "" renders a loud placeholder
  host: string;
  port: string;
  opItem?: string;
}): string {
  const { firstName, lastName, extension, password, host, port, opItem } = opts;
  const missing = opItem
    ? `<<< from 1Password, item "${opItem}", field ${extension} >>>`
    : `<<< from 1Password (set PBX_OP_ITEM, PBX_OP_VAULT and PBX_OP_ACCOUNT in .env to look this up automatically) >>>`;
  return `MicroSIP account for ${firstName} ${lastName} (extension ${extension})
Add this through MicroSIP's Account menu, not by editing MicroSIP.ini.

  Account name      ${host}
  SIP server        ${host}:${port}
  Proxy             (leave blank)
  Domain            ${host}
  Username          ${extension}
  Auth ID           ${extension}
  Password          ${password || missing}
  Display name      ${firstName} ${lastName}
  Transport         TLS
  Media encryption  Mandatory SRTP (RTP/SAVP)
  Codecs            ulaw, alaw, opus
  DTMF              RFC 2833 / RFC 4733
  Default account   ${DEFAULT_ACCOUNT}

Notes
  - Point this at ${host}, never at the PBX's tailnet address. The phone path is
    deliberately public-internet only.
  - You may need to set the TLS source port to ${port} in MicroSIP's global Settings.
  - This extension allows one registered device. Register only this agent's own machine.
  - Verify on the PBX with: asterisk -rx "pjsip show contacts"  (expect Avail)
  - Use the current PBX password. The retired PBX's secret will not work.
`;
}

// The per-extension secrets live in a 1Password item, one field per extension.
// Read it if we can; if we cannot, return the reason so the operator sees why
// the sheet has a placeholder instead of a silently blank password. A partial
// PBX_OP_* config is a mistake in .env, not "not configured", so it throws.
export interface PasswordLookup {
  password: string | null;
  reason?: string;
}

export async function lookupPassword(extension: string): Promise<PasswordLookup> {
  const vars = {
    PBX_OP_ITEM: process.env.PBX_OP_ITEM,
    PBX_OP_VAULT: process.env.PBX_OP_VAULT,
    PBX_OP_ACCOUNT: process.env.PBX_OP_ACCOUNT,
  };
  const unset = Object.entries(vars)
    .filter(([, v]) => !v)
    .map(([k]) => k);
  if (unset.length === 3) {
    return { password: null, reason: "PBX_OP_ITEM/PBX_OP_VAULT/PBX_OP_ACCOUNT not set" };
  }
  if (unset.length > 0) {
    throw new Error(
      `Incomplete 1Password config for the PBX: ${unset.join(", ")} not set. ` +
        `Set all of PBX_OP_ITEM, PBX_OP_VAULT and PBX_OP_ACCOUNT, or none of them.`,
    );
  }

  let proc;
  try {
    proc = Bun.spawn(
      [
        "op", "item", "get", vars.PBX_OP_ITEM!,
        "--vault", vars.PBX_OP_VAULT!,
        "--account", vars.PBX_OP_ACCOUNT!,
        "--fields", `label=${extension}`,
        "--reveal",
      ],
      // An explicit env makes Bun resolve `op` against the current PATH rather
      // than the one the process started with.
      { stdout: "pipe", stderr: "pipe", env: { ...process.env } },
    );
  } catch (e) {
    const err = e as NodeJS.ErrnoException;
    if (err.code === "ENOENT") {
      return { password: null, reason: "1Password CLI (op) not installed" };
    }
    return { password: null, reason: `could not run op: ${err.message}` };
  }
  const [out, errText, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (code !== 0) {
    const first = errText.trim().split("\n")[0] || `op exited ${code}`;
    return { password: null, reason: first };
  }
  const password = out.trim();
  if (!password) return { password: null, reason: `field ${extension} is empty` };
  return { password };
}

export const pbxStep: Step = {
  name: "PBX",

  async check(): Promise<boolean> {
    return false; // cheap to regenerate; always produce a current sheet
  },

  async run(ctx: Context): Promise<void> {
    const ext = ctx.extension ?? ctx.sonarAgentKey;
    if (!ext) {
      throw new Error(
        "No extension set. Pass --extension, or set SONAR_DATABASE_URL so the " +
          "Sonar step runs and assigns one.",
      );
    }
    assertValidExtension(ext);

    const host = pbxHost();
    const port = process.env.PBX_TLS_PORT || "5061";

    const enabled = isPbxEnabled(ext);
    if (enabled === false) {
      throw new Error(
        `Extension ${ext} is not enabled on ${host}.\n` +
          `  Migrated extensions default to the disabled endpoint template: they cannot\n` +
          `  register and cannot place calls. Ask the PBX admin (see IAI-35) to move it\n` +
          `  to the default endpoint template, pjsip reload, set a strong secret, and add\n` +
          `  that secret to the 1Password item. Then re-run.`,
      );
    }
    if (enabled === null) {
      console.log(
        `  (PBX_ENABLED_EXTENSIONS unset - not checking whether ${ext} is enabled)`,
      );
    }

    const { password, reason } = await lookupPassword(ext);
    ctx.pbxPasswordMissing = !password;
    if (!password) {
      console.log(
        `  ⚠ No password for ${ext} from 1Password (${reason}) - the sheet will have a placeholder.`,
      );
    }

    const sheet = accountSheet({
      firstName: ctx.firstName,
      lastName: ctx.lastName,
      extension: ext,
      password,
      host,
      port,
      opItem: process.env.PBX_OP_ITEM,
    });

    const outDir = join(process.cwd(), "output");
    mkdirSync(outDir, { recursive: true });
    const outPath = join(outDir, sheetFilename(ext, ctx.firstName, ctx.lastName));
    await Bun.write(outPath, sheet);
    ctx.pbxAccountSheetPath = outPath;

    console.log();
    console.log(sheet);
  },
};
