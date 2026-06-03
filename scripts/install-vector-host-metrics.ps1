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
$Script:Revision = ""

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

# NOTE: Confirm the sink (ingest host, codec, and metrics vs logs handling) against
# the working AMG-402 sage-amg Vector setup before relying on this in production.
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
