# install-sage-default-printer-guard.ps1
# Installs (idempotently) the Sage default printer guard on the Sage RDS host:
# copies sage-default-printer-guard.ps1 to ProgramData and registers a
# scheduled task that runs it in the user's own session. Run elevated, from the
# folder holding both scripts. ASCII only.
#
#   .\install-sage-default-printer-guard.ps1 -OnlyUser jdoe   # pilot, one account
#   .\install-sage-default-printer-guard.ps1                  # every Sage user
#   .\install-sage-default-printer-guard.ps1 -Uninstall
param(
    # Pilot on one local account instead of the whole group.
    [string]$OnlyUser,
    # Group whose members get the guard. Default: Remote Desktop Users, which
    # is the Sage users and leaves out service accounts.
    [string]$GroupSid = 'S-1-5-32-555',
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$Script:Revision = 'dev'

$taskName  = 'AG Sage Default Printer Guard'
$destDir   = Join-Path $env:ProgramData 'ag-admin'
$guardPath = Join-Path $destDir 'sage-default-printer-guard.ps1'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $guardPath -ErrorAction SilentlyContinue
    Write-Host "  Removed scheduled task '$taskName' and $guardPath." -ForegroundColor Green
    return
}

$source = Join-Path $PSScriptRoot 'sage-default-printer-guard.ps1'
if (-not (Test-Path $source)) { throw "sage-default-printer-guard.ps1 not found next to this script." }
if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force $destDir | Out-Null }
if ((Resolve-Path $source).Path -ne $guardPath) { Copy-Item $source $guardPath -Force }

if ($OnlyUser) {
    $account   = "$env:COMPUTERNAME\$OnlyUser"
    $null      = (New-Object System.Security.Principal.NTAccount($account)).Translate(
                     [System.Security.Principal.SecurityIdentifier])
    $principal = "<UserId>$account</UserId><LogonType>InteractiveToken</LogonType>"
    $who       = "<UserId>$account</UserId>"
} else {
    $principal = "<GroupId>$GroupSid</GroupId>"
    $who       = ''
}

# Three triggers: logon, every session reconnect, and the spooler's own report
# that it replaced the default (event 823, DefaultPrinterSelectedBySpooler=1).
# The cmdlets cannot build the last two, hence the XML.
$eventQuery = "&lt;QueryList&gt;&lt;Query Id='0' Path='Microsoft-Windows-PrintService/Admin'&gt;" +
    "&lt;Select Path='Microsoft-Windows-PrintService/Admin'&gt;" +
    "*[System[Provider[@Name='Microsoft-Windows-PrintService'] and (EventID=823)]] and " +
    "*[UserData[ChangingDefaultPrinter[DefaultPrinterSelectedBySpooler='1']]]" +
    "&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;"

# conhost --headless keeps a console window from flashing in the user's session.
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Restores a Sage user's office printer as the Windows default after the spooler drops it on session reconnect. See docs/runbooks/iai-sage-user-printers.md in it-admin.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled>$who</LogonTrigger>
    <SessionStateChangeTrigger><Enabled>true</Enabled><StateChange>RemoteConnect</StateChange>$who</SessionStateChangeTrigger>
    <EventTrigger><Enabled>true</Enabled><Subscription>$eventQuery</Subscription></EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">$principal<RunLevel>LeastPrivilege</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Hidden>true</Hidden>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>conhost.exe</Command>
      <Arguments>--headless powershell.exe -NoProfile -NonInteractive -File "$guardPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Xml $xml | Out-Null
$scope = if ($OnlyUser) { "user $OnlyUser only" } else { "group $GroupSid" }
Write-Host "  Registered scheduled task '$taskName' ($scope)." -ForegroundColor Green
