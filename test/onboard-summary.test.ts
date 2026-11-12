import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { printSummary } from "../src/onboard/lib/summary";
import type { Context } from "../src/onboard/types";

const ctx = (extra: Partial<Context> = {}): Context => ({
  firstName: "Nancy",
  lastName: "Example",
  email: "nancy@example.com",
  directLine: false,
  ...extra,
});

const PAUSED =
  'no - paused; agent clicks "Start taking calls" once the phone registers';
const SHEET = "/tmp/output/microsip-9015-nancy-example.txt";
const LINE = "══════════════════════════════════════════";

describe("printSummary", () => {
  const savedLog = console.log;
  const savedDomain = process.env.DOMAIN;
  let out: string;

  beforeEach(() => {
    out = "";
    console.log = (...args: unknown[]) => {
      out += args.join(" ") + "\n";
    };
    process.env.DOMAIN = "inetalliance.net"; // IAI unless a test says otherwise
  });

  afterEach(() => {
    console.log = savedLog;
    if (savedDomain === undefined) delete process.env.DOMAIN;
    else process.env.DOMAIN = savedDomain;
  });

  const summary = (c: Context): string => {
    out = "";
    printSummary(c);
    return out;
  };
  const takingCalls = (s: string) => s.match(/Taking calls: (.*)/)?.[1];
  const pbxExtension = (s: string) =>
    s.match(/PBX \(IAI softphone, MicroSIP\)\n\s+Extension: (.*)/)?.[1];

  describe("tenant sections", () => {
    it("shows Sonar and PBX for IAI", () => {
      const s = summary(ctx());
      expect(s).toContain("\n  Sonar\n    Agent Key: skipped\n    Taking calls: n/a\n\n  Twilio");
      expect(s).toContain("\n  PBX (IAI softphone, MicroSIP)\n    Extension: skipped");
    });

    it("matches the pre-IAI summary exactly for AmeriGlide", () => {
      for (const domain of ["ameriglide.com", undefined]) {
        if (domain === undefined) delete process.env.DOMAIN;
        else process.env.DOMAIN = domain;
        // Even with Sonar/PBX fields set, AmeriGlide shows neither section.
        const s = summary(
          ctx({ sonarAgentKey: "9015", extension: "9015", pbxAccountSheetPath: SHEET }),
        );
        expect(s).toBe(`
${LINE}
  New Employee: Nancy Example
  Email: nancy@example.com
${LINE}

  Google Workspace
    Temp Password: already existed

  Google Groups
    Joined: skipped

  Amberjack
    Employee ID: skipped

  Phenix
    Agent ID: skipped

  Twilio
    Worker SID: skipped
    SIP Username: skipped
    SIP Password: already existed

  Direct Line
    Phone: none

  Zoiper
    Config: not generated
    Activation: handled by setup-workstation.ps1 (ZOIPER_USERNAME/PASSWORD in .env)

${LINE}
  Next: set up the workstation (you'll be prompted), or use bin/copy for one-offs
${LINE}

`);
      }
    });
  });

  describe("Taking calls", () => {
    it("is n/a without a Sonar agent", () => {
      expect(takingCalls(summary(ctx({ sonarAgentPaused: true })))).toBe("n/a");
    });

    it("says paused when the agent is paused", () => {
      const s = summary(
        ctx({ sonarAgentKey: "9015", sonarAgentPaused: true, sonarAgentCreated: false }),
      );
      expect(takingCalls(s)).toBe(PAUSED);
    });

    it("says yes when the agent is not paused, even if just created", () => {
      const s = summary(
        ctx({ sonarAgentKey: "9015", sonarAgentPaused: false, sonarAgentCreated: true }),
      );
      expect(takingCalls(s)).toBe("yes");
    });

    // The Sonar step always records paused today; these cover the defensive
    // fallbacks for a future path that sets the key without it.
    it("falls back to paused for a new agent when paused is unknown", () => {
      const s = summary(ctx({ sonarAgentKey: "9015", sonarAgentCreated: true }));
      expect(takingCalls(s)).toBe(PAUSED);
    });

    it("falls back to unchanged for an existing agent when paused is unknown", () => {
      const s = summary(ctx({ sonarAgentKey: "9015", sonarAgentCreated: false }));
      expect(takingCalls(s)).toBe("unchanged (agent already existed)");
    });
  });

  describe("PBX", () => {
    it("shows the MISSING password line only when the password is missing", () => {
      expect(
        summary(ctx({ extension: "9015", pbxAccountSheetPath: SHEET, pbxPasswordMissing: true })),
      ).toContain("Password: MISSING");
      expect(
        summary(ctx({ extension: "9015", pbxAccountSheetPath: SHEET, pbxPasswordMissing: false })),
      ).not.toContain("Password: MISSING");
      expect(
        summary(ctx({ extension: "9015", pbxAccountSheetPath: SHEET })),
      ).not.toContain("Password: MISSING");
    });

    it("shows the extension when a sheet was written", () => {
      const s = summary(ctx({ extension: "9015", pbxAccountSheetPath: SHEET }));
      expect(pbxExtension(s)).toBe("9015");
    });

    it("falls back to the Sonar agent key for the extension", () => {
      const s = summary(ctx({ sonarAgentKey: "9015", pbxAccountSheetPath: "/tmp/x" }));
      expect(pbxExtension(s)).toBe("9015");
      expect(s).toContain("Account sheet: /tmp/x");
    });

    it("shows skipped when no sheet was written, even with an extension set", () => {
      const s = summary(ctx({ extension: "9015" }));
      expect(pbxExtension(s)).toBe("skipped");
      expect(s).toContain("Account sheet: not generated");
    });
  });
});
