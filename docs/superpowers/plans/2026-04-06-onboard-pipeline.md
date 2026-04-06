# bin/onboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `bin/onboard` — a single CLI command that provisions a new employee across Google Workspace, Amberjack, Phenix, Twilio, and generates a Zoiper config file.

**Architecture:** Pipeline of step modules sharing a Context object. Each step has `check()` (idempotency) and `run()` methods. Entry point parses CLI args, loads `.env`, runs steps in order, prints summary.

**Tech Stack:** Bun + TypeScript, `postgres` (porsager/postgres) for DB, `googleapis` for Google Admin SDK, native `fetch` for Twilio REST API, `gum` CLI for interactive prompts, Node.js `crypto` for AES-256-ECB encryption.

**Spec:** `docs/superpowers/specs/2026-04-06-onboard-pipeline-design.md`

---

## File Structure

```
bin/onboard                  CLI entry point (Bun shebang)
src/onboard/types.ts         Context and Step interfaces
src/onboard/run.ts           Orchestrator — runs steps in sequence
src/onboard/steps/google.ts       Step 1: Google Workspace account
src/onboard/steps/amberjack.ts    Step 2: Amberjack Employee + Access
src/onboard/steps/phenix.ts       Step 3: Phenix Agent + skills + team
src/onboard/steps/twilio.ts       Step 4: TaskRouter worker + SIP creds
src/onboard/steps/direct-line.ts  Step 5: Buy phone number (optional)
src/onboard/steps/zoiper.ts       Step 6: Generate Zoiper Config.xml
src/onboard/lib/db.ts             Postgres connection helpers
src/onboard/lib/prompt.ts         gum wrapper for interactive prompts
src/onboard/lib/crypto.ts         AES-256-ECB encrypt/decrypt
src/onboard/lib/password.ts       Password generators (words + random)
src/onboard/lib/summary.ts        Format + print summary output
src/onboard/lib/twilio.ts         Twilio REST API helpers
src/onboard/lib/google.ts         Google Admin SDK auth helper
test/crypto.test.ts               Tests for AES encryption
test/password.test.ts             Tests for password generators
test/zoiper.test.ts               Tests for Config.xml generation
.env.example                      Template with all required env vars
```

---

### Task 1: Project Scaffolding

**Files:**
- Modify: `package.json`
- Create: `src/onboard/types.ts`
- Create: `.env.example`
- Create: `bin/onboard`

- [ ] **Step 1: Install dependencies**

Run:
```bash
bun add postgres googleapis
```

- [ ] **Step 2: Create .env.example**

Create `.env.example`:
```env
# Google Workspace (service account with domain-wide delegation)
GOOGLE_SERVICE_ACCOUNT_KEY=./service-account.json
GOOGLE_ADMIN_EMAIL=admin@ameriglide.com

# Amberjack DB
AMBERJACK_DATABASE_URL=postgresql://aj:PASSWORD@host:25060/aj?sslmode=require

# Phenix DB
PHENIX_DATABASE_URL=postgresql://phenix:PASSWORD@host:25060/phenix?sslmode=require

# Twilio
TWILIO_ACCOUNT_SID=AC...
TWILIO_AUTH_TOKEN=...
TWILIO_WORKSPACE_SID=WSa872a1cc13360fa91e74ceefa9adab3e
TWILIO_CREDENTIAL_LIST_SID=CLef996d536b7d15b6caea3528d879336d
TWILIO_TWIML_APP_SID=APb87ac09d7487f42163b8fad4897db52c

# AES-256 encryption key (base64-encoded, 32 bytes decoded)
AES_KEY=

# Tailscale (existing, used by bin/copy)
TAILSCALE_AUTH_KEY=
```

- [ ] **Step 3: Create types.ts**

Create `src/onboard/types.ts`:
```ts
export interface Context {
  firstName: string;
  lastName: string;
  email: string;
  directLine: boolean | undefined; // true=yes, false=no, undefined=ask

  // Populated by steps:
  googlePassword?: string | null; // null = already existed
  amberjackEmployeeId?: number;
  phenixAgentId?: number;
  twilioWorkerSid?: string;
  sipUsername?: string;
  sipPassword?: string | null; // null = already existed
  credentialSid?: string;
  phoneNumber?: string;
  zoiperConfigPath?: string;
}

export interface Step {
  name: string;
  check(ctx: Context): Promise<boolean>; // true = already done
  run(ctx: Context): Promise<void>;
}
```

- [ ] **Step 4: Create bin/onboard entry point (stub)**

Create `bin/onboard`:
```ts
#!/usr/bin/env bun

import { parseArgs } from "util";
import { run } from "../src/onboard/run";
import type { Context } from "../src/onboard/types";

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    first: { type: "string" },
    last: { type: "string" },
    "direct-line": { type: "boolean", default: false },
  },
  strict: true,
});

// If --direct-line was not passed at all, set to undefined (will prompt)
const directLine = Bun.argv.includes("--direct-line") ? true : undefined;

const firstName = values.first ?? (await prompt("First name"));
const lastName = values.last ?? (await prompt("Last name"));

if (!firstName || !lastName) {
  console.error("First and last name are required.");
  process.exit(1);
}

const email = `${firstName.toLowerCase()}.${lastName.toLowerCase()}@ameriglide.com`;

const ctx: Context = { firstName, lastName, email, directLine };

await run(ctx);

async function prompt(label: string): Promise<string> {
  // Placeholder — will use gum in lib/prompt.ts
  const proc = Bun.spawn(["gum", "input", "--placeholder", label, "--prompt", `${label}: `], {
    stdin: "inherit",
    stdout: "pipe",
    stderr: "inherit",
  });
  const text = await new Response(proc.stdout).text();
  return text.trim();
}
```

- [ ] **Step 5: Make bin/onboard executable**

Run:
```bash
chmod +x bin/onboard
```

- [ ] **Step 6: Create orchestrator stub**

Create `src/onboard/run.ts`:
```ts
import type { Context, Step } from "./types";

export async function run(ctx: Context): Promise<void> {
  const steps: Step[] = [
    // Steps will be added as we build them
  ];

  for (const step of steps) {
    console.log(`\nChecking ${step.name}...`);
    const done = await step.check(ctx);
    if (done) {
      console.log(`  ✓ ${step.name} — already done, skipping`);
      continue;
    }
    console.log(`Running ${step.name}...`);
    await step.run(ctx);
    console.log(`  ✓ ${step.name} — done`);
  }
}
```

- [ ] **Step 7: Commit**

```bash
git add bin/onboard src/onboard/types.ts src/onboard/run.ts .env.example package.json bun.lock
git commit -m "feat: scaffold bin/onboard with types, orchestrator stub, and deps"
```

---

### Task 2: Shared Libraries — Crypto, Passwords, Prompts, DB

**Files:**
- Create: `src/onboard/lib/crypto.ts`
- Create: `src/onboard/lib/password.ts`
- Create: `src/onboard/lib/prompt.ts`
- Create: `src/onboard/lib/db.ts`
- Create: `test/crypto.test.ts`
- Create: `test/password.test.ts`

- [ ] **Step 1: Write crypto tests**

Create `test/crypto.test.ts`:
```ts
import { describe, expect, test } from "bun:test";
import { encrypt, decrypt } from "../src/onboard/lib/crypto";

// The Phenix app uses AES/ECB/PKCS5PADDING with a base64-encoded 32-byte key.
// We need to produce identical ciphertext so Phenix can decrypt our SIP secrets.
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
    // ECB mode is deterministic — same plaintext always produces same ciphertext
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
```

- [ ] **Step 2: Run crypto tests to verify they fail**

Run: `bun test test/crypto.test.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Implement crypto.ts**

Create `src/onboard/lib/crypto.ts`:
```ts
import { createCipheriv, createDecipheriv } from "crypto";

/**
 * AES-256-ECB encryption, matching Phenix's Java Security class:
 *   Cipher.getInstance("AES/ECB/PKCS5PADDING")
 *
 * ECB mode does not use an IV (pass empty buffer).
 */
export function encrypt(plaintext: string, key: Buffer): Buffer {
  const cipher = createCipheriv("aes-256-ecb", key, null);
  return Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
}

export function decrypt(ciphertext: Buffer, key: Buffer): string {
  const decipher = createDecipheriv("aes-256-ecb", key, null);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
}
```

- [ ] **Step 4: Run crypto tests to verify they pass**

Run: `bun test test/crypto.test.ts`
Expected: PASS (3 tests)

- [ ] **Step 5: Write password tests**

Create `test/password.test.ts`:
```ts
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
    // Astronomically unlikely to collide
    expect(a).not.toBe(b);
  });
});

describe("generateSipPassword", () => {
  test("returns 16 characters", () => {
    expect(generateSipPassword()).toHaveLength(16);
  });

  test("contains at least 1 uppercase, 1 lowercase, 1 digit", () => {
    // Run several times to account for randomness
    for (let i = 0; i < 20; i++) {
      const pw = generateSipPassword();
      expect(pw).toMatch(/[A-Z]/);
      expect(pw).toMatch(/[a-z]/);
      expect(pw).toMatch(/[0-9]/);
    }
  });
});
```

- [ ] **Step 6: Run password tests to verify they fail**

Run: `bun test test/password.test.ts`
Expected: FAIL — module not found

- [ ] **Step 7: Implement password.ts**

Create `src/onboard/lib/password.ts`:
```ts
import { randomInt } from "crypto";

// ~400 common English words, easy to pronounce and dictate.
// Curated to avoid homophones, offensive words, and confusing spellings.
const WORDS = [
  "apple", "arrow", "badge", "baker", "beach", "blade", "blaze", "bloom",
  "board", "bonus", "brave", "brick", "brush", "cabin", "candy", "cargo",
  "cedar", "chain", "chalk", "chart", "chess", "chief", "chord", "civic",
  "claim", "clash", "clay", "cliff", "climb", "clock", "cloud", "coach",
  "coast", "coral", "craft", "crane", "creek", "crisp", "crown", "crush",
  "curve", "dairy", "dance", "delta", "depot", "derby", "disco", "dodge",
  "draft", "drain", "dream", "drift", "drive", "drone", "drums", "eagle",
  "earth", "ember", "equal", "event", "fable", "fairy", "feast", "fence",
  "fiber", "field", "final", "flame", "flash", "flask", "fleet", "flint",
  "float", "flood", "flora", "flute", "focal", "forge", "forum", "frost",
  "fruit", "gamma", "gauge", "genre", "ghost", "giant", "glade", "glass",
  "gleam", "globe", "glove", "grain", "grand", "grape", "grasp", "green",
  "grove", "guard", "guide", "haven", "heart", "hedge", "herbs", "heron",
  "honey", "horse", "house", "humor", "ivory", "jewel", "joint", "judge",
  "juice", "kayak", "knack", "kneel", "knife", "lance", "latch", "layer",
  "lemon", "level", "light", "lilac", "linen", "lodge", "lunar", "lyric",
  "magic", "manor", "maple", "march", "marsh", "medal", "melon", "mercy",
  "metal", "minor", "mixer", "model", "money", "moose", "mound", "music",
  "nerve", "noble", "north", "novel", "ocean", "olive", "opera", "orbit",
  "organ", "otter", "outer", "oxide", "ozone", "paint", "panel", "paper",
  "paste", "patch", "pearl", "penny", "perch", "pilot", "pinch", "pixel",
  "pizza", "plain", "plane", "plant", "plaza", "plume", "plumb", "polar",
  "poppy", "power", "press", "pride", "prism", "prize", "proof", "prose",
  "pulse", "punch", "quest", "quick", "quiet", "quilt", "quota", "radar",
  "ranch", "raven", "realm", "reign", "relay", "ridge", "rival", "river",
  "robin", "rocky", "rouge", "round", "royal", "ruby", "ruler", "saint",
  "salad", "scale", "scene", "scout", "seven", "shade", "shark", "sharp",
  "sheep", "shelf", "shell", "shift", "shirt", "shore", "shown", "sight",
  "silky", "slate", "slice", "slope", "smart", "smith", "smoke", "snake",
  "solar", "solid", "sonic", "south", "space", "spark", "spear", "spice",
  "spike", "spine", "spoke", "squad", "staff", "stage", "stake", "stamp",
  "stand", "stare", "stark", "start", "steam", "steel", "steep", "stern",
  "stock", "stone", "storm", "stove", "strap", "straw", "strip", "sugar",
  "surge", "swamp", "sweet", "swept", "swift", "sword", "table", "thorn",
  "tiger", "timer", "toast", "topaz", "torch", "total", "tower", "trace",
  "track", "trade", "trail", "train", "trait", "trend", "trial", "tribe",
  "trick", "trout", "trunk", "trust", "tulip", "tuner", "ultra", "unity",
  "upper", "urban", "valid", "valor", "vault", "verse", "vigor", "vinyl",
  "viola", "vivid", "vocal", "voice", "wagon", "watch", "water", "whale",
  "wheat", "wheel", "white", "width", "world", "wrist", "yacht", "youth",
  "zebra", "bloom", "bluff", "briar", "cairn", "cider", "cloak", "creed",
  "ember", "haven", "ivory", "lotus", "oasis", "plaid", "quest", "relic",
  "sable", "talon", "umbra", "vista", "whelk", "xenon", "arbor", "basin",
];

/** 4 random words, hyphenated, initial caps. e.g. "Tiger-Maple-Cloud-Seven" */
export function generateTempPassword(): string {
  const picked: string[] = [];
  while (picked.length < 4) {
    const word = WORDS[randomInt(WORDS.length)];
    if (!picked.includes(word)) {
      picked.push(word[0].toUpperCase() + word.slice(1));
    }
  }
  return picked.join("-");
}

const UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const LOWER = "abcdefghijklmnopqrstuvwxyz";
const DIGITS = "0123456789";
const ALL = UPPER + LOWER + DIGITS;

/** Random 16-char password with at least 1 uppercase, 1 lowercase, 1 digit. */
export function generateSipPassword(): string {
  let pw: string;
  do {
    pw = Array.from({ length: 16 }, () => ALL[randomInt(ALL.length)]).join("");
  } while (!/[A-Z]/.test(pw) || !/[a-z]/.test(pw) || !/[0-9]/.test(pw));
  return pw;
}
```

- [ ] **Step 8: Run password tests to verify they pass**

Run: `bun test test/password.test.ts`
Expected: PASS (4 tests)

- [ ] **Step 9: Implement prompt.ts**

Create `src/onboard/lib/prompt.ts`:
```ts
/** Run gum and return trimmed stdout. */
async function gum(args: string[]): Promise<string> {
  const proc = Bun.spawn(["gum", ...args], {
    stdin: "inherit",
    stdout: "pipe",
    stderr: "inherit",
  });
  const text = await new Response(proc.stdout).text();
  const code = await proc.exited;
  if (code !== 0) throw new Error(`gum exited with code ${code}`);
  return text.trim();
}

/** Prompt for a single line of text. */
export async function input(label: string): Promise<string> {
  return gum(["input", "--prompt", `${label}: `, "--placeholder", label]);
}

/** Single-select from a list. Returns the chosen item. */
export async function choose(items: string[]): Promise<string> {
  return gum(["choose", ...items]);
}

/** Multi-select from a list. Returns chosen items (one per line). */
export async function chooseMulti(items: string[]): Promise<string[]> {
  const result = await gum(["choose", "--no-limit", ...items]);
  return result.split("\n").filter(Boolean);
}

/** Yes/no confirmation. Returns true if confirmed. */
export async function confirm(message: string): Promise<boolean> {
  const proc = Bun.spawn(["gum", "confirm", message], {
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
  const code = await proc.exited;
  return code === 0;
}
```

- [ ] **Step 10: Implement db.ts**

Create `src/onboard/lib/db.ts`:
```ts
import postgres from "postgres";

let amberjack: ReturnType<typeof postgres> | null = null;
let phenix: ReturnType<typeof postgres> | null = null;

export function getAmberjack() {
  if (!amberjack) {
    const url = process.env.AMBERJACK_DATABASE_URL;
    if (!url) throw new Error("AMBERJACK_DATABASE_URL not set");
    amberjack = postgres(url);
  }
  return amberjack;
}

export function getPhenix() {
  if (!phenix) {
    const url = process.env.PHENIX_DATABASE_URL;
    if (!url) throw new Error("PHENIX_DATABASE_URL not set");
    phenix = postgres(url);
  }
  return phenix;
}

export async function closeAll() {
  if (amberjack) await amberjack.end();
  if (phenix) await phenix.end();
}
```

- [ ] **Step 11: Commit**

```bash
git add src/onboard/lib/ test/
git commit -m "feat: add shared libs — crypto, password, prompt, db"
```

---

### Task 3: Google Workspace Step

**Files:**
- Create: `src/onboard/lib/google.ts`
- Create: `src/onboard/steps/google.ts`
- Modify: `src/onboard/run.ts`

- [ ] **Step 1: Implement Google auth helper**

Create `src/onboard/lib/google.ts`:
```ts
import { google } from "googleapis";

/**
 * Authenticate as a service account with domain-wide delegation,
 * impersonating the admin user. Returns an Admin SDK directory client.
 */
export async function getDirectoryClient() {
  const keyPath = process.env.GOOGLE_SERVICE_ACCOUNT_KEY;
  const adminEmail = process.env.GOOGLE_ADMIN_EMAIL;
  if (!keyPath) throw new Error("GOOGLE_SERVICE_ACCOUNT_KEY not set");
  if (!adminEmail) throw new Error("GOOGLE_ADMIN_EMAIL not set");

  const auth = new google.auth.GoogleAuth({
    keyFile: keyPath,
    scopes: ["https://www.googleapis.com/auth/admin.directory.user"],
    clientOptions: { subject: adminEmail },
  });

  return google.admin({ version: "directory_v1", auth });
}
```

- [ ] **Step 2: Implement Google step**

Create `src/onboard/steps/google.ts`:
```ts
import type { Step, Context } from "../types";
import { getDirectoryClient } from "../lib/google";
import { generateTempPassword } from "../lib/password";

export const googleStep: Step = {
  name: "Google Workspace",

  async check(ctx: Context): Promise<boolean> {
    const admin = await getDirectoryClient();
    try {
      await admin.users.get({ userKey: ctx.email });
      ctx.googlePassword = null; // exists, password unknown
      return true;
    } catch (e: any) {
      if (e.code === 404) return false;
      throw e;
    }
  },

  async run(ctx: Context): Promise<void> {
    const admin = await getDirectoryClient();
    const password = generateTempPassword();

    await admin.users.insert({
      requestBody: {
        primaryEmail: ctx.email,
        name: { givenName: ctx.firstName, familyName: ctx.lastName },
        password,
        changePasswordAtNextLogin: true,
      },
    });

    ctx.googlePassword = password;
  },
};
```

- [ ] **Step 3: Wire Google step into orchestrator**

Modify `src/onboard/run.ts`:
```ts
import type { Context, Step } from "./types";
import { googleStep } from "./steps/google";

export async function run(ctx: Context): Promise<void> {
  const steps: Step[] = [
    googleStep,
    // More steps added in subsequent tasks
  ];

  for (const step of steps) {
    console.log(`\nChecking ${step.name}...`);
    const done = await step.check(ctx);
    if (done) {
      console.log(`  ✓ ${step.name} — already done, skipping`);
      continue;
    }
    console.log(`Running ${step.name}...`);
    await step.run(ctx);
    console.log(`  ✓ ${step.name} — done`);
  }
}
```

- [ ] **Step 4: Commit**

```bash
git add src/onboard/lib/google.ts src/onboard/steps/google.ts src/onboard/run.ts
git commit -m "feat: add Google Workspace step — create user with temp password"
```

---

### Task 4: Amberjack Step

**Files:**
- Create: `src/onboard/steps/amberjack.ts`
- Modify: `src/onboard/run.ts`

- [ ] **Step 1: Implement Amberjack step**

Create `src/onboard/steps/amberjack.ts`:

```ts
import type { Step, Context } from "../types";
import { getAmberjack } from "../lib/db";

// Weborder permission assets
const ACCESS_ASSETS = [2, 3, 4, 5, 6, 21];

export const amberjackStep: Step = {
  name: "Amberjack",

  async check(ctx: Context): Promise<boolean> {
    const sql = getAmberjack();
    const [row] = await sql`SELECT id FROM employee WHERE email = ${ctx.email}`;
    if (row) {
      ctx.amberjackEmployeeId = row.id;
      return true;
    }
    return false;
  },

  async run(ctx: Context): Promise<void> {
    const sql = getAmberjack();
    const name = `${ctx.firstName.toLowerCase()}.${ctx.lastName.toLowerCase()}`;

    await sql.begin(async (tx) => {
      const [emp] = await tx`
        INSERT INTO employee (name, firstname, lastname, email, phone, locked, admin, sudoer, jumpcloudorg)
        VALUES (${name}, ${ctx.firstName}, ${ctx.lastName}, ${ctx.email}, ${name}, false, false, false, 1)
        RETURNING id
      `;

      for (const asset of ACCESS_ASSETS) {
        await tx`
          INSERT INTO access (employee, asset, role, role_policy)
          VALUES (${emp.id}, ${asset}, 2, 2)
        `;
      }

      ctx.amberjackEmployeeId = emp.id;
    });
  },
};
```

- [ ] **Step 2: Add to orchestrator**

Modify `src/onboard/run.ts` — add import and append to steps array:
```ts
import { amberjackStep } from "./steps/amberjack";

// In the steps array:
const steps: Step[] = [
  googleStep,
  amberjackStep,
];
```

- [ ] **Step 3: Commit**

```bash
git add src/onboard/steps/amberjack.ts src/onboard/run.ts
git commit -m "feat: add Amberjack step — create Employee + Access records"
```

---

### Task 5: Phenix Step

**Files:**
- Create: `src/onboard/steps/phenix.ts`
- Modify: `src/onboard/run.ts`

- [ ] **Step 1: Implement Phenix step**

Create `src/onboard/steps/phenix.ts`:

```ts
import type { Step, Context } from "../types";
import { getPhenix } from "../lib/db";
import { choose, chooseMulti } from "../lib/prompt";

export const phenixStep: Step = {
  name: "Phenix",

  async check(ctx: Context): Promise<boolean> {
    const sql = getPhenix();
    const [row] = await sql`SELECT id FROM agent WHERE email = ${ctx.email}`;
    if (row) {
      ctx.phenixAgentId = row.id;
      return true;
    }
    return false;
  },

  async run(ctx: Context): Promise<void> {
    const sql = getPhenix();

    // Query available options from DB
    // channel: id, name, abbreviation (e.g. 1, "Phone", "PHONE")
    const channels = await sql`SELECT id, name, abbreviation FROM channel ORDER BY name`;
    // skill: value, attribute (e.g. "SALES", null) — primary key is "value"
    const skills = await sql`SELECT value, attribute FROM skill ORDER BY value`;
    // productline: id, name, abbreviation (e.g. 1, "Stairlifts", "SL")
    const products = await sql`SELECT id, name, abbreviation FROM productline ORDER BY name`;

    // Interactive selection
    console.log("\nSelect channel:");
    const channelName = await choose(channels.map((c) => c.name));
    const channel = channels.find((c) => c.name === channelName)!;

    console.log("\nSelect skill/role:");
    const skillValue = await choose(skills.map((s) => s.value));

    console.log("\nSelect products (space to toggle, enter to confirm):");
    const productItems = ["all", ...products.map((p) => p.name)];
    const selectedNames = await chooseMulti(productItems);

    let selectedProducts = products;
    if (!selectedNames.includes("all")) {
      selectedProducts = products.filter((p) => selectedNames.includes(p.name));
    }

    await sql.begin(async (tx) => {
      const [agent] = await tx`
        INSERT INTO agent (firstname, lastname, email, active)
        VALUES (${ctx.firstName}, ${ctx.lastName}, ${ctx.email}, true)
        RETURNING id
      `;

      // Add channel (agentchannel table, composite PK: agent + channel)
      await tx`
        INSERT INTO agentchannel (agent, channel)
        VALUES (${agent.id}, ${channel.id})
      `;

      // Add product skills (productskill table, composite PK: agent + product)
      // One row per product for the selected skill, backup=false
      for (const product of selectedProducts) {
        await tx`
          INSERT INTO productskill (agent, product, skill, backup)
          VALUES (${agent.id}, ${product.id}, ${skillValue}, false)
        `;
      }

      // Add to team 8
      await tx`
        INSERT INTO teammember (team, agent)
        VALUES (8, ${agent.id})
      `;

      ctx.phenixAgentId = agent.id;
    });
  },
};
```

- [ ] **Step 2: Add to orchestrator**

Modify `src/onboard/run.ts` — add import and append to steps array:
```ts
import { phenixStep } from "./steps/phenix";

const steps: Step[] = [
  googleStep,
  amberjackStep,
  phenixStep,
];
```

- [ ] **Step 3: Commit**

```bash
git add src/onboard/steps/phenix.ts src/onboard/run.ts
git commit -m "feat: add Phenix step — create Agent with channels, skills, and team"
```

---

### Task 6: Twilio Step

**Files:**
- Create: `src/onboard/lib/twilio.ts`
- Create: `src/onboard/steps/twilio.ts`
- Modify: `src/onboard/run.ts`

- [ ] **Step 1: Implement Twilio REST helpers**

Create `src/onboard/lib/twilio.ts`:

```ts
type TwilioEnv = {
  accountSid: string;
  authToken: string;
  workspaceSid: string;
  credentialListSid: string;
};

function getEnv(): TwilioEnv {
  const accountSid = process.env.TWILIO_ACCOUNT_SID;
  const authToken = process.env.TWILIO_AUTH_TOKEN;
  const workspaceSid = process.env.TWILIO_WORKSPACE_SID;
  const credentialListSid = process.env.TWILIO_CREDENTIAL_LIST_SID;
  if (!accountSid || !authToken || !workspaceSid || !credentialListSid) {
    throw new Error("Missing TWILIO_* environment variables");
  }
  return { accountSid, authToken, workspaceSid, credentialListSid };
}

function authHeaders(env: TwilioEnv): HeadersInit {
  const basic = Buffer.from(`${env.accountSid}:${env.authToken}`).toString("base64");
  return { Authorization: `Basic ${basic}` };
}

async function twilioFetch(url: string, init?: RequestInit): Promise<any> {
  const env = getEnv();
  const res = await fetch(url, {
    ...init,
    headers: { ...authHeaders(env), ...init?.headers },
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Twilio API ${res.status}: ${body}`);
  }
  return res.json();
}

async function twilioPost(url: string, params: Record<string, string>): Promise<any> {
  const env = getEnv();
  const res = await fetch(url, {
    method: "POST",
    headers: {
      ...authHeaders(env),
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams(params),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Twilio API ${res.status}: ${body}`);
  }
  return res.json();
}

const BASE = "https://api.twilio.com/2010-04-01";
const TASKROUTER = "https://taskrouter.twilio.com/v1";

/** Search for a TaskRouter worker by email in attributes. */
export async function findWorkerByEmail(email: string): Promise<{ sid: string } | null> {
  const env = getEnv();
  // TaskRouter worker list supports FriendlyName filter but not attribute search.
  // We need to list and search. Page through up to 100 workers.
  const url = `${TASKROUTER}/Workspaces/${env.workspaceSid}/Workers?PageSize=100`;
  const data = await twilioFetch(url);
  for (const w of data.workers) {
    try {
      const attrs = JSON.parse(w.attributes);
      if (attrs.email === email) return { sid: w.sid };
    } catch {}
  }
  return null;
}

/** Create a TaskRouter worker. */
export async function createWorker(
  friendlyName: string,
  attributes: Record<string, any>,
): Promise<string> {
  const env = getEnv();
  const url = `${TASKROUTER}/Workspaces/${env.workspaceSid}/Workers`;
  const data = await twilioPost(url, {
    FriendlyName: friendlyName,
    Attributes: JSON.stringify(attributes),
  });
  return data.sid;
}

/** Update a worker's attributes. */
export async function updateWorkerAttributes(
  workerSid: string,
  attributes: Record<string, any>,
): Promise<void> {
  const env = getEnv();
  const url = `${TASKROUTER}/Workspaces/${env.workspaceSid}/Workers/${workerSid}`;
  await twilioPost(url, { Attributes: JSON.stringify(attributes) });
}

/** List SIP credentials, search by username. */
export async function findCredentialByUsername(username: string): Promise<{ sid: string } | null> {
  const env = getEnv();
  const url = `${BASE}/Accounts/${env.accountSid}/SIP/CredentialLists/${env.credentialListSid}/Credentials.json?PageSize=100`;
  const data = await twilioFetch(url);
  const cred = data.credentials.find((c: any) => c.username === username);
  return cred ? { sid: cred.sid } : null;
}

/** Create a SIP credential. */
export async function createCredential(username: string, password: string): Promise<string> {
  const env = getEnv();
  const url = `${BASE}/Accounts/${env.accountSid}/SIP/CredentialLists/${env.credentialListSid}/Credentials.json`;
  const data = await twilioPost(url, { Username: username, Password: password });
  return data.sid;
}

/** Search available local phone numbers. */
export async function searchLocalNumbers(
  areaCode?: string,
  inLocality?: string,
): Promise<Array<{ phoneNumber: string; friendlyName: string; locality: string; region: string }>> {
  const env = getEnv();
  const params = new URLSearchParams();
  if (areaCode) params.set("AreaCode", areaCode);
  if (inLocality) params.set("InLocality", inLocality);
  params.set("VoiceEnabled", "true");
  params.set("SmsEnabled", "false");
  const url = `${BASE}/Accounts/${env.accountSid}/AvailablePhoneNumbers/US/Local.json?${params}`;
  const data = await twilioFetch(url);
  return data.available_phone_numbers.map((n: any) => ({
    phoneNumber: n.phone_number,
    friendlyName: n.friendly_name,
    locality: n.locality,
    region: n.region,
  }));
}

/** Buy a phone number and configure it with the TwiML app. */
export async function buyNumber(phoneNumber: string): Promise<string> {
  const env = getEnv();
  const twimlAppSid = process.env.TWILIO_TWIML_APP_SID;
  if (!twimlAppSid) throw new Error("TWILIO_TWIML_APP_SID not set");
  const url = `${BASE}/Accounts/${env.accountSid}/IncomingPhoneNumbers.json`;
  const data = await twilioPost(url, {
    PhoneNumber: phoneNumber,
    VoiceApplicationSid: twimlAppSid,
  });
  return data.sid;
}
```

- [ ] **Step 2: Implement Twilio step**

Create `src/onboard/steps/twilio.ts`:

```ts
import type { Step, Context } from "../types";
import { getPhenix } from "../lib/db";
import { encrypt } from "../lib/crypto";
import { generateSipPassword } from "../lib/password";
import {
  findWorkerByEmail,
  createWorker,
  updateWorkerAttributes,
  findCredentialByUsername,
  createCredential,
} from "../lib/twilio";

export const twilioStep: Step = {
  name: "Twilio",

  async check(ctx: Context): Promise<boolean> {
    const worker = await findWorkerByEmail(ctx.email);
    if (worker) {
      ctx.twilioWorkerSid = worker.sid;
      ctx.sipUsername = `${ctx.firstName.toLowerCase()}.${ctx.lastName.toLowerCase()}`;
      ctx.sipPassword = null; // exists, password unknown
      return true;
    }
    return false;
  },

  async run(ctx: Context): Promise<void> {
    const sql = getPhenix();
    const sipUser = `${ctx.firstName.toLowerCase()}.${ctx.lastName.toLowerCase()}`;
    const sipPassword = generateSipPassword();

    // 1. Create or find SIP credential
    let credSid: string;
    const existing = await findCredentialByUsername(sipUser);
    if (existing) {
      console.log(`  SIP credential for ${sipUser} already exists, reusing`);
      credSid = existing.sid;
    } else {
      credSid = await createCredential(sipUser, sipPassword);
    }

    // 2. Encrypt and store SIP secret in Phenix
    const aesKeyB64 = process.env.AES_KEY;
    if (!aesKeyB64) throw new Error("AES_KEY not set");
    const aesKey = Buffer.from(aesKeyB64, "base64");
    const encryptedSecret = encrypt(sipPassword, aesKey);

    const sipUri = `sip:${sipUser}@ameriglide.pstn.twilio.com`;

    await sql`
      UPDATE agent
      SET sip_secret = ${encryptedSecret},
          sip_uri = ${sipUri},
          credential_sid = ${credSid},
          call_routing_mode = 'SIP'
      WHERE id = ${ctx.phenixAgentId}
    `;

    // 3. Build worker attributes from agent's productskills and channels
    // Uses abbreviations, matching Phenix's Agent.getWorkerAttributes() format:
    // { "roles": ["SALES"], "SALES": { "primary": ["SL", "EL"], "backup": [] }, "channels": ["PHONE"] }
    const productSkills = await sql`
      SELECT ps.skill, ps.backup, pl.abbreviation AS product_abbr
      FROM productskill ps
      JOIN productline pl ON pl.id = ps.product
      WHERE ps.agent = ${ctx.phenixAgentId}
    `;
    const channels = await sql`
      SELECT c.abbreviation FROM agentchannel ac JOIN channel c ON c.id = ac.channel WHERE ac.agent = ${ctx.phenixAgentId}
    `;

    // Group products by skill, split into primary/backup
    const skillMap = new Map<string, { primary: string[]; backup: string[] }>();
    for (const ps of productSkills) {
      if (!skillMap.has(ps.skill)) skillMap.set(ps.skill, { primary: [], backup: [] });
      const entry = skillMap.get(ps.skill)!;
      if (ps.backup) entry.backup.push(ps.product_abbr);
      else entry.primary.push(ps.product_abbr);
    }

    const attributes: Record<string, any> = {
      email: ctx.email,
      roles: [...skillMap.keys()],
      channels: channels.map((c) => c.abbreviation),
    };
    for (const [skill, products] of skillMap) {
      attributes[skill] = products;
    }

    // 4. Create TaskRouter worker
    const workerSid = await createWorker(
      `${ctx.firstName} ${ctx.lastName}`,
      attributes,
    );

    // 5. Store worker SID in Phenix
    await sql`UPDATE agent SET sid = ${workerSid} WHERE id = ${ctx.phenixAgentId}`;

    ctx.sipUsername = sipUser;
    ctx.sipPassword = sipPassword;
    ctx.credentialSid = credSid;
    ctx.twilioWorkerSid = workerSid;
  },
};
```

- [ ] **Step 3: Add to orchestrator**

Modify `src/onboard/run.ts`:
```ts
import { twilioStep } from "./steps/twilio";

const steps: Step[] = [
  googleStep,
  amberjackStep,
  phenixStep,
  twilioStep,
];
```

- [ ] **Step 4: Commit**

```bash
git add src/onboard/lib/twilio.ts src/onboard/steps/twilio.ts src/onboard/run.ts
git commit -m "feat: add Twilio step — SIP credentials + TaskRouter worker"
```

---

### Task 7: Direct Line Step

**Files:**
- Create: `src/onboard/steps/direct-line.ts`
- Modify: `src/onboard/run.ts`

- [ ] **Step 1: Implement direct-line step**

Create `src/onboard/steps/direct-line.ts`:

```ts
import type { Step, Context } from "../types";
import { getPhenix } from "../lib/db";
import { input, choose, confirm } from "../lib/prompt";
import { searchLocalNumbers, buyNumber } from "../lib/twilio";

export const directLineStep: Step = {
  name: "Direct Line",

  async check(ctx: Context): Promise<boolean> {
    if (ctx.directLine === false) return true; // explicitly declined

    const sql = getPhenix();
    const [row] = await sql`
      SELECT phone_number FROM verified_caller_id WHERE direct = ${ctx.phenixAgentId}
    `;
    if (row) {
      ctx.phoneNumber = row.phone_number;
      return true;
    }
    return false;
  },

  async run(ctx: Context): Promise<void> {
    // If not pre-decided, ask
    if (ctx.directLine === undefined) {
      const yes = await confirm("Buy a direct line for this agent?");
      if (!yes) {
        ctx.directLine = false;
        return;
      }
    }

    const locality = await input("City or area code");

    // Search — try as area code first (3 digits), otherwise as city name
    const isAreaCode = /^\d{3}$/.test(locality);
    const numbers = await searchLocalNumbers(
      isAreaCode ? locality : undefined,
      isAreaCode ? undefined : locality,
    );

    if (numbers.length === 0) {
      console.error(`  No numbers found for "${locality}". Skipping direct line.`);
      return;
    }

    // Present choices
    const labels = numbers.map(
      (n) => `${n.friendlyName}  (${n.locality}, ${n.region})`,
    );
    console.log("\nSelect a phone number:");
    const selected = await choose(labels);
    const idx = labels.indexOf(selected);
    const number = numbers[idx];

    // Buy it
    const numberSid = await buyNumber(number.phoneNumber);

    // Insert verified_caller_id in Phenix
    const sql = getPhenix();
    await sql`
      INSERT INTO verified_caller_id (sid, phone_number, friendly_name, direct, default_outbound)
      VALUES (${numberSid}, ${number.phoneNumber}, ${number.friendlyName}, ${ctx.phenixAgentId}, false)
    `;

    ctx.phoneNumber = number.phoneNumber;
  },
};
```

- [ ] **Step 2: Add to orchestrator**

Modify `src/onboard/run.ts`:
```ts
import { directLineStep } from "./steps/direct-line";

const steps: Step[] = [
  googleStep,
  amberjackStep,
  phenixStep,
  twilioStep,
  directLineStep,
];
```

- [ ] **Step 3: Commit**

```bash
git add src/onboard/steps/direct-line.ts src/onboard/run.ts
git commit -m "feat: add Direct Line step — search, buy, and configure phone number"
```

---

### Task 8: Zoiper Config Step

**Files:**
- Create: `src/onboard/steps/zoiper.ts`
- Create: `test/zoiper.test.ts`
- Modify: `src/onboard/run.ts`

- [ ] **Step 1: Write Zoiper config test**

Create `test/zoiper.test.ts`:

```ts
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
    expect(xml).toContain("<transport>2</transport>"); // TLS
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test test/zoiper.test.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Implement Zoiper step**

Create `src/onboard/steps/zoiper.ts`:

```ts
import { mkdirSync, existsSync } from "fs";
import { join } from "path";
import type { Step, Context } from "../types";

function escapeXml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

export function generateConfig(opts: {
  sipUser: string;
  sipPassword: string;
  sipDomain: string;
}): string {
  return `<?xml version="1.0" encoding="utf-8"?>
<options>
  <accounts>
    <account>
      <name>${escapeXml(opts.sipUser)}</name>
      <username>${escapeXml(opts.sipUser)}</username>
      <password>${escapeXml(opts.sipPassword)}</password>
      <host>${escapeXml(opts.sipDomain)}</host>
      <transport>2</transport>
      <use_rport>1</use_rport>
      <dtmf_style>1</dtmf_style>
      <registration_expiry>600</registration_expiry>
      <use_stun>0</use_stun>
      <codec>
        <codec_id>0</codec_id>
        <priority>0</priority>
        <enabled>1</enabled>
      </codec>
      <codec>
        <codec_id>8</codec_id>
        <priority>1</priority>
        <enabled>1</enabled>
      </codec>
      <codec>
        <codec_id>9</codec_id>
        <priority>2</priority>
        <enabled>1</enabled>
      </codec>
    </account>
  </accounts>
</options>`;
}

export const zoiperStep: Step = {
  name: "Zoiper Config",

  async check(ctx: Context): Promise<boolean> {
    if (!ctx.sipUsername || !ctx.sipPassword) return true; // no SIP creds to write
    const name = `${ctx.firstName.toLowerCase()}-${ctx.lastName.toLowerCase()}`;
    const outPath = join(process.cwd(), "output", `zoiper-${name}.xml`);
    if (existsSync(outPath)) {
      ctx.zoiperConfigPath = outPath;
      return true;
    }
    return false;
  },

  async run(ctx: Context): Promise<void> {
    if (!ctx.sipUsername || !ctx.sipPassword) return;

    const xml = generateConfig({
      sipUser: ctx.sipUsername,
      sipPassword: ctx.sipPassword,
      sipDomain: "ameriglide.pstn.twilio.com",
    });

    const outDir = join(process.cwd(), "output");
    mkdirSync(outDir, { recursive: true });

    const name = `${ctx.firstName.toLowerCase()}-${ctx.lastName.toLowerCase()}`;
    const outPath = join(outDir, `zoiper-${name}.xml`);
    await Bun.write(outPath, xml);

    ctx.zoiperConfigPath = outPath;
  },
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test test/zoiper.test.ts`
Expected: PASS (2 tests)

- [ ] **Step 5: Add output/ to .gitignore**

Append to `.gitignore`:
```
output/
```

- [ ] **Step 6: Add to orchestrator**

Modify `src/onboard/run.ts`:
```ts
import { zoiperStep } from "./steps/zoiper";

const steps: Step[] = [
  googleStep,
  amberjackStep,
  phenixStep,
  twilioStep,
  directLineStep,
  zoiperStep,
];
```

- [ ] **Step 7: Commit**

```bash
git add src/onboard/steps/zoiper.ts test/zoiper.test.ts src/onboard/run.ts .gitignore
git commit -m "feat: add Zoiper step — generate Config.xml with SIP credentials"
```

---

### Task 9: Summary Output & Final Wiring

**Files:**
- Create: `src/onboard/lib/summary.ts`
- Modify: `src/onboard/run.ts`
- Modify: `bin/onboard`

- [ ] **Step 1: Implement summary output**

Create `src/onboard/lib/summary.ts`:

```ts
import type { Context } from "../types";

const LINE = "══════════════════════════════════════════";

export function printSummary(ctx: Context): void {
  console.log(`
${LINE}
  New Employee: ${ctx.firstName} ${ctx.lastName}
  Email: ${ctx.email}
${LINE}

  Google Workspace
    Temp Password: ${ctx.googlePassword ?? "already existed"}

  Amberjack
    Employee ID: ${ctx.amberjackEmployeeId ?? "skipped"}

  Phenix
    Agent ID: ${ctx.phenixAgentId ?? "skipped"}

  Twilio
    Worker SID: ${ctx.twilioWorkerSid ?? "skipped"}
    SIP Username: ${ctx.sipUsername ?? "skipped"}
    SIP Password: ${ctx.sipPassword ?? "already existed"}

  Direct Line
    Phone: ${ctx.phoneNumber ?? "none"}

  Zoiper
    Config: ${ctx.zoiperConfigPath ?? "not generated"}
    Manual: Activate Pro, then copy to %APPDATA%\\Zoiper5\\

${LINE}
  Next: Run bin/copy on the new machine
${LINE}
`);
}
```

- [ ] **Step 2: Wire summary into orchestrator and add error handling + cleanup**

Update `src/onboard/run.ts` to its final form:

```ts
import type { Context, Step } from "./types";
import { googleStep } from "./steps/google";
import { amberjackStep } from "./steps/amberjack";
import { phenixStep } from "./steps/phenix";
import { twilioStep } from "./steps/twilio";
import { directLineStep } from "./steps/direct-line";
import { zoiperStep } from "./steps/zoiper";
import { printSummary } from "./lib/summary";
import { closeAll } from "./lib/db";

const steps: Step[] = [
  googleStep,
  amberjackStep,
  phenixStep,
  twilioStep,
  directLineStep,
  zoiperStep,
];

export async function run(ctx: Context): Promise<void> {
  const completed: string[] = [];

  try {
    for (const step of steps) {
      console.log(`\nChecking ${step.name}...`);
      const done = await step.check(ctx);
      if (done) {
        console.log(`  ✓ ${step.name} — already done, skipping`);
        completed.push(step.name);
        continue;
      }
      console.log(`Running ${step.name}...`);
      await step.run(ctx);
      console.log(`  ✓ ${step.name} — done`);
      completed.push(step.name);
    }

    printSummary(ctx);
  } catch (err) {
    console.error(`\n✗ Failed during step execution\n`);
    console.error(err);
    console.error(`\nCompleted steps: ${completed.join(", ") || "none"}`);
    console.error(`Re-run the same command to resume from where it failed.`);
    process.exit(1);
  } finally {
    await closeAll();
  }
}
```

- [ ] **Step 3: Finalize bin/onboard entry point**

Update `bin/onboard` to its final form:

```ts
#!/usr/bin/env bun

import { parseArgs } from "util";
import { run } from "../src/onboard/run";
import { input } from "../src/onboard/lib/prompt";
import type { Context } from "../src/onboard/types";

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    first: { type: "string" },
    last: { type: "string" },
    "direct-line": { type: "boolean", default: false },
  },
  strict: true,
});

const directLine = Bun.argv.includes("--direct-line") ? true : undefined;

const firstName = values.first ?? (await input("First name"));
const lastName = values.last ?? (await input("Last name"));

if (!firstName || !lastName) {
  console.error("First and last name are required.");
  process.exit(1);
}

const email = `${firstName.toLowerCase()}.${lastName.toLowerCase()}@ameriglide.com`;

console.log(`\nOnboarding ${firstName} ${lastName} (${email})\n`);

const ctx: Context = { firstName, lastName, email, directLine };

await run(ctx);
```

- [ ] **Step 4: Run all tests**

Run: `bun test`
Expected: All 9 tests pass (crypto: 3, password: 4, zoiper: 2)

- [ ] **Step 5: Commit**

```bash
git add src/onboard/lib/summary.ts src/onboard/run.ts bin/onboard
git commit -m "feat: add summary output, error handling, and finalize bin/onboard"
```

---

### Task 10: Manual Integration Test

This task is not automated — it's the checklist for verifying the full pipeline works.

- [ ] **Step 1: Populate .env with real credentials**

Copy `.env.example` to `.env` (already exists, add the new variables):
- `AMBERJACK_DATABASE_URL` — from existing add-agent.sh
- `PHENIX_DATABASE_URL` — from Phenix .env (`PRODUCTION_DB`)
- `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN` — from Phenix .env
- `TWILIO_WORKSPACE_SID`, `TWILIO_CREDENTIAL_LIST_SID`, `TWILIO_TWIML_APP_SID` — from Phenix .env
- `AES_KEY` — from Phenix .env (the `key` variable)
- `GOOGLE_SERVICE_ACCOUNT_KEY`, `GOOGLE_ADMIN_EMAIL` — requires one-time GCP setup

- [ ] **Step 2: Set up Google service account (one-time)**

1. Go to console.cloud.google.com → create project (or reuse existing)
2. Enable "Admin SDK API"
3. Create service account → download JSON key → save as `./service-account.json`
4. Copy the service account's `client_id`
5. Go to Google Workspace Admin → Security → API controls → Domain-wide delegation
6. Add new: Client ID = the `client_id`, Scopes = `https://www.googleapis.com/auth/admin.directory.user`
7. Set `GOOGLE_SERVICE_ACCOUNT_KEY=./service-account.json` and `GOOGLE_ADMIN_EMAIL=admin@ameriglide.com` in `.env`

- [ ] **Step 3: Test with a real onboarding**

Run:
```bash
bin/onboard --first Test --last Agent
```

Verify each step completes. Then run again to verify idempotency (all steps should skip).

- [ ] **Step 4: Clean up test data**

Remove the test employee from Google Workspace, Amberjack, Phenix, and Twilio.
