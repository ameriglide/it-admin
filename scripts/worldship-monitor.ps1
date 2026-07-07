# worldship-monitor.ps1
# Reads the installed UPS WorldShip version and scans recent WorldShip syslogs;
# beats a Better Stack heartbeat with the version in the body, or POSTs to
# <heartbeatUrl>/fail when the latest update attempt failed (or WorldShip is
# missing). Cadence comes from the 'AG WorldShip Monitor' scheduled task.
# ASCII only.
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'

$BaseDir    = Join-Path $env:ProgramData 'ag-admin'
$ConfigPath = Join-Path $BaseDir 'worldship-monitor.config.json'
$LogPath    = Join-Path $BaseDir 'worldship-monitor.log'

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
    foreach ($f in $logFiles) { $all += @(Get-Content -Path $f.FullName -ErrorAction SilentlyContinue) }
    $lastAttempt = -1
    for ($i = 0; $i -lt $all.Count; $i++) {
        if ($all[$i] -like "*$attemptPattern*") { $lastAttempt = $i }
    }
    if ($lastAttempt -ge 0) {
        for ($i = $lastAttempt + 1; $i -lt $all.Count; $i++) {
            foreach ($p in $failPatterns) {
                if ($all[$i] -like "*$p*") { $failLine = $all[$i].Trim(); break }
            }
            if ($failLine) { break }
        }
    }
}

if ($version -eq 'not-installed') { $failLine = 'WorldShipTD.exe not found' }

# 3. Ping.
if ($failLine) {
    $short = $failLine.Substring(0, [Math]::Min(300, $failLine.Length))
    $body  = "version=$version error=$short"
    $url   = "$($cfg.heartbeatUrl)/fail"
    Write-WsLog ("UNHEALTHY: {0}" -f $body)
} else {
    $body = "version=$version"
    $url  = $cfg.heartbeatUrl
    Write-WsLog ("healthy: {0}" -f $body)
}

if ($DryRun) { Write-WsLog 'DRYRUN: heartbeat not sent'; return }
try { Invoke-RestMethod -Uri $url -Method Post -Body $body -TimeoutSec 15 | Out-Null }
catch { Write-WsLog "heartbeat ping failed: $($_.Exception.Message)" }
