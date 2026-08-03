#requires -version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path -Path $repoRoot -ChildPath '.assets\WinRMWorkshop\WinRMWorkshop.psd1'
$entryPoint = Join-Path -Path $repoRoot -ChildPath 'DeviceCheck.ps1'
$inventoryPart = Join-Path -Path $PSScriptRoot -ChildPath 'DeviceCheck\05-InventoryAndSnapshots.ps1'
$exporter = Join-Path -Path $PSScriptRoot -ChildPath 'Export-DeviceCheckEvidence.ps1'
$readme = Join-Path -Path $repoRoot -ChildPath 'README.md'

$moduleInfo = Test-ModuleManifest -Path $manifest -ErrorAction Stop
if ($moduleInfo.Version -ne [version]'1.0.0') {
    throw "Expected canonical WinRMWorkshop 1.0.0, found $($moduleInfo.Version)."
}
Import-Module -Name $manifest -Force -ErrorAction Stop
foreach ($commandName in @('Add-WinRMWorkshopTrustedHost', 'Get-WinRMWorkshopTrustedHost', 'Remove-WinRMWorkshopTrustedHost')) {
    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
        throw "Vendored WinRMWorkshop module did not export $commandName."
    }
}

foreach ($path in @($entryPoint, $inventoryPart, $exporter)) {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "$(Split-Path -Leaf $path) has $($parseErrors.Count) parser error(s)."
    }
}

$entrySource = Get-Content -LiteralPath $entryPoint -Raw
if ($entrySource -notmatch 'WinRMWorkshop\\WinRMWorkshop\.psd1|WinRMWorkshop') {
    throw 'DeviceCheck entrypoint does not import the pinned WinRMWorkshop module.'
}

$consumerSources = @(
    Get-Content -LiteralPath $inventoryPart -Raw
    Get-Content -LiteralPath $exporter -Raw
)
foreach ($source in $consumerSources) {
    if ($source -notmatch 'Add-WinRMWorkshopTrustedHost') {
        throw 'A DeviceCheck remote consumer does not use canonical exact-target preparation.'
    }
    if ($source -match 'WSMan:\\localhost\\Client\\TrustedHosts|Set-Item[^\r\n]+TrustedHosts|function\s+Add-(DeviceCheck)?TrustedHost') {
        throw 'An ad-hoc TrustedHosts implementation remains in a DeviceCheck consumer.'
    }
}

$readmeSource = Get-Content -LiteralPath $readme -Raw
if ($readmeSource -notmatch '(?i)controlled workshop LAN' -or $readmeSource -notmatch '(?i)certificate-backed server identity') {
    throw 'README does not disclose the canonical workshop WinRM security boundary.'
}

Write-Host 'DeviceCheck WinRMWorkshop integration tests passed.' -ForegroundColor Green
