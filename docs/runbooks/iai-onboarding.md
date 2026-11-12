# Onboarding an IAI employee

_last verified: 2026-11-12_

`bin/onboard` serves both tenants from one codebase. Which steps run is decided
**per tenant, by the checkout's `DOMAIN`** (default `ameriglide.com`), not by a
flag:

- On `ameriglide.com`, Sonar and PBX are skipped, and Amberjack and Phenix are
  **required** — a missing `AMBERJACK_DATABASE_URL` / `PHENIX_DATABASE_URL`
  fails the run loudly instead of silently skipping.
- On any other tenant (IAI), Sonar and PBX are **required** — a missing
  `SONAR_DATABASE_URL` or `PBX_HOST` fails the run loudly — and Amberjack and
  Phenix are skipped when their URLs are unset.
- Twilio, Direct Line and Zoiper still skip whenever `TWILIO_ACCOUNT_SID` is
  unset, on either tenant.

| Step | Runs when | Tenant |
| -- | -- | -- |
| Google, Google Groups | always / `ONBOARD_ROLES` | both |
| Amberjack | always on ameriglide.com (needs `AMBERJACK_DATABASE_URL`) | AmeriGlide |
| Phenix | always on ameriglide.com (needs `PHENIX_DATABASE_URL`) | AmeriGlide |
| Twilio, Direct Line, Zoiper | `TWILIO_ACCOUNT_SID` | AmeriGlide |
| **Sonar** | always off ameriglide.com (needs `SONAR_DATABASE_URL`) | **IAI** |
| **PBX** | always off ameriglide.com (needs `PBX_HOST`) | **IAI** |
| Org directory | `MEM0_API_KEY` + ameriglide.com | AmeriGlide |

So an IAI run needs its own checkout with its own `.env` — the TypeScript
entrypoints resolve `.env` from the repo root they live in, so a second clone
is all it takes. Connection strings, hostnames and the 1Password coordinates are
deployment topology and **are not in this repo**; they live in `.env` and in
`ameriglide/it-admin-docs`.

```bash
bin/onboard --first Jane --last Doe --extension 7415 --call-center "..."
```

## The one thing to understand first

**In Sonar, the agent's primary key _is_ the phone extension.** The `agent`
table in the `cg2` database is keyed on `key varchar(4)`, and `Agent.getCallerId()` hands that key straight to
Asterisk. There is no separate agent id to allocate and no mapping table: pick
the number once and it is simultaneously the CRM record and the SIP endpoint.

That is why `--extension` feeds both steps, and why getting it wrong is not a
cosmetic mistake — the Sonar row and the PBX endpoint would disagree about who
the agent is.

Two consequences:

- The extension must be free in Sonar **and** enabled on the PBX. The Sonar
  step checks both before it writes anything: an extension that
  `PBX_ENABLED_EXTENSIONS` lists as not enabled is refused **before** the
  agent row is inserted, so a refused run leaves no stray Sonar row behind.
  The PBX step checks the same list again when it builds the sheet.
- Re-running is safe. The Sonar step keys off `email`, so a second run finds
  the existing agent rather than creating a duplicate. If `--extension` is
  omitted or equals the existing agent's `key`, that key is adopted and the
  run carries on. If `--extension` names a **different** number, the run stops
  with an error naming both — fix the flag (or the Sonar row) rather than
  expecting the script to re-key an agent. `--call-center` and `--no-sales`
  are ignored, with a warning, for an agent that already exists.
- If the PBX step fails after Sonar succeeded (sheet, password lookup), just
  re-run: Sonar finds the agent it already created and is skipped, and the run
  resumes at the PBX step.

## Google

Nothing IAI-specific in the code. The IAI `.env` needs its own service account
with domain-wide delegation on the IAI tenant, `GOOGLE_ADMIN_EMAIL` for that
tenant, `DOMAIN` / `BRAND` / `MARKETING_URL` set to IAI's, and
**`ONBOARD_ORG_UNIT_PATH` set to an org unit that exists in the IAI
Workspace**. Left unset it defaults to AmeriGlide's `/Exempt from MFA`, and
`users.insert` fails on any tenant that does not have that OU.

Sonar authenticates through Google OAuth and the `agent` table has no password
column, so **the Google account is what actually grants Sonar access**. If
Google fails, nothing downstream is usable regardless of what the Sonar step
reports.

## Sonar

Creates the row in the `agent` table of the `cg2` database. Required: first
name, last name, email. The step also asks for a call center (the
`callcenter` table, same database).

`sales` defaults to **true** — IAI agents are sales agents (decided
2026-11-02). Pass `--no-sales` for a non-selling account. The call center
rarely matters; pick the obvious one.

It inserts with **`paused = true` on purpose.** A brand-new agent should not be
handed live calls before their softphone registers. The agent clears it
themselves with Sonar's "Start taking calls", and that click is also what adds
them to the Asterisk queue — see the 2026-10-21 queue-membership note in mem0
(`domain=iai-phones`): an agent who looks available in Sonar but is missing
from `queue show` is fixed by Stop, then Start.

Skills (the `skilledagent` table) are **not** set by the script. Add them in Sonar
once the phone registers.

## Phone

The PBX step does not configure anything remotely. It produces the
field-by-field MicroSIP account sheet for that extension, at
`output/microsip-<ext>-<first>-<last>.txt`, and prints it.

Deliberate choices:

- **MicroSIP, not Zoiper.** Agents register with SIP-TLS and *mandatory* SRTP.
  Free Zoiper's SRTP support is unreliable; MicroSIP does TLS+SRTP for free.
  Move Zoiper users across rather than buying Pro licences.
- **No `MicroSIP.ini` is written.** MicroSIP rewrites that file on start *and*
  on exit, so a config dropped underneath a running client is silently lost.
  Add the account through its UI.
- **Public internet, not the tailnet.** Do not point a softphone at the PBX's
  tailnet address; removing Tailscale from the phone path is the point of the
  current PBX (decision, 2026-10-26).

### Until cutover, agents get two accounts

The PBX step covers the **current** PBX only. Until cutover, an agent also
needs the retired PBX's account alongside it, kept as the **default** (decided
2026-11-02: cutover timing is not yet fixed). That old account is set up by
hand — it is chan_sip over UDP and reached through the Tailscale subnet route,
so it does not fit this step's TLS/SRTP shape and is deliberately not
automated.

This applies even on a brand-new machine with nothing on it.

### The blocker you will hit with a new hire

Migrated extensions sit on a **disabled endpoint template**: they cannot
register and cannot place calls. Only a handful are enabled. A new hire's
extension is therefore almost certainly disabled, and **nothing in this repo
can enable it** — that is a server-side template change plus a strong secret,
and the secret has to be added to the 1Password item.

An agent who already had an account on the retired PBX should *already* have
been migrated, extension and password included. If they are missing from the
1Password item, that item is wrong rather than the agent being genuinely new —
get it corrected rather than allocating them a second extension.

The run refuses a disabled extension rather than emitting a sheet that cannot
work — and it does so in the Sonar step, before the agent row is inserted, so
there is nothing to clean up: get the extension enabled (ask the PBX admin),
add it to `PBX_ENABLED_EXTENSIONS`, and re-run. Keep that list current, or
leave it unset to skip the check. Tracking: IAI-35 (softphone rollout), SNR-35 (PBX TLS/SRTP).

### Password

`PBX_OP_ITEM` / `PBX_OP_VAULT` / `PBX_OP_ACCOUNT` point at the 1Password item
that holds one SIP password per extension, field label = extension. With all
three set the step fills the password in. With none set, or when the 1Password
lookup fails, the sheet carries a loud placeholder, the step's warning says
why the lookup failed (not signed in, item or field missing, and so on), and
the end-of-run summary flags the placeholder password. Setting only one or two
of the three is a config error, not a silent fallback.

**Use the current PBX's password.** The retired PBX's secret will not work, and
copying it from an existing softphone account is the most common failure.

## Verifying

- Sonar: the agent appears, paused.
- Phone: `asterisk -rx "pjsip show contacts"` on the PBX shows the extension
  as `Avail`. One contact per extension — register only the agent's own machine.
- Queue: after the agent clicks "Start taking calls", they appear in
  `asterisk -rx "queue show"`.
