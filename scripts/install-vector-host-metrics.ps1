# install-vector-host-metrics.ps1
# Installs Vector as a Windows service shipping host_metrics (CPU/RAM/disk/network)
# to a Better Stack telemetry source. Windows counterpart to
# install-vector-host-metrics.sh; mirrors the same known-good pipeline:
# host_metrics -> metric_to_log -> remap -> http "/metrics". ASCII only.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceToken,
    # Per-source ingesting host, e.g. s2493609.us-east-9.betterstackdata.com
    # (Better Stack -> the source -> "ingesting host"). NOT in.logs.betterstack.com.
    [Parameter(Mandatory)][string]$IngestHost,
    # Tag every metric with host=<name> so a fleet dashboard can group by host.
    [string]$HostName = $env:COMPUTERNAME,
    [string]$VectorVersion = '0.49.0'
)
$ErrorActionPreference = 'Stop'
$Script:Revision = "d253733"

$vectorDir  = 'C:\Program Files\Vector'
$configPath = Join-Path $vectorDir 'vector.yaml'
$exePath    = Join-Path $vectorDir 'bin\vector.exe'

if (-not (Test-Path $exePath)) {
    Write-Host "Installing Vector $VectorVersion..." -ForegroundColor Yellow
    $zip     = "$env:TEMP\vector.zip"
    $staging = Join-Path $env:TEMP 'vector-extract'
    $url = "https://github.com/vectordotdev/vector/releases/download/v$VectorVersion/vector-$VectorVersion-x86_64-pc-windows-msvc.zip"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $staging -Force
    $found = Get-ChildItem -Path $staging -Recurse -Filter 'vector.exe' | Select-Object -First 1
    if (-not $found) { throw "vector.exe not found in the downloaded archive" }
    # Package layout is <root>\bin\vector.exe; copy the whole <root> into $vectorDir.
    $pkgRoot = Split-Path (Split-Path $found.FullName -Parent) -Parent
    New-Item -ItemType Directory -Path $vectorDir -Force | Out-Null
    Copy-Item -Path (Join-Path $pkgRoot '*') -Destination $vectorDir -Recurse -Force
}

# Pipeline mirrors the working sage-amg / Linux setup: raw host_metrics are turned
# into log events (metric_to_log), stamped with .dt + host tag (remap), then POSTed
# to the source's /metrics endpoint as gzipped JSON with bearer auth. A bare
# host_metrics -> http sink (no metric_to_log, wrong URI) silently ingests nothing.
$config = @"
data_dir: C:\ProgramData\vector

sources:
  better_stack_host_metrics:
    type: host_metrics
    scrape_interval_secs: 30
    collectors: [cpu, disk, filesystem, memory, network]

transforms:
  better_stack_host_metrics_log:
    type: metric_to_log
    inputs: ["better_stack_host_metrics"]
  better_stack_host_metrics_parser:
    type: remap
    inputs: ["better_stack_host_metrics_log"]
    source: |
      del(.source_type)
      .dt = del(.timestamp)
      .tags.host = "$HostName"

sinks:
  better_stack_metrics:
    type: http
    method: post
    inputs: ["better_stack_host_metrics_parser"]
    uri: "https://$IngestHost/metrics"
    encoding:
      codec: json
    compression: gzip
    auth:
      strategy: bearer
      token: "$SourceToken"
"@
New-Item -ItemType Directory -Path 'C:\ProgramData\vector' -Force | Out-Null
Set-Content -Path $configPath -Value $config -Encoding ascii

# Fail loudly on a bad config rather than registering a service that crash-loops.
& $exePath validate $configPath
if ($LASTEXITCODE -ne 0) { throw "vector validate failed for $configPath" }

# Register Vector as a service (idempotent). New-Service handles the quoting of a
# spaced binary path + args cleanly; sc.exe's "binPath= " form is brittle and was
# silently failing (exit 1639) under PowerShell's native-arg passing.
$binaryPath = '"{0}" --config "{1}"' -f $exePath, $configPath
$svc = Get-Service -Name 'vector' -ErrorAction SilentlyContinue
if (-not $svc) {
    New-Service -Name 'vector' -DisplayName 'Vector (Better Stack host metrics)' `
        -BinaryPathName $binaryPath -StartupType Automatic | Out-Null
}
Restart-Service -Name 'vector' -Force
Write-Host "  Vector host_metrics installed and started -> https://$IngestHost/metrics" -ForegroundColor Green
