#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs standard workstation applications via winget.

.DESCRIPTION
    Installs:
      - Google Chrome
      - Adobe Acrobat Reader DC (no McAfee)
      - Zoiper 5 Free (VoIP softphone)
      - Slack

    Uses winget for version-stable installs. Skips anything already installed.

.EXAMPLE
    .\install-apps.ps1
#>

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Script:Revision = "7cdbfc4"

Write-Host "install-apps.ps1 rev $Script:Revision" -ForegroundColor DarkGray

# Check if this is the latest version
try {
    $commits = Invoke-RestMethod -Uri "https://api.github.com/repos/ameriglide/it-admin/commits?per_page=2" -ErrorAction Stop
    $parentSha = $commits[1].sha.Substring(0, 7)
    if ($Script:Revision -ne "dev" -and $parentSha -ne $Script:Revision) {
        Write-Host ""
        Write-Host "  WARNING: You are running rev $Script:Revision but the latest is $parentSha" -ForegroundColor Red
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

Write-Host "Using winget $(winget --version)" -ForegroundColor DarkGray
Write-Host ""

$apps = @(
    @{ Name = "Google Chrome";       Id = "Google.Chrome" },
    @{ Name = "Adobe Acrobat Reader"; Id = "Adobe.Acrobat.Reader.64-bit" },
    @{ Name = "Zoiper 5";            Id = "Zoiper.Zoiper5" },
    @{ Name = "Slack";               Id = "SlackTechnologies.Slack" }
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

Write-Host "========================================" -ForegroundColor Green
Write-Host "  App installation complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
