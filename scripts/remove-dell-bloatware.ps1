#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Remove Dell SupportAssist (and its family) plus Dell Digital Delivery.

.DESCRIPTION
  Action1's native "Uninstall Software" leaves the core Dell SupportAssist
  agent behind because its service is tamper-protected and -- on these boxes --
  its cached MSI is missing, so "msiexec /x" fails with 1612 (source absent).

  This script: stops + disables the related services, kills the processes,
  then for each matching product tries the proper uninstall (MSI by product
  code, or the vendor's quiet string). If the MSI uninstall cannot run because
  the source is absent, it force-removes the product's registration so the
  machine -- and Action1's inventory -- no longer report it. Finally it sweeps
  leftover scheduled tasks and folders.

  Idempotent and safe to re-run. Intended for the Dell Workstations endpoint
  group (one-time to clean current boxes, or recurring to catch newly imaged
  Dells that ship with this junk preinstalled).

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

# 1. Kill running processes so files/registration are not locked.
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

# Returns $true if the product was removed (or forcibly de-registered).
function Invoke-Uninstall($app) {
    $dn  = $app.DisplayName
    $key = $app.PSChildName

    if ($key -match '^\{[0-9A-Fa-f-]+\}$') {
        # MSI product: uninstall silently by product code.
        $proc = Start-Process 'msiexec.exe' -ArgumentList "/x $key /qn /norestart" -Wait -NoNewWindow -PassThru
        $rc = $proc.ExitCode
        Write-Host "  msiexec /x $key -> exit $rc"
        if ($rc -eq 0 -or $rc -eq 3010 -or $rc -eq 1605) { return $true }  # removed / not present
        # Cannot MSI-uninstall (e.g. 1612 = source absent). Files are swept
        # below; force-remove the registration so it clears from inventory.
        Write-Warning "  msiexec could not uninstall $dn (exit $rc); force-removing its registration."
        Remove-Item -Path $app.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        return $true
    }

    # EXE uninstaller. Split the leading (optionally quoted) exe path from args.
    $cmd = if ($app.QuietUninstallString) { $app.QuietUninstallString } else { $app.UninstallString }
    if (-not $cmd) {
        Write-Warning "  No uninstall string for $dn; force-removing its registration."
        Remove-Item -Path $app.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        return $true
    }
    if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') {
        $exe = $Matches[1]; $rest = $Matches[2]
    } elseif ($cmd -match '^\s*(\S+)\s*(.*)$') {
        $exe = $Matches[1]; $rest = $Matches[2]
    } else {
        Write-Warning "  Unparseable uninstall string for $dn"; return $false
    }
    # If the vendor gave a quiet string, run it as-is; otherwise add common
    # silent flags for Dell's NSIS/InstallShield uninstallers.
    if (-not $app.QuietUninstallString) { $rest = ("$rest /S /silent /norestart").Trim() }
    Write-Host "  $exe $rest"
    Start-Process $exe -ArgumentList $rest -Wait -NoNewWindow
    return $true
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
        try { if (Invoke-Uninstall $app) { $removed++ } }
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

Write-Host "Dell bloatware removal complete. Products handled: $removed." -ForegroundColor Green
