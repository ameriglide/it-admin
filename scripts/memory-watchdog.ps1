# memory-watchdog.ps1
# Beats a Better Stack heartbeat only while memory/commit is healthy, and stops
# beating when commit is exhausted so an incident fires (escalation policy
# 114897, same as tailnet-<server>). This catches the failure the liveness
# heartbeat cannot see: a box that is still "up" and answering pings while its
# commit charge is exhausted -- allocations start failing, DWM crashes, RDP
# sessions get logged off. Cadence comes from the AG Memory Heartbeat scheduled
# task. ASCII only.
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'

$BaseDir    = Join-Path $env:ProgramData 'ag-admin'
$ConfigPath = Join-Path $BaseDir 'memory-watchdog.config.json'
$LogPath    = Join-Path $BaseDir 'memory-watchdog.log'

function Write-MemLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogPath -Value $line
    $lines = @(Get-Content -Path $LogPath -ErrorAction SilentlyContinue)
    if ($lines.Count -gt 1000) { $lines[-1000..-1] | Set-Content -Path $LogPath }
}

if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
$cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$commitPctMax = [double]$cfg.commitPctMax   # unhealthy at/above this % committed
$availMbMin   = [double]$cfg.availMbMin      # unhealthy below this many MB free

# % Committed Bytes In Use is committed / commit-limit -- the exact quantity that
# ran out today. Available MBytes is the physical-pressure backstop.
$commitPct = [math]::Round((Get-Counter '\Memory\% Committed Bytes In Use' -ErrorAction Stop).CounterSamples[0].CookedValue, 1)
$availMb   = [math]::Round((Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue, 0)

$healthy = ($commitPct -lt $commitPctMax) -and ($availMb -gt $availMbMin)
Write-MemLog ("commit={0}% availMB={1} healthy={2} (thresholds: commit<{3}% avail>{4}MB)" -f $commitPct, $availMb, $healthy, $commitPctMax, $availMbMin)

if ($DryRun) { Write-MemLog 'DRYRUN: heartbeat not sent'; return }

if ($healthy) {
    try { Invoke-RestMethod -Uri $cfg.heartbeatUrl -TimeoutSec 10 | Out-Null }
    catch { Write-MemLog "heartbeat ping failed: $($_.Exception.Message)" }
} else {
    Write-MemLog 'UNHEALTHY: withholding heartbeat (incident fires after grace)'
}
