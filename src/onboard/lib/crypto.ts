import { createCipheriv, createDecipheriv } from "crypto";

export function encrypt(plaintext: string, key: Buffer): Buffer {
  const cipher = createCipheriv("aes-256-ecb", key, null);
  return Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
}

export function decrypt(ciphertext: Buffer, key: Buffer): string {
  const decipher = createDecipheriv("aes-256-ecb", key, null);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
}
