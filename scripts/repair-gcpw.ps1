<#
.SYNOPSIS
    Repairs GCPW by doing a clean uninstall and reinstall.

.PARAMETER Domain
    Your Google Workspace domain (e.g. ameriglide.com)

.EXAMPLE
    .\repair-gcpw.ps1 -Domain ameriglide.com
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Domain
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  GCPW Repair" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Uninstall
Write-Host "[1/4] Uninstalling GCPW..." -ForegroundColor Yellow
$gcpw = Get-WmiObject Win32_Product -Filter "Name LIKE '%Google Credential Provider%'" -ErrorAction SilentlyContinue
if ($gcpw) {
    $gcpw.Uninstall() | Out-Null
    Write-Host "  Uninstalled via WMI." -ForegroundColor Green
} else {
    Write-Host "  Not found in WMI, trying msiexec..." -ForegroundColor Yellow
    $msi = "$env:TEMP\GCPWStandaloneEnterprise64.msi"
    if (Test-Path $msi) {
        Start-Process msiexec.exe -ArgumentList "/x `"$msi`" /quiet /norestart" -Wait -PassThru | Out-Null
    }
}

# Step 2: Clean up
Write-Host ""
Write-Host "[2/4] Cleaning up..." -ForegroundColor Yellow
Remove-Item "HKLM:\SOFTWARE\Google\GCPW" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  Removed GCPW registry keys."
$gcpwDirs = @(
    "C:\Program Files\Google\Credential Provider",
    "C:\Program Files (x86)\Google\Credential Provider"
)
foreach ($dir in $gcpwDirs) {
    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  Removed $dir"
    }
}

# Step 3: Reinstall
Write-Host ""
Write-Host "[3/4] Reinstalling GCPW..." -ForegroundColor Yellow
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$msi = "$env:TEMP\gcpw_fresh.msi"
Write-Host "  Downloading..."
Invoke-WebRequest -Uri "https://dl.google.com/credentialprovider/GCPWStandaloneEnterprise64.msi" -OutFile $msi -UseBasicParsing
Write-Host "  Installing..."
$process = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart /l*v `"$env:TEMP\gcpw_repair.log`"" -Wait -PassThru
if ($process.ExitCode -ne 0) {
    Write-Error "Install failed (exit code $($process.ExitCode)). Check $env:TEMP\gcpw_repair.log"
    exit 1
}
Write-Host "  Installed." -ForegroundColor Green

# Step 4: Configure
Write-Host ""
Write-Host "[4/4] Configuring..." -ForegroundColor Yellow
New-Item -Path "HKLM:\SOFTWARE\Google\GCPW" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Google\GCPW" -Name "domains_allowed_to_login" -Value $Domain
Set-ItemProperty -Path "HKLM:\SOFTWARE\Google\GCPW" -Name "enable_multi_user_login" -Value 1 -Type DWord
Write-Host "  Set domains_allowed_to_login = $Domain"
Write-Host "  Set enable_multi_user_login = 1"

# Verify
if (-not (Test-Path "HKCR:\")) {
    New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -ErrorAction SilentlyContinue | Out-Null
}
$clsid = Get-ItemProperty "HKCR:\CLSID\{0B5BFDF0-4594-47AC-940A-CFC69ABC561C}\InprocServer32" -ErrorAction SilentlyContinue
if ($clsid) {
    $dllPath = $clsid.'(default)'
    if (Test-Path $dllPath) {
        Write-Host "  DLL verified at $dllPath" -ForegroundColor Green
    } else {
        Write-Warning "  CLSID registered but DLL missing at $dllPath"
    }
} else {
    Write-Warning "  CLSID not registered. GCPW may not show on login screen."
}

# Kick GoogleUpdater -- required for GCPW tile to actually render on the lock screen.
# The MSI install completes but post-install initialization is done by the updater task.
$updaterTasks = Get-ScheduledTask -TaskPath "\GoogleUpdater\" -ErrorAction SilentlyContinue
if ($updaterTasks) {
    Write-Host ""
    Write-Host "Triggering GoogleUpdater to finalize GCPW initialization..." -ForegroundColor Yellow
    foreach ($task in $updaterTasks) {
        try {
            Start-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction Stop
            Write-Host "  Started $($task.TaskName)" -ForegroundColor DarkGray
        } catch {
            Write-Warning "  Failed to start $($task.TaskName): $_"
        }
    }
    Start-Sleep -Seconds 5
} else {
    Write-Warning "No GoogleUpdater tasks found. GCPW tile may not render until updater runs."
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Repair complete! Reboot to test." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
