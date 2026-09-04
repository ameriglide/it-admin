# Every sage-taxcode-*.ps1 must parse cleanly. The scripts themselves need the
# Sage ODBC driver / ProvideX COM and cannot be executed off the Sage server,
# so this is the automated check that stands in for running them.
Describe 'sage-taxcode scripts parse' {
    $scripts = Get-ChildItem -Path "$PSScriptRoot/../scripts" -Filter 'sage-taxcode-*.ps1' | ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } }

    It 'finds at least the lib and the dump script' {
        $scripts.Count | Should -BeGreaterOrEqual 2
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
