# share-user-printer.ps1
# Publish a workstation's locally attached printer as a SINGLE-USER share that
# the AWS Sage host reaches over the tailnet, so that one IAI person -- and only
# that person -- can add it inside their own Sage desktop.
#
# Context: IAI moved off remote desktop to the Guacamole portal. A Sage session
# runs on a shared RDS host, so anything installed server-wide is visible to all
# ~24 users. The only way to keep a printer private to one person is to leave it
# on their own workstation, share it with a DACL naming just them, and have them
# connect to it from inside their Sage session -- which is what stores the
# per-user credential and the per-user printer connection under their HKCU.
#
# This script does the WORKSTATION half (Michael's steps 1-4) and then prints
# the exact per-user instructions for steps 5-7, which must be done by the
# person themselves in their own Sage desktop. Do NOT substitute a server-side
# install or rundll32 PrintUIEntry over SSM: those run as the Sage-side account,
# land in HKLM, and give every Sage user the printer.
#
# NOTE on the firewall step: on this fleet, Windows Firewall inbound rules do
# not govern tailnet traffic -- Tailscale permits it below that layer, so 445
# stays reachable tailnet-wide no matter what this script adds. The single-user
# share DACL, not the firewall, is what keeps the printer private. Restricting
# who can reach 445 belongs in the tailnet ACL. Measured 2026-08-31.
#
# Run elevated ON the user's workstation. Idempotent. ASCII only.
#
#   .\share-user-printer.ps1 -AllowFrom <sage-tailnet-ip>
#   .\share-user-printer.ps1 -PrinterName "HP LaserJet" -ShareName Jane_HP `
#       -AccountName WORKSTATION01\jdoe -AllowFrom <sage-tailnet-ip>
#
[CmdletBinding()]
param(
    # Tailnet address(es) permitted to reach TCP 445 on this workstation --
    # normally just the Sage host. Never hardcoded: this repo is public.
    [Parameter(Mandatory)][string[]]$AllowFrom,

    # Printer to share. Auto-detected when there is exactly one candidate.
    [string]$PrinterName,

    # SMB share name. Defaults to <FirstName>_<Manufacturer>, e.g. Jane_HP.
    [string]$ShareName,

    # The principal granted Print, in DOMAIN\user or COMPUTERNAME\user form.
    # Defaults to the console user. On a workgroup box this MUST be the local
    # account (COMPUTERNAME\localuser), not the AD form -- see the runbook.
    [string]$AccountName,

    # Leave the broad LAN "File and Printer Sharing (SMB-In)" rules alone.
    [switch]$KeepLanSmb,

    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
$Script:Revision = "unreleased"

$verb   = if ($WhatIfOnly) { 'Would' } else { 'Did' }
$issues = [System.Collections.Generic.List[string]]::new()
function Note($m) { Write-Host "  $m" -ForegroundColor DarkGray }
function Good($m) { Write-Host "  $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  $m" -ForegroundColor Yellow; $issues.Add($m) | Out-Null }

if (-not ([Security.Principal.WindowsPrincipal] `
          [Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this elevated (Run as administrator)."
}

# ---------------------------------------------------------------- step 1: spooler
Write-Host "`n[1/5] Spooler and printer health" -ForegroundColor Cyan

$spooler = Get-Service -Name Spooler
if ($spooler.Status -ne 'Running') {
    Bad "Spooler is $($spooler.Status). Start it and re-run: Start-Service Spooler"
} else {
    Good "Spooler running (StartType $($spooler.StartType))."
}

# Virtual/redirected devices are never the answer here.
$virtual = 'Microsoft Print to PDF|Microsoft XPS|OneNote|Fax|PDFCreator|Adobe PDF'
# NOTE: always wrap Get-Printer / Get-PrintJob / Get-NetFirewallRule results in @().
# They return CimInstance objects, and a SINGLE CimInstance does not expose a
# usable .Count -- it resolves against the CIM property bag and yields $null. That
# made a one-printer machine fail both the -eq 1 and -eq 0 tests and fall through
# to the "too many printers" branch, printing an empty count. Found on the first
# real run, 2026-08-31.
if ($PrinterName) {
    $printer = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
    if (-not $printer) { throw "No printer named '$PrinterName'. Present: $((Get-Printer).Name -join '; ')" }
} else {
    # @() is required: a single CimInstance has no usable .Count (see note above).
    $localAll = @(Get-Printer | Where-Object { $_.Type -eq 'Local' -and $_.Name -notmatch $virtual })
    if ($localAll.Count -eq 1) {
        $printer = $localAll[0]
        Note "Auto-detected the only local printer: $($printer.Name)"
    } elseif ($localAll.Count -eq 0) {
        # The common case when someone was put on this list by mistake. Say so
        # plainly rather than making the operator infer it from an empty list.
        Write-Host ""
        Write-Host "NO LOCAL PRINTER ON THIS MACHINE." -ForegroundColor Yellow
        Write-Host "  Nothing to share. This user does not need a Sage printer share," -ForegroundColor Yellow
        Write-Host "  or their printer is a network printer that Sage should reach directly." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Printers Windows can see here (all types):" -ForegroundColor DarkGray
        $all = @(Get-Printer)
        if ($all) {
            $all | ForEach-Object {
                Write-Host "    $($_.Name)  [type=$($_.Type) port=$($_.PortName)]" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "    (none at all)" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "No changes were made. Nothing to revert." -ForegroundColor Green
        return
    } else {
        throw ("Found $($localAll.Count) local printers; cannot pick one. Re-run with " +
               "-PrinterName set to one of: " +
               (($localAll | ForEach-Object { "$($_.Name) [$($_.PortName)]" }) -join '; '))
    }
}

Note "Printer : $($printer.Name)"
Note "Driver  : $($printer.DriverName)"
Note "Port    : $($printer.PortName)"
if ($printer.PortName -notmatch '^(USB|DOT4)') {
    Note "Port is not USB/DOT4 -- confirm this is really the locally attached device."
}

$status = (Get-WmiObject Win32_Printer -Filter "Name='$($printer.Name -replace "'","''")'").PrinterStatus
# 3 = Idle, 4 = Printing, 5 = Warming up are all healthy.
if ($status -notin 3,4,5) { Bad "Printer status code $status (not idle/printing). Check power and cable." }
else { Good "Printer reachable (status $status)." }

$stuck = @(Get-PrintJob -PrinterName $printer.Name -ErrorAction SilentlyContinue)
if ($stuck.Count -gt 0) { Note "$($stuck.Count) job(s) in the queue." }

# ---------------------------------------------------------- step 1b: tailnet IP
Write-Host "`n[2/5] Tailscale address" -ForegroundColor Cyan

# Read the address off the adapter FIRST. `tailscale.exe ip` is owned by whichever
# user started the Tailscale client, and returns "401 Unauthorized: Tailscale
# already in use by <user>" to anyone else -- which is the normal case here, since
# this script runs elevated as a local admin while the client belongs to the
# console user. The adapter is readable regardless of who owns the client.
$tailscaleIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -like '100.*' -and $_.InterfaceAlias -match 'Tailscale' } |
    Select-Object -First 1 -ExpandProperty IPAddress)

if (-not $tailscaleIp) {
    # Fall back to the CLI, but never let its stderr become a terminating error --
    # $ErrorActionPreference is 'Stop' for this script and a NativeCommandError
    # would otherwise abort the whole run over a purely cosmetic value.
    $tsExe = "$env:ProgramFiles\Tailscale\tailscale.exe"
    if (Test-Path $tsExe) {
        try {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $out = & $tsExe ip -4 2>&1
            $ErrorActionPreference = $prev
            $tailscaleIp = ($out | Where-Object { "$_" -match '^\d{1,3}(\.\d{1,3}){3}$' } |
                            Select-Object -First 1)
        } catch {
            $ErrorActionPreference = 'Stop'
        }
    }
}
if ($tailscaleIp) {
    Good "Workstation tailnet IP: $tailscaleIp"
} else {
    # Not fatal: this value only decorates the closing instructions. Everything
    # that actually changes the machine uses -AllowFrom, not this.
    $tailscaleIp = '<workstation-tailnet-ip>'
    Bad "Could not read a Tailscale IPv4 here. Confirm Tailscale is up, and substitute the real address in the instructions below."
}

# ------------------------------------------------------------- step 2: identity
Write-Host "`n[3/5] Share name and grantee" -ForegroundColor Cyan

if (-not $AccountName) {
    $consoleUser = (Get-WmiObject Win32_ComputerSystem).UserName   # DOMAIN\user
    if (-not $consoleUser) { throw "Nobody is logged on; pass -AccountName explicitly." }
    $AccountName = $consoleUser
    Note "Defaulting grantee to the console user."
}

# Resolve to a SID now: a typo here silently produces a share nobody can use.
try {
    $ntAccount = New-Object System.Security.Principal.NTAccount($AccountName)
    $sid       = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
} catch {
    throw ("Cannot resolve '$AccountName' on this machine. On a workgroup " +
           "workstation use COMPUTERNAME\localuser (this box is $env:COMPUTERNAME). " +
           "Local accounts here: " + ((Get-LocalUser | Where-Object Enabled).Name -join ', '))
}
Good "Grantee : $AccountName  ($sid)"

if (-not $ShareName) {
    $first = ($AccountName -split '\\')[-1] -split '[.\s_]' | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($first)) { throw "Cannot derive a share name from '$AccountName'; pass -ShareName." }
    $first = ($first.Substring(0,1).ToUpper() + $first.Substring(1).ToLower())
    $make  = ($printer.DriverName -split '[\s/]')[0] -replace '[^A-Za-z0-9]',''
    $ShareName = "${first}_${make}"
}
# SMB share names: no spaces or the UNC path becomes a support call.
$ShareName = $ShareName -replace '[^A-Za-z0-9_-]',''
Good "Share   : $ShareName"

# ------------------------------------------------- steps 2+3: share and the DACL
Write-Host "`n[4/5] Sharing and permissions" -ForegroundColor Cyan

if (-not $WhatIfOnly) {
    Set-Printer -Name $printer.Name -Shared $true -ShareName $ShareName
    # Keep it out of the browse list; the user connects by explicit UNC path.
    Set-Printer -Name $printer.Name -Published $false
}
Good "$verb share '$ShareName' (not published to directory)."

# Printer DACL. Access masks from winspool.h:
#   PRINTER_ACCESS_USE        0x00000008
#   READ_CONTROL              0x00020000
#   "Print"                   0x00020008  on the printer object
#   document-inherit ACE      0x00020000  with OI|IO flags (0x01|0x08 = 0x09)
#   PRINTER_ALL_ACCESS        0x000F000C  ("Manage this printer")
$PRINT_ON_OBJECT = 0x00020008
$PRINT_ON_DOCS   = 0x00020000
$OI_IO           = 0x09
$FULL            = 0x000F000C
$ACCESS_ALLOWED  = 0

$wmiPrinter = Get-WmiObject Win32_Printer -Filter "Name='$($printer.Name -replace "'","''")'"
$sd = $wmiPrinter.GetSecurityDescriptor().Descriptor

function New-PrinterAce {
    param([string]$Sid, [int]$Mask, [int]$Flags)
    $trustee = ([WMIClass]'\\.\root\cimv2:Win32_Trustee').CreateInstance()
    $trustee.SIDString = $Sid
    $ace = ([WMIClass]'\\.\root\cimv2:Win32_ACE').CreateInstance()
    $ace.AccessMask = $Mask
    $ace.AceFlags   = $Flags
    $ace.AceType    = $ACCESS_ALLOWED
    $ace.Trustee    = $trustee
    return $ace
}

# Principals that must keep management access, per Michael's step 3.
$keepSids = @(
    'S-1-5-32-544',   # BUILTIN\Administrators
    'S-1-5-18',       # NT AUTHORITY\SYSTEM
    'S-1-3-0'         # CREATOR OWNER (owns your own documents)
)
# Broad print grants to strip: Everyone, Authenticated Users, INTERACTIVE,
# Users, and the app-container SIDs Windows 10/11 adds to printers.
$stripSids = @(
    'S-1-1-0',        # Everyone
    'S-1-5-11',       # Authenticated Users
    'S-1-5-4',        # INTERACTIVE
    'S-1-5-32-545',   # BUILTIN\Users
    'S-1-15-2-1',     # ALL APPLICATION PACKAGES
    'S-1-15-2-2'      # ALL RESTRICTED APPLICATION PACKAGES
)

$kept = @(); $removed = @()
foreach ($ace in $sd.DACL) {
    $s = $ace.Trustee.SIDString
    if ($keepSids -contains $s) { $kept += $ace }
    elseif ($stripSids -contains $s) { $removed += $s }
    elseif ($s -eq $sid) { }            # rebuilt below, cleanly
    else { $kept += $ace }              # unknown principal: leave it, report it
}

$newDacl  = @($kept)
$newDacl += New-PrinterAce -Sid $sid -Mask $PRINT_ON_OBJECT -Flags 0
$newDacl += New-PrinterAce -Sid $sid -Mask $PRINT_ON_DOCS   -Flags $OI_IO
$sd.DACL  = $newDacl

if (-not $WhatIfOnly) {
    # Only the DACL is ours to change. GetSecurityDescriptor also hands back Owner
    # and Group, and SetSecurityDescriptor will try to apply those too -- which
    # fails with 1307 ERROR_INVALID_OWNER (0x8007051B) when the caller lacks the
    # privilege to assign that owner SID. Clearing them leaves owner/group as they
    # are and applies the DACL alone. Found on the first apply, 2026-08-31.
    $sd.Owner = $null
    $sd.Group = $null

    $rc = $wmiPrinter.SetSecurityDescriptor($sd).ReturnValue
    if ($rc -ne 0) {
        $hex = "0x{0:X8}" -f $rc
        $hint = switch ($rc) {
            5          { "Access denied -- is this shell really elevated?" }
            2147943707 { "ERROR_INVALID_OWNER: the descriptor still carries an owner this account cannot assign." }
            default    { "" }
        }
        # Do not leave the printer shared with its original all-users DACL. That is
        # the exact exposure this script exists to prevent, so undo the share before
        # failing.
        try {
            Set-Printer -Name $printer.Name -Shared $false -ErrorAction Stop
            Write-Warning "Rolled back: un-shared '$ShareName' so the printer is not left shared with its original permissions."
        } catch {
            Write-Warning "COULD NOT ROLL BACK. Un-share it by hand NOW: Set-Printer -Name '$($printer.Name)' -Shared `$false"
        }
        throw "SetSecurityDescriptor failed: $rc ($hex). $hint"
    }
}
Good "$verb grant Print to $AccountName."
$sidNames = @{
    'S-1-1-0'      = 'Everyone'
    'S-1-5-11'     = 'Authenticated Users'
    'S-1-5-4'      = 'INTERACTIVE'
    'S-1-5-32-545' = 'BUILTIN\Users'
    'S-1-15-2-1'   = 'ALL APPLICATION PACKAGES'
    'S-1-15-2-2'   = 'ALL RESTRICTED APPLICATION PACKAGES'
}
$removedUnique = @($removed | Select-Object -Unique)
if ($removedUnique.Count -gt 0) {
    $pretty = ($removedUnique | ForEach-Object { if ($sidNames[$_]) { $sidNames[$_] } else { $_ } }) -join ', '
    Good "$verb remove broad print grants from: $pretty  ($($removed.Count) ACE(s))"
} else {
    Note "No broad print grants were present."
}
Note "Preserved: Administrators, SYSTEM, CREATOR OWNER"

# One SID normally holds several ACEs on a printer -- one on the object plus
# inherit-only ones for documents -- so report distinct principals, not raw rows.
$extraSids = @($kept |
    Where-Object { $keepSids -notcontains $_.Trustee.SIDString } |
    ForEach-Object { $_.Trustee.SIDString } |
    Select-Object -Unique)

# S-1-15-3-* are app-container CAPABILITY SIDs. Windows puts one on every printer
# so Store/UWP apps can print locally. This is NOT a remote exposure: a user
# arriving over SMB never carries a capability SID in their token, so it grants
# nothing to another Sage user. Stripping it would only break Store-app printing
# for the machine's own user. Report it and move on -- do not remove it, and do
# not hold up the verdict over it.
$capability = @($extraSids | Where-Object { $_ -like 'S-1-15-3-*' })
$unknown    = @($extraSids | Where-Object { $_ -notlike 'S-1-15-3-*' })

if ($capability.Count -gt 0) {
    Note "$($capability.Count) app-container capability SID(s) left in place (normal on Windows printers; local Store-app printing only, not reachable over SMB)."
}
if ($unknown.Count -gt 0) {
    Bad "Unexpected principal(s) still hold rights on this printer -- review: $($unknown -join ', ')"
}

# --------------------------------------------------------------- step 4: firewall
Write-Host "`n[5/5] Firewall: SMB reachability" -ForegroundColor Cyan

$ruleName = "IAI Sage printer share (SMB from tailnet)"
if (-not $WhatIfOnly) {
    $existing = @(Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) { $existing | Remove-NetFirewallRule }
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 445 -RemoteAddress $AllowFrom -Profile Any `
        -Description "Lets the AWS Sage host reach this user's printer share." | Out-Null
}
Good "$verb add an inbound allow for TCP 445 from $($AllowFrom -join ', ')."

# Do NOT claim this restricts anything. Measured on this fleet 2026-08-31: the
# Windows Firewall profiles are enabled with inbound default Block and no rule
# permits 445, yet 445 answers from anywhere on the tailnet -- on IAI and
# AmeriGlide machines alike. Tailscale permits inbound tailnet connections
# through its own WFP filters, below the layer Get-NetFirewallRule describes,
# whenever ShieldsUp is off. Two independent reasons an allow-rule cannot
# narrow this: it adds permission to a path already permitted, and Windows
# Firewall unions allow-rules, so "only from X" is not expressible by adding
# an allow at all.
$tsAdapter = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -like '100.*' -and $_.InterfaceAlias -match 'Tailscale' })
if ($tsAdapter.Count -gt 0) {
    Bad ("Windows Firewall is NOT the effective control for tailnet traffic here. " +
         "Expect TCP 445 to stay reachable from the whole tailnet regardless of this rule. " +
         "The share DACL above is what actually keeps this printer private. " +
         "To restrict reachability, use the tailnet ACL, not this machine.")
    Note "Verify from a machine that is NOT $($AllowFrom -join '/'):  Test-NetConnection $tailscaleIp -Port 445"
    Note "  It answering does not mean this printer is exposed -- the DACL still gates use."
}

if ($KeepLanSmb) {
    Note "-KeepLanSmb: left the broad LAN SMB-In rules untouched."
} else {
    $broad = @(Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'File and Printer Sharing*SMB-In*' })
    if ($broad.Count -gt 0) {
        if (-not $WhatIfOnly) { $broad | Disable-NetFirewallRule }
        Good "$verb disable $($broad.Count) broad SMB-In rule(s) (removes the LAN/Public path; see the tailnet caveat above)."
        Note "Revert with: Get-NetFirewallRule -DisplayName 'File and Printer Sharing*SMB-In*' | Enable-NetFirewallRule"
    } else {
        Note "No broad SMB-In rules were enabled."
    }
}

# ------------------------------------------------------------------- the verdict
$unc = "\\$tailscaleIp\$ShareName"
Write-Host "`n============================ VERDICT ============================" -ForegroundColor Cyan
if ($issues.Count -eq 0) {
    Write-Host "Workstation side is ready." -ForegroundColor Green
    Write-Host "The share DACL is what makes this printer private to one user." -ForegroundColor Green
} else {
    Write-Host "Workstation side is INCOMPLETE -- resolve these first:" -ForegroundColor Yellow
    $issues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
Write-Host @"

Next, from the Sage host (step 5), confirm it can reach this workstation:

    Test-NetConnection $tailscaleIp -Port 445

Then $AccountName -- and nobody else -- does this INSIDE their own Sage
desktop, reached through the Guacamole portal (steps 6-7):

    Win + R  ->  $unc
    Sign in as : $AccountName
    Password   : the one they use on this physical workstation
    Right-click the printer -> Connect

Do NOT do this for them over SSM or with a server-wide install. That runs as
the Sage-side account, writes to HKLM, and exposes the printer to every Sage
user -- with no prompt to tell you it happened.

Verify by having a DIFFERENT Sage user check that the printer is absent from
their print dialog and that $unc refuses them.
"@ -ForegroundColor White
Write-Host "=================================================================" -ForegroundColor Cyan
