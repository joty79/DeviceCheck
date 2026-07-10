param(
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSCommandPath
$launcherPath = Join-Path $repoRoot 'tools\Launch-DriverPackageImpactTrace.vbs'
$traceScriptPath = Join-Path $repoRoot 'tools\Trace-DriverPackageImpact.ps1'
$wscriptPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$iconPath = Join-Path $repoRoot 'assets\devicemanager.ico'
$menuKey = 'HKCU\Software\Classes\SystemFileAssociations\.exe\shell\DeviceCheckTraceDriverPackage'
$legacyMenuKeys = @(
    'HKCU\Software\Classes\exefile\shell\DeviceCheckTraceDriverPackage'
)
$legacyExefileRoot = 'HKCU\Software\Classes\exefile'

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

function Remove-LegacyExefileRootIfEmpty {
    $output = @(reg.exe query $legacyExefileRoot /s 2>$null | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) { return }

    $hasValueLines = @($output | Where-Object { $_ -match '\s+REG_' }).Count -gt 0
    $hasUnexpectedSubkeys = @($output | Where-Object {
        $_ -match '^HKEY_CURRENT_USER\\Software\\Classes\\exefile\\' -and
        $_ -notmatch '^HKEY_CURRENT_USER\\Software\\Classes\\exefile\\shell$'
    }).Count -gt 0

    if (-not $hasValueLines -and -not $hasUnexpectedSubkeys) {
        & reg.exe delete $legacyExefileRoot /f >$null 2>$null
    }
}

if ($Uninstall) {
    & reg.exe delete $menuKey /f >$null 2>$null
    foreach ($legacyMenuKey in $legacyMenuKeys) {
        & reg.exe delete $legacyMenuKey /f >$null 2>$null
    }
    Remove-LegacyExefileRootIfEmpty
    Write-Host 'DeviceCheck driver package trace context menu removed.'
    exit 0
}

foreach ($requiredPath in @($launcherPath, $traceScriptPath, $wscriptPath, $iconPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required file was not found: $requiredPath"
    }
}

$commandKey = "$menuKey\command"
$command = '"{0}" "{1}" "%1"' -f $wscriptPath, $launcherPath

foreach ($legacyMenuKey in $legacyMenuKeys) {
    & reg.exe delete $legacyMenuKey /f >$null 2>$null
}
Remove-LegacyExefileRootIfEmpty

Set-RegStringValue -KeyPath $menuKey -Name '(Default)' -Value 'Trace driver package impact'
Set-RegStringValue -KeyPath $menuKey -Name 'MUIVerb' -Value 'Trace driver package impact'
Set-RegStringValue -KeyPath $menuKey -Name 'Icon' -Value $iconPath
Set-RegStringValue -KeyPath $menuKey -Name 'Position' -Value 'Top'
Set-RegStringValue -KeyPath $commandKey -Name '(Default)' -Value $command

Write-Host 'DeviceCheck driver package trace context menu installed for .exe files.'
[void](Invoke-RegExe -RegArguments @('query', $menuKey, '/s'))
