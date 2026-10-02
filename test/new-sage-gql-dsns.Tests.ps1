Describe 'new-sage-gql-dsns script contract' {
    It 'refuses 32-bit PowerShell so it writes x64 system DSNs' {
        $scriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'scripts/new-sage-gql-dsns.ps1'
        $source = Get-Content -Raw $scriptPath
        $source | Should -Match '\[Environment\]::Is64BitProcess'
    }

    It 'creates the ODBC log directory before configuring DSNs' {
        $scriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'scripts/new-sage-gql-dsns.ps1'
        $source = Get-Content -Raw $scriptPath
        $source | Should -Match '\$logDirectory = "C:\\sage-gql"'
        $source | Should -Match 'New-Item -ItemType Directory -Path \$logDirectory -Force'
    }
}
