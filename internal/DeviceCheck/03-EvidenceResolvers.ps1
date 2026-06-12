# Part of DeviceCheck.ps1. Dot-sourced by the root entrypoint; keep script-scope state shared.
# Purpose: Offline hardware, board, audio, monitor, driver, SDIO, and evidence cache helpers.
function Test-HardwareIdCacheReady {
    param(
        [string]$CacheRoot
    )

    if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
        return $false
    }

    $normalizedRoot = Join-Path -Path $CacheRoot -ChildPath 'normalized'
    foreach ($fileName in @('pci.json', 'usb.json', 'pnp.json')) {
        $filePath = Join-Path -Path $normalizedRoot -ChildPath $fileName
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            return $false
        }
    }

    return $true
}

function Update-HardwareIdCacheIfMissing {
    param(
        [string]$CacheRoot
    )

    if (Test-HardwareIdCacheReady -CacheRoot $CacheRoot) {
        return
    }

    $updateScriptPath = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'internal\Update-HardwareIdDatabases.ps1'
    if (-not (Test-Path -LiteralPath $updateScriptPath -PathType Leaf)) {
        throw "Hardware ID cache is missing and updater was not found: $updateScriptPath"
    }

    $null = & $updateScriptPath -OutputRoot $CacheRoot -ErrorAction Stop *>&1

    if (-not (Test-HardwareIdCacheReady -CacheRoot $CacheRoot)) {
        throw "Hardware ID cache updater completed, but normalized cache files are still missing under: $CacheRoot"
    }
}

function Initialize-HardwareIdResolver {
    if ($script:HardwareIdResolverState -ne 'NotLoaded') {
        return
    }

    $script:HardwareIdResolverState = 'Unavailable'
    $script:HardwareIdResolverError = ''

    try {
        $modulePath = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'internal\HardwareIdResolver.psm1'
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            $script:HardwareIdResolverError = "Resolver module not found: $modulePath"
            return
        }

        Import-Module -Name $modulePath -Force -ErrorAction Stop
        $cacheRoot = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'data\hwdb'
        Update-HardwareIdCacheIfMissing -CacheRoot $cacheRoot
        $script:HardwareIdDatabaseCache = Import-HardwareIdDatabaseCache -CacheRoot $cacheRoot
        $script:HardwareIdResolverState = 'Ready'
    }
    catch {
        $script:HardwareIdResolverError = $_.Exception.Message
        $script:HardwareIdResolverState = 'Unavailable'
    }
}

function Test-AlsaUcmCacheReady {
    param(
        [string]$CacheRoot
    )

    $cachePath = Join-Path -Path $CacheRoot -ChildPath 'normalized\alsa-ucm-usb-audio.json'
    return (Test-Path -LiteralPath $cachePath -PathType Leaf)
}

function Update-AlsaUcmCacheIfMissing {
    param(
        [string]$CacheRoot
    )

    if (Test-AlsaUcmCacheReady -CacheRoot $CacheRoot) {
        return
    }

    $sourcePath = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'source\alsa-ucm-conf\USB-Audio.conf'
    $updateScriptPath = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'internal\Update-AlsaUcmProfiles.ps1'
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf) -or -not (Test-Path -LiteralPath $updateScriptPath -PathType Leaf)) {
        return
    }

    & $updateScriptPath -OutputRoot $CacheRoot > $null
}

function Initialize-AlsaUcmResolver {
    if ($script:AlsaUcmResolverState -ne 'NotLoaded') {
        return
    }

    $script:AlsaUcmResolverState = 'Unavailable'
    $script:AlsaUcmResolverError = ''
    $script:AlsaUcmUsbAudioProfileCache = $null

    try {
        $modulePath = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'internal\AlsaUcmResolver.psm1'
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            $script:AlsaUcmResolverError = "ALSA UCM resolver module not found: $modulePath"
            return
        }

        Import-Module -Name $modulePath -Force -ErrorAction Stop
        $cacheRoot = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'data\hwdb'
        Update-AlsaUcmCacheIfMissing -CacheRoot $cacheRoot
        if (-not (Test-AlsaUcmCacheReady -CacheRoot $cacheRoot)) {
            $script:AlsaUcmResolverError = 'ALSA UCM source/cache is not available.'
            return
        }

        $script:AlsaUcmUsbAudioProfileCache = Import-AlsaUcmUsbAudioProfileCache -CacheRoot $cacheRoot
        $script:AlsaUcmResolverState = 'Ready'
    }
    catch {
        $script:AlsaUcmResolverError = $_.Exception.Message
        $script:AlsaUcmResolverState = 'Unavailable'
    }
}

function Initialize-MonitorEdidResolver {
    if ($script:MonitorEdidResolverState -ne 'NotLoaded') {
        return
    }

    $script:MonitorEdidResolverState = 'Unavailable'
    $script:MonitorEdidResolverError = ''
    $script:MonitorEdidIdentityCache = @{}
    $script:MonitorWmiEvidenceCache = @{}
    $script:MonitorInfEvidenceCache = @{}

    try {
        $modulePath = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'internal\MonitorEdidResolver.psm1'
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            $script:MonitorEdidResolverError = "Monitor EDID resolver module not found: $modulePath"
            return
        }

        Import-Module -Name $modulePath -Force -ErrorAction Stop
        $script:MonitorEdidResolverState = 'Ready'
    }
    catch {
        $script:MonitorEdidResolverError = $_.Exception.Message
        $script:MonitorEdidResolverState = 'Unavailable'
    }
}

function Get-HardwareResolutionDisplayName {
    param(
        [object]$Resolution
    )

    $lookup = Get-NotePropertyValue -Object $Resolution -Name 'Lookup'
    foreach ($name in @('SubsystemName', 'DeviceName', 'ProductName', 'InterfaceName', 'VendorName')) {
        $value = [string](Get-NotePropertyValue -Object $lookup -Name $name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return ''
}

function Get-HardwareResolutionDisplayText {
    param(
        [object]$Resolution
    )

    $bus = [string](Get-NotePropertyValue -Object $Resolution -Name 'Bus')
    $confidence = [string](Get-NotePropertyValue -Object $Resolution -Name 'Confidence')
    $displayName = Get-HardwareResolutionDisplayName -Resolution $Resolution
    $lookup = Get-NotePropertyValue -Object $Resolution -Name 'Lookup'
    $fields = Get-NotePropertyValue -Object $Resolution -Name 'Fields'
    $subvendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'SubvendorName')
    $subdeviceId = [string](Get-NotePropertyValue -Object $fields -Name 'SubdeviceId')
    $productId = [string](Get-NotePropertyValue -Object $fields -Name 'ProductId')
    $textParts = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($bus)) {
        $textParts.Add($bus)
    }
    if (-not [string]::IsNullOrWhiteSpace($confidence)) {
        $textParts.Add($confidence)
    }
    if (-not [string]::IsNullOrWhiteSpace($displayName)) {
        $textParts.Add($displayName)
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-NotePropertyValue -Object $lookup -Name 'SubsystemName')) -and
        -not [string]::IsNullOrWhiteSpace($subvendorName)) {
        $boardText = "board $subvendorName"
        if (-not [string]::IsNullOrWhiteSpace($subdeviceId)) {
            $boardText = "$boardText $subdeviceId"
        }
        $textParts.Add($boardText)
    }
    if ($bus -eq 'DISPLAY' -and -not [string]::IsNullOrWhiteSpace($productId)) {
        $textParts.Add("EDID product $productId")
    }

    if ($textParts.Count -eq 0) {
        return ''
    }

    return ($textParts -join ' / ')
}

function Get-ShortHardwareVendorName {
    param(
        [AllowEmptyString()][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }
    if ($Name -match '\[([^\]]+)\]\s*$') {
        return $Matches[1]
    }

    $shortName = $Name -replace '\s+Corporation$', ''
    $shortName = $shortName -replace '\s+Co\.,?\s+Ltd\.?$', ''
    $shortName = $shortName -replace ',.*$', ''
    return $shortName.Trim()
}


function Get-FormattedHardwareVendorName {
    param(
        [AllowEmptyString()][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }

    $bracketName = ''
    $baseName = $Name
    if ($Name -match '^(.*?)\s*\[([^\]]+)\]\s*$') {
        $baseName = $Matches[1]
        $bracketName = $Matches[2].Trim()
    }

    $baseName = $baseName -replace '\s+Corporation$', ''
    $baseName = $baseName -replace '\s+Co\.,?\s+Ltd\.?$', ''
    $baseName = $baseName -replace ',.*$', ''
    $baseName = $baseName.Trim()

    if ($bracketName -and $bracketName -ne $baseName) {
        return "$baseName / $bracketName"
    }

    return $baseName
}


function New-HardwareIdentityRow {
    param(
        [string]$Key,
        [AllowEmptyString()][string]$Value,
        [string]$Color = 'White'
    )

    return [PSCustomObject]@{
        Key   = $Key
        Value = $Value
        Color = $Color
    }
}

function Normalize-HardwareEvidenceId {
    param(
        [AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return (($Value -replace '^(?i:0x)', '').Trim()).ToUpperInvariant()
}

function Get-BoardModelEvidenceKey {
    param(
        [AllowEmptyString()][string]$Bus,
        [AllowEmptyString()][string]$VendorId,
        [AllowEmptyString()][string]$DeviceId,
        [AllowEmptyString()][string]$ProductId,
        [AllowEmptyString()][string]$SubvendorId,
        [AllowEmptyString()][string]$SubdeviceId,
        [AllowEmptyString()][string]$InterfaceId,
        [AllowEmptyString()][string]$Revision
    )

    $keyParts = @(
        (Normalize-HardwareEvidenceId -Value $Bus),
        (Normalize-HardwareEvidenceId -Value $VendorId),
        (Normalize-HardwareEvidenceId -Value $DeviceId),
        (Normalize-HardwareEvidenceId -Value $ProductId),
        (Normalize-HardwareEvidenceId -Value $SubvendorId),
        (Normalize-HardwareEvidenceId -Value $SubdeviceId),
        (Normalize-HardwareEvidenceId -Value $InterfaceId),
        (Normalize-HardwareEvidenceId -Value $Revision)
    )

    return ($keyParts -join '|')
}

function Add-BoardModelEvidenceIndexEntry {
    param(
        [object]$Entry
    )

    $bus = [string](Get-NotePropertyValue -Object $Entry -Name 'Bus')
    $vendorId = [string](Get-NotePropertyValue -Object $Entry -Name 'VendorId')
    $deviceId = [string](Get-NotePropertyValue -Object $Entry -Name 'DeviceId')
    $productId = [string](Get-NotePropertyValue -Object $Entry -Name 'ProductId')
    $subvendorId = [string](Get-NotePropertyValue -Object $Entry -Name 'SubvendorId')
    $subdeviceId = [string](Get-NotePropertyValue -Object $Entry -Name 'SubdeviceId')
    $interfaceId = [string](Get-NotePropertyValue -Object $Entry -Name 'InterfaceId')
    $revision = [string](Get-NotePropertyValue -Object $Entry -Name 'Revision')

    $normalizedBus = (Normalize-HardwareEvidenceId -Value $bus)
    $hasPciTuple = (
        $normalizedBus -eq 'PCI' -and
        -not [string]::IsNullOrWhiteSpace($vendorId) -and
        -not [string]::IsNullOrWhiteSpace($deviceId) -and
        -not [string]::IsNullOrWhiteSpace($subvendorId) -and
        -not [string]::IsNullOrWhiteSpace($subdeviceId)
    )
    $hasUsbTuple = (
        $normalizedBus -in @('USB', 'HID') -and
        -not [string]::IsNullOrWhiteSpace($vendorId) -and
        -not [string]::IsNullOrWhiteSpace($productId)
    )
    $hasHdAudioTuple = (
        $normalizedBus -eq 'HDAUDIO' -and
        -not [string]::IsNullOrWhiteSpace($vendorId) -and
        -not [string]::IsNullOrWhiteSpace($deviceId) -and
        -not [string]::IsNullOrWhiteSpace($subvendorId) -and
        -not [string]::IsNullOrWhiteSpace($subdeviceId)
    )
    $hasDisplayTuple = (
        $normalizedBus -eq 'DISPLAY' -and
        -not [string]::IsNullOrWhiteSpace($vendorId) -and
        -not [string]::IsNullOrWhiteSpace($productId)
    )

    if (-not ($hasPciTuple -or $hasUsbTuple -or $hasHdAudioTuple -or $hasDisplayTuple)) {
        return
    }

    foreach ($entryInterfaceId in @($interfaceId, '')) {
        foreach ($entryRevision in @($revision, '')) {
            $key = Get-BoardModelEvidenceKey -Bus $bus -VendorId $vendorId -DeviceId $deviceId -ProductId $productId -SubvendorId $subvendorId -SubdeviceId $subdeviceId -InterfaceId $entryInterfaceId -Revision $entryRevision
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                $script:BoardModelEvidenceIndex[$key] = $Entry
            }
        }
    }
}

function Initialize-BoardModelEvidenceStore {
    if ($script:BoardModelEvidenceState -ne 'NotLoaded') {
        return
    }

    $script:BoardModelEvidenceState = 'Unavailable'
    $script:BoardModelEvidenceError = ''
    $script:BoardModelEvidenceIndex = @{}

    $evidencePath = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'config\board-model-evidence.json'
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        $script:BoardModelEvidenceState = 'Ready'
        return
    }

    try {
        $payload = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($entry in @($payload.Evidence)) {
            Add-BoardModelEvidenceIndexEntry -Entry $entry
        }
        $script:BoardModelEvidenceState = 'Ready'
    }
    catch {
        $script:BoardModelEvidenceError = $_.Exception.Message
        $script:BoardModelEvidenceState = 'Unavailable'
    }
}

function Get-BoardModelEvidenceForResolution {
    param(
        [object]$Resolution
    )

    if ($script:BoardModelEvidenceState -ne 'Ready') {
        return $null
    }

    $fields = Get-NotePropertyValue -Object $Resolution -Name 'Fields'
    $bus = [string](Get-NotePropertyValue -Object $Resolution -Name 'Bus')
    $vendorId = [string](Get-NotePropertyValue -Object $fields -Name 'VendorId')
    $deviceId = [string](Get-NotePropertyValue -Object $fields -Name 'DeviceId')
    $productId = [string](Get-NotePropertyValue -Object $fields -Name 'ProductId')
    $subvendorId = [string](Get-NotePropertyValue -Object $fields -Name 'SubvendorId')
    $subdeviceId = [string](Get-NotePropertyValue -Object $fields -Name 'SubdeviceId')
    $interfaceId = [string](Get-NotePropertyValue -Object $fields -Name 'InterfaceId')
    $revision = [string](Get-NotePropertyValue -Object $fields -Name 'Revision')

    foreach ($candidateInterfaceId in @($interfaceId, '')) {
        foreach ($candidateRevision in @($revision, '')) {
            $key = Get-BoardModelEvidenceKey -Bus $bus -VendorId $vendorId -DeviceId $deviceId -ProductId $productId -SubvendorId $subvendorId -SubdeviceId $subdeviceId -InterfaceId $candidateInterfaceId -Revision $candidateRevision
            if ($script:BoardModelEvidenceIndex.ContainsKey($key)) {
                return $script:BoardModelEvidenceIndex[$key]
            }
        }
    }

    return $null
}

function Add-BoardModelEvidenceRows {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [object]$Resolution
    )

    $evidence = Get-BoardModelEvidenceForResolution -Resolution $Resolution
    if ($null -eq $evidence) {
        return $false
    }

    $resolutionBus = [string](Get-NotePropertyValue -Object $Resolution -Name 'Bus')
    $modelName = [string](Get-NotePropertyValue -Object $evidence -Name 'ModelName')
    $modelKey = [string](Get-NotePropertyValue -Object $evidence -Name 'ModelKey')
    $source = Get-NotePropertyValue -Object $evidence -Name 'Source'
    $sourceName = [string](Get-NotePropertyValue -Object $source -Name 'Name')
    $sourceType = [string](Get-NotePropertyValue -Object $source -Name 'Type')
    $sourceUrl = [string](Get-NotePropertyValue -Object $source -Name 'Url')
    $confidence = [string](Get-NotePropertyValue -Object $evidence -Name 'Confidence')
    $confidenceScore = [string](Get-NotePropertyValue -Object $evidence -Name 'ConfidenceScore')
    $sourceDisplay = $(if ($sourceType -eq 'UserConfirmedExternalPage' -and $sourceUrl -match 'techpowerup\.com') {
        'User-confirmed + TechPowerUp GPU Database'
    } else {
        $sourceName
    })
    if ([string]::IsNullOrWhiteSpace($modelKey)) {
        $modelKey = $(if ($resolutionBus -in @('USB', 'HID')) { 'Product Model' } else { 'Board Model' })
    }

    if (-not [string]::IsNullOrWhiteSpace($modelName)) {
        $Rows.Add((New-HardwareIdentityRow -Key $modelKey -Value $modelName -Color 'OK'))
    }

    $confidenceText = @(
        $confidence
        $(if (-not [string]::IsNullOrWhiteSpace($confidenceScore)) { "$confidenceScore/100" })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (@($confidenceText).Count -gt 0) {
        $Rows.Add((New-HardwareIdentityRow -Key 'Confidence' -Value ($confidenceText -join ' / ') -Color 'OK'))
    }

    if (-not [string]::IsNullOrWhiteSpace($sourceDisplay)) {
        $Rows.Add((New-HardwareIdentityRow -Key 'Source' -Value $sourceDisplay -Color 'White'))
    }

    if (-not [string]::IsNullOrWhiteSpace($sourceUrl)) {
        $Rows.Add((New-HardwareIdentityRow -Key 'URL' -Value $sourceUrl -Color 'Info'))
    }

    return $true
}

function Add-AlsaUcmAudioProfileRows {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [object]$Resolution
    )

    if ($script:AlsaUcmResolverState -ne 'Ready' -or $null -eq $script:AlsaUcmUsbAudioProfileCache) {
        return $false
    }

    $inputId = [string](Get-NotePropertyValue -Object $Resolution -Name 'Input')
    if ([string]::IsNullOrWhiteSpace($inputId)) {
        return $false
    }

    $profileMatch = @(Resolve-AlsaUcmUsbAudioProfile -HardwareId $inputId -Cache $script:AlsaUcmUsbAudioProfileCache | Select-Object -First 1)
    if ($profileMatch.Count -eq 0) {
        return $false
    }

    $profile = $profileMatch[0]
    if (-not [string]::IsNullOrWhiteSpace([string]$profile.ProfileName)) {
        $Rows.Add((New-HardwareIdentityRow -Key 'Audio Profile' -Value ([string]$profile.ProfileName) -Color 'OK'))
    }

    $matchParts = @(
        ([string]$profile.UsbId)
        ([string]$profile.EvidenceLabel)
        ([string]$profile.SourceId)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (@($matchParts).Count -gt 0) {
        $Rows.Add((New-HardwareIdentityRow -Key 'Profile Match' -Value ($matchParts -join ' / ') -Color 'Info'))
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$profile.CommentLabel)) {
        $Rows.Add((New-HardwareIdentityRow -Key 'Profile Note' -Value ([string]$profile.CommentLabel) -Color 'Dim'))
    }

    $sourceVersion = [string]$profile.SourceVersion
    $sourceCommit = [string]$profile.SourceCommit
    $sourceDisplay = 'ALSA UCM'
    if (-not [string]::IsNullOrWhiteSpace($sourceVersion)) {
        $sourceDisplay = "$sourceDisplay $sourceVersion"
    }
    if (-not [string]::IsNullOrWhiteSpace($sourceCommit) -and $sourceCommit.Length -ge 8) {
        $sourceDisplay = "$sourceDisplay / $($sourceCommit.Substring(0, 8))"
    }
    $Rows.Add((New-HardwareIdentityRow -Key 'Evidence' -Value "$sourceDisplay; audio profile, not usb.ids product" -Color 'White'))

    return $true
}

function Get-MonitorEdidIdentityForResolution {
    param(
        [object]$Resolution,
        [object]$Evidence
    )

    if ($script:MonitorEdidResolverState -ne 'Ready') {
        return $null
    }

    $candidateSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $candidates = [System.Collections.Generic.List[string]]::new()

    function Add-MonitorEdidCandidate {
        param([AllowEmptyString()][string]$Value)
        if (-not [string]::IsNullOrWhiteSpace($Value) -and $candidateSet.Add($Value)) {
            $candidates.Add($Value)
        }
    }

    $device = Get-NotePropertyValue -Object $Evidence -Name 'Device'
    Add-MonitorEdidCandidate -Value ([string](Get-NotePropertyValue -Object $device -Name 'InstanceId'))
    Add-MonitorEdidCandidate -Value ([string](Get-NotePropertyValue -Object $Resolution -Name 'Input'))
    Add-MonitorEdidCandidate -Value ([string](Get-NotePropertyValue -Object $Resolution -Name 'Normalized'))

    $fields = Get-NotePropertyValue -Object $Resolution -Name 'Fields'
    $vendorId = [string](Get-NotePropertyValue -Object $fields -Name 'VendorId')
    $productId = [string](Get-NotePropertyValue -Object $fields -Name 'ProductId')
    if (-not [string]::IsNullOrWhiteSpace($vendorId) -and -not [string]::IsNullOrWhiteSpace($productId)) {
        Add-MonitorEdidCandidate -Value "DISPLAY\$vendorId$productId"
    }

    foreach ($candidate in @($candidates)) {
        if ($script:MonitorEdidIdentityCache.ContainsKey($candidate)) {
            $cached = $script:MonitorEdidIdentityCache[$candidate]
            if ($null -ne $cached) {
                return $cached
            }
            continue
        }

        try {
            $edid = Get-MonitorEdidFromRegistry -InstanceId $candidate
            $script:MonitorEdidIdentityCache[$candidate] = $edid
            if ($null -ne $edid) {
                return $edid
            }
        }
        catch {
            $script:MonitorEdidResolverError = $_.Exception.Message
            $script:MonitorEdidIdentityCache[$candidate] = $null
        }
    }

    return $null
}

function Get-MonitorWmiIdentityForResolution {
    param(
        [object]$Resolution,
        [object]$Evidence
    )

    if ($script:MonitorEdidResolverState -ne 'Ready') {
        return $null
    }

    $candidateSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $candidates = [System.Collections.Generic.List[string]]::new()

    function Add-MonitorWmiCandidate {
        param([AllowEmptyString()][string]$Value)
        if (-not [string]::IsNullOrWhiteSpace($Value) -and $candidateSet.Add($Value)) {
            $candidates.Add($Value)
        }
    }

    $device = Get-NotePropertyValue -Object $Evidence -Name 'Device'
    Add-MonitorWmiCandidate -Value ([string](Get-NotePropertyValue -Object $device -Name 'InstanceId'))
    Add-MonitorWmiCandidate -Value ([string](Get-NotePropertyValue -Object $Resolution -Name 'Input'))
    Add-MonitorWmiCandidate -Value ([string](Get-NotePropertyValue -Object $Resolution -Name 'Normalized'))

    $fields = Get-NotePropertyValue -Object $Resolution -Name 'Fields'
    $vendorId = [string](Get-NotePropertyValue -Object $fields -Name 'VendorId')
    $productId = [string](Get-NotePropertyValue -Object $fields -Name 'ProductId')
    if (-not [string]::IsNullOrWhiteSpace($vendorId) -and -not [string]::IsNullOrWhiteSpace($productId)) {
        Add-MonitorWmiCandidate -Value "DISPLAY\$vendorId$productId"
    }

    foreach ($candidate in @($candidates)) {
        if ($script:MonitorWmiEvidenceCache.ContainsKey($candidate)) {
            $cached = $script:MonitorWmiEvidenceCache[$candidate]
            if ($null -ne $cached) {
                return $cached
            }
            continue
        }

        try {
            $wmiData = Get-MonitorWmiEvidence -InstanceId $candidate
            $script:MonitorWmiEvidenceCache[$candidate] = $wmiData
            if ($null -ne $wmiData) {
                return $wmiData
            }
        }
        catch {
            $script:MonitorWmiEvidenceCache[$candidate] = $null
        }
    }

    return $null
}

function Get-MonitorInfIdentityForResolution {
    param(
        [object]$Resolution,
        [object]$Evidence
    )

    if ($script:MonitorEdidResolverState -ne 'Ready') {
        return $null
    }

    $device = Get-NotePropertyValue -Object $Evidence -Name 'Device'
    $instanceId = [string](Get-NotePropertyValue -Object $device -Name 'InstanceId')
    if ([string]::IsNullOrWhiteSpace($instanceId)) {
        return $null
    }

    if ($script:MonitorInfEvidenceCache.ContainsKey($instanceId)) {
        return $script:MonitorInfEvidenceCache[$instanceId]
    }

    $driver = Get-InstalledDriverEvidenceFields -Evidence $Evidence
    $hardwareIds = @(Get-CandidateEvidenceHardwareIds -Evidence $Evidence -InstanceId $instanceId)

    try {
        $infData = Get-MonitorInfEvidence -InfName $driver.InfName -SectionName $driver.InfSection -HardwareIds $hardwareIds
        $script:MonitorInfEvidenceCache[$instanceId] = $infData
        return $infData
    }
    catch {
        $script:MonitorInfEvidenceCache[$instanceId] = $null
        return $null
    }
}

function Add-MonitorEdidRows {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [object]$Resolution,
        [object]$Evidence
    )

    $edid = Get-MonitorEdidIdentityForResolution -Resolution $Resolution -Evidence $Evidence
    if ($null -eq $edid) {
        return $false
    }

    $monitorName = [string](Get-NotePropertyValue -Object $edid -Name 'MonitorName')
    $manufacturerId = [string](Get-NotePropertyValue -Object $edid -Name 'ManufacturerId')
    $productCode = [string](Get-NotePropertyValue -Object $edid -Name 'ProductCode')
    $widthCm = [int](Get-NotePropertyValue -Object $edid -Name 'WidthCm')
    $heightCm = [int](Get-NotePropertyValue -Object $edid -Name 'HeightCm')
    $manufactureWeek = [int](Get-NotePropertyValue -Object $edid -Name 'ManufactureWeek')
    $manufactureYear = [int](Get-NotePropertyValue -Object $edid -Name 'ManufactureYear')
    $serialDescriptor = [string](Get-NotePropertyValue -Object $edid -Name 'SerialText')
    $serialNumber = [uint32](Get-NotePropertyValue -Object $edid -Name 'SerialNumber')
    $checksumValid = [bool](Get-NotePropertyValue -Object $edid -Name 'ChecksumValid')
    $source = [string](Get-NotePropertyValue -Object $edid -Name 'Source')

    if (-not [string]::IsNullOrWhiteSpace($monitorName)) {
        $Rows.Add((New-HardwareIdentityRow -Key 'EDID Name' -Value $monitorName -Color 'OK'))
    }

    $edidIdParts = @(
        $manufacturerId
        $productCode
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (@($edidIdParts).Count -gt 0) {
        $Rows.Add((New-HardwareIdentityRow -Key 'EDID ID' -Value ($edidIdParts -join ' ') -Color 'Info'))
    }

    if ($widthCm -gt 0 -or $heightCm -gt 0) {
        $Rows.Add((New-HardwareIdentityRow -Key 'Panel Size' -Value ("{0} x {1} cm" -f $widthCm, $heightCm) -Color 'White'))
    }

    if ($manufactureYear -gt 1990) {
        $madeText = $(if ($manufactureWeek -gt 0) {
            "week $manufactureWeek / $manufactureYear"
        } else {
            [string]$manufactureYear
        })
        $Rows.Add((New-HardwareIdentityRow -Key 'Made' -Value $madeText -Color 'Dim'))
    }

    $timing = Get-NotePropertyValue -Object $edid -Name 'PreferredTiming'
    if ($null -ne $timing -and $timing.Width -gt 0 -and $timing.Height -gt 0) {
        $timingText = "{0}x{1}" -f $timing.Width, $timing.Height
        if ($null -ne $timing.RefreshRateHz) {
            $timingText = "$timingText @ $($timing.RefreshRateHz)Hz"
        }
        $Rows.Add((New-HardwareIdentityRow -Key 'Native Timing' -Value $timingText -Color 'White'))
    }

    $checksumText = $(if ($checksumValid) { 'OK' } else { 'Invalid' })
    $checksumColor = $(if ($checksumValid) { 'OK' } else { 'Warn' })
    $Rows.Add((New-HardwareIdentityRow -Key 'EDID Checksum' -Value $checksumText -Color $checksumColor))

    return $true
}

function Get-VideoOutputTechnologyName {
    param(
        [int]$Technology
    )
    switch ($Technology) {
        -2 { "Other" }
        -1 { "Uninitialized" }
        0  { "HD15 (VGA)" }
        1  { "S-Video" }
        2  { "Composite Video" }
        3  { "Component Video" }
        4  { "DVI" }
        5  { "HDMI" }
        6  { "LVDS" }
        8  { "D-JPN" }
        9  { "SDI" }
        10 { "DisplayPort External" }
        11 { "DisplayPort Embedded" }
        12 { "UDI External" }
        13 { "UDI Embedded" }
        14 { "SDTV Dongle" }
        15 { "Miracast" }
        20 { "Indirect Wired" }
        21 { "Indirect Virtual" }
        -2147483648 { "Internal" }
        2147483648  { "Internal" }
        Default { "Unknown ($Technology)" }
    }
}

function Add-MonitorWmiAndInfRows {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [object]$Resolution,
        [object]$Evidence
    )

    $hasInf = $false
    $infData = Get-MonitorInfIdentityForResolution -Resolution $Resolution -Evidence $Evidence
    if ($null -ne $infData) {
        $hasInf = $true
        if (-not $infData.IsGeneric) {
            $Rows.Add((New-HardwareIdentityRow -Key 'INF Name' -Value $infData.ModelName -Color 'Info'))
        }
        else {
            $Rows.Add((New-HardwareIdentityRow -Key 'INF Name' -Value "$($infData.ModelName) (Generic)" -Color 'Dim'))
        }
    }

    $hasWmi = $false
    $wmi = Get-MonitorWmiIdentityForResolution -Resolution $Resolution -Evidence $Evidence
    if ($null -ne $wmi) {
        $hasWmi = $true
        $friendlyName = [string](Get-NotePropertyValue -Object $wmi -Name 'UserFriendlyName')
        $manufacturerId = [string](Get-NotePropertyValue -Object $wmi -Name 'ManufacturerId')
        $productCode = [string](Get-NotePropertyValue -Object $wmi -Name 'ProductCode')
        $widthCm = Get-NotePropertyValue -Object $wmi -Name 'MaxHorizontalCm'
        $heightCm = Get-NotePropertyValue -Object $wmi -Name 'MaxVerticalCm'
        $videoOutputTech = Get-NotePropertyValue -Object $wmi -Name 'VideoOutputTechnology'
        $timing = Get-NotePropertyValue -Object $wmi -Name 'PreferredTiming'

        $nameAlreadyShown = @($Rows | Where-Object { $_.Key -match 'Name$' -and $_.Value -eq $friendlyName }).Count -gt 0
        if (-not [string]::IsNullOrWhiteSpace($friendlyName) -and -not $nameAlreadyShown) {
            $Rows.Add((New-HardwareIdentityRow -Key 'WMI Name' -Value $friendlyName -Color 'OK'))
        }

        if ($null -ne $videoOutputTech) {
            $portName = Get-VideoOutputTechnologyName -Technology $videoOutputTech
            $Rows.Add((New-HardwareIdentityRow -Key 'Connection' -Value $portName -Color 'White'))
        }

        $hasPanelSize = @($Rows | Where-Object { $_.Key -eq 'Panel Size' }).Count -gt 0
        if (-not $hasPanelSize -and $null -ne $widthCm -and $null -ne $heightCm -and ($widthCm -gt 0 -or $heightCm -gt 0)) {
            $Rows.Add((New-HardwareIdentityRow -Key 'Panel Size' -Value ("{0} x {1} cm" -f $widthCm, $heightCm) -Color 'White'))
        }

        $hasNativeTiming = @($Rows | Where-Object { $_.Key -eq 'Native Timing' }).Count -gt 0
        if (-not $hasNativeTiming -and $null -ne $timing -and $timing.Width -gt 0 -and $timing.Height -gt 0) {
            $timingText = "{0}x{1}" -f $timing.Width, $timing.Height
            if ($null -ne $timing.RefreshRateHz) {
                $timingText = "$timingText @ $($timing.RefreshRateHz)Hz"
            }
            $Rows.Add((New-HardwareIdentityRow -Key 'Native Timing' -Value $timingText -Color 'White'))
        }
    }

    return ($hasInf -or $hasWmi)
}

function Get-HardwareResolutionDetailRows {
    param(
        [object]$Resolution,
        [object]$Evidence
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $lookup = Get-NotePropertyValue -Object $Resolution -Name 'Lookup'
    $fields = Get-NotePropertyValue -Object $Resolution -Name 'Fields'
    $bus = [string](Get-NotePropertyValue -Object $Resolution -Name 'Bus')
    $confidence = [string](Get-NotePropertyValue -Object $Resolution -Name 'Confidence')
    $sourceName = [string](Get-NotePropertyValue -Object $lookup -Name 'Source')
    $matchParts = @($bus, $confidence, $sourceName) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (@($matchParts).Count -gt 0) {
        $rows.Add((New-HardwareIdentityRow -Key 'Local Match' -Value ($matchParts -join ' / ') -Color 'Info'))
    }

    if ($bus -ne 'PCI') {
        $hasEvidence = Add-BoardModelEvidenceRows -Rows $rows -Resolution $Resolution
        if (-not $hasEvidence -and $bus -in @('USB', 'HID')) {
            [void](Add-AlsaUcmAudioProfileRows -Rows $rows -Resolution $Resolution)
            $vendorId = [string](Get-NotePropertyValue -Object $fields -Name 'VendorId')
            $productId = [string](Get-NotePropertyValue -Object $fields -Name 'ProductId')
            $interfaceId = [string](Get-NotePropertyValue -Object $fields -Name 'InterfaceId')
            $productName = [string](Get-NotePropertyValue -Object $lookup -Name 'ProductName')
            $vendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'VendorName')
            $driver = Get-InstalledDriverEvidenceFields -Evidence $Evidence
            $safeVendorName = Get-ShortHardwareVendorName -Name $vendorName
            if (-not [string]::IsNullOrWhiteSpace($safeVendorName) -and -not [string]::IsNullOrWhiteSpace($driver.DeviceName)) {
                $safeKind = $(if ($driver.DeviceName -match '(?i)audio') { 'USB Audio device' } else { 'USB device' })
                $rows.Add((New-HardwareIdentityRow -Key 'Safe Label' -Value "$safeVendorName $safeKind, $($driver.DeviceName) driver" -Color 'White'))
            }
            $busPrefix = $(if ($bus -eq 'HID') { 'HID' } else { 'USB' })
            $tupleHint = ''
            if (-not [string]::IsNullOrWhiteSpace($vendorId) -and -not [string]::IsNullOrWhiteSpace($productId)) {
                $tupleHint = "$busPrefix\VID_$vendorId&PID_$productId"
                if (-not [string]::IsNullOrWhiteSpace($interfaceId)) {
                    $tupleHint = "$tupleHint&MI_$interfaceId"
                }
            }
            $searchParts = @(
                $tupleHint
                (Get-ShortHardwareVendorName -Name $vendorName)
                $productName
                $vendorId
                $productId
                $(if (-not [string]::IsNullOrWhiteSpace($interfaceId)) { "MI_$interfaceId" })
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if ([string]::IsNullOrWhiteSpace($productName)) {
                $rows.Add((New-HardwareIdentityRow -Key 'Coverage' -Value 'No exact product model in local usb.ids' -Color 'Dim'))
            }
            if (@($searchParts).Count -gt 0) {
                $rows.Add((New-HardwareIdentityRow -Key 'Search Hint' -Value (($searchParts | Select-Object -Unique) -join ' ') -Color 'Info'))
            }
        }
        elseif ($bus -eq 'HDAUDIO') {
            $codecName = ''
            $boardProduct = ''
            $boardManufacturer = ''
            $evidence = Get-BoardModelEvidenceForResolution -Resolution $Resolution
            if ($null -ne $evidence) {
                $codecName = [string](Get-NotePropertyValue -Object $evidence -Name 'CodecName')
                $boardProduct = [string](Get-NotePropertyValue -Object $evidence -Name 'BoardProduct')
                $boardManufacturer = [string](Get-NotePropertyValue -Object $evidence -Name 'BoardManufacturer')
            }

            $vendorId = [string](Get-NotePropertyValue -Object $fields -Name 'VendorId')
            $deviceId = [string](Get-NotePropertyValue -Object $fields -Name 'DeviceId')
            $functionId = [string](Get-NotePropertyValue -Object $fields -Name 'FunctionId')
            $subvendorId = [string](Get-NotePropertyValue -Object $fields -Name 'SubvendorId')
            $subdeviceId = [string](Get-NotePropertyValue -Object $fields -Name 'SubdeviceId')
            $controllerVendorId = [string](Get-NotePropertyValue -Object $fields -Name 'ControllerVendorId')
            $controllerDeviceId = [string](Get-NotePropertyValue -Object $fields -Name 'ControllerDeviceId')
            $vendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'VendorName')
            $subvendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'SubvendorName')
            $controllerVendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'ControllerVendorName')
            $controllerDeviceName = [string](Get-NotePropertyValue -Object $lookup -Name 'ControllerDeviceName')

            if (-not [string]::IsNullOrWhiteSpace($codecName)) {
                $rows.Add((New-HardwareIdentityRow -Key 'Codec' -Value $codecName -Color 'OK'))
            }
            if (-not [string]::IsNullOrWhiteSpace($vendorName)) {
                $rows.Add((New-HardwareIdentityRow -Key 'Codec Vendor' -Value (Get-FormattedHardwareVendorName -Name $vendorName) -Color 'Dim'))
            }
            if (-not [string]::IsNullOrWhiteSpace($subvendorName) -or -not [string]::IsNullOrWhiteSpace($subdeviceId)) {
                $subsystemParts = @(
                    (Get-FormattedHardwareVendorName -Name $subvendorName)
                    $(if (-not [string]::IsNullOrWhiteSpace($subvendorId) -or -not [string]::IsNullOrWhiteSpace($subdeviceId)) { "$subvendorId`:$subdeviceId" })
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                $rows.Add((New-HardwareIdentityRow -Key 'Subsystem' -Value (($subsystemParts | Select-Object -Unique) -join ' / ') -Color 'Info'))
            }
            if (-not [string]::IsNullOrWhiteSpace($controllerVendorId) -or -not [string]::IsNullOrWhiteSpace($controllerDeviceId)) {
                $controllerText = @(
                    (Get-FormattedHardwareVendorName -Name $controllerVendorName)
                    $controllerDeviceName
                    $(if (-not [string]::IsNullOrWhiteSpace($controllerVendorId) -or -not [string]::IsNullOrWhiteSpace($controllerDeviceId)) { "$controllerVendorId`:$controllerDeviceId" })
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                $rows.Add((New-HardwareIdentityRow -Key 'Controller' -Value (($controllerText | Select-Object -Unique) -join ' / ') -Color 'Dim'))
            }
            if (-not $hasEvidence) {
                $rows.Add((New-HardwareIdentityRow -Key 'Coverage' -Value 'HDAUDIO codec/subsystem parsed; exact codec model needs board/OEM/open-source evidence' -Color 'Dim'))
            }

            $tupleFunctionId = $(if ([string]::IsNullOrWhiteSpace($functionId)) { '01' } else { $functionId })
            $tupleHint = "HDAUDIO\FUNC_$tupleFunctionId&VEN_$vendorId&DEV_$deviceId"
            if (-not [string]::IsNullOrWhiteSpace($subvendorId) -and -not [string]::IsNullOrWhiteSpace($subdeviceId)) {
                $tupleHint = "$tupleHint&SUBSYS_$subvendorId$subdeviceId"
            }
            $searchParts = @(
                $tupleHint
                (Get-ShortHardwareVendorName -Name $subvendorName)
                $boardManufacturer
                $boardProduct
                $codecName
                $vendorId
                $deviceId
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if (@($searchParts).Count -gt 0) {
                $rows.Add((New-HardwareIdentityRow -Key 'Search Hint' -Value (($searchParts | Select-Object -Unique) -join ' ') -Color 'Info'))
            }
        }
        elseif ($bus -eq 'DISPLAY') {
            $vendorId = [string](Get-NotePropertyValue -Object $fields -Name 'VendorId')
            $productId = [string](Get-NotePropertyValue -Object $fields -Name 'ProductId')
            $vendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'VendorName')
            $hasEdid = Add-MonitorEdidRows -Rows $rows -Resolution $Resolution -Evidence $Evidence
            $hasWmiOrInf = Add-MonitorWmiAndInfRows -Rows $rows -Resolution $Resolution -Evidence $Evidence
            $displayVendor = $(if (-not [string]::IsNullOrWhiteSpace($vendorName)) {
                Get-FormattedHardwareVendorName -Name $vendorName
            } else {
                $vendorId
            })
            if (-not ($hasEdid -or $hasWmiOrInf) -and -not [string]::IsNullOrWhiteSpace($displayVendor)) {
                $rows.Add((New-HardwareIdentityRow -Key 'Display Vendor' -Value $displayVendor -Color 'White'))
            }
            if (-not ($hasEdid -or $hasWmiOrInf) -and -not [string]::IsNullOrWhiteSpace($productId)) {
                $rows.Add((New-HardwareIdentityRow -Key 'EDID Product' -Value $productId -Color 'Info'))
            }
            $coverageText = $(if ($hasEdid -or $hasWmiOrInf) {
                'Registry EDID + WMI + INF'
            } else {
                'DISPLAY ID gives EDID vendor/product code; exact monitor model needs EDID/INF/WMI/OEM evidence'
            })
            $rows.Add((New-HardwareIdentityRow -Key 'Evidence' -Value $coverageText -Color 'Dim'))
            $searchParts = @(
                $(if (-not [string]::IsNullOrWhiteSpace($vendorId) -and -not [string]::IsNullOrWhiteSpace($productId)) { "DISPLAY\$vendorId$productId" })
                $displayVendor
                $vendorId
                $productId
                'monitor'
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if (-not ($hasEdid -or $hasWmiOrInf) -and @($searchParts).Count -gt 0) {
                $rows.Add((New-HardwareIdentityRow -Key 'Search Hint' -Value (($searchParts | Select-Object -Unique) -join ' ') -Color 'Info'))
            }
        }
        elseif ($bus -in @('SCSI', 'USBSTOR', 'IDE')) {
            $deviceTypeName = [string](Get-NotePropertyValue -Object $lookup -Name 'DeviceTypeName')
            $vendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'VendorName')
            $productName = [string](Get-NotePropertyValue -Object $lookup -Name 'ProductName')
            $device = Get-NotePropertyValue -Object $Evidence -Name 'Device'
            $friendlyName = [string](Get-NotePropertyValue -Object $device -Name 'FriendlyName')
            $displayModel = $(if (-not [string]::IsNullOrWhiteSpace($friendlyName)) { $friendlyName } else { $productName })
            if (-not [string]::IsNullOrWhiteSpace($displayModel)) {
                $rows.Add((New-HardwareIdentityRow -Key 'Storage Model' -Value $displayModel -Color 'White'))
            }
            if (-not [string]::IsNullOrWhiteSpace($vendorName)) {
                if ($vendorName -match '^(?i:NVME)$') {
                    $rows.Add((New-HardwareIdentityRow -Key 'Storage Stack' -Value 'NVMe surfaced through Windows SCSI storage stack' -Color 'Dim'))
                }
                else {
                    $rows.Add((New-HardwareIdentityRow -Key 'Storage Vendor' -Value $vendorName -Color 'Dim'))
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($deviceTypeName)) {
                $rows.Add((New-HardwareIdentityRow -Key 'Storage Type' -Value $deviceTypeName -Color 'Dim'))
            }
            $rows.Add((New-HardwareIdentityRow -Key 'Evidence' -Value "Windows $bus storage ID" -Color 'Dim'))
        }
        return @($rows)
    }

    $deviceName = [string](Get-NotePropertyValue -Object $lookup -Name 'DeviceName')
    $subsystemName = [string](Get-NotePropertyValue -Object $lookup -Name 'SubsystemName')
    $subvendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'SubvendorName')
    $vendorId = [string](Get-NotePropertyValue -Object $fields -Name 'VendorId')
    $deviceId = [string](Get-NotePropertyValue -Object $fields -Name 'DeviceId')
    $subvendorId = [string](Get-NotePropertyValue -Object $fields -Name 'SubvendorId')
    $subdeviceId = [string](Get-NotePropertyValue -Object $fields -Name 'SubdeviceId')

    if (-not [string]::IsNullOrWhiteSpace($subsystemName)) {
        $rows.Add((New-HardwareIdentityRow -Key 'Exact Model' -Value $subsystemName -Color 'OK'))
    }

    $hasBoardEvidence = Add-BoardModelEvidenceRows -Rows $rows -Resolution $Resolution

    if (-not $hasBoardEvidence -and [string]::IsNullOrWhiteSpace($subsystemName) -and
        (-not [string]::IsNullOrWhiteSpace($subvendorName) -or -not [string]::IsNullOrWhiteSpace($subdeviceId))) {
        $rows.Add((New-HardwareIdentityRow -Key 'Coverage' -Value 'No exact board model in local pci.ids' -Color 'Dim'))
    }

    $searchParts = @(
        (Get-ShortHardwareVendorName -Name $subvendorName)
        $deviceName
        $subdeviceId
        $subvendorId
        $deviceId
        $vendorId
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (-not $hasBoardEvidence -and [string]::IsNullOrWhiteSpace($subsystemName) -and @($searchParts).Count -gt 0) {
        $rows.Add((New-HardwareIdentityRow -Key 'Search Hint' -Value (($searchParts | Select-Object -Unique) -join ' ') -Color 'Info'))
    }

    return @($rows)
}

function Get-CandidateEvidenceHardwareIds {
    param(
        [object]$Evidence,
        [string]$InstanceId
    )

    $idSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ids = [System.Collections.Generic.List[string]]::new()

    function Add-DeviceCheckHardwareId {
        param([AllowEmptyString()][string]$Value)
        if (-not [string]::IsNullOrWhiteSpace($Value) -and $idSet.Add($Value)) {
            $ids.Add($Value)
        }
    }

    if ($InstanceId -match '^(?i:SCSI|USBSTOR|IDE)\\[A-Z0-9]+&VEN_[^&\\]+&PROD_[^&\\]+') {
        Add-DeviceCheckHardwareId -Value $InstanceId
    }

    $importantProperties = Get-NotePropertyValue -Object $Evidence -Name 'ImportantProperties'
    foreach ($propertyName in @('DEVPKEY_Device_HardwareIds', 'DEVPKEY_Device_CompatibleIds', 'DEVPKEY_Device_MatchingDeviceId')) {
        $propertyValue = Get-NotePropertyValue -Object $importantProperties -Name $propertyName
        foreach ($item in @($propertyValue)) {
            Add-DeviceCheckHardwareId -Value ([string]$item)
        }
    }

    $signedDriver = Get-NotePropertyValue -Object $Evidence -Name 'SignedDriver'
    foreach ($propertyName in @('HardwareID', 'CompatID')) {
        $propertyValue = Get-NotePropertyValue -Object $signedDriver -Name $propertyName
        foreach ($item in @($propertyValue)) {
            Add-DeviceCheckHardwareId -Value ([string]$item)
        }
    }

    Add-DeviceCheckHardwareId -Value $InstanceId
    return @($ids)
}

function Get-LocalHardwareIdentitySummaries {
    param(
        [object]$Evidence,
        [string]$InstanceId,
        [int]$MaxCount = 3
    )

    if ($script:HardwareIdResolverState -ne 'Ready') {
        return @()
    }

    $ids = @(Get-CandidateEvidenceHardwareIds -Evidence $Evidence -InstanceId $InstanceId | Select-Object -First 12)
    if ($ids.Count -eq 0) {
        return @()
    }

    $cacheKey = ($ids | ForEach-Object { [string]$_ }) -join "`n"
    if ($script:HardwareIdResolutionDisplayCache.ContainsKey($cacheKey)) {
        return @($script:HardwareIdResolutionDisplayCache[$cacheKey])
    }

    $summaries = [System.Collections.Generic.List[string]]::new()
    try {
        $resolutions = @(Resolve-HardwareId -HardwareId $ids -Cache $script:HardwareIdDatabaseCache)
        foreach ($resolution in @($resolutions)) {
            $confidence = [string](Get-NotePropertyValue -Object $resolution -Name 'Confidence')
            if ($confidence -in @('UNSUPPORTED', 'NO-ID')) {
                continue
            }

            $displayText = Get-HardwareResolutionDisplayText -Resolution $resolution
            if (-not [string]::IsNullOrWhiteSpace($displayText) -and -not $summaries.Contains($displayText)) {
                $summaries.Add($displayText)
            }
            if ($summaries.Count -ge $MaxCount) {
                break
            }
        }
    }
    catch {
        $script:HardwareIdResolverError = $_.Exception.Message
        $script:HardwareIdResolverState = 'Unavailable'
        return @()
    }

    $script:HardwareIdResolutionDisplayCache[$cacheKey] = @($summaries)
    return @($summaries)
}

function Get-LocalHardwareIdentityRows {
    param(
        [object]$Evidence,
        [string]$InstanceId,
        [int]$MaxCount = 3
    )

    if ($script:HardwareIdResolverState -ne 'Ready') {
        return @()
    }

    $ids = @(Get-CandidateEvidenceHardwareIds -Evidence $Evidence -InstanceId $InstanceId | Select-Object -First 12)
    if ($ids.Count -eq 0) {
        return @()
    }

    $cacheKey = ($ids | ForEach-Object { [string]$_ }) -join "`n"
    if ($script:HardwareIdResolutionDetailCache.ContainsKey($cacheKey)) {
        return @($script:HardwareIdResolutionDetailCache[$cacheKey])
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    try {
        $resolutions = @(Resolve-HardwareId -HardwareId $ids -Cache $script:HardwareIdDatabaseCache)
        foreach ($resolution in @($resolutions)) {
            $confidence = [string](Get-NotePropertyValue -Object $resolution -Name 'Confidence')
            if ($confidence -in @('UNSUPPORTED', 'NO-ID')) {
                continue
            }

            foreach ($row in @(Get-HardwareResolutionDetailRows -Resolution $resolution -Evidence $Evidence)) {
                $duplicate = @($rows | Where-Object { $_.Key -eq $row.Key -and $_.Value -eq $row.Value }).Count -gt 0
                if (-not $duplicate) {
                    $rows.Add($row)
                }
            }

            # Stop after the first successfully resolved hardware ID to avoid duplicate and overlapping rows
            break
        }
    }
    catch {
        $script:HardwareIdResolverError = $_.Exception.Message
        $script:HardwareIdResolverState = 'Unavailable'
        return @()
    }

    $script:HardwareIdResolutionDetailCache[$cacheKey] = @($rows)
    return @($rows)
}

function Get-FirstNonEmptyEvidenceValue {
    param(
        [object[]]$Values
    )

    foreach ($value in @($Values)) {
        foreach ($item in @($value)) {
            if ($null -eq $item) {
                continue
            }

            $text = [string]$item
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                return $text.Trim()
            }
        }
    }

    return ''
}

function Get-InstalledDriverEvidenceFields {
    param(
        [object]$Evidence
    )

    $importantProperties = Get-NotePropertyValue -Object $Evidence -Name 'ImportantProperties'
    $signedDriver = Get-NotePropertyValue -Object $Evidence -Name 'SignedDriver'

    $provider = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $signedDriver -Name 'DriverProviderName'),
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_DriverProvider')
    )
    $version = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $signedDriver -Name 'DriverVersion'),
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_DriverVersion')
    )
    $date = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $signedDriver -Name 'DriverDate'),
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_DriverDate')
    )
    $infName = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $signedDriver -Name 'InfName'),
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_DriverInfPath')
    )
    $deviceName = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $signedDriver -Name 'DeviceName')
    )
    $manufacturer = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $signedDriver -Name 'Manufacturer'),
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_Manufacturer')
    )
    $service = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_Service')
    )
    $driverKey = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_Driver')
    )
    $infSection = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_DriverInfSection')
    )
    $signedDriverError = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $Evidence -Name 'SignedDriverError')
    )

    $hasAny = -not [string]::IsNullOrWhiteSpace((@(
        $provider
        $version
        $date
        $infName
        $deviceName
        $manufacturer
        $service
        $driverKey
        $infSection
        $signedDriverError
    ) -join ''))

    return [PSCustomObject]@{
        HasAny            = $hasAny
        DeviceName        = $deviceName
        Manufacturer      = $manufacturer
        Provider          = $provider
        Version           = $version
        Date              = $date
        InfName           = $infName
        InfSection        = $infSection
        Service           = $service
        DriverKey         = $driverKey
        SignedDriverError = $signedDriverError
    }
}

function Add-InstalledDriverDetailLines {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[string]]$Lines,
        [object]$Evidence,
        [int]$Width
    )

    $driver = Get-InstalledDriverEvidenceFields -Evidence $Evidence
    if (-not $driver.HasAny) {
        return
    }

    $Lines.Add((New-SectionLine -Title 'Installed Driver' -Width $Width))

    if (-not [string]::IsNullOrWhiteSpace($driver.Provider)) {
        Add-KeyValueLines -Lines $Lines -Key 'Provider' -Value $driver.Provider -Width $Width
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.Version)) {
        Add-KeyValueLines -Lines $Lines -Key 'Version' -Value $driver.Version -Width $Width -ValueColor $_C.OK
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.Date)) {
        Add-KeyValueLines -Lines $Lines -Key 'Date' -Value $driver.Date -Width $Width
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.InfName)) {
        Add-KeyValueLines -Lines $Lines -Key 'INF' -Value $driver.InfName -Width $Width -ValueColor $_C.Info
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.InfSection)) {
        Add-KeyValueLines -Lines $Lines -Key 'INF Section' -Value $driver.InfSection -Width $Width -ValueColor $_C.Info
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.Service)) {
        Add-KeyValueLines -Lines $Lines -Key 'Service' -Value $driver.Service -Width $Width
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.DriverKey)) {
        Add-KeyValueLines -Lines $Lines -Key 'Driver Key' -Value $driver.DriverKey -Width $Width -ValueColor $_C.Dim
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.DeviceName)) {
        Add-KeyValueLines -Lines $Lines -Key 'Driver Name' -Value $driver.DeviceName -Width $Width
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.Manufacturer) -and $driver.Manufacturer -ne $driver.Provider) {
        Add-KeyValueLines -Lines $Lines -Key 'Maker' -Value $driver.Manufacturer -Width $Width
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.SignedDriverError)) {
        Add-KeyValueLines -Lines $Lines -Key 'Driver CIM' -Value $driver.SignedDriverError -Width $Width -ValueColor $_C.Warn
    }
}

function Get-SdioCandidateColor {
    param($Candidate)

    $labels = @(Get-NotePropertyValue -Object $Candidate -Name 'StatusLabels')
    if ($labels -contains 'BETTER' -or $labels -contains 'NEW') { return $_C.OK }
    if ($labels -contains 'WORSE' -or $labels -contains 'INVALID') { return $_C.Warn }
    if ($labels -contains 'CURRENT' -or $labels -contains 'SAME') { return $_C.Info }
    return $_C.White
}

function Add-SdioDriverMatchDetailLines {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[string]]$Lines,
        [string]$InstanceId,
        [int]$Width,
        [int]$MaxCandidates = 3
    )

    $audit = Read-CachedSdioAudit -InstanceId $InstanceId
    if ($null -eq $audit) {
        return
    }

    $devices = @(Get-NotePropertyValue -Object $audit -Name 'Devices')
    if ($devices.Count -eq 0) {
        return
    }

    $device = $devices | Where-Object { [int](Get-NotePropertyValue -Object $_ -Name 'CandidateCount') -gt 0 } | Select-Object -First 1
    if ($null -eq $device) {
        $device = $devices | Select-Object -First 1
    }

    $candidates = @(Get-NotePropertyValue -Object $device -Name 'Candidates')
    if ($candidates.Count -eq 0) {
        return
    }

    $Lines.Add((New-SectionLine -Title 'SDIO Matches' -Width $Width))

    $generatedAt = [string](Get-NotePropertyValue -Object $audit -Name 'GeneratedAt')
    if (-not [string]::IsNullOrWhiteSpace($generatedAt)) {
        Add-KeyValueLines -Lines $Lines -Key 'Audit' -Value $generatedAt -Width $Width -ValueColor $_C.Dim
    }

    $candidateCount = [int](Get-NotePropertyValue -Object $device -Name 'CandidateCount')
    if ($candidateCount -gt 0) {
        Add-KeyValueLines -Lines $Lines -Key 'Candidates' -Value "$candidateCount indexed matches" -Width $Width -ValueColor $_C.Info
    }

    $installed = Get-NotePropertyValue -Object $device -Name 'Installed'
    $installedHardwareId = [string](Get-NotePropertyValue -Object $installed -Name 'HardwareId')
    if (-not [string]::IsNullOrWhiteSpace($installedHardwareId)) {
        Add-KeyValueLines -Lines $Lines -Key 'Installed ID' -Value $installedHardwareId -Width $Width -ValueColor $_C.Info
    }

    $warnings = @(Get-NotePropertyValue -Object $audit -Name 'Warning')
    if ($warnings.Count -gt 0) {
        Add-KeyValueLines -Lines $Lines -Key 'Caution' -Value ([string]$warnings[0]) -Width $Width -ValueColor $_C.Warn
    }

    $index = 1
    foreach ($candidate in @($candidates | Select-Object -First $MaxCandidates)) {
        $labels = @(Get-NotePropertyValue -Object $candidate -Name 'StatusLabels') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        $statusText = $(if ($labels.Count -gt 0) { $labels -join '+' } else { [string](Get-NotePropertyValue -Object $candidate -Name 'Status') })
        $matchKind = [string](Get-NotePropertyValue -Object $candidate -Name 'MatchKind')
        if ([string]::IsNullOrWhiteSpace($matchKind)) { $matchKind = 'Unknown' }
        $candidateColor = Get-SdioCandidateColor -Candidate $candidate

        Add-KeyValueLines -Lines $Lines -Key "#$index" -Value "$matchKind / $statusText" -Width $Width -ValueColor $candidateColor

        $version = [string](Get-NotePropertyValue -Object $candidate -Name 'Version')
        $date = [string](Get-NotePropertyValue -Object $candidate -Name 'Date')
        $versionText = (@($version, $date) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' / '
        if (-not [string]::IsNullOrWhiteSpace($versionText)) {
            Add-KeyValueLines -Lines $Lines -Key 'Version' -Value $versionText -Width $Width -ValueColor $_C.OK
        }

        $description = [string](Get-NotePropertyValue -Object $candidate -Name 'Description')
        if (-not [string]::IsNullOrWhiteSpace($description)) {
            Add-KeyValueLines -Lines $Lines -Key 'Name' -Value $description -Width $Width
        }

        $hardwareId = [string](Get-NotePropertyValue -Object $candidate -Name 'HardwareId')
        if (-not [string]::IsNullOrWhiteSpace($hardwareId)) {
            Add-KeyValueLines -Lines $Lines -Key 'INF HWID' -Value $hardwareId -Width $Width -ValueColor $_C.Info
        }

        $infFile = [string](Get-NotePropertyValue -Object $candidate -Name 'InfFile')
        if (-not [string]::IsNullOrWhiteSpace($infFile)) {
            Add-KeyValueLines -Lines $Lines -Key 'INF' -Value $infFile -Width $Width -ValueColor $_C.Dim
        }

        $packName = [string](Get-NotePropertyValue -Object $candidate -Name 'PackName')
        if (-not [string]::IsNullOrWhiteSpace($packName)) {
            Add-KeyValueLines -Lines $Lines -Key 'Pack' -Value (Split-Path -Path $packName -Leaf) -Width $Width -ValueColor $_C.Dim
        }

        $index++
    }
}

function Get-SdioAuditCachePath {
    param([string]$InstanceId)

    $deviceHash = New-DeviceCheckHash -Text $InstanceId
    return (Join-Path -Path $script:MachineCacheRoot -ChildPath "sdio-audit\$deviceHash.json")
}

function Get-DeviceEvidenceCachePath {
    param([string]$InstanceId)

    $deviceHash = New-DeviceCheckHash -Text $InstanceId
    return (Join-Path -Path $script:MachineCacheRoot -ChildPath "devices\$deviceHash.json")
}

function New-AgentTracePath {
    param([string]$InstanceId)

    $deviceHash = New-DeviceCheckHash -Text $InstanceId
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    return (Join-Path -Path $script:MachineCacheRoot -ChildPath "agent-logs\$deviceHash-$stamp.jsonl")
}

function New-AgentCheckpointPath {
    param([string]$InstanceId)

    $deviceHash = New-DeviceCheckHash -Text $InstanceId
    return (Join-Path -Path $script:MachineCacheRoot -ChildPath "agent-state\$deviceHash.json")
}

function New-AgentToolCacheRoot {
    return (Join-Path -Path $script:MachineCacheRoot -ChildPath 'agent-tool-cache')
}

function Read-CachedDeviceEvidence {
    param([string]$InstanceId)

    # In-memory cache: avoid disk I/O + JSON parse on every render frame
    if ($script:EvidenceCacheMemory.ContainsKey($InstanceId)) {
        return $script:EvidenceCacheMemory[$InstanceId]
    }

    $cachePath = Get-DeviceEvidenceCachePath -InstanceId $InstanceId
    if (-not (Test-Path -LiteralPath $cachePath)) { return $null }

    try {
        $parsed = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
        $script:EvidenceCacheMemory[$InstanceId] = $parsed
        return $parsed
    } catch {
        return $null
    }
}

function Read-CachedSdioAudit {
    param([string]$InstanceId)

    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return $null }
    if ($script:SdioAuditCacheMemory.ContainsKey($InstanceId)) {
        return $script:SdioAuditCacheMemory[$InstanceId]
    }

    $cachePath = Get-SdioAuditCachePath -InstanceId $InstanceId
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { return $null }

    try {
        $parsed = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
        $script:SdioAuditCacheMemory[$InstanceId] = $parsed
        return $parsed
    } catch {
        return $null
    }
}

function Invalidate-EvidenceCache {
    param([string]$InstanceId)

    if (-not [string]::IsNullOrWhiteSpace($InstanceId)) {
        $script:EvidenceCacheMemory.Remove($InstanceId)
        $script:SdioAuditCacheMemory.Remove($InstanceId)
    } else {
        $script:EvidenceCacheMemory.Clear()
        $script:SdioAuditCacheMemory.Clear()
    }
}
