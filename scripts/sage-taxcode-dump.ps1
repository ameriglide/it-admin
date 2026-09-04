# scripts/sage-taxcode-dump.ps1
# Dumps the Sage 100 sales tax code tables and Visual Integrator job tables as
# TSV sections on stdout, read-only, from either the live system (-Source live,
# through an ODBC DSN) or the Aug 28 pre-cutover snapshot directory
# (-Source snapshot, DSN-less local-file connection). Feed two dumps to
# bin/sage-taxcode-diff. Runs on the Sage server as a Sage user with Unified
# Login (verified over plain SSH, AG-806). ASCII only.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('live', 'snapshot')][string]$Source,
    [string]$Dsn = 'sage_ad1',
    [string]$SnapshotDir = 'C:\sage-migrate\extract\MAS90',
    [string]$SageHome = 'C:\Sage\Sage 100\MAS90\Home'
)
$Script:Revision = ""
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sage-taxcode-lib.ps1')

$queries = [ordered]@{
    'SY_SalesTaxCode'       = 'SELECT TaxCode, TaxCodeDesc, TaxCodeShortDesc, TaxOnTax, TaxClassForTaxOnTax, TaxLimit, ExpenseToVendorItem, RetentionTaxable FROM SY_SalesTaxCode'
    'SY_SalesTaxCodeDetail' = 'SELECT TaxCode, TaxClass, SalesTaxable, PurchasesTaxable, TaxRate, NonRecoverablePercent FROM SY_SalesTaxCodeDetail'
    'SY_SalesTaxClass'      = 'SELECT TaxClass, TaxClassDesc FROM SY_SalesTaxClass'
    'VI_JobHeader'          = 'SELECT * FROM VI_JobHeader'
    'VI_JobImportElements'  = 'SELECT * FROM VI_JobImportElements'
    'VI_JobExportElements'  = 'SELECT * FROM VI_JobExportElements'
    'VI_JobExportSelection' = 'SELECT * FROM VI_JobExportSelection'
    'VI_JobImportSelection' = 'SELECT * FROM VI_JobImportSelection'
}

if ($Source -eq 'live') {
    $cs = Get-SageLiveConnectionString -Dsn $Dsn
} else {
    $cs = Get-SageSnapshotConnectionString -SnapshotDir $SnapshotDir -SageHome $SageHome
}

$cxn = New-Object System.Data.Odbc.OdbcConnection($cs)
$cxn.ConnectionTimeout = 45
$cxn.Open()
try {
    foreach ($table in $queries.Keys) {
        "##### $table"
        $cmd = $cxn.CreateCommand()
        $cmd.CommandText = $queries[$table]
        $cmd.CommandTimeout = 180
        try {
            $rd = $cmd.ExecuteReader()
            try {
                $cols = @()
                for ($i = 0; $i -lt $rd.FieldCount; $i++) { $cols += $rd.GetName($i) }
                $cols -join "`t"
                while ($rd.Read()) {
                    $vals = @()
                    for ($i = 0; $i -lt $rd.FieldCount; $i++) { $vals += ConvertTo-TsvValue $rd.GetValue($i) }
                    $vals -join "`t"
                }
            } finally { $rd.Close() }
        } catch {
            "!ERROR`t$($_.Exception.Message)"
        }
    }
} finally { $cxn.Close() }
