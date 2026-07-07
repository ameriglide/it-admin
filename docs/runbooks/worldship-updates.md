# WorldShip update monitoring

UPS WorldShip stations apply two kinds of updates, both interactive:

- **Object distribution** (delta patches): downloaded by WSUpdater
  (`WorldShipCF.exe`), applied by `runpatch.exe`/`PatchUPS.exe` when the app
  exits. The patcher exes have no `requestedExecutionLevel` manifest, so UAC
  installer detection forces an elevation prompt. A standard user cannot apply
  them (`ShellExecute returned a status of 5` in the syslog). **Shipping
  station users are therefore local admins** (fleet convention).
- **Full installers**: ~1 GB `WSxx_x_xxx_x_ENU.exe` in
  `C:\ProgramData\UPS\WSTD\Autodownload`, offered by WorldShip at launch.
  Also requires elevation.

Updates cannot be force-pushed as SYSTEM (they run inside the user's WorldShip
session), so we monitor instead of auto-remediating.

## How the monitoring works

Each station runs the `AG WorldShip Monitor` scheduled task (SYSTEM, daily
07:00 local) -> `%ProgramData%\ag-admin\worldship-monitor.ps1`, which:

1. reads the `WorldShipTD.exe` file version,
2. scans `C:\ProgramData\UPS\WSTD\Syslog\*.log` (last `lookbackDays`, default
   3) and determines whether the **latest** update attempt failed,
3. POSTs to the station's Better Stack heartbeat `worldship-<station>`:
   clean ping with `version=...` in the body, or `<url>/fail` with
   `version=... error=<syslog line>`.

Heartbeats: period 24 h, grace 6 h, escalation policy 114897. A failure that
lands mid-scan is reported by the next daily run (detection latency up to
24 h).

## Alerts and what to do

| Alert | Meaning | Response |
|---|---|---|
| `/fail` ping incident | Latest update attempt failed on the station | Read the incident body (version + error). Usual cause: UAC prompt declined or user lacks admin. Have the station user relaunch WorldShip and accept the UAC prompt; verify the user is in the local `Administrators` group. |
| Missed heartbeat (dark) | Box off/network down, task broken, or script deleted | Check the box (SSM/Action1/TeamViewer). `Get-ScheduledTask 'AG WorldShip Monitor'` and `%ProgramData%\ag-admin\worldship-monitor.log`. |
| Version drift across stations | Visible in heartbeat bodies | Not alerted by itself; if one station lags for weeks, check for recurring `/fail` pings. |

## Install / update on a station

`bin/copy` -> "Server monitoring — install WorldShip update monitor on a
shipping station..." emits the one-liner (needs `WORLDSHIP_STATIONS` and
`BETTERSTACK_UPTIME_TOKEN` in `.env`). Run it in an elevated PowerShell on the
station, or via SSM send-command as SYSTEM. Re-running is idempotent (reuses
the heartbeat, re-registers the task).

## Station notes

- Station list lives in `.env` (`WORLDSHIP_STATIONS`), not in this public repo.
- If a station is unreachable at rollout time (agent down, box off), you can
  pre-create its heartbeat via the Uptime API with `"paused": true` so it does
  not raise a dark-station incident before the monitor is installed. Running
  the installer once the station is reachable unpauses the heartbeat
  automatically.
