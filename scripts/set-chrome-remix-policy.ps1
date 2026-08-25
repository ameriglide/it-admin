# set-chrome-remix-policy.ps1
# Grant Remix (production) microphone access and media autoplay in Chrome
# without per-user prompts, via two Chrome machine policies (AG-746):
#   AudioCaptureAllowedUrls  -> mic prompt suppressed for the origin
#   AutoplayAllowlist        -> media autoplay permitted for the origin
#
# Writes HKLM:\SOFTWARE\Policies\Google\Chrome\<Policy>\1 = <origin>. Chrome
# reads these on its next policy refresh (~90 min) or browser restart;
# chrome://policy > Reload policies forces it. Chrome only -- Edge has its own
# policy tree and is not touched. Rollback: delete the two subkeys.
#
# Run as SYSTEM (SSM AWS-RunPowerShellScript or Action1). Idempotent. Prints a
# verdict line (OK/FAIL) so a fleet run can be triaged from output alone.
# ASCII only.
[CmdletBinding()]
param(
    # Scheme + host only, no path or trailing slash.
    [string]$Origin = 'https://remix.ameriglide.com'
)

$ErrorActionPreference = 'Stop'
$Script:Revision = ""

if ($Origin -notmatch '^https?://[A-Za-z0-9.-]+(:\d+)?$') {
    Write-Output "FAIL invalid origin '$Origin' (want scheme://host[:port], no path)"
    exit 1
}

$base = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
$policies = @('AudioCaptureAllowedUrls', 'AutoplayAllowlist')

foreach ($p in $policies) {
    $key = Join-Path $base $p
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name '1' -Value $Origin -PropertyType String -Force | Out-Null
}

# Verify by reading back, so the verdict reflects the registry, not our intent.
$bad = @()
foreach ($p in $policies) {
    $key = Join-Path $base $p
    $v = (Get-ItemProperty -Path $key -Name '1' -ErrorAction SilentlyContinue).'1'
    Write-Output ("{0}\1 = {1}" -f $p, $v)
    if ($v -ne $Origin) { $bad += $p }
}

if ($bad.Count -eq 0) {
    Write-Output "OK $env:COMPUTERNAME chrome policies set for $Origin"
} else {
    Write-Output "FAIL $env:COMPUTERNAME could not verify: $($bad -join ', ')"
    exit 1
}
