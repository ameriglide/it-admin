# Per-user printers for IAI users on the Sage portal

_last verified: 2026-08-31_

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

## Steps 6-7: the user, in their own Sage desktop

Have them log into Sage through the Guacamole portal, then **in that session**:

1. `Win + R` -> `\\<workstation-tailnet-ip>\<share-name>`
2. Sign in as the account from above, with the password they use on their
   physical workstation.
3. Open the printer share, click **Connect**.

Then confirm it appears in Sage's print dialog for that user, and that a
**different** Sage user neither sees it in their print dialog nor can open the
share.

## What breaks this later

- **The workstation sleeps or is powered off.** The share is only reachable
  while the machine is awake on the tailnet. Printing fails at the moment of
  use, not at setup. Laptops are the usual offender.
- **The user changes their Windows password.** The credential Windows stored in
  step 6 goes stale and printing starts failing with a credential prompt buried
  in the Sage session. Re-run step 6; no workstation change is needed.
- **Tailscale restarts and the IP changes.** Rare with a stable tailnet, but the
  share is addressed by IP, so the stored connection breaks. Re-run step 6 with
  the new address.
