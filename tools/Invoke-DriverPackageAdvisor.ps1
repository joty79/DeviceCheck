#requires -version 7.0
[CmdletBinding()]
param(
    [AllowEmptyString()][string]$ReportPath = '',
    [AllowEmptyString()][string]$CasePath = '',
    [string]$ReportRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.devicecheck-data\driver-source-comparisons'),
    [ValidateSet('Overview','Sources','Candidates','Evidence','Actions')][string]$View = 'Overview',
    [switch]$NoUI,
    [switch]$PlainText,
    [switch]$AsJson,
    [int]$Width = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$helperRoot = Join-Path $PSScriptRoot 'DriverAdvisor'
foreach ($helper in @('RecommendationEngine.ps1','CaseReplay.ps1','TerminalRenderer.ps1')) {
    $path = Join-Path $helperRoot $helper
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required Driver Advisor helper not found: $path" }
    . $path
}

if (-not [string]::IsNullOrWhiteSpace($CasePath)) {
    $case = Import-DriverAdvisorCase -Path $CasePath
    $report = $case.Report
    $resolvedSourcePath = (Resolve-Path -LiteralPath $CasePath).ProviderPath
}
else {
    if ([string]::IsNullOrWhiteSpace($ReportPath)) {
        $latest = Get-ChildItem -LiteralPath $ReportRoot -Filter 'driver-source-comparison-*.json' -File -ErrorAction Stop |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -eq $latest) { throw "No driver comparison reports found under '$ReportRoot'." }
        $ReportPath = $latest.FullName
    }
    if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) { throw "Driver comparison report not found: $ReportPath" }
    $resolvedSourcePath = (Resolve-Path -LiteralPath $ReportPath).ProviderPath
    $report = Get-Content -LiteralPath $resolvedSourcePath -Raw | ConvertFrom-Json
}

$report | Add-Member -NotePropertyName AdvisorReportPath -NotePropertyValue $resolvedSourcePath -Force
$recommendation = Get-DriverAdvisorRecommendation -Report $report

if ($AsJson) {
    [pscustomobject]@{ ReportPath=$resolvedSourcePath; Recommendation=$recommendation } | ConvertTo-Json -Depth 12
    return
}

$outputRedirected = $false
try { $outputRedirected = [Console]::IsOutputRedirected } catch { Write-Debug "Output redirection detection failed: $($_.Exception.Message)" }
if ($NoUI -or $outputRedirected) {
    ConvertTo-DriverAdvisorSnapshot -Report $report -Recommendation $recommendation -View $View -Width $Width -PlainText:$PlainText
    return
}

Show-DriverAdvisorTui -Report $report -Recommendation $recommendation -InitialView $View
