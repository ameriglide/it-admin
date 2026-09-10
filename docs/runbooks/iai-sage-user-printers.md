# Per-user printers for IAI users on the Sage portal

_last verified: 2026-09-09_

IAI moved off remote desktop to the Guacamole portal. Sage now runs on a shared
RDS session host, so **anything installed server-wide is visible to all IAI
users**. When one person needs their own locally attached printer inside Sage,
it stays on their workstation and is shared to exactly one account.

Inventory (who has a local printer, which workstation, which account) is **not
in this repo** -- it is host inventory and this repo is public. It lives in
`ameriglide/it-admin-docs`.

## The rule that makes this work

The printer connection must be created **by the user, inside their own Sage
desktop, authenticating with their workstation credentials**. That is what
writes the per-user credential and the per-user printer connection under their
`HKCU`.

**Do not** use a server-wide printer install or `rundll32 printui.dll,PrintUIEntry`
over SSM. Those run as the Sage-side account, write to `HKLM`, and hand the
printer to every Sage user -- with no visible prompt telling you it happened.

## Know which account name to use

This is the step that most often fails. IAI workstations are a **mix**:

- Domain-joined boxes authenticate as `<AD-DOMAIN>\<user>`.
- Workgroup boxes -- the majority -- have only a **local** account. The
  qualifier is the computer name, not the domain: `WORKSTATION01\jdoe`. The
  domain-qualified form does not exist on those machines at all, so the
  connection in step 6 simply refuses and the step-3 Print ACE cannot be
  created either.

Do not assume the domain form. Local usernames are also irregular -- expect
truncations, and expect spaces inside some of them. Check the real value on
each machine before you start:

```powershell
# on the workstation
(Get-WmiObject Win32_ComputerSystem).UserName    # DOMAIN\user or COMPUTERNAME\user
Get-LocalUser | Where-Object Enabled             # local accounts, if workgroup
```

`share-user-printer.ps1` resolves the name to a SID up front and fails loudly
with the list of valid local accounts rather than creating a share nobody can
reach.

## Step 0: prove the printer actually prints, BEFORE anything else

Run this on the workstation and confirm a sheet comes out:

```powershell
(Get-WmiObject Win32_Printer -Filter "Name='<printer>'").PrintTestPage()
```

Do not skip it and do not infer it from the printer looking healthy. The first
real rollout burned most of a day diagnosing share permissions on a printer that
could not print from its own PC and had not since the previous October. Windows
reported it `Normal`, `DetectedErrorState 0`, `WorkOffline False` throughout.

Two things that produce "job disappears, no paper, no error":

* **A generic class driver.** `Brother Laser Type1 Class Driver`, `HP Color
  LaserJet ... Class Driver` and friends accept jobs and render nothing. Install
  the vendor's model-specific driver. `Set-Printer -DriverName` refuses to swap
  a driver (`0x80070032 ERROR_NOT_SUPPORTED`) -- use `Remove-Printer` then
  `Add-Printer`, then **reboot**, which is what finally made it print.
* **`WorkOffline = True`.** Check with
  `Get-CimInstance Win32_Printer | Select Name,WorkOffline,PrinterStatus,Default`.
  If `Get-PnpDevice` shows the printer `Unknown` rather than `OK`, it is simply
  off or unplugged -- no amount of software work will help.

Also confirm which printer object the user really prints through (`Default`).
Machines often carry two objects for the same USB device, one on a good driver
and one on a class driver.

## Steps 1-4: on the workstation (scripted)

Run elevated on the user's own workstation. `-AllowFrom` is the Sage host's
tailnet address; it is a parameter because this repo must not carry tailnet IPs.

```powershell
.\share-user-printer.ps1 -AllowFrom <sage-tailnet-ip>
```

Add `-WhatIfOnly` first to see the plan. Override the guesses when needed:

```powershell
.\share-user-printer.ps1 -PrinterName "HP LaserJet 400" -ShareName Jane_HP `
    -AccountName WORKSTATION01\jdoe -AllowFrom <sage-tailnet-ip>
```

It confirms the spooler and printer are healthy, reports the workstation's
tailnet IP, shares the printer under a distinct name, rewrites the printer DACL
to grant Print to that one account (stripping Everyone, Authenticated Users,
Users, INTERACTIVE and the app-container SIDs, while preserving Administrators,
SYSTEM and CREATOR OWNER), and scopes inbound TCP 445 to the tailnet.

By default it also disables the broad `File and Printer Sharing (SMB-In)` rules
so the LAN and Public profiles cannot reach 445. If the user still needs LAN
file sharing, pass `-KeepLanSmb`. To revert:

```powershell
Get-NetFirewallRule -DisplayName 'File and Printer Sharing*SMB-In*' | Enable-NetFirewallRule
```

The script ends with a verdict and the exact per-user instructions. It never
reboots or removes the printer.

## Step 5: from the Sage host

```powershell
Test-NetConnection <workstation-tailnet-ip> -Port 445
```

`TcpTestSucceeded : True` is required before going further. If it fails, check
that Tailscale is up on the workstation and that the workstation is awake --
see "What breaks this later" below.

## Step 5b: pre-install the printer's driver ON THE SAGE HOST

**Required. The user's connect fails without it**, with the useless dialog
"Windows cannot connect to the printer. No printers were found."

Non-admins cannot install a driver from a remote print server (the
post-PrintNightmare default), and the driver cannot be made to transfer from the
workstation by any route: unelevated gives `0x800702e4 ERROR_ELEVATION_REQUIRED`,
elevated gives `0x80070005 ERROR_ACCESS_DENIED` even after `net use \\<ws>\IPC$`
authenticates successfully in the same window. Stop trying to pull it across --
put it on the Sage host directly.

On the Sage host, elevated:

```powershell
pnputil /add-driver "C:\<extracted-driver-folder>\*.inf" /subdirs /install
Add-PrinterDriver -Name "<exact driver name from the workstation>"
Get-PrinterDriver | findstr /i <vendor>
```

You do not need an RDP session for this. The Sage host is an SSM-managed EC2
instance, so `bin/ssm-ps` runs it from your Mac (find the instance id with
`./bin/ssm-ps --list`). Fetch the vendor package straight onto the host and
unpack it with the standalone 7-Zip console rather than running the vendor
installer, which wants a desktop:

```bash
./bin/ssm-ps <sage-instance-id> '$d="C:\Temp\drv"; New-Item -ItemType Directory -Force $d | Out-Null;
  [Net.ServicePointManager]::SecurityProtocol="Tls12";
  Invoke-WebRequest "<vendor package url>" -OutFile "$d\pkg.exe" -UseBasicParsing;
  Invoke-WebRequest "https://www.7-zip.org/a/7zr.exe" -OutFile "$d\7zr.exe" -UseBasicParsing;
  & "$d\7zr.exe" x "$d\pkg.exe" -o"$d\x" -y | Select-Object -Last 2;
  Get-ChildItem "$d\x" -Recurse -Filter *.inf | Select-Object -ExpandProperty FullName'
```

Then read the candidate INFs before installing one. **Do not trust the file
name or the "PCL" suffix to tell you v3 from v4**: in HP's OfficeJet Pro 7740
package the v3 driver is the bare `HP OfficeJet Pro 7740 series` and the v4
one is `... series PCL-3` -- the reverse of what the names suggest. Match the
workstation's `Get-PrinterDriver` `Name` **and** `MajorVersion` to the INF's
model string and driver type, then:

```bash
./bin/ssm-ps <sage-instance-id> 'pnputil /add-driver "C:\Temp\drv\x\<chosen>.inf" /install;
  Add-PrinterDriver -Name "<exact driver name from the workstation>";
  Get-PrinterDriver | Where-Object Name -like "*<model>*" | Select-Object Name,MajorVersion'
```

The workstation is usually SSM-managed too, so the version check that decides
this (`Get-PrinterDriver -Name "<driver>" | Select-Object Name,MajorVersion`)
can be run the same way with its `mi-...` id.

`Add-PrinterDriver` is **not** optional -- `pnputil` (or the vendor's `dpinst`)
stages the package but leaves `Get-PrinterDriver` empty on its own.

The name must match the workstation's `DriverName` exactly, and the driver
type must match too: check `MajorVersion` on the workstation and install the
same -- v3 for the three Brother/LaserJet users, v4 for the HP OfficeJet Pro
7740, and both connected first time once the host had the matching one.
Prefer a "no installer" download so there is no wizard demanding attached
hardware.

Do every printer in one sitting rather than per user.

**Diagnosing this step:** never trust the GUI dialog. Use
`Add-Printer -ConnectionName \\<ws-ip>\<share>` instead -- it returns a real
HRESULT. `Get-SmbSession` on the workstation shows whether the user's Sage
session ever arrived at all, which separates a connection problem from a driver
one.

## Steps 6-7: the user, in their own Sage desktop

**The order below is the whole fix. Do not reorder it.**

Have them log into Sage through the Guacamole portal, then **in that session**:

1. **Sign out of Windows fully.** Start -> user icon -> **Sign out**. Closing
   the browser tab or disconnecting is not enough. If the sign-out hangs for
   more than a couple of minutes, reload the Guacamole tab first (it often
   freezes on the last frame); if it is genuinely stuck, `logoff <id>` the
   session from an admin session on the Sage host.
2. Sign back in through Guacamole. **Do not touch anything printer-related
   yet** -- no `Win + R`, no Settings, no printer dialog.
3. First thing, save the credential:

   ```
   cmdkey /add:<workstation-tailnet-ip> /user:WORKSTATION01\jdoe /pass
   ```

   It prompts for the workstation account's password; nothing goes on the
   command line.
4. Then connect:

   ```
   rundll32 printui.dll,PrintUIEntry /in /n \\<workstation-tailnet-ip>\<share-name>
   ```

   **Run this once.** If it prompts for a password or errors, stop and read
   the error -- do not retry (see the lockout note below).
5. Verify:

   ```
   Get-Printer | Select-Object Name,Type,ComputerName
   ```

   The connection appears as `\\<workstation-tailnet-ip>\<printer-name>` with
   Type `Connection`. Windows labels it with the printer's own name, not the
   share name; that is normal.

Then confirm it appears in Sage's print dialog for that user, and that a
**different** Sage user neither sees it in `Get-Printer` nor can open the
share.

### Why the order matters (Win32 error 1219)

The obvious way -- `Win + R` to the UNC path, then type the credentials when
asked -- fails on this fleet, silently at first and then with an endless loop
of "credentials conflict with an existing set of credentials / the existing
set cannot be deleted". Nothing in `cmdkey /list` or `net use` shows the
conflicting credential, because there is none.

What actually happens: the redirector first tries the share as the user's
implicit Sage identity (`SAGE\<user>`), which does not exist on the
workstation. The failed attempt leaves a half-open connection to the
workstation inside the logon session. Supplying the real workstation account
is then a second identity to the same server from one session, which Windows
refuses with `ERROR_SESSION_CREDENTIAL_CONFLICT` (1219). `printui` tries to
tear down the existing connection, cannot address an implicit one, and loops.

The sign-out is the only thing that clears the half-open connection. Saving
the credential with `cmdkey` **before** the first contact makes the redirector
use the workstation account from the first packet, so the Sage identity is
never tried and no conflict forms. A user who happened to get a credential
saved during earlier failed attempts will connect without any of this -- which
is why one user "just worked" and the rest did not.

### The lockout trap (error 0x775)

`Operation failed with error 0x00000775` from `printui` is
`ERROR_ACCOUNT_LOCKED_OUT`. The workstation account is locked; no password will
work until it is unlocked, so every retry is wasted and re-arms the lockout.

Windows 11 22H2+ locks a local account after 10 bad passwords in 10 minutes by
default, and a **saved** credential with a wrong password is retried several
times per connection attempt -- one `printui` run can trip it. On the
workstation, elevated:

```powershell
net user jdoe                       # "Account active   Locked" confirms it
$u=[ADSI]'WinNT://./jdoe,user'; $u.IsAccountLocked=$false; $u.SetInfo()
net user jdoe *                     # reset to a known password; prompts twice
net user jdoe /passwordreq:yes      # blank passwords cannot log on over the network
```

Then delete the bad saved credential in the Sage session
(`cmdkey /delete:<workstation-tailnet-ip>`) and restart from step 1 of this
section with the new password.

## What breaks this later

- **The workstation sleeps or is powered off.** The share is only reachable
  while the machine is awake on the tailnet. Printing fails at the moment of
  use, not at setup. Laptops are the usual offender.
- **The workstation account's password changes.** The credential saved in
  step 6 goes stale and printing starts failing with a credential prompt buried
  in the Sage session. Re-run step 6 from the sign-out; no workstation change
  is needed. Note that a stale saved credential is retried automatically and
  will lock the workstation account within minutes -- check for the lockout
  before assuming the password is wrong.
- **Tailscale restarts and the IP changes.** Rare with a stable tailnet, but the
  share is addressed by IP, so the stored connection breaks. Re-run step 6 with
  the new address.
