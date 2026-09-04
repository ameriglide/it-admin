# Sage 100: restoring system tables lost at the Aug 29 cutover (AG-806)

_last verified: 2026-09-04_

The Aug 29, 2026 cutover re-migrated company folders but not `MAS_System`
(the shared setup tables), which still date from the June 17 trial
migration. Sales tax codes, tax-class lines, and Visual Integrator jobs
changed on the old server between June 16 and Aug 28 are missing on the new
server. The Aug 28 copy is at `C:\sage-migrate\extract\MAS90` on the Sage
server. Root cause and the diff numbers are on Linear AG-806; the design is
in `it-admin-docs/specs/2026-09-04-sage-taxcode-merge-design.md`.

Everything below runs on the Sage server over SSH as a Sage user with
Unified Login. No scheduled task is needed, and as of 2026-09-04 the Task
Scheduler on that host hangs anyway.

## Tax codes and class lines

1. Copy `scripts/sage-taxcode-lib.ps1`, `scripts/sage-taxcode-dump.ps1`, and
   `scripts/sage-taxcode-apply.ps1` into one directory on the server
   (`scp -O`, see the mem0 note on scp and these hosts).
2. Dump both sides:

       powershell -NoProfile -ExecutionPolicy Bypass -File sage-taxcode-dump.ps1 -Source snapshot > snapshot.tsv
       powershell -NoProfile -ExecutionPolicy Bypass -File sage-taxcode-dump.ps1 -Source live > live.tsv

3. Copy the two TSVs back and build the plan:

       bin/sage-taxcode-diff snapshot.tsv live.tsv --out plan.json

   Read the summary. `changed headers (NOT planned)` must be `none`; if not,
   decide each one by hand in Sales Tax Code Maintenance and re-dump.
   `update lines` should be the freight pattern (class TF in AZ, CA, FL, IL,
   MA, MO going to 0% / N) plus a handful of GA, NC, WA rate updates.
4. Take an AMI snapshot of the Sage server (or copy
   `MAS_System\SY_SalesTaxCode.M4T` and `SY_SalesTaxCodeDetail.M4T` aside
   with backup semantics) before writing.
5. Copy `plan.json` to the server, then in order:

       powershell -NoProfile -ExecutionPolicy Bypass -File sage-taxcode-apply.ps1 -SelfTest
       powershell -NoProfile -ExecutionPolicy Bypass -File sage-taxcode-apply.ps1 -Plan plan.json
       powershell -NoProfile -ExecutionPolicy Bypass -File sage-taxcode-apply.ps1 -Plan plan.json -Apply

   The self test writes, reads back, and deletes `ZZ AG806 SPIKE`. The dry
   run prints every intended write. Apply stops at the first verification
   mismatch (exit 3) and logs to
   `C:\ProgramData\ag-admin\sage-taxcode-apply.log`.
6. Dump live again, re-run the diff, and expect `headers: add 0` and
   `lines: add 0, update 0`. Then ask the tax code owner to spot check one
   restored code (TX BELL COUNTY) and one freight line (any CA code, class
   TF, 0% and not taxable).

## Visual Integrator jobs

There is no business object for job definitions, so the four VI files are
copied during a maintenance window. This is safe only while the live VI
tables have not changed since June: the diff summary's `VI jobs missing`
list must show snapshot-only jobs and nothing else (no `live only`,
no `changed`).

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
