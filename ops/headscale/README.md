# Headscale zombie-node detector

Flags nodes that are `online=true` in Headscale but whose `last_seen` is stale
(> 15 min) -- the signature of a half-closed Tailscale control connection -- and
raises a Better Stack incident per node, auto-resolving on recovery. This is the
backstop for nodes the per-node watchdog has not reached (e.g. the workstation
fleet) and for the watchdog itself failing.

## Install (on the Headscale host)

```bash
sudo mkdir -p /opt/headscale-zombie-detector
sudo cp headscale-zombie-detector.sh /opt/headscale-zombie-detector/
sudo chmod +x /opt/headscale-zombie-detector/headscale-zombie-detector.sh
sudo cp headscale-zombie-detector.service headscale-zombie-detector.timer /etc/systemd/system/

# Secrets / config (not committed):
sudo tee /etc/headscale-zombie-detector.env >/dev/null <<'EOF'
BETTERSTACK_API_TOKEN=...
REQUESTER_EMAIL=it@ameriglide.com
STALE_SECONDS=900
HEADSCALE_CONTAINER=headscale
EOF
sudo chmod 600 /etc/headscale-zombie-detector.env

sudo systemctl daemon-reload
sudo systemctl enable --now headscale-zombie-detector.timer
```

## Test

```bash
# Dry run with a low threshold so a normally-idle node trips: should print
# DRYRUN incident ids, open no real incidents, and leave state untouched.
sudo DRY_RUN=1 STALE_SECONDS=60 \
  BETTERSTACK_API_TOKEN=x \
  /opt/headscale-zombie-detector/headscale-zombie-detector.sh
```

Confirm a powered-off node (`online=false`) is NOT listed. Then run once for real
(`sudo systemctl start headscale-zombie-detector.service`) and check
`journalctl -t headscale-zombie`.
