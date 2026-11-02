import { describe, expect, it } from "bun:test";
import { accountSheet } from "../src/onboard/steps/pbx";

const base = {
  firstName: "Nancy",
  lastName: "Example",
  extension: "7415",
  host: "pbx.example.com",
  port: "5061",
};

describe("accountSheet", () => {
  it("carries the settings an agent has to type into MicroSIP", () => {
    const sheet = accountSheet({ ...base, password: "s3cret" });
    expect(sheet).toContain("pbx.example.com:5061");
    expect(sheet).toContain("Nancy Example");
    expect(sheet).toMatch(/Username\s+7415/);
    expect(sheet).toMatch(/Auth ID\s+7415/);
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
    expect(sheet).toContain("field 7415");
  });

  it("still says where to look when no 1Password item is configured", () => {
    const sheet = accountSheet({ ...base, password: null });
    expect(sheet).toContain("PBX_OP_ITEM");
  });

  it("names the host to use rather than a tailnet address", () => {
    const sheet = accountSheet({ ...base, password: "x" });
    expect(sheet).toContain("never at the PBX's tailnet address");
    expect(sheet).not.toMatch(/100\.64\./);
  });
});
