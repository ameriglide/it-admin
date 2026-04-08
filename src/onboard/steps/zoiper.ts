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
      <username>${escapeXml(opts.sipUser)}</username>
      <password>${escapeXml(opts.sipPassword)}</password>
      <SIP_domain>${escapeXml(opts.sipDomain)}</SIP_domain>
      <SIP_transport_type>2</SIP_transport_type>
      <SIP_use_rport>1</SIP_use_rport>
      <SIP_dtmf_style>1</SIP_dtmf_style>
      <reregistration_time>60</reregistration_time>
      <use_ice>1</use_ice>
      <codecs>
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
      </codecs>
      <stun>
        <use_stun>1</use_stun>
        <stun_host>global.stun.twilio.com</stun_host>
        <stun_port>3478</stun_port>
      </stun>
    </account>
  </accounts>
</options>`;
}

export const zoiperStep: Step = {
  name: "Zoiper Config",

  async check(ctx: Context): Promise<boolean> {
    if (!ctx.sipUsername || !ctx.sipPassword) return true;
    const filename = `zoiper-${ctx.firstName}-${ctx.lastName}.xml`
      .toLowerCase()
      .replace(/[^a-z0-9.\-]/g, "");
    const outPath = join(process.cwd(), "output", filename);
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

    const filename = `zoiper-${ctx.firstName}-${ctx.lastName}.xml`
      .toLowerCase()
      .replace(/[^a-z0-9.\-]/g, "");
    const outPath = join(outDir, filename);
    await Bun.write(outPath, xml);

    ctx.zoiperConfigPath = outPath;
  },
};
