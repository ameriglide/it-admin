#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Onboard a new user to sage-amg, mirroring how existing users got there.

.DESCRIPTION
    sage-amg has NLA on. The 38ish users who came over during the 2026-05
    JumpCloud->GCPW cutover had: (a) a local account, (b) their local
    password equal to their Google password, (c) a SID->email association
    in HKLM:\SOFTWARE\Google\GCPW\Users\<SID>. NLA pre-auths their Google
    password and they land in their session.

    This script reproduces the same end state for a new hire:
      1. Creates sage-amg\<SamName> with the supplied password.
      2. Adds them to Remote Desktop Users.
      3. Writes the GCPW SID->email association so GCPW is bookkept the
         same way as the cutover crowd. (Mostly insurance: with NLA on,
         users never see the Google tile, but if NLA ever gets flipped
         off the assoc means they land in this same profile rather than
         a parallel one.)

    Use the same password you set on the user's Google Workspace account
    so they have a single day-one credential.

.PARAMETER SamName
    Local username (typically first.last).

.PARAMETER Password
    Initial password. Use the same value you set on Google.

.PARAMETER Email
    Google email. Defaults to <SamName>@ameriglide.com.

.PARAMETER Force
    Skip the hostname guard.

.EXAMPLE
    .\onboard-sage-amg-user.ps1 -SamName zak.roberts -Password 'Maple-Lantern-Quiet-Cobalt'

.EXAMPLE
    # Cross-domain user
    .\onboard-sage-amg-user.ps1 -SamName someone -Password '...' -Email someone@atlasacces.com
#>
param(
    [Parameter(Mandatory)][string]$SamName,
    [Parameter(Mandatory)][string]$Password,
    [string]$Email,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

if (-not $Force -and $env:COMPUTERNAME -inotmatch '^sage-amg$') {
    Write-Error "Refusing to run on '$env:COMPUTERNAME'. This script is sage-amg-specific. Use -Force to override."
    exit 1
}

if (-not $Email) { $Email = "$($SamName.ToLower())@ameriglide.com" }

$GcpwRegPath = "HKLM:\SOFTWARE\Google\GCPW"

if (Get-LocalUser -Name $SamName -ErrorAction SilentlyContinue) {
    Write-Error "Local user '$SamName' already exists. Aborting."
    exit 1
}

# 1. Create local account
$securePwd = ConvertTo-SecureString $Password -AsPlainText -Force
$user = New-LocalUser -Name $SamName -Password $securePwd -PasswordNeverExpires -Description "Onboarded $(Get-Date -Format yyyy-MM-dd)"
Write-Host "Created sage-amg\$SamName ($($user.SID.Value))" -ForegroundColor Green

# 2. RDP group
Add-LocalGroupMember -Group "Remote Desktop Users" -Member $SamName
Write-Host "Added to Remote Desktop Users" -ForegroundColor Green

# 3. GCPW SID->email association (mirrors deploy-gcpw-sage-amg.ps1 step [4/7])
if (-not (Test-Path $GcpwRegPath)) {
    Write-Warning "GCPW registry root not found at $GcpwRegPath. Skipping SID assoc."
} else {
    $assocPath = "$GcpwRegPath\Users\$($user.SID.Value)"
    if (-not (Test-Path $assocPath)) { New-Item -Path $assocPath -Force | Out-Null }
    Set-ItemProperty -Path $assocPath -Name "email" -Value $Email
    Write-Host "GCPW assoc: $($user.SID.Value) -> $Email" -ForegroundColor Green
}

Write-Host ""
Write-Host "Send to the user:"
Write-Host "  Host : sage-amg"
Write-Host "  User : $SamName"
Write-Host "  Pass : (the same password you set on their Google account)"
Write-Host ""
Write-Host "Optional - on their workstation, to skip mstsc's prompt:"
Write-Host "  cmdkey /generic:TERMSRV/sage-amg.nodes.headscale.mage.net /user:$SamName /pass:<password>"
Write-Host ""
