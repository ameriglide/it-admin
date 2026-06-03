# watchdog-core.ps1
# Pure decision logic for the Tailscale watchdog. No I/O and no Windows-only
# cmdlets, so it runs under Pester on any platform. ASCII only.
$Script:Revision = ""

function New-WatchdogState {
    return [pscustomobject]@{
        ConsecutiveFailures = 0
        LastRestartEpoch    = 0
        RestartEpochs       = @()
    }
}

function Get-WatchdogAction {
    param(
        [bool]$InternetUp,
        [bool]$TailnetUp,
        [bool]$HasHeartbeat,
        [pscustomobject]$State,
        [hashtable]$Config,
        [long]$NowEpoch
    )

    $next = [pscustomobject]@{
        ConsecutiveFailures = [int]$State.ConsecutiveFailures
        LastRestartEpoch    = [long]$State.LastRestartEpoch
        RestartEpochs       = @($State.RestartEpochs)
    }

    if (-not $InternetUp) {
        $next.ConsecutiveFailures = 0
        return [pscustomobject]@{ Action = 'skip'; Reason = 'no outbound internet'; State = $next }
    }

    if ($TailnetUp) {
        $next.ConsecutiveFailures = 0
        $action = if ($HasHeartbeat) { 'beat' } else { 'healthy' }
        return [pscustomobject]@{ Action = $action; Reason = 'tailnet healthy'; State = $next }
    }

    $next.ConsecutiveFailures = [int]$State.ConsecutiveFailures + 1
    $threshold = [int]$Config.consecutiveFailuresBeforeRestart
    if ($next.ConsecutiveFailures -lt $threshold) {
        return [pscustomobject]@{ Action = 'wait'; Reason = "unhealthy $($next.ConsecutiveFailures)/$threshold"; State = $next }
    }

    $hourAgo = $NowEpoch - 3600
    $recent = @($next.RestartEpochs | Where-Object { $_ -gt $hourAgo })
    $next.RestartEpochs = $recent

    if ($recent.Count -ge [int]$Config.maxRestartsPerHour) {
        return [pscustomobject]@{ Action = 'capped'; Reason = "restart cap reached ($($recent.Count)/hr)"; State = $next }
    }

    $gapSeconds = [int]$Config.minRestartGapMinutes * 60
    if ($next.LastRestartEpoch -gt 0 -and ($NowEpoch - $next.LastRestartEpoch) -lt $gapSeconds) {
        return [pscustomobject]@{ Action = 'backoff'; Reason = 'within min restart gap'; State = $next }
    }

    $next.LastRestartEpoch = $NowEpoch
    $next.RestartEpochs = @($recent + $NowEpoch)
    $next.ConsecutiveFailures = 0
    return [pscustomobject]@{ Action = 'restart'; Reason = 'tailnet down, healing'; State = $next }
}
