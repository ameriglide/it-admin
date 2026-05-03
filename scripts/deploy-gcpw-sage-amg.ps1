#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Server-side cutover from JumpCloud to GCPW on sage-amg.

.DESCRIPTION
    sage-amg is a Windows Server 2022 RDP host. Workstations connect with
    `sage-amg\<first.last>` over Tailscale. This script:

      1. Installs GCPW + configures it for the cross-domain (ameriglide.com,
         atlasacces.com) login set sage-amg needs.
      2. Pre-populates GCPW user-SID associations so existing JC-provisioned
         local accounts (`first.last`) get reused - no orphan profiles.
      3. Disables RDP NLA so the GCPW OAuth tile renders through the RDP login
         screen on first sign-in. Tailscale ACLs gate reachability, so this is
         a small security delta. Once each user has signed in once, GCPW keeps
         their local Windows password in sync with their Google password and
         NLA-RDP works again - but we leave NLA off since this is a multi-user
         RDP host where new users keep onboarding.
      4. Removes JumpCloud Agent + JumpCloud Remote Assist + scheduled tasks +
         registry + on-disk artifacts. Local user accounts are NOT touched.

    NOT a workstation script. Use scripts/deploy-gcpw.ps1 for workstations.

.PARAMETER Force
    Skip the hostname guard. Only useful if you've renamed the host.

.PARAMETER Yes
    Skip the interactive 'YES' prompt before destructive steps.

.PARAMETER BackupAdminPassword
    Password for the local 'localadmin' safety-net account. Prompted if not
    supplied.

.PARAMETER SkipJumpCloudRemoval
    Install GCPW + flip NLA but leave JumpCloud running. Used for a staged
    cutover where you want to validate GCPW sign-in before pulling the JC plug.

.EXAMPLE
    .\deploy-gcpw-sage-amg.ps1

.EXAMPLE
    # Stage 1: install GCPW alongside JC, validate, then re-run without the flag
    .\deploy-gcpw-sage-amg.ps1 -SkipJumpCloudRemoval
#>

param(
    [switch]$Force,
    [switch]$Yes,
    [string]$BackupAdminPassword,
    [switch]$SkipJumpCloudRemoval
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
# Stamped by pre-commit hook -- do not edit manually
$Script:Revision = "c58b900"

Write-Host "deploy-gcpw-sage-amg.ps1 rev $Script:Revision" -ForegroundColor DarkGray
$osInfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
Write-Host "Windows build: $($osInfo.DisplayVersion) $($osInfo.CurrentBuild).$($osInfo.UBR)" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Hostname guard -- this script is sage-amg-specific.
# ---------------------------------------------------------------------------
if (-not $Force -and $env:COMPUTERNAME -inotmatch '^sage-amg$') {
    Write-Error "Refusing to run on '$env:COMPUTERNAME'. This script is sage-amg-specific. Use -Force to override."
    exit 1
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
$GcpwMsiUrl       = "https://dl.google.com/credentialprovider/GCPWStandaloneEnterprise64.msi"
$GcpwMsiPath      = "$env:TEMP\GCPWStandaloneEnterprise64.msi"
$GcpwRegPath      = "HKLM:\SOFTWARE\Google\GCPW"
$GcpwClsid        = "HKCR:\CLSID\{0B5BFDF0-4594-47AC-940A-CFC69ABC561C}"
$GcpwProviderGuid = "{0B5BFDF0-4594-47AC-940A-CFC69ABC561C}"
$GcpwProviderReg  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$GcpwProviderGuid"
$WebView2Reg      = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
$WebView2Url      = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
$WebView2Path     = "$env:TEMP\MicrosoftEdgeWebview2Setup.exe"
$ChromeUrl        = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi"
$ChromePath       = "$env:TEMP\chrome_enterprise.msi"
$ChromeExePaths   = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
)

$BackupAdminUser  = "localadmin"

# Comma-separated list passed to GCPW's domains_allowed_to_login.
$AllowedDomains   = "ameriglide.com,atlasacces.com"

$RdpRegPath       = "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"

# JumpCloud Agent is a single-MSI install. ProductCode pinned from sage-amg.
$JcAgentMsi       = "{09B5BB85-C342-46D2-8017-668A8AC6AF0A}"
$JcAgentDir       = "C:\Program Files\JumpCloud"
$JcRemoteAssistDir = "C:\Program Files\JumpCloud Remote Assist"
$JcRemoteAssistUninstaller = "$JcRemoteAssistDir\Uninstall JumpCloud Remote Assist.exe"
$JcProgramData    = "C:\ProgramData\JumpCloud"

# Existing single-name JumpCloud accounts whose Google emails don't follow the
# default `<sam>@ameriglide.com` rule. Add to this map as needed.
$EmailOverrides = @{
    "phil"    = "phil.vandal@ameriglide.com"
    "victor"  = "victor@atlasacces.com"
    "vincent" = "vincent@ameriglide.com"
}

# Local accounts to leave entirely alone -- not JumpCloud-provisioned, no GCPW
# association needed.
$ManualLocalAccounts = @(
    "Administrator", "Guest", "DefaultAccount", "WDAGUtilityAccount",
    "warehouse", "sage", "bhumi.jasani", "nadia.dupont", "natasha.roy",
    "denise.saurette", $BackupAdminUser
)

# ---------------------------------------------------------------------------
# Helpers (subset of deploy-gcpw.ps1 -- kept self-contained for irm|iex use)
# ---------------------------------------------------------------------------
function Wait-ForServicingIdle {
    param([int]$TimeoutSeconds = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $announced = $false
    while ((Get-Date) -lt $deadline) {
        $busy = Get-Process -Name TiWorker, TrustedInstaller, msiexec -ErrorAction SilentlyContinue |
                Where-Object { $_.Id -ne $PID }
        if (-not $busy) { return }
        if (-not $announced) {
            Write-Host "  Waiting for Windows servicing to finish ($($busy.Name -join ', '))..." -ForegroundColor DarkGray
            $announced = $true
        }
        Start-Sleep -Seconds 5
    }
    Write-Warning "  Servicing still busy after $TimeoutSeconds seconds. Proceeding anyway."
}

function Install-Chrome {
    $existing = $ChromeExePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($existing) {
        Write-Host "  Chrome already installed at $existing" -ForegroundColor Green
        return
    }
    Write-Host "  Chrome not found. Installing Chrome Enterprise MSI (required by GCPW)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $ChromeUrl -OutFile $ChromePath -UseBasicParsing
    $process = Start-Process msiexec.exe -ArgumentList "/i `"$ChromePath`" /qn /norestart" -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Write-Warning "  Chrome install returned exit code $($process.ExitCode). GCPW tile may not render."
    } else {
        Write-Host "  Chrome installed." -ForegroundColor Green
    }
}

function Install-WebView2 {
    $wv = Get-ItemProperty $WebView2Reg -ErrorAction SilentlyContinue
    if ($wv -and $wv.pv) {
        Write-Host "  WebView2 runtime already installed (version $($wv.pv))." -ForegroundColor Green
        return
    }
    Write-Host "  WebView2 runtime not found. Installing..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $WebView2Url -OutFile $WebView2Path -UseBasicParsing
    $process = Start-Process -FilePath $WebView2Path -ArgumentList "/silent /install" -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Write-Warning "  WebView2 install returned exit code $($process.ExitCode). GCPW tile may not render."
    } else {
        Write-Host "  WebView2 installed." -ForegroundColor Green
    }
}

function Install-GCPW {
    Install-Chrome
    Install-WebView2
    Wait-ForServicingIdle

    $gcpwInstalled = Get-WmiObject Win32_Product -Filter "Name LIKE '%Google Credential Provider%'" -ErrorAction SilentlyContinue
    if ($gcpwInstalled) {
        Write-Host "  GCPW already installed (version $($gcpwInstalled.Version))." -ForegroundColor Green
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Host "  Downloading GCPW..."
        Invoke-WebRequest -Uri $GcpwMsiUrl -OutFile $GcpwMsiPath -UseBasicParsing

        $msiLog = "$env:TEMP\gcpw_install.log"
        Write-Host "  Installing (log: $msiLog)..."
        $process = Start-Process msiexec.exe -ArgumentList "/i `"$GcpwMsiPath`" /quiet /norestart /l*v `"$msiLog`"" -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            Write-Error "GCPW installation failed with exit code $($process.ExitCode). See $msiLog"
            exit 1
        }
    }

    if (-not (Test-Path "HKCR:\")) {
        New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -ErrorAction SilentlyContinue | Out-Null
    }

    $clsidEntry = Get-ItemProperty "$GcpwClsid\InprocServer32" -ErrorAction SilentlyContinue
    $clsidOk = ($clsidEntry -and (Test-Path $clsidEntry.'(default)'))
    $providerOk = Test-Path $GcpwProviderReg

    if (-not $clsidOk -or -not $providerOk) {
        Write-Warning "  GCPW registration incomplete (clsid=$clsidOk provider=$providerOk). Reinstalling..."
        Start-Process msiexec.exe -ArgumentList "/x `"$GcpwMsiPath`" /quiet /norestart" -Wait | Out-Null
        Start-Sleep 3
        Wait-ForServicingIdle
        $msiLog = "$env:TEMP\gcpw_install.log"
        $process = Start-Process msiexec.exe -ArgumentList "/i `"$GcpwMsiPath`" /quiet /norestart /l*v `"$msiLog`"" -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            Write-Error "GCPW reinstall failed with exit code $($process.ExitCode). See $msiLog"
            exit 1
        }
        $clsidEntry = Get-ItemProperty "$GcpwClsid\InprocServer32" -ErrorAction SilentlyContinue
        if (-not $clsidEntry -or -not (Test-Path $clsidEntry.'(default)') -or -not (Test-Path $GcpwProviderReg)) {
            Write-Error "GCPW registration still incomplete after reinstall. See $msiLog"
            exit 1
        }
    }
    Write-Host "  GCPW installed and verified." -ForegroundColor Green

    # Kick GoogleUpdater so the tile actually renders. Without this, fresh
    # installs sit broken until the scheduled task fires on its own clock.
    $updaterTasks = Get-ScheduledTask -TaskPath "\GoogleUpdater\" -ErrorAction SilentlyContinue
    if ($updaterTasks) {
        Write-Host "  Triggering GoogleUpdater to finalize GCPW initialization..."
        foreach ($task in $updaterTasks) {
            try {
                Start-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction Stop
                Write-Host "    Started $($task.TaskName)" -ForegroundColor DarkGray
            } catch {
                Write-Warning "    Failed to start $($task.TaskName): $_"
            }
        }
        Start-Sleep -Seconds 5
    } else {
        Write-Warning "  No GoogleUpdater tasks found. GCPW tile may not render until updater runs."
    }
}

function Disable-PasswordlessSignin {
    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"
    if (-not (Test-Path $key)) {
        New-Item -Path $key -Force | Out-Null
    }
    $current = (Get-ItemProperty $key -Name "DevicePasswordLessBuildVersion" -ErrorAction SilentlyContinue).DevicePasswordLessBuildVersion
    if ($current -ne 0) {
        Set-ItemProperty -Path $key -Name "DevicePasswordLessBuildVersion" -Value 0 -Type DWord
        Write-Host "  Disabled passwordless sign-in requirement (was $current)." -ForegroundColor Yellow
    }
}

# Map a JumpCloud-provisioned SAM name to its Google email.
# Returns $null if we should skip this account.
function Resolve-GoogleEmail {
    param([string]$SamName)
    if ($EmailOverrides.ContainsKey($SamName)) {
        return $EmailOverrides[$SamName]
    }
    # Default: lowercased SAM @ ameriglide.com if SAM is `first.last`.
    if ($SamName -match '^[a-zA-Z]+\.[a-zA-Z]+$') {
        return "$($SamName.ToLower())@ameriglide.com"
    }
    return $null
}

# ============================================================================
#  Main
# ============================================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  sage-amg: JumpCloud -> GCPW cutover" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Allowed domains  : $AllowedDomains"
Write-Host "Skip JC removal  : $SkipJumpCloudRemoval"
Write-Host ""

if (-not $Yes) {
    Write-Host "  This will:" -ForegroundColor Yellow
    Write-Host "    - Create local '$BackupAdminUser' admin (safety net)"
    Write-Host "    - Install GCPW and configure cross-domain login"
    Write-Host "    - Pre-associate existing JC user accounts with their Google emails"
    Write-Host "    - Disable RDP NLA (GCPW OAuth flow needs full login screen)"
    if (-not $SkipJumpCloudRemoval) {
        Write-Host "    - Uninstall JumpCloud Agent + Remote Assist" -ForegroundColor Red
        Write-Host "    - Delete JumpCloud directories, registry keys, scheduled tasks" -ForegroundColor Red
    }
    Write-Host "    - Leave all local user accounts in place"
    Write-Host ""
    $resp = Read-Host "  Type 'YES' to continue"
    if ($resp -ne "YES") { Write-Host "  Aborted."; exit 0 }
}

# ----------------------------------------------------------------------------
# [1/7] Backup admin
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[1/7] Ensuring backup admin '$BackupAdminUser' exists..." -ForegroundColor Yellow
$backupExists = Get-LocalUser -Name $BackupAdminUser -ErrorAction SilentlyContinue
if ($backupExists) {
    Write-Host "  Already exists. Skipping." -ForegroundColor Green
} else {
    if (-not $BackupAdminPassword) {
        $securePwd = Read-Host "  Enter password for '$BackupAdminUser'" -AsSecureString
        $confirmPwd = Read-Host "  Confirm" -AsSecureString
        $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
        $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmPwd))
        if ($p1 -ne $p2) { Write-Error "Passwords do not match."; exit 1 }
        $p1 = $null; $p2 = $null
    } else {
        $securePwd = ConvertTo-SecureString $BackupAdminPassword -AsPlainText -Force
    }
    New-LocalUser -Name $BackupAdminUser -Password $securePwd -Description "GCPW cutover safety-net admin" -PasswordNeverExpires | Out-Null
    Add-LocalGroupMember -Group "Administrators" -Member $BackupAdminUser
    Write-Host "  Created. Remember the password." -ForegroundColor Red
}

# ----------------------------------------------------------------------------
# [2/7] GCPW install
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[2/7] Installing GCPW..." -ForegroundColor Yellow
Install-GCPW

# ----------------------------------------------------------------------------
# [3/7] GCPW config
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[3/7] Configuring GCPW for sage-amg..." -ForegroundColor Yellow
if (-not (Test-Path $GcpwRegPath)) { New-Item -Path $GcpwRegPath -Force | Out-Null }
Set-ItemProperty -Path $GcpwRegPath -Name "domains_allowed_to_login" -Value $AllowedDomains
Write-Host "  domains_allowed_to_login = $AllowedDomains"
Set-ItemProperty -Path $GcpwRegPath -Name "enable_multi_user_login" -Value 1 -Type DWord
Write-Host "  enable_multi_user_login = 1"
Disable-PasswordlessSignin

# ----------------------------------------------------------------------------
# [4/7] Pre-associate existing JC accounts so GCPW reuses their SIDs
#       instead of creating new SAM names.
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[4/7] Associating existing local accounts with Google emails..." -ForegroundColor Yellow

$jcUsers = Get-LocalUser | Where-Object {
    $_.Enabled -and
    $_.Description -eq "Added by JumpCloud" -and
    $ManualLocalAccounts -notcontains $_.Name
}

$associated = 0
$skipped = @()
foreach ($u in $jcUsers) {
    $email = Resolve-GoogleEmail -SamName $u.Name
    if (-not $email) {
        $skipped += $u.Name
        continue
    }
    $sid = $u.SID.Value
    if (-not $sid) {
        Write-Warning "  Could not read SID for $($u.Name); skipping."
        $skipped += $u.Name
        continue
    }
    $assocPath = "$GcpwRegPath\Users\$sid"
    if (-not (Test-Path $assocPath)) { New-Item -Path $assocPath -Force | Out-Null }
    Set-ItemProperty -Path $assocPath -Name "email" -Value $email
    Write-Host "  $($u.Name) ($sid) -> $email"
    $associated++
}
Write-Host "  Associated $associated account(s)." -ForegroundColor Green
if ($skipped.Count -gt 0) {
    Write-Host "  Skipped (no email mapping): $($skipped -join ', ')" -ForegroundColor DarkGray
    Write-Host "  Add overrides to `$EmailOverrides at the top of this script if any of these need GCPW access." -ForegroundColor DarkGray
}

# ----------------------------------------------------------------------------
# [5/7] Disable RDP NLA so the GCPW OAuth flow can render through RDP.
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[5/7] Disabling RDP NLA..." -ForegroundColor Yellow
$current = (Get-ItemProperty -LiteralPath $RdpRegPath -Name UserAuthentication -ErrorAction SilentlyContinue).UserAuthentication
Write-Host "  Current UserAuthentication = $current"
Set-ItemProperty -LiteralPath $RdpRegPath -Name UserAuthentication -Value 0 -Type DWord
Write-Host "  Set UserAuthentication = 0 (NLA off, full Windows login screen on RDP)." -ForegroundColor Green
Write-Host "  SecurityLayer left alone (TLS still enforced)."

# ----------------------------------------------------------------------------
# [6/7] JumpCloud removal (optional)
# ----------------------------------------------------------------------------
if ($SkipJumpCloudRemoval) {
    Write-Host ""
    Write-Host "[6/7] Skipping JumpCloud removal (-SkipJumpCloudRemoval)." -ForegroundColor Yellow
    Write-Host "  Re-run without the flag once GCPW sign-in is verified."
} else {
    Write-Host ""
    Write-Host "[6/7] Removing JumpCloud..." -ForegroundColor Yellow

    # Stop services first so files unlock.
    $jcServices = Get-Service -Name "jumpcloud*" -ErrorAction SilentlyContinue
    foreach ($svc in $jcServices) {
        Write-Host "  Stopping service: $($svc.Name)"
        Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
    }

    # Uninstall Remote Assist via its registered quiet uninstaller.
    if (Test-Path $JcRemoteAssistUninstaller) {
        Write-Host "  Uninstalling JumpCloud Remote Assist..."
        $p = Start-Process -FilePath $JcRemoteAssistUninstaller -ArgumentList "/allusers /S" -Wait -PassThru
        if ($p.ExitCode -ne 0) {
            Write-Warning "    Remote Assist uninstaller exit code $($p.ExitCode)."
        } else {
            Write-Host "    Done." -ForegroundColor Green
        }
    }

    # Uninstall the Agent MSI by ProductCode.
    Write-Host "  Uninstalling JumpCloud Agent (msiexec /x $JcAgentMsi)..."
    $p = Start-Process msiexec.exe -ArgumentList "/x $JcAgentMsi /qn /norestart" -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-Warning "    msiexec exit code $($p.ExitCode); attempting Win32_Product fallback..."
        $jcProduct = Get-WmiObject Win32_Product -Filter "Name LIKE '%JumpCloud%'" -ErrorAction SilentlyContinue
        if ($jcProduct) { $jcProduct | ForEach-Object { $_.Uninstall() | Out-Null } }
    } else {
        Write-Host "    Done." -ForegroundColor Green
    }

    # Make sure services are gone (uninstaller usually handles this).
    foreach ($svcName in @("jumpcloud-agent", "jumpcloud-assist-service")) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Host "  Removing leftover service: $svcName"
            sc.exe delete $svcName | Out-Null
        }
    }

    # Wipe directories.
    foreach ($dir in @($JcAgentDir, $JcRemoteAssistDir, $JcProgramData)) {
        if (Test-Path $dir) {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed $dir"
        }
    }

    # Wipe registry keys.
    foreach ($regPath in @("HKLM:\SOFTWARE\JumpCloud", "HKLM:\SOFTWARE\WOW6432Node\JumpCloud")) {
        if (Test-Path $regPath) {
            Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed registry key $regPath"
        }
    }

    # Wipe scheduled tasks.
    $jcTasks = Get-ScheduledTask -TaskName "*JumpCloud*" -ErrorAction SilentlyContinue
    foreach ($task in $jcTasks) {
        Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  Removed scheduled task: $($task.TaskName)"
    }

    Write-Host "  JumpCloud removed." -ForegroundColor Green
}

# ----------------------------------------------------------------------------
# [7/7] Done
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  sage-amg cutover complete." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "USER COMMS - paste into the announcement:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  RDP to sage-amg has switched to Google sign-in."
Write-Host ""
Write-Host "  When you connect, you'll see the full Windows login screen"
Write-Host "  (not the small NLA prompt). Click the Google tile and sign in"
Write-Host "  with your @ameriglide.com account. After that, your sage-amg"
Write-Host "  password is your Google password - no extra step on next sign-in."
Write-Host ""
Write-Host "  victor: use your @atlasacces.com account."
Write-Host "  phil: use phil.vandal@ameriglide.com."
Write-Host ""
Write-Host "If something goes wrong, log in as '$BackupAdminUser' on the console."
Write-Host ""
