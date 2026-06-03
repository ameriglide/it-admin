# Headscale zombie-node detector (v2, active reachability)

Flags **always-on** nodes that Headscale reports `online=true` but that are
actually **unreachable** via `tailscale ping` from the Headscale host -- the
signature of a half-closed Tailscale control connection -- and raises a Better
Stack incident per node, auto-resolving on recovery.

Why active probing: on Headscale v0.28 `last_seen` is not a keepalive (it
freezes for stably-connected nodes) and `online` is sticky on interrupted
connections, so "online + stale last_seen" produced ~92% false positives. The
Headscale host is itself a tailnet member, so it probes nodes directly. See
`docs/superpowers/specs/2026-06-03-headscale-zombie-detector-v2-design.md`.

Scope is **always-on infrastructure only** (servers/routers/PBX), listed in
`MONITORED_NODES`. Workstations are covered by the per-node self-heal watchdog
(AMG-409) and are intentionally not probed (they sleep/suspend normally).

## Install (on the Headscale host)

```bash
sudo mkdir -p /opt/headscale-zombie-detector
sudo cp headscale-zombie-detector.sh /opt/headscale-zombie-detector/
sudo chmod +x /opt/headscale-zombie-detector/headscale-zombie-detector.sh
sudo cp headscale-zombie-detector.service headscale-zombie-detector.timer /etc/systemd/system/

# Secrets / config (not committed):
sudo tee /etc/headscale-zombie-detector.env >/dev/null <<'EOF'
BETTERSTACK_API_TOKEN=...
BETTERSTACK_TEAM_ID=540247
REQUESTER_EMAIL=it@ameriglide.com
HEADSCALE_CONTAINER=headscale
FAILS_THRESHOLD=2
MONITORED_NODES=web phenix headscale db sage-amg sage-iai sage-server amg-bjx iai-bjx tailscale-router-b asterisk-pbx asterisk-pbx-nyc3 amg-blog youtrack
EOF
sudo chmod 600 /etc/headscale-zombie-detector.env

sudo systemctl daemon-reload
sudo systemctl enable --now headscale-zombie-detector.timer
```

`MONITORED_NODES` is a space-separated list of Headscale `given_name`s. Edit it
when always-on infrastructure is added or removed; nodes dropped from the list
have any open incident auto-resolved on the next run.

## Test

```bash
# Unit-test the decision logic (no network needed):
bash test-headscale-zombie-detector.sh

# Read-only classification on the host (real pings, no incidents, no state write):
sudo DRY_RUN=1 \
  MONITORED_NODES="web phenix headscale db sage-amg sage-iai sage-server amg-bjx iai-bjx tailscale-router-b asterisk-pbx asterisk-pbx-nyc3 amg-blog youtrack" \
  /opt/headscale-zombie-detector/headscale-zombie-detector.sh
```

Expect each monitored node printed as `REACHABLE -> ok`, `UNREACHABLE -> suspect`,
`offline -> skip`, or `ABSENT`. A normally-running fleet shows everything `ok`
or `skip`. Then run once for real
(`sudo systemctl start headscale-zombie-detector.service`) and check
`journalctl -t headscale-zombie`.

## How it decides

Per run, for each monitored node: `online=false` -> reset (powered off is the
heartbeat's job, not this detector's); `online=true` + reachable -> reset /
resolve; `online=true` + unreachable for `FAILS_THRESHOLD` (2) consecutive runs
-> open incident. Safety valve: if some monitored nodes are online but **none**
are reachable, the run assumes the host's own tailscale/DERP path is broken and
does nothing.
