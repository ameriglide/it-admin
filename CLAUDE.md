# it-admin

IT administration scripts and ops tooling for AmeriGlide.

## This repo is PUBLIC

`ameriglide/it-admin` is a **public** repo (the workstation/server setup
one-liners `irm` raw files from it without auth). Therefore:

- **Never commit internal network topology**: tailnet/CGNAT IPs (`100.64.0.*`),
  the headscale control URL, or host inventory. These live in `.env` (gitignored)
  and are passed as parameters by `bin/copy` (e.g. `HEADSCALE_URL`,
  `SERVERS_MONITORED`, `TAILNET_ANCHORS_*`). PowerShell scripts take them as
  params (`-Anchors`, `-HeadscaleUrl`); they do not hardcode them.
- **Never commit secrets.** Tokens live in `.env` and are passed as args. Better
  Stack uses **team-scoped** tokens: `BETTERSTACK_UPTIME_TOKEN` (uptime API:
  heartbeats/incidents/policies) and `BETTERSTACK_TELEMETRY_TOKEN` (telemetry API:
  sources). Do NOT pass `better_stack_team_id` to the API with team-scoped tokens.

## Design & plan docs are in a PRIVATE repo

Specs and plans live in **`ameriglide/it-admin-docs`** (private), NOT in this
repo, because they contain topology. Clone that repo for design context, and add
new design/plan docs there. `docs/superpowers/README.md` here is just a pointer.

## PowerShell

ASCII-only in `.ps1` files and in commit messages (Windows PS 5.1 parses scripts
as ANSI). No em-dashes, curly quotes, or other multi-byte characters. Verify with
`grep -P '[^\x00-\x7F]' scripts/*.ps1` (should be empty).

## Onboarding a server to monitoring

See `docs/runbooks/server-monitoring.md` and the `bin/copy` "Server monitoring"
entries.
