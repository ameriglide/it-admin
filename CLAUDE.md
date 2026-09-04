# it-admin

IT administration scripts and ops tooling for AmeriGlide.

This file is the shared brief for coding agents working in this repository.
`AGENTS.md` is a symlink to it, so Claude Code and other agents read the same
document — edit this file, never the symlink.

> The repo is `ameriglide/it-admin`. It is commonly checked out at
> `~/Projects/ag-admin`, so the directory name and the repo name disagree;
> memories and tooling for it are filed under `it-admin`.

Operational detail — credential locations, monitoring IDs, per-host specifics,
API quirks — lives in mem0 under `app_id=it-admin` (and `team-shared`) rather
than here, so it can be corrected without a commit. This file keeps the
structural facts and the constraints that must not be violated.

## This repo is PUBLIC

`ameriglide/it-admin` is a **public** repo — the workstation and server setup
one-liners `irm` raw files from it without auth. Therefore:

- **Never commit internal network topology**: tailnet/CGNAT IPs (`100.64.0.*`),
  the headscale control URL, or host inventory. These live in `.env`
  (gitignored) and are passed in as parameters by `bin/copy`. PowerShell
  scripts take them as parameters (`-Anchors`, `-HeadscaleUrl`) and must not
  hardcode them.
- **Never commit secrets.** Tokens live in `.env` and are passed as arguments.

`.gitignore` already covers `.env*` (except `.env.example`),
`service-account.json`, `*.tbz2`/`*.tar.bz2` secret archives, and
`scripts/*.rdp` (which would carry an internal FQDN). If you add a new artifact
that embeds topology or credentials, add it there in the same commit.

## Design and plan docs are in a PRIVATE repo

Specs and plans live in **`ameriglide/it-admin-docs`** (private), not here,
because they contain topology. Clone that repo for design context and add new
design/plan docs there. `docs/superpowers/README.md` in this repo is only a
pointer.

## Layout

- `bin/` — bash entry points: `copy` (interactive clipboard helper for
  workstation setup), `cost-allocation`, `groups`, `onboard`, `offboard`,
  `reset-user`, `rotate-ssm-activation`, `sage-taxcode-diff`, `sip-password`.
- `src/` — TypeScript run by Bun: `cost-allocation/`, `offboard/`, `onboard/`,
  and shared `lib/` (`google-groups.ts`, `load-env.ts`).
- `scripts/` — PowerShell for Windows workstations and servers (`sage-taxcode-{lib,dump,apply}.ps1` for Sage system-table recovery), plus a couple
  of shell installers.
- `ops/` — systemd units and their scripts (currently the headscale zombie
  detector).
- `docs/runbooks/` — operator runbooks. `docs/superpowers/` — pointer only.
- `test/` — Bun tests (`*.test.ts`) plus a Pester suite
  (`watchdog-core.Tests.ps1`).

## Commands

```bash
bun install
bun test            # runs the *.test.ts suites under test/
```

Environment is loaded by `source ~/Projects/ag-admin/load-env.sh` (or, inside
`bin/copy`, by its own reader). Do **not** plain-`source` `.env` — see the
mem0 note on how that file is mounted and why sourcing it breaks.

`.env` is a read-only 1Password Environment mount and holds hand-authored
config only. **Machine-written values — rotated SSM activations, Tailscale
keys, Vector tokens — are not in it.** They live in the 1Password item
`ag-admin-runtime`, in a vault of the same name, because Environments have no
write path outside the desktop app. `bin/copy` and `bin/rotate-ssm-activation`
read and write that item; TypeScript entrypoints use `src/lib/op-runtime.ts`.
Reading it costs several seconds, so fetch the one field you need rather than
loading it eagerly:

```bash
op item get ag-admin-runtime --vault ag-admin-runtime \
   --account ameriglide.1password.com --fields label=SSM_ACTIVATION_ID --reveal
```

There is no `.env.local`. It existed until 2026-08-21 as the writable half of
the pair, and was removed because it silently shadowed stale copies of the same
keys still sitting in the Environment — which value you got depended on which
loader you went through. Do not reintroduce it.

## PowerShell

ASCII-only in `.ps1` files **and in commit messages** — Windows PowerShell 5.1
parses scripts as ANSI, and a multi-byte character desyncs the parser so the
error surfaces past the offending line as a misleading "string is missing the
terminator". No em-dashes, en-dashes, curly quotes, or ellipses. Verify before
pushing:

```bash
rg -n '[^\x00-\x7F]' scripts/*.ps1   # should print nothing
```

Use `rg`, not `grep -P`. `rg` is a required tool for this repo. Whether
`grep -P` works depends entirely on which grep is installed -- a stock BSD grep
has no `-P` at all, while some replacements (ugrep, GNU grep) do -- so the
`grep -P` form is not portable across the team's machines. `rg` always is. `rg` also
ignores a leading UTF-8 BOM, which is what you want — `scripts/deploy-gcpw.ps1`
intentionally carries one (a BOM is how PowerShell 5.1 is told to read a file
as UTF-8), and a byte-level check would flag it as a false positive.

The husky `pre-commit` hook stamps `$Script:Revision` in each staged `.ps1`
with the latest commit that touched it, and re-stages the file. Keep the
`$Script:Revision = "..."` line intact in scripts that have one.

## Onboarding a server to monitoring

_last verified: 2026-08-19_

See `docs/runbooks/server-monitoring.md` and the "Server monitoring" entries in
`bin/copy`. Better Stack token scoping and its API quirks are in mem0
(`app_id=it-admin`, topic `betterstack-team-scoped-tokens`) rather than
repeated here.

## Sage system-table gap (AG-806)

_last verified: 2026-09-04_

The Aug 29, 2026 Sage cutover did not re-migrate `MAS_System`; sales tax
codes, class lines, and VI jobs changed between June 16 and Aug 28 were
restored from the Aug 28 snapshot with `scripts/sage-taxcode-*.ps1` and
`bin/sage-taxcode-diff`. Procedure: `docs/runbooks/sage-system-table-gap.md`.
