import { describe, expect, test } from "bun:test";
import { generateTempPassword, generateSipPassword } from "../src/onboard/lib/password";

describe("generateTempPassword", () => {
  test("returns 4 words separated by hyphens with initial caps", () => {
    const pw = generateTempPassword();
    const parts = pw.split("-");
    expect(parts).toHaveLength(4);
    for (const word of parts) {
      expect(word.length).toBeGreaterThanOrEqual(3);
      expect(word[0]).toBe(word[0].toUpperCase());
      expect(word.slice(1)).toBe(word.slice(1).toLowerCase());
    }
  });

  test("generates different passwords each time", () => {
    const a = generateTempPassword();
    const b = generateTempPassword();
    expect(a).not.toBe(b);
  });
});

describe("generateSipPassword", () => {
  test("returns 16 characters", () => {
    expect(generateSipPassword()).toHaveLength(16);
  });

  test("contains at least 1 uppercase, 1 lowercase, 1 digit", () => {
    for (let i = 0; i < 20; i++) {
      const pw = generateSipPassword();
      expect(pw).toMatch(/[A-Z]/);
      expect(pw).toMatch(/[a-z]/);
      expect(pw).toMatch(/[0-9]/);
    }
  });
});
