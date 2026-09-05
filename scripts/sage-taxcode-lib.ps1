# Shared helpers for sage-taxcode-dump.ps1 and sage-taxcode-apply.ps1 (AG-806).
# Pure functions only: no ODBC, no COM, so they can be exercised by Pester on
# any machine. Dot-source this file. ASCII only.
$Script:Revision = "346bbe3"

function Get-SageLiveConnectionString {
    param([Parameter(Mandatory)][string]$Dsn)
    return "DSN=$Dsn;"
}

function Get-SageSnapshotConnectionString {
    # DSN-less local-file connection. The 2026 driver reads the Aug 28 snapshot
    # directory directly when Directory/Prefix point at it and ViewDLL points at
    # the live Home (verified 2026-09-04, AG-806). No RemotePVKIOHost: local mode.
    param(
        [Parameter(Mandatory)][string]$SnapshotDir,
        [Parameter(Mandatory)][string]$SageHome
    )
    $dir = $SnapshotDir.TrimEnd('\')
    $sageHomeDir = $SageHome.TrimEnd('\')
    return ('Driver={MAS 90 4.0 ODBC Driver};Directory=' + $dir +
        ';Prefix=' + $dir + '\SY\, ' + $dir + '\==\;ViewDLL=' + $sageHomeDir +
        '\;Company=AD1;SILENT=1;DirtyReads=1;StripTrailingSpaces=1;')
}

function ConvertTo-TsvValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    $s = $s -replace "[`t`r`n]", ' '
    return $s.TrimEnd()
}

function ConvertTo-SageYesNo {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    switch -Regex (([string]$Value).Trim()) {
        '^(?i:y|yes|true|1)$' { return 'Y' }
        '^(?i:n|no|false|0)?$' { return 'N' }
        default { throw "ConvertTo-SageYesNo: cannot interpret '$Value' as Y/N" }
    }
}

function Test-PlanShape {
    param([Parameter(Mandatory)][object]$Plan)
    foreach ($name in @('addHeaders', 'addLines', 'updateLines', 'liveOnlyHeaders', 'liveOnlyLines', 'changedHeaders', 'viJobsMissing')) {
        if ($null -eq $Plan.PSObject.Properties[$name]) {
            throw "plan is missing the '$name' bucket"
        }
    }
    return $true
}

function Format-ApplyLogLine {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Key,
        [AllowEmptyString()][string]$Before = '',
        [AllowEmptyString()][string]$After = '',
        [Parameter(Mandatory)][string]$Result
    )
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    return ($ts, $Phase, $Key, $Before, $After, $Result) -join "`t"
}

function ConvertTo-HeaderLogValue {
    param([Parameter(Mandatory)][object]$Header)
    return ('desc={0}|short={1}|tot={2}|totclass={3}|limit={4}|etv={5}|ret={6}' -f $Header.TaxCodeDesc, $Header.TaxCodeShortDesc, $Header.TaxOnTax, $Header.TaxClassForTaxOnTax, $Header.TaxLimit, $Header.ExpenseToVendorItem, $Header.RetentionTaxable)
}

function ConvertTo-LineLogValue {
    param([Parameter(Mandatory)][object]$Line)
    return ('sales={0}|purch={1}|rate={2}|nonrec={3}' -f $Line.SalesTaxable, $Line.PurchasesTaxable, $Line.TaxRate, $Line.NonRecoverablePercent)
}
