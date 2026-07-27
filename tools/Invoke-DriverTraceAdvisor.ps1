#requires -version 7.0
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '', Justification = 'Repository policy uses UTF-8 without BOM for PowerShell source.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive orchestration status is intentionally host-facing; comparison JSON remains pipeline-safe.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TraceFolder,
    [AllowEmptyString()][string]$InstanceId = '',
    [switch]$SkipWindowsUpdate,
    [switch]$IncludeWindowsUpdate,
    [switch]$IncludeSignatureEvidence,
    [switch]$SkipCatalog,
    [switch]$IncludeCatalog,
    [switch]$SkipSdio,
    [AllowEmptyString()][string]$SdioRoot = '',
    [switch]$NoUI,
    [switch]$PlainText
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$benchmarkHelper = Join-Path $PSScriptRoot 'DriverSourceComparison\Benchmark.ps1'
if (-not (Test-Path -LiteralPath $benchmarkHelper -PathType Leaf)) { throw "Required benchmark helper not found: $benchmarkHelper" }
. $benchmarkHelper
$benchmark = New-DriverBenchmarkRecorder -Name 'DriverTraceAdvisor'
$discoveryStopwatch = [Diagnostics.Stopwatch]::StartNew()

$resolvedTrace = (Resolve-Path -LiteralPath $TraceFolder).ProviderPath
$previewPath = Join-Path $resolvedTrace 'package-preview.json'
if (-not (Test-Path -LiteralPath $previewPath -PathType Leaf)) { throw "Trace preview not found: $previewPath" }

$preview = Get-Content -LiteralPath $previewPath -Raw | ConvertFrom-Json
$traceRoot = Split-Path -Parent $resolvedTrace
$advisorRenderer = Join-Path $PSScriptRoot 'DriverAdvisor\TerminalRenderer.ps1'
$topologyHelper = Join-Path $PSScriptRoot 'DriverPackageView\Topology.ps1'
$packageRenderer = Join-Path $PSScriptRoot 'DriverPackageView\TerminalRenderer.ps1'
foreach ($helperPath in @($advisorRenderer, $topologyHelper, $packageRenderer)) {
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) { throw "Required package-view helper not found: $helperPath" }
    . $helperPath
}
$topology = New-DriverPackageTopology -Preview $preview -OutputPath (Join-Path $resolvedTrace 'package-topology.json')

function Find-CompletedDriverTraceEvidence {
    param(
        [string]$CurrentTrace,
        [string]$InstallerHash,
        [string]$TargetInstanceId
    )

    $candidates = @(
        Get-ChildItem -LiteralPath $traceRoot -Directory | Where-Object FullName -ne $CurrentTrace | Sort-Object LastWriteTime -Descending | ForEach-Object {
            $candidateFolder = $_.FullName
            $candidatePreviewPath = Join-Path $candidateFolder 'package-preview.json'
            $candidateDiffPath = Join-Path $candidateFolder 'diff.json'
            if (-not (Test-Path -LiteralPath $candidatePreviewPath -PathType Leaf) -or -not (Test-Path -LiteralPath $candidateDiffPath -PathType Leaf)) { return }
            try {
                $candidatePreview = Get-Content -LiteralPath $candidatePreviewPath -Raw | ConvertFrom-Json
                $sameInstaller = [string]$candidatePreview.InstallerHash -eq $InstallerHash
                $hasTarget = @($candidatePreview.Matches | Where-Object InstanceId -eq $TargetInstanceId).Count -gt 0
                if ($sameInstaller -and $hasTarget) { $candidateFolder }
            }
            catch {
                Write-Debug "Skipping unreadable trace '$candidateFolder': $($_.Exception.Message)"
            }
        }
    )
    return @($candidates | Select-Object -First 1)
}
$targets = @(
    $preview.Matches | Group-Object InstanceId | ForEach-Object {
        $first = $_.Group | Select-Object -First 1
        [pscustomobject]@{
            InstanceId = [string]$first.InstanceId
            DeviceName = [string]$first.DeviceName
            DeviceClass = [string]$first.DeviceClass
            MatchCount = $_.Count
        }
    } | Sort-Object DeviceName, InstanceId
)

if (-not [string]::IsNullOrWhiteSpace($InstanceId)) {
    $targets = @($targets | Where-Object InstanceId -eq $InstanceId)
    if ($targets.Count -eq 0) { throw "Trace has no package match for InstanceId '$InstanceId'." }
}

if ($targets.Count -eq 0) {
    Write-Host 'Driver Package Advisor: no present-device INF matches were found in this trace.' -ForegroundColor Yellow
    return
}

$selectedTargets = $targets
if (-not $NoUI -and [string]::IsNullOrWhiteSpace($InstanceId)) {
    $selected = Show-DriverPackageView -Topology $topology
    if ($null -eq $selected) { return }
    if ($selected -ne '__ALL__') { $selectedTargets = @($targets | Where-Object InstanceId -eq $selected) }
}
$discoveryStopwatch.Stop()
Add-DriverBenchmarkPhase -Recorder $benchmark -Name 'TraceAndTargetDiscovery' -ElapsedMilliseconds $discoveryStopwatch.ElapsedMilliseconds

$comparePath = Join-Path $PSScriptRoot 'Compare-DriverSources.ps1'
$runResults = [System.Collections.Generic.List[object]]::new()
foreach ($target in $selectedTargets) {
    Write-Host ''
    Write-Host ("Advisor source scan: {0}" -f $target.DeviceName) -ForegroundColor Cyan
    $evidenceTrace = $resolvedTrace
    $historyStopwatch = [Diagnostics.Stopwatch]::StartNew()
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedTrace 'diff.json') -PathType Leaf)) {
        $historicalTrace = @(Find-CompletedDriverTraceEvidence -CurrentTrace $resolvedTrace -InstallerHash ([string]$preview.InstallerHash) -TargetInstanceId $target.InstanceId)
        if ($historicalTrace.Count -gt 0) {
            $evidenceTrace = $historicalTrace[0]
            Write-Host ("Reusing completed trace evidence: {0}" -f $evidenceTrace) -ForegroundColor DarkCyan
        }
    }
    $historyStopwatch.Stop()
    Add-DriverBenchmarkPhase -Recorder $benchmark -Name 'HistoricalTraceLookup' -ElapsedMilliseconds $historyStopwatch.ElapsedMilliseconds -Detail $target.DeviceName
    $arguments = @{
        InstanceId = $target.InstanceId
        KnownActiveSource = 'Current active stack; package candidate from OEM trace'
        TraceFolder = $evidenceTrace
        ShowAdvisor = $true
        AdvisorNoUI = $NoUI
        AdvisorPlainText = $PlainText
        AutoSdio = -not $SkipSdio
    }
    if ($IncludeWindowsUpdate -and -not $SkipWindowsUpdate) { $arguments.IncludeWindowsUpdate = $true }
    else { $arguments.SkipWindowsUpdate = $true }
    if ($IncludeSignatureEvidence) { $arguments.IncludeSignatureEvidence = $true }
    if ($IncludeCatalog -and -not $SkipCatalog) { $arguments.IncludeCatalog = $true }
    else { $arguments.SkipCatalog = $true }
    if ($SkipSdio) { $arguments.SkipSdio = $true }
    if (-not [string]::IsNullOrWhiteSpace($SdioRoot)) { $arguments.SdioRoot = $SdioRoot }
    Measure-DriverBenchmarkPhase -Recorder $benchmark -Name 'PerDeviceComparisonAndUi' -Detail $target.DeviceName -Operation {
        & $comparePath @arguments
    }
    $runResults.Add([pscustomobject]@{ InstanceId=$target.InstanceId; DeviceName=$target.DeviceName; EvidenceTraceFolder=$evidenceTrace; Completed=$true })
}

$benchmarkResult = Complete-DriverBenchmark -Recorder $benchmark
$advisorRun = [pscustomobject]@{
    SchemaVersion = 1
    GeneratedAt = (Get-Date).ToString('o')
    TraceFolder = $resolvedTrace
    InstallerName = [string]$preview.InstallerName
    Targets = @($runResults)
    Benchmark = $benchmarkResult
}
$advisorRun | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resolvedTrace 'advisor-run.json') -Encoding utf8
$benchmarkResult | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resolvedTrace 'advisor-benchmark.json') -Encoding utf8
