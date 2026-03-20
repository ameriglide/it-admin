Create a new PowerShell script: $ARGUMENTS

## Instructions

1. Create the script at `scripts/<name>.ps1` using the standard template below
2. The script MUST include:
   - `#Requires -RunAsAdministrator`
   - Comment-based help block (`.SYNOPSIS`, `.DESCRIPTION`, `.EXAMPLE`)
   - `$ErrorActionPreference = "Stop"`
   - `$ProgressPreference = "SilentlyContinue"`
   - `$Script:Revision = "dev"` (the pre-commit hook will stamp this automatically)
   - The standard version check block (see template)
3. Use ASCII only -- no em dashes, curly quotes, or other non-ASCII characters
4. Add a one-liner to the README under a new section for the script
5. The one-liner format is: `Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/ameriglide/it-admin/main/scripts/<name>.ps1 -OutFile $env:TEMP\<name>.ps1; & $env:TEMP\<name>.ps1`
6. Commit and push when done

## Template

```powershell
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    <One line description>

.DESCRIPTION
    <Detailed description>

.EXAMPLE
    .\<name>.ps1
#>

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Script:Revision = "dev"

Write-Host "<name>.ps1 rev $Script:Revision" -ForegroundColor DarkGray

# Check if this is the latest version
try {
    $commits = Invoke-RestMethod -Uri "https://api.github.com/repos/ameriglide/it-admin/commits?path=scripts/<name>.ps1&per_page=1" -ErrorAction Stop
    $latestSha = $commits[0].sha.Substring(0, 7)
    if ($Script:Revision -ne "dev" -and $latestSha -ne $Script:Revision) {
        Write-Host ""
        Write-Host "  WARNING: You are running rev $Script:Revision but the latest is $latestSha" -ForegroundColor Red
        Write-Host "  Re-download the script to get the latest version." -ForegroundColor Red
        Write-Host ""
        $continue = Read-Host "  Press Enter to continue anyway, or Ctrl+C to abort"
    }
} catch {}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  <Title>" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# --- Script logic here ---
```

## Conventions

- All scripts are idempotent -- safe to re-run
- Check if something is already done before doing it (installed, configured, etc.)
- Use `Write-Host` with `-ForegroundColor Yellow` for step headers
- Use `Write-Host` with `-ForegroundColor Green` for success
- Use `Write-Warning` for non-fatal issues
- Use `Write-Error` and `exit 1` for fatal issues
- Use winget for app installs when possible
- No secrets in scripts -- pass sensitive values as parameters
- Step numbering format: `[1/N] Step name...`
