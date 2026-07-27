#requires -version 7.0
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive summary output is intentional; -AsJson provides pipeline-safe output.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are consumed inside benchmarked scriptblock closures that PSScriptAnalyzer does not trace.')]
[CmdletBinding()]
param(
    [string]$Filter = 'RZ616 Wi-Fi 6E',

    [AllowEmptyString()]
    [string]$InstanceId = '',

    [AllowEmptyString()]
    [string]$KnownActiveSource = '',

    [switch]$SkipWindowsUpdate,

    [switch]$IncludeWindowsUpdate,

    [switch]$IncludeSignatureEvidence,

    [switch]$SkipCatalog,

    [switch]$IncludeCatalog,

    [AllowEmptyString()]
    [string]$MSCatalogModulePath = '',

    [AllowEmptyString()]
    [string]$SdioReportPath = '',

    [switch]$AutoSdio,

    [switch]$SkipSdio,

    [AllowEmptyString()]
    [string]$SdioRoot = '',

    [AllowEmptyString()]
    [string]$CatalogInspectionManifest = '',

    [AllowEmptyString()]
    [string]$SelectionEvidencePath = '',

    [AllowEmptyString()]
    [string]$TraceFolder = '',

    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.devicecheck-data\driver-source-comparisons'),

    [switch]$NoReport,

    [switch]$ShowAdvisor,

    [switch]$AdvisorNoUI,

    [switch]$AdvisorPlainText,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$helperRoot = Join-Path $PSScriptRoot 'DriverSourceComparison'
$benchmarkHelper = Join-Path $helperRoot 'Benchmark.ps1'
if (-not (Test-Path -LiteralPath $benchmarkHelper -PathType Leaf)) { throw "Required benchmark helper not found: $benchmarkHelper" }
. $benchmarkHelper
$benchmark = New-DriverBenchmarkRecorder -Name 'DriverSourceComparison'
$helperStopwatch = [Diagnostics.Stopwatch]::StartNew()
foreach ($helper in @('LocalEvidence.ps1', 'WindowsUpdateEvidence.ps1', 'CatalogEvidence.ps1', 'PackageInspection.ps1', 'SelectionEvidence.ps1', 'TraceEvidence.ps1', 'SdioLocalEvidence.ps1', 'ComparisonReport.ps1')) {
    $helperPath = Join-Path $helperRoot $helper
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        throw "Required comparison helper not found: $helperPath"
    }
    . $helperPath
}
$helperStopwatch.Stop()
Add-DriverBenchmarkPhase -Recorder $benchmark -Name 'HelperLoad' -ElapsedMilliseconds $helperStopwatch.ElapsedMilliseconds

$local = Measure-DriverBenchmarkPhase -Recorder $benchmark -Name 'LocalWindowsEvidence' -Operation {
    Get-DriverComparisonLocalEvidence -Filter $Filter -InstanceId $InstanceId -KnownActiveSource $KnownActiveSource -BenchmarkRecorder $benchmark -IncludeSignatureEvidence:$IncludeSignatureEvidence
}
$primaryHardwareId = @($local.Device.HardwareIds | Select-Object -First 1)
if ($primaryHardwareId.Count -eq 0) {
    throw "No Hardware ID was available for '$($local.Device.FriendlyName)'."
}

$windowsUpdate = if ($SkipWindowsUpdate -or -not $IncludeWindowsUpdate) {
    $null
}
else {
    Measure-DriverBenchmarkPhase -Recorder $benchmark -Name 'WindowsUpdateQuery' -Operation {
        Get-WindowsUpdateDriverEvidence -HardwareIds $local.Device.HardwareIds -CompatibleIds $local.Device.CompatibleIds
    }
}

$catalog = if ($SkipCatalog -or -not $IncludeCatalog) {
    $null
}
else {
    Measure-DriverBenchmarkPhase -Recorder $benchmark -Name 'CatalogQuery' -Operation {
        $resolvedCatalogModule = Resolve-MSCatalogModulePath -RequestedPath $MSCatalogModulePath -RepoRoot $repoRoot
        Get-CatalogDriverEvidence -HardwareIds $local.Device.HardwareIds -ModulePath $resolvedCatalogModule
    }
}

$catalogPackage = $null
if (-not [string]::IsNullOrWhiteSpace($CatalogInspectionManifest)) {
    $catalogPackage = Measure-DriverBenchmarkPhase -Recorder $benchmark -Name 'CatalogInspectionImport' -Operation {
        Import-CatalogPackageInspectionEvidence -ManifestPath $CatalogInspectionManifest -ExpectedInstanceId $local.Device.InstanceId
    }
}

$selectionEvidence = $null
if (-not [string]::IsNullOrWhiteSpace($SelectionEvidencePath)) {
    $selectionEvidence = Measure-DriverBenchmarkPhase -Recorder $benchmark -Name 'SelectionEvidenceImport' -Operation {
        Import-DriverSelectionExperimentEvidence -ManifestPath $SelectionEvidencePath -ExpectedInstanceId $local.Device.InstanceId
    }
}

$oemTrace = $null
if (-not [string]::IsNullOrWhiteSpace($TraceFolder)) {
    if (-not (Test-Path -LiteralPath $TraceFolder -PathType Container)) {
        throw "Driver-package trace folder not found: $TraceFolder"
    }
    $oemTrace = Measure-DriverBenchmarkPhase -Recorder $benchmark -Name 'OemTraceImport' -Operation {
        Get-DriverPackageTraceEvidence -TraceFolder (Resolve-Path -LiteralPath $TraceFolder).ProviderPath -InstanceId $local.Device.InstanceId
    }
}

$sdio = $null
if (-not $SkipSdio -and -not [string]::IsNullOrWhiteSpace($SdioReportPath)) {
    if (-not (Test-Path -LiteralPath $SdioReportPath -PathType Leaf)) {
        throw "SDIO report not found: $SdioReportPath"
    }
    $sdio = Measure-DriverBenchmarkPhase -Recorder $benchmark -Name 'SdioReportImport' -Operation {
        Get-Content -LiteralPath $SdioReportPath -Raw | ConvertFrom-Json
    }
}
elseif (-not $SkipSdio -and $AutoSdio) {
    $sdio = Measure-DriverBenchmarkPhase -Recorder $benchmark -Name 'SdioLocalEvidence' -Operation {
        Get-AutomaticSdioEvidence -LocalEvidence $local -OemTraceEvidence $oemTrace -RepoRoot $repoRoot -OutputRoot $OutputRoot -SdioRoot $SdioRoot
    }
}

$report = Measure-DriverBenchmarkPhase -Recorder $benchmark -Name 'ReportModel' -Operation {
    New-DriverSourceComparisonReport -LocalEvidence $local -WindowsUpdateEvidence $windowsUpdate -CatalogEvidence $catalog -CatalogPackageEvidence $catalogPackage -SelectionEvidence $selectionEvidence -OemTraceEvidence $oemTrace -SdioEvidence $sdio
}
$advisorEnginePath = Join-Path $PSScriptRoot 'DriverAdvisor\RecommendationEngine.ps1'
if (-not (Test-Path -LiteralPath $advisorEnginePath -PathType Leaf)) {
    throw "Required Driver Advisor engine not found: $advisorEnginePath"
}
. $advisorEnginePath
$advisorRecommendation = Measure-DriverBenchmarkPhase -Recorder $benchmark -Name 'RecommendationEngine' -Operation {
    Get-DriverAdvisorRecommendation -Report $report
}
$report | Add-Member -NotePropertyName AdvisorRecommendation -NotePropertyValue $advisorRecommendation -Force

if ($ShowAdvisor -and $NoReport) {
    throw '-ShowAdvisor requires a generated report; remove -NoReport.'
}
if ($ShowAdvisor -and $AsJson) {
    throw '-ShowAdvisor and -AsJson cannot be used together.'
}

if (-not $NoReport) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $OutputRoot "driver-source-comparison-$stamp.json"
    $markdownPath = Join-Path $OutputRoot "driver-source-comparison-$stamp.md"
    $benchmarkPath = Join-Path $OutputRoot "driver-source-comparison-$stamp.benchmark.json"
    $report | Add-Member -NotePropertyName Paths -NotePropertyValue ([pscustomobject]@{
            Json = $jsonPath
            Markdown = $markdownPath
            Benchmark = $benchmarkPath
        }) -Force
    $report | Add-Member -NotePropertyName Benchmark -NotePropertyValue (Get-DriverBenchmarkSnapshot -Recorder $benchmark) -Force
    Measure-DriverBenchmarkPhase -Recorder $benchmark -Name 'InitialReportWrite' -Operation {
        $report | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
        ConvertTo-DriverSourceComparisonMarkdown -Report $report | Set-Content -LiteralPath $markdownPath -Encoding UTF8
    }
}

if ($AsJson) {
    $benchmarkResult = Complete-DriverBenchmark -Recorder $benchmark
    $report | Add-Member -NotePropertyName Benchmark -NotePropertyValue $benchmarkResult -Force
    if (-not $NoReport) {
        $benchmarkResult | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report.Paths.Benchmark -Encoding UTF8
        $report | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $report.Paths.Json -Encoding UTF8
        ConvertTo-DriverSourceComparisonMarkdown -Report $report | Set-Content -LiteralPath $report.Paths.Markdown -Encoding UTF8
    }
    $report | ConvertTo-Json -Depth 24
    return
}

if ($ShowAdvisor) {
    $advisorPath = Join-Path $PSScriptRoot 'Invoke-DriverPackageAdvisor.ps1'
    Measure-DriverBenchmarkPhase -Recorder $benchmark -Name 'AdvisorUi' -Operation {
        & $advisorPath -ReportPath $report.Paths.Json -NoUI:$AdvisorNoUI -PlainText:$AdvisorPlainText
    }
    $benchmarkResult = Complete-DriverBenchmark -Recorder $benchmark
    $report | Add-Member -NotePropertyName Benchmark -NotePropertyValue $benchmarkResult -Force
    $benchmarkResult | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report.Paths.Benchmark -Encoding UTF8
    $report | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $report.Paths.Json -Encoding UTF8
    ConvertTo-DriverSourceComparisonMarkdown -Report $report | Set-Content -LiteralPath $report.Paths.Markdown -Encoding UTF8
    return
}

$benchmarkResult = Complete-DriverBenchmark -Recorder $benchmark
$report | Add-Member -NotePropertyName Benchmark -NotePropertyValue $benchmarkResult -Force
if (-not $NoReport) {
    $benchmarkResult | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report.Paths.Benchmark -Encoding UTF8
    $report | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $report.Paths.Json -Encoding UTF8
    ConvertTo-DriverSourceComparisonMarkdown -Report $report | Set-Content -LiteralPath $report.Paths.Markdown -Encoding UTF8
}

Write-Host 'Driver Source Comparison' -ForegroundColor Cyan
Write-Host '------------------------' -ForegroundColor Cyan
Write-Host ("Device    : {0}" -f $report.Target.FriendlyName)
Write-Host ("Active    : {0} | {1} | {2}" -f $report.Active.ActiveDriver.PublishedInf, $report.Active.ActiveDriver.Version, $report.Active.ActiveDriver.Date)
Write-Host ("Provenance: {0}" -f $report.Active.KnownProvenance)
if ($null -ne $report.Sources.WindowsUpdate) {
    Write-Host ("WUAPI     : {0} | matches {1}" -f $report.Sources.WindowsUpdate.Outcome, $report.Sources.WindowsUpdate.MatchingOfferCount)
}
if ($null -ne $report.Sources.CatalogPublic) {
    Write-Host ("Catalog   : {0} public rows | discovery only" -f $report.Sources.CatalogPublic.TotalRowCount)
}
if ($null -ne $report.Sources.CatalogPackage) {
    $packageMatches = @($report.Sources.CatalogPackage.Packages | ForEach-Object { $_.Infs } | ForEach-Object { $_.TargetMatches }).Count
    Write-Host ("CAB inspect: {0} packages | {1} exact INF matches | guard {2}" -f @($report.Sources.CatalogPackage.Packages).Count, $packageMatches, $report.Sources.CatalogPackage.MutationGuard.Unchanged)
}
if ($null -ne $report.Sources.SelectionExperiment) {
    if ($report.Sources.SelectionExperiment.Mode -eq 'ControlledActivation') {
        Write-Host ("Selection : {0} | activated {1}" -f $report.Sources.SelectionExperiment.Outcome, $report.Sources.SelectionExperiment.DeviceGuard.ActivationSucceeded)
    }
    else {
        Write-Host ("Selection : {0} | active unchanged {1}" -f $report.Sources.SelectionExperiment.Outcome, $report.Sources.SelectionExperiment.NetworkGuard.ActiveBindingUnchanged)
    }
}
if ($null -ne $report.Sources.OEMTrace) {
    Write-Host ("OEM trace : {0}" -f $report.Sources.OEMTrace.Outcome)
}
if ($null -ne $report.Sources.SDIO) {
    $sdioCandidates = @($report.Sources.SDIO.Devices | ForEach-Object { $_.Candidates }).Count
    Write-Host ("SDIO      : {0} candidates | {1} parser warnings" -f $sdioCandidates, @($report.Sources.SDIO.ParserWarnings).Count)
}
Write-Host ("Verdict   : {0}" -f $report.OverallVerdict) -ForegroundColor Yellow
if ($null -ne $report.PSObject.Properties['Paths']) {
    Write-Host ("JSON      : {0}" -f $report.Paths.Json) -ForegroundColor DarkGray
    Write-Host ("Markdown  : {0}" -f $report.Paths.Markdown) -ForegroundColor DarkGray
    Write-Host ("Benchmark : {0}" -f $report.Paths.Benchmark) -ForegroundColor DarkGray
}
