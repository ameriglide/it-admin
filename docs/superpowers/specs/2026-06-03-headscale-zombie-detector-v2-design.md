# Headscale zombie detector v2 — active reachability — Design

## Background

AMG-410 deployed the v1 detector (`ops/headscale/headscale-zombie-detector.sh`), whose premise was
"`online=true` in Headscale **AND** `last_seen` older than 15 min = zombie." On-host verification
(headscale **v0.28.0**) proved that premise invalid:

- **`last_seen` is not a keepalive.** It bumps on map-session events (re-handshake / endpoint
  change), not on DERP keepalives. Over a 30 s window only **7 of 59** online nodes advanced
  `last_seen`; servers `web` and `db` were `online=true` but **11.8 h** stale while fully serving.
  The headscale container had been up 2.5 months, so this is steady-state behaviour, not a restart
  artifact.
- **`online` is sticky.** On an interrupted connection v0.28 keeps a node `online=true` until
  headscale restarts (juanfont/headscale issue #2129; the HA-router probe in v0.29 PR #3194 only
  covers 2+ nodes sharing a prefix, not general nodes). So `online` alone is also unreliable.
- **Result:** a dry run at the real 900 s threshold flagged **26** nodes; a `tailscale ping` sweep
  found **24 reachable** (false positives, ~92 %), only `adams-lenovo7400` and `narwhal`
  unreachable.

The reliable zombie signal is **active reachability**. The headscale host is itself a tailnet member
(`100.64.0.4`, has the `tailscale` CLI, can reach tailnet IPs), so it can probe nodes directly.

Upgrading to v0.29 was considered and deferred: it is a separate, riskier decision (min Tailscale
client v1.80.0, ACL wildcard semantics change, enforced sequential minor upgrades) and does not by
itself solve fleet-wide zombie detection.

## Goal

Flag an **always-on** node that Headscale reports `online=true` but that is actually **unreachable**,
raise/auto-resolve a Better Stack incident per node, and do so without false alarms from
normally-offline workstations or transient network blips.

## Scope decisions

- **Always-on infra only**, via an explicit allowlist. Workstations/laptops go unreachable normally
  (sleep/suspend while Headscale still shows `online=true`) and are covered by the AMG-409 self-heal
  watchdog; probing them would re-introduce noise.
- **Allowlist source: explicit env-var list** (`MONITORED_NODES`), not Headscale tags. Tags were
  rejected because `tag:always-on` requires declaring `tagOwners` in an ACL policy, and this tailnet
  currently has **no** ACL policy (default allow-all). Introducing one to enable a monitoring tag is
  disproportionate risk; an env list is identical in behaviour with zero tailnet-config change.
- **Allowlist contents (14 nodes):** `web phenix headscale db sage-amg sage-iai sage-server amg-bjx
  iai-bjx tailscale-router-b asterisk-pbx asterisk-pbx-nyc3 amg-blog youtrack`.
- **Debounce: 2 consecutive unreachable runs** (~10 min at the 5-min timer cadence) before opening
  an incident — matches the AMG-409 watchdog's 2-failure debounce.
- **`last_seen` is dropped entirely** as a signal (kept out of the decision; may be logged for
  context only).

## Architecture

Unchanged shape from v1: a single bash script `ops/headscale/headscale-zombie-detector.sh`, run by
the existing systemd timer (`headscale-zombie-detector.timer`, every 5 min) on the Headscale host,
configured from `/etc/headscale-zombie-detector.env`.

Data sources:
- `docker exec <container> headscale nodes list -o json` — inventory + `online` + tailnet IPs.
- `tailscale ping` (run on the host) — reachability.
- Better Stack Incidents API — unchanged (`better_stack_team_id=540247`, `requester_email`).

Dependencies on the host (already verified present): `docker`, `jq`, `curl`, `logger`, `tailscale`.

## Per-run logic

For each node whose `given_name` is in `MONITORED_NODES`:

1. **`online == false`/null** → powered off, not a zombie. Reset its failure counter; resolve any
   open incident for it; do **not** probe. (A genuinely-down always-on server is the AMG-408
   heartbeat's job, not this detector's.)
2. **`online == true`** → resolve the node's tailnet IPv4 from `ip_addresses` (the `100.64.x` entry),
   then probe: `tailscale ping -c 1 --timeout 5s --until-direct=false <ip>`, retried up to **3×**.
   **Reachable if any attempt returns a pong** (DERP-relayed counts).
   - **Reachable** → reset counter to 0; resolve open incident if present.
   - **Unreachable** → increment counter. When counter **≥ `FAILS_THRESHOLD` (2)** and no incident
     is currently open for the node → **open** a Better Stack incident.

### Safety valve (mass-failure guard)

If **zero** monitored nodes that are `online=true` are reachable in a run, assume the local
`tailscale` daemon / DERP path is the problem (not 14 simultaneous zombies). **Fail safe**: log a
warning and make no incident or counter changes this run. This prevents an incident storm when
tailscale on the host itself hiccups.

## State

`/var/lib/headscale-zombie-detector/state.json`, a per-node map:

```json
{
  "web":     { "fails": 0, "incident": null },
  "narwhal": { "fails": 2, "incident": "12345" }
}
```

- `fails` — consecutive unreachable-run count (reset to 0 on reachable / offline).
- `incident` — open Better Stack incident id, or null.

Nodes no longer in `MONITORED_NODES` have any open incident resolved and are pruned from state.

## Error handling

- `headscale nodes list` fails or emits non-JSON → fail safe: log, exit 0, change nothing (matches
  v1's fail-safe-on-shape-change behaviour).
- Better Stack **create** fails → log a warning, leave the counter at threshold, do **not** record an
  id; retried next run.
- Better Stack **resolve** fails → keep the `incident` id and retry next run.
- `tailscale ping` distinguishes only pong/no-pong; daemon-down is handled by the safety valve, not
  per-node.

## Incident content

- Summary: `Tailnet zombie: <node>`
- Description: `<node> is online in Headscale but unreachable via tailscale ping for N consecutive
  checks (~M min). Likely a half-closed Tailscale control connection. Restart Tailscale on <node> /
  check the host.`
- `call:false, sms:false, email:true`, `better_stack_team_id:540247`. Incidents route through the
  AMG-397 escalation policy (configured Better Stack side).

## Modes

- **`DRY_RUN=1`** — read-only: classify every monitored node (reachable / unreachable / offline-skip)
  and log what it *would* do; make no API calls and no state writes.

## Testability

- **Pure decision function** `decide(prev_fails, online, reachable, has_incident, threshold)` →
  one of `noop | incr | open | resolve | reset`. No I/O. This isolates the debounce/lifecycle logic
  from docker/tailscale/curl.
- **`test-headscale-zombie-detector.sh`** — sources the function and asserts the decision table:
  healthy (online+reachable → reset/resolve), transient-1× (incr, no open), sustained-2× (open),
  recovery (resolve), powered-off (reset/resolve, no probe), already-open (noop while still down).
- **On-host:** `DRY_RUN=1` classification print; the README manual-verification flow (force a known
  always-on node unreachable, confirm raise after 2 runs and resolve on recovery).

## Config (env file)

`/etc/headscale-zombie-detector.env` (chmod 600). Changes from v1:
- **Add** `MONITORED_NODES="web phenix headscale db sage-amg sage-iai sage-server amg-bjx iai-bjx
  tailscale-router-b asterisk-pbx asterisk-pbx-nyc3 amg-blog youtrack"`.
- **Add** `FAILS_THRESHOLD=2`.
- **Remove** `STALE_SECONDS`.
- **Keep** `BETTERSTACK_API_TOKEN` (team-scoped uptime token; no team id needed), `REQUESTER_EMAIL`,
  `HEADSCALE_CONTAINER=headscale`.

## Out of scope

- Headscale v0.29 upgrade (separate ticket if pursued).
- Alerting on always-on servers that are `online=false` (AMG-408 heartbeat covers this).
- Workstation reachability alerting (AMG-409 self-heal watchdog covers this).
