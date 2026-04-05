#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up GCPW on a Windows workstation. Supports both new machines and
    migrations from JumpCloud.

.DESCRIPTION
    NewMachine mode (for fresh workstations):
      - Installs GCPW and Endpoint Verification
      - Configures domain restriction
      - User gets Google login on next reboot -- no profile association needed

    Migration mode (Phase 1 + Phase 2, for existing JumpCloud machines):
      Phase 1 (safe, no disruption):
        - Creates a local admin backup account (safety net)
        - Installs GCPW and Endpoint Verification
        - Associates the existing Windows profile with a Google account

      Phase 2 (after confirming GCPW login works):
        - Uninstalls JumpCloud agent
        - Cleans up JumpCloud artifacts

.PARAMETER NewMachine
    Use this flag for fresh workstations with no existing user profile to
    preserve. Installs GCPW and configures it -- that's it.

.PARAMETER GoogleEmail
    The user's Google Workspace email (e.g. jane@yourdomain.com).
    Required for Phase 1 (migration). Optional for NewMachine (if provided,
    pre-associates the account).

.PARAMETER Domain
    Your Google Workspace domain (e.g. yourdomain.com)

.PARAMETER WindowsUsername
    The existing Windows username to associate. Defaults to the currently
    logged-in user if not specified. Not used with -NewMachine.

.PARAMETER Phase
    Which phase to run: 1 (install GCPW) or 2 (remove JumpCloud).
    Default is 1. Ignored when -NewMachine is set.

.PARAMETER BackupAdminPassword
    Password for the local backup admin account. If not specified, you will
    be prompted. Not used with -NewMachine.

.PARAMETER SkipEndpointVerification
    If set, skips Endpoint Verification installation.

.EXAMPLE
    # New machine setup
    .\deploy-gcpw.ps1 -NewMachine -Domain acme.com

    # Migration Phase 1: Install GCPW alongside JumpCloud
    .\deploy-gcpw.ps1 -GoogleEmail jane@acme.com -Domain acme.com -Phase 1

    # Migration Phase 2: Remove JumpCloud
    .\deploy-gcpw.ps1 -Phase 2
#>

param(
    [switch]$NewMachine,

    [string]$GoogleEmail,

    [string]$Domain,

    [string]$WindowsUsername,

    [ValidateSet(1, 2)]
    [int]$Phase = 1,

    [string]$BackupAdminPassword,

    [switch]$SkipEndpointVerification
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
# Stamped by pre-commit hook -- do not edit manually
$Script:Revision = "2196a33"

Write-Host "deploy-gcpw.ps1 rev $Script:Revision" -ForegroundColor DarkGray

# Surface the OS build at the top so it lands in any copy/pasted output.
# Windows 11 shows up as "Windows 10 Pro" in ProductName (MS quirk), so rely on build number.
$osInfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
Write-Host "Windows build: $($osInfo.DisplayVersion) $($osInfo.CurrentBuild).$($osInfo.UBR)" -ForegroundColor DarkGray

# Check if this is the latest version
try {
    $commits = Invoke-RestMethod -Uri "https://api.github.com/repos/ameriglide/it-admin/commits?path=scripts/deploy-gcpw.ps1&per_page=2" -ErrorAction Stop
    $knownRevs = $commits | ForEach-Object { $_.sha.Substring(0, 7) }
    if ($Script:Revision -ne "dev" -and $Script:Revision -notin $knownRevs) {
        Write-Host ""
        Write-Host "  WARNING: You are running rev $Script:Revision but the latest is $($knownRevs[0])" -ForegroundColor Red
        Write-Host "  Re-download the script to get the latest version." -ForegroundColor Red
        Write-Host ""
        $continue = Read-Host "  Press Enter to continue anyway, or Ctrl+C to abort"
    }
} catch {
    # Can't reach GitHub -- no big deal, just skip the check
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
$GcpwMsiUrl       = "https://dl.google.com/credentialprovider/GCPWStandaloneEnterprise64.msi"
$GcpwMsiPath      = "$env:TEMP\GCPWStandaloneEnterprise64.msi"
$GcpwRegPath      = "HKLM:\SOFTWARE\Google\GCPW"
$EvMsiUrl         = "https://dl.google.com/secureconnect/install/win/EndpointVerification_admin.msi"
$EvMsiPath        = "$env:TEMP\EndpointVerification.msi"
$BackupAdminUser  = "localadmin"
$GcpwClsid        = "HKCR:\CLSID\{0B5BFDF0-4594-47AC-940A-CFC69ABC561C}"
$GcpwProviderGuid = "{0B5BFDF0-4594-47AC-940A-CFC69ABC561C}"
$GcpwProviderReg  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$GcpwProviderGuid"
$WebView2Reg      = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
$WebView2Url      = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
$WebView2Path     = "$env:TEMP\MicrosoftEdgeWebview2Setup.exe"
$JcAgentPath      = "C:\Program Files\JumpCloud"
$JcUninstaller    = "C:\Program Files\JumpCloud\Uninstall.exe"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Wait for Windows Update / servicing to stop racing us on the Windows Installer.
# We observed MSI installs returning exit code 0 while leaving payload half-extracted
# when TrustedInstaller/WU was active during install.
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

function Install-WebView2 {
    # GCPW uses WebView2 to render the Google sign-in UI in LogonUI.
    # If it's missing, the credential provider loads but has nothing to draw with
    # and the tile silently fails to appear.
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

    # Map HKCR since PowerShell doesn't mount it by default
    if (-not (Test-Path "HKCR:\")) {
        New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -ErrorAction SilentlyContinue | Out-Null
    }

    # Verify both the COM CLSID and the credential-provider registration.
    # The CLSID alone is not sufficient -- winlogon reads the provider list from
    # HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\{GUID}.
    $needReinstall = $false
    $clsidEntry = Get-ItemProperty "$GcpwClsid\InprocServer32" -ErrorAction SilentlyContinue
    if (-not $clsidEntry -or -not (Test-Path $clsidEntry.'(default)')) {
        Write-Warning "  GCPW CLSID or DLL missing."
        $needReinstall = $true
    }
    if (-not (Test-Path $GcpwProviderReg)) {
        Write-Warning "  GCPW not registered under Authentication\Credential Providers."
        $needReinstall = $true
    }

    if ($needReinstall) {
        Write-Warning "  Attempting clean reinstall..."
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
    Write-Host "  GCPW installed and verified (CLSID + provider registration)." -ForegroundColor Green

    # Critical: the MSI completes install but doesn't run post-install initialization.
    # Without this, winlogon silently refuses to load gaia1_0.dll and the Google tile
    # never appears on the lock screen despite everything being registered correctly.
    # Kicking the GoogleUpdater scheduled task completes whatever state GCPW needs.
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

# Win11's "passwordless sign-in" feature hides password-based credential providers
# (including GCPW) from the lock screen. Disable it so the Google tile can show.
function Disable-PasswordlessSignin {
    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"
    if (-not (Test-Path $key)) {
        New-Item -Path $key -Force | Out-Null
    }
    $current = (Get-ItemProperty $key -Name "DevicePasswordLessBuildVersion" -ErrorAction SilentlyContinue).DevicePasswordLessBuildVersion
    if ($current -ne 0) {
        Set-ItemProperty -Path $key -Name "DevicePasswordLessBuildVersion" -Value 0 -Type DWord
        Write-Host "  Disabled Win11 passwordless sign-in requirement (was $current)." -ForegroundColor Yellow
    }
}

# ============================================================================
#  NEW MACHINE: Fresh GCPW setup, no migration
# ============================================================================
if ($NewMachine) {

    if (-not $Domain) {
        Write-Error "-NewMachine requires -Domain parameter."
        exit 1
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  New Machine: GCPW Setup" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Domain           : $Domain"
    if ($GoogleEmail) {
        Write-Host "Google Email     : $GoogleEmail"
    }
    Write-Host ""

    # ------------------------------------------------------------------
    # Step 1: Create local admin account
    # ------------------------------------------------------------------
    Write-Host "[1/4] Creating local admin account..." -ForegroundColor Yellow

    $backupExists = Get-LocalUser -Name $BackupAdminUser -ErrorAction SilentlyContinue
    if ($backupExists) {
        Write-Host "  Admin account '$BackupAdminUser' already exists. Skipping." -ForegroundColor Green
    } else {
        if (-not $BackupAdminPassword) {
            $securePwd = Read-Host "  Enter password for local admin account '$BackupAdminUser'" -AsSecureString
            $confirmPwd = Read-Host "  Confirm password" -AsSecureString
            $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
            $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmPwd))
            if ($plain1 -ne $plain2) {
                Write-Error "Passwords do not match. Aborting."
                exit 1
            }
            $plain1 = $null
            $plain2 = $null
        } else {
            $securePwd = ConvertTo-SecureString $BackupAdminPassword -AsPlainText -Force
        }

        New-LocalUser -Name $BackupAdminUser -Password $securePwd -Description "Local admin account" -PasswordNeverExpires | Out-Null
        Add-LocalGroupMember -Group "Administrators" -Member $BackupAdminUser
        Write-Host "  Created local admin account '$BackupAdminUser'." -ForegroundColor Green
    }

    # Disable auto-login if enabled
    $winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $autoLogin = Get-ItemProperty $winlogon -Name "AutoAdminLogon" -ErrorAction SilentlyContinue
    if ($autoLogin -and $autoLogin.AutoAdminLogon -eq "1") {
        Set-ItemProperty $winlogon -Name "AutoAdminLogon" -Value "0"
        Write-Host "  Disabled auto-login (was preventing login screen from showing)." -ForegroundColor Yellow
    }

    # ------------------------------------------------------------------
    # Step 2: Download and install GCPW
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "[2/4] Installing GCPW..." -ForegroundColor Yellow
    Install-GCPW

    # ------------------------------------------------------------------
    # Step 3: Configure GCPW registry
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "[3/4] Configuring GCPW..." -ForegroundColor Yellow

    if (-not (Test-Path $GcpwRegPath)) {
        New-Item -Path $GcpwRegPath -Force | Out-Null
    }

    Set-ItemProperty -Path $GcpwRegPath -Name "domains_allowed_to_login" -Value $Domain
    Write-Host "  Set domains_allowed_to_login = $Domain"

    Set-ItemProperty -Path $GcpwRegPath -Name "enable_multi_user_login" -Value 1 -Type DWord
    Write-Host "  Set enable_multi_user_login = 1"

    Disable-PasswordlessSignin

    # If a Google email was provided, pre-associate with current user profile
    if ($GoogleEmail -and $env:USERNAME -ne "SYSTEM") {
        $userObj = New-Object System.Security.Principal.NTAccount($env:USERNAME)
        try {
            $sid = $userObj.Translate([System.Security.Principal.SecurityIdentifier]).Value
            $assocRegPath = "$GcpwRegPath\Users\$sid"
            if (-not (Test-Path $assocRegPath)) {
                New-Item -Path $assocRegPath -Force | Out-Null
            }
            Set-ItemProperty -Path $assocRegPath -Name "email" -Value $GoogleEmail
            Write-Host "  Pre-associated $env:USERNAME (SID: $sid) -> $GoogleEmail"
        } catch {
            Write-Warning "  Could not pre-associate user profile. User will create a new profile on first Google login."
        }
    }

    # ------------------------------------------------------------------
    # Step 4: Endpoint Verification
    # ------------------------------------------------------------------
    if (-not $SkipEndpointVerification) {
        Write-Host ""
        Write-Host "[4/4] Installing Endpoint Verification..." -ForegroundColor Yellow

        $evInstalled = Get-WmiObject Win32_Product -Filter "Name LIKE '%Endpoint Verification%'" -ErrorAction SilentlyContinue
        if ($evInstalled) {
            Write-Host "  Already installed. Skipping." -ForegroundColor Green
        } else {
            Invoke-WebRequest -Uri $EvMsiUrl -OutFile $EvMsiPath -UseBasicParsing
            $process = Start-Process msiexec.exe -ArgumentList "/i `"$EvMsiPath`" /quiet /norestart" -Wait -PassThru
            if ($process.ExitCode -ne 0) {
                Write-Warning "Endpoint Verification install failed (exit code $($process.ExitCode)). Non-fatal."
            } else {
                Write-Host "  Endpoint Verification installed." -ForegroundColor Green
            }
        }
    } else {
        Write-Host ""
        Write-Host "[4/4] Skipping Endpoint Verification (flag set)." -ForegroundColor Yellow
    }

    # ------------------------------------------------------------------
    # Done
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  New machine setup complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "  1. Reboot the machine"
    Write-Host "  2. On the login screen, sign in with a @$Domain Google account"
    Write-Host "  3. A new Windows profile will be created tied to that Google account"
    Write-Host "  4. Verify the device appears in Google Admin Console > Devices"
    Write-Host ""

    exit 0
}

# ============================================================================
#  PHASE 1: Install GCPW, preserve profile (migration from JumpCloud)
# ============================================================================
if ($Phase -eq 1) {

    # Validate required params for Phase 1
    if (-not $GoogleEmail -or -not $Domain) {
        Write-Error "Phase 1 requires -GoogleEmail and -Domain parameters."
        exit 1
    }

    # Resolve Windows username
    if (-not $WindowsUsername) {
        $WindowsUsername = $env:USERNAME
        Write-Host "No -WindowsUsername specified, using current user: $WindowsUsername"
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Phase 1: Install GCPW" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Google Email     : $GoogleEmail"
    Write-Host "Allowed Domain   : $Domain"
    Write-Host "Windows Username : $WindowsUsername"
    Write-Host ""

    # ------------------------------------------------------------------
    # Step 1: Create local backup admin account
    # ------------------------------------------------------------------
    Write-Host "[1/5] Creating local backup admin account..." -ForegroundColor Yellow

    $backupExists = Get-LocalUser -Name $BackupAdminUser -ErrorAction SilentlyContinue
    if ($backupExists) {
        Write-Host "  Backup account '$BackupAdminUser' already exists. Skipping." -ForegroundColor Green
    } else {
        if (-not $BackupAdminPassword) {
            $securePwd = Read-Host "  Enter password for backup admin account '$BackupAdminUser'" -AsSecureString
            $confirmPwd = Read-Host "  Confirm password" -AsSecureString
            $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
            $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmPwd))
            if ($plain1 -ne $plain2) {
                Write-Error "Passwords do not match. Aborting."
                exit 1
            }
            $plain1 = $null
            $plain2 = $null
        } else {
            $securePwd = ConvertTo-SecureString $BackupAdminPassword -AsPlainText -Force
        }

        New-LocalUser -Name $BackupAdminUser -Password $securePwd -Description "Backup admin for GCPW migration" -PasswordNeverExpires | Out-Null
        Add-LocalGroupMember -Group "Administrators" -Member $BackupAdminUser
        Write-Host "  Created local admin account '$BackupAdminUser'." -ForegroundColor Green
        Write-Host "  IMPORTANT: Remember this password! It's your safety net." -ForegroundColor Red
    }

    # ------------------------------------------------------------------
    # Step 2: Resolve the user's SID
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "[2/5] Resolving user SID..." -ForegroundColor Yellow

    $userObj = New-Object System.Security.Principal.NTAccount($WindowsUsername)
    try {
        $sid = $userObj.Translate([System.Security.Principal.SecurityIdentifier]).Value
        Write-Host "  Resolved SID: $sid"
    } catch {
        # JumpCloud accounts might need the machine name prefix
        $userObj = New-Object System.Security.Principal.NTAccount("$env:COMPUTERNAME\$WindowsUsername")
        try {
            $sid = $userObj.Translate([System.Security.Principal.SecurityIdentifier]).Value
            Write-Host "  Resolved SID: $sid (using $env:COMPUTERNAME\$WindowsUsername)"
        } catch {
            Write-Error "Could not resolve SID for '$WindowsUsername'. Verify the username and try again."
            exit 1
        }
    }

    # ------------------------------------------------------------------
    # Step 3: Download and install GCPW
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "[3/5] Installing GCPW..." -ForegroundColor Yellow
    Install-GCPW

    # ------------------------------------------------------------------
    # Step 4: Configure GCPW registry
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "[4/5] Configuring GCPW..." -ForegroundColor Yellow

    if (-not (Test-Path $GcpwRegPath)) {
        New-Item -Path $GcpwRegPath -Force | Out-Null
    }

    # Restrict logins to your domain
    Set-ItemProperty -Path $GcpwRegPath -Name "domains_allowed_to_login" -Value $Domain
    Write-Host "  Set domains_allowed_to_login = $Domain"

    # Allow multiple users on same machine
    Set-ItemProperty -Path $GcpwRegPath -Name "enable_multi_user_login" -Value 1 -Type DWord
    Write-Host "  Set enable_multi_user_login = 1"

    Disable-PasswordlessSignin

    # Associate existing profile with Google account
    $assocRegPath = "$GcpwRegPath\Users\$sid"
    if (-not (Test-Path $assocRegPath)) {
        New-Item -Path $assocRegPath -Force | Out-Null
    }
    Set-ItemProperty -Path $assocRegPath -Name "email" -Value $GoogleEmail
    Write-Host "  Associated $WindowsUsername (SID: $sid) -> $GoogleEmail"

    # ------------------------------------------------------------------
    # Step 5: Endpoint Verification
    # ------------------------------------------------------------------
    if (-not $SkipEndpointVerification) {
        Write-Host ""
        Write-Host "[5/5] Installing Endpoint Verification..." -ForegroundColor Yellow

        $evInstalled = Get-WmiObject Win32_Product -Filter "Name LIKE '%Endpoint Verification%'" -ErrorAction SilentlyContinue
        if ($evInstalled) {
            Write-Host "  Already installed. Skipping." -ForegroundColor Green
        } else {
            Invoke-WebRequest -Uri $EvMsiUrl -OutFile $EvMsiPath -UseBasicParsing
            $process = Start-Process msiexec.exe -ArgumentList "/i `"$EvMsiPath`" /quiet /norestart" -Wait -PassThru
            if ($process.ExitCode -ne 0) {
                Write-Warning "Endpoint Verification install failed (exit code $($process.ExitCode)). Non-fatal."
            } else {
                Write-Host "  Endpoint Verification installed." -ForegroundColor Green
            }
        }
    } else {
        Write-Host ""
        Write-Host "[5/5] Skipping Endpoint Verification (flag set)." -ForegroundColor Yellow
    }

    # ------------------------------------------------------------------
    # Phase 1 complete
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Phase 1 complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "  1. Reboot the machine"
    Write-Host "  2. On the login screen, user signs in with: $GoogleEmail"
    Write-Host "  3. Verify they land in their existing profile (desktop, files intact)"
    Write-Host "  4. Verify the device appears in Google Admin Console > Devices"
    Write-Host "  5. If everything works, run Phase 2 to remove JumpCloud:"
    Write-Host ""
    Write-Host "     .\deploy-gcpw.ps1 -Phase 2" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  If something goes wrong, log in with '$BackupAdminUser' to fix it."
    Write-Host ""
}

# ============================================================================
#  PHASE 2: Remove JumpCloud
# ============================================================================
if ($Phase -eq 2) {

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Phase 2: Remove JumpCloud" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Pre-flight: confirm GCPW is installed
    $gcpwInstalled = Get-WmiObject Win32_Product -Filter "Name LIKE '%Google Credential Provider%'" -ErrorAction SilentlyContinue
    if (-not $gcpwInstalled) {
        Write-Error "GCPW is not installed. Run Phase 1 first and verify Google login works before removing JumpCloud."
        exit 1
    }
    Write-Host "  GCPW is installed (version $($gcpwInstalled.Version))." -ForegroundColor Green

    # Confirm backup admin exists
    $backupExists = Get-LocalUser -Name $BackupAdminUser -ErrorAction SilentlyContinue
    if (-not $backupExists) {
        Write-Warning "Backup admin account '$BackupAdminUser' not found. Proceeding anyway -- make sure you have another way to log in if something breaks."
    } else {
        Write-Host "  Backup admin account '$BackupAdminUser' exists." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  WARNING: This will uninstall the JumpCloud agent." -ForegroundColor Red
    Write-Host "  The machine will no longer be managed by JumpCloud." -ForegroundColor Red
    Write-Host ""
    $confirm = Read-Host "  Type 'YES' to continue"
    if ($confirm -ne "YES") {
        Write-Host "  Aborted." -ForegroundColor Yellow
        exit 0
    }

    # ------------------------------------------------------------------
    # Step 1: Stop JumpCloud services
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "[1/3] Stopping JumpCloud services..." -ForegroundColor Yellow

    $jcServices = Get-Service -Name "jumpcloud*" -ErrorAction SilentlyContinue
    foreach ($svc in $jcServices) {
        Write-Host "  Stopping $($svc.Name)..."
        Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  Services stopped." -ForegroundColor Green

    # ------------------------------------------------------------------
    # Step 2: Uninstall JumpCloud agent
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "[2/3] Uninstalling JumpCloud agent..." -ForegroundColor Yellow

    if (Test-Path $JcUninstaller) {
        # JumpCloud's own uninstaller
        $process = Start-Process -FilePath $JcUninstaller -ArgumentList "/S" -Wait -PassThru
        if ($process.ExitCode -eq 0) {
            Write-Host "  JumpCloud agent uninstalled via uninstaller." -ForegroundColor Green
        } else {
            Write-Warning "  Uninstaller exited with code $($process.ExitCode). Trying WMI fallback..."
        }
    }

    # Fallback / additional cleanup: try WMI uninstall
    $jcProduct = Get-WmiObject Win32_Product -Filter "Name LIKE '%JumpCloud%'" -ErrorAction SilentlyContinue
    if ($jcProduct) {
        Write-Host "  Removing JumpCloud via WMI..."
        $jcProduct.Uninstall() | Out-Null
        Write-Host "  Done." -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # Step 3: Clean up JumpCloud artifacts
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "[3/3] Cleaning up JumpCloud artifacts..." -ForegroundColor Yellow

    # Remove JumpCloud directory
    if (Test-Path $JcAgentPath) {
        Remove-Item -Path $JcAgentPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  Removed $JcAgentPath"
    }

    # Remove JumpCloud registry keys
    $jcRegPaths = @(
        "HKLM:\SOFTWARE\JumpCloud",
        "HKLM:\SOFTWARE\WOW6432Node\JumpCloud"
    )
    foreach ($regPath in $jcRegPaths) {
        if (Test-Path $regPath) {
            Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed registry key $regPath"
        }
    }

    # Remove JumpCloud scheduled tasks
    $jcTasks = Get-ScheduledTask -TaskName "*JumpCloud*" -ErrorAction SilentlyContinue
    foreach ($task in $jcTasks) {
        Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  Removed scheduled task: $($task.TaskName)"
    }

    # ------------------------------------------------------------------
    # Phase 2 complete
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Phase 2 complete! JumpCloud removed." -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "The machine is now managed by GCPW only."
    Write-Host "Users log in with their Google Workspace credentials."
    Write-Host ""
    Write-Host "Optional cleanup:" -ForegroundColor Yellow
    Write-Host "  - Once all machines are migrated, delete the backup admin account:"
    Write-Host "    Remove-LocalUser -Name '$BackupAdminUser'"
    Write-Host "  - Cancel your JumpCloud subscription"
    Write-Host ""
}
