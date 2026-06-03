# Tailnet self-healing watchdog + zombie detector — Design

**Date:** 2026-06-03
**Author:** Michael Ventura (with Claude)
**Status:** Approved design — pending implementation plan
**Linear:** New parent ticket under project *Server resource monitoring in Better Stack* (AMG, `49d21c28-ee7c-4ac3-9a64-b981f779591e`)

## Background

On 2026-06-03 a user (`mcgee` / `100.64.0.66`) could not reach `sage-amg` (`100.64.0.9`) over the
tailnet. Symptoms: the peer showed `tx > 0, rx = 0` and `tailscale ping` timed out, while Headscale
reported `sage-amg` as `online=true` with a `last_seen` that was ~1h43m stale (every other live node
refreshed within seconds).

Root cause: `sage-amg`'s Tailscale control connection had **half-closed** — the stream looked alive
to Headscale but was no longer exchanging keepalives or receiving netmap updates. Its frozen netmap
predated the peer being (re)keyed, so it silently dropped that peer's packets. A `tailscale set`
config nudge did **not** recover it; **restarting the Tailscale service** did.

This is a silent, self-inflicted outage of exactly the class the *Server resource monitoring in
Better Stack* project exists to eliminate. This design adds tailnet **reachability** monitoring and
**self-healing** to complement that project's resource-metrics monitoring.

### Relationship to the Better Stack monitoring project

- Reuses the project foundation: data region **us_east**, team **540247**, and the alert
  policy/escalation being established in **AMG-397** (in progress). New alerts attach to that policy
  rather than defining a parallel one.
- Distinct *signal*: that project monitors CPU/RAM/disk via Vector; this monitors tailnet
  reachability and self-heals. Same Better Stack instance, same Windows hosts, same "no silent
  failures" goal.
- The server install bundles **Vector host_metrics** onboarding for `sage-iai` and `sage-server`,
  closing most of **AMG-403** for those two boxes while we are on each machine.

## Goals

1. Automatically detect and recover a wedged Tailscale connection on every Windows tailnet node
   (servers and workstations), with no human in the loop.
2. Alert when an **always-on server** stays unreachable despite self-healing.
3. Provide a server-side backstop that flags the zombie signature on **any** node from the
   authoritative source (Headscale), covering nodes the watchdog has not yet reached.
4. Reduce IT support tickets caused by silently-wedged tunnels on user workstations.

## Non-goals

- Monitoring resource metrics (covered by the parent project's other tickets).
- Managing/forcing `accept-routes`. On-prem LAN nodes must keep `accept-routes=false` (enabling it
  hijacks local `192.168.96.0/24` traffic and breaks services like ODBC) — this stays a documented
  default, **not** something the watchdog mutates.
- Remote restart of a Windows service from the Headscale host (the detector is detection-only).

## Design principles by role

| | Self-heal (restart) | Heartbeat alert | Observability |
|---|---|---|---|
| **Servers** (sage-amg, sage-iai, sage-server) | Yes | Yes (per-node gated heartbeat) | Heartbeat + detector |
| **Workstations** (~40 Windows nodes) | Yes | **No** | Detector only |

**Why no workstation heartbeats:** laptops legitimately power off nightly/weekends. A gated heartbeat
would lapse constantly and generate false "down" alerts. The Headscale detector distinguishes a
powered-off node (`online=false`, ignored) from a zombie (`online=true` + stale `last_seen`,
flagged) with no per-workstation config and no nightly noise.

## Components

### 1. `tailscale-watchdog.ps1` (all Windows nodes)

Installed to `C:\ProgramData\ag-admin\tailscale-watchdog.ps1`. One cycle:

1. **Internet check** — confirm basic outbound connectivity (e.g. resolve + reach a public
   endpoint). If the box has **no** internet, do nothing this cycle (the user is simply offline;
   restarting Tailscale would not help).
2. **Tailnet probe** — `tailscale ping --timeout 3s -c 1` against each anchor in config order;
   healthy if **any** anchor returns a pong.
3. **Healthy** → if `heartbeatUrl` is set in config, `Invoke-RestMethod` it (the gated beat). Reset
   the consecutive-failure counter. Exit.
4. **Unhealthy** (internet up, tailnet down) → increment the consecutive-failure counter in the
   state file. Restart only after **2 consecutive** unhealthy cycles (debounce against transient
   wifi blips), subject to backoff. Withhold the beat.
   - **Backoff:** at least **10 min** between restarts; at most **3 restarts/hour**. Once capped,
     stop restarting and rely on the lapsed heartbeat (servers) / detector to alert.
5. **Logging** — append to `C:\ProgramData\ag-admin\tailscale-watchdog.log`, trimmed to the last
   ~1000 lines.

**Modes:** `-Once` (single cycle for manual verification) and `-DryRun` (decide + log, never restart
or beat).

**Decision logic is a pure function** (`Get-WatchdogAction` taking probe results + state, returning
an action) so it is unit-testable without touching the service.

### 2. Per-node config — `tailscale-watchdog.config.json`

```json
{
  "heartbeatUrl": "https://uptime.betterstack.com/api/v1/heartbeat/XXXX",
  "anchors": ["100.64.0.4", "100.64.0.11", "100.64.0.10"],
  "intervalMinutes": 5,
  "minRestartGapMinutes": 10,
  "maxRestartsPerHour": 3,
  "consecutiveFailuresBeforeRestart": 2
}
```

- Servers set `heartbeatUrl`; workstations omit it (`null`) for self-heal-only mode.
- The heartbeat URL is a capability token; ProgramData (admin/SYSTEM-readable) is an acceptable
  location. No other secrets live on the node.

**Anchors:**

| Node | Anchors (in order) |
|---|---|
| sage-amg (`.9`) | `100.64.0.4` (headscale), `100.64.0.11`, `100.64.0.10` |
| sage-iai (`.10`) | `100.64.0.4`, `100.64.0.11`, `100.64.0.9` |
| sage-server (`.11`) | `100.64.0.4`, `100.64.0.9`, `100.64.0.10` |
| Workstations | `100.64.0.4` (headscale), `100.64.0.11` (sage-server) |

The Headscale node (`100.64.0.4`) is the primary anchor everywhere (rock-solid uptime). Multiple
anchors mean one down anchor never causes a false restart.

### 3. Scheduled task

`Register-ScheduledTask "AG Tailscale Watchdog"`:
- Runs as `SYSTEM`, every `intervalMinutes` (5), and at boot.
- `-WindowStyle Hidden -ExecutionPolicy Bypass`, "run whether logged on or not."
- Idempotent: unregister-if-exists, then register.

### 4. `install-tailscale-watchdog.ps1` (servers, run once per box)

Parameters include `-BetterStackApiToken` (also reads `$env:BETTERSTACK_API_TOKEN`). Steps:
1. Provision/reuse a Better Stack heartbeat for the hostname: `GET` heartbeats, reuse by name, else
   `POST /api/v2/heartbeats` with `period=300, grace=900` in team `540247`. Capture its URL.
2. Write `tailscale-watchdog.config.json` with the heartbeat URL and this host's anchor row.
3. Copy `tailscale-watchdog.ps1` to `C:\ProgramData\ag-admin\`.
4. Register the scheduled task.
5. **Bundled (AMG-403):** for `sage-iai`/`sage-server`, install Vector as a Windows service with the
   `host_metrics` source per the AMG-402 pattern (shipping CPU/RAM/disk to a Better Stack source in
   us_east / team 540247).

Re-runnable. ASCII-only. `$Script:Revision` stamped by the existing pre-commit hook.

`grace=900` rationale: a single transient self-heal (detect ~5 min + restart + next healthy beat)
stays well under the grace window, so it does not alert; only a **sustained** outage trips it.

### 5. Workstation install — `setup-workstation.ps1` section

A new `Should-Run "watchdog"` section installs the watchdog in **self-heal-only** mode: copy the
script, write a config with `heartbeatUrl=null` and the workstation anchor row, register the task.
No Better Stack token required, no heartbeat, no new alert noise. Re-runnable via `-Only watchdog`.

### 6. `headscale-zombie-detector` (Headscale host)

A small script driven by a **systemd timer** (or cron) on the Headscale host, every 5 min:
1. `docker exec headscale headscale nodes list -o json`.
2. With `jq`, select nodes where `online == true` **AND** `now - last_seen > 15 min` (live nodes
   refresh in seconds; a powered-off node is `online=false` and is ignored).
3. For each flagged node, raise a Better Stack alert naming the host; auto-resolve when it recovers.
   Dedup via a small state file of currently-open alerts per node so it does not re-fire each run.
   (Exact API — Incidents API keyed by hostname vs a telemetry-log alert rule — finalized in the
   plan; default is the Incidents API. Alerts route through AMG-397's escalation policy.)

Lives in the repo under `ops/headscale/` with an install note. This is the universal backstop and
the **sole** alerting surface for the workstation fleet.

## Testing

- **Watchdog decision logic:** unit-test `Get-WatchdogAction` against synthetic probe/state inputs
  (healthy, transient-1x, sustained, backoff-capped, no-internet).
- **Watchdog live drill (one server):** stop the Tailscale service → confirm restart after 2 cycles,
  withheld beat, recovery beat; confirm no-internet case does not restart.
- **Detector:** temporarily lower the stale threshold to flag a known-idle node; confirm the alert
  fires and auto-resolves; confirm a powered-off (`online=false`) node is not flagged.

## Rollout & Linear

Parent ticket *"Tailnet self-healing watchdog + zombie detector"* under the monitoring project, with
subtasks:

- **(a) Watchdog script + server installer** — build + deploy to the 3 servers. **Assignee: Michael.**
- **(b) Workstation rollout** — `setup-workstation.ps1` section + push to reachable workstations.
  **Assignee: Alan.**
- **(c) Headscale zombie detector** — build + deploy on the Headscale host. **Assignee: Michael.**
- **(d) Vector host_metrics for sage-iai/sage-server** — rolls under **AMG-403**.

Deployment tickets (Alan = workstation installs, Michael = server installs) are cut **after** the
implementation lands.

## Conventions

- ASCII-only PowerShell (no non-ASCII in `.ps1`, comments or strings) — verify with
  `grep -P '[^\x00-\x7F]' scripts/*.ps1`.
- Follows the existing `setup-workstation.ps1` `Should-Run`/section style; revision-stamped.
- Targets the `ameriglide/it-admin` repo the scripts already reference.

## Open items (finalize in the plan)

- Exact Better Stack alerting call for the detector (Incidents API vs telemetry-log alert rule).
- Internet-reachability probe target for the watchdog (public DNS/HTTP endpoint).
- Confirm AMG-397's alert policy/escalation is ready to attach the server heartbeats to, or use a
  default escalation and re-point.
