import { describe, expect, test } from "bun:test";
import { generateConfig } from "../src/onboard/steps/zoiper";

describe("zoiper config", () => {
  test("generates valid XML with SIP credentials", () => {
    const xml = generateConfig({
      sipUser: "john.doe",
      sipPassword: "testPass123",
      sipDomain: "phenix.sip.twilio.com",
    });

    expect(xml).toContain('<?xml version="1.0"');
    expect(xml).toContain("<ident>john.doe@phenix.sip.twilio.com</ident>");
    expect(xml).toContain("<name>john.doe</name>");
    expect(xml).toContain("<protocol>sip</protocol>");
    expect(xml).toContain("<username>john.doe</username>");
    expect(xml).toContain("<password>testPass123</password>");
    expect(xml).toContain("<SIP_domain>phenix.sip.twilio.com:5061</SIP_domain>");
    expect(xml).toContain("<SIP_transport_type>tls</SIP_transport_type>");
    expect(xml).toContain("<SIP_srtp_mode>none</SIP_srtp_mode>");
    expect(xml).toContain("<use_stun>disabled</use_stun>");
    // PCMU=0, PCMA=6, G.722=7 per Zoiper's codec_id enumeration
    // (NOT the SDP/RTP payload type numbers 0/8/9)
    expect(xml).toContain("<codec_id>0</codec_id>");
    expect(xml).toContain("<codec_id>6</codec_id>");
    expect(xml).toContain("<codec_id>7</codec_id>");
  });

  test("escapes XML special characters in password", () => {
    const xml = generateConfig({
      sipUser: "test",
      sipPassword: 'a<b>&c"d',
      sipDomain: "example.com",
    });

    expect(xml).toContain("&lt;");
    expect(xml).toContain("&amp;");
  });
});
