# Runbook: onboard an always-on server to monitoring

How to put a sage-* (always-on Windows) server under the tailnet reliability +
host-metrics stack. Everything is driven from `bin/copy` so you don't have to
remember the API calls. Part of the AG-24 epic (tailnet self-healing watchdog +
zombie detector).

## What a monitored server gets

1. **Tailscale watchdog** — self-heals a wedged Tailscale tunnel (restart,
   debounced 2x, backoff). `scripts/tailscale-watchdog.ps1`, run by a SYSTEM
   scheduled task every 5 min.
2. **Better Stack heartbeat** (`tailnet-<server>`) — alerts if the box stops
   beating (i.e. is actually down), routed through escalation policy **114897**.
3. **Vector host_metrics** — ships CPU / RAM / disk to a per-host Better Stack
   telemetry source (the "Hosts" dashboard). Bundled for sage-iai / sage-server.

The Headscale **zombie detector** (AG-25) is a separate, fleet-wide backstop
that runs on the headscale host, not per-server — see `ops/headscale/README.md`.

## Tokens (the easy thing to forget)

Better Stack has **two separate APIs with two separate token types.** Both live
in `.env` (gitignored) as **team-scoped** tokens (the old global token was
retired):

| `.env` var                   | API                         | Used for |
|------------------------------|-----------------------------|----------|
| `BETTERSTACK_UPTIME_TOKEN`   | `uptime.betterstack.com`    | heartbeats, incidents, escalation policies |
| `BETTERSTACK_TELEMETRY_TOKEN`| `telemetry.betterstack.com` | telemetry **sources** (Vector host_metrics) |

A uptime token **cannot** create telemetry sources and vice-versa — that is why
source provisioning is its own step.

Per-host source tokens are cached in `.env` as `VECTOR_SOURCE_TOKEN_<HOST>`
(e.g. `VECTOR_SOURCE_TOKEN_SAGE_IAI`), written automatically by the provisioning
step below.

## Onboarding steps

Run `./bin/copy` and pick, in order:

1. **"Server monitoring — provision Better Stack Vector source (saves token to
   .env)..."**
   - Choose the server. Creates (or reuses) the `<server> (Vector)` telemetry
     source via the telemetry API (vector platform, `us_east`, 90-day logs +
     metrics), and saves its ingest token to `.env`.
   - Idempotent: re-running reuses the existing source.
   - Skip this for a server that already has a `VECTOR_SOURCE_TOKEN_*` in `.env`.

2. **"Server monitoring — install watchdog + heartbeat (+ Vector) on a sage-*
   server..."**
   - Choose the server. Copies a PowerShell one-liner to your clipboard.
   - On the server, open an **admin PowerShell** and paste it. It downloads
     `install-tailscale-watchdog.ps1` from the public repo and runs it with the
     uptime token (and the Vector source token if present).
   - If no `VECTOR_SOURCE_TOKEN_*` is set, the command uses `-SkipVector`
     (watchdog + heartbeat only) and warns you — provision the source first to
     include metrics.

Do the **first server (sage-server) as a live drill** and watch one watchdog
cycle before doing the others (see AG-27).

## Verify

- **Heartbeat:** in Better Stack, `tailnet-<server>` exists and shows escalation
  policy **114897** (set by `install-tailscale-watchdog.ps1`).
- **Scheduled task:** on the server, `Get-ScheduledTask "AG Tailscale Watchdog"`
  is `Ready`; `C:\ProgramData\ag-admin\tailscale-watchdog.log` shows cycles.
- **Metrics:** the `<server> (Vector)` source in Better Stack shows incoming
  data; the Hosts dashboard renders CPU/RAM/disk.

## Adding a new always-on server

1. Add its `given_name` to the detector allowlist if it should also be covered
   by the zombie detector: `MONITORED_NODES` in
   `/etc/headscale-zombie-detector.env` on the headscale host (see
   `ops/headscale/README.md`).
2. Run the two `bin/copy` steps above.
