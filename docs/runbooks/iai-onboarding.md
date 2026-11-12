# Onboarding an IAI employee

_last verified: 2026-11-12_

`bin/onboard` serves both tenants from one codebase. Which steps run is decided
**per tenant, by the checkout's `DOMAIN`** (trimmed and lowercased; empty means
`ameriglide.com`), not by a flag:

- On `ameriglide.com`, Sonar and PBX are skipped regardless of env, and
  Amberjack and Phenix are **required** — a missing `AMBERJACK_DATABASE_URL` /
  `PHENIX_DATABASE_URL` fails the run loudly instead of silently skipping.
- On any other tenant (IAI), Sonar, PBX and the Google org unit are
  **required** — `SONAR_DATABASE_URL`, `PBX_HOST` and `ONBOARD_ORG_UNIT_PATH`
  must be set — and Amberjack and Phenix run only if their URLs are set.
  Those are AmeriGlide steps, so leave `AMBERJACK_DATABASE_URL` and
  `PHENIX_DATABASE_URL` unset in an IAI `.env`; if either is set, the preflight
  warns that it will run.
- Twilio, Direct Line and Zoiper still skip whenever `TWILIO_ACCOUNT_SID` is
  unset, on either tenant. Off `ameriglide.com`, a set `TWILIO_ACCOUNT_SID`
  makes them run, and the preflight warns about it the same way as for
  Amberjack/Phenix.

| Step | Runs when | Tenant |
| -- | -- | -- |
| Google, Google Groups | always / `ONBOARD_ROLES` | both |
| Amberjack | always on ameriglide.com (needs `AMBERJACK_DATABASE_URL`) | AmeriGlide |
| Phenix | always on ameriglide.com (needs `PHENIX_DATABASE_URL`) | AmeriGlide |
| Twilio, Direct Line, Zoiper | `TWILIO_ACCOUNT_SID` | either (if Twilio is configured) |
| **Sonar** | always off ameriglide.com (needs `SONAR_DATABASE_URL`) | **IAI** |
| **PBX** | always off ameriglide.com (needs `PBX_HOST`) | **IAI** |
| Org directory | `MEM0_API_KEY` + ameriglide.com | AmeriGlide |

So an IAI run needs its own checkout with its own `.env` — the TypeScript
entrypoints resolve `.env` from the repo root they live in, so a second clone
is all it takes. Connection strings, hostnames and the 1Password coordinates are
deployment topology and **are not in this repo**; they live in `.env` and in
`ameriglide/it-admin-docs`.

```bash
bin/onboard --first Jane --last Doe --extension 9001 --call-center "..."
```

Before the first step the run prints `Tenant: <domain>; running: <steps>`.
Check that line: it is the quickest way to spot a run against the wrong
checkout's `.env`, or an AmeriGlide step that should not be there.

`--call-center` and `--no-sales` only feed the Sonar step, and `--extension`
feeds Sonar and PBX, so they have **no effect on `ameriglide.com`** (or when
Sonar is `--skip`'ped, for `--call-center` / `--no-sales`; when both Sonar and
PBX are, for `--extension`). The preflight prints a warning naming the cause
(the tenant, or the skip) rather than failing. On `ameriglide.com` the end-of-run summary has no Sonar or PBX
sections either.

## Preflight: config mistakes fail before anything is written

Before **any** step runs — so before Google creates the account — the run
checks the following, for each step that is not `--skip`'ped (empty entries in
`--skip` are ignored):

- On `ameriglide.com`:
  - Amberjack: `AMBERJACK_DATABASE_URL`.
  - Phenix: `PHENIX_DATABASE_URL`.
- On any other tenant:
  - Sonar: `SONAR_DATABASE_URL`.
  - PBX: `PBX_HOST`, and `PBX_OP_ITEM` / `PBX_OP_VAULT` / `PBX_OP_ACCOUNT` set
    all together or not at all.
  - Google: `ONBOARD_ORG_UNIT_PATH`.
- On either tenant, when Sonar or PBX runs: a given `--extension` must be
  exactly four digits and, when `PBX_ENABLED_EXTENSIONS` is set, appear in
  that list. `PBX_ENABLED_EXTENSIONS` set to something that lists no
  extensions (`,`, spaces) is itself a problem rather than being read as
  unset, so a typo cannot quietly turn the check off. When PBX runs but Sonar
  is `--skip`'ped, `--extension` is required (there is no Sonar prompt to
  supply it).

Every problem is listed at once and nothing is changed — fix `.env` (or the
flag) and re-run.

The preflight does **not** check the Google service account or credentials,
Twilio, or the Google Groups config (`ONBOARD_ROLES`). Mistakes there still
surface at run time, possibly after Google has created the user.

It also prints non-blocking warnings: `--call-center` / `--no-sales` given
when Sonar does not run, `--extension` given when neither Sonar nor PBX runs,
and, off `ameriglide.com`, which AmeriGlide steps will run because their env
is set (Amberjack or Phenix via its URL; Twilio, Direct Line and Zoiper via
`TWILIO_ACCOUNT_SID`), listing only the ones not `--skip`'ped.

## The one thing to understand first

**In Sonar, the agent's primary key _is_ the phone extension.** The `agent`
table in the `cg2` database is keyed on `key varchar(4)`, and `Agent.getCallerId()` hands that key straight to
Asterisk. There is no separate agent id to allocate and no mapping table: pick
the number once and it is simultaneously the CRM record and the SIP endpoint.

That is why `--extension` feeds both steps, and why getting it wrong is not a
cosmetic mistake — the Sonar row and the PBX endpoint would disagree about who
the agent is.

Consequences:

- The extension must be free in Sonar **and** enabled on the PBX.
  `PBX_ENABLED_EXTENSIONS` lists the **enabled** extensions; when it is set,
  any extension not in it is refused **before** the agent row is inserted —
  in the preflight for `--extension`, or in the Sonar step for one typed at
  the prompt — so a refused run leaves no stray Sonar row behind. The PBX
  step checks the same list again when it builds the sheet.
- Re-running is safe. The Sonar step keys off `email`, so a second run finds
  the existing agent rather than creating a duplicate. If `--extension` is
  omitted or equals the existing agent's `key`, that key is adopted and the
  run carries on. If `--extension` names a **different** number, the run stops
  with an error naming both — fix the flag (or the Sonar row) rather than
  expecting the script to re-key an agent. `--call-center` and `--no-sales`
  are ignored, with a warning, for an agent that already exists.
- An existing agent's key is checked too. A key that is not four digits stops
  the run with an error (fix the Sonar row). A key that is not in
  `PBX_ENABLED_EXTENSIONS` only gets a warning from the Sonar step, but the
  PBX step then refuses it — get the extension enabled, as for a new hire.
- The preflight catches only the configuration mistakes listed
  [above](#preflight-config-mistakes-fail-before-anything-is-written). A step
  can still fail at run time (bad Google credentials, a database or Google API
  error, Twilio, the sheet file not being writable). A failed 1Password lookup
  does **not** fail the PBX step — see [Password](#password).
- **If a step fails after Google created the user, record the temp password
  first.** The failure output prints the Google temp password once, because a
  re-run reports the account as "already existed" and never shows it again.
  Pressing Ctrl-C after the Google step does the same: the password is printed
  before the run exits. The password is recorded before the create request is
  sent, so it is printed even if the run is interrupted (or the network drops)
  while Google is creating the account; it is dropped only when Google rejects
  the request (a 4xx), since then no account was created. Save it, then re-run:
  Google and Sonar find what they already created, and the run resumes at the
  step that failed.

## Google

The only tenant-specific code is the org unit: `ONBOARD_ORG_UNIT_PATH`, which
off `ameriglide.com` has no default. The IAI `.env` needs its own service
account
with domain-wide delegation on the IAI tenant, `GOOGLE_ADMIN_EMAIL` for that
tenant, `DOMAIN` / `BRAND` / `MARKETING_URL` set to IAI's, and
**`ONBOARD_ORG_UNIT_PATH` set to an org unit that exists in the IAI
Workspace**. Off `ameriglide.com` it is required and the preflight refuses to
start without it; there is deliberately no fallback to AmeriGlide's
`/Exempt from MFA`, which is MFA-exempt (and Google rejects `users.insert`
against an OU the tenant does not have).

Sonar authenticates through Google OAuth and the `agent` table has no password
column, so **the Google account is what actually grants Sonar access**. If
the Google account is missing (e.g. Google was `--skip`'ped), the Sonar agent
is unusable.

## Sonar

Creates the row in the `agent` table of the `cg2` database. Required: first
name, last name, email, and the extension — without `--extension` the step
prompts `Sonar extension (4 digits)` and, if `PBX_ENABLED_EXTENSIONS` is set
and does not include the answer, refuses it before inserting. Without
`--call-center` the step also prompts for a call center (the `callcenter`
table, same database).

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
`output/microsip-<ext>-<first>-<last>.txt` **relative to the directory you ran
`bin/onboard` from** (not the repo root), and prints it. The file is written
with mode `0600`, since it can carry the SIP password; delete it once the
softphone is set up.

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
work — in the preflight for `--extension` (before Google is touched) or in the
Sonar step for a prompted one, either way before the agent row is inserted, so
there is nothing to clean up in Sonar: get the extension enabled (ask the PBX admin),
add it to `PBX_ENABLED_EXTENSIONS`, and re-run. Keep that list current, or
leave it unset to skip the check. Tracking: IAI-35 (softphone rollout), SNR-35 (PBX TLS/SRTP).

### Password

`PBX_OP_ITEM` / `PBX_OP_VAULT` / `PBX_OP_ACCOUNT` point at the 1Password item
that holds one SIP password per extension, field label = extension. With all
three set the step fills the password in. With none set, or when the 1Password
lookup fails, the sheet carries a loud placeholder, the step's warning says
why the lookup failed (not signed in, item or field missing, and so on), and
the end-of-run summary shows `Password: MISSING`. A failed lookup does not
fail the step. Setting only one or two of the three is a config error caught by
the preflight, not a silent fallback.

The lookup reads the item with `op ... --format json`, so a password may
contain commas or quotes. If more than one field on the item carries the
extension as its label, the lookup reports that rather than guessing, and the
sheet gets the placeholder.

**Use the current PBX's password.** The retired PBX's secret will not work, and
copying it from an existing softphone account is the most common failure.

## Verifying

- Sonar: the agent appears, paused (the summary's "Taking calls" reflects
  Sonar's actual `paused` value).
- Phone: `asterisk -rx "pjsip show contacts"` on the PBX shows the extension
  as `Avail`. One contact per extension — register only the agent's own machine.
- Queue: after the agent clicks "Start taking calls", they appear in
  `asterisk -rx "queue show"`.
