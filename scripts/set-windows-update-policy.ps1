#requires -Version 5.1
<#
.SYNOPSIS
  Make Action1 the sole authority for Windows updates: disable Windows'
  own auto-update and pin the feature release so the OS never self-upgrades.
  Self-pinning -- auto-detects current product + release unless overridden.
.NOTES
  ASCII-only (Windows PowerShell 5.1 parses scripts as ANSI).
#>
param(
    [string]$ProductVersion,   # "Windows 10" / "Windows 11"; auto-detected if omitted
    [string]$TargetRelease     # "22H2" / "24H2"; auto-detected if omitted
)

$ErrorActionPreference = 'Stop'

$cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
if (-not $TargetRelease) {
    $TargetRelease = (Get-ItemProperty $cv).DisplayVersion
}
if (-not $ProductVersion) {
    $build = [int](Get-ItemProperty $cv).CurrentBuildNumber
    $ProductVersion = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
}
Write-Host "Pinning to $ProductVersion $TargetRelease; Action1 owns updates." -ForegroundColor Yellow

$wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$au = "$wu\AU"
foreach ($k in @($wu, $au)) {
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
}

Set-ItemProperty -Path $au -Name 'NoAutoUpdate'                 -Value 1 -Type DWord
Set-ItemProperty -Path $au -Name 'AUOptions'                   -Value 2 -Type DWord
Set-ItemProperty -Path $au -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1 -Type DWord
Set-ItemProperty -Path $wu -Name 'TargetReleaseVersion'        -Value 1 -Type DWord
Set-ItemProperty -Path $wu -Name 'TargetReleaseVersionInfo'    -Value $TargetRelease -Type String
Set-ItemProperty -Path $wu -Name 'ProductVersion'             -Value $ProductVersion -Type String
Set-ItemProperty -Path $wu -Name 'DisableOSUpgrade'           -Value 1 -Type DWord

Write-Host "  Windows Update policy applied." -ForegroundColor Green
