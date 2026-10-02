# Sage 100: moving the Sage server from UTC to Eastern time

_last verified: 2026-09-20 (change carried out Sun 2026-09-20, about 9:15 to 9:40 PM Eastern)_

**Status: done.** The server has been on Eastern time with `SAGE_TZ` set
since 2026-09-20. The pre-change AMI is `sage-host-pre-eastern-tz-2026-09-20`.
The procedure is kept for reference and for rollback.

Since the Aug 29, 2026 cutover the Sage server has run on UTC. The old
server was on Eastern. Sage 100 Advanced and every user session run on
the same host, so everyone sees UTC. Anything entered after 8 PM Eastern
(7 PM in winter) gets the next day's date: the default accounting date,
invoice and payment dates, and `DateCreated`/`TimeCreated`/`DateUpdated`/
`TimeUpdated`. Accounting reported it on 2026-09-17 in #accounting-it.

Fix it by changing the whole server's time zone. Don't use RDP time zone
redirection or the Guacamole `timezone` connection parameter. Server-side
processes (the PVX service and the sync) would still use UTC, and sessions
that connect without redirection would too. You'd get mixed time zones in
the same tables.

## What depends on the server clock

- **sage-gql sync (the one that matters).** It reads Sage's local date/time
  stamps and converts them to UTC with the `SAGE_TZ` setting
  (`libs/providers/src/pvx/pvx.ts`), which defaults to `UTC`. Incremental
  sync only picks up records created after the last synced object
  (`apps/sync/src/sync.service.ts`, `getSyncIntervals`). If the server
  changes to Eastern while `SAGE_TZ` is still unset, new records look 4
  hours old and records from the first ~4 hours are skipped for good. **Set
  `SAGE_TZ` in the same maintenance window, before the stack restarts.**
- The sync's own schedule is pinned to `timeZone: 'UTC'`, so it isn't affected.
- `AG Tailscale Watchdog` is scheduled with an explicit `+00:00` offset, so it isn't affected.
- Vector, the SSM agent, and AWS maintenance windows use UTC internally, so they aren't affected.
- Records written between Aug 29 and the change keep their UTC stamps. The
  sync doesn't re-read them in normal running. A full re-sync would read
  them 4 hours late.

## How the sync stack starts

The `sage-sync` user logs on automatically (`AutoAdminLogon=1`). The
at-logon task `SageSyncStack` then runs `C:\sage-gql\start-sage.ps1`, which
starts gql/feeds/cron under PM2 and the sync apps under `run-sync.cjs`. Both
read their environment from `C:\sage-gql\.env.<division>` for each of `ad1`,
`ad4`, `ad5`, `amc` and `iai`. A reboot restarts the whole stack.

## Procedure

Do this after hours with nobody in Sage. Tell #accounting-it beforehand
(done 2026-09-17) and ask everyone to log out.

1. **Check who is logged on.** Run `quser` on the server. Only `sage-sync`
   should be left. Log off stragglers (`logoff <id>`). Anything they haven't
   saved is lost.
2. **Take an AMI snapshot** of the Sage server.
3. **Set `SAGE_TZ` for every division.** On the server, append a line to
   each env file. Do not rewrite the files, because they hold credentials:

       'ad1','ad4','ad5','amc','iai' | ForEach-Object {
         $f = "C:\sage-gql\.env.$_"
         if (-not (Select-String -Path $f -Pattern '^SAGE_TZ=' -Quiet)) {
           Add-Content -Path $f -Value 'SAGE_TZ="America/New_York"' -Encoding ascii
         }
       }
       Select-String -Path C:\sage-gql\.env.* -Pattern '^SAGE_TZ='

   Check first that each file ends with a newline, or `Add-Content` will
   join the new line onto the last key.

   **The quotes are required.** The env files have CRLF line endings, and
   both launchers (`run-sync.cjs` and `ecosystem.config.js`) split them on
   `\n`, so an unquoted value reaches the apps with a trailing carriage
   return. Their regex drops it only when the value is quoted. On
   2026-09-20 the unquoted form gave the sync apps `America/New_York\r`.
   date-fns-tz turned that into `Invalid Date`, and every sync app died on
   its first cycle and was respawned every five minutes until the line was
   quoted. The default `UTC` never showed this because it doesn't come from
   the file.
4. **Change the time zone:**

       Set-TimeZone -Id 'Eastern Standard Time'
       tzutil /g        # Eastern Standard Time

   `Eastern Standard Time` is the Windows ID for US Eastern. It includes
   daylight saving time.
5. **Reboot** (`Restart-Computer -Force`). The PVX service, the Erisana
   services and node only read the time zone when they start.
6. **Verify after the reboot:**
   - `tzutil /g` shows `Eastern Standard Time`, and `Get-Date` shows Eastern
     wall-clock time.
   - `quser` shows `sage-sync` on the console, and port 4001 is listening
     (`Get-NetTCPConnection -LocalPort 4001 -State Listen`).
   - Each division's sync log (`C:\sage-gql\sync-<div>.out.log`) prints
     `Sage: serverZone=America/New_York` at startup. That line alone is not
     enough, because it looks the same with a trailing carriage return. Wait
     for the first five-minute cycle and check that `firstObj` and `lastObj`
     are real dates, not `Invalid Date`, and that the process ID stays the
     same from one cycle to the next. A few `ECONNREFUSED ... bootstrap
     failed` lines in `sync-<div>.err.log` right after boot are normal: the
     sync apps retry until gql is up.
   - The Better Stack heartbeats for each division check in within 10
     minutes.
   - Log in through Guacamole, open Sage and confirm the accounting date is
     today in Eastern time.
   - Create a test customer or sales order, and within one sync cycle confirm
     it reaches the CRM with the right creation time.
7. Post completion in #accounting-it.

## Rollback

Run `Set-TimeZone -Id 'UTC'`, remove the `SAGE_TZ=` line from each
`.env.<division>`, then reboot. Records created while the server was on
Eastern keep Eastern stamps, and the sync will skip them the same way in
reverse. Roll back only if the change itself breaks something, and check
the CRM for gaps afterwards.

## Known leftovers

- Evening entries between Aug 29 and the change may be dated a day late.
  The one that matters is Aug 31 after 8 PM Eastern, which shows as Sep 1
  (month-end totals and commissions). Accounting was told on 2026-09-17.
- Each November, when clocks fall back, 1:00 to 2:00 AM repeats. Records
  created in that hour can confuse the sync's cutoff. Nobody works then, so
  nothing is done about it.
