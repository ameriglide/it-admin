# Every sage-taxcode-*.ps1 must parse cleanly. The scripts themselves need the
# Sage ODBC driver / ProvideX COM and cannot be executed off the Sage server,
# so this is the automated check that stands in for running them.
Describe 'sage-taxcode scripts parse' {
    $scripts = Get-ChildItem -Path "$PSScriptRoot/../scripts" -Filter 'sage-taxcode-*.ps1' | ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } }

    It 'finds at least the lib and the dump script' {
        (Get-ChildItem -Path "$PSScriptRoot/../scripts" -Filter 'sage-taxcode-*.ps1').Count | Should -BeGreaterOrEqual 2
    }

    It 'parses <Name> without errors' -ForEach $scripts {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }

    It '<Name> is pure ASCII' -ForEach $scripts {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        ($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe 'sage-taxcode-apply line writes' {
    # AG-806 regression guard. Sage auto-generates a tax code's class lines when
    # the header is created, so Write-Line must not skip a row just because
    # nSetKey reports it already exists. That decision now lives in
    # Get-LineWriteDisposition, which is unit tested in sage-taxcode-lib.Tests.
    BeforeAll {
        $src = Get-Content "$PSScriptRoot/../scripts/sage-taxcode-apply.ps1" -Raw
        $Script:WriteLineBody = [regex]::Match($src, '(?s)function Write-Line.*?\r?\n\}').Value
    }

    It 'has a Write-Line function' {
        $Script:WriteLineBody | Should -Not -BeNullOrEmpty
    }

    It 'delegates the nSetKey decision to Get-LineWriteDisposition' {
        $Script:WriteLineBody | Should -Match 'Get-LineWriteDisposition'
    }

    It 'does not skip an existing line on an add' {
        $Script:WriteLineBody | Should -Not -Match 'already exists'
    }
}
