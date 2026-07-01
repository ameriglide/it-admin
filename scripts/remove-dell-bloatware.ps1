#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Compatibility shim. Dell debloat now lives in the consolidated engine
  remove-bloatware.ps1 (-Profile dell). This path is kept because
  setup-workstation.ps1 (the 'delldebloat' block), the Action1 "Remove Dell
  Bloatware" library script, and the "Dell debloat sweep" automation all
  reference it. Delegates so there is one source of truth for the engine.
.NOTES
  ASCII-only -- Windows PowerShell 5.1 parses scripts as ANSI.
#>
$s = "$env:TEMP\remove-bloatware.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/ameriglide/it-admin/main/scripts/remove-bloatware.ps1" -OutFile $s -UseBasicParsing
& $s -Profile dell
