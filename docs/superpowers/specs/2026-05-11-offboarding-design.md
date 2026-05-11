# Offboarding design

## Goal

Add `bin/offboard` to `ag-admin` — the symmetric counterpart to `bin/onboard` — that tears down a departing employee's accounts across Google Workspace, Slack, Amberjack, Phenix (via Remix GraphQL), and Twilio, in a single idempotent run.

The immediate driver is two real users: **Jim Soffe** (full fresh offboarding) and **Kevin Dougherty** (already mostly gone; just leftover active row in Phenix making him appear in the dial-button HUD). The design must handle both as the same code path — re-running the offboard script on Kevin should detect everything else is clean and only flip Phenix.

## Non-goals

- `bin/onboard` changes to consume parked direct-line numbers. Deferred; numbers accumulate as `parked = true` rows and the reuse logic lands later.
- An explicit `audit` subcommand. The `--dry-run` flag already gives the audit behavior; promote later if a recurring need emerges.
- Anything Windows-side (GCPW profile removal on individual workstations). Out of scope; handled separately if a machine is reissued.

## Dependencies

Net-new Remix-side work — see `docs/remix-offboard-api-handoff.md`. Specifically:

- `setAgentInactive(email)` mutation — flips `agent.active`, parks the agent's verifiedcallerid rows (`direct = NULL, parked = true`), refreshes HUD.
- `salesManagers` query — used to populate the Drive-transfer-target picker.
- Schema migration adding `parked` boolean to `verifiedcallerid`.
- A user-key auth token provisioned for the offboarding operator.

`ag-admin` offboard cannot ship until those are in place. The `parkedNumbers` query is also handed off but is non-blocking.

## Structure

```
src/offboard/
  run.ts                # idempotent step loop (mirrors src/onboard/run.ts)
  types.ts              # OffboardContext + Step
  lib/
    gyb.ts              # NEW — wraps gyb CLI via Bun.spawn
    google.ts           # NEW — Directory + Groups + Groups Settings clients
    remix.ts            # NEW — GraphQL client over Remix
    slack.ts            # NEW — Slack admin API client
    manager.ts          # NEW — picker over salesManagers GraphQL query
  steps/
    phenix.ts           # 1. setAgentInactive mutation
    slack.ts            # 2. deactivate Slack user
    twilio.ts           # 3. delete worker + delete SIP credential
    amberjack.ts        # 4. locked = true
    google.ts           # 5. GYB backup → delete w/ transfer → group create → settings → load archive
bin/
  offboard              # CLI
docs/
  remix-offboard-api-handoff.md   # already written
  superpowers/specs/2026-05-11-offboarding-design.md  # this doc
```

Reuses from onboarding: `lib/db.ts` (Amberjack only — Phenix DB access moves to Remix GraphQL), `lib/prompt.ts`, `lib/twilio.ts` (extended with delete methods).

## Step order and rationale

1. **Phenix** — first so calls stop being routed to the departing agent immediately. Worker is still alive in Twilio at this point but inbound routing through Phenix is cut.
2. **Slack** — deactivate the Slack user so DMs stop arriving and they lose access to channels.
3. **Twilio** — destructive teardown of the worker and SIP credential. Done before Google so any Twilio-API errors surface before the irreversible Google delete.
4. **Amberjack** — flip `locked = true`. Cheap, can't fail in interesting ways.
5. **Google** — last, because GYB backup is slow and the user delete is the most irreversible action in the flow. Everything upstream must succeed first.

Each step is idempotent: `check()` returns true if the offboard outcome already exists in that system. For Kevin, every step's `check()` except Phenix returns true and is skipped.

## Step details

### `steps/phenix.ts`

One GraphQL call:

```graphql
mutation { setAgentInactive(email: $email) { email active } }
```

- `check(ctx)`: GraphQL query for the agent — returns true if `active = false`.
- `run(ctx)`: send the mutation. No additional bookkeeping; Remix handles the HUD refresh and the verifiedcallerid parking.

### `steps/slack.ts`

Single Slack admin API call. Requires an existing Slack app (operationally referred to as `slack-agent`) up-permissioned with `admin.users:write` (Enterprise Grid) or, on a standard workspace, an admin user token used as `SLACK_ADMIN_TOKEN`. The exact API is plan-dependent:

- **Standard / Business+ workspaces**: `users.profile.set` cannot deactivate; deactivation goes through SCIM (`/scim/v1/Users/<id>` PATCH with `active: false`) using an admin token. Requires the SCIM API which is plan-gated.
- **Enterprise Grid**: `admin.users.session.reset` to sign them out everywhere, then `admin.users.remove` or `admin.users.session.invalidate` depending on whether removal-from-org vs sign-out-only is desired.

Step responsibilities:

- `lib/slack.ts` exposes `findUserByEmail(email)` and `deactivateUser(userId)`.
- `check(ctx)`: looks up the user; returns true if not found or already deactivated.
- `run(ctx)`: deactivates.

**Dependency** — to be confirmed during implementation: which Slack plan we're on, what the exact deactivation API surface is, and whether `slack-agent`'s current scopes cover it. If they don't, this is a small Slack-app rollout (add scope, reinstall app, capture new token) tracked alongside the Remix work in the handoff cycle.

### `steps/twilio.ts`

Adds `deleteWorker(sid)` and `deleteCredential(sid)` to `lib/twilio.ts` (`DELETE /Workers/<sid>` and `DELETE /SIP/CredentialLists/<list>/Credentials/<sid>.json`).

- SIP username is the email's local part (e.g. `jim.soffe` for `jim.soffe@ameriglide.com`) — same convention as onboarding.
- `check(ctx)`: returns true if `findWorkerByEmail(email)` and `findCredentialByUsername(<local-part>)` both return null.
- `run(ctx)`: deletes whichever currently exists.

### `steps/amberjack.ts`

- `check(ctx)`: `SELECT locked FROM employee WHERE email = $email` returns `locked = true`.
- `run(ctx)`: `UPDATE employee SET locked = true WHERE email = $email`. `access` rows are left intact for historical reporting.

### `steps/google.ts`

The complicated one. Sequence:

1. **Resolve manager** via `lib/manager.ts`:
   - If `ctx.managerEmail` was passed via `--manager`, use it.
   - Otherwise, fetch `salesManagers` from Remix GraphQL, present as a `choose()` picker.
   - Store result on `ctx`.

2. **GYB backup** via `lib/gyb.ts`:
   - `gyb --email <user> --action backup --local-folder <AG_ARCHIVE_ROOT>/<email>/`
   - Block until exit 0. Non-zero exit aborts the step (and the run, surfacing the error).
   - `AG_ARCHIVE_ROOT` defaults to `~/ag-admin-archives`.

3. **Delete Google user with Drive transfer**:
   - Directory API `users.delete` with the `transferTo` parameter set to `ctx.managerEmail`.
   - Google handles the Drive transfer asynchronously in the background.

4. **Wait for delete to propagate** — poll `users.get` until 404, up to ~30s. Required because the next step (create Group at the same address) fails if the address is still occupied.

5. **Create archive Group**:
   - `groups.insert` with `email = <former user email>`, `name = "<First> <Last> (archived)"`.

6. **Configure Group settings** (Groups Settings API):
   - `whoCanPostMessage = ANYONE_CAN_POST` (external mail still arrives).
   - `whoCanJoin = CAN_REQUEST_TO_JOIN` (anyone else has to ask).
   - `whoCanViewMembership = ALL_MEMBERS_CAN_VIEW`.
   - `whoCanViewGroup = ALL_MEMBERS_CAN_VIEW`.
   - `whoCanModerateMembers = OWNERS_AND_MANAGERS`.
   - `archiveOnly = false`.

7. **Add manager as owner**: `members.insert` with `email = managerEmail, role = OWNER`.

8. **Load mail archive into group**: `gyb --email <group address> --action restore-group --local-folder <AG_ARCHIVE_ROOT>/<email>/`.

`check(ctx)`: the address `<email>` resolves to a Group (not a User). That state implies the migration completed.

**`lib/gyb.ts`**: thin wrapper around `Bun.spawn(['gyb', ...])`. Verifies `gyb --version` works at start of the offboard run and bails with install instructions if not. Streams gyb's stdout/stderr through so the operator can see progress.

**Extended Google scopes**: `lib/google.ts` (in `src/offboard/`) needs broader scopes than onboarding's directory client:
- `admin.directory.user` (already present)
- `admin.directory.group`
- `admin.directory.group.member`
- `apps.groups.settings`

These must be granted to the service account in the Workspace admin console as part of rollout.

## CLI

```
bin/offboard --email <addr> [--manager <addr>] [--dry-run] [--skip <step,step>]
```

- Identity: either `--email <addr>`, or `--first <first> --last <last>` which derives the email as `<first>.<last>@<DOMAIN>` (same convention as `bin/onboard`). One of the two forms must be supplied.
- `--manager <addr>` optional override; otherwise interactive picker.
- `--dry-run` runs every `check()` and prints "would do X" / "already done" without executing any `run()`.
- `--skip <step,...>` mirrors `bin/onboard`'s skip flag.

## Context

```typescript
export interface OffboardContext {
  email: string;
  firstName?: string;       // optional; some steps only need email
  lastName?: string;
  managerEmail?: string;    // resolved during google step if not passed via --manager
  dryRun: boolean;

  // Populated by steps:
  amberjackEmployeeId?: number;
  phenixAgentId?: number;
  twilioWorkerSid?: string | null;       // null = wasn't there
  credentialSid?: string | null;
  gybBackupPath?: string;
  groupEmail?: string;
}
```

## Environment variables

New:
- `REMIX_GRAPHQL_URL` — e.g. `https://phenix.ameriglide.com/graphql` (TBD with Remix team).
- `REMIX_API_KEY` — user key bearer token.
- `SLACK_ADMIN_TOKEN` — admin/SCIM-scoped Slack token used by the Slack step.
- `AG_ARCHIVE_ROOT` — local path for GYB backups; defaults to `~/ag-admin-archives`.

Reused from onboarding: `AMBERJACK_DATABASE_URL`, `TWILIO_*`, `GOOGLE_SERVICE_ACCOUNT_KEY`, `GOOGLE_ADMIN_EMAIL`, `DOMAIN`.

## Error handling and resumption

Same model as `bin/onboard`: any step throwing aborts the run. The operator re-runs the same command — each step's `check()` skips already-completed work, picking up at the failure point. Particular care:

- **GYB backup failure** — re-runs from scratch; gyb handles incremental backup natively, so re-invocation is cheap if it partially succeeded.
- **Post-delete, pre-group creation failure** — manual recovery: the user is gone but the group doesn't exist yet. Re-running the step is safe because `check()` looks for the group address, finds nothing, and proceeds from step 5. The user-already-deleted branch is detected by `users.get` returning 404 in the inner check.
- **Group created, archive load failed** — re-run; gyb restore can be re-invoked safely against the existing group.

## Out of scope (follow-ups)

- `bin/onboard` direct-line step learning to consume `parkedNumbers` from Remix before searching Twilio's national pool.
- A standalone `bin/offboard-audit` if `--dry-run` proves insufficient.
- Slack channel cleanup (removing the user from individual channels — deactivation already handles access, channel membership cleanup is cosmetic).
- Windows GCPW profile removal on individual machines.

## Validation plan

1. Once Remix endpoints land, dry-run against Kevin Dougherty. Expected: every step reports "already done" except Phenix, which reports "would call `setAgentInactive`."
2. Real-run against Kevin. Verify dial button drops him after HUD refresh.
3. Dry-run against Jim Soffe. Expected: every step reports "would do X" with concrete details (manager picker visible, GYB backup path shown, etc.).
4. Real-run against Jim. Verify mail addressed to his address still arrives (now into the archive group), manager has Drive ownership, Twilio worker and SIP credential gone, Amberjack employee locked.
