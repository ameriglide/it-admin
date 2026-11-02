# Onboarding an IAI employee

_last verified: 2026-11-02_

`bin/onboard` serves both tenants from one codebase. Which steps run is decided
by **which credentials the checkout's `.env` has**, not by a flag:

| Step | Runs when | Tenant |
| -- | -- | -- |
| Google, Google Groups | always / `ONBOARD_ROLES` | both |
| Amberjack | `AMBERJACK_DATABASE_URL` | AmeriGlide |
| Phenix | `PHENIX_DATABASE_URL` | AmeriGlide |
| Twilio, Direct Line, Zoiper | `TWILIO_ACCOUNT_SID` | AmeriGlide |
| **Sonar** | `SONAR_DATABASE_URL` | **IAI** |
| **PBX** | `PBX_HOST` | **IAI** |
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

**In Sonar, the agent's primary key _is_ the phone extension.** `cg2.agent` is
keyed on `key varchar(4)`, and `Agent.getCallerId()` hands that key straight to
Asterisk. There is no separate agent id to allocate and no mapping table: pick
the number once and it is simultaneously the CRM record and the SIP endpoint.

That is why `--extension` feeds both steps, and why getting it wrong is not a
cosmetic mistake — the Sonar row and the PBX endpoint would disagree about who
the agent is.

Two consequences:

- The extension must be free in Sonar **and** enabled on the PBX. The Sonar
  step checks the first; the PBX step checks the second against
  `PBX_ENABLED_EXTENSIONS`.
- Re-running is safe. The Sonar step keys off `email`, so a second run finds
  the existing agent and adopts its `key` rather than creating a duplicate.

## Google

Nothing IAI-specific in the code. The IAI `.env` needs its own service account
with domain-wide delegation on the IAI tenant, `GOOGLE_ADMIN_EMAIL` for that
tenant, and `DOMAIN` / `BRAND` / `MARKETING_URL` set to IAI's.

Sonar authenticates through Google OAuth and `cg2.agent` has no password
column, so **the Google account is what actually grants Sonar access**. If
Google fails, nothing downstream is usable regardless of what the Sonar step
reports.

## Sonar

Creates the `cg2.agent` row. Required: first name, last name, email. The step
also asks for a call center (`cg2.callcenter`).

It inserts with **`paused = true` on purpose.** A brand-new agent should not be
handed live calls before their softphone registers. The agent clears it
themselves with Sonar's "Start taking calls", and that click is also what adds
them to the Asterisk queue — see the 2026-10-21 queue-membership note in mem0
(`domain=iai-phones`): an agent who looks available in Sonar but is missing
from `queue show` is fixed by Stop, then Start.

Skills (`cg2.skilledagent`) are **not** set by the script. Add them in Sonar
once the phone registers.

## Phone

The PBX step does not configure anything remotely. It produces the
field-by-field MicroSIP account sheet for that extension, under `output/`, and
prints it.

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

### The blocker you will hit with a new hire

Migrated extensions sit on a **disabled endpoint template**: they cannot
register and cannot place calls. Only a handful are enabled. A new hire's
extension is therefore almost certainly disabled, and **nothing in this repo
can enable it** — that is a server-side template change plus a strong secret,
and the secret has to be added to the 1Password item.

The step fails loudly in that case rather than emitting a sheet that cannot
work. Keep `PBX_ENABLED_EXTENSIONS` current, or leave it unset to skip the
check. Tracking: IAI-35 (softphone rollout), SNR-35 (PBX TLS/SRTP).

### Password

`PBX_OP_ITEM` / `PBX_OP_VAULT` / `PBX_OP_ACCOUNT` point at the 1Password item
that holds one SIP password per extension, field label = extension. With all
three set the step fills the password in; otherwise the sheet carries a loud
placeholder naming where to get it.

**Use the current PBX's password.** The retired PBX's secret will not work, and
copying it from an existing softphone account is the most common failure.

## Verifying

- Sonar: the agent appears, paused.
- Phone: `asterisk -rx "pjsip show contacts"` on the PBX shows the extension
  as `Avail`. One contact per extension — register only the agent's own machine.
- Queue: after the agent clicks "Start taking calls", they appear in
  `asterisk -rx "queue show"`.
