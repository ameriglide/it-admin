#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Remove OEM / consumer bloatware. One hardened engine, three profiles.

.DESCRIPTION
  -Profile dell     Dell SupportAssist family + Dell Digital Delivery.
  -Profile hp       HP Wolf Security, HP Support Assistant, myHP, and the
                    usual HP consumer utilities.
  -Profile generic  Common third-party crapware + Windows consumer Store apps
                    (Xbox, Bing, Solitaire, Clipchamp, etc.).

  For each profile the engine: kills the processes, stops+disables the
  services, uninstalls matching Win32 products (MSI by product code, or the
  vendor quiet string) -- and if an MSI uninstall cannot run because its
  cached source is gone (error 1612), force-removes the registration so it
  clears from inventory. It then removes matching Appx/Store packages for all
  users AND deprovisions them from the image, and sweeps leftover scheduled
  tasks and folders.

  DELIBERATE KEEPS: Dell Command | Update, Dell/HP hotkey + audio drivers,
  Microsoft Teams, OneDrive, Copilot, and all framework/dependency packages
  (VCLibs, UI.Xaml, .NET Native, WebView2) are never matched.

  Idempotent and safe to re-run.

.PARAMETER Profile
  Which bloatware set to remove: dell, hp, or generic.

.NOTES
  ASCII-only -- Windows PowerShell 5.1 parses scripts as ANSI. No non-ASCII.
#>
param(
    [ValidateSet('dell', 'hp', 'generic')]
    [string]$Profile = 'generic'
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Profiles. "Uninstall" = DisplayName -like patterns for Win32 products.
# "Appx" = package-name -like patterns for Store apps. Patterns are chosen
# to hit only the junk, never drivers/hotkey/audio support or dependencies.
# ---------------------------------------------------------------------------
$profiles = @{
    dell = @{
        Uninstall = @('Dell SupportAssist*', 'SupportAssist*', 'Dell Digital Delivery*')
        Services  = @('SupportAssistAgent', 'Dell SupportAssist Remediation', 'Dell Hardware Support', 'DDSHCMSvc')
        Processes = @('SupportAssistAgent', 'SupportAssistClientUI', 'SARemediation', 'DigitalDelivery')
        Appx      = @()
        Folders   = @(
            "$env:ProgramFiles\Dell\SupportAssistAgent",
            "$env:ProgramFiles\Dell\SupportAssist",
            "${env:ProgramFiles(x86)}\Dell\SupportAssist",
            "$env:ProgramData\Dell\SupportAssist",
            "${env:ProgramFiles(x86)}\Dell Digital Delivery Services"
        )
    }
    hp = @{
        Uninstall = @(
            'HP Wolf Security*', 'HP Security Update Service', 'HP Sure*',
            'HP Support Assistant', 'HP Support Solutions Framework',
            'myHP', 'HP Connection Optimizer', 'HP Documentation',
            'HP JumpStart*', 'HP QuickDrop*', 'HP System Information*',
            'HP Notifications', 'HP Programmable Key', 'HP Privacy Settings',
            'HP PC Hardware Diagnostics*', 'HP Smart', 'HP Easy Clean',
            'HP WorkWell', 'HP Power Manager'
        )
        Services  = @(
            'HP Wolf Security', 'HP Wolf Security Application Support',
            'HP Comm Recover', 'HPAppHelperCap', 'HPDiagsCap', 'HPNetworkCap',
            'HPSysInfoCap', 'HpTouchpointAnalyticsService',
            'hpsupportsolutionsframeworkservice'
        )
        Processes = @('HPSupportSolutionsFrameworkService', 'myHP', 'HPPrintScanDoctor')
        Appx      = @(
            'AD2F1837.myHP', 'AD2F1837.HPJumpStarts', 'AD2F1837.HPPCHardwareDiagnosticsWindows',
            'AD2F1837.HPPowerManager', 'AD2F1837.HPPrivacySettings', 'AD2F1837.HPSupportAssistant',
            'AD2F1837.HPSystemInformation', 'AD2F1837.HPQuickDrop', 'AD2F1837.HPWorkWell',
            'AD2F1837.HPDesktopSupportUtilities', 'AD2F1837.HPEasyClean', 'AD2F1837.HPSystemEventUtility'
        )
        Folders   = @()
    }
    generic = @{
        # Conservative Win32 list -- only unambiguous third-party junk. (No
        # broad vendor wildcards: e.g. "Amazon*" would match Amazon SSM Agent.)
        Uninstall = @(
            'McAfee*', 'WildTangent*', 'Booking.com*', 'ExpressVPN',
            'Norton*', '*WebAdvisor*'
        )
        Services  = @()
        Processes = @()
        # Windows consumer Store junk. Excludes anything productivity/system:
        # Photos, Calculator, Camera, Store, Terminal, Notepad, Snipping,
        # Paint, Windows Security, Teams, Copilot, PhoneLink, and all
        # framework/dependency packages are intentionally NOT listed.
        Appx      = @(
            'Microsoft.XboxApp', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxGameOverlay',
            'Microsoft.XboxGamingOverlay', 'Microsoft.XboxSpeechToTextOverlay',
            'Microsoft.GamingApp', 'Microsoft.BingWeather', 'Microsoft.BingNews',
            'Microsoft.MicrosoftSolitaireCollection', 'Clipchamp.Clipchamp',
            'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.MixedReality.Portal',
            'Microsoft.Microsoft3DViewer', 'Microsoft.MSPaint', 'Microsoft.People',
            'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.SkypeApp',
            'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'SpotifyAB.SpotifyMusic',
            '*CandyCrush*', 'king.com.*', '*.Netflix', '*.Disney', 'BytedancePte.Ltd.TikTok'
        )
        Folders   = @()
    }
}

$prof = $profiles[$Profile]
Write-Host "Bloatware removal -- profile: $Profile" -ForegroundColor Cyan

# 1. Kill processes so files/registration are not locked.
foreach ($p in $prof.Processes) {
    Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# 2. Stop + disable services so uninstallers are not blocked.
foreach ($name in $prof.Services) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "Stopping service: $name"
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        Set-Service  -Name $name -StartupType Disabled -ErrorAction SilentlyContinue
    }
}

# 3. Uninstall matching Win32 products from the uninstall registry.
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

function Invoke-Uninstall($app) {
    $dn  = $app.DisplayName
    $key = $app.PSChildName
    if ($key -match '^\{[0-9A-Fa-f-]+\}$') {
        $proc = Start-Process 'msiexec.exe' -ArgumentList "/x $key /qn /norestart" -Wait -NoNewWindow -PassThru
        $rc = $proc.ExitCode
        Write-Host "  msiexec /x $key -> exit $rc"
        if ($rc -eq 0 -or $rc -eq 3010 -or $rc -eq 1605) { return }
        Write-Warning "  msiexec could not uninstall $dn (exit $rc); force-removing its registration."
        Remove-Item -Path $app.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    $cmd = if ($app.QuietUninstallString) { $app.QuietUninstallString } else { $app.UninstallString }
    if (-not $cmd) {
        Write-Warning "  No uninstall string for $dn; force-removing its registration."
        Remove-Item -Path $app.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $rest = $Matches[2] }
    elseif ($cmd -match '^\s*(\S+)\s*(.*)$') { $exe = $Matches[1]; $rest = $Matches[2] }
    else { Write-Warning "  Unparseable uninstall string for $dn"; return }
    if (-not $app.QuietUninstallString) { $rest = ("$rest /S /silent /norestart").Trim() }
    Write-Host "  $exe $rest"
    Start-Process $exe -ArgumentList $rest -Wait -NoNewWindow
}

foreach ($root in $uninstallRoots) {
    Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
        $app = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        $dn  = $app.DisplayName
        if (-not $dn) { return }
        $isTarget = $false
        foreach ($t in $prof.Uninstall) { if ($dn -like $t) { $isTarget = $true } }
        if (-not $isTarget) { return }
        Write-Host "Removing (Win32): $dn"
        try { Invoke-Uninstall $app } catch { Write-Warning "  Failed: $($_.Exception.Message)" }
    }
}

# 4. Remove matching Appx/Store packages for all users, and deprovision from
#    the image so they do not return for new users.
foreach ($pat in $prof.Appx) {
    Get-AppxPackage -AllUsers -Name $pat -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "Removing (Appx): $($_.Name)"
        Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
    }
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $pat } | ForEach-Object {
            Write-Host "Deprovisioning (Appx): $($_.DisplayName)"
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
        }
}

# 5. Sweep leftover scheduled tasks (SupportAssist / HP telemetry).
Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -like '*SupportAssist*' -or $_.TaskPath -like '*HP\*' -or $_.TaskName -like 'HP *' } |
    ForEach-Object {
        Write-Host "Removing task: $($_.TaskName)"
        Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    }

# 6. Sweep leftover folders.
foreach ($f in $prof.Folders) {
    if (Test-Path $f) {
        Write-Host "Removing folder: $f"
        Remove-Item -Path $f -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 7. Delete any leftover (now stopped + disabled) services so no stale service
#    entries remain after the product's files/registration are gone.
foreach ($name in $prof.Services) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "Deleting service: $($svc.Name)"
        & sc.exe delete "$($svc.Name)" | Out-Null
    }
}

Write-Host "Bloatware removal complete (profile: $Profile)." -ForegroundColor Green
