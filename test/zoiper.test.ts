import { describe, expect, test } from "bun:test";
import { generateConfig } from "../src/onboard/steps/zoiper";

describe("zoiper config", () => {
  test("generates valid XML with SIP credentials", () => {
    const xml = generateConfig({
      sipUser: "john.doe",
      sipPassword: "testPass123",
      sipDomain: "ameriglide.pstn.twilio.com",
    });

    expect(xml).toContain('<?xml version="1.0"');
    expect(xml).toContain("<username>john.doe</username>");
    expect(xml).toContain("<password>testPass123</password>");
    expect(xml).toContain("<host>ameriglide.pstn.twilio.com</host>");
    expect(xml).toContain("<transport>2</transport>");
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
