# po-printflag-raw.ps1 (one-off, follows po-printflag-bulk.ps1)
# Clears the print flag and print-queue rows on POs (default: completed, status X) that
# the PO business object refuses to open. Writes at the ProvideX file level,
# the way Data File Display and Maintenance does: header PRINTPURCHASEORDERS$
# Y -> N, and every PO_PurchaseOrderPrint row for the PO removed. Nothing else
# is touched. Every original record is appended to a backup file before it is
# changed, so the run can be reversed exactly.
# Dry run unless -Apply. Target is -Po <list> or -AllComplete. Stops on the
# first error. ASCII only.
[CmdletBinding()]
param(
    [string[]]$Po = @(),
    [switch]$AllComplete,
    [string[]]$Status = @('X'),
    [switch]$Apply,
    [datetime]$CreatedBefore = '2026-09-15',
    [string]$Dsn = 'sage_ad1',
    [string]$SageHome = 'C:\Sage\Sage 100\MAS90\Home',
    [string]$Dir = 'C:\Sage\Sage 100\MAS90\MAS_AD1\POAD1',
    [string]$LogDir = $env:USERPROFILE
)
$ErrorActionPreference = 'Stop'
$Status = @($Status | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Po = @($Po | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $AllComplete -and $Po.Count -eq 0) { throw 'give -Po <list> or -AllComplete' }

if ($AllComplete) {
    $c = New-Object System.Data.Odbc.OdbcConnection("DSN=$Dsn;")
    $c.Open()
    $cmd = $c.CreateCommand()
    $cmd.CommandText = "SELECT PurchaseOrderNo FROM PO_PurchaseOrderHeader WHERE PrintPurchaseOrders = 'Y' AND OrderStatus IN ($(($Status | ForEach-Object { "'$_'" }) -join ',')) AND DateCreated < {d '$($CreatedBefore.ToString('yyyy-MM-dd'))'}"
    $r = $cmd.ExecuteReader()
    $Po = @(while ($r.Read()) { [string]$r.GetValue(0) })
    $r.Close(); $c.Close()
}
$Targets = @($Po | Sort-Object -Unique)

$mode = if ($Apply) { 'APPLY' } else { 'DRYRUN' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $LogDir "po-printflag-raw-$stamp-$mode.csv"
$bak = Join-Path $LogDir "po-printflag-raw-$stamp-BACKUP.txt"
'PurchaseOrderNo,Result,QueueRowsRemoved,Detail' | Set-Content $log -Encoding ASCII
Write-Host "mode: $mode  targets: $($Targets.Count)  log: $log"
if ($Apply) { Write-Host "backup: $bak" }

$pvx = New-Object -ComObject ProvideX.Script
$pvx.Init($SageHome)
function X([string]$s) { [void]$pvx.Execute($s) }
function E([string]$s) { [string]$pvx.Evaluate($s) }
function Row($po, $res, $n, $d) { ('"{0}","{1}","{2}","{3}"' -f $po, $res, $n, ($d -replace '"', "'")) | Add-Content $log -Encoding ASCII }

$openMode = if ($Apply) { '' } else { 'INPUT ' }
X "H=UNT; OPEN $openMode(H,IOL=*)""$Dir\PO_PurchaseOrderHeader.M4T"""
X "P=UNT; OPEN $openMode(P,IOL=*)""$Dir\PO_PurchaseOrderPrint.M4T"""

# Index the print queue once: PO number -> list of raw keys.
$queue = @{}
# KEY() past the last record raises an error through COM; that ends the scan.
X 'K$=KEF(P)'
while ($true) {
    $k = E 'K$'
    X 'READ (P,KEY=K$)'
    $p = E 'PURCHASEORDERNO$'
    if (-not $queue.ContainsKey($p)) { $queue[$p] = New-Object System.Collections.Generic.List[string] }
    $queue[$p].Add($k)
    try { X 'K$=KEY(P)' } catch { break }
}
$queueTotal = ($queue.Values | Measure-Object -Property Count -Sum).Sum
Write-Host "print queue rows indexed: $queueTotal"

$pass = 0; $skip = 0; $removed = 0; $verdict = ''
try {
    foreach ($poNo in $Targets) {
        if ($poNo -notmatch '^[0-9A-Z]{1,7}$') { throw "bad PO number '$poNo'" }
        X "READ (H,KEY=""$poNo"")"
        $flag = E 'PRINTPURCHASEORDERS$'; $curStatus = E 'ORDERSTATUS$'
        $keys = if ($queue.ContainsKey($poNo)) { @($queue[$poNo]) } else { @() }
        if ($Status -notcontains $curStatus -or $flag -ne 'Y') {
            $skip++; Row $poNo 'SKIP' 0 "status=$curStatus flag=$flag"; continue
        }
        if (-not $Apply) { $pass++; Row $poNo 'DRYRUN' $keys.Count "would clear flag and remove $($keys.Count) queue row(s)"; continue }

        # Backup first: the header flag and every queue row, exactly.
        "HEADER|$poNo|PRINTPURCHASEORDERS$=$flag" | Add-Content $bak -Encoding ASCII
        foreach ($k in $keys) {
            X "K$=""$k""; READ (P,KEY=K$)"
            "QUEUE|$poNo|KEY=[$k]|PRINTTYPE$=$(E 'PRINTTYPE$')|PURCHASEORDERNO$=$(E 'PURCHASEORDERNO$')|APDIVISIONNO$=$(E 'APDIVISIONNO$')|VENDORNO$=$(E 'VENDORNO$')" | Add-Content $bak -Encoding ASCII
        }

        X "EXTRACT (H,KEY=""$poNo"")"
        X 'PRINTPURCHASEORDERS$="N"; WRITE (H)'
        foreach ($k in $keys) { X "K$=""$k""; REMOVE (P,KEY=K$)" }

        # Re-read both from the file.
        X "READ (H,KEY=""$poNo"")"
        $after = E 'PRINTPURCHASEORDERS$'
        $left = 0
        # A missing key raises error 11 through COM; that is the expected outcome.
        foreach ($k in $keys) { try { X "K$=""$k""; READ (P,KEY=K$)"; $left++ } catch { } }
        if ($after -ne 'N' -or $left -ne 0) {
            Row $poNo 'REVIEW' $keys.Count "after: flag=$after queueRowsLeft=$left"
            $verdict = "STOPPED (PO $poNo did not verify)"; break
        }
        $pass++; $removed += $keys.Count
        Row $poNo 'PASS' $keys.Count ''
    }
}
catch {
    $verdict = "STOPPED on error at PO $poNo : $($_.Exception.Message.Split([char]10)[0])"
    Row $poNo 'ERROR' 0 $verdict
}
finally {
    try { X 'CLOSE (H); CLOSE (P)' } catch { }
}
if (-not $verdict) { $verdict = if ($Apply) { "PASS ($pass cleared, $removed queue rows removed, $skip skipped)" } else { "DRY RUN ($pass would be cleared, $skip skipped, nothing written)" } }
Write-Host "VERDICT: $verdict"
