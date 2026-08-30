#Requires -RunAsAdministrator
# new-sage-gql-dsns.ps1
# Creates the five 64-bit Sage 100 ODBC system DSNs used by sage-gql.
# Run this elevated on the Sage 100 2026 server. ASCII only.

$ErrorActionPreference = "Stop"

if (-not [Environment]::Is64BitProcess) {
    throw "Run this script from 64-bit PowerShell so it creates 64-bit system DSNs."
}

$logDirectory = "C:\sage-gql"
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

$odbcRoot = "HKLM:\SOFTWARE\ODBC\ODBC.INI"
$dataSourcesPath = Join-Path $odbcRoot "ODBC Data Sources"

if (-not (Test-Path $dataSourcesPath)) {
    New-Item -Path $dataSourcesPath -Force | Out-Null
}

$companies = @{
    ad1 = "AD1"
    ad4 = "AD4"
    ad5 = "AD5"
    amc = "AMC"
    iai = "IAI"
}

foreach ($division in $companies.Keys) {
    $dsnName = "sage_$division"
    $dsnPath = Join-Path $odbcRoot $dsnName

    if (-not (Test-Path $dsnPath)) {
        New-Item -Path $dsnPath -Force | Out-Null
    }

    $properties = [ordered]@{
        Driver                 = "C:\Windows\system32\PVXODBC.DLL"
        Description            = "sage-gql $division sync"
        Company                = $companies[$division]
        Directory              = "C:\Sage\Sage 100\MAS90"
        Prefix                 = "C:\Sage\Sage 100\MAS90\SY\, C:\Sage\Sage 100\MAS90\==\"
        ViewDLL                = "C:\Sage\Sage 100\MAS90\Home\"
        RemotePVKIOHost        = "sage"
        RemotePVKIOPort        = "20222"
        MAS90RootDirectory     = ""
        CacheSize              = "256"
        DirtyReads             = "1"
        BurstMode              = "1"
        StripTrailingSpaces    = "1"
        Compression            = "0"
        Debug                  = "0"
        KeyRestrict            = "0"
        EnforceDouble          = "0"
        EnforceNULLDate        = "0"
        SILENT                 = "1"
        UID                    = ""
        PWD                    = ""
        SID                    = ""
        LogFile                = "C:\sage-gql\pvxodbc-$division.log"
    }

    foreach ($property in $properties.GetEnumerator()) {
        New-ItemProperty -Path $dsnPath -Name $property.Key -Value $property.Value -PropertyType String -Force | Out-Null
    }

    New-ItemProperty -Path $dataSourcesPath -Name $dsnName -Value "MAS 90 4.0 ODBC Driver" -PropertyType String -Force | Out-Null
    Write-Host "Configured 64-bit system DSN $dsnName" -ForegroundColor Green
}
