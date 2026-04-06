import { mkdirSync, existsSync } from "fs";
import { join } from "path";
import type { Step, Context } from "../types";

function escapeXml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

export function generateConfig(opts: {
  sipUser: string;
  sipPassword: string;
  sipDomain: string;
}): string {
  return `<?xml version="1.0" encoding="utf-8"?>
<options>
  <accounts>
    <account>
      <name>${escapeXml(opts.sipUser)}</name>
      <username>${escapeXml(opts.sipUser)}</username>
      <password>${escapeXml(opts.sipPassword)}</password>
      <host>${escapeXml(opts.sipDomain)}</host>
      <transport>2</transport>
      <use_rport>1</use_rport>
      <dtmf_style>1</dtmf_style>
      <registration_expiry>600</registration_expiry>
      <use_stun>0</use_stun>
      <codec>
        <codec_id>0</codec_id>
        <priority>0</priority>
        <enabled>1</enabled>
      </codec>
      <codec>
        <codec_id>8</codec_id>
        <priority>1</priority>
        <enabled>1</enabled>
      </codec>
      <codec>
        <codec_id>9</codec_id>
        <priority>2</priority>
        <enabled>1</enabled>
      </codec>
    </account>
  </accounts>
</options>`;
}

export const zoiperStep: Step = {
  name: "Zoiper Config",

  async check(ctx: Context): Promise<boolean> {
    if (!ctx.sipUsername || !ctx.sipPassword) return true;
    const name = `${ctx.firstName.toLowerCase()}-${ctx.lastName.toLowerCase()}`;
    const outPath = join(process.cwd(), "output", `zoiper-${name}.xml`);
    if (existsSync(outPath)) {
      ctx.zoiperConfigPath = outPath;
      return true;
    }
    return false;
  },

  async run(ctx: Context): Promise<void> {
    if (!ctx.sipUsername || !ctx.sipPassword) return;

    const xml = generateConfig({
      sipUser: ctx.sipUsername,
      sipPassword: ctx.sipPassword,
      sipDomain: "ameriglide.pstn.twilio.com",
    });

    const outDir = join(process.cwd(), "output");
    mkdirSync(outDir, { recursive: true });

    const name = `${ctx.firstName.toLowerCase()}-${ctx.lastName.toLowerCase()}`;
    const outPath = join(outDir, `zoiper-${name}.xml`);
    await Bun.write(outPath, xml);

    ctx.zoiperConfigPath = outPath;
  },
};
