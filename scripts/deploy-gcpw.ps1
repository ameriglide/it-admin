#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up GCPW on a Windows workstation. Supports both new machines and
    migrations from JumpCloud.

.DESCRIPTION
    NewMachine mode (for fresh workstations):
      - Installs GCPW and Endpoint Verification
      - Configures domain restriction
      - User gets Google login on next reboot — no profile association needed

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
    preserve. Installs GCPW and configures it — that's it.

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

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
$GcpwMsiUrl       = "https://dl.google.com/credentialprovider/GCPWStandaloneEnterprise64.msi"
$GcpwMsiPath      = "$env:TEMP\GCPWStandaloneEnterprise64.msi"
$GcpwRegPath      = "HKLM:\SOFTWARE\Google\GCPW"
$EvMsiUrl         = "https://dl.google.com/endpoint-verification/EndpointVerification.msi"
$EvMsiPath        = "$env:TEMP\EndpointVerification.msi"
$BackupAdminUser  = "localadmin"
$JcAgentPath      = "C:\Program Files\JumpCloud"
$JcUninstaller    = "C:\Program Files\JumpCloud\Uninstall.exe"

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
    # Step 1: Download and install GCPW
    # ------------------------------------------------------------------
    Write-Host "[1/3] Installing GCPW..." -ForegroundColor Yellow

    $gcpwInstalled = Get-WmiObject Win32_Product -Filter "Name LIKE '%Google Credential Provider%'" -ErrorAction SilentlyContinue
    if ($gcpwInstalled) {
        Write-Host "  GCPW already installed (version $($gcpwInstalled.Version)). Skipping." -ForegroundColor Green
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Host "  Downloading GCPW..."
        Invoke-WebRequest -Uri $GcpwMsiUrl -OutFile $GcpwMsiPath -UseBasicParsing

        Write-Host "  Installing..."
        $process = Start-Process msiexec.exe -ArgumentList "/i `"$GcpwMsiPath`" /quiet /norestart" -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            Write-Error "GCPW installation failed with exit code $($process.ExitCode)"
            exit 1
        }
        Write-Host "  GCPW installed successfully." -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # Step 2: Configure GCPW registry
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "[2/3] Configuring GCPW..." -ForegroundColor Yellow

    if (-not (Test-Path $GcpwRegPath)) {
        New-Item -Path $GcpwRegPath -Force | Out-Null
    }

    Set-ItemProperty -Path $GcpwRegPath -Name "domains_allowed_to_login" -Value $Domain
    Write-Host "  Set domains_allowed_to_login = $Domain"

    Set-ItemProperty -Path $GcpwRegPath -Name "enable_multi_user_login" -Value 1 -Type DWord
    Write-Host "  Set enable_multi_user_login = 1"

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
    # Step 3: Endpoint Verification
    # ------------------------------------------------------------------
    if (-not $SkipEndpointVerification) {
        Write-Host ""
        Write-Host "[3/3] Installing Endpoint Verification..." -ForegroundColor Yellow

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
        Write-Host "[3/3] Skipping Endpoint Verification (flag set)." -ForegroundColor Yellow
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

    $gcpwInstalled = Get-WmiObject Win32_Product -Filter "Name LIKE '%Google Credential Provider%'" -ErrorAction SilentlyContinue
    if ($gcpwInstalled) {
        Write-Host "  GCPW already installed (version $($gcpwInstalled.Version)). Skipping." -ForegroundColor Green
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Host "  Downloading GCPW..."
        Invoke-WebRequest -Uri $GcpwMsiUrl -OutFile $GcpwMsiPath -UseBasicParsing

        Write-Host "  Installing..."
        $process = Start-Process msiexec.exe -ArgumentList "/i `"$GcpwMsiPath`" /quiet /norestart" -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            Write-Error "GCPW installation failed with exit code $($process.ExitCode)"
            exit 1
        }
        Write-Host "  GCPW installed successfully." -ForegroundColor Green
    }

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
        Write-Warning "Backup admin account '$BackupAdminUser' not found. Proceeding anyway — make sure you have another way to log in if something breaks."
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
