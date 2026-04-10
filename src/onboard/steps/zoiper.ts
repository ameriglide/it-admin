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
  const ident = `${opts.sipUser}@${opts.sipDomain}`;
  return `<?xml version="1.0" encoding="utf-8"?>
<options>
  <accounts>
    <account>
      <ident>${escapeXml(ident)}</ident>
      <name>${escapeXml(opts.sipUser)}</name>
      <protocol>sip</protocol>
      <username>${escapeXml(opts.sipUser)}</username>
      <password>${escapeXml(opts.sipPassword)}</password>
      <save_username>true</save_username>
      <save_password>true</save_password>
      <register_on_startup>true</register_on_startup>
      <SIP_domain>${escapeXml(`${opts.sipDomain}:5061`)}</SIP_domain>
      <SIP_transport_type>tls</SIP_transport_type>
      <SIP_use_rport>true</SIP_use_rport>
      <SIP_srtp_mode>none</SIP_srtp_mode>
      <SIP_dtmf_style>rfc_2833</SIP_dtmf_style>
      <reregistration_mode>custom</reregistration_mode>
      <reregistration_time>600</reregistration_time>
      <codecs>
        <codec>
          <codec_id>0</codec_id>
          <priority>0</priority>
          <enabled>true</enabled>
        </codec>
        <codec>
          <codec_id>6</codec_id>
          <priority>1</priority>
          <enabled>true</enabled>
        </codec>
        <codec>
          <codec_id>7</codec_id>
          <priority>2</priority>
          <enabled>true</enabled>
        </codec>
      </codecs>
      <stun>
        <use_stun>disabled</use_stun>
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
      sipDomain: "phenix.sip.twilio.com",
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
