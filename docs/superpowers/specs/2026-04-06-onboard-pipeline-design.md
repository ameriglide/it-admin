# bin/onboard — Employee Onboarding Pipeline

## Overview

A single CLI command (`bin/onboard`) that provisions a new employee across all systems: Google Workspace, Amberjack, Phenix CRM, Twilio, and generates a Zoiper SIP config file. Replaces the current multi-script, multi-repo manual process with one idempotent pipeline.

**Runtime:** Bun + TypeScript
**Repo:** it-admin (public — no secrets in source)

## CLI Interface

```
bin/onboard [--first NAME] [--last NAME] [--direct-line]
```

- `--first`, `--last`: Optional. If omitted, prompted interactively.
- `--direct-line`: If passed, auto-yes for buying a phone number. If omitted, the user is prompted (y/n) during the direct-line step.
- Email is derived: `firstname.lastname@ameriglide.com` (lowercased).

## Architecture

Pipeline of step modules, each with a common interface:

```
bin/onboard              CLI entry, arg parsing, orchestration
src/steps/google.ts      Create Google Workspace account
src/steps/amberjack.ts   Insert Employee + Access records
src/steps/phenix.ts      Insert Agent + channels + skills + team
src/steps/twilio.ts      TaskRouter worker + SIP credentials
src/steps/direct-line.ts Buy number, configure TwiML, insert VerifiedCallerId
src/steps/zoiper.ts      Generate Zoiper Config.xml
src/lib/db.ts            Shared pg client (Amberjack + Phenix connections)
src/lib/prompt.ts        Wrapper around gum for interactive prompts
src/lib/crypto.ts        AES-256 encrypt for SIP secrets
```

### Step Interface

```ts
interface Step {
  name: string
  check(ctx: Context): Promise<boolean>  // true = already done, skip
  run(ctx: Context): Promise<void>       // do the work, mutate ctx
}
```

### Context

```ts
interface Context {
  firstName: string
  lastName: string
  email: string
  directLine: boolean | undefined  // true=yes, false=no, undefined=ask
  // Populated by steps as they complete:
  googlePassword?: string
  amberjackEmployeeId?: number
  phenixAgentId?: number
  twilioWorkerSid?: string
  sipUsername?: string
  sipPassword?: string
  phoneNumber?: string
  zoiperConfigPath?: string
}
```

### Orchestration

```
for each step:
  print "Checking {step.name}..."
  if check(ctx) → print "already done, skipping" → next
  print "Running {step.name}..."
  run(ctx)
  print "done"
```

On failure: print what succeeded and what failed, then exit. Re-running the same command skips completed steps (idempotent via `check()`).

No cross-step transactions. Each step that touches a database uses a transaction internally, so a single step either fully completes or fully rolls back.

## Steps

### 1. Google Workspace

**check:** Admin SDK `users.get(email)`. If user exists, set `ctx.googlePassword = null`, skip.

**run:**
1. Auth via service account JSON (path from env: `GOOGLE_SERVICE_ACCOUNT_KEY`), impersonating `GOOGLE_ADMIN_EMAIL` (a Workspace admin account — required for domain-wide delegation). Scope: `https://www.googleapis.com/auth/admin.directory.user`.
2. Generate temp password: 4 random dictionary words, hyphenated, initial caps (e.g. `Tiger-Maple-Cloud-Seven`). Easy to dictate to a new hire; Google forces a change on first login anyway.
3. Admin SDK `users.insert`: primary email, first/last name, temp password, `changePasswordAtNextLogin: true`.
4. Set `ctx.googlePassword`.

**One-time setup (manual, not in script):**
- Create GCP project + service account
- Enable Admin SDK API
- Grant domain-wide delegation in Google Workspace admin (Security > API controls > Domain-wide delegation)
- Download service account JSON key, reference in `.env`

### 2. Amberjack

**check:** `SELECT id FROM employee WHERE email = $1`. If exists, set `ctx.amberjackEmployeeId`, skip.

**run:**
1. Connect to Amberjack DB (`AMBERJACK_DATABASE_URL` from env).
2. Single transaction:
   - `INSERT INTO employee` (first name, last name, email, active=true) → returns `id`
   - `INSERT INTO access` — 6 rows for assets `[2, 3, 4, 5, 6, 21]` (Weborder permissions), linked to new employee id
3. Set `ctx.amberjackEmployeeId`.

### 3. Phenix

**check:** `SELECT id FROM agent WHERE email = $1` on Phenix DB. If exists, set `ctx.phenixAgentId`, skip.

**run:**
1. Connect to Phenix DB (`PHENIX_DATABASE_URL` from env).
2. Interactive prompts (via gum, queried from DB):
   - **Channel:** `gum choose` from `SELECT * FROM channel` (single select)
   - **Role:** `gum choose` from `SELECT * FROM role` (single select)
   - **Products:** `gum choose --no-limit` from `SELECT * FROM product` (multi-select, with "all" option)
3. Single transaction:
   - `INSERT INTO agent` (name, email, channel, role) → returns `id`
   - `INSERT INTO agent_skill` — one row per selected product
   - `INSERT INTO team_member` — team 8 (default)
4. Set `ctx.phenixAgentId`.

### 4. Twilio

**check:** Search TaskRouter workers in workspace `WSa872a1cc13360fa91e74ceefa9adab3e` for a worker whose attributes contain the agent's email. If found, set `ctx.twilioWorkerSid`, skip.

**run:**
1. Auth via `TWILIO_ACCOUNT_SID` + `TWILIO_AUTH_TOKEN` from env. All calls via `fetch` (REST API).
2. Generate SIP password: random 16 chars, at least 1 uppercase, 1 lowercase, 1 digit.
3. Create SIP credential on credential list `CLef996d536b7d15b6caea3528d879336d`:
   - Username = email prefix (before `@`)
   - Password = generated password
   - Idempotency: list existing credentials and search by username; if exists, skip creation.
4. Encrypt SIP password with AES-256 (key from env: `AES_KEY`, base64-encoded). Write encrypted value to `agent.sip_secret` in Phenix DB.
5. Create TaskRouter worker:
   - Friendly name = full name
   - Attributes = JSON with email, channels, skills matching Phenix setup
6. Set `ctx.sipUsername`, `ctx.sipPassword`, `ctx.twilioWorkerSid`.

### 5. Direct Line (optional)

**check:** If `ctx.directLine === false`, skip entirely. Otherwise query Phenix DB for a `verified_caller_id` row for this agent. If found, set `ctx.phoneNumber`, skip.

**run:**
1. If `ctx.directLine === undefined` (no flag), prompt "Buy a direct line? (y/n)". If no, skip.
2. Prompt for city or area code (gum input).
3. Search Twilio available local numbers matching locality.
4. Present results via `gum choose` — pick a number.
5. Buy the number.
6. Configure with TwiML app `APb87ac09d7487f42163b8fad4897db52c`.
7. Insert `verified_caller_id` in Phenix DB linking number to agent.
8. Set `ctx.phoneNumber`.

### 6. Zoiper Config

**check:** If `ctx.zoiperConfigPath` already set or output file exists, skip.

**run:**
1. Generate a Zoiper 5 `Config.xml` with the SIP account pre-configured:
   - SIP domain/server
   - Username (`ctx.sipUsername`)
   - Password (`ctx.sipPassword`)
   - TLS transport
   - Codec preferences
2. Write to `./output/zoiper-{firstname}-{lastname}.xml`.
3. Set `ctx.zoiperConfigPath`.

**Manual steps after (not automated):**
1. Log into the new machine as the user
2. Activate Zoiper Pro
3. Copy the generated `Config.xml` to `%APPDATA%\Zoiper5\Config.xml`

## Summary Output

After all steps, print a formatted summary:

```
══════════════════════════════════════════
  New Employee: Zak Roberts
  Email: zak.roberts@ameriglide.com
══════════════════════════════════════════

  Google Workspace
    Temp Password: Tiger-Maple-Cloud-Seven

  Amberjack
    Employee ID: 142

  Phenix
    Agent ID: 87

  Twilio
    Worker SID: WK...
    SIP Username: zak.roberts
    SIP Password: aB3x...

  Direct Line
    Phone: +1 (706) 555-1234

  Zoiper
    Config: ./output/zoiper-zak-roberts.xml
    Manual: Activate Pro, then copy to %APPDATA%\Zoiper5\

══════════════════════════════════════════
  Next: Run bin/copy on the new machine
══════════════════════════════════════════
```

- Steps that were skipped (already existed) show "already existed" instead of values.
- Temp password only shows if generated this run (not on re-runs).

## Environment Variables (.env)

```env
# Google
GOOGLE_SERVICE_ACCOUNT_KEY=./service-account.json
GOOGLE_ADMIN_EMAIL=admin@ameriglide.com

# Amberjack
AMBERJACK_DATABASE_URL=postgresql://aj:...@host:port/aj

# Phenix
PHENIX_DATABASE_URL=postgresql://phenix:...@host:port/phenix

# Twilio
TWILIO_ACCOUNT_SID=AC...
TWILIO_AUTH_TOKEN=...
TWILIO_WORKSPACE_SID=WSa872a1cc13360fa91e74ceefa9adab3e
TWILIO_CREDENTIAL_LIST_SID=CLef996d536b7d15b6caea3528d879336d
TWILIO_TWIML_APP_SID=APb87ac09d7487f42163b8fad4897db52c

# Encryption
AES_KEY=... (base64)

# Tailscale (existing, used by bin/copy)
TAILSCALE_AUTH_KEY=...
```

All secrets in `.env`, which is gitignored. The repo is public.

## Dependencies

**npm packages (new):**
- `pg` (or `postgres` — PostgreSQL client)
- `googleapis` (Google Admin SDK)

**System tools (already installed):**
- `gum` — interactive prompts
- `bun` — runtime

**One-time setup:**
- Google Cloud service account with domain-wide delegation (see Step 1)
- Populate `.env` with all credentials

## What This Replaces

| Before | After |
|--------|-------|
| `~/bin/add-agent` (bash, Amberjack + Phenix inserts) | Steps 2-3 in `bin/onboard` |
| `~/Projects/phenix/bin/provision-agent.sh` (Gradle, Twilio) | Step 4 in `bin/onboard` |
| Manual Google Admin console | Step 1 in `bin/onboard` |
| Manual Zoiper SIP entry | Step 6 generates config file |
| No direct-line automation | Step 5 in `bin/onboard` |
