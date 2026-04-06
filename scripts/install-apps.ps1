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
$Script:Revision = "5c17d6e"

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
        choco install $app.Id -y
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  $($app.Name) installed." -ForegroundColor Green
        } elseif ($LASTEXITCODE -eq 1) {
            # Check if this was a checksum failure
            $chocoLog = Get-Content "$env:ChocolateyInstall\logs\chocolatey.log" -Tail 50 -ErrorAction SilentlyContinue
            $checksumFail = $chocoLog | Select-String -Pattern "checksum|hash" -Quiet
            if ($checksumFail) {
                Write-Warning "  $($app.Name) failed due to a checksum mismatch."
                Write-Host "  This can happen when the vendor updates the download without updating the package." -ForegroundColor DarkGray
                $retry = Read-Host "  Retry with checksum verification disabled? (y/N)"
                if ($retry -eq 'y') {
                    choco install $app.Id -y --ignore-checksums
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "  $($app.Name) installed (checksum skipped)." -ForegroundColor Green
                    } else {
                        Write-Warning "  $($app.Name) still failed (exit code $LASTEXITCODE)."
                    }
                } else {
                    Write-Warning "  Skipped $($app.Name)."
                }
            } else {
                Write-Warning "  $($app.Name) install failed (exit code $LASTEXITCODE)."
            }
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

# ---------------------------------------------------------------------------
# Slack auto-start pointed at ag-atlas workspace
# ---------------------------------------------------------------------------
Write-Host "Slack startup config..." -ForegroundColor Yellow

$slackExe = Get-ChildItem "C:\Program Files\Slack","C:\Program Files (x86)\Slack" -Filter "slack.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($slackExe) {
    Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "Slack" `
        -Value "`"$($slackExe.FullName)`" --url `"slack://open?domain=ag-atlas`"" -Type String
    Write-Host "  Slack will auto-start at login (ag-atlas workspace)." -ForegroundColor Green
} else {
    Write-Warning "  Slack executable not found. Auto-start not configured."
}
Write-Host ""

# ---------------------------------------------------------------------------
# Chrome bookmarks and settings (via managed policy + initial_preferences)
# ---------------------------------------------------------------------------
Write-Host "Chrome bookmarks & settings..." -ForegroundColor Yellow

# 1. Bookmarks bar: always visible
$chromePolicies = "HKLM:\SOFTWARE\Policies\Google\Chrome"
if (-not (Test-Path $chromePolicies)) {
    New-Item -Path $chromePolicies -Force | Out-Null
}
Set-ItemProperty -Path $chromePolicies -Name "BookmarkBarEnabled" -Value 1 -Type DWord
Set-ItemProperty -Path $chromePolicies -Name "DefaultBrowserSettingEnabled" -Value 1 -Type DWord
Write-Host "  Bookmarks bar enabled."
Write-Host "  Chrome will prompt to be set as default browser."

# Auto-start Chrome to Phenix CRM on login
$chromeExe = "C:\Program Files\Google\Chrome\Application\chrome.exe"
if (Test-Path $chromeExe) {
    Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "Chrome" `
        -Value "`"$chromeExe`" https://phenix.ameriglide.com" -Type String
    Write-Host "  Chrome will auto-start at login (phenix.ameriglide.com)."
}

# 2. Managed bookmarks — flat on the bar, no folders.
#    javascript: URLs are blocked in managed bookmarks, so Quote Me goes
#    directly into the Bookmarks file via initial_preferences instead.
$managedBookmarks = @(
    @{ toplevel_name = "Bookmarks" }
    @{ name = "AmeriGlide";       url = "https://www.ameriglide.com" }
    @{ name = "Phenix CRM";       url = "https://phenix.ameriglide.com" }
    @{ name = "Remix CRM";        url = "https://remix.ameriglide.com" }
    @{ name = "Base";             url = "https://base.inetalliance.net" }
    @{ name = "Gmail";            url = "https://mail.google.com" }
    @{ name = "Calendar";         url = "https://calendar.google.com" }
    @{ name = "Drive";            url = "https://drive.google.com" }
    @{ name = "Docs";             url = "https://docs.google.com" }
    @{ name = "Sheets";           url = "https://sheets.google.com" }
    @{ name = "Meet";             url = "https://meet.google.com" }
    @{ name = "ADP (Payroll/PTO)"; url = "https://my.adp.com" }
    @{ name = "401k";             url = "https://mykplan.com" }
) | ConvertTo-Json -Depth 2 -Compress

Set-ItemProperty -Path $chromePolicies -Name "ManagedBookmarks" -Value $managedBookmarks -Type String
Write-Host "  Managed bookmarks configured."

# 3. Quote Me bookmarklet + initial_preferences.
#    Write the Bookmarks JSON file directly into the Default profile template
#    instead of using import_bookmarks_from_file (which dumps into an
#    "Imported" folder instead of the bar).
$chromePath = "C:\Program Files\Google\Chrome\Application"
if (Test-Path $chromePath) {
    $initialPrefs = @{
        distribution = @{
            import_bookmarks = $false
            show_bookmarks_bar = $true
        }
        browser = @{
            show_bookmarks_bar = $true
        }
        bookmark_bar = @{
            show_on_all_tabs = $true
        }
    } | ConvertTo-Json -Depth 3
    Set-Content -Path "$chromePath\initial_preferences" -Value $initialPrefs -Encoding UTF8
    Write-Host "  initial_preferences written (bookmarks bar on)."

    # Pre-create the Default profile Bookmarks file with Quote Me on the bar.
    # Chrome merges this with managed bookmarks on first launch.
    $defaultProfile = "$env:SystemDrive\Users\Default\AppData\Local\Google\Chrome\User Data\Default"
    New-Item -Path $defaultProfile -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    $bookmarksJson = @'
{
   "roots": {
      "bookmark_bar": {
         "children": [
            {
               "name": "Quote Me",
               "type": "url",
               "url": "javascript:createQuote()"
            }
         ],
         "name": "Bookmarks bar",
         "type": "folder"
      },
      "other": { "children": [], "name": "Other bookmarks", "type": "folder" },
      "synced": { "children": [], "name": "Mobile bookmarks", "type": "folder" }
   },
   "version": 1
}
'@
    Set-Content -Path "$defaultProfile\Bookmarks" -Value $bookmarksJson -Encoding UTF8
    Write-Host "  Quote Me bookmarklet placed on bookmarks bar."
} else {
    Write-Warning "  Chrome not found at $chromePath. Skipping initial_preferences."
}

Write-Host "  Done." -ForegroundColor Green
Write-Host ""

Write-Host "========================================" -ForegroundColor Green
Write-Host "  App installation complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
