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

.PARAMETER ZoiperUsername
    Zoiper account username for activating the Pro license.

.PARAMETER ZoiperPassword
    Zoiper account password for activating the Pro license.

.PARAMETER Only
    If set, install only the named app(s) and skip post-install bookmarks/Slack/Zoiper sections.
    Valid values match the choco IDs: googlechrome, adobereader, slack, tailscale, googledrive, zoiper.
    Example: -Only tailscale

.PARAMETER Domain
    Google Workspace domain for the tenant this workstation belongs to
    (e.g. ameriglide.com, inetalliance.net). Used to scope Chrome site-permission
    allowlists ([*.]<Domain>) for mic/popups/notifications/autoplay.
    Defaults to ameriglide.com.

.PARAMETER Brand
    Company brand label. Drives the C:\ProgramData\<Brand> directory used for
    auto-generated login helpers, the $env:LOCALAPPDATA\.<brand-lower>-2sv-prompted
    flag file, and the display name on the storefront bookmark. Defaults to
    AmeriGlide. Avoid spaces (becomes a directory name).

.PARAMETER MarketingUrl
    Storefront URL placed on the Chrome bookmark bar with -Brand as its label.
    Defaults to https://www.ameriglide.com.

.EXAMPLE
    .\install-apps.ps1 -TailscaleAuthKey "tskey-auth-abc123" -ZoiperUsername "user@example.com" -ZoiperPassword "secret"

.EXAMPLE
    .\install-apps.ps1 -TailscaleAuthKey "tskey-auth-abc123" -Only tailscale
#>

param(
    [string]$TailscaleAuthKey,
    [string]$ZoiperUsername,
    [string]$ZoiperPassword,
    [string[]]$Only = @(),
    [string]$Domain = "ameriglide.com",
    [string]$Brand = "AmeriGlide",
    [string]$MarketingUrl = "https://www.ameriglide.com"
)

$BrandLower = $Brand.ToLower()
$BrandDir   = "C:\ProgramData\$Brand"
$Flag2sv    = ".$BrandLower-2sv-prompted"

$OnlyMode = $Only.Count -gt 0
function Should-Run([string]$id) {
    if (-not $OnlyMode) { return $true }
    return $Only -contains $id
}

# Disable progress bar - speeds up Invoke-WebRequest dramatically
$ProgressPreference = 'SilentlyContinue'

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
$Script:Revision = "4a40782"

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
) | Where-Object { Should-Run $_.Id }

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
if (Should-Run "tailscale") {
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
}

# ---------------------------------------------------------------------------
# Zoiper 5 (hosted in repo -- not available on winget or choco reliably)
# ---------------------------------------------------------------------------
if (Should-Run "zoiper") {
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
# Zoiper 5 Pro activation
# ---------------------------------------------------------------------------
if ($ZoiperUsername -and $ZoiperPassword) {
    Write-Host "Activating Zoiper 5 Pro license..." -ForegroundColor Yellow
    $zoiperPath = $null
    foreach ($dir in @("${env:ProgramFiles}\Zoiper5", "${env:ProgramFiles(x86)}\Zoiper5")) {
        if (Test-Path "$dir\Zoiper5.exe") { $zoiperPath = "$dir\Zoiper5.exe"; break }
    }
    if ($zoiperPath) {
        $activationProcess = Start-Process -FilePath $zoiperPath `
            -ArgumentList "--activation-username=`"$ZoiperUsername`" --activation-password=`"$ZoiperPassword`"" `
            -Wait -PassThru
        if ($activationProcess.ExitCode -eq 0) {
            Write-Host "  Zoiper 5 Pro activated." -ForegroundColor Green
        } else {
            Write-Warning "  Zoiper activation failed (exit code $($activationProcess.ExitCode))."
        }
    } else {
        Write-Warning "  Zoiper5.exe not found. Cannot activate."
    }
} else {
    Write-Host "Zoiper activation: skipped (no credentials provided)." -ForegroundColor DarkGray
}
Write-Host ""
}

# ---------------------------------------------------------------------------
# Slack auto-start pointed at ag-atlas workspace
# ---------------------------------------------------------------------------
if (Should-Run "slack") {
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
}

# ---------------------------------------------------------------------------
# Chrome bookmarks and settings (via managed policy + initial_preferences)
# ---------------------------------------------------------------------------
if (Should-Run "googlechrome") {
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

# Pre-grant permissions for our internal apps so users aren't prompted.
# Pattern [*.]<Domain> covers tenant-internal hosts (phenix/remix for ameriglide,
# crm/callgrove for inetalliance, etc). Required for embedded WebRTC voice
# clients (mic + autoplay) and CRM popups/notifications.
$siteGlob = "[*.]$Domain"
$siteAllowlists = @{
    "AudioCaptureAllowedUrls"      = $siteGlob  # microphone
    "NotificationsAllowedForUrls"  = $siteGlob
    "PopupsAllowedForUrls"         = $siteGlob
    "AutoplayAllowlist"            = $siteGlob  # so call audio plays without click
}
foreach ($policy in $siteAllowlists.GetEnumerator()) {
    $sub = "$chromePolicies\$($policy.Key)"
    if (-not (Test-Path $sub)) { New-Item -Path $sub -Force | Out-Null }
    Set-ItemProperty -Path $sub -Name "1" -Value $policy.Value -Type String
}
Write-Host "  Granted mic/popups/notifications/autoplay for $siteGlob."

# Auto-start Chrome at login. We use a tiny wrapper script (per-user flag
# file) so the first login gets the 2-Step Verification setup tab front and
# center, but subsequent logins get just phenix. Avoids spamming the user
# with "you're already enrolled" on every reboot.
$chromeExe = $null
foreach ($candidate in @(
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
)) {
    if (Test-Path $candidate) { $chromeExe = $candidate; break }
}
if ($chromeExe) {
    $launcherDir = $BrandDir
    $launcherPath = "$launcherDir\chrome-launcher.ps1"
    if (-not (Test-Path $launcherDir)) { New-Item -Path $launcherDir -ItemType Directory -Force | Out-Null }
    @"
# Auto-generated by install-apps.ps1. Do not edit; will be overwritten.
`$chrome = `"$chromeExe`"
`$flag = "`$env:LOCALAPPDATA\$Flag2sv"
`$urls = @("https://phenix.ameriglide.com")
if (-not (Test-Path `$flag)) {
    `$urls = @("https://myaccount.google.com/signinoptions/two-step-verification") + `$urls
    New-Item -Path `$flag -ItemType File -Force | Out-Null
}
& `$chrome `$urls
"@ | Set-Content -Path $launcherPath -Encoding UTF8

    Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "Chrome" `
        -Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherPath`"" -Type String
    Write-Host "  Chrome will auto-start at login (2SV setup once per user, then phenix only)."
} else {
    Write-Warning "  Chrome not found at expected path. Auto-start skipped."
}

# Sage AMG RDP shortcut on Public Desktop. Same wrapper-script pattern as
# Chrome - derives the user's sage-amg\<first.last> credential from their
# GCPW SAM name (jim.soffe_ameriglide -> jim.soffe) and launches mstsc with
# a generated .rdp file. sage-amg resolves over Tailscale MagicDNS.
if (-not (Test-Path $BrandDir)) { New-Item -Path $BrandDir -ItemType Directory -Force | Out-Null }
$rdpLauncher = "$BrandDir\sage-amg-rdp.ps1"
@'
# Auto-generated by install-apps.ps1. Do not edit; will be overwritten.
$samUser = $env:USERNAME
$user = ($samUser -split '_')[0]
$rdpFile = "$env:TEMP\sage-amg.rdp"
@"
full address:s:sage-amg
username:s:sage-amg\$user
authentication level:i:2
screen mode id:i:2
audiomode:i:0
redirectprinters:i:0
redirectclipboard:i:1
"@ | Set-Content -Path $rdpFile -Encoding ASCII
& mstsc.exe $rdpFile
'@ | Set-Content -Path $rdpLauncher -Encoding UTF8

# Public Desktop shortcut visible on every user's desktop.
$WshShell = New-Object -ComObject WScript.Shell
$shortcutPath = "C:\Users\Public\Desktop\Sage AMG.lnk"
$shortcut = $WshShell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$rdpLauncher`""
$shortcut.IconLocation = "$env:SystemRoot\system32\mstsc.exe,0"
$shortcut.Description = "Connect to sage-amg via RDP (over Tailscale)"
$shortcut.Save()
Write-Host "  Sage AMG RDP shortcut placed on Public Desktop."

# 2. Bookmarks bar entries - written directly into the Default profile's
#    Bookmarks JSON so they appear flat on the bar, not nested in a folder.
#    (The ManagedBookmarks policy ALWAYS nests entries inside a folder, which
#    is why we don't use it here. Also: javascript: URLs are blocked in
#    managed bookmarks, so Quote Me has to be in the JSON anyway.)
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

    # Build the bookmark bar children list.
    $barEntries = @(
        @{ name = "Phenix CRM";        url = "https://phenix.ameriglide.com" }
        @{ name = "Remix CRM";         url = "https://remix.ameriglide.com" }
        @{ name = "Base";              url = "https://base.inetalliance.net" }
        @{ name = $Brand;              url = $MarketingUrl }
        @{ name = "Gmail";             url = "https://mail.google.com" }
        @{ name = "Calendar";          url = "https://calendar.google.com" }
        @{ name = "Drive";             url = "https://drive.google.com" }
        @{ name = "Docs";              url = "https://docs.google.com" }
        @{ name = "Sheets";            url = "https://sheets.google.com" }
        @{ name = "ADP (Payroll/PTO)"; url = "https://my.adp.com" }
        @{ name = "401k";              url = "https://mykplan.com" }
        @{ name = "Quote Me";          url = "javascript:createQuote()" }
    ) | ForEach-Object {
        @{ name = $_.name; type = "url"; url = $_.url }
    }

    $bookmarks = @{
        roots = @{
            bookmark_bar = @{
                children = $barEntries
                name = "Bookmarks bar"
                type = "folder"
            }
            other = @{ children = @(); name = "Other bookmarks"; type = "folder" }
            synced = @{ children = @(); name = "Mobile bookmarks"; type = "folder" }
        }
        version = 1
    } | ConvertTo-Json -Depth 6

    # Pre-seed the Default profile Bookmarks file so new users get the bar
    # populated when their profile is created on first sign-in.
    $defaultProfile = "$env:SystemDrive\Users\Default\AppData\Local\Google\Chrome\User Data\Default"
    New-Item -Path $defaultProfile -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    Set-Content -Path "$defaultProfile\Bookmarks" -Value $bookmarks -Encoding UTF8
    Write-Host "  Bookmarks bar populated ($($barEntries.Count) entries)."
} else {
    Write-Warning "  Chrome not found at $chromePath. Skipping bookmark setup."
}

# Clean up any prior ManagedBookmarks policy from earlier installs (it would
# show as a "Bookmarks" folder on the bar and duplicate everything).
Remove-ItemProperty -Path $chromePolicies -Name "ManagedBookmarks" -ErrorAction SilentlyContinue

Write-Host "  Done." -ForegroundColor Green
Write-Host ""
}

Write-Host "========================================" -ForegroundColor Green
Write-Host "  App installation complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
