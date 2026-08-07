# worldship-monitor.ps1
# Reads the installed UPS WorldShip version and scans recent WorldShip syslogs;
# beats a Better Stack heartbeat with the version in the body, or POSTs to
# <heartbeatUrl>/fail when the latest update attempt failed (or WorldShip is
# missing). Cadence comes from the 'AG WorldShip Monitor' scheduled task.
# ASCII only.
#
# Also probes the station's critical accounting endpoint when
# 'criticalEndpoint' (host:port) is configured. A shipping station's whole job
# is order lookups against Sage, and that dependency fails SILENTLY: when the
# tunnel to Sage is down, OzLINK's SELECTs return zero rows with no error, so
# the operator sees "order not found" and hand-keys labels with blank
# addresses. Nothing else on the box notices. The tailnet watchdog does not
# catch it either -- its anchor probe is satisfied by ANY one anchor
# responding, so a single dead peer reads as healthy (2026-08-06, AG).
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'

$BaseDir    = Join-Path $env:ProgramData 'ag-admin'
$ConfigPath = Join-Path $BaseDir 'worldship-monitor.config.json'
$LogPath    = Join-Path $BaseDir 'worldship-monitor.log'

function Test-TcpConnect {
    # Hard-bounded TCP connect. Test-NetConnection has no usable timeout and can
    # hang for minutes on a wedged stack, which would stall the scheduled task
    # (same reasoning as watchdog-core.ps1, AG-47).
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMs = 3000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($iar)   # throws if the connection actually failed
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Write-WsLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogPath -Value $line
    $lines = @(Get-Content -Path $LogPath -ErrorAction SilentlyContinue)
    if ($lines.Count -gt 1000) { $lines[-1000..-1] | Set-Content -Path $LogPath }
}

if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
$cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$lookbackDays = [int]$cfg.lookbackDays

# 1. Version stamp (goes in every heartbeat body).
$exePath = 'C:\Program Files (x86)\UPS\WSTD\WorldShipTD.exe'
if (Test-Path $exePath) {
    $version = ((Get-Item $exePath).VersionInfo.FileVersion -replace ' ', '')
} else {
    $version = 'not-installed'
}

# 2. Latest-attempt outcome from recent syslogs. YYYYMMDD.log names sort
#    chronologically, so concatenating in name order preserves event order.
$attemptPattern = 'Executing object distribution'
$failPatterns   = @('Object Distribution Failed', 'The update to your UPS WorldShip has failed')
$syslogDir      = 'C:\ProgramData\UPS\WSTD\Syslog'
$cutoff         = (Get-Date).AddDays(-$lookbackDays)

$failLine = $null
if (Test-Path $syslogDir) {
    $logFiles = Get-ChildItem -Path $syslogDir -Filter '*.log' -File |
        Where-Object { $_.LastWriteTime -ge $cutoff } | Sort-Object Name
    $all = @()
    foreach ($f in $logFiles) {
        try { $all += @(Get-Content -Path $f.FullName -ErrorAction Stop) }
        catch { Write-WsLog ("WARNING: could not read {0}: {1}" -f $f.Name, $_.Exception.Message) }
    }
    $lastAttempt = -1
    for ($i = 0; $i -lt $all.Count; $i++) {
        if ($all[$i] -like "*$attemptPattern*") { $lastAttempt = $i }
    }
    for ($i = $lastAttempt + 1; $i -lt $all.Count; $i++) {
        foreach ($p in $failPatterns) {
            if ($all[$i] -like "*$p*") { $failLine = $all[$i].Trim(); break }
        }
        if ($failLine) { break }
    }
}

if ($version -eq 'not-installed') { $failLine = 'WorldShipTD.exe not found' }

# 3. Critical accounting endpoint (optional). Absent config = not probed, so
# stations without the setting behave exactly as before.
$sage = 'not-configured'
if ($cfg.PSObject.Properties.Name -contains 'criticalEndpoint' -and $cfg.criticalEndpoint) {
    $parts = ("$($cfg.criticalEndpoint)" -split ':')
    if ($parts.Count -ne 2 -or -not ($parts[1] -as [int])) {
        $sage = 'bad-config'
        Write-WsLog ("WARNING: criticalEndpoint '{0}' is not host:port" -f $cfg.criticalEndpoint)
    } elseif (Test-TcpConnect -ComputerName $parts[0] -Port ([int]$parts[1])) {
        $sage = 'ok'
    } else {
        $sage = 'UNREACHABLE'
        # Do not mask a WorldShip failure that is already the headline.
        if (-not $failLine) {
            $failLine = "critical endpoint $($cfg.criticalEndpoint) unreachable - order lookups will silently return no rows"
        }
    }
}

# 4. Ping.
if ($failLine) {
    $short = $failLine.Substring(0, [Math]::Min(300, $failLine.Length))
    $body  = "version=$version sage=$sage error=$short"
    $url   = "$($cfg.heartbeatUrl)/fail"
    Write-WsLog ("UNHEALTHY: {0}" -f $body)
} else {
    $body = "version=$version sage=$sage"
    $url  = $cfg.heartbeatUrl
    Write-WsLog ("healthy: {0}" -f $body)
}

if ($DryRun) { Write-WsLog 'DRYRUN: heartbeat not sent'; return }
try { Invoke-RestMethod -Uri $url -Method Post -Body $body -TimeoutSec 15 | Out-Null }
catch { Write-WsLog "heartbeat ping failed: $($_.Exception.Message)" }
