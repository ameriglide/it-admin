#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Uninstall JumpCloud Remote Assist from a workstation whose JumpCloud agent
  is already gone. ASCII only.

.DESCRIPTION
  Remote Assist (jumpcloud-assist-service, an Electron service) depends on the
  JumpCloud agent. JumpCloud's own UninstallWindowsAgent.ps1 removes both
  together for that reason. deploy-gcpw.ps1 Phase 2 removed only the agent
  (an MSI) and left Remote Assist (an NSIS exe install) behind, so on every
  migrated machine the orphaned service crash-looped every 5 seconds from
  2026-09-12 (AG-1141): ~17,000 Event ID 7031 entries per day per machine,
  enough to overrun the System log and erase diagnostic history.

  What this does, in order:
    1. Refuses to run while the JumpCloud agent is still installed, unless
       -Force is given (deploy-gcpw Phase 2 passes -Force because it has just
       removed the agent in the same run).
    2. Stops the service, clears its RESTART/5s failure actions, and kills any
       Remote Assist processes.
    3. Runs the vendor uninstaller silently (QuietUninstallString from the
       registry, falling back to UninstallString + /S).
    4. Sweeps whatever the uninstaller left: the service registration, the
       install directory, the Uninstall registry key.
    5. Verifies and prints a verdict. Never reboots.

  Idempotent: on a clean machine it reports "already clean" and exits 0.
  Exit 0 = clean (or preview), exit 1 = leftovers remain, exit 2 = refused
  because the agent is still installed.

.PARAMETER Force
  Uninstall even if the JumpCloud agent is still present.

.PARAMETER WhatIfOnly
  Report what would be done without changing anything.

.NOTES
  ASCII-only -- Windows PowerShell 5.1 parses scripts as ANSI. No non-ASCII.
  Clearing failure actions has to go through cmd.exe: PowerShell drops the
  empty-quote token that sc.exe needs for actions= "".
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Continue'
$Script:Revision = ""

$ServiceName   = 'jumpcloud-assist-service'
$InstallDir    = "$env:ProgramFiles\JumpCloud Remote Assist"
$DisplayName   = 'JumpCloud Remote Assist'
$UninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

function Get-RemoteAssistUninstallEntry {
    foreach ($root in $UninstallKeys) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in Get-ChildItem -Path $root -ErrorAction SilentlyContinue) {
            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if ($props.DisplayName -like "*$DisplayName*") { return $props }
        }
    }
    return $null
}

function Get-RemoteAssistState {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Service      = $svc
        InstallDir   = (Test-Path $InstallDir)
        Uninstall    = (Get-RemoteAssistUninstallEntry)
        Processes    = @(Get-Process -Name 'jumpcloud-assist*', 'JumpCloud Remote Assist', 'desktop-change-listener' -ErrorAction SilentlyContinue)
    }
}

function Test-Clean($state) {
    (-not $state.Service) -and (-not $state.InstallDir) -and (-not $state.Uninstall)
}

# Split "\"C:\path\Uninstall.exe\" /allusers /S" into the exe and its arguments.
function Split-UninstallCommand([string]$command) {
    $command = $command.Trim()
    if ($command.StartsWith('"')) {
        $end = $command.IndexOf('"', 1)
        return @{ Exe = $command.Substring(1, $end - 1); Args = $command.Substring($end + 1).Trim() }
    }
    $parts = $command -split '\s+', 2
    return @{ Exe = $parts[0]; Args = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }) }
}

Write-Host "remove-jumpcloud-remote-assist.ps1 rev $Script:Revision on $env:COMPUTERNAME" -ForegroundColor DarkGray

$before = Get-RemoteAssistState
if (Test-Clean $before) {
    Write-Host "VERDICT: already clean -- $DisplayName is not installed." -ForegroundColor Green
    exit 0
}

$agent = Get-CimInstance Win32_Service -Filter "Name='jumpcloud-agent'" -ErrorAction SilentlyContinue
if ($agent -and -not $Force) {
    Write-Host "VERDICT: refused -- the JumpCloud agent is still installed ($($agent.State)), so Remote Assist is still supported here." -ForegroundColor Yellow
    Write-Host "         Remove the agent first (deploy-gcpw.ps1 -Phase 2), or re-run with -Force." -ForegroundColor Yellow
    exit 2
}

$svcState = if ($before.Service) { "$($before.Service.State)/$($before.Service.StartMode)" } else { 'absent' }
$quiet = if ($before.Uninstall) { $before.Uninstall.QuietUninstallString } else { $null }
$plain = if ($before.Uninstall) { $before.Uninstall.UninstallString } else { $null }
$command = if ($quiet) { $quiet } elseif ($plain) { "$plain /S" } else { $null }
Write-Host "  service: $svcState   dir: $($before.InstallDir)   uninstall entry: $([bool]$before.Uninstall)   processes: $($before.Processes.Count)"

if ($WhatIfOnly) {
    Write-Host "  Would stop and clear failure actions on $ServiceName, kill $($before.Processes.Count) process(es)."
    if ($command) { Write-Host "  Would run: $command" } else { Write-Host "  No uninstall entry; would sweep service, directory and registry by hand." }
    Write-Host "VERDICT: preview only -- no changes made." -ForegroundColor DarkGray
    exit 0
}

# --- 1. Stop the loop -------------------------------------------------------
if ($before.Service) {
    Write-Host "[1/3] Stopping $ServiceName and clearing its failure actions..." -ForegroundColor Yellow
    & sc.exe config $ServiceName start= disabled | Out-Null
    & cmd.exe /c "sc failure $ServiceName reset= 86400 actions= `"`"" | Out-Null
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "[1/3] Service already absent." -ForegroundColor DarkGray
}
foreach ($p in $before.Processes) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }

# --- 2. Vendor uninstaller --------------------------------------------------
if ($command) {
    $parsed = Split-UninstallCommand $command
    if (Test-Path $parsed.Exe) {
        Write-Host "[2/3] Running vendor uninstaller: $command" -ForegroundColor Yellow
        $proc = Start-Process -FilePath $parsed.Exe -ArgumentList $parsed.Args -Wait -PassThru -ErrorAction SilentlyContinue
        if ($proc) { Write-Host "  uninstaller exit code $($proc.ExitCode)" }
        # NSIS uninstallers copy themselves to %TEMP% and return before the
        # copy finishes deleting files; give it a moment before sweeping.
        $deadline = (Get-Date).AddSeconds(60)
        while ((Test-Path $InstallDir) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
    } else {
        Write-Host "[2/3] Uninstaller not found at $($parsed.Exe); sweeping by hand." -ForegroundColor Yellow
    }
} else {
    Write-Host "[2/3] No uninstall entry; sweeping by hand." -ForegroundColor Yellow
}

# --- 3. Sweep leftovers -----------------------------------------------------
Write-Host "[3/3] Sweeping leftovers..." -ForegroundColor Yellow
$mid = Get-RemoteAssistState
if ($mid.Service) {
    & sc.exe delete $ServiceName | Out-Null
    Write-Host "  deleted service registration"
}
if ($mid.InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $InstallDir)) { Write-Host "  removed $InstallDir" }
}
if ($mid.Uninstall) {
    Remove-Item -Path $mid.Uninstall.PSPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  removed uninstall registry key"
}
foreach ($shortcut in @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\$DisplayName.lnk",
                        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\$DisplayName")) {
    if (Test-Path $shortcut) { Remove-Item -Path $shortcut -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- Verdict ---------------------------------------------------------------
$after = Get-RemoteAssistState
if (Test-Clean $after) {
    Write-Host "VERDICT: clean -- $DisplayName removed from $env:COMPUTERNAME." -ForegroundColor Green
    exit 0
}
$left = @()
if ($after.Service)    { $left += "service ($($after.Service.State))" }
if ($after.InstallDir) { $left += "directory $InstallDir" }
if ($after.Uninstall)  { $left += 'uninstall registry key' }
Write-Host "VERDICT: leftovers remain on $env:COMPUTERNAME -- $($left -join '; '). A reboot may release locked files; re-run afterwards." -ForegroundColor Red
exit 1
