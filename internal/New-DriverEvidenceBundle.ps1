[CmdletBinding()]
param(
    [string]$InventoryPath = '',

    [string]$InventoryRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'devices'),

    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'driver-evidence'),

    [string]$Filter = '',

    [switch]$AllDevices,

    [switch]$SkipLiveIdEnrichment,

    [switch]$NoReport,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LatestInventoryPath {
    param(
        [string]$RootPath
    )

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return ''
    }

    $latest = Get-ChildItem -LiteralPath $RootPath -Filter 'device-inventory-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $latest) {
        return ''
    }

    return $latest.FullName
}

function Get-InventoryBundle {
    param(
        [AllowEmptyString()]
        [string]$Path,
        [string]$RootPath
    )

    $resolvedPath = $Path
    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        $resolvedPath = Get-LatestInventoryPath -RootPath $RootPath
    }

    if ([string]::IsNullOrWhiteSpace($resolvedPath) -or -not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "No inventory JSON found. Run internal\Show-DeviceInventory.ps1 first."
    }

    [pscustomobject]@{
        Path = (Resolve-Path -LiteralPath $resolvedPath).ProviderPath
        Inventory = (Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json)
    }
}

function Invoke-JsonReportTool {
    param(
        [string]$ScriptName,
        [string[]]$ToolArguments
    )

    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Required tool not found: $scriptPath"
    }

    $pwshPath = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($pwshPath)) {
        $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    }

    $processArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $ToolArguments
    $jsonText = (& $pwshPath @processArguments | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        throw "Tool produced no JSON output: $ScriptName"
    }

    try {
        return ($jsonText | ConvertFrom-Json)
    }
    catch {
        throw "Tool did not produce valid JSON: $ScriptName. $($_.Exception.Message)"
    }
}

function Get-ObjectPropertyValue {
    param(
        [object]$InputObject,
        [string]$PropertyName,
        [object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Get-DeviceKey {
    param(
        [object]$Device
    )

    return ([string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'InstanceId' -DefaultValue '')).ToUpperInvariant()
}

function New-DeviceMap {
    param(
        [object[]]$Devices
    )

    $map = @{}
    foreach ($device in @($Devices)) {
        $key = Get-DeviceKey -Device $device
        if (-not [string]::IsNullOrWhiteSpace($key) -and -not $map.ContainsKey($key)) {
            $map[$key] = $device
        }
    }

    return $map
}

function Test-GenericHardwareId {
    param(
        [AllowEmptyString()]
        [string]$HardwareId
    )

    if ([string]::IsNullOrWhiteSpace($HardwareId)) {
        return $false
    }

    return $HardwareId -match '(?i)\\CLASS_|\\MS_COMP_|^USB\\COMPOSITE$|^ROOT\\|^SWD\\|^ACPI\\PNP|\*PNP'
}

function Test-SpecificHardwareId {
    param(
        [AllowEmptyString()]
        [string]$HardwareId
    )

    if ([string]::IsNullOrWhiteSpace($HardwareId)) {
        return $false
    }

    return $HardwareId -match '^(?i)PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}' -or
        $HardwareId -match '^(?i)(USB|HID)\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}'
}

function Get-PrimarySearchHardwareId {
    param(
        [object]$CandidateDevice
    )

    foreach ($searchId in @((Get-ObjectPropertyValue -InputObject $CandidateDevice -PropertyName 'SearchIds' -DefaultValue @()))) {
        $hardwareId = [string](Get-ObjectPropertyValue -InputObject $searchId -PropertyName 'HardwareId' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($hardwareId)) {
            return $hardwareId
        }
    }

    return [string](Get-ObjectPropertyValue -InputObject $CandidateDevice -PropertyName 'InstanceId' -DefaultValue '')
}

function Get-SearchLinkCount {
    param(
        [object]$CandidateDevice
    )

    $count = 0
    foreach ($searchId in @((Get-ObjectPropertyValue -InputObject $CandidateDevice -PropertyName 'SearchIds' -DefaultValue @()))) {
        $count += @((Get-ObjectPropertyValue -InputObject $searchId -PropertyName 'Links' -DefaultValue @())).Count
    }

    return $count
}

function New-DeviceAssessment {
    param(
        [object]$InventoryDevice,
        [object]$CandidateDevice,
        [object]$InfDevice
    )

    $notes = [System.Collections.Generic.List[string]]::new()
    $recommendedAction = 'Review evidence'
    $evidenceLevel = 'InventoryOnly'

    $driver = Get-ObjectPropertyValue -InputObject $InventoryDevice -PropertyName 'DriverProviderName' -DefaultValue ''
    $priority = [string](Get-ObjectPropertyValue -InputObject $InventoryDevice -PropertyName 'DriverResearchPriority' -DefaultValue '')
    $problem = [string](Get-ObjectPropertyValue -InputObject $InventoryDevice -PropertyName 'Problem' -DefaultValue '')
    $status = [string](Get-ObjectPropertyValue -InputObject $InventoryDevice -PropertyName 'Status' -DefaultValue '')
    $infMatches = @((Get-ObjectPropertyValue -InputObject $InfDevice -PropertyName 'Matches' -DefaultValue @()))
    $exactInfMatches = @($infMatches | Where-Object { $_.MatchType -eq 'ExactHardwareId' })
    $specificExactMatches = @($exactInfMatches | Where-Object { -not (Test-GenericHardwareId -HardwareId ([string]$_.HardwareId)) })
    $genericExactMatches = @($exactInfMatches | Where-Object { Test-GenericHardwareId -HardwareId ([string]$_.HardwareId) })
    $modelSectionExactMatches = @($exactInfMatches | Where-Object { $_.Source -eq 'ManufacturerModelSection' })
    $fallbackExactMatches = @($exactInfMatches | Where-Object { $_.Source -eq 'FallbackLineScan' })
    $hasInstalledInf = [bool](Get-ObjectPropertyValue -InputObject (Get-ObjectPropertyValue -InputObject $InfDevice -PropertyName 'MatchSummary' -DefaultValue $null) -PropertyName 'HasInstalledInfFile' -DefaultValue $false)
    $searchLinkCount = Get-SearchLinkCount -CandidateDevice $CandidateDevice

    if ($specificExactMatches.Count -gt 0) {
        $evidenceLevel = 'LocalInfExactSpecific'
        $notes.Add('Local installed INF contains an exact vendor/device-style Hardware ID match.')
    }
    elseif ($genericExactMatches.Count -gt 0) {
        $evidenceLevel = 'LocalInfExactGeneric'
        $notes.Add('Local installed INF match is generic/class-based, useful as current-driver evidence but not OEM proof.')
    }
    elseif ($hasInstalledInf) {
        $evidenceLevel = 'InstalledInfMetadata'
        $notes.Add('Inventory points to an installed local INF, but no exact Hardware ID line matched.')
    }
    elseif ($searchLinkCount -gt 0) {
        $evidenceLevel = 'SearchLinksOnly'
        $notes.Add('No local INF match was found; use search links for manual research.')
    }

    if ($modelSectionExactMatches.Count -gt 0) {
        $notes.Add('Exact local INF evidence came from a section-aware [Manufacturer] model section parse.')
    }
    elseif ($fallbackExactMatches.Count -gt 0) {
        $notes.Add('Exact local INF evidence came from fallback line scanning; review with lower confidence.')
    }

    if ($driver -match '^(?i:Microsoft|Windows Hello Face)$') {
        $notes.Add('Current installed provider is Microsoft/inbox or Microsoft-adjacent.')
    }
    if ($problem -eq 'CM_PROB_DISABLED') {
        $notes.Add('Windows reports the device is disabled; this may be intentional and is not automatically a missing-driver signal.')
    }
    elseif (-not [string]::IsNullOrWhiteSpace($problem) -and $problem -notin @('0', 'CM_PROB_NONE')) {
        $notes.Add("Windows reports an actionable problem code: $problem.")
    }
    if (-not [string]::IsNullOrWhiteSpace($status) -and $status -notmatch '^(?i:OK|Unknown)$') {
        $notes.Add("Windows status is $status.")
    }

    if ($priority -eq 'High') {
        $recommendedAction = 'Prioritize OEM/vendor driver research'
    }
    elseif ($priority -eq 'Medium' -and $genericExactMatches.Count -gt 0) {
        $recommendedAction = 'Review OEM driver availability; current local match is generic/class driver'
    }
    elseif ($priority -eq 'Medium') {
        $recommendedAction = 'Review driver candidates'
    }
    elseif ($evidenceLevel -eq 'LocalInfExactSpecific') {
        $recommendedAction = 'Treat local INF evidence as strong; compare with candidate links only if symptoms remain'
    }

    [pscustomobject]@{
        EvidenceLevel = $evidenceLevel
        RecommendedAction = $recommendedAction
        Notes = @($notes)
        LocalInf = [pscustomobject]@{
            ExactMatches = $exactInfMatches.Count
            SpecificExactMatches = $specificExactMatches.Count
            GenericExactMatches = $genericExactMatches.Count
            ModelSectionExactMatches = $modelSectionExactMatches.Count
            FallbackExactMatches = $fallbackExactMatches.Count
            HasInstalledInfFile = $hasInstalledInf
        }
        SearchLinks = $searchLinkCount
    }
}

function New-DriverResearchTrustAssessment {
    param(
        [object]$InventoryDevice,
        [object]$CandidateDevice,
        [object]$InfDevice,
        [object]$Assessment
    )

    $factors = [System.Collections.Generic.List[string]]::new()
    $blockers = [System.Collections.Generic.List[string]]::new()
    $score = 0

    $needsDriverResearch = [bool](Get-ObjectPropertyValue -InputObject $CandidateDevice -PropertyName 'NeedsDriverResearch' -DefaultValue $false)
    $priority = [string](Get-ObjectPropertyValue -InputObject $CandidateDevice -PropertyName 'DriverResearchPriority' -DefaultValue '')
    $problem = [string](Get-ObjectPropertyValue -InputObject $CandidateDevice -PropertyName 'Problem' -DefaultValue '')
    $provider = [string](Get-ObjectPropertyValue -InputObject (Get-ObjectPropertyValue -InputObject $CandidateDevice -PropertyName 'Driver' -DefaultValue $null) -PropertyName 'Provider' -DefaultValue '')
    $bestSearchId = Get-PrimarySearchHardwareId -CandidateDevice $CandidateDevice
    $searchLinkCount = Get-SearchLinkCount -CandidateDevice $CandidateDevice
    $localInf = Get-ObjectPropertyValue -InputObject $Assessment -PropertyName 'LocalInf' -DefaultValue $null
    $evidenceLevel = [string](Get-ObjectPropertyValue -InputObject $Assessment -PropertyName 'EvidenceLevel' -DefaultValue 'InventoryOnly')
    $specificExactMatches = [int](Get-ObjectPropertyValue -InputObject $localInf -PropertyName 'SpecificExactMatches' -DefaultValue 0)
    $genericExactMatches = [int](Get-ObjectPropertyValue -InputObject $localInf -PropertyName 'GenericExactMatches' -DefaultValue 0)
    $modelSectionExactMatches = [int](Get-ObjectPropertyValue -InputObject $localInf -PropertyName 'ModelSectionExactMatches' -DefaultValue 0)
    $fallbackExactMatches = [int](Get-ObjectPropertyValue -InputObject $localInf -PropertyName 'FallbackExactMatches' -DefaultValue 0)

    if ($needsDriverResearch) {
        $score += 10
        $factors.Add('Device is classified as NeedsDriverResearch.')
    }
    else {
        $factors.Add('Device is not classified as a default driver-research target.')
    }

    if ($priority -eq 'High') {
        $score += 15
        $factors.Add('Driver research priority is High.')
    }
    elseif ($priority -eq 'Medium') {
        $score += 8
        $factors.Add('Driver research priority is Medium.')
    }

    if (Test-SpecificHardwareId -HardwareId $bestSearchId) {
        $score += 20
        $factors.Add("Best search ID is vendor/device-specific: $bestSearchId")
    }
    elseif (-not [string]::IsNullOrWhiteSpace($bestSearchId)) {
        $score += 5
        $blockers.Add("Best search ID is generic or instance-shaped; review manually: $bestSearchId")
    }
    else {
        $blockers.Add('No usable search Hardware ID was found.')
    }

    if ($searchLinkCount -gt 0) {
        $score += [Math]::Min(10, $searchLinkCount)
        $factors.Add(("Search links are available: {0}" -f $searchLinkCount))
    }
    else {
        $blockers.Add('No search links are available yet.')
    }

    if ($specificExactMatches -gt 0) {
        $score += 25
        $factors.Add(("Local installed INF has vendor/device-specific exact matches: {0}" -f $specificExactMatches))
    }
    elseif ($genericExactMatches -gt 0) {
        $score += 10
        $factors.Add(("Local installed INF has generic/class exact matches: {0}" -f $genericExactMatches))
        $blockers.Add('Generic local INF evidence is current-driver evidence, not OEM candidate proof.')
    }
    elseif ($evidenceLevel -eq 'InstalledInfMetadata') {
        $score += 5
        $factors.Add('Installed INF metadata is present, but exact Hardware ID evidence is missing.')
    }

    if ($modelSectionExactMatches -gt 0) {
        $score += 15
        $factors.Add(("Exact INF evidence came from [Manufacturer] model sections: {0}" -f $modelSectionExactMatches))
    }
    if ($fallbackExactMatches -gt 0) {
        $score += 5
        $blockers.Add(("Some INF evidence came from fallback line scanning: {0}" -f $fallbackExactMatches))
    }

    if ($provider -match '^(?i:Microsoft|Windows Hello Face)$') {
        $score += 5
        $factors.Add('Current provider is Microsoft/inbox or Microsoft-adjacent; OEM availability may be worth checking.')
    }

    if ($problem -eq 'CM_PROB_DISABLED') {
        $blockers.Add('Device is disabled; this may be intentional and must not trigger automatic update behavior.')
    }
    elseif (-not [string]::IsNullOrWhiteSpace($problem) -and $problem -notin @('0', 'CM_PROB_NONE')) {
        $factors.Add("Windows reports problem code $problem.")
    }

    $blockers.Add('No candidate driver package metadata has been collected yet.')
    $blockers.Add('No signature, catalog, OS target, source URL, or rollback evidence has been verified.')

    if ($specificExactMatches -eq 0 -and $genericExactMatches -gt 0) {
        $score = [Math]::Min($score, 65)
    }
    if ($problem -eq 'CM_PROB_DISABLED') {
        $score = [Math]::Min($score, 60)
    }

    $score = [Math]::Min(100, [Math]::Max(0, $score))
    $level = 'InventoryOnly'
    $readiness = 'InventoryReviewOnly'

    if (-not $needsDriverResearch) {
        $level = 'NoDriverResearchNeeded'
        $readiness = 'NoDefaultCandidateReview'
    }
    elseif ($score -ge 70) {
        $level = 'StrongEvidenceManualReview'
        $readiness = 'ReadyForManualCandidateReview'
    }
    elseif ($score -ge 45) {
        $level = 'ReadyForManualCandidateReview'
        $readiness = 'ReadyForManualCandidateReview'
    }
    elseif ($score -ge 25) {
        $level = 'WeakEvidence'
        $readiness = 'NeedsMoreEvidenceBeforeCandidateReview'
    }

    [pscustomobject]@{
        SchemaVersion = 1
        Level = $level
        Score = $score
        CandidateReadiness = $readiness
        BestSearchId = $bestSearchId
        NextGate = 'Collect real candidate package metadata, then verify signature, catalog, OS targeting, version/date, source trust, and rollback path.'
        AllowsDownload = $false
        AllowsAutomaticInstall = $false
        AllowsDriverRemoval = $false
        Factors = @($factors)
        Blockers = @($blockers)
    }
}

function New-DriverEvidenceBundle {
    param(
        [object]$InventoryBundle,
        [object]$CandidateReport,
        [object]$InfReport,
        [AllowEmptyString()]
        [string]$FilterText,
        [bool]$AllDevicesValue,
        [bool]$SkipLiveIdEnrichmentValue
    )

    $inventoryMap = New-DeviceMap -Devices @($InventoryBundle.Inventory.Devices)
    $infMap = New-DeviceMap -Devices @($InfReport.Devices)
    $devices = [System.Collections.Generic.List[object]]::new()

    foreach ($candidateDevice in @($CandidateReport.Devices)) {
        $key = Get-DeviceKey -Device $candidateDevice
        $inventoryDevice = if ($inventoryMap.ContainsKey($key)) { $inventoryMap[$key] } else { $null }
        $infDevice = if ($infMap.ContainsKey($key)) { $infMap[$key] } else { $null }
        $assessment = New-DeviceAssessment -InventoryDevice $inventoryDevice -CandidateDevice $candidateDevice -InfDevice $infDevice
        $researchTrust = New-DriverResearchTrustAssessment -InventoryDevice $inventoryDevice -CandidateDevice $candidateDevice -InfDevice $infDevice -Assessment $assessment

        $devices.Add([pscustomobject]@{
            FriendlyName = $candidateDevice.FriendlyName
            InstanceId = $candidateDevice.InstanceId
            Class = $candidateDevice.Class
            DeviceKind = $candidateDevice.DeviceKind
            AttentionCategory = $candidateDevice.AttentionCategory
            DriverResearchPriority = $candidateDevice.DriverResearchPriority
            NeedsDriverResearch = $candidateDevice.NeedsDriverResearch
            Status = $candidateDevice.Status
            Problem = $candidateDevice.Problem
            Assessment = $assessment
            DriverResearchTrust = $researchTrust
            Inventory = $inventoryDevice
            InstalledDriver = $candidateDevice.Driver
            CandidateSearch = [pscustomobject]@{
                Reasons = @($candidateDevice.Reasons)
                SearchIds = @($candidateDevice.SearchIds)
            }
            LocalInfEvidence = [pscustomobject]@{
                InstalledInf = Get-ObjectPropertyValue -InputObject $infDevice -PropertyName 'InstalledInf' -DefaultValue $null
                Matches = @((Get-ObjectPropertyValue -InputObject $infDevice -PropertyName 'Matches' -DefaultValue @()))
                MatchSummary = Get-ObjectPropertyValue -InputObject $infDevice -PropertyName 'MatchSummary' -DefaultValue $null
                LiveIdEvidence = Get-ObjectPropertyValue -InputObject $infDevice -PropertyName 'LiveIdEvidence' -DefaultValue $null
            }
        })
    }

    $evidenceLevelCounts = [ordered]@{}
    foreach ($group in @($devices | Group-Object { $_.Assessment.EvidenceLevel } | Sort-Object Name)) {
        $evidenceLevelCounts[$group.Name] = $group.Count
    }

    $trustLevelCounts = [ordered]@{}
    foreach ($group in @($devices | Group-Object { $_.DriverResearchTrust.Level } | Sort-Object Name)) {
        $trustLevelCounts[$group.Name] = $group.Count
    }

    [ordered]@{
        SchemaVersion = 2
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        InventoryPath = $InventoryBundle.Path
        InventoryGeneratedAtUtc = $InventoryBundle.Inventory.GeneratedAtUtc
        Filter = $FilterText
        AllDevices = $AllDevicesValue
        SkipLiveIdEnrichment = $SkipLiveIdEnrichmentValue
        Counts = [ordered]@{
            Devices = $devices.Count
            NeedsDriverResearch = @($devices | Where-Object { $_.NeedsDriverResearch }).Count
            ExactInfDevices = @($devices | Where-Object { $_.Assessment.LocalInf.ExactMatches -gt 0 }).Count
            GenericInfOnlyDevices = @($devices | Where-Object { $_.Assessment.EvidenceLevel -eq 'LocalInfExactGeneric' }).Count
            EvidenceLevels = [pscustomobject]$evidenceLevelCounts
            ResearchTrustLevels = [pscustomobject]$trustLevelCounts
        }
        SourceReports = [ordered]@{
            DriverCandidatesGeneratedAtUtc = $CandidateReport.GeneratedAtUtc
            InstalledInfMatchesGeneratedAtUtc = $InfReport.GeneratedAtUtc
            InstalledInfLiveIdEnrichment = $InfReport.LiveIdEnrichment
        }
        Safety = [ordered]@{
            Mode = 'AuditOnly'
            InstallsDrivers = $false
            DownloadsDrivers = $false
            DeletesDrivers = $false
            CombinesLocalEvidenceAndSearchLinks = $true
            RequiresCandidatePackageMetadataBeforeTrust = $true
        }
        Devices = @($devices)
    }
}

function ConvertTo-MarkdownDriverEvidenceBundle {
    param(
        [object]$Bundle
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Driver Evidence Bundle')
    $lines.Add('')
    $lines.Add(('- Generated UTC: {0}' -f $Bundle.GeneratedAtUtc))
    $lines.Add(('- Inventory: `{0}`' -f $Bundle.InventoryPath))
    $lines.Add(('- Devices: {0}' -f $Bundle.Counts.Devices))
    $lines.Add(('- Needs driver research: {0}' -f $Bundle.Counts.NeedsDriverResearch))
    $lines.Add(('- Devices with exact local INF matches: {0}' -f $Bundle.Counts.ExactInfDevices))
    $lines.Add(('- Safety: audit-only, no download/install/remove actions'))
    $lines.Add('')

    foreach ($device in @($Bundle.Devices)) {
        $title = if ([string]::IsNullOrWhiteSpace([string]$device.FriendlyName)) { $device.InstanceId } else { $device.FriendlyName }
        $lines.Add(("## {0}" -f $title))
        $lines.Add('')
        $lines.Add(('- Recommendation: **{0}**' -f $device.Assessment.RecommendedAction))
        $lines.Add(('- Evidence level: `{0}`' -f $device.Assessment.EvidenceLevel))
        $lines.Add(('- Research trust: `{0}` / score `{1}` / readiness `{2}`' -f $device.DriverResearchTrust.Level, $device.DriverResearchTrust.Score, $device.DriverResearchTrust.CandidateReadiness))
        $lines.Add(('- Next gate: {0}' -f $device.DriverResearchTrust.NextGate))
        $lines.Add(('- Status: `{0}`  Problem: `{1}`  Class: `{2}`' -f $device.Status, $device.Problem, $device.Class))
        $lines.Add(('- Device kind: `{0}`  Attention: `{1}`  Driver research: `{2}`' -f $device.DeviceKind, $device.AttentionCategory, $device.DriverResearchPriority))
        $lines.Add(('- InstanceId: `{0}`' -f $device.InstanceId))
        $lines.Add(('- Installed driver: INF `{0}`, provider `{1}`, version `{2}`, date `{3}`' -f $device.InstalledDriver.InfName, $device.InstalledDriver.Provider, $device.InstalledDriver.Version, $device.InstalledDriver.Date))
        $lines.Add('')

        if (@($device.Assessment.Notes).Count -gt 0) {
            $lines.Add('### Notes')
            foreach ($note in @($device.Assessment.Notes)) {
                $lines.Add(('- {0}' -f $note))
            }
            $lines.Add('')
        }

        if (@($device.DriverResearchTrust.Blockers).Count -gt 0 -or @($device.DriverResearchTrust.Factors).Count -gt 0) {
            $lines.Add('### Research Trust Gate')
            $lines.Add(('- Allows download: `{0}`  Automatic install: `{1}`  Driver removal: `{2}`' -f $device.DriverResearchTrust.AllowsDownload, $device.DriverResearchTrust.AllowsAutomaticInstall, $device.DriverResearchTrust.AllowsDriverRemoval))
            foreach ($blocker in @($device.DriverResearchTrust.Blockers)) {
                $lines.Add(('- Blocker: {0}' -f $blocker))
            }
            foreach ($factor in @($device.DriverResearchTrust.Factors)) {
                $lines.Add(('- Factor: {0}' -f $factor))
            }
            $lines.Add('')
        }

        $lines.Add('### Hardware Identity')
        $bestResolutionName = [string](Get-ObjectPropertyValue -InputObject $device.Inventory -PropertyName 'BestResolutionName' -DefaultValue '')
        $bestResolution = Get-ObjectPropertyValue -InputObject $device.Inventory -PropertyName 'BestResolution' -DefaultValue $null
        if ($null -ne $bestResolution) {
            $lines.Add(('- Best local DB match: `{0}` / `{1}` / `{2}`' -f $bestResolution.Bus, $bestResolution.Confidence, $bestResolutionName))
        }
        foreach ($searchId in @($device.CandidateSearch.SearchIds | Select-Object -First 8)) {
            $lines.Add(('- `{0}`' -f $searchId.HardwareId))
        }
        $lines.Add('')

        $lines.Add('### Local INF Evidence')
        $matchSummary = $device.LocalInfEvidence.MatchSummary
        if ($null -ne $matchSummary) {
            $lines.Add(('- Installed INF file: `{0}`  Exact Hardware ID matches: `{1}`  Total matches: `{2}`' -f $matchSummary.HasInstalledInfFile, $matchSummary.ExactHardwareIdMatches, $matchSummary.TotalMatches))
        }
        foreach ($match in @($device.LocalInfEvidence.Matches | Select-Object -First 10)) {
            $matchLabel = if ([string]::IsNullOrWhiteSpace([string]$match.HardwareId)) { $match.MatchType } else { ('{0}: {1}' -f $match.MatchType, $match.HardwareId) }
            $lines.Add(('- `{0}` - {1}' -f $match.FileName, $matchLabel))
            if (-not [string]::IsNullOrWhiteSpace([string]$match.Line)) {
                $lines.Add(('  - Line: `{0}`' -f $match.Line))
            }
        }
        $lines.Add('')

        $lines.Add('### Search Links')
        foreach ($searchId in @($device.CandidateSearch.SearchIds | Select-Object -First 5)) {
            $lines.Add(('- `{0}`' -f $searchId.HardwareId))
            foreach ($link in @($searchId.Links | Select-Object -First 4)) {
                $lines.Add(('  - [{0}]({1}) - {2}' -f $link.Label, $link.Url, $link.Purpose))
            }
        }
        $lines.Add('')
    }

    return ($lines -join [Environment]::NewLine)
}

function Write-DriverEvidenceBundleSummary {
    param(
        [object]$Bundle
    )

    Write-Host 'Driver Evidence Bundle' -ForegroundColor Cyan
    Write-Host '----------------------' -ForegroundColor Cyan
    Write-Host ("Inventory       : {0}" -f $Bundle.InventoryPath) -ForegroundColor DarkGray
    Write-Host ("Devices         : {0}" -f $Bundle.Counts.Devices) -ForegroundColor Cyan
    Write-Host ("Driver research : {0}" -f $Bundle.Counts.NeedsDriverResearch) -ForegroundColor Cyan
    Write-Host ("Exact INF       : {0}" -f $Bundle.Counts.ExactInfDevices) -ForegroundColor Cyan
    Write-Host ("Live ID enrich  : {0}" -f $Bundle.SourceReports.InstalledInfLiveIdEnrichment.Enabled) -ForegroundColor Cyan
    Write-Host ("Trust levels    : {0}" -f (($Bundle.Counts.ResearchTrustLevels.PSObject.Properties | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join ', ')) -ForegroundColor Cyan
    Write-Host 'Safety          : audit-only; no downloads, installs, or removals' -ForegroundColor Green
    Write-Host ''

    foreach ($device in @($Bundle.Devices | Select-Object -First 12)) {
        Write-Host ("- {0}" -f $device.FriendlyName) -ForegroundColor Yellow
        Write-Host ("  {0} / {1} / trust {2} ({3}) / {4}" -f $device.Assessment.EvidenceLevel, $device.DriverResearchPriority, $device.DriverResearchTrust.Level, $device.DriverResearchTrust.Score, $device.Assessment.RecommendedAction) -ForegroundColor DarkGray
    }
}

function Save-DriverEvidenceBundle {
    param(
        [object]$Bundle,
        [string]$RootPath
    )

    New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $RootPath "driver-evidence-$timestamp.json"
    $markdownPath = Join-Path $RootPath "driver-evidence-$timestamp.md"

    $Bundle | ConvertTo-Json -Depth 48 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    ConvertTo-MarkdownDriverEvidenceBundle -Bundle $Bundle | Set-Content -LiteralPath $markdownPath -Encoding UTF8

    [pscustomobject]@{
        JsonPath = $jsonPath
        MarkdownPath = $markdownPath
    }
}

$inventoryBundle = Get-InventoryBundle -Path $InventoryPath -RootPath $InventoryRoot

$commonArguments = @('-InventoryPath', $inventoryBundle.Path, '-NoReport', '-AsJson')
if ($AllDevices) {
    $commonArguments += '-AllDevices'
}
if (-not [string]::IsNullOrWhiteSpace($Filter)) {
    $commonArguments += @('-Filter', $Filter)
}

$candidateReport = Invoke-JsonReportTool -ScriptName 'Find-DriverCandidates.ps1' -ToolArguments $commonArguments

$infArguments = @($commonArguments)
if ($SkipLiveIdEnrichment) {
    $infArguments += '-SkipLiveIdEnrichment'
}
$infReport = Invoke-JsonReportTool -ScriptName 'Find-InstalledInfMatches.ps1' -ToolArguments $infArguments

$bundle = New-DriverEvidenceBundle -InventoryBundle $inventoryBundle -CandidateReport $candidateReport -InfReport $infReport -FilterText $Filter -AllDevicesValue ([bool]$AllDevices) -SkipLiveIdEnrichmentValue ([bool]$SkipLiveIdEnrichment)

if ($AsJson) {
    $bundle | ConvertTo-Json -Depth 48
    return
}

Write-DriverEvidenceBundleSummary -Bundle $bundle

if (-not $NoReport) {
    $savedBundle = Save-DriverEvidenceBundle -Bundle $bundle -RootPath $OutputRoot
    Write-Host ''
    Write-Host 'Reports' -ForegroundColor Green
    Write-Host ("JSON     : {0}" -f $savedBundle.JsonPath) -ForegroundColor DarkGray
    Write-Host ("Markdown : {0}" -f $savedBundle.MarkdownPath) -ForegroundColor DarkGray
}
