#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs standard workstation applications via Chocolatey.

.DESCRIPTION
    Installs:
      - Google Chrome
      - Adobe Acrobat Reader DC
      - Slack
      - Tailscale
      - Zoiper 5 Free

    Installs Chocolatey if not already present. Skips anything already installed.

.PARAMETER TailscaleAuthKey
    Pre-auth key used to join the Tailscale network after install. Required.
    If not passed as a parameter, the script will prompt for it.
    Generate one at your Headscale/Tailscale admin console.

.EXAMPLE
    .\install-apps.ps1 -TailscaleAuthKey "tskey-auth-abc123"
#>

param(
    [string]$TailscaleAuthKey
)

if (-not $TailscaleAuthKey) {
    $TailscaleAuthKey = Read-Host "Tailscale auth key (tskey-auth-...)"
}
if (-not $TailscaleAuthKey) {
    Write-Error "Tailscale auth key is required. Generate one at your Headscale admin console and re-run."
    exit 1
}

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
# Stamped by pre-commit hook -- do not edit manually
$Script:Revision = "2778d17"

Write-Host "install-apps.ps1 rev $Script:Revision" -ForegroundColor DarkGray

# Check if this is the latest version
try {
    $commits = Invoke-RestMethod -Uri "https://api.github.com/repos/ameriglide/it-admin/commits?path=scripts/install-apps.ps1&per_page=2" -ErrorAction Stop
    $knownRevs = $commits | ForEach-Object { $_.sha.Substring(0, 7) }
    if ($Script:Revision -ne "dev" -and $Script:Revision -notin $knownRevs) {
        Write-Host ""
        Write-Host "  WARNING: You are running rev $Script:Revision but the latest is $($knownRevs[0])" -ForegroundColor Red
        Write-Host "  Re-download the script to get the latest version." -ForegroundColor Red
        Write-Host ""
        $continue = Read-Host "  Press Enter to continue anyway, or Ctrl+C to abort"
    }
} catch {}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Workstation App Installer" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Install Chocolatey if not present
# ---------------------------------------------------------------------------
$choco = Get-Command choco -ErrorAction SilentlyContinue
if (-not $choco) {
    Write-Host "Installing Chocolatey..." -ForegroundColor Yellow
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    # Refresh PATH so choco is available
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    Write-Host "  Chocolatey installed." -ForegroundColor Green
} else {
    Write-Host "Using Chocolatey $(choco --version)" -ForegroundColor DarkGray
}
Write-Host ""

# ---------------------------------------------------------------------------
# Apps
# ---------------------------------------------------------------------------
$apps = @(
    @{ Name = "Google Chrome";       Id = "googlechrome" },
    @{ Name = "Adobe Acrobat Reader"; Id = "adobereader" },
    @{ Name = "Slack";               Id = "slack" },
    @{ Name = "Tailscale";           Id = "tailscale" },
    @{ Name = "Google Drive";        Id = "googledrive" }
)

$total = $apps.Count
$current = 0

foreach ($app in $apps) {
    $current++
    Write-Host "[$current/$total] $($app.Name)..." -ForegroundColor Yellow

    $installed = choco list --local-only --id-only 2>&1 | Select-String -Pattern "^$($app.Id)$" -Quiet
    if ($installed) {
        Write-Host "  Already installed. Skipping." -ForegroundColor Green
    } else {
        choco install $app.Id -y --ignore-checksums
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  $($app.Name) installed." -ForegroundColor Green
        } else {
            Write-Warning "  $($app.Name) install failed (exit code $LASTEXITCODE)."
        }
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Tailscale auth
# ---------------------------------------------------------------------------
Write-Host "Joining Tailscale network..." -ForegroundColor Yellow
# Refresh PATH so freshly-installed Tailscale CLI is discoverable
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
$tsCmd = Get-Command tailscale -ErrorAction SilentlyContinue
if (-not $tsCmd) {
    $tsPath = "C:\Program Files\Tailscale\tailscale.exe"
    if (Test-Path $tsPath) { $tsCmd = $tsPath } else { $tsCmd = $null }
} else {
    $tsCmd = $tsCmd.Path
}

if ($tsCmd) {
    & $tsCmd up --login-server https://headscale.mage.net --auth-key $TailscaleAuthKey --unattended --timeout 30s
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Joined Tailscale network." -ForegroundColor Green
    } else {
        Write-Warning "  Tailscale auth failed (exit code $LASTEXITCODE)."
    }
} else {
    Write-Warning "  Tailscale CLI not found. May require a reboot before auth."
}
Write-Host ""

# ---------------------------------------------------------------------------
# Zoiper 5 (hosted in repo -- not available on winget or choco reliably)
# ---------------------------------------------------------------------------
Write-Host "Zoiper 5..." -ForegroundColor Yellow

$zoiperInstalled = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Zoiper*" }
if ($zoiperInstalled) {
    Write-Host "  Already installed. Skipping." -ForegroundColor Green
} else {
    $zoiperExe = "$env:TEMP\Zoiper5_Installer.exe"
    Write-Host "  Downloading..."
    Invoke-WebRequest -Uri "https://github.com/ameriglide/it-admin/releases/download/v0.1.0/Zoiper5_Installer.exe" -OutFile $zoiperExe -UseBasicParsing
    Write-Host "  Installing..."
    $process = Start-Process -FilePath $zoiperExe -ArgumentList "--mode unattended --unattendedmodeui none --zoiper_alluser_installation 1" -Wait -PassThru
    if ($process.ExitCode -eq 0) {
        Write-Host "  Zoiper 5 installed." -ForegroundColor Green
    } else {
        Write-Warning "  Zoiper 5 install failed (exit code $($process.ExitCode))."
    }
}
Write-Host ""

Write-Host "========================================" -ForegroundColor Green
Write-Host "  App installation complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
