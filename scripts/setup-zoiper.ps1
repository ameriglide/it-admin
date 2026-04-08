<#
.SYNOPSIS
    Install, activate, and configure Zoiper 5 with SIP credentials.

.DESCRIPTION
    Downloads and installs Zoiper 5, activates the Pro license, and writes
    the SIP account config so the phone is ready to use on first launch.

.PARAMETER SipUser
    SIP username (e.g. john.doe).

.PARAMETER SipPassword
    SIP password.

.PARAMETER SipDomain
    SIP domain. Defaults to ameriglide.pstn.twilio.com.

.PARAMETER ZoiperUsername
    Zoiper account username for Pro license activation.

.PARAMETER ZoiperPassword
    Zoiper account password for Pro license activation.

.EXAMPLE
    .\setup-zoiper.ps1 -SipUser "john.doe" -SipPassword "secret" -ZoiperUsername "user@example.com" -ZoiperPassword "pw"
#>

param(
    [Parameter(Mandatory)][string]$SipUser,
    [Parameter(Mandatory)][string]$SipPassword,
    [string]$SipDomain = "ameriglide.pstn.twilio.com",
    [string]$ZoiperUsername,
    [string]$ZoiperPassword,
    [string]$TargetUser
)

# Disable progress bar — speeds up Invoke-WebRequest dramatically
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Install Zoiper 5
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
# Activate Pro license
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

# ---------------------------------------------------------------------------
# Write SIP account config
# ---------------------------------------------------------------------------
Write-Host "Writing SIP config..." -ForegroundColor Yellow

# XML-escape values
function EscapeXml([string]$s) {
    $s.Replace("&","&amp;").Replace("<","&lt;").Replace(">","&gt;").Replace('"',"&quot;").Replace("'","&apos;")
}

$xml = @"
<?xml version="1.0" encoding="utf-8"?>
<options>
  <accounts>
    <account>
      <username>$(EscapeXml $SipUser)</username>
      <password>$(EscapeXml $SipPassword)</password>
      <SIP_domain>$(EscapeXml $SipDomain)</SIP_domain>
      <SIP_transport_type>2</SIP_transport_type>
      <SIP_use_rport>1</SIP_use_rport>
      <SIP_dtmf_style>1</SIP_dtmf_style>
      <reregistration_time>60</reregistration_time>
      <use_ice>1</use_ice>
      <codecs>
        <codec>
          <codec_id>0</codec_id>
          <priority>0</priority>
          <enabled>1</enabled>
        </codec>
        <codec>
          <codec_id>8</codec_id>
          <priority>1</priority>
          <enabled>1</enabled>
        </codec>
        <codec>
          <codec_id>9</codec_id>
          <priority>2</priority>
          <enabled>1</enabled>
        </codec>
      </codecs>
      <stun>
        <use_stun>1</use_stun>
        <stun_host>global.stun.twilio.com</stun_host>
        <stun_port>3478</stun_port>
      </stun>
    </account>
  </accounts>
</options>
"@

# Build list of directories to write the config into
$configDirs = @()

# Always write to Default profile (picked up on first login)
$configDirs += "$env:SystemDrive\Users\Default\AppData\Roaming\Zoiper5"

# If a target user was specified, write to their profile too
if ($TargetUser) {
    $userProfile = "$env:SystemDrive\Users\$TargetUser\AppData\Roaming\Zoiper5"
    if (Test-Path "$env:SystemDrive\Users\$TargetUser") {
        $configDirs += $userProfile
    } else {
        Write-Warning "  User profile for '$TargetUser' not found — will use Default profile only."
    }
}

foreach ($configDir in $configDirs) {
    if (-not (Test-Path $configDir)) {
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
    }
    $configFile = "$configDir\Config.xml"
    Set-Content -Path $configFile -Value $xml -Encoding UTF8
    Write-Host "  SIP config written to $configFile" -ForegroundColor Green
}
Write-Host ""

Write-Host "========================================" -ForegroundColor Green
Write-Host "  Zoiper setup complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
