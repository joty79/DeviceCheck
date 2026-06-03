[CmdletBinding()]
param(
    [string]$EvidencePath = '',

    [string]$EvidenceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'driver-evidence'),

    [string]$AdapterConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\driver-package-source-adapters.json'),

    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'driver-package-metadata'),

    [string]$Filter = '',

    [string[]]$Adapter = @(),

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
        throw "No driver evidence JSON found. Run internal\New-DriverEvidenceBundle.ps1 first."
    }

    [pscustomobject]@{
        Path = (Resolve-Path -LiteralPath $resolvedPath).ProviderPath
        Bundle = (Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json)
    }
}

function Get-AdapterConfig {
    param(
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue) -or -not (Test-Path -LiteralPath $PathValue -PathType Leaf)) {
        throw "Adapter config JSON not found: $PathValue"
    }

    [pscustomobject]@{
        Path = (Resolve-Path -LiteralPath $PathValue).ProviderPath
        Config = (Get-Content -LiteralPath $PathValue -Raw | ConvertFrom-Json)
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
    $trust = Get-ObjectPropertyValue -InputObject $Device -PropertyName 'DriverResearchTrust' -DefaultValue $null
    foreach ($value in @(
            (Get-ObjectPropertyValue -InputObject $Device -PropertyName 'FriendlyName' -DefaultValue ''),
            (Get-ObjectPropertyValue -InputObject $Device -PropertyName 'InstanceId' -DefaultValue ''),
            (Get-ObjectPropertyValue -InputObject $Device -PropertyName 'Class' -DefaultValue ''),
            (Get-ObjectPropertyValue -InputObject $trust -PropertyName 'BestSearchId' -DefaultValue '')
        )) {
        if ([string]$value -match "(?i)$needle") {
            return $true
        }
    }

    return $false
}

function Get-BestSearchId {
    param(
        [object]$Device
    )

    $trust = Get-ObjectPropertyValue -InputObject $Device -PropertyName 'DriverResearchTrust' -DefaultValue $null
    $bestSearchId = [string](Get-ObjectPropertyValue -InputObject $trust -PropertyName 'BestSearchId' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($bestSearchId)) {
        return $bestSearchId
    }

    $candidateSearch = Get-ObjectPropertyValue -InputObject $Device -PropertyName 'CandidateSearch' -DefaultValue $null
    foreach ($searchId in @(Get-ObjectArrayPropertyValue -InputObject $candidateSearch -PropertyName 'SearchIds')) {
        $hardwareId = [string](Get-ObjectPropertyValue -InputObject $searchId -PropertyName 'HardwareId' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($hardwareId)) {
            return $hardwareId
        }
    }

    return [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'InstanceId' -DefaultValue '')
}

function New-CollectionTask {
    param(
        [object]$Device,
        [object]$AdapterDefinition
    )

    $bestSearchId = Get-BestSearchId -Device $Device
    $installedDriver = Get-ObjectPropertyValue -InputObject $Device -PropertyName 'InstalledDriver' -DefaultValue $null
    $trust = Get-ObjectPropertyValue -InputObject $Device -PropertyName 'DriverResearchTrust' -DefaultValue $null
    $adapterId = [string](Get-ObjectPropertyValue -InputObject $AdapterDefinition -PropertyName 'Id' -DefaultValue '')
    $sourceType = [string](Get-ObjectPropertyValue -InputObject $AdapterDefinition -PropertyName 'SourceType' -DefaultValue '')

    [pscustomobject]@{
        AdapterId = $adapterId
        AdapterName = [string](Get-ObjectPropertyValue -InputObject $AdapterDefinition -PropertyName 'DisplayName' -DefaultValue $adapterId)
        SourceType = $sourceType
        Status = [string](Get-ObjectPropertyValue -InputObject $AdapterDefinition -PropertyName 'Status' -DefaultValue 'SkeletonOnly')
        Priority = [int](Get-ObjectPropertyValue -InputObject $AdapterDefinition -PropertyName 'Priority' -DefaultValue 999)
        Device = [pscustomobject]@{
            FriendlyName = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'FriendlyName' -DefaultValue '')
            InstanceId = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'InstanceId' -DefaultValue '')
            Class = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'Class' -DefaultValue '')
            DriverResearchTrustLevel = [string](Get-ObjectPropertyValue -InputObject $trust -PropertyName 'Level' -DefaultValue '')
            DriverResearchTrustScore = [int](Get-ObjectPropertyValue -InputObject $trust -PropertyName 'Score' -DefaultValue 0)
            BestSearchId = $bestSearchId
            CurrentDriver = [pscustomobject]@{
                InfName = [string](Get-ObjectPropertyValue -InputObject $installedDriver -PropertyName 'InfName' -DefaultValue '')
                Provider = [string](Get-ObjectPropertyValue -InputObject $installedDriver -PropertyName 'Provider' -DefaultValue '')
                Version = [string](Get-ObjectPropertyValue -InputObject $installedDriver -PropertyName 'Version' -DefaultValue '')
                Date = [string](Get-ObjectPropertyValue -InputObject $installedDriver -PropertyName 'Date' -DefaultValue '')
            }
        }
        Query = [pscustomobject]@{
            PrimaryHardwareId = $bestSearchId
            InputFields = @(Get-ObjectArrayPropertyValue -InputObject $AdapterDefinition -PropertyName 'QueryInputFields')
            SuggestedTemplateCommand = 'pwsh -ExecutionPolicy Bypass -File .\internal\Test-DriverCandidatePackageMetadata.ps1 -CreateTemplate -Filter "{0}"' -f $bestSearchId.Replace('"', '\"')
        }
        RequiredMetadataFields = @(Get-ObjectArrayPropertyValue -InputObject $AdapterDefinition -PropertyName 'RequiredMetadataFields')
        ManualCollectionSteps = @(Get-ObjectArrayPropertyValue -InputObject $AdapterDefinition -PropertyName 'ManualCollectionSteps')
        NextImplementationGate = [string](Get-ObjectPropertyValue -InputObject $AdapterDefinition -PropertyName 'NextImplementationGate' -DefaultValue '')
        Safety = [pscustomobject]@{
            Mode = 'AdapterSkeletonOnly'
            AllowsNetwork = $false
            AllowsDownload = $false
            AllowsAutomaticInstall = $false
            AllowsDriverRemoval = $false
        }
    }
}

function New-CollectionPlan {
    param(
        [object]$EvidenceInfo,
        [object]$AdapterInfo,
        [AllowEmptyString()]
        [string]$FilterText,
        [string[]]$AdapterIds
    )

    $adapterSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($adapterId in @($AdapterIds)) {
        if (-not [string]::IsNullOrWhiteSpace($adapterId)) {
            [void]$adapterSet.Add($adapterId)
        }
    }

    $selectedAdapters = @($AdapterInfo.Config.Adapters | Where-Object {
            $id = [string](Get-ObjectPropertyValue -InputObject $_ -PropertyName 'Id' -DefaultValue '')
            $adapterSet.Count -eq 0 -or $adapterSet.Contains($id)
        } | Sort-Object Priority, Id)

    if ($selectedAdapters.Count -eq 0) {
        throw 'No source adapters matched the requested -Adapter filter.'
    }

    $selectedDevices = @($EvidenceInfo.Bundle.Devices | Where-Object { Test-DeviceMatchesFilter -Device $_ -FilterText $FilterText })
    $tasks = [System.Collections.Generic.List[object]]::new()
    foreach ($device in @($selectedDevices)) {
        foreach ($adapterDefinition in @($selectedAdapters)) {
            $tasks.Add((New-CollectionTask -Device $device -AdapterDefinition $adapterDefinition))
        }
    }

    $taskStatusCounts = [ordered]@{}
    foreach ($group in @($tasks | Group-Object Status | Sort-Object Name)) {
        $taskStatusCounts[$group.Name] = $group.Count
    }

    [ordered]@{
        SchemaVersion = 1
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        EvidencePath = $EvidenceInfo.Path
        AdapterConfigPath = $AdapterInfo.Path
        Filter = $FilterText
        RequestedAdapters = @($AdapterIds)
        Counts = [ordered]@{
            Devices = $selectedDevices.Count
            Adapters = $selectedAdapters.Count
            Tasks = $tasks.Count
            Statuses = [pscustomobject]$taskStatusCounts
        }
        Safety = [ordered]@{
            Mode = 'MetadataAdapterSkeletonsOnly'
            AllowsNetwork = $false
            AllowsDownload = $false
            AllowsAutomaticInstall = $false
            AllowsDriverRemoval = $false
        }
        Tasks = @($tasks)
    }
}

function ConvertTo-MarkdownCollectionPlan {
    param(
        [object]$Plan
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Driver Package Metadata Collection Plan')
    $lines.Add('')
    $lines.Add(('- Generated UTC: {0}' -f $Plan.GeneratedAtUtc))
    $lines.Add(('- Evidence: `{0}`' -f $Plan.EvidencePath))
    $lines.Add(('- Adapter config: `{0}`' -f $Plan.AdapterConfigPath))
    $lines.Add(('- Devices: {0}' -f $Plan.Counts.Devices))
    $lines.Add(('- Tasks: {0}' -f $Plan.Counts.Tasks))
    $lines.Add('- Safety: adapter skeletons only, no network/download/install/remove actions')
    $lines.Add('')

    foreach ($task in @($Plan.Tasks)) {
        $deviceName = [string](Get-ObjectPropertyValue -InputObject $task.Device -PropertyName 'FriendlyName' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($deviceName)) {
            $deviceName = [string](Get-ObjectPropertyValue -InputObject $task.Device -PropertyName 'InstanceId' -DefaultValue '')
        }

        $lines.Add(("## {0} - {1}" -f $deviceName, $task.AdapterName))
        $lines.Add('')
        $lines.Add(('- Status: `{0}`  Priority: `{1}`  Source type: `{2}`' -f $task.Status, $task.Priority, $task.SourceType))
        $lines.Add(('- Best search ID: `{0}`' -f $task.Device.BestSearchId))
        $lines.Add(('- Suggested template command: `{0}`' -f $task.Query.SuggestedTemplateCommand))
        $lines.Add(('- Next implementation gate: {0}' -f $task.NextImplementationGate))
        $lines.Add('')
        $lines.Add('### Required Metadata Fields')
        foreach ($field in @($task.RequiredMetadataFields)) {
            $lines.Add(('- `{0}`' -f $field))
        }
        $lines.Add('')
        $lines.Add('### Manual Collection Steps')
        foreach ($step in @($task.ManualCollectionSteps)) {
            $lines.Add(('- {0}' -f $step))
        }
        $lines.Add('')
    }

    return ($lines -join [Environment]::NewLine)
}

function Write-CollectionPlanSummary {
    param(
        [object]$Plan
    )

    Write-Host 'Driver Package Metadata Collection Plan' -ForegroundColor Cyan
    Write-Host '---------------------------------------' -ForegroundColor Cyan
    Write-Host ("Evidence : {0}" -f $Plan.EvidencePath) -ForegroundColor DarkGray
    Write-Host ("Devices  : {0}" -f $Plan.Counts.Devices) -ForegroundColor Cyan
    Write-Host ("Adapters : {0}" -f $Plan.Counts.Adapters) -ForegroundColor Cyan
    Write-Host ("Tasks    : {0}" -f $Plan.Counts.Tasks) -ForegroundColor Cyan
    Write-Host 'Safety   : adapter skeletons only; no network, downloads, installs, or removals' -ForegroundColor Green
    Write-Host ''

    foreach ($task in @($Plan.Tasks | Select-Object -First 12)) {
        Write-Host ("- {0} / {1}" -f $task.Device.FriendlyName, $task.AdapterName) -ForegroundColor Yellow
        Write-Host ("  {0} / {1}" -f $task.Status, $task.Device.BestSearchId) -ForegroundColor DarkGray
    }
}

function Save-CollectionPlan {
    param(
        [object]$Plan,
        [string]$RootPath
    )

    New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $RootPath "driver-package-collection-plan-$timestamp.json"
    $markdownPath = Join-Path $RootPath "driver-package-collection-plan-$timestamp.md"

    $Plan | ConvertTo-Json -Depth 48 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    ConvertTo-MarkdownCollectionPlan -Plan $Plan | Set-Content -LiteralPath $markdownPath -Encoding UTF8

    [pscustomobject]@{
        JsonPath = $jsonPath
        MarkdownPath = $markdownPath
    }
}

$evidenceInfo = Get-DriverEvidenceBundle -PathValue $EvidencePath -RootPath $EvidenceRoot
$adapterInfo = Get-AdapterConfig -PathValue $AdapterConfigPath
$plan = New-CollectionPlan -EvidenceInfo $evidenceInfo -AdapterInfo $adapterInfo -FilterText $Filter -AdapterIds $Adapter

if ($AsJson) {
    $plan | ConvertTo-Json -Depth 48
    return
}

Write-CollectionPlanSummary -Plan $plan

if (-not $NoReport) {
    $savedPlan = Save-CollectionPlan -Plan $plan -RootPath $OutputRoot
    Write-Host ''
    Write-Host 'Reports' -ForegroundColor Green
    Write-Host ("JSON     : {0}" -f $savedPlan.JsonPath) -ForegroundColor DarkGray
    Write-Host ("Markdown : {0}" -f $savedPlan.MarkdownPath) -ForegroundColor DarkGray
}
