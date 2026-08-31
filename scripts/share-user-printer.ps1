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
if ($PrinterName) {
    $printer = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
    if (-not $printer) { throw "No printer named '$PrinterName'. Present: $((Get-Printer).Name -join '; ')" }
} else {
    $localAll = Get-Printer | Where-Object { $_.Type -eq 'Local' -and $_.Name -notmatch $virtual }
    if ($localAll.Count -eq 1) {
        $printer = $localAll[0]
        Note "Auto-detected the only local printer: $($printer.Name)"
    } else {
        throw ("Cannot auto-detect. Pass -PrinterName. Local printers: " +
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

$stuck = Get-PrintJob -PrinterName $printer.Name -ErrorAction SilentlyContinue
if ($stuck) { Note "$($stuck.Count) job(s) in the queue." }

# ---------------------------------------------------------- step 1b: tailnet IP
Write-Host "`n[2/5] Tailscale address" -ForegroundColor Cyan

$tailscaleIp = $null
$tsExe = "$env:ProgramFiles\Tailscale\tailscale.exe"
if (Test-Path $tsExe) {
    $tailscaleIp = (& $tsExe ip -4 2>$null | Select-Object -First 1)
}
if (-not $tailscaleIp) {
    $tailscaleIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like '100.*' -and $_.InterfaceAlias -match 'Tailscale' } |
        Select-Object -First 1 -ExpandProperty IPAddress)
}
if ($tailscaleIp) { Good "Workstation tailnet IP: $tailscaleIp" }
else { Bad "No Tailscale IPv4 found. Sage cannot reach this box until Tailscale is up." }

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
    $rc = $wmiPrinter.SetSecurityDescriptor($sd).ReturnValue
    if ($rc -ne 0) { throw "SetSecurityDescriptor failed with return value $rc." }
}
Good "$verb grant Print to $AccountName."
if ($removed) { Good "$verb remove broad print grants: $($removed -join ', ')" }
else { Note "No broad print grants were present." }
$extra = @($kept | Where-Object { $keepSids -notcontains $_.Trustee.SIDString })
Note "Preserved: Administrators, SYSTEM, CREATOR OWNER"
if ($extra.Count -gt 0) {
    Bad "$($extra.Count) other principal(s) still hold rights on this printer -- review: $(($extra | ForEach-Object { $_.Trustee.SIDString }) -join ', ')"
}

# --------------------------------------------------------------- step 4: firewall
Write-Host "`n[5/5] Firewall: SMB from the tailnet only" -ForegroundColor Cyan

$ruleName = "IAI Sage printer share (SMB from tailnet)"
if (-not $WhatIfOnly) {
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existing) { $existing | Remove-NetFirewallRule }
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 445 -RemoteAddress $AllowFrom -Profile Any `
        -Description "Lets the AWS Sage host reach this user's printer share." | Out-Null
}
Good "$verb allow TCP 445 inbound from $($AllowFrom -join ', ') only."

if ($KeepLanSmb) {
    Note "-KeepLanSmb: left the broad LAN SMB-In rules untouched."
} else {
    $broad = Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'File and Printer Sharing*SMB-In*' }
    if ($broad) {
        if (-not $WhatIfOnly) { $broad | Disable-NetFirewallRule }
        Good "$verb disable $($broad.Count) broad SMB-In rule(s) so LAN/Public cannot reach 445."
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
