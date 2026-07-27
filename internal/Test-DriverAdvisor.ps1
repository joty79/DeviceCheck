#requires -version 7.0
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '', Justification = 'Repository policy uses UTF-8 without BOM for PowerShell source.')]
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$helperRoot = Join-Path $repoRoot 'tools\DriverAdvisor'
. (Join-Path $helperRoot 'RecommendationEngine.ps1')
. (Join-Path $helperRoot 'CaseReplay.ps1')
. (Join-Path $helperRoot 'TerminalRenderer.ps1')

function Assert-DriverAdvisorTrue {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$caseRoot = Join-Path $PSScriptRoot 'fixtures\driver-advisor'
$results = @(Invoke-DriverAdvisorCaseSuite -CaseRoot $caseRoot -PassThru)
Assert-DriverAdvisorTrue -Condition ($results.Count -eq 7) -Message 'Expected seven real-machine Driver Advisor regression cases.'
Assert-DriverAdvisorTrue -Condition (@($results | Where-Object { -not $_.Passed }).Count -eq 0) -Message 'At least one Driver Advisor regression case failed.'

$views = @('Overview','Sources','Candidates','Evidence','Actions')
foreach ($result in $results) {
    $casePath = Get-ChildItem -LiteralPath $caseRoot -Filter '*.case.json' -File | Where-Object {
        (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Name -eq $result.Name
    } | Select-Object -First 1
    $case = Import-DriverAdvisorCase -Path $casePath.FullName
    foreach ($width in @(60, 80, 120)) {
        foreach ($view in $views) {
            $snapshot = ConvertTo-DriverAdvisorSnapshot -Report $case.Report -Recommendation $result.Recommendation -View $view -Width $width -PlainText
            foreach ($line in $snapshot -split '\r?\n') {
                Assert-DriverAdvisorTrue -Condition ($line.Length -le $width) -Message "Snapshot line exceeded width $width in '$($result.Name)' / ${view}: '$line'"
            }
        }

        $frame = New-DriverAdvisorFrame -Report $case.Report -Recommendation $result.Recommendation -View Overview -Width $width -Height 24 -PlainText
        Assert-DriverAdvisorTrue -Condition ($frame.LineCount -eq 24) -Message "Frame height mismatch at width $width."
        foreach ($line in $frame.Text -split '\r?\n') {
            Assert-DriverAdvisorTrue -Condition ($line.Length -le $width) -Message "Frame line exceeded width ${width}: '$line'"
        }
        $coloredFrame = New-DriverAdvisorFrame -Report $case.Report -Recommendation $result.Recommendation -View Overview -Width $width -Height 24
        Assert-DriverAdvisorTrue -Condition ($coloredFrame.LineCount -eq 24) -Message "Colored frame height mismatch at width $width."
        foreach ($line in $coloredFrame.Text -split '\r?\n') {
            $printable = ConvertFrom-DriverAdvisorAnsi -Text $line
            Assert-DriverAdvisorTrue -Condition ($printable.Length -le $width) -Message "Colored frame printable width exceeded ${width}: '$printable'"
        }
        $interactiveFrame = ConvertTo-DriverAdvisorInteractiveFrameText -Text $coloredFrame.Text
        $interactiveRows = @($interactiveFrame -split '\r?\n')
        Assert-DriverAdvisorTrue -Condition ($interactiveRows.Count -eq 24) -Message "Interactive frame height mismatch at width $width."
        $eraseToEndOfLine = "$([char]27)[K"
        foreach ($line in $interactiveRows) {
            Assert-DriverAdvisorTrue -Condition $line.EndsWith($eraseToEndOfLine) -Message "Interactive frame row did not erase its previous suffix at width $width."
        }
    }
}

$cardResult = $results | Where-Object { $_.Recommendation.Code -eq 'KeepVerifiedActiveCandidate' } | Select-Object -First 1
$cardCase = Import-DriverAdvisorCase -Path (Join-Path $caseRoot 'realtek-cardreader-activation.case.json')
$overview = ConvertTo-DriverAdvisorSnapshot -Report $cardCase.Report -Recommendation $cardResult.Recommendation -View Overview -Width 88 -PlainText
Assert-DriverAdvisorTrue -Condition $overview.Contains('DeviceCheck Driver Package Advisor') -Message 'Static snapshot must include the Advisor header.'
Assert-DriverAdvisorTrue -Condition $overview.Contains('Εκκρεμεί') -Message 'Static snapshot must separate pending functional evidence.'

$sdioCase = Import-DriverAdvisorCase -Path (Join-Path $caseRoot 'rz616-local-sdio-linked.case.json')
$sdioResult = $results | Where-Object Name -eq $sdioCase.Name | Select-Object -First 1
$sdioSources = ConvertTo-DriverAdvisorSnapshot -Report $sdioCase.Report -Recommendation $sdioResult.Recommendation -View Sources -Width 100 -PlainText
$sdioCandidates = ConvertTo-DriverAdvisorSnapshot -Report $sdioCase.Report -Recommendation $sdioResult.Recommendation -View Candidates -Width 100 -PlainText
Assert-DriverAdvisorTrue -Condition $sdioSources.Contains('Not required') -Message 'Sources view must explain that identical active/OEM selection testing is not required.'
Assert-DriverAdvisorTrue -Condition $sdioCandidates.Contains('DP_Bluetooth_SDIO01_26072.7z') -Message 'Candidates view must render normalized local SDIO pack evidence.'

Write-Output 'Driver Advisor tests passed.'
