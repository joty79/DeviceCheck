#requires -version 7.0
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '', Justification = 'Repository policy uses UTF-8 without BOM for PowerShell source.')]
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$helperRoot = Join-Path $repoRoot 'tools\DriverSourceComparison'
. (Join-Path $helperRoot 'Benchmark.ps1')
. (Join-Path $helperRoot 'ComparisonReport.ps1')
. (Join-Path $helperRoot 'TraceEvidence.ps1')
. (Join-Path $helperRoot 'PackageInspection.ps1')
. (Join-Path $helperRoot 'SelectionEvidence.ps1')
. (Join-Path $helperRoot 'SdioLocalEvidence.ps1')

function Assert-DriverComparisonEqual {
    param(
        $Actual,
        $Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', actual '$Actual'."
    }
}

function Assert-DriverComparisonTrue {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$local = [pscustomobject]@{
    KnownProvenance = 'SDIO'
    Device = [pscustomobject]@{
        FriendlyName = 'Fixture Wi-Fi'
        InstanceId = 'PCI\FIXTURE\1'
        Class = 'Net'
        Status = 'OK'
        ProblemCode = 0
        HardwareIds = @('PCI\VEN_1234&DEV_5678&SUBSYS_00000000')
        CompatibleIds = @('PCI\VEN_1234&DEV_5678')
    }
    ActiveDriver = [pscustomobject]@{
        PublishedInf = 'oem1.inf'
        Provider = 'Fixture Provider'
        Version = '2.0.0.0'
        Date = '2026-01-01'
        MatchingDeviceId = 'PCI\VEN_1234&DEV_5678&SUBSYS_00000000'
        Signer = 'Fixture Signer'
    }
}
$wu = [pscustomobject]@{
    MatchingOfferCount = 0
    TotalDriverOffers = 1
    Outcome = 'NoCurrentWuOfferObserved'
    Interpretation = 'No current target offer.'
    Offers = @()
}
$catalog = [pscustomobject]@{
    TotalRowCount = 2
    QueryHardwareId = 'PCI\VEN_1234&DEV_5678&SUBSYS_00000000'
    QueryAttempts = @([pscustomobject]@{ HardwareId = 'PCI\VEN_1234&DEV_5678&SUBSYS_00000000'; RowCount = 2 })
    Outcome = 'CatalogDiscoveryOnly'
    Interpretation = 'Discovery only.'
    Rows = @()
}
$oem = [pscustomobject]@{
    Outcome = 'ObservedOutrankedCandidate'
    InstallerName = 'Fixture OEM.exe'
    TargetPreviewMatches = @()
    TargetDriverNodes = @()
    AddedPublishedDrivers = @()
}
$sdio = [pscustomobject]@{
    MatchedDeviceCount = 1
    TotalDeviceCount = 1
    ParserWarnings = @()
    Devices = @([pscustomobject]@{
            Installed = [pscustomobject]@{ Date = '01/01/2026'; Version = '2.0.0.0'; Inf = 'oem1.inf' }
            Candidates = @([pscustomobject]@{
                    StatusLabels = @('SAME', 'CURRENT')
                    Date = '01/01/2026'
                    Version = '2.0.0.0'
                    InfFile = 'fixture.inf'
                })
        })
}

$report = New-DriverSourceComparisonReport -LocalEvidence $local -WindowsUpdateEvidence $wu -CatalogEvidence $catalog -OemTraceEvidence $oem -SdioEvidence $sdio
Assert-DriverComparisonEqual -Actual $report.OverallVerdict -Expected 'KeepCurrent_NoVerifiedBetterCandidate' -Message 'Verified-evidence verdict mismatch.'
Assert-DriverComparisonEqual -Actual $report.Safety.InstallsDrivers -Expected $false -Message 'Safety contract must prohibit driver installation.'

$markdown = ConvertTo-DriverSourceComparisonMarkdown -Report $report
Assert-DriverComparisonTrue -Condition ($markdown.Contains('CatalogDiscoveryOnly')) -Message 'Markdown must preserve the Catalog discovery boundary.'
Assert-DriverComparisonTrue -Condition ($markdown.Contains('ObservedOutrankedCandidate')) -Message 'Markdown must preserve the OEM trace outcome.'
Assert-DriverComparisonTrue -Condition ($markdown.Contains('SAME+CURRENT')) -Message 'Markdown must preserve SDIO-native status labels.'

$comparisonOnly = New-DriverSourceComparisonReport -LocalEvidence $local -WindowsUpdateEvidence $null -CatalogEvidence $null -OemTraceEvidence $null -SdioEvidence $null
Assert-DriverComparisonEqual -Actual $comparisonOnly.OverallVerdict -Expected 'EvidenceComparisonOnly' -Message 'Missing external evidence must not produce a keep-current verdict.'

$catalogPackage = [pscustomobject]@{
    MutationGuard = [pscustomobject]@{ Unchanged = $true }
    Packages = @([pscustomobject]@{
            CatalogGuid = 'fixture-guid'
            CabLength = 1
            SHA1Verified = $true
            CabSignatureStatus = 'Valid'
            Infs = @([pscustomobject]@{
                    Name = 'fixture.inf'
                    DriverVer = '03/24/2026, 3.5.0.1392'
                    ActiveComparison = [pscustomobject]@{ DateRelation = 'Newer'; VersionRelation = 'Lower' }
                    TargetMatches = @([pscustomobject]@{
                            HardwareId = 'PCI\VEN_1234&DEV_5678&SUBSYS_00000000'
                            MatchKind = 'DeviceHardwareIdToInfHardwareId'
                            FeatureScore = '0xFF'
                            IdentifierScore = '0x0000'
                            ComputedRankBody = '00FF0000'
                            ComputedRankConfidence = 'StrongInferenceNotWindowsSelectionEvidence'
                        })
                })
        })
}
$packageReport = New-DriverSourceComparisonReport -LocalEvidence $local -WindowsUpdateEvidence $wu -CatalogEvidence $catalog -CatalogPackageEvidence $catalogPackage -OemTraceEvidence $oem -SdioEvidence $sdio
Assert-DriverComparisonEqual -Actual $packageReport.OverallVerdict -Expected 'KeepCurrent_CatalogCandidateRequiresControlledSelectionProof' -Message 'A newer exact package with no WU offer must require controlled selection proof.'

$selection = [pscustomobject]@{
    Mode = 'StageOnlyNoInstall'
    CommandGuards = [pscustomobject]@{ InstallSwitchUsed = $false; RebootSwitchUsed = $false }
    NetworkGuard = [pscustomobject]@{
        ActiveInfBefore = 'oem1.inf'
        ActiveInfAfter = 'oem1.inf'
        ActiveBindingUnchanged = $true
        AdapterStayedUp = $true
    }
    Outcome = 'ObservedBestRankedCandidateWithoutBinding'
    Cleanup = [pscustomobject]@{
        DeletedPublishedInfs = @('oem2.inf')
        UninstallSwitchUsed = $false
        ForceSwitchUsed = $false
        RestoredBaselineCandidates = $true
        ActiveInfAfterCleanup = 'oem1.inf'
        AdapterStatusAfterCleanup = 'Up'
    }
    Candidates = @(
        [pscustomobject]@{ PublishedInf = 'oem2.inf'; DriverVer = '2026-03-24 / 3.5.0.1392'; Rank = '00FF0001'; Status = 'Best Ranked' },
        [pscustomobject]@{ PublishedInf = 'oem1.inf'; DriverVer = '2026-01-01 / 2.0.0.0'; Rank = '00FF0001'; Status = 'Outranked / Installed' }
    )
}
$selectionReport = New-DriverSourceComparisonReport -LocalEvidence $local -WindowsUpdateEvidence $wu -CatalogEvidence $catalog -CatalogPackageEvidence $catalogPackage -SelectionEvidence $selection -OemTraceEvidence $oem -SdioEvidence $sdio
Assert-DriverComparisonEqual -Actual $selectionReport.OverallVerdict -Expected 'CatalogCandidateObservedBestRanked_ActiveUnchanged' -Message 'Observed stage-only Windows selection must replace the controlled-proof gate.'
Assert-DriverComparisonTrue -Condition ((ConvertTo-DriverSourceComparisonMarkdown -Report $selectionReport).Contains('Observed Windows Selection Evidence')) -Message 'Markdown must render observed selection evidence.'
Assert-DriverComparisonTrue -Condition ((ConvertTo-DriverSourceComparisonMarkdown -Report $selectionReport).Contains('Cleanup restored baseline candidates: `True`')) -Message 'Markdown must render selection-experiment cleanup evidence.'

$activation = [pscustomobject]@{
    Mode = 'ControlledActivation'
    CommandGuards = [pscustomobject]@{ InstallSwitchUsed = $true; RebootSwitchUsed = $false }
    DeviceGuard = [pscustomobject]@{
        ActiveInfBefore = 'oem1.inf'
        ActiveInfAfter = 'oem2.inf'
        ActivationSucceeded = $true
        StatusAfter = 'OK'
        ProblemCodeAfter = 0
        ServiceAfter = 'FixtureService'
        ExtensionInfBefore = @('oem3.inf')
        ExtensionInfAfter = @('oem3.inf')
    }
    RuntimeEvidence = [pscustomobject]@{
        BinaryPath = 'C:\Windows\System32\drivers\fixture.sys'
        FileVersion = '3.0.0.0'
        SignatureStatus = 'Valid'
        MatchesPayloadHash = $true
    }
    FunctionalEvidence = [pscustomobject]@{
        MediaTestStatus = 'NotRunNoMediaDetected'
        Interpretation = 'Device is healthy; no physical media was present.'
    }
    Outcome = 'ObservedBestRankedCandidateActivated'
    Candidates = @([pscustomobject]@{ PublishedInf = 'oem2.inf'; DriverVer = '2026-03-24 / 3.0.0.0'; Rank = '00FF0001'; Status = 'Best Ranked / Installed' })
}
$activationReport = New-DriverSourceComparisonReport -LocalEvidence $local -WindowsUpdateEvidence $null -CatalogEvidence $null -CatalogPackageEvidence $null -SelectionEvidence $activation -OemTraceEvidence $null -SdioEvidence $null
Assert-DriverComparisonEqual -Actual $activationReport.OverallVerdict -Expected 'CandidateObservedBestRankedAndActivated' -Message 'Controlled activation evidence must produce the activated verdict.'
$activationMarkdown = ConvertTo-DriverSourceComparisonMarkdown -Report $activationReport
Assert-DriverComparisonTrue -Condition ($activationMarkdown.Contains('Physical media test: `NotRunNoMediaDetected`')) -Message 'Markdown must preserve the physical-media test boundary.'

$parsedDriverVer = ConvertFrom-DriverComparisonDriverVer -DriverVer '03/24/2026, 3.05.00.1392'
Assert-DriverComparisonEqual -Actual $parsedDriverVer.Date.ToString('yyyy-MM-dd') -Expected '2026-03-24' -Message 'DriverVer date parsing mismatch.'

Assert-DriverComparisonEqual -Actual (ConvertTo-TraceEvidenceVersionKey '23.032.2.0558') -Expected '23.32.2.558' -Message 'Trace version matching must ignore numeric leading zeros.'
Assert-DriverComparisonTrue -Condition (@(Get-SdioPackFamilyToken 'drivers\WiFi_26040.7z') -contains 'wifi') -Message 'SDIO family parsing must map an old WiFi pack identity to the current WiFi family.'
Assert-DriverComparisonEqual -Actual (Get-DriverComparisonVersionRelation -CandidateDate '01/30/2026' -CandidateVersion '25.040.2.0586' -ActiveDate '2026-01-30' -ActiveVersion '25.40.2.586') -Expected 'SameAsActive' -Message 'Archive fallback must normalize numeric DriverVer components before accepting a current payload.'

$benchmarkFixture = New-DriverBenchmarkRecorder -Name 'Fixture'
$measuredValue = Measure-DriverBenchmarkPhase -Recorder $benchmarkFixture -Name 'FixturePhase' -Operation { 'ok' }
$benchmarkFixtureResult = Complete-DriverBenchmark -Recorder $benchmarkFixture
Assert-DriverComparisonEqual -Actual $measuredValue -Expected 'ok' -Message 'Benchmark wrapper must preserve operation output.'
Assert-DriverComparisonEqual -Actual @($benchmarkFixtureResult.Phases).Count -Expected 1 -Message 'Benchmark recorder must retain measured phases.'

$sdioFixtureRoot = Join-Path $env:TEMP "DeviceCheck-SdioFilter-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $sdioFixtureRoot -Force
try {
    $sdioFixturePaths = [pscustomobject]@{ Root=$sdioFixtureRoot; Drivers=$sdioFixtureRoot; Indexes=$sdioFixtureRoot }
    $baseCandidate = [ordered]@{
        MatchKind='HardwareId'; AltSectScore=2; Score='00FF0001'; Date='01/01/2026'; DecorScore=100; MarkerScore=21
        Status='42'; StatusLabels=@('SAME','CURRENT'); DriverSection='fixture.ntamd64'; PackName='drivers\Test_26000.7z'
        InfCrc='ABC123'; InfFile='fixture\driver.inf'; Manufacturer='Fixture'; Version='2.0.0.0'; HardwareId='PCI\VEN_1234&DEV_5678&SUBSYS_00000000'; Description='Fixture device'
    }
    $currentAudit = [pscustomobject]@{ Devices=@([pscustomobject]@{ Candidates=@([pscustomobject]$baseCandidate) }) }
    $currentFiltered = Add-SdioLocalComparisonEvidence -Audit $currentAudit -LocalEvidence $local -OemTraceEvidence $null -SdioPaths $sdioFixturePaths
    Assert-DriverComparisonEqual -Actual $currentFiltered.LocalComparison.Outcome -Expected 'NoNewerOrBetterCandidate' -Message 'Fast SDIO policy must ignore current-only candidates.'
    Assert-DriverComparisonEqual -Actual $currentFiltered.LocalComparison.ApplicableCount -Expected 0 -Message 'Current-only candidates must not trigger payload inspection.'

    $null = New-Item -ItemType File -Path (Join-Path $sdioFixtureRoot 'DP_Test_26000.7z') -Force
    $newCandidate = [ordered]@{} + $baseCandidate
    $newCandidate.Status = '22'
    $newCandidate.StatusLabels = @('SAME','NEW')
    $newCandidate.Date = '02/01/2026'
    $newCandidate.Version = '3.0.0.0'
    $newCandidate.InfCrc = 'DEF456'
    $newAudit = [pscustomobject]@{ Devices=@([pscustomobject]@{ Candidates=@([pscustomobject]$newCandidate) }) }
    $newFiltered = Add-SdioLocalComparisonEvidence -Audit $newAudit -LocalEvidence $local -OemTraceEvidence $null -SdioPaths $sdioFixturePaths
    Assert-DriverComparisonEqual -Actual $newFiltered.LocalComparison.Outcome -Expected 'NewerOrBetterCandidateFound' -Message 'Fast SDIO policy must keep the best NEW candidate.'
    Assert-DriverComparisonEqual -Actual $newFiltered.LocalComparison.ApplicableCount -Expected 1 -Message 'Show-only-best policy must return exactly one eligible fixture candidate.'
}
finally {
    Remove-Item -LiteralPath $sdioFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$linkedSdio = [pscustomobject]@{
    Source = 'ExistingLog'
    MatchedDeviceCount = 1
    TotalDeviceCount = 1
    ParserWarnings = @()
    Devices = @()
    LocalComparison = [pscustomobject]@{
        Outcome = 'MatchingCandidatesFound'
        ApplicableCount = 1
        NewerThanActiveCount = 0
        SelectionAssessment = [pscustomobject]@{ Status='NotRequiredSameAsActive'; Display='Not required — extracted OEM candidate is the active driver' }
        OemCandidates = @([pscustomobject]@{ ActiveRelation='SameAsActive' })
        Candidates = @([pscustomobject]@{ ActiveRelation='OlderThanActive'; DriverVer='2025-01-01 / 1.0.0.0'; SdioStatus='SAME+OLD'; InfFile='fixture.inf'; PackName='DP_Fixture.7z' })
    }
}
$linkedOem = [pscustomobject]@{
    InstallerName='Fixture OEM.exe'
    Outcome='ObservedPackageMatchPreviewOnly'
    TargetPreviewMatches=@()
    TargetDriverNodes=@()
    AddedPublishedDrivers=@()
}
$linkedReport = New-DriverSourceComparisonReport -LocalEvidence $local -WindowsUpdateEvidence $null -CatalogEvidence $null -CatalogPackageEvidence $null -SelectionEvidence $null -OemTraceEvidence $linkedOem -SdioEvidence $linkedSdio
Assert-DriverComparisonEqual -Actual $linkedReport.OverallVerdict -Expected 'KeepCurrent_NoVerifiedBetterCandidate' -Message 'Identical active/OEM evidence with no newer local SDIO candidate should keep current.'
Assert-DriverComparisonTrue -Condition ((ConvertTo-DriverSourceComparisonMarkdown $linkedReport).Contains('NotRequiredSameAsActive')) -Message 'Markdown must preserve the no-selection-required assessment.'
$extensionPreview = [pscustomobject]@{ Inf='payload\LnvDmft.inf'; DriverVer='06/12/2023,1.0.0.27' }
$extensionNode = [pscustomobject]@{ OriginalName='lnvdmft.inf'; DriverDate='2023-06-12'; DriverVersion='1.0.0.27' }
Assert-DriverComparisonTrue -Condition (Test-TraceEvidencePackageNode -Node $extensionNode -PreviewMatch $extensionPreview) -Message 'Extension preview must map to the matching SetupAPI package node.'
$differentVersionNode = [pscustomobject]@{ OriginalName='lnvdmft.inf'; DriverDate='2023-06-12'; DriverVersion='1.0.0.26' }
Assert-DriverComparisonTrue -Condition (-not (Test-TraceEvidencePackageNode -Node $differentVersionNode -PreviewMatch $extensionPreview)) -Message 'Same INF name with a different version must not be attributed to the package.'

Write-Output 'Driver source comparison tests passed.'
