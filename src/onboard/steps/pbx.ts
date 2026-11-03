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

export function accountSheet(opts: {
  firstName: string;
  lastName: string;
  extension: string;
  password: string | null;
  host: string;
  port: string;
  opItem?: string;
}): string {
  const { firstName, lastName, extension, password, host, port, opItem } = opts;
  const missing = opItem
    ? `<<< from 1Password, item "${opItem}", field ${extension} >>>`
    : `<<< from 1Password (set PBX_OP_ITEM in .env to look this up automatically) >>>`;
  return `MicroSIP account for ${firstName} ${lastName} (extension ${extension})
Add this through MicroSIP's Account menu, not by editing MicroSIP.ini.

  Account name      ${host}
  SIP server        ${host}:${port}
  Proxy             (leave blank)
  Domain            ${host}
  Username          ${extension}
  Auth ID           ${extension}
  Password          ${password ?? missing}
  Display name      ${firstName} ${lastName}
  Transport         TLS
  Media encryption  Mandatory SRTP (RTP/SAVP)
  Codecs            ulaw, alaw, opus
  DTMF              RFC 2833 / RFC 4733
  Default account   No

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
// Read it if we can; if we cannot, say what is missing rather than emitting a
// sheet with a silently blank password.
async function lookupPassword(extension: string): Promise<string | null> {
  const item = process.env.PBX_OP_ITEM;
  const vault = process.env.PBX_OP_VAULT;
  const account = process.env.PBX_OP_ACCOUNT;
  if (!item || !vault || !account) return null;

  const proc = Bun.spawn(
    [
      "op", "item", "get", item,
      "--vault", vault,
      "--account", account,
      "--fields", `label=${extension}`,
      "--reveal",
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  const out = (await new Response(proc.stdout).text()).trim();
  const code = await proc.exited;
  if (code !== 0 || !out) return null;
  return out;
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
        "No extension set. Run the Sonar step first, or pass --extension.",
      );
    }
    assertValidExtension(ext);

    const host = pbxHost();
    const port = process.env.PBX_TLS_PORT ?? "5061";

    const enabled = isPbxEnabled(ext);
    ctx.pbxExtensionEnabled = enabled ?? undefined;
    if (enabled === false) {
      throw new Error(
        `Extension ${ext} is not enabled on ${host}.\n` +
          `  Migrated extensions default to the disabled endpoint template: they cannot\n` +
          `  register and cannot place calls. Ask Michael to switch it back to the\n` +
          `  default template, pjsip reload, set a strong secret, and add that secret to\n` +
          `  the 1Password item. Then re-run. See IAI-35.`,
      );
    }
    if (enabled === null) {
      console.log(
        `  (PBX_ENABLED_EXTENSIONS unset - not checking whether ${ext} is enabled)`,
      );
    }

    const password = await lookupPassword(ext);
    if (!password) {
      console.log(
        `  ⚠ No password for ${ext} from 1Password - the sheet will have a placeholder.`,
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
    const filename = `microsip-${ctx.firstName}-${ctx.lastName}.txt`
      .toLowerCase()
      .replace(/[^a-z0-9.\-]/g, "");
    const outPath = join(outDir, filename);
    await Bun.write(outPath, sheet);
    ctx.pbxAccountSheetPath = outPath;

    console.log();
    console.log(sheet);
  },
};
