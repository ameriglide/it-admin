# sage-default-printer-guard.ps1
# Puts a Sage user's office printer back as their Windows default after the
# spooler drops it. Runs in the user's own session from the scheduled task
# registered by install-sage-default-printer-guard.ps1. ASCII only.
#
# Why: on the Sage RDS host a default that points at a per-user printer
# connection does not survive a session reconnect. The spooler finds the
# default unusable and falls back to the first local printer, the Sage 100
# Paperless Office driver (PrintService/Admin event 823 with
# DefaultPrinterSelectedBySpooler=1). Guacamole reconnects many times a day,
# so a default set by hand is gone within minutes.
#
# It only acts when the user has exactly ONE printer connection and the
# current default is empty or the Paperless driver. A default the user picked
# themselves (Print to PDF, say) is left alone.
param(
    # Seconds to wait before each check, one after another: checks land 5, 15,
    # 45, 105 and 225 seconds in. Asking for the default is what makes the
    # spooler notice a broken one, and after a reconnect the connection is not
    # usable straight away: the set fails with win32 1801 (invalid printer
    # name), usually for a few seconds, once seen for over a minute. The later
    # checks are the retry. Keep the total under the task's 10-minute limit.
    [int[]]$CheckAfterSeconds = @(5, 10, 30, 60, 120),
    [switch]$WhatIfOnly
)
$ErrorActionPreference = 'Stop'
$Script:Revision = 'dev'

$fallbackPattern = 'Sage 100 Paperless Office Driver*'
$logDir  = Join-Path $env:LOCALAPPDATA 'ag-admin'
$logFile = Join-Path $logDir 'default-printer-guard.log'

function Write-Log([string]$Message) {
    try {
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 200KB) {
            Set-Content -Path $logFile -Value (Get-Content $logFile -Tail 500) -Encoding ASCII
        }
        Add-Content -Path $logFile -Encoding ASCII `
            -Value ("{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $PID, $Message)
    } catch { }
}

# The user's printer connections, as \\server\printer names. The registry key
# names use commas where the UNC path has backslashes.
function Get-ConnectionPrinter {
    $key = 'HKCU:\Printers\Connections'
    if (-not (Test-Path $key)) { return @() }
    @(Get-ChildItem $key | ForEach-Object { $_.PSChildName -replace ',', '\' })
}

# Asks the spooler, not the registry: this is the call that makes the spooler
# validate the default and fall back if it cannot use it.
function Get-DefaultPrinterName {
    Add-Type -AssemblyName System.Drawing
    $settings = New-Object System.Drawing.Printing.PrinterSettings
    if ($settings.IsDefaultPrinter) { return $settings.PrinterName }
    return ''
}

try {
    # @() here, not only inside the function: PowerShell unrolls a one-element
    # array on return, and indexing the resulting string yields its first char.
    $connections = @(Get-ConnectionPrinter)
    # Most Sage users have no office printer; say nothing and leave no log.
    if ($connections.Count -eq 0) { return }
    if ($connections.Count -ne 1) {
        Write-Log ("skip: {0} printer connections, need exactly 1" -f $connections.Count)
        return
    }
    $wanted = $connections[0]

    foreach ($delay in $CheckAfterSeconds) {
        Start-Sleep -Seconds $delay
        $current = Get-DefaultPrinterName
        # Done. A later fallback logs event 823, which starts a fresh run.
        if ($current -eq $wanted) { return }
        if ($current -and $current -notlike $fallbackPattern) {
            Write-Log "leave: default is '$current', chosen by the user"
            return
        }
        if ($WhatIfOnly) {
            Write-Log "whatif: would change default from '$current' to '$wanted'"
            continue
        }
        # The spooler's own call, not WScript.Network: that one writes the
        # registry value itself in a driver,port form the spooler never uses
        # and logs no event 823.
        if (-not ('AgAdmin.Spooler' -as [type])) {
            Add-Type -Namespace AgAdmin -Name Spooler -MemberDefinition `
                '[DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool SetDefaultPrinter(string name);'
        }
        $ok  = [AgAdmin.Spooler]::SetDefaultPrinter($wanted)
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Log ("set: '{0}' -> '{1}', ok={2} win32={3}, now '{4}'" -f `
            $current, $wanted, $ok, $err, (Get-DefaultPrinterName))
    }
} catch {
    Write-Log ("error: {0}" -f $_.Exception.Message)
}
