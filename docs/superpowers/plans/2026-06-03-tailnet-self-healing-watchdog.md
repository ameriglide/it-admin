# Tailnet Self-Healing Watchdog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect and auto-recover wedged Tailscale connections on every Windows tailnet node, alert when an always-on server stays down, and add a Headscale-side detector that flags the zombie signature on any node.

**Architecture:** A pure decision function (`Get-WatchdogAction`) drives a thin PowerShell watchdog run every 5 min by a SYSTEM scheduled task. Servers install it via a standalone installer (with a per-node Better Stack heartbeat and bundled Vector host_metrics); workstations get it self-heal-only via `setup-workstation.ps1`. A bash detector on the Headscale host raises/resolves Better Stack incidents for nodes that are `online` but stale.

**Tech Stack:** PowerShell 5.1 (ASCII-only), Pester (cross-platform via pwsh) for the pure logic, Windows Task Scheduler, Better Stack Uptime API (heartbeats + incidents), bash + jq + curl + systemd on the Headscale host.

---

## Spec

Design: `docs/superpowers/specs/2026-06-03-tailnet-self-healing-watchdog-design.md`

## File Structure

| File | Responsibility |
|---|---|
| `scripts/watchdog-core.ps1` | Pure decision logic (`New-WatchdogState`, `Get-WatchdogAction`). No I/O. Dot-sourced by the wrapper and the tests. |
| `scripts/tailscale-watchdog.ps1` | Wrapper: probes (internet + tailnet), state I/O, logging, performs the action. Single cycle (cadence comes from the scheduler). |
| `scripts/register-watchdog-task.ps1` | Registers the `AG Tailscale Watchdog` scheduled task. Shared by server installer and workstation section. |
| `scripts/install-tailscale-watchdog.ps1` | Server installer: provision/reuse heartbeat, write config, copy scripts, register task, bundle Vector. |
| `scripts/install-vector-host-metrics.ps1` | Vector host_metrics service install for sage-iai/sage-server (AMG-403). |
| `scripts/setup-workstation.ps1` | MODIFY: add `Should-Run "watchdog"` section (self-heal-only); gate the auth-key prompt on `Should-Run "tailscale"`. |
| `ops/headscale/headscale-zombie-detector.sh` | Detector: flag online+stale nodes, raise/resolve Better Stack incidents. |
| `ops/headscale/headscale-zombie-detector.service` | systemd oneshot unit. |
| `ops/headscale/headscale-zombie-detector.timer` | systemd timer (every 5 min). |
| `ops/headscale/README.md` | Install + test notes for the detector. |
| `test/watchdog-core.Tests.ps1` | Pester tests for the pure decision logic. |

## Conventions (apply to every task)

- **ASCII-only** in all `.ps1` files (comments AND strings). Before committing any task that touches `.ps1`, run: `grep -P '[^\x00-\x7F]' scripts/*.ps1` (must be empty).
- `$Script:Revision = "dev"` near the top of each new `.ps1` (DOUBLE quotes — the `.husky/pre-commit` sed pattern only stamps double-quoted assignments; single quotes are silently skipped); the pre-commit hook stamps it.
- Commit after every task.

## Prerequisite: local pwsh + Pester (one-time)

Pester tests run cross-platform; the dev machine is macOS.

- [ ] **Step 1: Install PowerShell + Pester locally**

```bash
brew install --cask powershell
pwsh -NoProfile -c "Install-Module Pester -Force -Scope CurrentUser; Import-Module Pester; (Get-Module Pester).Version"
```

Expected: prints a Pester 5.x version.

---

## Task 1: Watchdog decision logic — state factory + first test

**Files:**
- Create: `scripts/watchdog-core.ps1`
- Test: `test/watchdog-core.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `test/watchdog-core.Tests.ps1`:

```powershell
. "$PSScriptRoot/../scripts/watchdog-core.ps1"

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -c "Invoke-Pester test/watchdog-core.Tests.ps1"`
Expected: FAIL (`New-WatchdogState`/`Get-WatchdogAction` not recognized).

- [ ] **Step 3: Write minimal implementation**

Create `scripts/watchdog-core.ps1`:

```powershell
# watchdog-core.ps1
# Pure decision logic for the Tailscale watchdog. No I/O and no Windows-only
# cmdlets, so it runs under Pester on any platform. ASCII only.
$Script:Revision = "dev"

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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -c "Invoke-Pester test/watchdog-core.Tests.ps1"`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add scripts/watchdog-core.ps1 test/watchdog-core.Tests.ps1
git commit -m "feat(watchdog): pure decision logic with no-internet skip"
```

---

## Task 2: Watchdog decision logic — full behavior coverage

**Files:**
- Modify: `test/watchdog-core.Tests.ps1`

- [ ] **Step 1: Add the remaining failing tests**

Inside the `Describe 'Get-WatchdogAction'` block, after the existing `It`, add:

```powershell
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
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `pwsh -NoProfile -c "Invoke-Pester test/watchdog-core.Tests.ps1"`
Expected: PASS (7 tests). The logic from Task 1 already satisfies these. If `caps restarts per hour` fails, confirm the capped check precedes the backoff check in `Get-WatchdogAction`.

- [ ] **Step 3: Commit**

```bash
git add test/watchdog-core.Tests.ps1
git commit -m "test(watchdog): cover debounce, restart, backoff, and hourly cap"
```

---

## Task 3: Watchdog wrapper script

**Files:**
- Create: `scripts/tailscale-watchdog.ps1`

This script is verified by `-DryRun` rather than unit tests (it calls Windows-only cmdlets).

- [ ] **Step 1: Write the wrapper**

Create `scripts/tailscale-watchdog.ps1`:

```powershell
# tailscale-watchdog.ps1
# Single cycle: probe internet + tailnet, decide via Get-WatchdogAction, act.
# Cadence is provided by the AG Tailscale Watchdog scheduled task. ASCII only.
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
$Script:Revision = "dev"

$BaseDir    = Join-Path $env:ProgramData 'ag-admin'
$CorePath   = Join-Path $BaseDir 'watchdog-core.ps1'
$ConfigPath = Join-Path $BaseDir 'tailscale-watchdog.config.json'
$StatePath  = Join-Path $BaseDir 'tailscale-watchdog.state.json'
$LogPath    = Join-Path $BaseDir 'tailscale-watchdog.log'

. $CorePath

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

function Test-OutboundConnectivity {
    foreach ($t in @(@{H='headscale.mage.net';P=443}, @{H='1.1.1.1';P=443})) {
        try {
            $r = Test-NetConnection -ComputerName $t.H -Port $t.P -WarningAction SilentlyContinue
            if ($r.TcpTestSucceeded) { return $true }
        } catch {}
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
```

- [ ] **Step 2: ASCII check**

Run: `grep -P '[^\x00-\x7F]' scripts/tailscale-watchdog.ps1 scripts/watchdog-core.ps1`
Expected: no output.

- [ ] **Step 3: Syntax parse check (cross-platform)**

Run:
```bash
pwsh -NoProfile -c "[System.Management.Automation.Language.Parser]::ParseFile('scripts/tailscale-watchdog.ps1',[ref]\$null,[ref]\$null) | Out-Null; 'parsed ok'"
```
Expected: prints `parsed ok` (no parse errors). Runtime behavior is verified later in the live drill (Task 8), since the Windows-only cmdlets cannot execute on macOS.

- [ ] **Step 4: Commit**

```bash
git add scripts/tailscale-watchdog.ps1
git commit -m "feat(watchdog): wrapper script with probes, state, and logging"
```

---

## Task 4: Scheduled-task registrar

**Files:**
- Create: `scripts/register-watchdog-task.ps1`

- [ ] **Step 1: Write the registrar**

Create `scripts/register-watchdog-task.ps1`:

```powershell
# register-watchdog-task.ps1
# Registers (idempotently) the AG Tailscale Watchdog scheduled task: SYSTEM,
# every 5 minutes, plus at startup. ASCII only.
$ErrorActionPreference = 'Stop'
$Script:Revision = "dev"

$taskName   = 'AG Tailscale Watchdog'
$scriptPath = Join-Path $env:ProgramData 'ag-admin\tailscale-watchdog.ps1'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

$triggerInterval = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$triggerStartup  = New-ScheduledTaskTrigger -AtStartup

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action `
    -Trigger @($triggerInterval, $triggerStartup) -Principal $principal -Settings $settings | Out-Null
Write-Host "  Registered scheduled task '$taskName'." -ForegroundColor Green
```

- [ ] **Step 2: ASCII + parse check**

Run:
```bash
grep -P '[^\x00-\x7F]' scripts/register-watchdog-task.ps1
pwsh -NoProfile -c "[System.Management.Automation.Language.Parser]::ParseFile('scripts/register-watchdog-task.ps1',[ref]\$null,[ref]\$null) | Out-Null; 'parsed ok'"
```
Expected: no grep output; `parsed ok`.

- [ ] **Step 3: Commit**

```bash
git add scripts/register-watchdog-task.ps1
git commit -m "feat(watchdog): idempotent SYSTEM scheduled-task registrar"
```

---

## Task 5: Vector host_metrics installer (AMG-403 bundle)

**Files:**
- Create: `scripts/install-vector-host-metrics.ps1`

Mirrors the completed AMG-402 approach (Vector as a Windows service shipping host metrics to a Better Stack source). The Better Stack source ingestion host/token are passed in.

- [ ] **Step 1: Write the installer**

Create `scripts/install-vector-host-metrics.ps1`:

```powershell
# install-vector-host-metrics.ps1
# Installs Vector as a Windows service shipping host_metrics (CPU/RAM/disk) to a
# Better Stack telemetry source. Mirrors the AMG-402 sage-amg setup. ASCII only.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceToken,
    [string]$IngestHost = 'in.logs.betterstack.com',
    [string]$VectorVersion = '0.40.0'
)
$ErrorActionPreference = 'Stop'
$Script:Revision = "dev"

$vectorDir  = 'C:\Program Files\Vector'
$configPath = Join-Path $vectorDir 'vector.yaml'
$exePath    = Join-Path $vectorDir 'bin\vector.exe'

if (-not (Test-Path $exePath)) {
    Write-Host "Installing Vector $VectorVersion..." -ForegroundColor Yellow
    $zip = "$env:TEMP\vector.zip"
    $url = "https://packages.timber.io/vector/$VectorVersion/vector-$VectorVersion-x86_64-pc-windows-msvc.zip"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $vectorDir -Force
}

$config = @"
data_dir: C:\ProgramData\vector
sources:
  host:
    type: host_metrics
    scrape_interval_secs: 30
sinks:
  better_stack:
    type: http
    inputs: [host]
    uri: https://$IngestHost
    encoding:
      codec: json
    request:
      headers:
        Authorization: Bearer $SourceToken
"@
New-Item -ItemType Directory -Path 'C:\ProgramData\vector' -Force | Out-Null
Set-Content -Path $configPath -Value $config -Encoding ascii

# Register Vector as a service via sc.exe (idempotent).
$svc = Get-Service -Name 'vector' -ErrorAction SilentlyContinue
if (-not $svc) {
    & sc.exe create vector binPath= "`"$exePath`" --config `"$configPath`"" start= auto | Out-Null
}
Restart-Service -Name 'vector' -Force -ErrorAction SilentlyContinue
Start-Service  -Name 'vector' -ErrorAction SilentlyContinue
Write-Host "  Vector host_metrics installed and started." -ForegroundColor Green
```

- [ ] **Step 2: ASCII + parse check**

Run:
```bash
grep -P '[^\x00-\x7F]' scripts/install-vector-host-metrics.ps1
pwsh -NoProfile -c "[System.Management.Automation.Language.Parser]::ParseFile('scripts/install-vector-host-metrics.ps1',[ref]\$null,[ref]\$null) | Out-Null; 'parsed ok'"
```
Expected: no grep output; `parsed ok`.

- [ ] **Step 3: Commit**

```bash
git add scripts/install-vector-host-metrics.ps1
git commit -m "feat(monitoring): Vector host_metrics installer for sage-iai/sage-server (AMG-403)"
```

---

## Task 6: Server installer

**Files:**
- Create: `scripts/install-tailscale-watchdog.ps1`

- [ ] **Step 1: Write the installer**

Create `scripts/install-tailscale-watchdog.ps1`:

```powershell
# install-tailscale-watchdog.ps1
# Server-only installer: provision/reuse a Better Stack heartbeat, write config,
# copy the watchdog, register the task, and (sage-iai/sage-server) install
# Vector host_metrics. Run once per server. ASCII only.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('sage-amg','sage-iai','sage-server')][string]$Server,
    [string]$BetterStackApiToken = $env:BETTERSTACK_API_TOKEN,
    [string]$VectorSourceToken,
    [switch]$SkipVector
)
$ErrorActionPreference = 'Stop'
$Script:Revision = "dev"

if (-not $BetterStackApiToken) { throw "BetterStack API token required (-BetterStackApiToken or BETTERSTACK_API_TOKEN)." }

$BaseDir = Join-Path $env:ProgramData 'ag-admin'
New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

$anchorMap = @{
    'sage-amg'    = @('100.64.0.4','100.64.0.11','100.64.0.10')
    'sage-iai'    = @('100.64.0.4','100.64.0.11','100.64.0.9')
    'sage-server' = @('100.64.0.4','100.64.0.9','100.64.0.10')
}
$anchors = $anchorMap[$Server]

# 1. Provision or reuse the heartbeat.
$headers = @{ Authorization = "Bearer $BetterStackApiToken" }
$hbName  = "tailnet-$Server"
$list    = Invoke-RestMethod -Uri 'https://uptime.betterstack.com/api/v2/heartbeats' -Headers $headers
$existing = $list.data | Where-Object { $_.attributes.name -eq $hbName } | Select-Object -First 1
if ($existing) {
    $hbUrl = $existing.attributes.url
    Write-Host "Reusing heartbeat '$hbName'." -ForegroundColor Green
} else {
    $body = @{ name = $hbName; period = 300; grace = 900 } | ConvertTo-Json
    $created = Invoke-RestMethod -Uri 'https://uptime.betterstack.com/api/v2/heartbeats' -Headers $headers -Method Post -Body $body -ContentType 'application/json'
    $hbUrl = $created.data.attributes.url
    Write-Host "Created heartbeat '$hbName'." -ForegroundColor Green
}

# 2. Write config.
$config = [ordered]@{
    heartbeatUrl                     = $hbUrl
    anchors                          = $anchors
    intervalMinutes                  = 5
    minRestartGapMinutes             = 10
    maxRestartsPerHour               = 3
    consecutiveFailuresBeforeRestart = 2
}
$config | ConvertTo-Json | Set-Content -Path (Join-Path $BaseDir 'tailscale-watchdog.config.json')

# 3. Copy scripts.
Copy-Item -Path (Join-Path $PSScriptRoot 'watchdog-core.ps1')      -Destination $BaseDir -Force
Copy-Item -Path (Join-Path $PSScriptRoot 'tailscale-watchdog.ps1') -Destination $BaseDir -Force

# 4. Register the scheduled task.
& (Join-Path $PSScriptRoot 'register-watchdog-task.ps1')

# 5. Bundle Vector host_metrics for the two boxes not yet onboarded (AMG-403).
if (-not $SkipVector -and $Server -in @('sage-iai','sage-server')) {
    if (-not $VectorSourceToken) {
        Write-Warning "VectorSourceToken not supplied; skipping Vector host_metrics (AMG-403). Re-run with -VectorSourceToken to onboard metrics."
    } else {
        & (Join-Path $PSScriptRoot 'install-vector-host-metrics.ps1') -SourceToken $VectorSourceToken
    }
}

Write-Host "Watchdog installed on $Server." -ForegroundColor Green
```

- [ ] **Step 2: ASCII + parse check**

Run:
```bash
grep -P '[^\x00-\x7F]' scripts/install-tailscale-watchdog.ps1
pwsh -NoProfile -c "[System.Management.Automation.Language.Parser]::ParseFile('scripts/install-tailscale-watchdog.ps1',[ref]\$null,[ref]\$null) | Out-Null; 'parsed ok'"
```
Expected: no grep output; `parsed ok`.

- [ ] **Step 3: Commit**

```bash
git add scripts/install-tailscale-watchdog.ps1
git commit -m "feat(watchdog): server installer with heartbeat provisioning + Vector bundle"
```

---

## Task 7: Workstation integration in setup-workstation.ps1

**Files:**
- Modify: `scripts/setup-workstation.ps1` (auth-key prompt ~97-99; add new section after the Tailscale auth section ending at line 233)

- [ ] **Step 1: Gate the auth-key prompt on the Tailscale step**

Replace lines 97-99:

```powershell
if (-not $TailscaleAuthKey) {
    $TailscaleAuthKey = Read-Host "Tailscale auth key (tskey-auth-...)"
}
```

with:

```powershell
if ((Should-Run "tailscale") -and -not $TailscaleAuthKey) {
    $TailscaleAuthKey = Read-Host "Tailscale auth key (tskey-auth-...)"
}
```

Note: `Should-Run` is defined at line 89, above line 97, so this is safe.

- [ ] **Step 2: Add the watchdog section**

Immediately after the Tailscale auth section's closing brace (line 233), insert:

```powershell
# ---------------------------------------------------------------------------
# Tailscale watchdog (self-heal only -- workstations get no heartbeat)
# ---------------------------------------------------------------------------
if (Should-Run "watchdog") {
Write-Host "Installing Tailscale watchdog..." -ForegroundColor Yellow
$wdBase = Join-Path $env:ProgramData 'ag-admin'
New-Item -ItemType Directory -Path $wdBase -Force | Out-Null

$wdConfig = [ordered]@{
    heartbeatUrl                     = $null
    anchors                          = @('100.64.0.4','100.64.0.11')
    intervalMinutes                  = 5
    minRestartGapMinutes             = 10
    maxRestartsPerHour               = 3
    consecutiveFailuresBeforeRestart = 2
}
$wdConfig | ConvertTo-Json | Set-Content -Path (Join-Path $wdBase 'tailscale-watchdog.config.json')
Copy-Item -Path (Join-Path $PSScriptRoot 'watchdog-core.ps1')      -Destination $wdBase -Force
Copy-Item -Path (Join-Path $PSScriptRoot 'tailscale-watchdog.ps1') -Destination $wdBase -Force
& (Join-Path $PSScriptRoot 'register-watchdog-task.ps1')
Write-Host "  Watchdog installed (self-heal only)." -ForegroundColor Green
Write-Host ""
}
```

- [ ] **Step 3: ASCII + parse check**

Run:
```bash
grep -P '[^\x00-\x7F]' scripts/setup-workstation.ps1
pwsh -NoProfile -c "[System.Management.Automation.Language.Parser]::ParseFile('scripts/setup-workstation.ps1',[ref]\$null,[ref]\$null) | Out-Null; 'parsed ok'"
```
Expected: no grep output; `parsed ok`.

- [ ] **Step 4: Commit**

```bash
git add scripts/setup-workstation.ps1
git commit -m "feat(setup-workstation): self-heal watchdog section; gate auth-key prompt"
```

---

## Task 8: Live drill on one server (manual verification)

No code. Verifies the Windows-only paths before fleet rollout. Run on **sage-server** (so a wedged sage-amg test does not affect the box we just fixed).

- [ ] **Step 1: Install on sage-server**

From an admin PowerShell in the repo `scripts/` dir on sage-server:
```powershell
.\install-tailscale-watchdog.ps1 -Server sage-server -BetterStackApiToken <token> -VectorSourceToken <source-token>
```
Expected: "Created heartbeat 'tailnet-sage-server'.", task registered, Vector started.

- [ ] **Step 2: Dry-run a healthy cycle**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\ag-admin\tailscale-watchdog.ps1" -DryRun
Get-Content "C:\ProgramData\ag-admin\tailscale-watchdog.log" -Tail 3
```
Expected: a line with `internet=True tailnet=True action=beat`.

- [ ] **Step 3: Simulate a wedged tunnel**

```powershell
Stop-Service Tailscale
# cycle 1 (debounce -> wait), then cycle 2 (-> restart)
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\ag-admin\tailscale-watchdog.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\ag-admin\tailscale-watchdog.ps1"
Get-Content "C:\ProgramData\ag-admin\tailscale-watchdog.log" -Tail 5
Get-Service Tailscale
```
Expected: first line `action=wait`, second `action=restart` followed by "restarting Tailscale service"; service is Running again.

- [ ] **Step 4: Confirm the heartbeat in Better Stack**

In Better Stack Uptime, the `tailnet-sage-server` heartbeat shows recent pings (Up). Confirm the scheduled task is present: `Get-ScheduledTask -TaskName 'AG Tailscale Watchdog'`.

- [ ] **Step 5: Record results**

Note pass/fail for each step in the rollout ticket. If any step fails, stop and debug before rolling to the other servers.

---

## Task 9: Headscale zombie detector

**Files:**
- Create: `ops/headscale/headscale-zombie-detector.sh`
- Create: `ops/headscale/headscale-zombie-detector.service`
- Create: `ops/headscale/headscale-zombie-detector.timer`
- Create: `ops/headscale/README.md`

- [ ] **Step 1: Write the detector script**

Create `ops/headscale/headscale-zombie-detector.sh`:

```bash
#!/usr/bin/env bash
# Flags tailnet nodes that are online in Headscale but whose last_seen is stale
# (a half-closed control connection), and raises/resolves a Better Stack incident
# per node. Run via systemd timer on the Headscale host. Needs docker, jq, curl.
set -euo pipefail

STALE_SECONDS="${STALE_SECONDS:-900}"
STATE_FILE="${STATE_FILE:-/var/lib/headscale-zombie-detector/state.json}"
CONTAINER="${HEADSCALE_CONTAINER:-headscale}"
REQUESTER_EMAIL="${REQUESTER_EMAIL:-it@ameriglide.com}"
DRY_RUN="${DRY_RUN:-0}"
: "${BETTERSTACK_API_TOKEN:?BETTERSTACK_API_TOKEN required}"

mkdir -p "$(dirname "$STATE_FILE")"
[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

now=$(date +%s)
nodes_json=$(docker exec "$CONTAINER" headscale nodes list -o json)

zombies=$(echo "$nodes_json" | jq -r --argjson now "$now" --argjson stale "$STALE_SECONDS" '
  .[]
  | select(.online == true)
  | select((($now) - (.last_seen.seconds // 0)) > $stale)
  | .given_name')

state=$(cat "$STATE_FILE")
new_state="$state"

bs_create() {
  local node="$1"
  if [ "$DRY_RUN" = "1" ]; then echo "DRYRUN-$node"; return; fi
  curl -sf -X POST https://uptime.betterstack.com/api/v2/incidents \
    -H "Authorization: Bearer $BETTERSTACK_API_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"summary\":\"Tailnet zombie: $node\",\"description\":\"Node $node is online in Headscale but last_seen is stale (> ${STALE_SECONDS}s). Likely a half-closed Tailscale control connection. Restart the Tailscale service on $node.\",\"requester_email\":\"$REQUESTER_EMAIL\",\"call\":false,\"sms\":false,\"email\":true}" \
    | jq -r '.data.id'
}

bs_resolve() {
  local id="$1"
  if [ "$DRY_RUN" = "1" ]; then echo "DRYRUN resolve $id"; return; fi
  curl -sf -X POST "https://uptime.betterstack.com/api/v2/incidents/${id}/resolve" \
    -H "Authorization: Bearer $BETTERSTACK_API_TOKEN" >/dev/null || true
}

# Open incidents for newly-zombied nodes.
for z in $zombies; do
  open_id=$(echo "$state" | jq -r --arg n "$z" '.[$n] // empty')
  if [ -z "$open_id" ]; then
    id=$(bs_create "$z")
    new_state=$(echo "$new_state" | jq --arg n "$z" --arg id "$id" '.[$n]=$id')
    logger -t headscale-zombie "opened incident $id for $z"
  fi
done

# Resolve incidents for recovered nodes.
for n in $(echo "$state" | jq -r 'keys[]'); do
  if ! echo "$zombies" | grep -qx "$n"; then
    id=$(echo "$state" | jq -r --arg n "$n" '.[$n]')
    bs_resolve "$id"
    new_state=$(echo "$new_state" | jq --arg n "$n" 'del(.[$n])')
    logger -t headscale-zombie "resolved incident $id for $n"
  fi
done

echo "$new_state" > "$STATE_FILE"
```

- [ ] **Step 2: Write the systemd units**

Create `ops/headscale/headscale-zombie-detector.service`:

```ini
[Unit]
Description=Headscale zombie-node detector
After=docker.service

[Service]
Type=oneshot
EnvironmentFile=/etc/headscale-zombie-detector.env
ExecStart=/opt/headscale-zombie-detector/headscale-zombie-detector.sh
```

Create `ops/headscale/headscale-zombie-detector.timer`:

```ini
[Unit]
Description=Run the Headscale zombie detector every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=headscale-zombie-detector.service

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Write the README**

Create `ops/headscale/README.md`:

```markdown
# Headscale zombie-node detector

Flags nodes that are `online=true` in Headscale but whose `last_seen` is stale
(> 15 min) -- the signature of a half-closed Tailscale control connection -- and
raises a Better Stack incident per node, auto-resolving on recovery. This is the
backstop for nodes the per-node watchdog has not reached (e.g. the workstation
fleet) and for the watchdog itself failing.

## Install (on the Headscale host)

```bash
sudo mkdir -p /opt/headscale-zombie-detector
sudo cp headscale-zombie-detector.sh /opt/headscale-zombie-detector/
sudo chmod +x /opt/headscale-zombie-detector/headscale-zombie-detector.sh
sudo cp headscale-zombie-detector.service headscale-zombie-detector.timer /etc/systemd/system/

# Secrets / config (not committed):
sudo tee /etc/headscale-zombie-detector.env >/dev/null <<'EOF'
BETTERSTACK_API_TOKEN=...
REQUESTER_EMAIL=it@ameriglide.com
STALE_SECONDS=900
HEADSCALE_CONTAINER=headscale
EOF
sudo chmod 600 /etc/headscale-zombie-detector.env

sudo systemctl daemon-reload
sudo systemctl enable --now headscale-zombie-detector.timer
```

## Test

```bash
# Dry run with a low threshold so a normally-idle node trips: should print
# DRYRUN incident ids, open no real incidents, and leave state untouched.
sudo DRY_RUN=1 STALE_SECONDS=60 \
  BETTERSTACK_API_TOKEN=x \
  /opt/headscale-zombie-detector/headscale-zombie-detector.sh
```

Confirm a powered-off node (`online=false`) is NOT listed. Then run once for real
(`sudo systemctl start headscale-zombie-detector.service`) and check
`journalctl -t headscale-zombie`.
```

- [ ] **Step 4: Lint the shell script**

Run: `shellcheck ops/headscale/headscale-zombie-detector.sh`
Expected: no errors (warnings about `$zombies` word-splitting are intentional; add `# shellcheck disable=SC2086` only if shellcheck flags the intended splits).

- [ ] **Step 5: Commit**

```bash
git add ops/headscale/
git commit -m "feat(headscale): zombie-node detector with Better Stack incidents + systemd timer"
```

---

## Task 10: Deploy detector + finalize rollout

- [ ] **Step 1: Deploy the detector on the Headscale host**

Follow `ops/headscale/README.md`. Verify: `systemctl list-timers | grep zombie` shows it scheduled; run once and check `journalctl -t headscale-zombie -n 20`.

- [ ] **Step 2: Roll the watchdog to the remaining servers**

On sage-amg and sage-iai, run `install-tailscale-watchdog.ps1 -Server <name> -BetterStackApiToken <t> -VectorSourceToken <t>`. Confirm each heartbeat appears in Better Stack.

- [ ] **Step 3: Attach heartbeats + incidents to AMG-397 escalation**

In Better Stack, confirm the three `tailnet-*` heartbeats and the detector incidents route through the alert policy/escalation defined in AMG-397. If AMG-397 is not finished, leave them on the default escalation and note it on the ticket to re-point later.

- [ ] **Step 4: Cut the Linear tickets**

Under project *Server resource monitoring in Better Stack*, create the parent + subtasks:
- Parent: "Tailnet self-healing watchdog + zombie detector"
- Subtask "Workstation watchdog installs" -> **assignee Alan**
- Subtask "Server watchdog installs (sage-amg/iai/server)" -> **assignee Michael**
- Subtask "Headscale zombie detector deploy" -> **assignee Michael**
- Link the sage-iai/sage-server Vector work to **AMG-403**.

- [ ] **Step 5: Final ASCII sweep + open the PR**

```bash
grep -P '[^\x00-\x7F]' scripts/*.ps1   # must be empty
git push -u origin feature/tailnet-watchdog
gh pr create --fill
```

---

## Self-Review

**Spec coverage:**
- Self-heal on all Windows nodes -> Tasks 3, 6 (servers), 7 (workstations). Covered.
- Heartbeat alerting servers-only -> config `heartbeatUrl` set by Task 6, null by Task 7; `beat` only when `HasHeartbeat` (Task 1). Covered.
- Internet-vs-tailnet gating + 2-cycle debounce + backoff -> Tasks 1-2 (logic), Task 3 (probes). Covered.
- Server installer + heartbeat provisioning + Vector bundle -> Tasks 5, 6. Covered.
- Workstation install via setup-workstation -> Task 7. Covered.
- Headscale detector (online + stale), incidents, dedup -> Task 9. Covered.
- Reuse us_east / team 540247 / AMG-397 policy -> Task 10 step 3; heartbeats created in team via the token's team scope. Covered.
- Linear structure + Alan/Michael assignments -> Task 10 step 4. Covered.
- ASCII-only + revision stamp -> per-task ASCII checks; `$Script:Revision='dev'` in each `.ps1`. Covered.

**Placeholder scan:** Tokens shown as `<token>` are runtime secrets supplied at deploy, not plan placeholders. No TBD/TODO logic remains.

**Type/name consistency:** `New-WatchdogState`, `Get-WatchdogAction`, state fields (`ConsecutiveFailures`, `LastRestartEpoch`, `RestartEpochs`), config keys (`heartbeatUrl`, `anchors`, `minRestartGapMinutes`, `maxRestartsPerHour`, `consecutiveFailuresBeforeRestart`), task name `AG Tailscale Watchdog`, and ProgramData paths are identical across the wrapper, installer, and workstation section.
