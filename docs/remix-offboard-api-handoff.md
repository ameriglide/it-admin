# Remix API work for ag-admin offboarding

`ag-admin` is gaining an `offboard` command (counterpart to `onboard`) that fully tears down a departing employee's accounts across Google Workspace, Amberjack, Phenix, and Twilio. The Phenix-side work (deactivate agent, park direct line, refresh HUD) is being expressed as Remix GraphQL endpoints so the business logic lives in one place and side-effects stay consistent regardless of caller.

This doc covers only the Remix-side work. The `ag-admin` design follows separately and depends on these endpoints existing.

## What ag-admin needs

### 1. Mutation: `setAgentInactive`

```graphql
setAgentInactive(email: String!): Agent!
```

**Server-side responsibilities** — must all happen atomically (or as compensating actions if a transaction isn't feasible):

1. `UPDATE agent SET active = false WHERE email = $email`
2. For every `verifiedcallerid` row where `direct = <that agent.id>`:
   - `UPDATE verifiedcallerid SET direct = NULL, parked = true`
3. Invalidate / refresh the HUD cache (equivalent to today's `GET /api/hud?produce=true&teams=true`). Whether this is a direct cache-bust call, a pub/sub fan-out, or another mechanism is at Remix's discretion — caller doesn't care, just needs the HUD to reflect the change without a follow-up call.

**Idempotent.** Calling on an already-inactive agent should be a no-op and return the agent without error.

**Returns** the updated agent (or at least `{ email, active }`) so the caller can verify.

### 2. Query: `salesManagers`

```graphql
salesManagers: [User!]!
```

Returns active users with `canManageSales = true`. Used by `bin/offboard` to populate the "transfer Drive ownership to" picker. Should include at minimum `{ firstName, lastName, email }`.

### 3. Query: `parkedNumbers` (deferred — not blocking v1)

```graphql
parkedNumbers: [VerifiedCallerId!]!
```

Returns `verifiedcallerid` rows where `parked = true AND direct IS NULL`. Used by a future change to `bin/onboard` so it reuses parked numbers before purchasing new ones from Twilio's national pool. Fields needed: `{ id, phonenumber, friendlyname, sid }`.

This one isn't on the critical path for offboard v1 — parked numbers will accumulate quietly until onboard learns to consume them.

## Schema migration

Add `parked` to `verifiedcallerid`:

```sql
ALTER TABLE verifiedcallerid ADD COLUMN parked boolean NOT NULL DEFAULT false;
```

Purely a tooling marker. The TwiML handler must continue to ignore it — current behavior of "row matched, `direct` and `queue` both null → route to main IVR" is exactly what we want for parked numbers, and that path stays unchanged.

## Auth

`ag-admin` will authenticate to Remix's GraphQL endpoint with a bearer token (user key) in the `Authorization` header. Whatever existing user-key auth mechanism Remix uses for admin-scoped operations is fine — `ag-admin` just needs one provisioned for the offboarding operator's use. Token will live in `REMIX_API_KEY` in `ag-admin`'s env file.

## Why this lives in Remix instead of ag-admin

`ag-admin` could do all of this with raw SQL against the Phenix DB plus a fetch to `/api/hud?produce=true&teams=true`. We're not, because:

- "Agent goes inactive" should mean the same thing whether triggered by the offboarding script, a Remix UI action, or anything future. Centralizing the side-effects (parking the direct line, refreshing the HUD) avoids one caller getting it half-right.
- Keeps `ag-admin` thin — it orchestrates external systems (Google, Twilio, Amberjack) and delegates Phenix-data concerns to the system that owns them.
- Adding the `parked` column and its consumers is a Phenix-data concern; landing it in the Remix repo keeps the migration alongside the code that uses it.

## Order of operations

Once the mutation + query above are merged and a user key is provisioned, `ag-admin` offboard can be built and shipped. The `parkedNumbers` query and the `bin/onboard` reuse logic can land independently afterwards — parked rows will be sitting there waiting.
