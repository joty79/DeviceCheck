#requires -version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TraceFolder,
    [switch]$NoUI,
    [switch]$PlainText,
    [switch]$AsJson,
    [int]$Width = 140,
    [int]$Height = 34
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$resolvedTrace = (Resolve-Path -LiteralPath $TraceFolder).ProviderPath
$previewPath = Join-Path $resolvedTrace 'package-preview.json'
if (-not (Test-Path -LiteralPath $previewPath -PathType Leaf)) { throw "Trace preview not found: $previewPath" }

$advisorRenderer = Join-Path $PSScriptRoot 'DriverAdvisor\TerminalRenderer.ps1'
$topologyHelper = Join-Path $PSScriptRoot 'DriverPackageView\Topology.ps1'
$packageRenderer = Join-Path $PSScriptRoot 'DriverPackageView\TerminalRenderer.ps1'
foreach ($helperPath in @($advisorRenderer, $topologyHelper, $packageRenderer)) {
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) { throw "Required package-view helper not found: $helperPath" }
    . $helperPath
}

$preview = Get-Content -LiteralPath $previewPath -Raw | ConvertFrom-Json
$topologyPath = Join-Path $resolvedTrace 'package-topology.json'
$topology = New-DriverPackageTopology -Preview $preview -OutputPath $topologyPath

if ($AsJson) {
    $topology | ConvertTo-Json -Depth 12
    return
}

$outputRedirected = $false
try { $outputRedirected = [Console]::IsOutputRedirected } catch { Write-Debug "Output redirection detection failed: $($_.Exception.Message)" }
if ($NoUI -or $outputRedirected) {
    ConvertTo-DriverPackageViewSnapshot -Topology $topology -Width $Width -Height $Height -PlainText:$PlainText
    return
}

$selection = Show-DriverPackageView -Topology $topology
if ($null -ne $selection) { $selection }
