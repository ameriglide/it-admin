# guacd leak reaper

Kills **leaked guacd connection children** on the Guacamole portal host --
forked children whose RDP connection died but which never tore down, and now
spin on the dead socket burning 25-100% of a core each, forever.

## Why

When enough of them accumulate the portal runs out of CPU, and the failure does
not look like a portal problem at all -- it looks like Windows being broken:

1. guacd children leak, each pinning most of a core.
2. The host saturates. New RDP connections cannot be serviced in time.
3. Connections abort. Windows logs `TCP socket WRITE operation failed, error
   1236` (`ERROR_CONNECTION_ABORTED`) in
   `Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational`.
4. Guacamole retries. Each retry opens a *new* RDP session that session
   arbitration folds back into the user's existing one, so
   `TerminalServices-LocalSessionManager/Operational` fills with
   `Begin session arbitration` / `Session reconnection succeeded` /
   `Session has been disconnected` cycles.
5. The user sits on the Windows "Welcome" spinner, getting a few seconds of
   desktop at a time. It looks like their profile or their account is broken.

Observed 2026-09-01 on sage-portal: six leaked children, about **5 cores of
demand on a 4-core box**, load average 7.93, **0.0% idle**. One user was stuck
flapping for 16 minutes; seven others had been dropping all afternoon. Killing
the six restored the host to 98-99% idle and 4.5% total guacd CPU while serving
*more* sessions than before.

The leak itself is upstream guacd behaviour. This reaper does not fix it; it
keeps it from taking the portal down.

## What feeds the leak: resize-method

Every teardown is a chance to leak, so what matters is how often connections are
torn down. All 47 connections were originally set to `resize-method=reconnect`,
which rebuilds the **entire RDP connection** on any browser resize -- including
the initial layout settle a few seconds after login:

```
19:13:59  Resize method: reconnect
19:13:59  User joined connection ... RDPDR user logged on
19:14:03  Internal RDP client disconnected      <- 4s later
19:14:04  RDPDR user logged on                  <- full rebuild
```

That produced a leak roughly every two minutes, and each rebuild also opened a
*new* RDP session on sage-host that session arbitration folded back into the
user's existing one -- filling
`TerminalServices-LocalSessionManager/Operational` with arbitration churn and
leaving users on the "Welcome" spinner.

Changed 2026-09-01 to `resize-method=display-update`, which resizes in place
over the RDP Display Update channel with no teardown (needs Windows Server
2012 R2+; sage-host is Server 2025):

```sql
update guacamole_connection_parameter
   set parameter_value = 'display-update'
 where parameter_name = 'resize-method';
```

It takes effect on each user's next connection; no service restart. Confirm with
`journalctl -u guacd | grep "Resize method"`. Keep this reaper installed
regardless -- `display-update` removes most teardowns, not the underlying guacd
bug.

## How it decides

Per run, for every child of the `guacd.service` MainPID:

| Condition | Action | Why |
|---|---|---|
| has an established connection to `RDP_PORT` | keep | serving a live session |
| younger than `MIN_AGE_SECS` (120) | keep | may still be handshaking |
| CPU below `CPU_THRESHOLD` (20%) | keep | idle orphan, harmless |
| otherwise | **reap** | spinning with no session |

CPU is a **live sample** from `/proc/<pid>/stat` jiffy deltas over
`SAMPLE_SECS`, not `ps` lifetime average -- a child that worked hard an hour ago
and then went idle must not look like a spinner.

Reaping is SIGTERM, then SIGKILL after `TERM_GRACE`. Every candidate is
re-verified immediately before the kill (still exists, still named `guacd`,
still a child of the master, still no RDP connection), because state can change
during sampling. The master PID is never a candidate.

**Safety valve.** If *every* child looks leaked, that is far more likely to mean
the RDP target host is unreachable than that every session leaked at once. The
run logs a warning, raises a Better Stack incident if a token is configured, and
still reaps no more than `MAX_REAP` (6) per run so the blast radius stays
bounded. Candidates are ordered by CPU, worst first, so the biggest offenders go
first and the rest are picked up on the next run.

## Install (on the portal host)

```bash
sudo mkdir -p /opt/guacd-leak-reaper
sudo cp guacd-leak-reaper.sh /opt/guacd-leak-reaper/
sudo chmod +x /opt/guacd-leak-reaper/guacd-leak-reaper.sh
sudo cp guacd-leak-reaper.service guacd-leak-reaper.timer /etc/systemd/system/

# Optional config/secrets (the unit tolerates the file being absent):
sudo tee /etc/guacd-leak-reaper.env >/dev/null <<'EOF'
CPU_THRESHOLD=20
MIN_AGE_SECS=120
MAX_REAP=6
BETTERSTACK_API_TOKEN=...
BETTERSTACK_POLICY_ID=114897
REQUESTER_EMAIL=it@ameriglide.com
EOF
sudo chmod 600 /etc/guacd-leak-reaper.env

sudo systemctl daemon-reload
sudo systemctl enable --now guacd-leak-reaper.timer
```

Without `BETTERSTACK_API_TOKEN` the reaper still reaps; it just does not raise
incidents.

## Test

```bash
# Unit-test the decision logic (no host needed, runs anywhere):
bash test-guacd-leak-reaper.sh

# Read-only classification on the portal (real sampling, kills nothing):
sudo DRY_RUN=1 /opt/guacd-leak-reaper/guacd-leak-reaper.sh
```

Expect one line per child, e.g.:

```
[DRY_RUN] pid=71781 age=986s cpu=0.2% rdp_conns=1 -> keep
[DRY_RUN] pid=69031 age=3540s cpu=57.6% rdp_conns=0 -> reap
```

A healthy portal shows every child as `keep`. Then run it for real
(`sudo systemctl start guacd-leak-reaper.service`) and check
`journalctl -t guacd-reaper`.

## Tuning

| Variable | Default | Notes |
|---|---|---|
| `CPU_THRESHOLD` | `20` | percent of one core; below this a childless orphan is left alone |
| `MIN_AGE_SECS` | `120` | grace period before a child is eligible |
| `SAMPLE_SECS` | `3` | CPU sampling window; the run takes roughly this times the child count |
| `MAX_REAP` | `6` | per-run blast-radius cap |
| `TERM_GRACE` | `5` | seconds between SIGTERM and SIGKILL |
| `RDP_PORT` | `3389` | connection port that marks a child as "in use" |
| `GUACD_SERVICE` | `guacd.service` | unit whose MainPID owns the children |
| `DRY_RUN` | `0` | `1` classifies and prints, kills nothing |
