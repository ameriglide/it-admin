# disable-wpad-proxy.ps1
# Disable Windows WPAD proxy auto-detection on always-on tailnet servers.
#
# Root cause of AG-46: tailscaled runs as SYSTEM, and SYSTEM has "Automatically
# detect settings" (WPAD) enabled. tailscaled's tshttpproxy calls WinHTTP
# GetProxyForURL on outbound dials; when connectivity briefly hiccups the WPAD
# discovery call hangs for HOURS (no effective timeout), wedging the daemon
# (including MagicDNS) and taking the node off the tailnet until it finally
# cancels. These servers use no proxy, so WPAD is pure liability.
#
# This clears the WPAD auto-detect bit in every relevant WinINET connection
# profile. It deliberately does NOT disable WinHttpAutoProxySvc -- that service
# is a dependency of iphlpsvc/Tailscale on these boxes, and disabling it blocks
# the whole stack from starting on the next boot (see repair-tailscale-service-
# deps.ps1). Idempotent. ASCII only.
[CmdletBinding()]
param([switch]$WhatIfOnly)

$ErrorActionPreference = 'Stop'
$Script:Revision = "a2d2043"

# WinINET stores per-profile proxy config as the REG_BINARY
# DefaultConnectionSettings. Byte 8 is a flags bitmask:
#   0x01 direct  0x02 manual proxy  0x04 auto-config (PAC)  0x08 auto-detect (WPAD)
# Bytes 4..7 are a little-endian change counter WinINET checks to reload.
function Clear-WpadAutoDetect {
    param([Parameter(Mandatory)][string]$ConnectionsKey)
    if (-not (Test-Path $ConnectionsKey)) { return $false }
    $name = 'DefaultConnectionSettings'
    $prop = Get-ItemProperty -Path $ConnectionsKey -Name $name -ErrorAction SilentlyContinue
    if (-not $prop) { return $false }
    $bytes = [byte[]]$prop.$name
    if ($bytes.Length -lt 9) { return $false }
    if (($bytes[8] -band 0x08) -eq 0) { return $false }   # already off
    $bytes[8] = $bytes[8] -band 0xF7                       # clear only the WPAD bit
    for ($i = 4; $i -le 7; $i++) {                         # bump the LE change counter
        $bytes[$i] = ($bytes[$i] + 1) -band 0xFF
        if ($bytes[$i] -ne 0) { break }
    }
    if (-not $WhatIfOnly) { Set-ItemProperty -Path $ConnectionsKey -Name $name -Value $bytes }
    return $true
}

$sub = 'Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
$targets = [System.Collections.Generic.List[string]]::new()
$targets.Add("Registry::HKEY_USERS\S-1-5-18\$sub")          # SYSTEM (tailscaled runs here)
$targets.Add("Registry::HKEY_LOCAL_MACHINE\$sub")           # machine default
# Plus every loaded real user hive (the interactive sage account, etc.).
Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^S-1-5-21-' } |
    ForEach-Object { $targets.Add("Registry::HKEY_USERS\$($_.PSChildName)\$sub") }

$verb = if ($WhatIfOnly) { 'Would clear' } else { 'Cleared' }
$changed = 0
foreach ($t in ($targets | Select-Object -Unique)) {
    try {
        if (Clear-WpadAutoDetect -ConnectionsKey $t) {
            $changed++
            Write-Host "  $verb WPAD auto-detect: $t" -ForegroundColor Green
        }
    } catch {
        Write-Warning "  Could not update $t : $($_.Exception.Message)"
    }
}
if ($changed -eq 0) { Write-Host "  WPAD auto-detect already off (no WinINET changes)." -ForegroundColor DarkGray }

# NOTE: do NOT disable WinHttpAutoProxySvc here. It is a service dependency of
# iphlpsvc (and therefore Tailscale) on these servers, so disabling it stops the
# whole stack from starting on the next boot (AG-46 follow-up, 2026-06-10).
# Clearing the WPAD auto-detect bit above is enough to stop the tailscaled
# GetProxyForURL hang; the spurious dependency itself is removed separately by
# repair-tailscale-service-deps.ps1.

if ($WhatIfOnly) { Write-Host "Preview only -- no changes made." -ForegroundColor DarkGray }
else { Write-Host "WPAD proxy auto-detect disabled." -ForegroundColor Green }
