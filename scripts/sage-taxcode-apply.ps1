# scripts/sage-taxcode-apply.ps1
# Replays a bin/sage-taxcode-diff plan into Sage 100 through the Business
# Object Interface (BOI): adds the missing sales tax code headers, adds the
# missing tax-class lines, then updates the changed lines. Dry run unless
# -Apply is given. Every write is verified by re-reading through the same
# object; the first mismatch stops the run. Refuses a plan that carries
# changedHeaders (those need a human decision first). -SelfTest writes, reads
# back, and deletes one clearly named test code and exits.
# Run on the Sage server as a Sage user with Unified Login (verified over plain
# SSH, AG-806). This is run by a person, on purpose. ASCII only.
[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'plan')][string]$Plan,
    [Parameter(ParameterSetName = 'plan')][switch]$Apply,
    [Parameter(Mandatory, ParameterSetName = 'selftest')][switch]$SelfTest,
    [string]$Company = 'AD1',
    [string]$SageHome = 'C:\Sage\Sage 100\MAS90\Home',
    [string]$Log = (Join-Path $env:ProgramData 'ag-admin\sage-taxcode-apply.log')
)
$Script:Revision = "643f1cd"
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sage-taxcode-lib.ps1')

$logDir = Split-Path $Log -Parent
if ($logDir) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
function Write-Log([string]$Line) { Add-Content -Path $Log -Value $Line; Write-Host $Line }

function Connect-Sage {
    $pvx = New-Object -ComObject ProvideX.Script
    $pvx.Init($SageHome)
    $oSS = $pvx.NewObject('SY_Session')
    if ($oSS.nLogon() -ne 1) { throw "BOI logon failed: $($oSS.sLastErrorMsg)" }
    if ($oSS.nSetCompany($Company) -ne 1) { throw "nSetCompany $Company failed: $($oSS.sLastErrorMsg)" }
    [void]$oSS.nSetModule('S/Y')
    $task = $oSS.nLookupTask('SY_SalesTaxCode_ui')
    [void]$oSS.nSetProgram($task)
    return @{ pvx = $pvx; session = $oSS }
}

function Get-Str($obj, [string]$name) { $v = ''; [void]$obj.nGetValue($name, [ref]$v); return [string]$v }
function Get-Num($obj, [string]$name) { $v = 0.0; [void]$obj.nGetValue($name, [ref]$v); return [double]$v }
function Assert-Ret([string]$what, $ret, $obj) { if ($ret -ne 1) { throw "$what returned $ret : $($obj.sLastErrorMsg)" } }

function Read-Header($o, [string]$code) {
    if ($o.nFind($code) -ne 1) { return $null }
    return [pscustomobject]@{
        TaxCode = $code; TaxCodeDesc = Get-Str $o 'TaxCodeDesc$'; TaxCodeShortDesc = Get-Str $o 'TaxCodeShortDesc$'
        TaxOnTax = Get-Str $o 'TaxOnTax$'; TaxClassForTaxOnTax = Get-Str $o 'TaxClassForTaxOnTax$'
        TaxLimit = [string](Get-Num $o 'TaxLimit'); ExpenseToVendorItem = Get-Str $o 'ExpenseToVendorItem$'; RetentionTaxable = Get-Str $o 'RetentionTaxable$'
    }
}

function Read-Line($d, [string]$code, [string]$class) {
    [void]$d.nSetKeyValue('TaxCode$', $code); [void]$d.nSetKeyValue('TaxClass$', $class)
    if ($d.nSetKey() -ne 1) { return $null }
    return [pscustomobject]@{
        TaxCode = $code; TaxClass = $class; SalesTaxable = Get-Str $d 'SalesTaxable$'; PurchasesTaxable = Get-Str $d 'PurchasesTaxable$'
        TaxRate = [string](Get-Num $d 'TaxRate'); NonRecoverablePercent = [string](Get-Num $d 'NonRecoverablePercent')
    }
}

function Test-HeaderMatches($want, $got) {
    return ($got.TaxCodeDesc -eq $want.TaxCodeDesc) -and ($got.TaxCodeShortDesc -eq $want.TaxCodeShortDesc) -and
        ((ConvertTo-SageYesNo $got.TaxOnTax) -eq (ConvertTo-SageYesNo $want.TaxOnTax)) -and ($got.TaxClassForTaxOnTax -eq $want.TaxClassForTaxOnTax) -and
        ([double]$got.TaxLimit -eq [double]$want.TaxLimit) -and ((ConvertTo-SageYesNo $got.ExpenseToVendorItem) -eq (ConvertTo-SageYesNo $want.ExpenseToVendorItem)) -and
        ((ConvertTo-SageYesNo $got.RetentionTaxable) -eq (ConvertTo-SageYesNo $want.RetentionTaxable))
}

function Test-LineMatches($want, $got) {
    return ((ConvertTo-SageYesNo $got.SalesTaxable) -eq (ConvertTo-SageYesNo $want.SalesTaxable)) -and
        ((ConvertTo-SageYesNo $got.PurchasesTaxable) -eq (ConvertTo-SageYesNo $want.PurchasesTaxable)) -and
        ([double]$got.TaxRate -eq [double]$want.TaxRate) -and ([double]$got.NonRecoverablePercent -eq [double]$want.NonRecoverablePercent)
}

function Write-Header($o, $h, [bool]$expectNew) {
    $ret = $o.nSetKey($h.TaxCode)
    if ($expectNew -and $ret -ne 2) { return "skip: nSetKey=$ret (already exists)" }
    if (-not $expectNew -and $ret -ne 1) { return "skip: nSetKey=$ret (not found)" }
    Assert-Ret 'TaxCodeDesc' ($o.nSetValue('TaxCodeDesc$', [string]$h.TaxCodeDesc)) $o
    Assert-Ret 'TaxCodeShortDesc' ($o.nSetValue('TaxCodeShortDesc$', [string]$h.TaxCodeShortDesc)) $o
    Assert-Ret 'TaxOnTax' ($o.nSetValue('TaxOnTax$', (ConvertTo-SageYesNo $h.TaxOnTax))) $o
    if ($h.TaxClassForTaxOnTax) { Assert-Ret 'TaxClassForTaxOnTax' ($o.nSetValue('TaxClassForTaxOnTax$', [string]$h.TaxClassForTaxOnTax)) $o }
    Assert-Ret 'TaxLimit' ($o.nSetValue('TaxLimit', [double]$h.TaxLimit)) $o
    Assert-Ret 'ExpenseToVendorItem' ($o.nSetValue('ExpenseToVendorItem$', (ConvertTo-SageYesNo $h.ExpenseToVendorItem))) $o
    Assert-Ret 'RetentionTaxable' ($o.nSetValue('RetentionTaxable$', (ConvertTo-SageYesNo $h.RetentionTaxable))) $o
    $w = $o.nWrite()
    if ($w -ne 1) { throw "nWrite $($h.TaxCode) returned $w : $($o.sLastErrorMsg)" }
    $got = Read-Header $o $h.TaxCode
    if ($null -eq $got) { throw "verify: $($h.TaxCode) not found after write" }
    if (-not (Test-HeaderMatches $h $got)) { throw "verify: $($h.TaxCode) read back as $(ConvertTo-HeaderLogValue $got), wanted $(ConvertTo-HeaderLogValue $h)" }
    return "nSetKey=$ret nWrite=1 verify=ok"
}

function Write-Line($d, $l, [bool]$expectNew) {
    [void]$d.nSetKeyValue('TaxCode$', [string]$l.TaxCode); [void]$d.nSetKeyValue('TaxClass$', [string]$l.TaxClass)
    $ret = $d.nSetKey()
    if ($expectNew -and $ret -ne 2) { return "skip: nSetKey=$ret (already exists)" }
    if (-not $expectNew -and $ret -ne 1) { return "skip: nSetKey=$ret (not found)" }
    Assert-Ret 'SalesTaxable' ($d.nSetValue('SalesTaxable$', (ConvertTo-SageYesNo $l.SalesTaxable))) $d
    Assert-Ret 'PurchasesTaxable' ($d.nSetValue('PurchasesTaxable$', (ConvertTo-SageYesNo $l.PurchasesTaxable))) $d
    Assert-Ret 'TaxRate' ($d.nSetValue('TaxRate', [double]$l.TaxRate)) $d
    Assert-Ret 'NonRecoverablePercent' ($d.nSetValue('NonRecoverablePercent', [double]$l.NonRecoverablePercent)) $d
    $w = $d.nWrite()
    if ($w -ne 1) { throw "nWrite $($l.TaxCode)/$($l.TaxClass) returned $w : $($d.sLastErrorMsg)" }
    $got = Read-Line $d $l.TaxCode $l.TaxClass
    if ($null -eq $got) { throw "verify: $($l.TaxCode)/$($l.TaxClass) not found after write" }
    if (-not (Test-LineMatches $l $got)) { throw "verify: $($l.TaxCode)/$($l.TaxClass) read back as $(ConvertTo-LineLogValue $got), wanted $(ConvertTo-LineLogValue $l)" }
    return "nSetKey=$ret nWrite=1 verify=ok"
}

if ($SelfTest) {
    $key = 'ZZ AG806 SPIKE'
    $s = Connect-Sage
    $o = $s.pvx.NewObject('SY_SalesTaxCode_bus', $s.session)
    $d = $s.pvx.NewObject('SY_SalesTaxCodeDetail_bus', $s.session)
    $h = [pscustomobject]@{ TaxCode = $key; TaxCodeDesc = 'AG-806 self test - delete me'; TaxCodeShortDesc = 'AG806'; TaxOnTax = 'N'; TaxClassForTaxOnTax = ''; TaxLimit = '0'; ExpenseToVendorItem = 'N'; RetentionTaxable = 'N' }
    $l = [pscustomobject]@{ TaxCode = $key; TaxClass = 'TX'; SalesTaxable = 'Y'; PurchasesTaxable = 'N'; TaxRate = '1.25'; NonRecoverablePercent = '0' }
    try {
        Write-Log (Format-ApplyLogLine -Phase 'selftest-header' -Key $key -Before '' -After (ConvertTo-HeaderLogValue $h) -Result (Write-Header $o $h $true))
        Write-Log (Format-ApplyLogLine -Phase 'selftest-line' -Key "$key/TX" -Before '' -After (ConvertTo-LineLogValue $l) -Result (Write-Line $d $l $true))
        [void]$o.nSetKey($key); $del = $o.nDelete()
        $gone = ($o.nFind($key) -eq 0) -and ($null -eq (Read-Line $d $key 'TX'))
        Write-Log (Format-ApplyLogLine -Phase 'selftest-delete' -Key $key -Before '' -After '' -Result "nDelete=$del gone=$gone")
        if (-not $gone) { Write-Log 'SELFTEST FAILED: test code still present'; exit 3 }
        Write-Log 'SELFTEST OK'
        exit 0
    } catch {
        Write-Log "STOP: $($_.Exception.Message)"
        exit 3
    } finally {
        try { $o.DropObject(); $d.DropObject(); $s.session.DropObject() } catch { }
    }
}

$planObj = Get-Content -Path $Plan -Raw | ConvertFrom-Json
[void](Test-PlanShape $planObj)
if (@($planObj.changedHeaders).Count -gt 0) {
    Write-Log "REFUSED: plan has $(@($planObj.changedHeaders).Count) changedHeaders; resolve them by hand first"
    exit 2
}
$mode = if ($Apply) { 'APPLY' } else { 'DRY RUN' }
Write-Log "sage-taxcode-apply $mode plan=$Plan generated=$($planObj.generatedAt) addHeaders=$(@($planObj.addHeaders).Count) addLines=$(@($planObj.addLines).Count) updateLines=$(@($planObj.updateLines).Count)"

if (-not $Apply) {
    foreach ($h in $planObj.addHeaders) { Write-Log (Format-ApplyLogLine -Phase 'would-addHeader' -Key $h.TaxCode -Before '' -After (ConvertTo-HeaderLogValue $h) -Result 'dry-run') }
    foreach ($l in $planObj.addLines) { Write-Log (Format-ApplyLogLine -Phase 'would-addLine' -Key "$($l.TaxCode)/$($l.TaxClass)" -Before '' -After (ConvertTo-LineLogValue $l) -Result 'dry-run') }
    foreach ($u in $planObj.updateLines) { Write-Log (Format-ApplyLogLine -Phase 'would-updateLine' -Key "$($u.key.TaxCode)/$($u.key.TaxClass)" -Before (ConvertTo-LineLogValue $u.from) -After (ConvertTo-LineLogValue $u.to) -Result 'dry-run') }
    Write-Log 'DRY RUN complete; re-run with -Apply to write'
    exit 0
}

$s = Connect-Sage
$o = $s.pvx.NewObject('SY_SalesTaxCode_bus', $s.session)
$d = $s.pvx.NewObject('SY_SalesTaxCodeDetail_bus', $s.session)
$counts = @{ addHeader = 0; addLine = 0; updateLine = 0; skipped = 0 }
try {
    foreach ($h in $planObj.addHeaders) {
        $r = Write-Header $o $h $true
        Write-Log (Format-ApplyLogLine -Phase 'addHeader' -Key $h.TaxCode -Before '' -After (ConvertTo-HeaderLogValue $h) -Result $r)
        if ($r -like 'skip:*') { $counts.skipped++ } else { $counts.addHeader++ }
    }
    foreach ($l in $planObj.addLines) {
        $r = Write-Line $d $l $true
        Write-Log (Format-ApplyLogLine -Phase 'addLine' -Key "$($l.TaxCode)/$($l.TaxClass)" -Before '' -After (ConvertTo-LineLogValue $l) -Result $r)
        if ($r -like 'skip:*') { $counts.skipped++ } else { $counts.addLine++ }
    }
    foreach ($u in $planObj.updateLines) {
        $current = Read-Line $d $u.key.TaxCode $u.key.TaxClass
        if ($null -ne $current -and -not (Test-LineMatches $u.from $current)) {
            Write-Log (Format-ApplyLogLine -Phase 'updateLine' -Key "$($u.key.TaxCode)/$($u.key.TaxClass)" -Before (ConvertTo-LineLogValue $current) -After (ConvertTo-LineLogValue $u.to) -Result 'STOP: live value differs from the plan''s from value; re-run the diff')
            exit 3
        }
        $r = Write-Line $d $u.to $false
        Write-Log (Format-ApplyLogLine -Phase 'updateLine' -Key "$($u.key.TaxCode)/$($u.key.TaxClass)" -Before (ConvertTo-LineLogValue $u.from) -After (ConvertTo-LineLogValue $u.to) -Result $r)
        if ($r -like 'skip:*') { $counts.skipped++ } else { $counts.updateLine++ }
    }
} catch {
    Write-Log "STOP: $($_.Exception.Message)"
    exit 3
} finally {
    try { $o.DropObject(); $d.DropObject(); $s.session.DropObject() } catch { }
}
Write-Log "APPLY complete: headers added $($counts.addHeader), lines added $($counts.addLine), lines updated $($counts.updateLine), skipped $($counts.skipped). Now dump live again and re-run the diff; expect an empty plan."
exit 0
