import { describe, expect, test } from "bun:test";
import { encrypt, decrypt } from "../src/onboard/lib/crypto";

const TEST_KEY = Buffer.from("D5QLaqzqvKWYUIXwFmY07A02LB3GJ6PVtGX9f6IEF7E=", "base64");

describe("crypto", () => {
  test("encrypt then decrypt roundtrips", () => {
    const plaintext = "testpassword123";
    const ciphertext = encrypt(plaintext, TEST_KEY);
    expect(ciphertext).toBeInstanceOf(Buffer);
    expect(ciphertext.length).toBeGreaterThan(0);
    expect(decrypt(ciphertext, TEST_KEY)).toBe(plaintext);
  });

  test("decrypt is stable (same input = same output)", () => {
    const plaintext = "hello";
    const a = encrypt(plaintext, TEST_KEY);
    const b = encrypt(plaintext, TEST_KEY);
    expect(a).toEqual(b);
  });

  test("different plaintexts produce different ciphertexts", () => {
    const a = encrypt("alpha", TEST_KEY);
    const b = encrypt("bravo", TEST_KEY);
    expect(a).not.toEqual(b);
  });
});
