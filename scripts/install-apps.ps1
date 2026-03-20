#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs standard workstation applications silently.

.DESCRIPTION
    Downloads and installs:
      - Google Chrome (enterprise MSI)
      - Adobe Acrobat Reader DC (enterprise installer, no McAfee)
      - Zoiper 5 Free (VoIP softphone)
      - Slack (enterprise MSI)

    Skips any application that is already installed.

.EXAMPLE
    .\install-apps.ps1
#>

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Script:Revision = "00140b7"

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

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Workstation App Installer" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$installed = Get-WmiObject Win32_Product -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Name

function Test-Installed($pattern) {
    # Check WMI
    if ($installed -like $pattern) { return $true }
    # Check common registry locations
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($path in $regPaths) {
        $found = Get-ItemProperty $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $pattern }
        if ($found) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Google Chrome
# ---------------------------------------------------------------------------
Write-Host "[1/4] Google Chrome..." -ForegroundColor Yellow

if (Test-Installed "*Google Chrome*") {
    Write-Host "  Already installed. Skipping." -ForegroundColor Green
} else {
    $chromeMsi = "$env:TEMP\GoogleChromeEnterprise64.msi"
    Write-Host "  Downloading..."
    Invoke-WebRequest -Uri "https://dl.google.com/chrome/install/GoogleChromeStandaloneEnterprise64.msi" -OutFile $chromeMsi -UseBasicParsing

    Write-Host "  Installing..."
    $process = Start-Process msiexec.exe -ArgumentList "/i `"$chromeMsi`" /quiet /norestart" -Wait -PassThru
    if ($process.ExitCode -eq 0) {
        Write-Host "  Chrome installed." -ForegroundColor Green
    } else {
        Write-Warning "  Chrome install failed (exit code $($process.ExitCode))."
    }
}

# ---------------------------------------------------------------------------
# Adobe Acrobat Reader DC (enterprise -- no McAfee)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[2/4] Adobe Acrobat Reader DC..." -ForegroundColor Yellow

if (Test-Installed "*Adobe Acrobat*Reader*") {
    Write-Host "  Already installed. Skipping." -ForegroundColor Green
} else {
    # Enterprise offline installer -- no McAfee bundled
    # This URL points to the enterprise distribution page redirect
    $adobeExe = "$env:TEMP\AcroRdrDC_en_US.exe"
    Write-Host "  Downloading from Adobe enterprise distribution..."
    try {
        Invoke-WebRequest -Uri "https://ardownload2.adobe.com/pub/adobe/acrobat/win/AcrobatDC/2400920379/AcroRdrDCx642400920379_en_US.exe" -OutFile $adobeExe -UseBasicParsing
    } catch {
        Write-Warning "  Adobe direct download failed. Trying alternate URL..."
        try {
            Invoke-WebRequest -Uri "https://ardownload2.adobe.com/pub/adobe/reader/win/AcrobatDC/2400920379/AcroRdrDCx642400920379_en_US.exe" -OutFile $adobeExe -UseBasicParsing
        } catch {
            Write-Warning "  Could not download Adobe Reader. The version URL may have changed."
            Write-Warning "  Download manually from: https://get.adobe.com/reader/enterprise/"
            $adobeExe = $null
        }
    }

    if ($adobeExe -and (Test-Path $adobeExe)) {
        Write-Host "  Installing..."
        $process = Start-Process -FilePath $adobeExe -ArgumentList "/sAll /msi /norestart /quiet ALLUSERS=1 EULA_ACCEPT=YES" -Wait -PassThru
        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 1603) {
            Write-Host "  Adobe Reader installed." -ForegroundColor Green
        } else {
            Write-Warning "  Adobe Reader install exited with code $($process.ExitCode)."
        }
    }
}

# ---------------------------------------------------------------------------
# Zoiper 5 Free
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[3/4] Zoiper 5..." -ForegroundColor Yellow

if (Test-Installed "*Zoiper*") {
    Write-Host "  Already installed. Skipping." -ForegroundColor Green
} else {
    $zoiperExe = "$env:TEMP\Zoiper5_Installer.exe"
    Write-Host "  Downloading..."
    try {
        Invoke-WebRequest -Uri "https://www.zoiper.com/en/voip-softphone/download/zoiper5/for/windows" -OutFile "$env:TEMP\zoiper_page.html" -UseBasicParsing
        # The download page redirects -- use the known direct download URL
        Invoke-WebRequest -Uri "https://www.zoiper.com/downloads/zoiper5/Zoiper5_Installer.exe" -OutFile $zoiperExe -UseBasicParsing
    } catch {
        Write-Warning "  Could not download Zoiper. Download manually from: https://www.zoiper.com/en/voip-softphone/download/current"
        $zoiperExe = $null
    }

    if ($zoiperExe -and (Test-Path $zoiperExe)) {
        Write-Host "  Installing..."
        $process = Start-Process -FilePath $zoiperExe -ArgumentList "--mode unattended --unattendedmodeui none --zoiper_alluser_installation 1" -Wait -PassThru
        if ($process.ExitCode -eq 0) {
            Write-Host "  Zoiper 5 installed." -ForegroundColor Green
        } else {
            Write-Warning "  Zoiper install exited with code $($process.ExitCode)."
        }
    }
}

# ---------------------------------------------------------------------------
# Slack
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[4/4] Slack..." -ForegroundColor Yellow

if (Test-Installed "*Slack*") {
    Write-Host "  Already installed. Skipping." -ForegroundColor Green
} else {
    $slackMsi = "$env:TEMP\Slack.msi"
    Write-Host "  Downloading..."
    try {
        Invoke-WebRequest -Uri "https://slack.com/ssb/download-win64-msi" -OutFile $slackMsi -UseBasicParsing
    } catch {
        Write-Warning "  Could not download Slack. Download manually from: https://slack.com/downloads/windows"
        $slackMsi = $null
    }

    if ($slackMsi -and (Test-Path $slackMsi)) {
        Write-Host "  Installing..."
        $process = Start-Process msiexec.exe -ArgumentList "/i `"$slackMsi`" /quiet /norestart" -Wait -PassThru
        if ($process.ExitCode -eq 0) {
            Write-Host "  Slack installed." -ForegroundColor Green
        } else {
            Write-Warning "  Slack install exited with code $($process.ExitCode))."
        }
    }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  App installation complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
