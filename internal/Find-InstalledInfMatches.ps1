[CmdletBinding()]
param(
    [string]$InventoryPath = '',

    [string]$InventoryRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'devices'),

    [string]$InfRoot = (Join-Path $env:windir 'INF'),

    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'inf-matches'),

    [string]$Filter = '',

    [switch]$AllDevices,

    [switch]$SkipLiveIdEnrichment,

    [switch]$SearchAllInstalledInf,

    [switch]$NoReport,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$infDriverParserModulePath = Join-Path $PSScriptRoot 'InfDriverParser.psm1'
if (-not (Test-Path -LiteralPath $infDriverParserModulePath -PathType Leaf)) {
    throw "Required module not found: $infDriverParserModulePath"
}
Import-Module $infDriverParserModulePath -Force

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

function Get-Inventory {
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

    $inventory = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json
    [pscustomobject]@{
        Path = (Resolve-Path -LiteralPath $resolvedPath).ProviderPath
        Inventory = $inventory
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

function Get-DeviceTextValue {
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [System.Array]) {
        return ((@($Value) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join '; ')
    }

    return [string]$Value
}

function Split-DeviceIdList {
    param(
        [object[]]$Values
    )

    $idSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($value in @($Values)) {
        if ($null -eq $value) {
            continue
        }

        if ($value -is [System.Array]) {
            foreach ($innerValue in @($value)) {
                $textValue = [string]$innerValue
                if (-not [string]::IsNullOrWhiteSpace($textValue)) {
                    [void]$idSet.Add($textValue.Trim())
                }
            }
            continue
        }

        foreach ($part in ([string]$value -split '\s*;\s*')) {
            if (-not [string]::IsNullOrWhiteSpace($part)) {
                [void]$idSet.Add($part.Trim())
            }
        }
    }

    return @($idSet | Sort-Object)
}

function Get-PnpPropertyValueSafe {
    param(
        [AllowEmptyString()]
        [string]$InstanceId,
        [AllowEmptyString()]
        [string]$KeyName
    )

    if ([string]::IsNullOrWhiteSpace($InstanceId) -or [string]::IsNullOrWhiteSpace($KeyName)) {
        return ''
    }

    try {
        $property = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction Stop
        if ($null -eq $property -or $null -eq $property.Data) {
            return ''
        }

        return (Get-DeviceTextValue -Value $property.Data)
    }
    catch {
        return ''
    }
}

function Get-LiveDeviceIdEvidence {
    param(
        [object]$Device
    )

    $instanceId = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'InstanceId' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($instanceId)) {
        return [pscustomobject]@{
            Queried = $false
            QuerySucceeded = $false
            InstanceId = ''
            HardwareIds = @()
            CompatibleIds = @()
            MatchingDeviceId = ''
            CandidateIds = @()
            Notes = @('No InstanceId available for targeted live ID enrichment.')
        }
    }

    $hardwareIds = @(Split-DeviceIdList -Values @((Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_HardwareIds')))
    $compatibleIds = @(Split-DeviceIdList -Values @((Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_CompatibleIds')))
    $matchingDeviceId = Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_MatchingDeviceId'
    $candidateIds = @(Split-DeviceIdList -Values @($hardwareIds, $compatibleIds, $matchingDeviceId))
    $querySucceeded = $candidateIds.Count -gt 0
    $notes = @()
    if (-not $querySucceeded) {
        $notes += 'No live HardwareIds/CompatibleIds were available from targeted Get-PnpDeviceProperty calls.'
    }

    [pscustomobject]@{
        Queried = $true
        QuerySucceeded = $querySucceeded
        InstanceId = $instanceId
        HardwareIds = @($hardwareIds)
        CompatibleIds = @($compatibleIds)
        MatchingDeviceId = $matchingDeviceId
        CandidateIds = @($candidateIds)
        Notes = @($notes)
    }
}

function ConvertTo-SearchableHardwareId {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $trimmed = $Value.Trim().Trim('"').Trim("'").Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return ''
    }

    $trimmed = $trimmed -replace '/', '\'
    if ($trimmed -match '^(?i)(PCI|USB|HID|ACPI|ROOT|SWD|BTH|BTHENUM)\\([^\\]+)\\.+') {
        return ('{0}\{1}' -f $Matches[1].ToUpperInvariant(), $Matches[2].ToUpperInvariant())
    }
    if ($trimmed -match '^(?i)(PCI|USB|HID|ACPI|ROOT|SWD|BTH|BTHENUM)\\(.+)$') {
        return ('{0}\{1}' -f $Matches[1].ToUpperInvariant(), $Matches[2].ToUpperInvariant())
    }
    if ($trimmed -match '^(?i)\*[A-Z0-9]{7,8}$') {
        return $trimmed.ToUpperInvariant()
    }

    return $trimmed.ToUpperInvariant()
}

function Add-UniqueText {
    param(
        [System.Collections.Generic.List[string]]$List,
        [System.Collections.Generic.HashSet[string]]$Set,
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    $trimmed = $Value.Trim()
    if (-not [string]::IsNullOrWhiteSpace($trimmed) -and $Set.Add($trimmed)) {
        $List.Add($trimmed)
    }
}

function Get-DeviceCandidateIds {
    param(
        [object]$Device,
        [object]$LiveIdEvidence = $null
    )

    $idSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($Device.CandidateHardwareIds, $Device.HardwareIds, $Device.CompatibleIds, $Device.MatchingDeviceId, $Device.InstanceId)) {
        foreach ($item in @($value)) {
            $candidateId = ConvertTo-SearchableHardwareId -Value ([string]$item)
            Add-UniqueText -List $ids -Set $idSet -Value $candidateId
        }
    }

    if ($null -ne $LiveIdEvidence) {
        foreach ($value in @($LiveIdEvidence.CandidateIds)) {
            foreach ($item in @($value)) {
                $candidateId = ConvertTo-SearchableHardwareId -Value ([string]$item)
                Add-UniqueText -List $ids -Set $idSet -Value $candidateId
            }
        }
    }

    return @($ids)
}

function Get-InfVersionMetadata {
    param(
        [string[]]$Lines
    )

    $metadata = [ordered]@{
        Provider = ''
        Class = ''
        ClassGuid = ''
        DriverVer = ''
        CatalogFile = ''
        Signature = ''
    }

    $inVersion = $false
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]') {
            $inVersion = $Matches[1] -eq 'Version'
            continue
        }

        if (-not $inVersion -or $trimmed -match '^\s*(;|$)') {
            continue
        }

        if ($trimmed -match '^(Provider|Class|ClassGuid|DriverVer|CatalogFile|Signature)\s*=\s*(.+)$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim().Trim('"')
            $metadata[$key] = $value
        }
    }

    return [pscustomobject]$metadata
}

function New-InfIndex {
    param(
        [string]$RootPath,
        [string[]]$IncludeFileNames = @()
    )

    if ([string]::IsNullOrWhiteSpace($RootPath) -or -not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        throw "INF root not found: $RootPath"
    }

    $byHardwareId = @{}
    $byFileName = @{}
    $allInfFiles = @(Get-ChildItem -LiteralPath $RootPath -Filter '*.inf' -File -ErrorAction Stop)
    $includeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($includeFileName in @($IncludeFileNames)) {
        if (-not [string]::IsNullOrWhiteSpace($includeFileName)) {
            [void]$includeSet.Add((Split-Path -Leaf $includeFileName))
        }
    }

    $infFiles = @(if ($includeSet.Count -gt 0) {
        $allInfFiles | Where-Object { $includeSet.Contains($_.Name) }
    }
    else {
        $allInfFiles
    })
    $parsedCount = 0
    $readErrorCount = 0
    $indexedIdCount = 0

    for ($index = 0; $index -lt $infFiles.Count; $index++) {
        $file = $infFiles[$index]
        try {
            $parsedInf = ConvertFrom-InfDriverFile -Path $file.FullName
        }
        catch {
            $readErrorCount++
            continue
        }

        $parsedCount++
        $metadata = $parsedInf.Metadata
        $hardwareIds = @($parsedInf.HardwareIds)
        $infRecord = [pscustomobject]@{
            FileName = $file.Name
            FullName = $file.FullName
            LastWriteTime = $file.LastWriteTime
            Length = $file.Length
            Provider = $metadata.Provider
            Class = $metadata.Class
            ClassGuid = $metadata.ClassGuid
            DriverVer = $metadata.DriverVer
            CatalogFile = $metadata.CatalogFile
            Signature = $metadata.Signature
            HardwareIds = @($hardwareIds)
            Parser = [pscustomobject]@{
                Mode = $parsedInf.ParseMode
                SectionCount = $parsedInf.SectionCount
                StringCount = $parsedInf.StringCount
                ModelSectionCount = @($parsedInf.ModelSectionNames).Count
                ModelHardwareIds = @($parsedInf.ModelHardwareIds).Count
                FallbackHardwareIds = @($parsedInf.FallbackHardwareIds).Count
            }
        }

        $byFileName[$file.Name.ToLowerInvariant()] = $infRecord
        foreach ($hardwareId in $hardwareIds) {
            $key = [string]$hardwareId.HardwareId
            if (-not $byHardwareId.ContainsKey($key)) {
                $byHardwareId[$key] = [System.Collections.Generic.List[object]]::new()
            }
            $byHardwareId[$key].Add([pscustomobject]@{
                FileName = $infRecord.FileName
                FullName = $infRecord.FullName
                Provider = $infRecord.Provider
                Class = $infRecord.Class
                ClassGuid = $infRecord.ClassGuid
                DriverVer = $infRecord.DriverVer
                CatalogFile = $infRecord.CatalogFile
                HardwareId = $hardwareId.HardwareId
                Label = $hardwareId.Label
                ResolvedLabel = $hardwareId.ResolvedLabel
                Line = $hardwareId.Line
                LineNumber = $hardwareId.LineNumber
                ModelSection = $hardwareId.ModelSection
                InstallSection = $hardwareId.InstallSection
                Source = $hardwareId.Source
                MatchType = 'ExactHardwareId'
            })
            $indexedIdCount++
        }

        if ((($index + 1) % 100) -eq 0 -or ($index + 1) -eq $infFiles.Count) {
            $percentComplete = [math]::Round((($index + 1) / [Math]::Max(1, $infFiles.Count)) * 100, 0)
            Write-Progress -Id 1 -Activity 'Index installed INF files' -Status ("{0}/{1} files" -f ($index + 1), $infFiles.Count) -PercentComplete $percentComplete
        }
    }

    Write-Progress -Id 1 -Activity 'Index installed INF files' -Completed

    [pscustomobject]@{
        RootPath = (Resolve-Path -LiteralPath $RootPath).ProviderPath
        ByHardwareId = $byHardwareId
        ByFileName = $byFileName
        Counts = [pscustomobject]@{
            InfFiles = $infFiles.Count
            AvailableInfFiles = $allInfFiles.Count
            ParsedInfFiles = $parsedCount
            ReadErrors = $readErrorCount
            IndexedHardwareIds = $indexedIdCount
            UniqueHardwareIds = $byHardwareId.Count
        }
    }
}

function Select-InventoryDevicesForInfMatching {
    param(
        [object]$Inventory,
        [switch]$AllDevices,
        [AllowEmptyString()]
        [string]$FilterText
    )

    $devices = @($Inventory.Devices)
    if (-not $AllDevices) {
        $devices = @($devices | Where-Object {
            $needsDriverResearch = Get-ObjectPropertyValue -InputObject $_ -PropertyName 'NeedsDriverResearch' -DefaultValue $null
            if ($null -ne $needsDriverResearch) {
                [bool]$needsDriverResearch
            }
            else {
                [bool]$_.NeedsAttention
            }
        })
    }
    if (-not [string]::IsNullOrWhiteSpace($FilterText)) {
        $devices = @($devices | Where-Object { Test-DeviceMatchesFilter -Device $_ -FilterText $FilterText })
    }

    return @($devices | Sort-Object @{ Expression = 'NeedsAttention'; Descending = $true }, FriendlyName, InstanceId)
}

function Get-InstalledInfNamesForDevices {
    param(
        [object[]]$Devices
    )

    $infSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $infNames = [System.Collections.Generic.List[string]]::new()
    foreach ($device in @($Devices)) {
        $infName = [string](Get-ObjectPropertyValue -InputObject $device -PropertyName 'InfName' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($infName)) {
            continue
        }

        $leafName = Split-Path -Leaf $infName
        if (-not [string]::IsNullOrWhiteSpace($leafName) -and $infSet.Add($leafName)) {
            $infNames.Add($leafName)
        }
    }

    return @($infNames | Sort-Object)
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
            $Device.FriendlyName,
            $Device.InstanceId,
            $Device.Class,
            $Device.Status,
            $Device.Problem,
            $Device.BestResolutionName,
            $Device.InfName,
            $Device.DriverProviderName
        )) {
        if ([string]$value -match "(?i)$needle") {
            return $true
        }
    }

    foreach ($candidateId in @(Get-DeviceCandidateIds -Device $Device)) {
        if ($candidateId -match "(?i)$needle") {
            return $true
        }
    }

    return $false
}

function New-InstalledInfMatchReport {
    param(
        [object]$Inventory,
        [string]$InventoryPath,
        [object[]]$Devices,
        [object]$InfIndex,
        [switch]$AllDevices,
        [switch]$UseLiveIdEnrichment,
        [switch]$SearchAllInstalledInf,
        [AllowEmptyString()]
        [string]$FilterText
    )

    $matchedDevices = [System.Collections.Generic.List[object]]::new()
    foreach ($device in @($Devices)) {
        $liveIdEvidence = if ($UseLiveIdEnrichment) { Get-LiveDeviceIdEvidence -Device $device } else { $null }
        $candidateIds = @(Get-DeviceCandidateIds -Device $device -LiveIdEvidence $liveIdEvidence)
        $matchSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $matches = [System.Collections.Generic.List[object]]::new()

        foreach ($candidateId in @($candidateIds)) {
            if ($InfIndex.ByHardwareId.ContainsKey($candidateId)) {
                foreach ($match in @($InfIndex.ByHardwareId[$candidateId])) {
                    $matchKey = '{0}|{1}|{2}' -f $match.FileName, $match.HardwareId, $match.MatchType
                    if ($matchSet.Add($matchKey)) {
                        $matches.Add($match)
                    }
                }
            }
        }

        $installedInfName = [string]$device.InfName
        $installedInf = $null
        if (-not [string]::IsNullOrWhiteSpace($installedInfName)) {
            $infKey = (Split-Path -Leaf $installedInfName).ToLowerInvariant()
            if ($InfIndex.ByFileName.ContainsKey($infKey)) {
                $installedInf = $InfIndex.ByFileName[$infKey]
                $matchKey = '{0}|{1}|DeviceInfName' -f $installedInf.FileName, $installedInfName
                if ($matchSet.Add($matchKey)) {
                    $matches.Insert(0, [pscustomobject]@{
                        FileName = $installedInf.FileName
                        FullName = $installedInf.FullName
                        Provider = $installedInf.Provider
                        Class = $installedInf.Class
                        ClassGuid = $installedInf.ClassGuid
                        DriverVer = $installedInf.DriverVer
                        CatalogFile = $installedInf.CatalogFile
                        HardwareId = ''
                        Label = ''
                        ResolvedLabel = ''
                        Line = ''
                        LineNumber = 0
                        ModelSection = ''
                        InstallSection = ''
                        Source = 'InstalledDriverMetadata'
                        MatchType = 'DeviceInfName'
                    })
                }
            }
        }

        $exactHardwareMatches = @($matches | Where-Object { $_.MatchType -eq 'ExactHardwareId' })
        $matchedDevices.Add([pscustomobject]@{
            FriendlyName = $device.FriendlyName
            InstanceId = $device.InstanceId
            Class = $device.Class
            DeviceKind = Get-ObjectPropertyValue -InputObject $device -PropertyName 'DeviceKind' -DefaultValue ''
            AttentionCategory = Get-ObjectPropertyValue -InputObject $device -PropertyName 'AttentionCategory' -DefaultValue ''
            DriverResearchPriority = Get-ObjectPropertyValue -InputObject $device -PropertyName 'DriverResearchPriority' -DefaultValue ''
            NeedsDriverResearch = [bool](Get-ObjectPropertyValue -InputObject $device -PropertyName 'NeedsDriverResearch' -DefaultValue $false)
            Status = $device.Status
            Problem = $device.Problem
            NeedsAttention = $device.NeedsAttention
            BestResolutionName = $device.BestResolutionName
            Driver = [pscustomobject]@{
                InfName = $device.InfName
                DriverName = $device.DriverName
                Provider = $device.DriverProviderName
                Version = $device.DriverVersion
                Date = $device.DriverDate
                Service = $device.ServiceName
            }
            SearchIds = @($candidateIds)
            LiveIdEvidence = $liveIdEvidence
            InstalledInf = $installedInf
            Matches = @($matches)
            MatchSummary = [pscustomobject]@{
                HasInstalledInfFile = $null -ne $installedInf
                ExactHardwareIdMatches = $exactHardwareMatches.Count
                ModelSectionExactHardwareIdMatches = @($exactHardwareMatches | Where-Object { $_.Source -eq 'ManufacturerModelSection' }).Count
                FallbackExactHardwareIdMatches = @($exactHardwareMatches | Where-Object { $_.Source -eq 'FallbackLineScan' }).Count
                TotalMatches = $matches.Count
            }
        })
    }

    [ordered]@{
        SchemaVersion = 1
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        InventoryPath = $InventoryPath
        InventoryGeneratedAtUtc = $Inventory.GeneratedAtUtc
        InfRoot = $InfIndex.RootPath
        AllDevices = [bool]$AllDevices
        Filter = $FilterText
        SearchAllInstalledInf = [bool]$SearchAllInstalledInf
        LiveIdEnrichment = [ordered]@{
            Enabled = [bool]$UseLiveIdEnrichment
            Scope = 'SelectedDevicesOnly'
            DevicesQueried = @($matchedDevices | Where-Object { $null -ne $_.LiveIdEvidence -and $_.LiveIdEvidence.Queried }).Count
            DevicesWithLiveIds = @($matchedDevices | Where-Object { $null -ne $_.LiveIdEvidence -and $_.LiveIdEvidence.QuerySucceeded }).Count
            LiveCandidateIds = @($matchedDevices | ForEach-Object {
                    if ($null -ne $_.LiveIdEvidence) {
                        $_.LiveIdEvidence.CandidateIds
                    }
                }).Count
        }
        Counts = [ordered]@{
            Devices = $matchedDevices.Count
            DevicesWithInstalledInfFile = @($matchedDevices | Where-Object { $_.MatchSummary.HasInstalledInfFile }).Count
            DevicesWithExactHardwareIdMatches = @($matchedDevices | Where-Object { $_.MatchSummary.ExactHardwareIdMatches -gt 0 }).Count
            ExactHardwareIdMatches = @($matchedDevices | ForEach-Object { $_.MatchSummary.ExactHardwareIdMatches } | Measure-Object -Sum).Sum
            InfFiles = $InfIndex.Counts.InfFiles
            AvailableInfFiles = $InfIndex.Counts.AvailableInfFiles
            ParsedInfFiles = $InfIndex.Counts.ParsedInfFiles
            InfReadErrors = $InfIndex.Counts.ReadErrors
            IndexedHardwareIds = $InfIndex.Counts.IndexedHardwareIds
            UniqueHardwareIds = $InfIndex.Counts.UniqueHardwareIds
            ModelSectionExactHardwareIdMatches = @($matchedDevices | ForEach-Object { $_.MatchSummary.ModelSectionExactHardwareIdMatches } | Measure-Object -Sum).Sum
            FallbackExactHardwareIdMatches = @($matchedDevices | ForEach-Object { $_.MatchSummary.FallbackExactHardwareIdMatches } | Measure-Object -Sum).Sum
        }
        Devices = @($matchedDevices)
        Safety = [ordered]@{
            Mode = 'AuditOnly'
            InstallsDrivers = $false
            DownloadsDrivers = $false
            DeletesDrivers = $false
            UsesLocalInstalledInfOnly = $true
            UsesTargetedLivePnpIdRead = [bool]$UseLiveIdEnrichment
            UsesIndependentSectionAwareInfParser = $true
            SearchAllInstalledInf = [bool]$SearchAllInstalledInf
        }
        Notes = @(
            'ExactHardwareId matches use inventory IDs plus targeted live HardwareIds/CompatibleIds when live ID enrichment is enabled.',
            'Default INF indexing is scoped to the installed INF files for selected devices; use -SearchAllInstalledInf for a broad C:\Windows\INF audit.',
            'ManufacturerModelSection matches come from INF model sections discovered through [Manufacturer].',
            'FallbackLineScan matches are weaker and come from non-model sections or loose ID lines.',
            'DeviceInfName evidence comes from the inventory installed driver metadata and only proves the local INF file exists.'
        )
    }
}

function ConvertTo-MarkdownInstalledInfMatchReport {
    param(
        [object]$Report
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Installed INF Matches')
    $lines.Add('')
    $lines.Add(('- Generated UTC: {0}' -f $Report.GeneratedAtUtc))
    $lines.Add(('- Inventory: `{0}`' -f $Report.InventoryPath))
    $lines.Add(('- INF root: `{0}`' -f $Report.InfRoot))
    $lines.Add(('- Devices: {0}' -f $Report.Counts.Devices))
    $lines.Add(('- Devices with installed INF file: {0}' -f $Report.Counts.DevicesWithInstalledInfFile))
    $lines.Add(('- Devices with exact Hardware ID matches: {0}' -f $Report.Counts.DevicesWithExactHardwareIdMatches))
    $lines.Add(('- Indexed INF files: {0} parsed / {1} scoped / {2} available' -f $Report.Counts.ParsedInfFiles, $Report.Counts.InfFiles, $Report.Counts.AvailableInfFiles))
    $lines.Add(('- Indexed Hardware IDs: {0} unique / {1} total' -f $Report.Counts.UniqueHardwareIds, $Report.Counts.IndexedHardwareIds))
    $lines.Add(('- Exact Hardware ID match sources: model section `{0}`, fallback line scan `{1}`' -f $Report.Counts.ModelSectionExactHardwareIdMatches, $Report.Counts.FallbackExactHardwareIdMatches))
    $lines.Add(('- Targeted live ID enrichment: enabled `{0}`, devices with live IDs `{1}` / queried `{2}`' -f $Report.LiveIdEnrichment.Enabled, $Report.LiveIdEnrichment.DevicesWithLiveIds, $Report.LiveIdEnrichment.DevicesQueried))
    $lines.Add(('- Broad installed INF search: `{0}`' -f $Report.SearchAllInstalledInf))
    $lines.Add('- Safety: audit-only, independent section-aware local INF parser, no download/install/remove actions')
    if (-not [string]::IsNullOrWhiteSpace([string]$Report.Filter)) {
        $lines.Add(('- Filter: `{0}`' -f $Report.Filter))
    }
    $lines.Add('')
    $lines.Add('> Tip: targeted live ID enrichment avoids a slow full inventory pass by reading deep IDs only for the selected devices. Use `-SkipLiveIdEnrichment` for strict inventory-only matching. Use `-SearchAllInstalledInf` only when you need a slower broad local INF audit.')
    $lines.Add('')

    foreach ($device in @($Report.Devices)) {
        $title = if ([string]::IsNullOrWhiteSpace([string]$device.FriendlyName)) { $device.InstanceId } else { $device.FriendlyName }
        $lines.Add(("## {0}" -f $title))
        $lines.Add('')
        $lines.Add(('- Status: `{0}`  Problem: `{1}`  Class: `{2}`' -f $device.Status, $device.Problem, $device.Class))
        $lines.Add(('- Device kind: `{0}`  Attention: `{1}`  Driver research: `{2}`' -f $device.DeviceKind, $device.AttentionCategory, $device.DriverResearchPriority))
        $lines.Add(('- InstanceId: `{0}`' -f $device.InstanceId))
        $lines.Add(('- Installed driver: INF `{0}`, provider `{1}`, version `{2}`, date `{3}`, service `{4}`' -f $device.Driver.InfName, $device.Driver.Provider, $device.Driver.Version, $device.Driver.Date, $device.Driver.Service))
        $lines.Add(('- Match summary: installed INF file `{0}`, exact Hardware ID matches `{1}`, model-section `{2}`, fallback `{3}`, total matches `{4}`' -f $device.MatchSummary.HasInstalledInfFile, $device.MatchSummary.ExactHardwareIdMatches, $device.MatchSummary.ModelSectionExactHardwareIdMatches, $device.MatchSummary.FallbackExactHardwareIdMatches, $device.MatchSummary.TotalMatches))
        if ($null -ne $device.LiveIdEvidence) {
            $lines.Add(('- Targeted live IDs: queried `{0}`, found `{1}`' -f $device.LiveIdEvidence.Queried, $device.LiveIdEvidence.QuerySucceeded))
        }
        if (@($device.SearchIds).Count -gt 0) {
            $lines.Add('- Inventory IDs:')
            foreach ($searchId in @($device.SearchIds | Select-Object -First 10)) {
                $lines.Add(('  - `{0}`' -f $searchId))
            }
        }

        if (@($device.Matches).Count -gt 0) {
            $lines.Add('')
            $lines.Add('### Local INF Evidence')
            $lines.Add('')
            foreach ($match in @($device.Matches | Select-Object -First 20)) {
                $matchLabel = if ([string]::IsNullOrWhiteSpace([string]$match.HardwareId)) { $match.MatchType } else { ('{0}: {1}' -f $match.MatchType, $match.HardwareId) }
                $lines.Add(('- `{0}` - {1}' -f $match.FileName, $matchLabel))
                if (-not [string]::IsNullOrWhiteSpace([string]$match.ResolvedLabel)) {
                    $lines.Add(('  - Label: `{0}`' -f $match.ResolvedLabel))
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$match.ModelSection) -or -not [string]::IsNullOrWhiteSpace([string]$match.InstallSection)) {
                    $lines.Add(('  - Model section `{0}`, install section `{1}`, source `{2}`, line `{3}`' -f $match.ModelSection, $match.InstallSection, $match.Source, $match.LineNumber))
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$match.Provider) -or -not [string]::IsNullOrWhiteSpace([string]$match.DriverVer)) {
                    $lines.Add(('  - Provider `{0}`, class `{1}`, DriverVer `{2}`, catalog `{3}`' -f $match.Provider, $match.Class, $match.DriverVer, $match.CatalogFile))
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$match.Line)) {
                    $lines.Add(('  - Line: `{0}`' -f $match.Line))
                }
            }
        }
        else {
            $lines.Add('')
            $lines.Add('No local installed INF evidence found for this selected device.')
        }

        $lines.Add('')
    }

    return ($lines -join [Environment]::NewLine)
}

function Write-InstalledInfMatchSummary {
    param(
        [object]$Report
    )

    Write-Host 'Installed INF Matches' -ForegroundColor Cyan
    Write-Host '---------------------' -ForegroundColor Cyan
    Write-Host ("Inventory       : {0}" -f $Report.InventoryPath) -ForegroundColor DarkGray
    Write-Host ("INF root        : {0}" -f $Report.InfRoot) -ForegroundColor DarkGray
    Write-Host ("Selected devices: {0}" -f $Report.Counts.Devices) -ForegroundColor Cyan
    Write-Host ("Installed INF   : {0}" -f $Report.Counts.DevicesWithInstalledInfFile) -ForegroundColor Cyan
    Write-Host ("Exact ID devices: {0}" -f $Report.Counts.DevicesWithExactHardwareIdMatches) -ForegroundColor Cyan
    Write-Host ("Model matches   : {0}" -f $Report.Counts.ModelSectionExactHardwareIdMatches) -ForegroundColor Cyan
    Write-Host ("INF index       : {0} parsed, {1} scoped, {2} available, {3} unique IDs" -f $Report.Counts.ParsedInfFiles, $Report.Counts.InfFiles, $Report.Counts.AvailableInfFiles, $Report.Counts.UniqueHardwareIds) -ForegroundColor Cyan
    Write-Host ("Broad INF search: {0}" -f $Report.SearchAllInstalledInf) -ForegroundColor Cyan
    Write-Host ("Live ID enrich  : {0}; live IDs {1}/{2} devices" -f $Report.LiveIdEnrichment.Enabled, $Report.LiveIdEnrichment.DevicesWithLiveIds, $Report.LiveIdEnrichment.DevicesQueried) -ForegroundColor Cyan
    Write-Host 'Safety          : audit-only; no downloads, installs, or removals' -ForegroundColor Green
    Write-Host ''

    foreach ($device in @($Report.Devices | Select-Object -First 12)) {
        Write-Host ("- {0}" -f $device.FriendlyName) -ForegroundColor Yellow
        Write-Host ("  {0} / {1} / research {2}" -f $device.Class, $device.Status, $device.DriverResearchPriority) -ForegroundColor DarkGray
        Write-Host ("  Installed INF: {0} / provider {1}" -f $device.Driver.InfName, $device.Driver.Provider) -ForegroundColor DarkCyan
        Write-Host ("  Matches: exact IDs {0}, model {1}, fallback {2}, total {3}" -f $device.MatchSummary.ExactHardwareIdMatches, $device.MatchSummary.ModelSectionExactHardwareIdMatches, $device.MatchSummary.FallbackExactHardwareIdMatches, $device.MatchSummary.TotalMatches) -ForegroundColor DarkGray
    }
}

function Save-InstalledInfMatchReport {
    param(
        [object]$Report,
        [string]$RootPath
    )

    New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $RootPath "installed-inf-matches-$timestamp.json"
    $markdownPath = Join-Path $RootPath "installed-inf-matches-$timestamp.md"

    $Report | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    ConvertTo-MarkdownInstalledInfMatchReport -Report $Report | Set-Content -LiteralPath $markdownPath -Encoding UTF8

    [pscustomobject]@{
        JsonPath = $jsonPath
        MarkdownPath = $markdownPath
    }
}

$inventoryBundle = Get-Inventory -Path $InventoryPath -RootPath $InventoryRoot
$selectedDevices = @(Select-InventoryDevicesForInfMatching -Inventory $inventoryBundle.Inventory -AllDevices:$AllDevices -FilterText $Filter)
$includeInfFileNames = if ($SearchAllInstalledInf) { @() } else { @(Get-InstalledInfNamesForDevices -Devices $selectedDevices) }
$infIndex = New-InfIndex -RootPath $InfRoot -IncludeFileNames $includeInfFileNames
$report = New-InstalledInfMatchReport -Inventory $inventoryBundle.Inventory -InventoryPath $inventoryBundle.Path -Devices $selectedDevices -InfIndex $infIndex -AllDevices:$AllDevices -UseLiveIdEnrichment:(-not [bool]$SkipLiveIdEnrichment) -SearchAllInstalledInf:$SearchAllInstalledInf -FilterText $Filter

if ($AsJson) {
    $report | ConvertTo-Json -Depth 32
    return
}

Write-InstalledInfMatchSummary -Report $report

if (-not $NoReport) {
    $savedReport = Save-InstalledInfMatchReport -Report $report -RootPath $OutputRoot
    Write-Host ''
    Write-Host 'Reports' -ForegroundColor Green
    Write-Host ("JSON     : {0}" -f $savedReport.JsonPath) -ForegroundColor DarkGray
    Write-Host ("Markdown : {0}" -f $savedReport.MarkdownPath) -ForegroundColor DarkGray
}
