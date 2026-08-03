[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path -Path $repoRoot -ChildPath '.assets\WinRMConnection\WinRMConnection.psd1'
$exporter = Join-Path -Path $PSScriptRoot -ChildPath 'Export-DeviceCheckEvidence.ps1'
$credentialAdapter = Join-Path -Path $PSScriptRoot -ChildPath 'DeviceCheck\01-ModelsAndCredentials.ps1'
$remoteConnection = Join-Path -Path $PSScriptRoot -ChildPath 'DeviceCheck\06-RemoteConnection.ps1'

$moduleInfo = Test-ModuleManifest -Path $manifest -ErrorAction Stop
if ($moduleInfo.Version -ne [version]'1.1.0') {
    throw "Expected canonical WinRMConnection 1.1.0, found $($moduleInfo.Version)."
}
Import-Module -Name $manifest -Force -ErrorAction Stop
foreach ($commandName in @('Connect-WinRMSession', 'Get-WinRMConnectionErrorCategory', 'Get-WinRMCredentialProfile', 'Save-WinRMCredentialProfile', 'Remove-WinRMCredentialProfile', 'New-WinRMBlankPasswordCredential')) {
    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
        throw "Vendored WinRMConnection module did not export $commandName."
    }
}

foreach ($path in @($exporter, $credentialAdapter, $remoteConnection)) {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "$(Split-Path -Leaf $path) has $($parseErrors.Count) parser error(s)."
    }
}

$source = Get-Content -LiteralPath $exporter -Raw
if ($source -notmatch 'WinRMConnection\\WinRMConnection\.psd1') {
    throw 'DeviceCheck exporter does not import the vendored WinRMConnection module.'
}
if ($source -notmatch 'Connect-WinRMSession') {
    throw 'DeviceCheck exporter does not use the shared WinRM session connector.'
}
foreach ($commandName in @('Get-WinRMCredentialProfile', 'Save-WinRMCredentialProfile', 'Remove-WinRMCredentialProfile', 'Get-WinRMConnectionErrorCategory')) {
    if ($source -notmatch [regex]::Escape($commandName)) {
        throw "DeviceCheck exporter does not use canonical $commandName."
    }
}
if ($source -match '\bExport-Clixml\b') {
    throw 'DeviceCheck exporter still writes an ad-hoc credential profile.'
}
$connectIndex = $source.IndexOf('Connect-WinRMSession', [System.StringComparison]::Ordinal)
$saveIndex = $source.IndexOf('Save-WinRMCredentialProfile', [System.StringComparison]::Ordinal)
if ($connectIndex -lt 0 -or $saveIndex -lt $connectIndex) {
    throw 'DeviceCheck exporter can save a credential before successful session opening.'
}
if ($source -match '\bNew-PSSession\b') {
    throw 'DeviceCheck exporter still contains an ad-hoc New-PSSession call.'
}
if ($source -notmatch 'Remove-PSSession\s+-Session\s+\$session|Remove-PSSession\s+\$session') {
    throw 'DeviceCheck exporter does not guarantee PSSession cleanup.'
}

$credentialSource = Get-Content -LiteralPath $credentialAdapter -Raw
foreach ($commandName in @('Get-WinRMCredentialProfile', 'Save-WinRMCredentialProfile', 'Remove-WinRMCredentialProfile')) {
    if ($credentialSource -notmatch [regex]::Escape($commandName)) {
        throw "DeviceCheck credential adapter does not route through $commandName."
    }
}
if ($credentialSource -match '\bExport-Clixml\b') {
    throw 'DeviceCheck credential adapter still writes an ad-hoc profile.'
}

$remoteSource = Get-Content -LiteralPath $remoteConnection -Raw
if ($remoteSource -notmatch 'New-WinRMBlankPasswordCredential') {
    throw 'DeviceCheck blank-password credentials do not use the canonical constructor.'
}
if ($remoteSource -notmatch "Get-WinRMConnectionErrorCategory[\s\S]+AuthenticationRejected") {
    throw 'DeviceCheck does not classify authentication rejection before removing a cached profile.'
}

Write-Host 'DeviceCheck WinRMConnection integration tests passed.' -ForegroundColor Green
