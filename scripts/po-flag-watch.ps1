# po-flag-watch.ps1 - read-only watch for the PO print flag coming back on old POs.
# Two scheduled tasks run it every 5 minutes, one per mode, because the two
# halves need different accounts:
#   -Mode Sage      as sage-sync (Interactive): ProvideX ODBC only logs on from
#                   a desktop session, which SYSTEM does not have. Appends to
#                   watch.csv how many POs created before the cutoff are
#                   flagged, how many print-queue rows exist and when the PO
#                   files were last written; when old POs are flagged it also
#                   saves which ones, with their last-updated stamps.
#   -Mode Sessions  as SYSTEM: only an administrator can see who owns other
#                   users' processes. Appends the open Sage task sessions to
#                   sessions.csv.
# Match the two files by time to find the session behind a jump. Writes
# nothing to Sage. ASCII only.
param(
    [ValidateSet('Sage', 'Sessions')][string]$Mode = 'Sage',
    [string]$Dsn = 'sage_ad1',
    [datetime]$CreatedBefore = '2026-09-15',
    [string]$OutDir = 'C:\ProgramData\ag-admin\po-flag-watch',
    [string]$PoDir = 'C:\Sage\Sage 100\MAS90\MAS_AD1\POAD1'
)
$ErrorActionPreference = 'Stop'
$now = Get-Date
$stamp = $now.ToString('yyyyMMdd-HHmmss')

function Write-Line([string]$file, [string]$header, [object[]]$fields) {
    $path = Join-Path $OutDir $file
    if (-not (Test-Path $path)) { $header | Set-Content $path -Encoding ASCII }
    ($fields | ForEach-Object { '"' + (([string]$_) -replace '"', "'") + '"' }) -join ',' | Add-Content $path -Encoding ASCII
}

if ($Mode -eq 'Sessions') {
    # Open Sage task sessions: client-side pvxwin64 processes with their owner.
    $sessions = @(Get-CimInstance Win32_Process -Filter "Name = 'pvxwin64.exe'" | Where-Object { $_.CommandLine -match 'Spawn' } | ForEach-Object {
        $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner
        if ($o.User -and $o.User -ne 'SYSTEM') { "$($o.User)@$($_.CreationDate.ToString('HH:mm'))#$($_.ProcessId)" }
    }) -join ' '
    Write-Line 'sessions.csv' 'Time,Sessions' @($now.ToString('s'), $sessions)
    return
}

$hdr = (Get-Item (Join-Path $PoDir 'PO_PurchaseOrderHeader.M4T')).LastWriteTime.ToString('s')
$prt = (Get-Item (Join-Path $PoDir 'PO_PurchaseOrderPrint.M4T')).LastWriteTime.ToString('s')

$old = ''; $queue = ''; $err = ''
try {
    $c = New-Object System.Data.Odbc.OdbcConnection("DSN=$Dsn;")
    $c.Open()
    $cmd = $c.CreateCommand()
    $cmd.CommandText = "SELECT PurchaseOrderNo, OrderStatus, DateUpdated, TimeUpdated, UserUpdatedKey FROM PO_PurchaseOrderHeader WHERE PrintPurchaseOrders = 'Y' AND DateCreated < {d '$($CreatedBefore.ToString('yyyy-MM-dd'))'}"
    $r = $cmd.ExecuteReader()
    $rows = @(while ($r.Read()) { '{0},{1},{2},{3},{4}' -f $r.GetValue(0), $r.GetValue(1), $r.GetValue(2), $r.GetValue(3), $r.GetValue(4) })
    $r.Close()
    $old = $rows.Count
    $cmd.CommandText = 'SELECT COUNT(*) FROM PO_PurchaseOrderPrint'
    $queue = [string]$cmd.ExecuteScalar()
    $c.Close()
    if ($rows.Count -gt 0) {
        $detail = Join-Path $OutDir "flagged-$stamp.csv"
        'PurchaseOrderNo,OrderStatus,DateUpdated,TimeUpdated,UserUpdatedKey' | Set-Content $detail -Encoding ASCII
        $rows | Add-Content $detail -Encoding ASCII
    }
} catch {
    $err = $_.Exception.Message.Split([char]10)[0]
}

Write-Line 'watch.csv' 'Time,OldFlagged,QueueRows,HeaderWritten,PrintWritten,Error' @($now.ToString('s'), $old, $queue, $hdr, $prt, $err)
