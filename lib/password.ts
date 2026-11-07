import "server-only";

import { randomBytes, scrypt, timingSafeEqual } from "node:crypto";

const version = "scrypt-v1";
const saltBytes = 16;
const hashBytes = 32;
const encodedHash = /^scrypt-v1\$([0-9a-f]{32})\$([0-9a-f]{64})$/;
const options = { N: 32768, r: 8, p: 3, maxmem: 48 * 1024 * 1024 };

function derive(password: string, salt: Buffer) {
  return new Promise<Buffer>((resolve, reject) => {
    scrypt(password, salt, hashBytes, options, (error, key) => {
      if (error) reject(error);
      else resolve(key);
    });
  });
}

export async function hashPassword(password: string) {
  const salt = randomBytes(saltBytes);
  const hash = await derive(password, salt);
  return [version, salt.toString("hex"), hash.toString("hex")].join("$");
}

export async function verifyPassword(password: string, storedHash: string | undefined) {
  // Unknown usernames still take the same password-derivation path.
  const parts = storedHash?.match(encodedHash);
  const salt = parts ? Buffer.from(parts[1], "hex") : Buffer.alloc(saltBytes);
  const expected = parts ? Buffer.from(parts[2], "hex") : Buffer.alloc(hashBytes);
  const actual = await derive(password, salt);
  return timingSafeEqual(actual, expected) && Boolean(parts);
}
