# Onboarding: Google Group membership

**Date:** 2026-06-18
**Status:** Approved (design)

## Problem

Google Group / distribution-list membership (e.g. `sales-staff@ameriglide.com`)
used to be managed automatically by JumpCloud. That automation is gone. After
staff churn, `sales-staff@` (15 members) no longer reflects the actual sales
team, and there is no codified, repeatable way to put a new hire into the right
groups.

Two needs:

1. **Going forward** — onboarding a new hire should reliably add them to the
   correct set of groups, driven by a version-able definition rather than the
   onboarder's memory.
2. **Right now** — a way to find and repair existing drift (people missing from
   the groups their role implies), so `sales-staff@` etc. can be reconciled.

## Goals

- Add a role-bundle-driven Google Groups step to `bin/onboard`.
- Provide a standalone `bin/groups` command to audit and repair existing
  membership.
- Keep the org's role/group taxonomy out of this **public** repo.

## Non-goals

- A full directory sync or authoritative HR-system integration.
- Removing members on role change (departures go through offboarding, which
  deletes the user and all memberships). A `remove` subcommand is deferred —
  the pain that prompted this is *missing* members, not extras.
- Mocking the Google Directory API in tests (consistent with the rest of the
  suite; verified manually).

## Configuration — `ONBOARD_ROLES`

A JSON object in `.env` (gitignored), role name → array of group tokens:

```
ONBOARD_ROLES='{"Sales Rep":["staff@","sales-staff@"],"Sales Manager":["staff@","sales-staff@","sales-management@"],"Customer Service":["staff@","customerservice@"],"Installer":["staff@","installations@"],"Developer":["staff@","developers@","it@"]}'
```

Token resolution (`resolveGroupAddress(token, domain)`):

- Token containing a real domain (`x@foo.com`) → used as-is.
- Bare token (`sales-staff`) or trailing-`@` token (`sales-staff@`) → expanded
  to `<localpart>@<domain>`, where `domain = process.env.DOMAIN ?? "ameriglide.com"`.
  This keeps the `inetalliance.net` tenant working without separate config.

`.env.example` ships a **generic** placeholder (e.g. `"Role Name":["staff@","some-group@"]`),
documenting the shape without publishing the real taxonomy to the public repo.

Error handling:

- `ONBOARD_ROLES` **unset** → the onboarding groups step auto-skips with a note
  (same pattern `run.ts` uses for missing `TWILIO_ACCOUNT_SID`).
- `ONBOARD_ROLES` **set but invalid JSON / wrong shape** → loud error, fail
  fast. Do not silently skip.

## Component: `src/lib/google-groups.ts` (new)

The group machinery currently lives only in `src/offboard/lib/google.ts`;
`src/onboard/lib/google.ts` has only the `admin.directory.user` scope. Extract a
focused shared module rather than duplicate. Offboard's `google.ts` is left
as-is (it carries extra datatransfer/groupssettings concerns; not worth churning
for this change).

Exports:

- `getGroupsDirectory()` — `directory_v1` admin client, scoped
  `admin.directory.group.member` (read+write group membership). Domain-wide
  delegation for this scope is already granted (offboard uses it). Auth follows
  the existing pattern: `GOOGLE_SERVICE_ACCOUNT_KEY` keyfile + `GOOGLE_ADMIN_EMAIL`
  subject.
- `parseRoles(raw: string | undefined): Record<string, string[]>` — JSON parse +
  validation (object of string→string[]). Throws a clear error on malformed
  input. Returns `{}` for unset/empty.
- `resolveGroupAddress(token: string, domain: string): string` — short→full
  expansion as above.
- `addGroupMember(groupEmail, userEmail): Promise<"added" | "existed">` —
  `members.insert` with role `MEMBER`; idempotent on 409 / duplicate (reuses
  offboard's proven detection). On 404 (group not found) throws a message that
  names the group and points at `ONBOARD_ROLES`. On 403 hints at missing
  domain-wide delegation scope.
- `listGroupMemberEmails(groupEmail): Promise<string[]>` — paginated
  `members.list`, returns lowercased member emails. Returns `[]` on 404.

## Component: `src/onboard/steps/google-groups.ts` (new)

A `Step` named `"Google Groups"`, registered in `run.ts` immediately after the
Google Workspace step (the user must exist before being added to groups).

- `check(ctx)` → always `false` — membership is multi-valued with no clean
  "already done" signal; the step is interactive and its writes are idempotent.
- `run(ctx)`:
  1. `parseRoles(process.env.ONBOARD_ROLES)`. Role names + a `"None (skip groups)"`
     sentinel.
  2. Role selection: `ctx.role` (from the `--role` CLI flag) if provided and
     valid, else `choose([...roleNames, "None (skip groups)"])`.
  3. If "None" → `ctx.groupsJoined = []`, return.
  4. Resolve the role's tokens to full addresses. Present them via
     `chooseMulti(addresses, { selected: addresses })` — all pre-selected; the
     onboarder toggles any off.
  5. For each selected group: `addGroupMember(group, ctx.email)`, collecting
     `{ group, result }`.
  6. `ctx.groupsJoined = selected`.

`run.ts` gains an auto-skip: if `!process.env.ONBOARD_ROLES`, push `"googlegroups"`
onto `skip` with a console note (step key = `"Google Groups"` lowercased,
whitespace-stripped = `"googlegroups"`).

## Supporting edits

- `src/onboard/types.ts` — add `role?: string` (CLI preselect) and
  `groupsJoined?: string[]` to `Context`.
- `src/onboard/lib/prompt.ts` — extend `chooseMulti` to accept an optional
  `{ selected?: string[] }`, passed to `gum choose --no-limit` via its
  `--selected="a,b"` flag.
- `src/onboard/lib/summary.ts` — add a **Google Groups** section listing joined
  groups (or "skipped").
- `bin/onboard` — parse a `--role` string option onto `ctx.role`.

## Component: `bin/groups` (new)

A standalone `bun` CLI (loads repo-root `.env` like the other `bin/` entries).
Reconciles *existing* membership. Subcommands:

- `bin/groups roles` — print configured roles and their resolved group
  addresses.
- `bin/groups show <email>` — list which of the configured role-groups the user
  is currently a member of.
- `bin/groups audit "<Role>"` — for the role's groups, print each group's member
  count and a **drift report**: members present in some-but-not-all of the
  role's groups (set difference across the bundle). This surfaces the stale
  `sales-staff@` people — e.g. someone in `team-x@` but missing from
  `sales-staff@`.

  Broad "all-staff" groups (default: `staff@`, plus any address matching a
  configurable `ONBOARD_BROAD_GROUPS` list) are **excluded from the drift
  comparison** — pairing the 26-member `staff@` with `sales-staff@` would
  otherwise flag all 26 as "missing from sales-staff@," which is noise. Broad
  groups are still shown with their counts, just not diffed. If a role's bundle
  has fewer than two non-broad groups, drift reporting is skipped (nothing
  meaningful to compare) and only counts are printed.
- `bin/groups add <email> [--role "<Role>"] [--group <addr>]` — add the user to a
  role's full bundle (or to a single `--group`), idempotent, printing
  added/existed per group. This is the command used to reconcile `sales-staff@`
  now.

Shares `parseRoles` / `resolveGroupAddress` / `addGroupMember` /
`listGroupMemberEmails` with the onboarding step via `src/lib/google-groups.ts`.

## Testing

`test/google-groups.test.ts` (bun test, matching the existing suite):

- `parseRoles`: valid object; unset/empty → `{}`; invalid JSON → throws;
  wrong shape (value not a string array) → throws.
- `resolveGroupAddress`: bare token → `localpart@domain`; trailing-`@` token →
  same; full address → passthrough; alternate `DOMAIN` (e.g.
  `inetalliance.net`) honored.

Google Directory API calls are not mocked; verified manually with
`bin/groups add` against a real test user and by inspecting the resulting
membership.

## Docs

- `.env.example` — document `ONBOARD_ROLES` with a generic placeholder.
- `README.md` — document the new onboarding step and `bin/groups`.

## Files

New: `src/lib/google-groups.ts`, `src/onboard/steps/google-groups.ts`,
`bin/groups`, `test/google-groups.test.ts`.

Edit: `src/onboard/run.ts`, `src/onboard/types.ts`, `src/onboard/lib/prompt.ts`,
`src/onboard/lib/summary.ts`, `bin/onboard`, `.env.example`, `README.md`.
