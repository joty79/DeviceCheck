param(
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSCommandPath
$launcherPath = Join-Path $repoRoot 'Launch-DeviceCheck.vbs'
$scriptPath = Join-Path $repoRoot 'DeviceCheck.ps1'
$wscriptPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$deviceManagerIcon = Join-Path $repoRoot 'assets\devicemanager.ico'

$menuKeys = @(
    'HKCU\Software\Classes\Directory\Background\shell\DeviceCheck',
    'HKCU\Software\Classes\Directory\shell\DeviceCheck',
    'HKCU\Software\Classes\Drive\shell\DeviceCheck'
)

function Invoke-RegExe {
    param(
        [Parameter(Mandatory)]
        [string[]]$RegArguments
    )

    $output = & reg.exe @RegArguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "reg.exe $($RegArguments -join ' ') failed with exit code $exitCode.`n$output"
    }
    return $output
}

function Set-RegStringValue {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    if ($Name -eq '(Default)') {
        [void](Invoke-RegExe -RegArguments @('add', $KeyPath, '/ve', '/t', 'REG_SZ', '/d', $Value, '/f'))
        return
    }

    [void](Invoke-RegExe -RegArguments @('add', $KeyPath, '/v', $Name, '/t', 'REG_SZ', '/d', $Value, '/f'))
}

function Remove-DeviceCheckContextMenu {
    foreach ($keyPath in $menuKeys) {
        & reg.exe delete $keyPath /f >$null 2>$null
    }
}

function Install-DeviceCheckContextMenu {
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "DeviceCheck.ps1 was not found: $scriptPath"
    }
    if (-not (Test-Path -LiteralPath $launcherPath)) {
        throw "Launch-DeviceCheck.vbs was not found: $launcherPath"
    }
    if (-not (Test-Path -LiteralPath $wscriptPath)) {
        throw "wscript.exe was not found: $wscriptPath"
    }
    if (-not (Test-Path -LiteralPath $deviceManagerIcon)) {
        throw "Device Manager icon was not found: $deviceManagerIcon"
    }

    $command = '"{0}" "{1}"' -f $wscriptPath, $launcherPath
    $icon = $deviceManagerIcon

    foreach ($keyPath in $menuKeys) {
        $commandKey = "$keyPath\command"
        Set-RegStringValue -KeyPath $keyPath -Name '(Default)' -Value 'DeviceCheck'
        Set-RegStringValue -KeyPath $keyPath -Name 'MUIVerb' -Value 'DeviceCheck'
        Set-RegStringValue -KeyPath $keyPath -Name 'Icon' -Value $icon
        Set-RegStringValue -KeyPath $keyPath -Name 'Position' -Value 'Top'
        Set-RegStringValue -KeyPath $commandKey -Name '(Default)' -Value $command
    }
}

if ($Uninstall) {
    Remove-DeviceCheckContextMenu
    Write-Host 'DeviceCheck context menu removed.'
    exit 0
}

Install-DeviceCheckContextMenu
Write-Host 'DeviceCheck context menu installed for the current user.'
Write-Host 'Locations: desktop/folder background, folders, and drives.'

foreach ($keyPath in $menuKeys) {
    Write-Host ''
    [void](Invoke-RegExe -RegArguments @('query', $keyPath, '/ve'))
    [void](Invoke-RegExe -RegArguments @('query', $keyPath, '/v', 'Icon'))
    [void](Invoke-RegExe -RegArguments @('query', "$keyPath\command", '/ve'))
}
