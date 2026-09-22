# remove-jumpcloud-remote-assist.ps1 needs a Windows SCM and the vendor
# uninstaller, so it cannot be executed here. This checks the parts that can
# be checked off-box: the file parses, is pure ASCII, keeps the pre-commit
# revision stamp, and its command-line splitter handles the shapes Windows
# writes into UninstallString / QuietUninstallString.
BeforeAll {
    $script = Join-Path $PSScriptRoot '../scripts/remove-jumpcloud-remote-assist.ps1'
}

Describe 'remove-jumpcloud-remote-assist.ps1' {
    It 'parses without errors' {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }

    It 'is pure ASCII' {
        $bytes = [System.IO.File]::ReadAllBytes($script)
        ($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'carries the revision stamp line' {
        (Get-Content $script) -match '^\$Script:Revision = ".*"$' | Should -Not -BeNullOrEmpty
    }

    It 'never reboots' {
        (Get-Content $script -Raw) | Should -Not -Match 'Restart-Computer|shutdown\.exe|shutdown /r'
    }
}

Describe 'Split-UninstallCommand' {
    BeforeAll {
        # Lift just the function out of the script so the rest (which needs
        # admin + SCM) never runs.
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Split-UninstallCommand' }, $false) | Select-Object -First 1
        Invoke-Expression $fn.Extent.Text
    }

    It 'splits a quoted path with arguments' {
        $r = Split-UninstallCommand '"C:\Program Files\JumpCloud Remote Assist\Uninstall JumpCloud Remote Assist.exe" /allusers /S'
        $r.Exe  | Should -Be 'C:\Program Files\JumpCloud Remote Assist\Uninstall JumpCloud Remote Assist.exe'
        $r.Args | Should -Be '/allusers /S'
    }

    It 'splits a quoted path with no arguments' {
        $r = Split-UninstallCommand '"C:\x\Uninstall.exe"'
        $r.Exe  | Should -Be 'C:\x\Uninstall.exe'
        $r.Args | Should -Be ''
    }

    It 'splits an unquoted command' {
        $r = Split-UninstallCommand 'MsiExec.exe /X{4A417E94-7651-4AEB-AAFB-C59BFF724CE7}'
        $r.Exe  | Should -Be 'MsiExec.exe'
        $r.Args | Should -Be '/X{4A417E94-7651-4AEB-AAFB-C59BFF724CE7}'
    }
}
