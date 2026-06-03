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
}
