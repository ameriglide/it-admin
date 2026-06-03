BeforeAll {
    . "$PSScriptRoot/../scripts/watchdog-core.ps1"
}

Describe 'Get-WatchdogAction' {
    BeforeAll {
        $script:cfg = @{ consecutiveFailuresBeforeRestart = 2; minRestartGapMinutes = 10; maxRestartsPerHour = 3 }
        $script:now = 1000000
    }

    It 'skips when there is no internet' {
        $s = New-WatchdogState
        $r = Get-WatchdogAction -InternetUp $false -TailnetUp $false -HasHeartbeat $true -State $s -Config $cfg -NowEpoch $now
        $r.Action | Should -Be 'skip'
    }

    It 'beats when healthy and a heartbeat is configured' {
        $s = New-WatchdogState
        $r = Get-WatchdogAction -InternetUp $true -TailnetUp $true -HasHeartbeat $true -State $s -Config $cfg -NowEpoch $now
        $r.Action | Should -Be 'beat'
        $r.State.ConsecutiveFailures | Should -Be 0
    }

    It 'is a healthy no-op when no heartbeat (workstation)' {
        $s = New-WatchdogState
        $r = Get-WatchdogAction -InternetUp $true -TailnetUp $false -HasHeartbeat $false -State $s -Config $cfg -NowEpoch $now
        # first unhealthy cycle still debounces regardless of heartbeat
        $r.Action | Should -Be 'wait'
    }

    It 'waits on the first unhealthy cycle (debounce)' {
        $s = New-WatchdogState
        $r = Get-WatchdogAction -InternetUp $true -TailnetUp $false -HasHeartbeat $true -State $s -Config $cfg -NowEpoch $now
        $r.Action | Should -Be 'wait'
        $r.State.ConsecutiveFailures | Should -Be 1
    }

    It 'restarts on the second consecutive unhealthy cycle' {
        $s = New-WatchdogState; $s.ConsecutiveFailures = 1
        $r = Get-WatchdogAction -InternetUp $true -TailnetUp $false -HasHeartbeat $true -State $s -Config $cfg -NowEpoch $now
        $r.Action | Should -Be 'restart'
        $r.State.RestartEpochs.Count | Should -Be 1
        $r.State.ConsecutiveFailures | Should -Be 0
    }

    It 'backs off within the min restart gap' {
        $s = New-WatchdogState; $s.ConsecutiveFailures = 1
        $s.LastRestartEpoch = $now - 60; $s.RestartEpochs = @($now - 60)
        $r = Get-WatchdogAction -InternetUp $true -TailnetUp $false -HasHeartbeat $true -State $s -Config $cfg -NowEpoch $now
        $r.Action | Should -Be 'backoff'
    }

    It 'caps restarts per hour' {
        $s = New-WatchdogState; $s.ConsecutiveFailures = 1
        $s.RestartEpochs = @(($now-1800), ($now-1200), ($now-700)); $s.LastRestartEpoch = $now - 700
        $r = Get-WatchdogAction -InternetUp $true -TailnetUp $false -HasHeartbeat $true -State $s -Config $cfg -NowEpoch $now
        $r.Action | Should -Be 'capped'
    }
}
