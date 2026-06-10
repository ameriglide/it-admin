# repair-tailscale-service-deps.ps1
# Remove the spurious WinHttpAutoProxySvc dependency that gates Tailscale, so a
# reboot (or a baseline re-push) can never wedge the stack. ASCII only.
#
# Root cause (AG-46 follow-up, 2026-06-10): in TierPoint a GPO/security-baseline
# (a) made iphlpsvc (IP Helper) depend on WinHttpAutoProxySvc -- NOT a Windows
# default; IP Helper normally depends only on nsi -- and (b) left
# WinHttpAutoProxySvc un-startable (ERROR_SERVICE_DISABLED 1058) with a locked
# security descriptor that denies reconfiguration even to elevated admins.
# Because Tailscale depends on iphlpsvc, a cold boot cascades:
#   Tailscale -> iphlpsvc -> WinHttpAutoProxySvc (dead)
# nothing starts, and the node drops off the tailnet until someone intervenes.
# These servers use no proxy, so the dependency is pure liability.
#
# Fix: drop WinHttpAutoProxySvc from the DependOnService list of iphlpsvc and
# Tailscale. We write the registry (so it survives reboot) AND push the same
# change through sc.exe config, because the live SCM caches the dependency graph
# in memory and only re-reads it via ChangeServiceConfig (what sc.exe uses) or on
# reboot -- a raw registry edit alone does not take effect until the next boot.
# Idempotent; never touches WinHttpAutoProxySvc itself (its SD is locked anyway).
[CmdletBinding()]
param([switch]$WhatIfOnly)

$ErrorActionPreference = 'Stop'
$Script:Revision = ""

$Dependency = 'WinHttpAutoProxySvc'
$Services   = 'iphlpsvc', 'Tailscale'
$changed = 0

foreach ($svc in $Services) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
    if (-not (Test-Path $key)) {
        Write-Host "  $svc not installed -- skipping." -ForegroundColor DarkGray
        continue
    }
    $cur = @((Get-ItemProperty -Path $key -Name DependOnService -ErrorAction SilentlyContinue).DependOnService)
    if ($cur -notcontains $Dependency) {
        Write-Host "  $svc already clean (no $Dependency dependency)." -ForegroundColor DarkGray
        continue
    }
    $new = @($cur | Where-Object { $_ -and $_ -ne $Dependency })
    if ($WhatIfOnly) {
        Write-Host "  Would set $svc deps: $($cur -join ', ')  ->  $($new -join ', ')" -ForegroundColor Green
        continue
    }
    # Persist (reboot-safe) ...
    Set-ItemProperty -Path $key -Name DependOnService -Value ([string[]]$new) -Type MultiString
    # ... and update the live SCM so no reboot is needed. sc.exe wants a space
    # after 'depend=' and '/'-separated names. An empty value would clear ALL
    # dependencies, so guard against it (these services always retain others).
    $depArg = ($new -join '/')
    if ($depArg) {
        $out = & sc.exe config $svc depend= $depArg 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Warning "  sc.exe config $svc failed ($LASTEXITCODE): $out" }
    }
    Write-Host "  $svc deps: $($cur -join ', ')  ->  $($new -join ', ')" -ForegroundColor Green
    $changed++
}

if ($WhatIfOnly)        { Write-Host "Preview only -- no changes made." -ForegroundColor DarkGray }
elseif ($changed -eq 0) { Write-Host "Tailscale service dependencies already clean." -ForegroundColor DarkGray }
else                    { Write-Host "Severed $Dependency from $changed service(s)." -ForegroundColor Green }
