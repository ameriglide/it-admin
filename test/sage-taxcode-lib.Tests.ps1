BeforeAll {
    . "$PSScriptRoot/../scripts/sage-taxcode-lib.ps1"
}

Describe 'Get-SageLiveConnectionString' {
    It 'wraps the DSN' {
        Get-SageLiveConnectionString -Dsn 'sage_ad1' | Should -Be 'DSN=sage_ad1;'
    }
}

Describe 'Get-SageSnapshotConnectionString' {
    It 'points the driver at the snapshot directory and the live ViewDLL' {
        $cs = Get-SageSnapshotConnectionString -SnapshotDir 'C:\snap\MAS90' -SageHome 'C:\Sage\Sage 100\MAS90\Home'
        $cs | Should -Match '^Driver=\{MAS 90 4\.0 ODBC Driver\};'
        $cs | Should -Match 'Directory=C:\\snap\\MAS90;'
        $cs | Should -Match 'Prefix=C:\\snap\\MAS90\\SY\\, C:\\snap\\MAS90\\==\\;'
        $cs | Should -Match 'ViewDLL=C:\\Sage\\Sage 100\\MAS90\\Home\\;'
        $cs | Should -Match 'Company=AD1;'
        $cs | Should -Match 'SILENT=1;'
    }
    It 'tolerates a trailing backslash on SageHome' {
        $cs = Get-SageSnapshotConnectionString -SnapshotDir 'C:\snap\MAS90' -SageHome 'C:\Sage\Sage 100\MAS90\Home\'
        $cs | Should -Match 'ViewDLL=C:\\Sage\\Sage 100\\MAS90\\Home\\;'
        $cs | Should -Not -Match 'Home\\\\;'
    }
}

Describe 'ConvertTo-TsvValue' {
    It 'replaces tabs and newlines with spaces and trims the end' {
        ConvertTo-TsvValue "a`tb`r`nc   " | Should -Be 'a b  c'
    }
    It 'maps null to empty' {
        ConvertTo-TsvValue $null | Should -Be ''
    }
    It 'keeps leading spaces' {
        ConvertTo-TsvValue '  x' | Should -Be '  x'
    }
}

Describe 'ConvertTo-SageYesNo' {
    It 'normalizes truthy spellings to Y' {
        foreach ($v in @('Y', 'y', 'true', '1')) { ConvertTo-SageYesNo $v | Should -Be 'Y' }
    }
    It 'normalizes falsy spellings to N' {
        foreach ($v in @('N', 'n', 'false', '0', '')) { ConvertTo-SageYesNo $v | Should -Be 'N' }
    }
    It 'rejects anything else' {
        { ConvertTo-SageYesNo 'maybe' } | Should -Throw
    }
}

Describe 'Test-PlanShape' {
    It 'accepts a plan with every bucket' {
        $plan = [pscustomobject]@{ addHeaders = @(); addLines = @(); updateLines = @(); liveOnlyHeaders = @(); liveOnlyLines = @(); changedHeaders = @(); viJobsMissing = @(); viJobsLiveOnly = @() }
        Test-PlanShape $plan | Should -BeTrue
    }
    It 'names the missing bucket' {
        $plan = [pscustomobject]@{ addHeaders = @(); addLines = @() }
        { Test-PlanShape $plan } | Should -Throw '*updateLines*'
    }
}

Describe 'Format-ApplyLogLine' {
    It 'emits timestamp, phase, key, before, after, result separated by tabs' {
        $line = Format-ApplyLogLine -Phase 'addHeader' -Key 'TX BELL COUNTY' -Before '' -After 'desc=TX BELL COUNTY' -Result 'nSetKey=2 nWrite=1 verify=ok'
        $parts = $line -split "`t"
        $parts.Count | Should -Be 6
        $parts[0] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        $parts[1] | Should -Be 'addHeader'
        $parts[2] | Should -Be 'TX BELL COUNTY'
        $parts[5] | Should -Be 'nSetKey=2 nWrite=1 verify=ok'
    }
}

Describe 'ConvertTo-HeaderLogValue' {
    It 'flattens a header record' {
        $h = [pscustomobject]@{ TaxCode = 'TX BELL COUNTY'; TaxCodeDesc = 'TX BELL COUNTY'; TaxCodeShortDesc = 'TX BEL'; TaxOnTax = 'N'; TaxClassForTaxOnTax = ''; TaxLimit = '0.000000'; ExpenseToVendorItem = 'N'; RetentionTaxable = 'N' }
        ConvertTo-HeaderLogValue $h | Should -Be 'desc=TX BELL COUNTY|short=TX BEL|tot=N|totclass=|limit=0.000000|etv=N|ret=N'
    }
}

Describe 'ConvertTo-LineLogValue' {
    It 'flattens a line record' {
        $l = [pscustomobject]@{ TaxCode = 'AZ MESA'; TaxClass = 'TF'; SalesTaxable = 'N'; PurchasesTaxable = 'N'; TaxRate = '0.000000'; NonRecoverablePercent = '0.000' }
        ConvertTo-LineLogValue $l | Should -Be 'sales=N|purch=N|rate=0.000000|nonrec=0.000'
    }
}

Describe 'Get-LineWriteDisposition' {
    # Regression guard for AG-806: creating a sales tax code header through the
    # BOI makes Sage auto-generate that code's class lines, so a planned "add"
    # legitimately finds the row already present and nSetKey returns 1. The
    # first live run treated that as "already exists" and skipped the write,
    # leaving 71 lines at rate 0 on 44 brand-new tax codes.
    It 'writes an added line that Sage auto-created with the header' {
        Get-LineWriteDisposition -ExpectNew $true -SetKeyResult 1 | Should -BeNullOrEmpty
    }

    It 'writes an added line that did not exist at all' {
        Get-LineWriteDisposition -ExpectNew $true -SetKeyResult 2 | Should -BeNullOrEmpty
    }

    It 'skips an added line whose record cannot be keyed' {
        Get-LineWriteDisposition -ExpectNew $true -SetKeyResult 0 | Should -Match '^skip: nSetKey=0'
    }

    It 'writes an updated line that exists' {
        Get-LineWriteDisposition -ExpectNew $false -SetKeyResult 1 | Should -BeNullOrEmpty
    }

    It 'skips an updated line that is missing' {
        Get-LineWriteDisposition -ExpectNew $false -SetKeyResult 2 | Should -Match 'not found'
    }
}
