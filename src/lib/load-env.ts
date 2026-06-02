// Loads the repo-root .env regardless of the current working directory.
//
// Bun only auto-loads `.env` from the cwd, so running a wrapper from inside
// bin/ (e.g. `cd bin && ./onboard`) makes Bun look for `bin/.env` and silently
// find nothing — which has burned us with confusing "missing credential"
// failures. Import this module first, for its side effect, from every bin/
// entrypoint: it resolves the repo-root .env from this file's location and
// warns loudly when no .env is present.
import { existsSync, readFileSync } from "fs";
import { join, resolve } from "path";

// src/lib/load-env.ts -> repo root is two directories up.
const repoRoot = resolve(import.meta.dir, "..", "..");
const envPath = join(repoRoot, ".env");

if (!existsSync(envPath)) {
  console.error(
    `\x1b[33m⚠  No .env found at ${envPath}\x1b[0m\n` +
      `   Commands that need credentials (Google, Twilio, Amberjack, Phenix) will fail.\n` +
      `   Place the shared .env in the repo root and re-run.`,
  );
} else {
  const text = readFileSync(envPath, "utf8");
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;

    const body = line.startsWith("export ") ? line.slice("export ".length) : line;
    const eq = body.indexOf("=");
    if (eq === -1) continue;

    const key = body.slice(0, eq).trim();
    if (!key) continue;

    let value = body.slice(eq + 1).trim();
    // Strip a single layer of matching surrounding quotes.
    if (
      value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'")))
    ) {
      value = value.slice(1, -1);
    }

    // Real environment variables win over .env, matching Bun's own precedence.
    if (process.env[key] === undefined) process.env[key] = value;
  }
}
