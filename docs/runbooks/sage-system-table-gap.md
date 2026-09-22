# Sage 100: restoring system tables lost at the Aug 29 cutover (AG-806)

_last verified: 2026-09-22_

> Status: the tax code and class line merge was applied to the live server on
> 2026-09-22 and verified clean. The Visual Integrator job copy is still
> outstanding. The rest of `MAS_System` (roles, forms, users) is untouched.

The Aug 29, 2026 cutover re-migrated company folders but not `MAS_System`
(the shared setup tables), which still date from the June 17 trial
migration. Sales tax codes, tax-class lines, and Visual Integrator jobs
changed on the old server between June 16 and Aug 28 are missing on the new
server. The Aug 28 copy is at `C:\sage-migrate\extract\MAS90` on the Sage
server. Root cause and the diff numbers are on Linear AG-806; the design is
in `it-admin-docs/specs/2026-09-04-sage-taxcode-merge-design.md`.

Everything below runs on the Sage server over SSH as a Sage user with
Unified Login. No scheduled task is needed. (The Task Scheduler on that host
hung from 2026-09-04 until the 2026-09-20 reboot cleared it; this procedure
never depended on it.)

The tax code half writes through the Business Object Interface, which honours
Sage's own record locking, so it does not need a quiet window and was run with
users working normally. The Visual Integrator half copies files directly and
does need one.

## Tax codes and class lines

1. Copy `scripts/sage-taxcode-lib.ps1`, `scripts/sage-taxcode-dump.ps1`, and
   `scripts/sage-taxcode-apply.ps1` into one directory on the server
   (`scp -O`, see the mem0 note on scp and these hosts).
2. Dump both sides:

       powershell -NoProfile -ExecutionPolicy Bypass -File sage-taxcode-dump.ps1 -Source snapshot | Out-File -Encoding ascii snapshot.tsv
       powershell -NoProfile -ExecutionPolicy Bypass -File sage-taxcode-dump.ps1 -Source live | Out-File -Encoding ascii live.tsv

   Use `Out-File -Encoding ascii`, not `>`: under Windows PowerShell 5.1 the
   redirection writes UTF-16, which the diff cannot read.

3. Copy the two TSVs back and build the plan:

       bin/sage-taxcode-diff snapshot.tsv live.tsv --out plan.json

   Read the summary. `changed headers (NOT planned)` must be `none`; if not,
   decide each one by hand in Sales Tax Code Maintenance and re-dump.
   `update lines` should be the freight pattern (class TF in AZ, CA, FL, IL,
   MA, MO going to 0% / N) plus a handful of GA, NC, WA rate updates.
4. Back up the two tables before writing. An AMI snapshot of the Sage server
   is the broadest option. To copy just the two files aside, use a shadow
   copy: the live files are held open by `pvxiosvr`, and `robocopy /b` fails
   against them (exit 8) even from an elevated session, so backup mode is not
   enough on its own.

       $sc = ([WMICLASS]'root\cimv2:Win32_ShadowCopy').Create('C:\','ClientAccessible')
       $s = Get-CimInstance Win32_ShadowCopy | Where-Object { $_.ID -eq $sc.ShadowID }
       cmd /c mklink /d $env:TEMP\sageshadow ($s.DeviceObject + '\')
       # copy SY_SalesTaxCode.M4T and SY_SalesTaxCodeDetail.M4T from
       # $env:TEMP\sageshadow\Sage\Sage 100\MAS90\MAS_System, then:
       cmd /c rmdir $env:TEMP\sageshadow
       $s | Remove-CimInstance

   Record the MD5 of each copied file, and remember to release the shadow
   copy. Keep the `live.tsv` dump from step 2 as well: it is a complete
   logical record of both tables and is enough to reconstruct any single row.
5. Copy `plan.json` to the server, then in order:

       powershell -NoProfile -ExecutionPolicy Bypass -File sage-taxcode-apply.ps1 -SelfTest
       powershell -NoProfile -ExecutionPolicy Bypass -File sage-taxcode-apply.ps1 -Plan plan.json
       powershell -NoProfile -ExecutionPolicy Bypass -File sage-taxcode-apply.ps1 -Plan plan.json -Apply

   The self test writes, reads back, and deletes `ZZ AG806 SPIKE`. The dry
   run prints every intended write. Apply stops at the first verification
   mismatch (exit 3) and logs to
   `C:\ProgramData\ag-admin\sage-taxcode-apply.log`.

   Creating a tax code header makes Sage auto-generate that code's class
   lines, one per `SY_SalesTaxClass` row, carrying default values. The apply
   therefore finds those rows already present and overwrites them with the
   planned values; the summary counts them as added. Do not read
   `nSetKey=1` in the log as a problem. Until 2026-09-22 the script skipped
   those rows instead of writing them, which left 71 lines at rate 0 on 44
   new codes and still exited 0, so on any older copy of the script run the
   apply, re-diff, and apply the new plan as well.
6. Dump live again, re-run the diff, and expect `headers: add 0` and
   `lines: add 0, update 0`. Treat this as the real proof the run worked:
   the apply reporting success is not sufficient on its own. Then ask the
   tax code owner to spot check one restored code (TX BELL COUNTY) and one
   freight line (any CA code, class TF, 0% and not taxable).

   `live-only` headers and lines are expected and are left alone: they are
   tax codes added on the new server since the cutover.

## Visual Integrator jobs

There is no business object for job definitions, so the four VI files are
copied during a maintenance window. This is safe only while the live VI
tables have not changed since June: the diff summary must show
`VI jobs only on live (would be DESTROYED by a file copy): none`; if it
names any job, stop, because the wholesale copy would delete that job, and
re-create the missing jobs by hand instead.

1. Announce the window; everyone out of Sage; stop the Sage 100 services
   (Sage 100 Advanced application server and `pvxiosvr`).
2. In `C:\Sage\Sage 100\MAS90\MAS_System`, rename each of
   `VI_JobHeader.M4T`, `VI_JobImportElements.M4T`,
   `VI_JobExportElements.M4T`, `VI_JobExportSelection.M4T` to
   `<name>.pre-ag806`, then copy the same four files from
   `C:\sage-migrate\extract\MAS90\MAS_System`.
3. Start the services, re-run the dump and diff, and expect
   `VI jobs missing: 0`.
4. Have the job owner open one restored job in Visual Integrator. Import
   file paths inside the jobs still point at her old desktop; she re-browses
   them on first use, as before.

## Still missing from the same root cause

Roles and task menus, paperless office forms, company and system options,
and the user list also changed in the window. Each is a separate job; the
list is on AG-806.
