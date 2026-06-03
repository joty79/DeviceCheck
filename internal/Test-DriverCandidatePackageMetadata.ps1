[CmdletBinding()]
param(
    [string[]]$Path = @(),

    [switch]$CreateTemplate,

    [string]$EvidencePath = '',

    [string]$EvidenceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'driver-evidence'),

    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'driver-package-metadata'),

    [string]$Filter = '',

    [switch]$NoReport,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-ObjectArrayPropertyValue {
    param(
        [object]$InputObject,
        [string]$PropertyName
    )

    $value = Get-ObjectPropertyValue -InputObject $InputObject -PropertyName $PropertyName -DefaultValue $null
    if ($null -eq $value) {
        return @()
    }

    return @($value)
}

function Get-NestedPropertyValue {
    param(
        [object]$InputObject,
        [string[]]$PropertyPath,
        [object]$DefaultValue = $null
    )

    $currentObject = $InputObject
    foreach ($propertyName in @($PropertyPath)) {
        $currentObject = Get-ObjectPropertyValue -InputObject $currentObject -PropertyName $propertyName -DefaultValue $null
        if ($null -eq $currentObject) {
            return $DefaultValue
        }
    }

    return $currentObject
}

function Get-LatestEvidencePath {
    param(
        [string]$RootPath
    )

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return ''
    }

    $latest = Get-ChildItem -LiteralPath $RootPath -Filter 'driver-evidence-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $latest) {
        return ''
    }

    return $latest.FullName
}

function Get-DriverEvidenceBundle {
    param(
        [AllowEmptyString()]
        [string]$PathValue,
        [string]$RootPath
    )

    $resolvedPath = $PathValue
    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        $resolvedPath = Get-LatestEvidencePath -RootPath $RootPath
    }

    if ([string]::IsNullOrWhiteSpace($resolvedPath) -or -not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        return $null
    }

    [pscustomobject]@{
        Path = (Resolve-Path -LiteralPath $resolvedPath).ProviderPath
        Bundle = (Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json)
    }
}

function Test-DeviceMatchesFilter {
    param(
        [object]$Device,
        [AllowEmptyString()]
        [string]$FilterText
    )

    if ([string]::IsNullOrWhiteSpace($FilterText)) {
        return $true
    }

    $needle = [regex]::Escape($FilterText.Trim())
    foreach ($value in @(
            (Get-ObjectPropertyValue -InputObject $Device -PropertyName 'FriendlyName' -DefaultValue ''),
            (Get-ObjectPropertyValue -InputObject $Device -PropertyName 'InstanceId' -DefaultValue ''),
            (Get-ObjectPropertyValue -InputObject $Device -PropertyName 'Class' -DefaultValue ''),
            (Get-NestedPropertyValue -InputObject $Device -PropertyPath @('DriverResearchTrust', 'BestSearchId') -DefaultValue '')
        )) {
        if ([string]$value -match "(?i)$needle") {
            return $true
        }
    }

    return $false
}

function Get-FirstEvidenceDevice {
    param(
        [object]$Bundle,
        [AllowEmptyString()]
        [string]$FilterText
    )

    foreach ($device in @($Bundle.Devices)) {
        if (Test-DeviceMatchesFilter -Device $device -FilterText $FilterText) {
            return $device
        }
    }

    return $null
}

function New-DriverCandidatePackageMetadataTemplate {
    param(
        [object]$Device,
        [AllowEmptyString()]
        [string]$EvidenceBundlePath
    )

    $trust = Get-ObjectPropertyValue -InputObject $Device -PropertyName 'DriverResearchTrust' -DefaultValue $null
    $installedDriver = Get-ObjectPropertyValue -InputObject $Device -PropertyName 'InstalledDriver' -DefaultValue $null
    $candidateSearch = Get-ObjectPropertyValue -InputObject $Device -PropertyName 'CandidateSearch' -DefaultValue $null
    $bestSearchId = [string](Get-ObjectPropertyValue -InputObject $trust -PropertyName 'BestSearchId' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($bestSearchId)) {
        foreach ($searchId in @(Get-ObjectArrayPropertyValue -InputObject $candidateSearch -PropertyName 'SearchIds')) {
            $bestSearchId = [string](Get-ObjectPropertyValue -InputObject $searchId -PropertyName 'HardwareId' -DefaultValue '')
            if (-not [string]::IsNullOrWhiteSpace($bestSearchId)) {
                break
            }
        }
    }

    [ordered]@{
        SchemaVersion = 1
        MetadataKind = 'DriverCandidatePackage'
        CreatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        EvidenceBundlePath = $EvidenceBundlePath
        DeviceContext = [ordered]@{
            FriendlyName = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'FriendlyName' -DefaultValue '')
            InstanceId = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'InstanceId' -DefaultValue '')
            Class = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'Class' -DefaultValue '')
            BestSearchId = $bestSearchId
            CurrentDriver = [ordered]@{
                InfName = [string](Get-ObjectPropertyValue -InputObject $installedDriver -PropertyName 'InfName' -DefaultValue '')
                Provider = [string](Get-ObjectPropertyValue -InputObject $installedDriver -PropertyName 'Provider' -DefaultValue '')
                Version = [string](Get-ObjectPropertyValue -InputObject $installedDriver -PropertyName 'Version' -DefaultValue '')
                Date = [string](Get-ObjectPropertyValue -InputObject $installedDriver -PropertyName 'Date' -DefaultValue '')
            }
        }
        Source = [ordered]@{
            Type = ''
            Name = ''
            Url = ''
            ResultId = ''
            PublishedDateUtc = ''
            TrustTier = ''
            CollectedBy = ''
            CollectionMethod = ''
        }
        Package = [ordered]@{
            Provider = ''
            Manufacturer = ''
            Class = ''
            Version = ''
            ReleaseDate = ''
            Architecture = ''
            OsTargets = @()
            DownloadUrl = ''
            FileName = ''
            SizeBytes = $null
            Sha256 = ''
            CatalogFile = ''
            InfFiles = @()
        }
        Identity = [ordered]@{
            MatchedHardwareId = $bestSearchId
            MatchType = ''
            HardwareIds = @()
            CompatibleIds = @()
        }
        Verification = [ordered]@{
            Downloaded = $false
            HashVerified = $false
            SignatureVerified = $false
            SignatureStatus = ''
            CatalogVerified = $false
            InfParsed = $false
            OsTargetVerified = $false
            VersionCompared = $false
            SourceTrustVerified = $false
            RollbackPlanVerified = $false
        }
        Recommendation = [ordered]@{
            Type = ''
            IsCandidateNewer = $false
            VersionComparison = ''
            TrustLevel = ''
            TrustScore = 0
            TrustFactors = @()
            CandidateFlags = [ordered]@{
                IsBeta = $false
                IsSignedClaimed = $false
                DirectHardwareIdMatch = $false
                OemProviderMatch = $false
            }
        }
        Safety = [ordered]@{
            MetadataOnly = $true
            AllowsDownload = $false
            AllowsAutomaticInstall = $false
            AllowsDriverRemoval = $false
        }
        Notes = @()
    }
}

function Test-TruthyValue {
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    return [string]$Value -match '^(?i:true|yes|verified|valid|ok)$'
}

function Test-DriverCandidatePackageMetadataObject {
    param(
        [object]$Metadata,
        [AllowEmptyString()]
        [string]$SourcePath
    )

    $factors = [System.Collections.Generic.List[string]]::new()
    $blockers = [System.Collections.Generic.List[string]]::new()
    $score = 0

    $schemaVersion = [string](Get-ObjectPropertyValue -InputObject $Metadata -PropertyName 'SchemaVersion' -DefaultValue '')
    if ($schemaVersion -eq '1') {
        $score += 5
        $factors.Add('SchemaVersion 1 metadata contract is present.')
    }
    else {
        $blockers.Add('SchemaVersion 1 is required.')
    }

    $sourceName = [string](Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Source', 'Name') -DefaultValue '')
    $sourceUrl = [string](Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Source', 'Url') -DefaultValue '')
    $sourceType = [string](Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Source', 'Type') -DefaultValue '')
    $sourceTrustVerified = Test-TruthyValue -Value (Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Verification', 'SourceTrustVerified') -DefaultValue $false)

    if (-not [string]::IsNullOrWhiteSpace($sourceName) -and -not [string]::IsNullOrWhiteSpace($sourceUrl)) {
        $score += 12
        $factors.Add("Source identity is present: $sourceName")
    }
    else {
        $blockers.Add('Source name and URL are required.')
    }

    if ($sourceType -match '^(?i:MicrosoftUpdateCatalog|OEM|WindowsUpdate|VendorSupport)$') {
        $score += 8
        $factors.Add("Source type is recognized: $sourceType")
    }
    elseif (-not [string]::IsNullOrWhiteSpace($sourceType)) {
        $blockers.Add("Source type is not in the recognized trusted-source set: $sourceType")
    }
    else {
        $blockers.Add('Source type is required.')
    }

    if ($sourceTrustVerified) {
        $score += 10
        $factors.Add('Source trust has been explicitly verified.')
    }
    else {
        $blockers.Add('Source trust is not verified.')
    }

    $provider = [string](Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Package', 'Provider') -DefaultValue '')
    $version = [string](Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Package', 'Version') -DefaultValue '')
    $releaseDate = [string](Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Package', 'ReleaseDate') -DefaultValue '')
    $architecture = [string](Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Package', 'Architecture') -DefaultValue '')
    $sha256 = [string](Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Package', 'Sha256') -DefaultValue '')
    $catalogFile = [string](Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Package', 'CatalogFile') -DefaultValue '')
    $infFiles = @(Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Package', 'InfFiles') -DefaultValue @())
    $osTargets = @(Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Package', 'OsTargets') -DefaultValue @())

    if (-not [string]::IsNullOrWhiteSpace($provider) -and -not [string]::IsNullOrWhiteSpace($version) -and -not [string]::IsNullOrWhiteSpace($releaseDate)) {
        $score += 12
        $factors.Add("Package provider/version/date are present: $provider $version $releaseDate")
    }
    else {
        $blockers.Add('Package provider, version, and release date are required.')
    }

    if (-not [string]::IsNullOrWhiteSpace($architecture)) {
        $score += 4
        $factors.Add("Package architecture is present: $architecture")
    }
    else {
        $blockers.Add('Package architecture is required.')
    }

    if ($infFiles.Count -gt 0) {
        $score += 8
        $factors.Add(("INF files are listed: {0}" -f ($infFiles -join ', ')))
    }
    else {
        $blockers.Add('At least one candidate INF file must be listed.')
    }

    if ($osTargets.Count -gt 0) {
        $score += 5
        $factors.Add(("OS targets are listed: {0}" -f ($osTargets -join ', ')))
    }
    else {
        $blockers.Add('OS targets are required.')
    }

    if ($sha256 -match '^(?i)[0-9a-f]{64}$') {
        $score += 8
        $factors.Add('SHA256 hash is present.')
    }
    else {
        $blockers.Add('A 64-character SHA256 hash is required.')
    }

    if (-not [string]::IsNullOrWhiteSpace($catalogFile)) {
        $score += 4
        $factors.Add("Catalog file is listed: $catalogFile")
    }
    else {
        $blockers.Add('Catalog file is required.')
    }

    $matchedHardwareId = [string](Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Identity', 'MatchedHardwareId') -DefaultValue '')
    $matchType = [string](Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Identity', 'MatchType') -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($matchedHardwareId) -and $matchType -eq 'ExactHardwareId') {
        $score += 18
        $factors.Add("Exact Hardware ID match is declared: $matchedHardwareId")
    }
    elseif (-not [string]::IsNullOrWhiteSpace($matchedHardwareId) -and $matchType -eq 'CompatibleId') {
        $score += 8
        $blockers.Add("Only a CompatibleId match is declared: $matchedHardwareId")
    }
    else {
        $blockers.Add('An ExactHardwareId match is required before package trust can advance.')
    }

    $hashVerified = Test-TruthyValue -Value (Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Verification', 'HashVerified') -DefaultValue $false)
    $signatureVerified = Test-TruthyValue -Value (Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Verification', 'SignatureVerified') -DefaultValue $false)
    $catalogVerified = Test-TruthyValue -Value (Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Verification', 'CatalogVerified') -DefaultValue $false)
    $infParsed = Test-TruthyValue -Value (Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Verification', 'InfParsed') -DefaultValue $false)
    $osTargetVerified = Test-TruthyValue -Value (Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Verification', 'OsTargetVerified') -DefaultValue $false)
    $versionCompared = Test-TruthyValue -Value (Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Verification', 'VersionCompared') -DefaultValue $false)
    $rollbackPlanVerified = Test-TruthyValue -Value (Get-NestedPropertyValue -InputObject $Metadata -PropertyPath @('Verification', 'RollbackPlanVerified') -DefaultValue $false)

    foreach ($verificationItem in @(
            [pscustomobject]@{ Name = 'Hash verification'; Verified = $hashVerified; Points = 7 },
            [pscustomobject]@{ Name = 'Signature verification'; Verified = $signatureVerified; Points = 12 },
            [pscustomobject]@{ Name = 'Catalog verification'; Verified = $catalogVerified; Points = 8 },
            [pscustomobject]@{ Name = 'INF parse verification'; Verified = $infParsed; Points = 5 },
            [pscustomobject]@{ Name = 'OS target verification'; Verified = $osTargetVerified; Points = 10 },
            [pscustomobject]@{ Name = 'Version comparison'; Verified = $versionCompared; Points = 5 },
            [pscustomobject]@{ Name = 'Rollback plan verification'; Verified = $rollbackPlanVerified; Points = 8 }
        )) {
        if ($verificationItem.Verified) {
            $score += [int]$verificationItem.Points
            $factors.Add($verificationItem.Name)
        }
        else {
            $blockers.Add(('{0} is required.' -f $verificationItem.Name))
        }
    }

    $score = [Math]::Min(100, [Math]::Max(0, $score))
    $level = 'IncompleteMetadata'
    $readiness = 'MetadataCaptureNeeded'

    if ($score -ge 75 -and $signatureVerified -and $catalogVerified -and $osTargetVerified -and $sourceTrustVerified -and $rollbackPlanVerified -and $matchType -eq 'ExactHardwareId') {
        $level = 'ManualPackageReviewReady'
        $readiness = 'ReadyForHumanPackageReview'
    }
    elseif ($score -ge 45) {
        $level = 'PackageReviewBlocked'
        $readiness = 'VerificationStillRequired'
    }

    [pscustomobject]@{
        SourcePath = $SourcePath
        Level = $level
        Score = $score
        Readiness = $readiness
        NextGate = 'Human review of verified package metadata; install automation remains disabled until a separate install/rollback workflow is designed.'
        AllowsDownload = $false
        AllowsAutomaticInstall = $false
        AllowsDriverRemoval = $false
        Factors = @($factors)
        Blockers = @($blockers)
        Metadata = $Metadata
    }
}

function ConvertTo-MarkdownPackageMetadataReport {
    param(
        [object]$Report
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Driver Candidate Package Metadata Gate')
    $lines.Add('')
    $lines.Add(('- Generated UTC: {0}' -f $Report.GeneratedAtUtc))
    $lines.Add(('- Packages: {0}' -f $Report.Counts.Packages))
    $lines.Add(('- Manual review ready: {0}' -f $Report.Counts.ManualPackageReviewReady))
    $lines.Add(('- Safety: metadata-only, no download/install/remove actions'))
    $lines.Add('')

    foreach ($package in @($Report.Packages)) {
        $sourcePath = [string](Get-ObjectPropertyValue -InputObject $package -PropertyName 'SourcePath' -DefaultValue '')
        $metadata = Get-ObjectPropertyValue -InputObject $package -PropertyName 'Metadata' -DefaultValue $null
        $friendlyName = [string](Get-NestedPropertyValue -InputObject $metadata -PropertyPath @('DeviceContext', 'FriendlyName') -DefaultValue '')
        $title = if ([string]::IsNullOrWhiteSpace($friendlyName)) { $sourcePath } else { $friendlyName }
        $lines.Add(("## {0}" -f $title))
        $lines.Add('')
        $lines.Add(('- Source file: `{0}`' -f $sourcePath))
        $lines.Add(('- Level: `{0}`  Score: `{1}`  Readiness: `{2}`' -f $package.Level, $package.Score, $package.Readiness))
        $lines.Add(('- Next gate: {0}' -f $package.NextGate))
        $lines.Add(('- Allows download: `{0}`  Automatic install: `{1}`  Driver removal: `{2}`' -f $package.AllowsDownload, $package.AllowsAutomaticInstall, $package.AllowsDriverRemoval))
        $lines.Add('')
        foreach ($blocker in @($package.Blockers)) {
            $lines.Add(('- Blocker: {0}' -f $blocker))
        }
        foreach ($factor in @($package.Factors)) {
            $lines.Add(('- Factor: {0}' -f $factor))
        }
        $lines.Add('')
    }

    return ($lines -join [Environment]::NewLine)
}

function Save-Template {
    param(
        [object]$Template,
        [string]$RootPath
    )

    New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $RootPath "driver-package-template-$timestamp.json"
    $Template | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    return $jsonPath
}

function Save-PackageMetadataReport {
    param(
        [object]$Report,
        [string]$RootPath
    )

    New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $RootPath "driver-package-metadata-$timestamp.json"
    $markdownPath = Join-Path $RootPath "driver-package-metadata-$timestamp.md"
    $Report | ConvertTo-Json -Depth 48 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    ConvertTo-MarkdownPackageMetadataReport -Report $Report | Set-Content -LiteralPath $markdownPath -Encoding UTF8
    [pscustomobject]@{
        JsonPath = $jsonPath
        MarkdownPath = $markdownPath
    }
}

function Write-PackageMetadataReportSummary {
    param(
        [object]$Report
    )

    Write-Host 'Driver Candidate Package Metadata Gate' -ForegroundColor Cyan
    Write-Host '--------------------------------------' -ForegroundColor Cyan
    Write-Host ("Packages            : {0}" -f $Report.Counts.Packages) -ForegroundColor Cyan
    Write-Host ("Manual review ready : {0}" -f $Report.Counts.ManualPackageReviewReady) -ForegroundColor Cyan
    Write-Host 'Safety              : metadata-only; no downloads, installs, or removals' -ForegroundColor Green
    Write-Host ''

    foreach ($package in @($Report.Packages | Select-Object -First 12)) {
        $sourcePath = [string](Get-ObjectPropertyValue -InputObject $package -PropertyName 'SourcePath' -DefaultValue '')
        Write-Host ("- {0}" -f $sourcePath) -ForegroundColor Yellow
        Write-Host ("  {0} / score {1} / {2}" -f $package.Level, $package.Score, $package.Readiness) -ForegroundColor DarkGray
        foreach ($blocker in @($package.Blockers | Select-Object -First 4)) {
            Write-Host ("  Blocker: {0}" -f $blocker) -ForegroundColor DarkGray
        }
    }
}

if ($CreateTemplate) {
    $bundleInfo = Get-DriverEvidenceBundle -PathValue $EvidencePath -RootPath $EvidenceRoot
    $device = $null
    $resolvedEvidencePath = ''
    if ($null -ne $bundleInfo) {
        $device = Get-FirstEvidenceDevice -Bundle $bundleInfo.Bundle -FilterText $Filter
        $resolvedEvidencePath = $bundleInfo.Path
    }

    $template = New-DriverCandidatePackageMetadataTemplate -Device $device -EvidenceBundlePath $resolvedEvidencePath
    if ($AsJson) {
        $template | ConvertTo-Json -Depth 32
        return
    }

    Write-Host 'Driver Candidate Package Metadata Template' -ForegroundColor Cyan
    Write-Host '------------------------------------------' -ForegroundColor Cyan
    Write-Host 'Safety : metadata-only template; no downloads, installs, or removals' -ForegroundColor Green
    if (-not [string]::IsNullOrWhiteSpace($resolvedEvidencePath)) {
        Write-Host ("Evidence: {0}" -f $resolvedEvidencePath) -ForegroundColor DarkGray
    }

    if (-not $NoReport) {
        $templatePath = Save-Template -Template $template -RootPath $OutputRoot
        Write-Host ("Template: {0}" -f $templatePath) -ForegroundColor DarkGray
    }
    return
}

if ($Path.Count -eq 0) {
    throw 'Provide -Path to one or more driver candidate package metadata JSON files, or use -CreateTemplate.'
}

$packageResults = [System.Collections.Generic.List[object]]::new()
foreach ($metadataPath in @($Path)) {
    if ([string]::IsNullOrWhiteSpace($metadataPath) -or -not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Metadata JSON not found: $metadataPath"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $metadataPath).ProviderPath
    $metadata = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json
    $packageResults.Add((Test-DriverCandidatePackageMetadataObject -Metadata $metadata -SourcePath $resolvedPath))
}

$levelCounts = [ordered]@{}
foreach ($group in @($packageResults | Group-Object Level | Sort-Object Name)) {
    $levelCounts[$group.Name] = $group.Count
}

$report = [ordered]@{
    SchemaVersion = 1
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Counts = [ordered]@{
        Packages = $packageResults.Count
        ManualPackageReviewReady = @($packageResults | Where-Object { $_.Level -eq 'ManualPackageReviewReady' }).Count
        Levels = [pscustomobject]$levelCounts
    }
    Safety = [ordered]@{
        Mode = 'MetadataAuditOnly'
        DownloadsDrivers = $false
        InstallsDrivers = $false
        DeletesDrivers = $false
    }
    Packages = @($packageResults)
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 48
    return
}

Write-PackageMetadataReportSummary -Report $report

if (-not $NoReport) {
    $savedReport = Save-PackageMetadataReport -Report $report -RootPath $OutputRoot
    Write-Host ''
    Write-Host 'Reports' -ForegroundColor Green
    Write-Host ("JSON     : {0}" -f $savedReport.JsonPath) -ForegroundColor DarkGray
    Write-Host ("Markdown : {0}" -f $savedReport.MarkdownPath) -ForegroundColor DarkGray
}
