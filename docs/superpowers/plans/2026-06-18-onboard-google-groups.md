# Onboarding Google Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a role-bundle-driven Google Groups step to `bin/onboard`, plus a standalone `bin/groups` command to audit and repair existing distribution-list membership.

**Architecture:** A new shared library `src/lib/google-groups.ts` holds pure config helpers (`parseRoles`, `resolveGroupAddress`, `getDomain`) and Google Directory API helpers (`getGroupsDirectory`, `addGroupMember`, `listGroupMemberEmails`). The onboarding step and the `bin/groups` CLI both consume it. Role→group bundles are defined in `ONBOARD_ROLES` (a JSON object in the gitignored `.env`).

**Tech Stack:** Bun + TypeScript, `googleapis` (Admin SDK Directory v1), `gum` for prompts, `bun:test` for unit tests.

## Global Constraints

- Runtime is **Bun**; entry scripts start with `#!/usr/bin/env bun` and `import "../src/lib/load-env";` as the first import.
- Repo is **public**: never commit real group addresses or the role taxonomy. Real values live in `.env`; `.env.example` ships generic placeholders only.
- No `tsconfig.json` exists — there is no `tsc` step. Verify non-test TypeScript files by importing them with Bun.
- Tests run with `bun test`; test files live in `test/*.test.ts` and import from `bun:test`.
- `DOMAIN` defaults to `ameriglide.com` when unset.
- Match existing style: 2-space indent, double-quoted strings, no semicolon omission (semicolons present).

---

### Task 1: Shared library `src/lib/google-groups.ts`

**Files:**
- Create: `src/lib/google-groups.ts`
- Test: `test/google-groups.test.ts`

**Interfaces:**
- Consumes: nothing (leaf module). Auth env vars `GOOGLE_SERVICE_ACCOUNT_KEY`, `GOOGLE_ADMIN_EMAIL` (same as `src/onboard/lib/google.ts`).
- Produces (relied on by Tasks 2 and 3):
  - `getDomain(): string`
  - `resolveGroupAddress(token: string, domain: string): string`
  - `parseRoles(raw: string | undefined): Record<string, string[]>`
  - `getGroupsDirectory()` — googleapis directory_v1 admin client
  - `addGroupMember(groupEmail: string, userEmail: string): Promise<"added" | "existed">`
  - `listGroupMemberEmails(groupEmail: string): Promise<string[]>`

- [ ] **Step 1: Write the failing test**

Create `test/google-groups.test.ts`:

```ts
import { describe, expect, test } from "bun:test";
import { parseRoles, resolveGroupAddress } from "../src/lib/google-groups";

describe("resolveGroupAddress", () => {
  test("bare token expands to localpart@domain", () => {
    expect(resolveGroupAddress("sales-staff", "ameriglide.com")).toBe(
      "sales-staff@ameriglide.com",
    );
  });
  test("trailing-@ token expands to localpart@domain", () => {
    expect(resolveGroupAddress("sales-staff@", "ameriglide.com")).toBe(
      "sales-staff@ameriglide.com",
    );
  });
  test("full address passes through unchanged", () => {
    expect(
      resolveGroupAddress("marketing@ameriglide-lexington-ky.com", "ameriglide.com"),
    ).toBe("marketing@ameriglide-lexington-ky.com");
  });
  test("honors an alternate domain", () => {
    expect(resolveGroupAddress("staff@", "inetalliance.net")).toBe(
      "staff@inetalliance.net",
    );
  });
  test("trims surrounding whitespace", () => {
    expect(resolveGroupAddress("  staff@  ", "ameriglide.com")).toBe(
      "staff@ameriglide.com",
    );
  });
});

describe("parseRoles", () => {
  test("parses a valid role map", () => {
    const r = parseRoles('{"Sales Rep":["staff@","sales-staff@"]}');
    expect(r).toEqual({ "Sales Rep": ["staff@", "sales-staff@"] });
  });
  test("undefined returns empty object", () => {
    expect(parseRoles(undefined)).toEqual({});
  });
  test("whitespace-only returns empty object", () => {
    expect(parseRoles("   ")).toEqual({});
  });
  test("invalid JSON throws", () => {
    expect(() => parseRoles("{not json")).toThrow(/not valid JSON/);
  });
  test("non-object (array) throws", () => {
    expect(() => parseRoles('["a","b"]')).toThrow();
  });
  test("non-string-array value throws", () => {
    expect(() => parseRoles('{"Role":[1,2]}')).toThrow();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test test/google-groups.test.ts`
Expected: FAIL — `Cannot find module '../src/lib/google-groups'` (or resolution error).

- [ ] **Step 3: Write the implementation**

Create `src/lib/google-groups.ts`:

```ts
import { google } from "googleapis";

export function getDomain(): string {
  return process.env.DOMAIN ?? "ameriglide.com";
}

// Short tokens ("sales-staff" or "sales-staff@") expand to <localpart>@<domain>,
// so the same ONBOARD_ROLES config works across tenants. A token that already
// carries a domain ("x@foo.com") is used as-is.
export function resolveGroupAddress(token: string, domain: string): string {
  const t = token.trim();
  const at = t.indexOf("@");
  if (at === -1) return `${t}@${domain}`;
  const local = t.slice(0, at);
  const rest = t.slice(at + 1);
  return rest.length > 0 ? t : `${local}@${domain}`;
}

// Parses the ONBOARD_ROLES env var: a JSON object mapping role name -> array of
// group tokens. Unset/empty -> {}. Malformed input throws loudly (never a
// silent skip on bad config).
export function parseRoles(raw: string | undefined): Record<string, string[]> {
  if (!raw || raw.trim() === "") return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (e: any) {
    throw new Error(`ONBOARD_ROLES is not valid JSON: ${e.message}`);
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("ONBOARD_ROLES must be a JSON object of role -> string[]");
  }
  const out: Record<string, string[]> = {};
  for (const [role, value] of Object.entries(parsed as Record<string, unknown>)) {
    if (
      !Array.isArray(value) ||
      value.some((v) => typeof v !== "string" || v.trim() === "")
    ) {
      throw new Error(
        `ONBOARD_ROLES["${role}"] must be an array of non-empty strings`,
      );
    }
    out[role] = value as string[];
  }
  return out;
}

function getAuth() {
  const keyPath = process.env.GOOGLE_SERVICE_ACCOUNT_KEY;
  const adminEmail = process.env.GOOGLE_ADMIN_EMAIL;
  if (!keyPath) throw new Error("GOOGLE_SERVICE_ACCOUNT_KEY not set");
  if (!adminEmail) throw new Error("GOOGLE_ADMIN_EMAIL not set");
  return new google.auth.GoogleAuth({
    keyFile: keyPath,
    scopes: ["https://www.googleapis.com/auth/admin.directory.group.member"],
    clientOptions: { subject: adminEmail },
  });
}

export function getGroupsDirectory() {
  return google.admin({ version: "directory_v1", auth: getAuth() });
}

function statusOf(err: any): number | undefined {
  return err?.code ?? err?.response?.status;
}

// Adds userEmail to groupEmail as a MEMBER. Idempotent: an existing membership
// (409 / duplicate) resolves to "existed" rather than throwing.
export async function addGroupMember(
  groupEmail: string,
  userEmail: string,
): Promise<"added" | "existed"> {
  const dir = getGroupsDirectory();
  try {
    await dir.members.insert({
      groupKey: groupEmail,
      requestBody: { email: userEmail, role: "MEMBER" },
    });
    return "added";
  } catch (err: any) {
    const status = statusOf(err);
    const msg = String(err?.message ?? "");
    if (status === 409 || /duplicate|already a member|memberKey/i.test(msg)) {
      return "existed";
    }
    if (status === 404) {
      throw new Error(`Group not found: ${groupEmail}. Check ONBOARD_ROLES.`);
    }
    if (status === 403) {
      throw new Error(
        `Permission denied adding to ${groupEmail}. The service account may be ` +
          `missing the admin.directory.group.member scope (domain-wide delegation).`,
      );
    }
    throw err;
  }
}

// Returns the lowercased emails of every direct member of groupEmail.
// A missing group (404) yields [] rather than throwing.
export async function listGroupMemberEmails(
  groupEmail: string,
): Promise<string[]> {
  const dir = getGroupsDirectory();
  const emails: string[] = [];
  let pageToken: string | undefined;
  try {
    do {
      const res = await dir.members.list({
        groupKey: groupEmail,
        maxResults: 200,
        pageToken,
      });
      for (const m of res.data.members ?? []) {
        if (m.email) emails.push(m.email.toLowerCase());
      }
      pageToken = res.data.nextPageToken ?? undefined;
    } while (pageToken);
  } catch (err: any) {
    if (statusOf(err) === 404) return [];
    throw err;
  }
  return emails;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test test/google-groups.test.ts`
Expected: PASS — 11 tests pass.

- [ ] **Step 5: Verify the whole module imports (covers the API helpers)**

Run: `bun -e 'await import("./src/lib/google-groups.ts"); console.log("ok")'`
Expected: prints `ok` (no syntax/import errors).

- [ ] **Step 6: Commit**

```bash
git add src/lib/google-groups.ts test/google-groups.test.ts
git commit -m "feat(lib): shared google-groups helpers (roles, addresses, membership)"
```

---

### Task 2: Onboarding "Google Groups" step + wiring

**Files:**
- Create: `src/onboard/steps/google-groups.ts`
- Modify: `src/onboard/types.ts` (add `role?`, `groupsJoined?` to `Context`)
- Modify: `src/onboard/lib/prompt.ts` (`chooseMulti` gains preselect)
- Modify: `src/onboard/run.ts` (register step + auto-skip)
- Modify: `src/onboard/lib/summary.ts` (Google Groups section)
- Modify: `bin/onboard` (parse `--role`)

**Interfaces:**
- Consumes: `parseRoles`, `resolveGroupAddress`, `addGroupMember`, `getDomain` from `src/lib/google-groups` (Task 1); `Step`, `Context` from `../types`; `choose`, `chooseMulti` from `../lib/prompt`.
- Produces: `googleGroupsStep: Step` (consumed by `run.ts`); `Context.role`, `Context.groupsJoined` (consumed by the step and `summary.ts`).

- [ ] **Step 1: Add the new Context fields**

In `src/onboard/types.ts`, add to the `Context` interface — `role` near the other preselect fields, `groupsJoined` in the "Populated by steps" block:

```ts
  // Role preselect for the Google Groups step (skip prompt when set):
  role?: string; // configured role name, e.g. "Sales Rep"
```

```ts
  groupsJoined?: string[]; // Google Group addresses the user was added to
```

- [ ] **Step 2: Extend `chooseMulti` to support preselected items**

In `src/onboard/lib/prompt.ts`, replace the existing `chooseMulti` with:

```ts
export async function chooseMulti(
  items: string[],
  options: { selected?: string[] } = {},
): Promise<string[]> {
  const args = ["choose", "--no-limit"];
  if (options.selected?.length) {
    args.push(`--selected=${options.selected.join(",")}`);
  }
  args.push(...items);
  const result = await gum(args);
  return result.split("\n").filter(Boolean);
}
```

- [ ] **Step 3: Verify prompt.ts still imports**

Run: `bun -e 'await import("./src/onboard/lib/prompt.ts"); console.log("ok")'`
Expected: prints `ok`.

- [ ] **Step 4: Write the step**

Create `src/onboard/steps/google-groups.ts`:

```ts
import type { Step, Context } from "../types";
import {
  parseRoles,
  resolveGroupAddress,
  addGroupMember,
  getDomain,
} from "../../lib/google-groups";
import { choose, chooseMulti } from "../lib/prompt";

const SKIP = "None (skip groups)";

export const googleGroupsStep: Step = {
  name: "Google Groups",

  // Membership is multi-valued with no clean "already done" signal; the step is
  // interactive and addGroupMember is idempotent, so always run when reached.
  async check(): Promise<boolean> {
    return false;
  },

  async run(ctx: Context): Promise<void> {
    const roles = parseRoles(process.env.ONBOARD_ROLES);
    const roleNames = Object.keys(roles);
    if (roleNames.length === 0) {
      console.log("  (ONBOARD_ROLES has no roles - nothing to do)");
      ctx.groupsJoined = [];
      return;
    }

    const domain = getDomain();
    let role = ctx.role;
    if (role && !roleNames.includes(role)) {
      console.log(`  --role "${role}" is not a configured role; ignoring.`);
      role = undefined;
    }
    if (!role) {
      role = await choose([...roleNames, SKIP]);
    }
    if (role === SKIP) {
      ctx.groupsJoined = [];
      return;
    }

    const addresses = roles[role].map((t) => resolveGroupAddress(t, domain));
    const selected = await chooseMulti(addresses, { selected: addresses });
    if (selected.length === 0) {
      ctx.groupsJoined = [];
      return;
    }

    const joined: string[] = [];
    for (const group of selected) {
      const result = await addGroupMember(group, ctx.email);
      console.log(`    ${result === "added" ? "+" : "="} ${group}`);
      joined.push(group);
    }
    ctx.groupsJoined = joined;
  },
};
```

- [ ] **Step 5: Register the step and auto-skip when unconfigured**

In `src/onboard/run.ts`:

(a) Add the import after the `googleStep` import:

```ts
import { googleGroupsStep } from "./steps/google-groups";
```

(b) Insert `googleGroupsStep` into the `steps` array immediately after `googleStep`:

```ts
const steps: Step[] = [
  googleStep,
  googleGroupsStep,
  amberjackStep,
  phenixStep,
  twilioStep,
  directLineStep,
  zoiperStep,
];
```

(c) After the existing `if (!process.env.TWILIO_ACCOUNT_SID) { ... }` block, add:

```ts
  // No role->group config for this tenant: skip the Google Groups step rather
  // than prompt with an empty list. (Step key = "Google Groups" lowercased,
  // whitespace stripped = "googlegroups".)
  if (!process.env.ONBOARD_ROLES) {
    if (!skip.includes("googlegroups")) skip.push("googlegroups");
    console.log("  (ONBOARD_ROLES unset - skipping Google Groups)");
  }
```

- [ ] **Step 6: Add the summary section**

In `src/onboard/lib/summary.ts`, add a Google Groups block after the Google Workspace block:

```ts
  Google Groups
    Joined: ${ctx.groupsJoined?.length ? ctx.groupsJoined.join(", ") : "skipped"}
```

- [ ] **Step 7: Parse `--role` in bin/onboard**

In `bin/onboard`:

(a) Add `role` to the `parseArgs` options (alongside `channel`):

```ts
    channel: { type: "string" },
    role: { type: "string" },
```

(b) Add `role` to the `ctx` object literal:

```ts
const ctx: Context = {
  firstName,
  lastName,
  email,
  directLine,
  phenixChannel: values.channel,
  role: values.role,
};
```

- [ ] **Step 8: Verify everything imports and the flow wires up**

Run: `bun -e 'await import("./src/onboard/run.ts"); await import("./src/onboard/steps/google-groups.ts"); await import("./src/onboard/lib/summary.ts"); console.log("ok")'`
Expected: prints `ok`.

- [ ] **Step 9: Verify the step's empty-roles path (non-interactive, no Google calls)**

This drives `run()` directly with no `ONBOARD_ROLES`, exercising the graceful no-op branch without invoking `gum` or the Directory API. Note: the session shell is **fish**, so use `env` to set the variable rather than a `VAR= cmd` prefix.

Run:
```bash
env -u ONBOARD_ROLES bun -e 'import {googleGroupsStep} from "./src/onboard/steps/google-groups.ts"; const ctx = {firstName:"T", lastName:"U", email:"t@e.com", directLine: undefined}; await googleGroupsStep.run(ctx); console.log("joined:", JSON.stringify(ctx.groupsJoined));'
```
Expected: prints `(ONBOARD_ROLES has no roles - nothing to do)` then `joined: []`. (The `run.ts` auto-skip wiring — which prevents the step from being reached at all when `ONBOARD_ROLES` is unset — is verified by review and by the import check in Step 8.)

- [ ] **Step 10: Commit**

```bash
git add src/onboard/steps/google-groups.ts src/onboard/types.ts src/onboard/lib/prompt.ts src/onboard/run.ts src/onboard/lib/summary.ts bin/onboard
git commit -m "feat(onboard): add Google Groups role-bundle step"
```

---

### Task 3: `bin/groups` CLI (roles / show / audit / add)

**Files:**
- Create: `bin/groups`

**Interfaces:**
- Consumes: `parseRoles`, `resolveGroupAddress`, `addGroupMember`, `listGroupMemberEmails`, `getDomain` from `src/lib/google-groups` (Task 1).
- Produces: a standalone CLI (no exports).

- [ ] **Step 1: Write the CLI**

Create `bin/groups`:

```ts
#!/usr/bin/env bun

import "../src/lib/load-env"; // must be first: loads repo-root .env regardless of cwd
import { parseArgs } from "util";
import {
  parseRoles,
  resolveGroupAddress,
  addGroupMember,
  listGroupMemberEmails,
  getDomain,
} from "../src/lib/google-groups";

const BROAD_DEFAULT = ["staff@"];

// "Broad" groups (everyone-style lists) are excluded from the audit drift
// comparison. Configurable via ONBOARD_BROAD_GROUPS (comma-separated tokens).
function broadGroups(domain: string): Set<string> {
  const raw = process.env.ONBOARD_BROAD_GROUPS;
  const tokens =
    raw && raw.trim()
      ? raw.split(",").map((s) => s.trim()).filter(Boolean)
      : BROAD_DEFAULT;
  return new Set(tokens.map((t) => resolveGroupAddress(t, domain).toLowerCase()));
}

function usage(): never {
  console.error(
    [
      "Usage:",
      "  bin/groups roles",
      "  bin/groups show <email>",
      '  bin/groups audit "<Role>"',
      '  bin/groups add <email> [--role "<Role>"] [--group <addr>]',
    ].join("\n"),
  );
  process.exit(1);
}

const argv = Bun.argv.slice(2);
const cmd = argv[0];
const domain = getDomain();
const roles = parseRoles(process.env.ONBOARD_ROLES);

function rolesToAddresses(role: string): string[] {
  return roles[role].map((t) => resolveGroupAddress(t, domain));
}

if (cmd === "roles") {
  const names = Object.keys(roles);
  if (names.length === 0) {
    console.log("No roles configured (set ONBOARD_ROLES).");
    process.exit(0);
  }
  for (const name of names) {
    console.log(`${name}:`);
    for (const t of roles[name]) console.log(`  ${resolveGroupAddress(t, domain)}`);
  }
  process.exit(0);
}

if (cmd === "show") {
  const email = argv[1];
  if (!email) usage();
  const all = new Set<string>();
  for (const tokens of Object.values(roles)) {
    for (const t of tokens) all.add(resolveGroupAddress(t, domain));
  }
  const lower = email.toLowerCase();
  console.log(`Group membership for ${email}:`);
  for (const group of [...all].sort()) {
    const members = await listGroupMemberEmails(group);
    console.log(`  ${members.includes(lower) ? "✓" : " "} ${group}`);
  }
  process.exit(0);
}

if (cmd === "audit") {
  const roleName = argv[1];
  if (!roleName) usage();
  if (!roles[roleName]) {
    console.error(`Unknown role: ${roleName}`);
    process.exit(1);
  }
  const broad = broadGroups(domain);
  const groups = rolesToAddresses(roleName);
  const memberMap = new Map<string, string[]>();
  for (const g of groups) memberMap.set(g, await listGroupMemberEmails(g));

  console.log(`Audit: ${roleName}`);
  for (const g of groups) {
    const tag = broad.has(g.toLowerCase()) ? "  (broad, not diffed)" : "";
    console.log(`  ${String(memberMap.get(g)!.length).padStart(4)}  ${g}${tag}`);
  }

  const narrow = groups.filter((g) => !broad.has(g.toLowerCase()));
  if (narrow.length < 2) {
    console.log("\nNot enough non-broad groups to compute drift.");
    process.exit(0);
  }
  const union = new Set<string>();
  for (const g of narrow) for (const m of memberMap.get(g)!) union.add(m);
  console.log("\nDrift (in some but not all of the role's narrow groups):");
  let any = false;
  for (const m of [...union].sort()) {
    const missing = narrow.filter((g) => !memberMap.get(g)!.includes(m));
    if (missing.length > 0) {
      any = true;
      console.log(`  ${m}  missing from: ${missing.join(", ")}`);
    }
  }
  if (!any) console.log("  none");
  process.exit(0);
}

if (cmd === "add") {
  const { values, positionals } = parseArgs({
    args: argv.slice(1),
    options: {
      role: { type: "string" },
      group: { type: "string" },
    },
    allowPositionals: true,
    strict: true,
  });
  const email = positionals[0];
  if (!email) usage();

  let targets: string[];
  if (values.group) {
    targets = [resolveGroupAddress(values.group, domain)];
  } else if (values.role) {
    if (!roles[values.role]) {
      console.error(`Unknown role: ${values.role}`);
      process.exit(1);
    }
    targets = rolesToAddresses(values.role);
  } else {
    console.error('Specify --role "<Role>" or --group <addr>');
    process.exit(1);
  }

  for (const g of targets) {
    const result = await addGroupMember(g, email);
    console.log(`  ${result === "added" ? "+" : "="} ${g}`);
  }
  process.exit(0);
}

usage();
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x bin/groups`
Expected: no output.

- [ ] **Step 3: Verify `roles` works against real config**

Run: `bin/groups roles`
Expected: prints each configured role and its resolved group addresses (or "No roles configured" if `ONBOARD_ROLES` is unset locally). No stack trace.

- [ ] **Step 4: Verify `audit` against a real role**

Run: `bin/groups audit "Sales Rep"` (substitute a real configured role name)
Expected: per-group member counts, `staff@` tagged `(broad, not diffed)`, and a drift section. No stack trace.

- [ ] **Step 5: Verify `show` against a real user**

Run: `bin/groups show <a-real-user@ameriglide.com>`
Expected: a checklist of role-groups with ✓ next to the ones they're in.

- [ ] **Step 6: Commit**

```bash
git add bin/groups
git commit -m "feat(groups): bin/groups audit + add to reconcile membership"
```

---

### Task 4: Documentation (`.env.example`, `README.md`)

**Files:**
- Modify: `.env.example`
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing (docs only).

- [ ] **Step 1: Document `ONBOARD_ROLES` in `.env.example`**

Append to `.env.example` (generic placeholders only — no real group taxonomy):

```sh
# Role -> Google Group bundles used by bin/onboard's "Google Groups" step and by
# bin/groups. JSON object: role name -> array of group tokens. Short tokens (no
# domain, or a trailing "@") expand to <localpart>@$DOMAIN, so the same config
# works across tenants. Unset -> the onboarding Google Groups step is skipped.
# ONBOARD_ROLES='{"Role Name":["staff@","some-group@"],"Another Role":["staff@","other-group@"]}'

# Optional: comma-separated "broad" (everyone-style) groups excluded from the
# bin/groups audit drift comparison. Defaults to "staff@".
# ONBOARD_BROAD_GROUPS=staff@
```

- [ ] **Step 2: Document the feature in `README.md`**

Add a subsection to `README.md` (under the onboarding documentation):

```markdown
### Google Groups

`bin/onboard` adds new hires to distribution lists based on role bundles defined
in `ONBOARD_ROLES` (a JSON map of role name -> group addresses, in `.env`). The
onboarder picks a role; its groups are pre-selected and can be toggled before
applying. Pass `--role "Sales Rep"` to skip the prompt. If `ONBOARD_ROLES` is
unset, the step is skipped.

Short group tokens (`sales-staff@`) expand to `<localpart>@$DOMAIN`; full
addresses (`marketing@other-domain.com`) pass through unchanged.

To repair existing membership, use `bin/groups`:

- `bin/groups roles` — list configured roles and their groups.
- `bin/groups show <email>` — which role-groups a person is currently in.
- `bin/groups audit "<Role>"` — member counts plus a drift report (people in
  some but not all of a role's groups). Broad lists like `staff@` are shown but
  excluded from the diff; override the broad set with `ONBOARD_BROAD_GROUPS`.
- `bin/groups add <email> [--role "<Role>"] [--group <addr>]` — add a person to a
  role's full bundle (or one group), idempotently.
```

- [ ] **Step 3: Verify `.env.example` is still ASCII-safe** *(repo convention for committed text)*

Run: `grep -nP '[^\x00-\x7F]' .env.example README.md || echo "clean"`
Expected: `clean` (or only pre-existing non-ASCII in README; do not introduce new non-ASCII).

- [ ] **Step 4: Commit**

```bash
git add .env.example README.md
git commit -m "docs(onboard): document ONBOARD_ROLES and bin/groups"
```

---

## Notes for the implementer

- **Domain-wide delegation:** `addGroupMember` / `listGroupMemberEmails` use the
  `admin.directory.group.member` scope. The offboarding flow already uses this
  scope with the same service account, so delegation should already be granted.
  A `403` from `addGroupMember` surfaces a message pointing at this.
- **Manual verification of writes:** Google Directory calls are not mocked. The
  safest end-to-end check of `addGroupMember` is `bin/groups add <test-user> --group <a-test-group@>`
  followed by `bin/groups show <test-user>`, then removing the test membership
  in the Admin console if needed.
- After all tasks, reconciling the real `sales-staff@` drift is a runtime
  operation (`bin/groups audit` then `bin/groups add ...`), not a code change.
