#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Remove Dell SupportAssist (and its family) plus Dell Digital Delivery.

.DESCRIPTION
  Action1's native "Uninstall Software" leaves the core Dell SupportAssist
  agent behind because its service is tamper-protected and blocks the silent
  MSI uninstall. This script stops + disables those services first, then forces
  each matching product to uninstall (MSI by product code, or the vendor's
  quiet uninstall string), then sweeps leftover scheduled tasks and folders.

  Idempotent and safe to re-run. Intended to be run on the Dell Workstations
  endpoint group (one-time to clean current boxes, or recurring to catch newly
  imaged Dells that ship with this junk preinstalled).

  Deliberately does NOT remove "Dell Command | Update" (kept as the driver/BIOS
  update tool).

.NOTES
  ASCII-only -- Windows PowerShell 5.1 parses scripts as ANSI. No non-ASCII.
#>

$ErrorActionPreference = 'Continue'

# DisplayName fragments identifying the junk. These intentionally do NOT match
# "Dell Command | Update" (which we keep).
$targets = @(
    'Dell SupportAssist',
    'SupportAssist',
    'Dell Digital Delivery'
)

# 1. Kill running processes so files are not locked.
$procNames = @(
    'SupportAssistAgent', 'SupportAssistClientUI', 'SARemediation',
    'DellSupportAssistRemedationService', 'PCDoctor', 'DigitalDelivery',
    'DellDigitalDelivery'
)
foreach ($p in $procNames) {
    Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# 2. Stop + disable related services so the uninstallers are not blocked.
$svcNames = @(
    'SupportAssistAgent',
    'Dell SupportAssist Remediation',
    'Dell Hardware Support',
    'DDSHCMSvc'
)
foreach ($name in $svcNames) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "Stopping service: $name"
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        Set-Service  -Name $name -StartupType Disabled -ErrorAction SilentlyContinue
    }
}

# 3. Enumerate uninstall entries (64-bit + 32-bit) and remove matching products.
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

function Invoke-Uninstall($app) {
    $dn  = $app.DisplayName
    $key = $app.PSChildName
    $cmd = if ($app.QuietUninstallString) { $app.QuietUninstallString } else { $app.UninstallString }

    if ($key -match '^\{[0-9A-Fa-f-]+\}$') {
        # MSI product: uninstall silently by product code (most reliable).
        Write-Host "  msiexec /x $key /qn"
        Start-Process 'msiexec.exe' -ArgumentList "/x $key /qn /norestart" -Wait -NoNewWindow
        return
    }
    if (-not $cmd) { Write-Warning "  No uninstall string for $dn"; return }

    # EXE uninstaller. Split the leading (optionally quoted) exe path from args.
    if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') {
        $exe = $Matches[1]; $rest = $Matches[2]
    } elseif ($cmd -match '^\s*(\S+)\s*(.*)$') {
        $exe = $Matches[1]; $rest = $Matches[2]
    } else {
        Write-Warning "  Unparseable uninstall string for $dn"; return
    }
    # If the vendor gave a quiet string, run it as-is; otherwise add common
    # silent flags for Dell's NSIS/InstallShield uninstallers.
    if (-not $app.QuietUninstallString) { $rest = ("$rest /S /silent /norestart").Trim() }
    Write-Host "  $exe $rest"
    Start-Process $exe -ArgumentList $rest -Wait -NoNewWindow
}

$removed = 0
foreach ($root in $uninstallRoots) {
    Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
        $app = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        $dn  = $app.DisplayName
        if (-not $dn) { return }
        $isTarget = $false
        foreach ($t in $targets) { if ($dn -like "*$t*") { $isTarget = $true } }
        if (-not $isTarget) { return }

        Write-Host "Removing: $dn"
        try { Invoke-Uninstall $app; $removed++ }
        catch { Write-Warning "  Uninstall failed for $dn : $($_.Exception.Message)" }
    }
}

# 4. Sweep leftover scheduled tasks.
Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -like '*SupportAssist*' -or $_.TaskPath -like '*Dell*SupportAssist*' } |
    ForEach-Object {
        Write-Host "Removing task: $($_.TaskName)"
        Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    }

# 5. Sweep leftover folders.
$folders = @(
    "$env:ProgramFiles\Dell\SupportAssistAgent",
    "$env:ProgramFiles\Dell\SupportAssist",
    "${env:ProgramFiles(x86)}\Dell\SupportAssist",
    "$env:ProgramData\Dell\SupportAssist",
    "${env:ProgramFiles(x86)}\Dell Digital Delivery Services",
    "$env:ProgramData\Dell\Digital Delivery"
)
foreach ($f in $folders) {
    if (Test-Path $f) {
        Write-Host "Removing folder: $f"
        Remove-Item -Path $f -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Dell bloatware removal complete. Products uninstalled: $removed." -ForegroundColor Green
