import { describe, expect, test } from "bun:test";
import { plausible, scanText } from "../src/mem0-scan/patterns";

// Every value here is made up for the test.
const rules = (text: string) => scanText(text).map((f) => f.rule);

describe("scanText finds credentials", () => {
  test.each([
    ["flag with a space", "ran setup-zoiper.ps1 -SipUser jdoe -SipPassword Fake9xQ2LmZp11aa", "password-keyword"],
    ["prose password", 'with SIP user "jdoe" and password Fake9xQ2LmZp11aa for target', "password-keyword"],
    ["password: value", "password: Fake9xQ2LmZp11aa", "password-keyword"],
    ["auth token hex", "sub-account ACfake (auth token 0123456789abcdef0123456789abcdef)", "token-keyword"],
    ["env token", "export TWILIO_AUTH_TOKEN=0123456789abcdef0123456789abcdef", "token-keyword"],
    ["url password", "postgres://app:Fake9xQ2Lm@db.example.com/app", "url-password"],
    ["github token", "token ghp_" + "a1B2".repeat(9), "github-token"],
    ["private key", "-----BEGIN OPENSSH PRIVATE KEY-----", "private-key"],
    ["bearer", "Authorization: Bearer abcdefghij0123456789ABCDEFGHIJ", "bearer-token"],
  ])("%s", (_name, text, rule) => {
    expect(rules(text)).toContain(rule);
  });
});

describe("scanText leaves non-secrets alone", () => {
  test.each([
    ["pointer to 1Password", "the SIP password (not stored here: read it with bin/sip-password --email)"],
    ["redacted", "password: [REDACTED]"],
    ["prose", "the password is stored encrypted in Phenix agent.sipsecret"],
    ["reset flow", "Password reset emails are sent by the onboarding script"],
    ["op reference", "API key op://IT/Twilio/credential"],
    ["identifier only", "Twilio API key SID SKfake is named Remix Sandbox Phones; the secret is in 1Password"],
    ["env placeholder", "MEM0_API_KEY=$MEM0_API_KEY"],
    ["variable name", "the production secret SAGE_GQL_AD1_BASE_URL is set in the cluster"],
    ["access key id alone", "AWS access key ID AKIAFAKEFAKEFAKE1234 belongs to IAM user twilio-recordings"],
  ])("%s", (_name, text) => {
    expect(rules(text)).toEqual([]);
  });
});

describe("hints never carry the value", () => {
  test("only the first four characters are shown", () => {
    const [finding] = scanText("password: Fake9xQ2LmZp11aa");
    expect(finding.hint).toBe("Fake... (16 chars)");
    expect(finding.hint).not.toContain("9xQ2");
  });
});

describe("plausible", () => {
  test("accepts generated-looking values", () => {
    expect(plausible("Fake9xQ2LmZp11aa")).toBe(true);
    expect(plausible("0123456789abcdef0123456789abcdef")).toBe(true);
  });
  test("rejects words, paths and placeholders", () => {
    expect(plausible("encrypted")).toBe(false);
    expect(plausible("/etc/asterisk/pjsip.conf")).toBe(false);
    expect(plausible("<your-password>")).toBe(false);
  });
});
