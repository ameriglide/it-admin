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
