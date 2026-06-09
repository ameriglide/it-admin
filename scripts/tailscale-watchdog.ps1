# tailscale-watchdog.ps1
# Single cycle: probe internet + tailnet, decide via Get-WatchdogAction, act.
# Cadence is provided by the AG Tailscale Watchdog scheduled task. ASCII only.
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'

$BaseDir    = Join-Path $env:ProgramData 'ag-admin'
$CorePath   = Join-Path $BaseDir 'watchdog-core.ps1'
$ConfigPath = Join-Path $BaseDir 'tailscale-watchdog.config.json'
$StatePath  = Join-Path $BaseDir 'tailscale-watchdog.state.json'
$LogPath    = Join-Path $BaseDir 'tailscale-watchdog.log'

. $CorePath
# Set AFTER dot-sourcing: watchdog-core.ps1 also assigns $Script:Revision, so
# stamping it before the dot-source gets clobbered to "" (logs showed empty "[]").
$Script:Revision = "70a11c5"

function Write-WatchdogLog {
    param([string]$Message)
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Script:Revision, $Message
    Add-Content -Path $LogPath -Value $line
    $lines = @(Get-Content -Path $LogPath -ErrorAction SilentlyContinue)
    if ($lines.Count -gt 1000) { $lines[-1000..-1] | Set-Content -Path $LogPath }
}

function Get-WatchdogConfig {
    if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
    $raw = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    return @{
        heartbeatUrl                     = $raw.heartbeatUrl
        anchors                          = @($raw.anchors)
        minRestartGapMinutes             = [int]$raw.minRestartGapMinutes
        maxRestartsPerHour               = [int]$raw.maxRestartsPerHour
        consecutiveFailuresBeforeRestart = [int]$raw.consecutiveFailuresBeforeRestart
    }
}

function Get-WatchdogStateFile {
    if (Test-Path $StatePath) {
        try {
            $raw = Get-Content -Path $StatePath -Raw | ConvertFrom-Json
            return [pscustomobject]@{
                ConsecutiveFailures = [int]$raw.ConsecutiveFailures
                LastRestartEpoch    = [long]$raw.LastRestartEpoch
                RestartEpochs       = @($raw.RestartEpochs)
            }
        } catch { return (New-WatchdogState) }
    }
    return (New-WatchdogState)
}

function Save-WatchdogState {
    param([pscustomobject]$State)
    $State | ConvertTo-Json -Depth 4 | Set-Content -Path $StatePath
}

function Test-TcpConnect {
    # Hard-bounded TCP connect. Test-NetConnection has no usable timeout and can
    # hang for minutes (or longer, behind a wedged WinHTTP/WPAD path) on a broken
    # stack; BeginConnect + WaitOne caps the wait so a cycle can never block
    # indefinitely while probing connectivity. (AG-47)
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

function Test-OutboundConnectivity {
    foreach ($t in @(@{H='1.1.1.1';P=443}, @{H='8.8.8.8';P=443})) {
        if (Test-TcpConnect -ComputerName $t.H -Port $t.P -TimeoutMs 3000) { return $true }
    }
    return $false
}

function Test-TailnetHealthy {
    param([string[]]$Anchors)
    $cmd = Get-Command tailscale -ErrorAction SilentlyContinue
    $exe = if ($cmd) { $cmd.Path } else { 'C:\Program Files\Tailscale\tailscale.exe' }
    foreach ($a in $Anchors) {
        try {
            $out = & $exe ping --timeout 3s -c 1 $a 2>&1
            if ($LASTEXITCODE -eq 0 -and ($out -match 'pong')) { return $true }
        } catch {}
    }
    return $false
}

$config   = Get-WatchdogConfig
$state    = Get-WatchdogStateFile
$now      = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$internet = Test-OutboundConnectivity
$tailnet  = if ($internet) { Test-TailnetHealthy -Anchors $config.anchors } else { $false }
$hasHb    = [bool]$config.heartbeatUrl

$decision = Get-WatchdogAction -InternetUp $internet -TailnetUp $tailnet -HasHeartbeat $hasHb -State $state -Config $config -NowEpoch $now
Write-WatchdogLog ("internet={0} tailnet={1} action={2} ({3})" -f $internet, $tailnet, $decision.Action, $decision.Reason)

if ($DryRun) {
    Write-WatchdogLog "DRYRUN: action not performed"
    return
}

switch ($decision.Action) {
    'beat' {
        try { Invoke-RestMethod -Uri $config.heartbeatUrl -TimeoutSec 10 | Out-Null }
        catch { Write-WatchdogLog "heartbeat ping failed: $($_.Exception.Message)" }
    }
    'restart' {
        Write-WatchdogLog "restarting Tailscale service"
        try { Restart-Service -Name Tailscale -Force -ErrorAction Stop }
        catch { Write-WatchdogLog "restart failed: $($_.Exception.Message)" }
    }
    default { }
}

Save-WatchdogState -State $decision.State
