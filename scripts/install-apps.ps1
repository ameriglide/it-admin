#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs standard workstation applications.

.DESCRIPTION
    Installs via winget:
      - Google Chrome
      - Adobe Acrobat Reader DC
      - Slack
      - Tailscale

    Installs via Chocolatey:
      - Zoiper 5 Free (not available on winget)

    Skips anything already installed.

.EXAMPLE
    .\install-apps.ps1
#>

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
# Stamped by pre-commit hook -- do not edit manually
$Script:Revision = "9b4ff0a"

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

# Check winget is available
$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Error "winget is not available on this machine. Install App Installer from the Microsoft Store."
    exit 1
}

# Reset winget source on first run / fresh machines
$testResult = winget search --id Microsoft.Edge --accept-source-agreements 2>&1
if ($testResult -match "0x8a15000f|Data required by the source is missing") {
    Write-Host "Initializing winget sources..." -ForegroundColor Yellow
    winget source reset --force 2>&1 | Out-Null
}

Write-Host "Using winget $(winget --version)" -ForegroundColor DarkGray
Write-Host ""

$apps = @(
    @{ Name = "Google Chrome";       Id = "Google.Chrome" },
    @{ Name = "Adobe Acrobat Reader"; Id = "Adobe.Acrobat.Reader.64-bit" },
    @{ Name = "Slack";               Id = "SlackTechnologies.Slack" },
    @{ Name = "Tailscale";           Id = "tailscale.tailscale" }
)

$total = $apps.Count
$current = 0

foreach ($app in $apps) {
    $current++
    Write-Host "[$current/$total] $($app.Name)..." -ForegroundColor Yellow

    $result = winget list --id $app.Id --accept-source-agreements 2>&1
    if ($result -match $app.Id) {
        Write-Host "  Already installed. Skipping." -ForegroundColor Green
    } else {
        Write-Host "  Installing..."
        winget install --id $app.Id --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  $($app.Name) installed." -ForegroundColor Green
        } else {
            Write-Warning "  $($app.Name) install failed (exit code $LASTEXITCODE)."
        }
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Zoiper 5 (via Chocolatey -- not available on winget)
# ---------------------------------------------------------------------------
Write-Host "Zoiper 5 (via Chocolatey)..." -ForegroundColor Yellow

$zoiperInstalled = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Zoiper*" }
if ($zoiperInstalled) {
    Write-Host "  Already installed. Skipping." -ForegroundColor Green
} else {
    # Install Chocolatey if not present
    $choco = Get-Command choco -ErrorAction SilentlyContinue
    if (-not $choco) {
        Write-Host "  Installing Chocolatey..."
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    }
    Write-Host "  Installing Zoiper 5..."
    choco install zoiper -y
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Zoiper 5 installed." -ForegroundColor Green
    } else {
        Write-Warning "  Zoiper 5 install failed (exit code $LASTEXITCODE)."
    }
}
Write-Host ""

Write-Host "========================================" -ForegroundColor Green
Write-Host "  App installation complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
