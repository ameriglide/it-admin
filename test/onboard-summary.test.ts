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

describe("printSummary", () => {
  const savedLog = console.log;
  let out: string;

  beforeEach(() => {
    out = "";
    console.log = (...args: unknown[]) => {
      out += args.join(" ") + "\n";
    };
  });

  afterEach(() => {
    console.log = savedLog;
  });

  const summary = (c: Context): string => {
    out = "";
    printSummary(c);
    return out;
  };
  const takingCalls = (s: string) => s.match(/Taking calls: (.*)/)?.[1];
  const pbxExtension = (s: string) =>
    s.match(/PBX \(IAI softphone, MicroSIP\)\n\s+Extension: (.*)/)?.[1];

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

    it("shows skipped when no sheet was written, even with an extension set", () => {
      const s = summary(ctx({ extension: "9015" }));
      expect(pbxExtension(s)).toBe("skipped");
      expect(s).toContain("Account sheet: not generated");
    });
  });
});
