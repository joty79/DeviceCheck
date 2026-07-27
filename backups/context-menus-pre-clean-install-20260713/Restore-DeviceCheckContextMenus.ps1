#requires -version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$exports = @(
    [pscustomobject]@{
        File = '01-DeviceCheck-Directory-Background.reg'
        Key = 'HKCU\Software\Classes\Directory\Background\shell\DeviceCheck'
    }
    [pscustomobject]@{
        File = '02-DeviceCheck-Directory.reg'
        Key = 'HKCU\Software\Classes\Directory\shell\DeviceCheck'
    }
    [pscustomobject]@{
        File = '03-DeviceCheck-Drive.reg'
        Key = 'HKCU\Software\Classes\Drive\shell\DeviceCheck'
    }
    [pscustomobject]@{
        File = '04-DeviceCheck-DriverTools-Exe.reg'
        Key = 'HKCU\Software\Classes\SystemFileAssociations\.exe\shell\DeviceCheckDriverPackageTools'
    }
    [pscustomobject]@{
        File = '05-DeviceCheck-DriverTools-Submenu.reg'
        Key = 'HKCU\Software\Classes\DeviceCheck.DriverPackageTools'
    }
)

foreach ($export in $exports) {
    $regPath = Join-Path $PSScriptRoot $export.File
    if (-not (Test-Path -LiteralPath $regPath -PathType Leaf)) {
        throw "Missing Registry backup: $regPath"
    }

    $header = Get-Content -LiteralPath $regPath -TotalCount 1
    if ($header -ne 'Windows Registry Editor Version 5.00') {
        throw "Invalid Registry export header: $regPath"
    }

    & reg.exe import $regPath
    if ($LASTEXITCODE -ne 0) {
        throw "Registry import failed with exit code $LASTEXITCODE`: $regPath"
    }
}

$missingKeys = @()
foreach ($export in $exports) {
    & reg.exe query $export.Key *> $null
    if ($LASTEXITCODE -ne 0) {
        $missingKeys += $export.Key
    }
}

if ($missingKeys.Count -gt 0) {
    throw "Registry restore verification failed. Missing keys: $($missingKeys -join ', ')"
}

Write-Host 'DeviceCheck context menus restored and verified.' -ForegroundColor Green
Write-Host 'No administrator elevation was required because the backups target HKCU.' -ForegroundColor DarkGray
