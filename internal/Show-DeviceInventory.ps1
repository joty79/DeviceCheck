[CmdletBinding()]
param(
    [ValidateSet('Quick', 'Full')]
    [string]$Mode = 'Quick',

    [switch]$AllDevices,

    [switch]$ProblemsOnly,

    [string]$CacheRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data\hwdb'),

    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'devices'),

    [switch]$NoReport,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'HardwareIdResolver.psm1') -Force

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

function Get-PnpPropertyValueSafe {
    param(
        [string]$InstanceId,
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

function Get-InventoryGroupName {
    param(
        [AllowEmptyString()]
        [string]$Class,
        [AllowEmptyString()]
        [string]$InstanceId
    )

    $classValue = if ($null -eq $Class) { '' } else { $Class }
    $instanceValue = if ($null -eq $InstanceId) { '' } else { $InstanceId }
    $classValue = $classValue.Trim()
    $instanceValue = $instanceValue.Trim().ToUpperInvariant()

    switch -Regex ($classValue) {
        '^(?i:Display|MEDIA|Camera|Image)$' { return 'Display / Media' }
        '^(?i:Net|Bluetooth)$' { return 'Network / Bluetooth' }
        '^(?i:HDC|SCSIAdapter|DiskDrive|CDROM|Volume|Storage)$' { return 'Storage' }
        '^(?i:USB|HIDClass|Keyboard|Mouse|Biometric)$' { return 'USB / HID / Input' }
        '^(?i:System|Computer|Processor|Firmware|SoftwareDevice)$' { return 'System / Firmware' }
        '^(?i:Ports|Modem)$' { return 'Ports / Serial' }
    }

    if ($instanceValue -match '^(USB|HID)\\') {
        return 'USB / HID / Input'
    }
    if ($instanceValue -match '^PCI\\') {
        return 'PCI / Internal'
    }
    if ($instanceValue -match '^ACPI\\|\*PNP') {
        return 'System / ACPI'
    }
    if ($instanceValue -match '^(SWD|ROOT|BTH|BTHENUM)\\') {
        return 'Software / Virtual'
    }

    return 'Other'
}

function Test-DeviceNeedsAttention {
    param(
        [object]$Device
    )

    $status = [string]$Device.Status
    $problem = [string]$Device.Problem
    $friendlyName = [string]$Device.FriendlyName

    if (
        -not [string]::IsNullOrWhiteSpace($problem) -and
        $problem -notin @('0', 'CM_PROB_NONE')
    ) {
        return $true
    }
    if (-not [string]::IsNullOrWhiteSpace($status) -and $status -notmatch '^(?i:OK|Unknown)$') {
        return $true
    }
    if ($friendlyName -match '(?i)\bunknown\b|base system device|other device') {
        return $true
    }

    return $false
}

function Get-DeviceAttentionCategory {
    param(
        [object]$Device
    )

    $status = [string]$Device.Status
    $problem = [string]$Device.Problem
    $friendlyName = [string]$Device.FriendlyName

    if ($problem -eq 'CM_PROB_DISABLED') {
        return 'Disabled'
    }
    if (-not [string]::IsNullOrWhiteSpace($problem) -and $problem -notin @('0', 'CM_PROB_NONE')) {
        return 'Problem'
    }
    if (-not [string]::IsNullOrWhiteSpace($status) -and $status -notmatch '^(?i:OK|Unknown)$') {
        return $status
    }
    if ($friendlyName -match '(?i)\bunknown\b|base system device|other device') {
        return 'UnknownName'
    }

    return 'Healthy'
}

function Get-DeviceClassification {
    param(
        [AllowEmptyString()]
        [string]$FriendlyName,
        [AllowEmptyString()]
        [string]$Class,
        [AllowEmptyString()]
        [string]$InstanceId,
        [AllowEmptyString()]
        [string]$Problem,
        [AllowEmptyString()]
        [string]$Status,
        [AllowEmptyString()]
        [string]$DriverProviderName,
        [AllowEmptyString()]
        [string]$InfName,
        [object]$BestResolution
    )

    $classValue = if ($null -eq $Class) { '' } else { $Class.Trim() }
    $instanceValue = if ($null -eq $InstanceId) { '' } else { $InstanceId.Trim().ToUpperInvariant() }
    $problemValue = if ($null -eq $Problem) { '' } else { $Problem.Trim() }
    $statusValue = if ($null -eq $Status) { '' } else { $Status.Trim() }
    $providerValue = if ($null -eq $DriverProviderName) { '' } else { $DriverProviderName.Trim() }
    $infValue = if ($null -eq $InfName) { '' } else { $InfName.Trim() }
    $nameValue = if ($null -eq $FriendlyName) { '' } else { $FriendlyName.Trim() }

    $deviceKind = 'Other'
    if ($instanceValue -match '^PCI\\') {
        $deviceKind = 'PhysicalPci'
    }
    elseif ($instanceValue -match '^(USB|HID)\\') {
        $deviceKind = 'PhysicalUsbHid'
    }
    elseif ($instanceValue -match '^(BTH|BTHENUM)\\') {
        $deviceKind = 'PhysicalBluetooth'
    }
    elseif ($instanceValue -match '^ACPI\\VEN_[A-Z0-9]{3,4}&DEV_') {
        $deviceKind = 'FirmwareAcpi'
    }
    elseif ($instanceValue -match '^ACPI\\PNP') {
        $deviceKind = 'LegacySystemAcpi'
    }
    elseif ($instanceValue -match '^(ROOT|SWD)\\') {
        $deviceKind = 'SoftwareVirtual'
    }
    elseif ($classValue -match '^(?i:Firmware)$') {
        $deviceKind = 'Firmware'
    }
    elseif ($classValue -match '^(?i:System|Computer|Processor)$') {
        $deviceKind = 'SystemResource'
    }

    $attentionCategory = Get-DeviceAttentionCategory -Device ([pscustomobject]@{
        Status = $statusValue
        Problem = $problemValue
        FriendlyName = $nameValue
    })

    $researchReasons = [System.Collections.Generic.List[string]]::new()
    $priority = 'None'
    $problemIsActionable = -not [string]::IsNullOrWhiteSpace($problemValue) -and $problemValue -notin @('0', 'CM_PROB_NONE')
    $statusIsActionable = -not [string]::IsNullOrWhiteSpace($statusValue) -and $statusValue -notmatch '^(?i:OK|Unknown)$'
    $unknownName = $nameValue -match '(?i)\bunknown\b|base system device|other device'
    $isMicrosoftInbox = $providerValue -match '^(?i:Microsoft|Windows Hello Face)$' -or $infValue -match '^(?i:machine\.inf|kdnic\.inf|compositebus\.inf|wsynth3dvsp\.inf)$'

    if ($unknownName) {
        $priority = 'High'
        $researchReasons.Add('Unknown device name')
    }
    elseif ($deviceKind -in @('PhysicalPci', 'PhysicalUsbHid', 'PhysicalBluetooth')) {
        if ($problemIsActionable -or $statusIsActionable) {
            $priority = if ($problemValue -eq 'CM_PROB_DISABLED') { 'Medium' } else { 'High' }
            $researchReasons.Add('Physical device has actionable Windows state')
        }
    }
    elseif ($deviceKind -eq 'FirmwareAcpi') {
        if ($problemIsActionable -or $statusIsActionable) {
            $priority = 'Medium'
            $researchReasons.Add('ACPI firmware device may need OEM/chipset driver research')
        }
    }
    elseif ($deviceKind -eq 'LegacySystemAcpi') {
        if (($problemIsActionable -or $statusIsActionable) -and -not $isMicrosoftInbox) {
            $priority = 'Low'
            $researchReasons.Add('Legacy ACPI device is not clearly Microsoft inbox handled')
        }
        else {
            $researchReasons.Add('Legacy ACPI system resource; usually not a driver search target')
        }
    }
    elseif ($deviceKind -eq 'SoftwareVirtual') {
        if (($problemIsActionable -or $statusIsActionable) -and -not $isMicrosoftInbox) {
            $priority = 'Low'
            $researchReasons.Add('Virtual/software device has non-inbox driver metadata')
        }
        else {
            $researchReasons.Add('Software/virtual device; usually not a hardware driver search target')
        }
    }

    if ($null -ne $BestResolution -and [string]$BestResolution.Confidence -in @('UNSUPPORTED', 'NO-ID') -and $priority -ne 'None') {
        $researchReasons.Add("Weak lookup confidence: $($BestResolution.Confidence)")
    }

    [pscustomobject]@{
        DeviceKind = $deviceKind
        AttentionCategory = $attentionCategory
        DriverResearchPriority = $priority
        NeedsDriverResearch = $priority -in @('High', 'Medium')
        DriverResearchReasons = @($researchReasons)
    }
}

function Get-ResolutionRank {
    param(
        [AllowEmptyString()]
        [string]$Confidence
    )

    switch ($Confidence) {
        'EXACT-SUBSYSTEM' { return 100 }
        'EXACT-INTERFACE' { return 95 }
        'EXACT-DEVICE' { return 90 }
        'EXACT-PRODUCT' { return 90 }
        'VENDOR-ONLY' { return 50 }
        'PARSED-ONLY' { return 25 }
        default { return 0 }
    }
}

function Get-BestResolution {
    param(
        [object[]]$Resolutions
    )

    $best = $null
    $bestRank = -1
    foreach ($resolution in @($Resolutions)) {
        $rank = Get-ResolutionRank -Confidence ([string]$resolution.Confidence)
        if ($rank -gt $bestRank) {
            $best = $resolution
            $bestRank = $rank
        }
    }

    return $best
}

function Get-ResolutionDisplayName {
    param(
        [object]$Resolution
    )

    if ($null -eq $Resolution) {
        return ''
    }

    foreach ($propertyName in @('SubsystemName', 'DeviceName', 'ProductName', 'InterfaceName', 'VendorName')) {
        $property = $Resolution.Lookup.PSObject.Properties[$propertyName]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    return ''
}

function New-InventoryDevice {
    param(
        [object]$Device,
        [object]$SignedDriver,
        [string]$Mode,
        [string]$CacheRoot,
        [object]$Cache
    )

    $instanceId = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'InstanceId' -DefaultValue '')
    $friendlyName = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'FriendlyName' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($friendlyName)) {
        $friendlyName = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'Name' -DefaultValue '')
    }

    $class = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'Class' -DefaultValue '')
    $status = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'Status' -DefaultValue '')
    $problem = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'Problem' -DefaultValue '')
    $present = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'Present' -DefaultValue '')

    $hardwareIds = ''
    $compatibleIds = ''
    $matchingDeviceId = ''
    $serviceName = ''
    $infName = ''
    $driverInfSection = ''
    $driverKey = ''
    $classGuid = ''
    $enumeratorName = ''
    $parent = ''
    $manufacturer = ''
    $driverProviderName = ''
    $driverVersion = ''
    $driverDate = ''
    $driverName = ''

    if ($null -ne $SignedDriver) {
        $infName = [string](Get-ObjectPropertyValue -InputObject $SignedDriver -PropertyName 'InfName' -DefaultValue '')
        $driverName = [string](Get-ObjectPropertyValue -InputObject $SignedDriver -PropertyName 'DriverName' -DefaultValue '')
        $manufacturer = [string](Get-ObjectPropertyValue -InputObject $SignedDriver -PropertyName 'Manufacturer' -DefaultValue '')
        $driverProviderName = [string](Get-ObjectPropertyValue -InputObject $SignedDriver -PropertyName 'DriverProviderName' -DefaultValue '')
        $serviceName = [string](Get-ObjectPropertyValue -InputObject $SignedDriver -PropertyName 'Service' -DefaultValue '')
        $classGuid = [string](Get-ObjectPropertyValue -InputObject $SignedDriver -PropertyName 'ClassGuid' -DefaultValue '')
        $driverVersion = [string](Get-ObjectPropertyValue -InputObject $SignedDriver -PropertyName 'DriverVersion' -DefaultValue '')
        $driverDate = [string](Get-ObjectPropertyValue -InputObject $SignedDriver -PropertyName 'DriverDate' -DefaultValue '')
    }

    if ($Mode -eq 'Full') {
        $hardwareIds = Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_HardwareIds'
        $compatibleIds = Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_CompatibleIds'
        $matchingDeviceId = Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_MatchingDeviceId'
        $driverInfSection = Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_DriverInfSection'
        $driverKey = Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_Driver'
        $enumeratorName = Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_EnumeratorName'
        $parent = Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_Parent'

        if ([string]::IsNullOrWhiteSpace($infName)) {
            $infName = Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_DriverInfPath'
        }
        if ([string]::IsNullOrWhiteSpace($serviceName)) {
            $serviceName = Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_Service'
        }
        if ([string]::IsNullOrWhiteSpace($classGuid)) {
            $classGuid = Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_ClassGuid'
        }
        if ([string]::IsNullOrWhiteSpace($manufacturer)) {
            $manufacturer = Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_Manufacturer'
        }
        if ([string]::IsNullOrWhiteSpace($driverProviderName)) {
            $driverProviderName = Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_DriverProvider'
        }
        if ([string]::IsNullOrWhiteSpace($driverVersion)) {
            $driverVersion = Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_DriverVersion'
        }
        if ([string]::IsNullOrWhiteSpace($driverDate)) {
            $driverDate = Get-PnpPropertyValueSafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_DriverDate'
        }
    }

    $candidateIds = @(Split-DeviceIdList -Values @($instanceId, $matchingDeviceId, $hardwareIds, $compatibleIds))
    $resolutions = @()
    if ($candidateIds.Count -gt 0) {
        $resolutions = @(Resolve-HardwareId -HardwareId $candidateIds -CacheRoot $CacheRoot -Cache $Cache)
    }

    $bestResolution = Get-BestResolution -Resolutions $resolutions
    if ($null -eq $bestResolution) {
        $bestResolution = [pscustomobject]@{
            Input = ''
            Normalized = ''
            Bus = 'UNKNOWN'
            IdType = 'NO_ID'
            Fields = [pscustomobject]@{}
            Confidence = 'NO-ID'
            Lookup = [pscustomobject]@{ Source = '' }
            Notes = @('No hardware ID was available for this device.')
        }
    }

    $groupName = Get-InventoryGroupName -Class $class -InstanceId $instanceId
    $bestName = Get-ResolutionDisplayName -Resolution $bestResolution
    $classification = Get-DeviceClassification -FriendlyName $friendlyName -Class $class -InstanceId $instanceId -Problem $problem -Status $status -DriverProviderName $driverProviderName -InfName $infName -BestResolution $bestResolution

    $inventoryDevice = [pscustomobject]@{
        FriendlyName = $friendlyName
        Group = $groupName
        DeviceKind = $classification.DeviceKind
        AttentionCategory = $classification.AttentionCategory
        DriverResearchPriority = $classification.DriverResearchPriority
        NeedsDriverResearch = $classification.NeedsDriverResearch
        DriverResearchReasons = @($classification.DriverResearchReasons)
        Class = $class
        Status = $status
        Problem = $problem
        Present = $present
        InstanceId = $instanceId
        HardwareIds = @(Split-DeviceIdList -Values @($hardwareIds))
        CompatibleIds = @(Split-DeviceIdList -Values @($compatibleIds))
        MatchingDeviceId = $matchingDeviceId
        ServiceName = $serviceName
        InfName = $infName
        DriverName = $driverName
        DriverInfSection = $driverInfSection
        DriverKey = $driverKey
        ClassGuid = $classGuid
        EnumeratorName = $enumeratorName
        Parent = $parent
        Manufacturer = $manufacturer
        DriverProviderName = $driverProviderName
        DriverVersion = $driverVersion
        DriverDate = $driverDate
        CandidateHardwareIds = $candidateIds
        BestResolutionName = $bestName
        BestResolution = $bestResolution
        Resolutions = $resolutions
        NeedsAttention = $false
    }

    $inventoryDevice.NeedsAttention = Test-DeviceNeedsAttention -Device $inventoryDevice
    return $inventoryDevice
}

function Get-DeviceInventory {
    param(
        [string]$Mode,
        [switch]$AllDevices,
        [switch]$ProblemsOnly,
        [string]$CacheRoot
    )

    $presentOnly = -not [bool]$AllDevices
    $devices = @(Get-PnpDevice -PresentOnly:$presentOnly -ErrorAction SilentlyContinue)
    $signedDriverMap = @{}
    $cache = Import-HardwareIdDatabaseCache -CacheRoot $CacheRoot

    foreach ($signedDriver in @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue)) {
        $deviceId = [string](Get-ObjectPropertyValue -InputObject $signedDriver -PropertyName 'DeviceID' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($deviceId) -and -not $signedDriverMap.ContainsKey($deviceId)) {
            $signedDriverMap[$deviceId] = $signedDriver
        }
    }

    $inventoryDevices = [System.Collections.Generic.List[object]]::new()
    $deviceCount = $devices.Count

    for ($deviceIndex = 0; $deviceIndex -lt $deviceCount; $deviceIndex++) {
        $device = $devices[$deviceIndex]
        $instanceId = [string](Get-ObjectPropertyValue -InputObject $device -PropertyName 'InstanceId' -DefaultValue '')
        $signedDriver = if ($signedDriverMap.ContainsKey($instanceId)) { $signedDriverMap[$instanceId] } else { $null }
        $inventoryDevice = New-InventoryDevice -Device $device -SignedDriver $signedDriver -Mode $Mode -CacheRoot $CacheRoot -Cache $cache
        if ($ProblemsOnly -and -not $inventoryDevice.NeedsAttention) {
            continue
        }

        $inventoryDevices.Add($inventoryDevice)

        if ((($deviceIndex + 1) % 20) -eq 0 -or ($deviceIndex + 1) -eq $deviceCount) {
            $percentComplete = [math]::Round((($deviceIndex + 1) / [Math]::Max(1, $deviceCount)) * 100, 0)
            Write-Progress -Id 1 -Activity 'Build Device Inventory' -Status ("{0}/{1} devices" -f ($deviceIndex + 1), $deviceCount) -PercentComplete $percentComplete
        }
    }

    Write-Progress -Id 1 -Activity 'Build Device Inventory' -Completed
    return @($inventoryDevices | Sort-Object @{ Expression = 'NeedsAttention'; Descending = $true }, Group, FriendlyName, InstanceId)
}

function New-InventoryEnvelope {
    param(
        [object[]]$Devices,
        [string]$Mode,
        [bool]$AllDevices,
        [bool]$ProblemsOnly,
        [string]$CacheRoot
    )

    $groupCounts = [ordered]@{}
    foreach ($group in @($Devices | Group-Object Group | Sort-Object Name)) {
        $groupCounts[$group.Name] = $group.Count
    }
    $kindCounts = [ordered]@{}
    foreach ($kind in @($Devices | Group-Object DeviceKind | Sort-Object Name)) {
        $kindCounts[$kind.Name] = $kind.Count
    }
    $researchCounts = [ordered]@{}
    foreach ($priority in @($Devices | Group-Object DriverResearchPriority | Sort-Object Name)) {
        $researchCounts[$priority.Name] = $priority.Count
    }

    [ordered]@{
        SchemaVersion = 1
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Mode = $Mode
        PresentOnly = -not $AllDevices
        ProblemsOnly = $ProblemsOnly
        CacheRoot = (Resolve-Path -LiteralPath $CacheRoot).ProviderPath
        Counts = [ordered]@{
            Devices = @($Devices).Count
            NeedsAttention = @($Devices | Where-Object { $_.NeedsAttention }).Count
            NeedsDriverResearch = @($Devices | Where-Object { $_.NeedsDriverResearch }).Count
            Groups = [pscustomobject]$groupCounts
            DeviceKinds = [pscustomobject]$kindCounts
            DriverResearchPriorities = [pscustomobject]$researchCounts
        }
        Devices = $Devices
    }
}

function ConvertTo-MarkdownInventoryReport {
    param(
        [object]$Inventory
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Device Inventory')
    $lines.Add('')
    $lines.Add(("- Generated UTC: {0}" -f $Inventory.GeneratedAtUtc))
    $lines.Add(("- Mode: {0}" -f $Inventory.Mode))
    $lines.Add(("- Present only: {0}" -f $Inventory.PresentOnly))
    $lines.Add(("- Problems only: {0}" -f $Inventory.ProblemsOnly))
    $lines.Add(("- Devices: {0}" -f $Inventory.Counts.Devices))
    $lines.Add(("- Needs attention: {0}" -f $Inventory.Counts.NeedsAttention))
    $lines.Add(("- Needs driver research: {0}" -f $Inventory.Counts.NeedsDriverResearch))
    $lines.Add('')

    foreach ($group in @($Inventory.Devices | Group-Object Group | Sort-Object Name)) {
        $lines.Add(("## {0} ({1})" -f $group.Name, $group.Count))
        $lines.Add('')

        foreach ($device in @($group.Group | Sort-Object @{ Expression = 'NeedsAttention'; Descending = $true }, FriendlyName, InstanceId)) {
            $attention = if ($device.NeedsAttention) { ' ATTENTION' } else { '' }
            $title = if ([string]::IsNullOrWhiteSpace([string]$device.FriendlyName)) { $device.InstanceId } else { $device.FriendlyName }
            $lines.Add(("### {0}{1}" -f $title, $attention))
            $lines.Add('')
            $lines.Add(('- Status: `{0}`  Problem: `{1}`  Class: `{2}`' -f $device.Status, $device.Problem, $device.Class))
            $lines.Add(('- Device kind: `{0}`  Attention: `{1}`  Driver research: `{2}`' -f $device.DeviceKind, $device.AttentionCategory, $device.DriverResearchPriority))
            $lines.Add(('- InstanceId: `{0}`' -f $device.InstanceId))
            $lines.Add(('- Best match: `{0}` / `{1}` / `{2}`' -f $device.BestResolution.Bus, $device.BestResolution.Confidence, $device.BestResolutionName))
            if (@($device.DriverResearchReasons).Count -gt 0) {
                $lines.Add(('- Research notes: {0}' -f (@($device.DriverResearchReasons) -join '; ')))
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$device.InfName) -or -not [string]::IsNullOrWhiteSpace([string]$device.DriverProviderName)) {
                $lines.Add(('- Driver: INF `{0}`, provider `{1}`, version `{2}`, date `{3}`' -f $device.InfName, $device.DriverProviderName, $device.DriverVersion, $device.DriverDate))
            }

            if (@($device.CandidateHardwareIds).Count -gt 0) {
                $lines.Add('- Candidate IDs:')
                foreach ($candidateId in @($device.CandidateHardwareIds | Select-Object -First 8)) {
                    $lines.Add(('  - `{0}`' -f $candidateId))
                }
            }

            $lines.Add('')
        }
    }

    return ($lines -join [Environment]::NewLine)
}

function Write-InventorySummary {
    param(
        [object]$Inventory
    )

    Write-Host 'Device Inventory' -ForegroundColor Cyan
    Write-Host '----------------' -ForegroundColor Cyan
    Write-Host ("Mode            : {0}" -f $Inventory.Mode) -ForegroundColor DarkGray
    Write-Host ("Present only    : {0}" -f $Inventory.PresentOnly) -ForegroundColor DarkGray
    Write-Host ("Devices         : {0}" -f $Inventory.Counts.Devices) -ForegroundColor Cyan
    Write-Host ("Needs attention : {0}" -f $Inventory.Counts.NeedsAttention) -ForegroundColor $(if ($Inventory.Counts.NeedsAttention -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host ("Driver research : {0}" -f $Inventory.Counts.NeedsDriverResearch) -ForegroundColor $(if ($Inventory.Counts.NeedsDriverResearch -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host ''

    $attentionDevices = @($Inventory.Devices | Where-Object { $_.NeedsAttention } | Select-Object -First 12)
    if ($attentionDevices.Count -gt 0) {
        Write-Host 'Needs Attention' -ForegroundColor Yellow
        Write-Host '---------------' -ForegroundColor Yellow
        foreach ($device in $attentionDevices) {
            $bestName = if ([string]::IsNullOrWhiteSpace([string]$device.BestResolutionName)) { 'unresolved' } else { $device.BestResolutionName }
            Write-Host ("- {0}" -f $device.FriendlyName) -ForegroundColor Yellow
            Write-Host ("  {0} / {1} / {2} / research {3}" -f $device.Class, $device.Status, $device.DeviceKind, $device.DriverResearchPriority) -ForegroundColor DarkGray
            Write-Host ("  {0}" -f $bestName) -ForegroundColor DarkCyan
        }
        Write-Host ''
    }

    Write-Host 'Groups' -ForegroundColor Cyan
    Write-Host '------' -ForegroundColor Cyan
    foreach ($groupProperty in @($Inventory.Counts.Groups.PSObject.Properties | Sort-Object Name)) {
        Write-Host ("{0,-24} {1,5}" -f $groupProperty.Name, $groupProperty.Value) -ForegroundColor DarkGray
    }
}

function Save-InventoryReports {
    param(
        [object]$Inventory,
        [string]$OutputRoot
    )

    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $baseName = "device-inventory-$timestamp"
    $jsonPath = Join-Path $OutputRoot "$baseName.json"
    $markdownPath = Join-Path $OutputRoot "$baseName.md"

    $Inventory | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    ConvertTo-MarkdownInventoryReport -Inventory $Inventory | Set-Content -LiteralPath $markdownPath -Encoding UTF8

    [pscustomobject]@{
        JsonPath = $jsonPath
        MarkdownPath = $markdownPath
    }
}

$inventoryDevices = @(Get-DeviceInventory -Mode $Mode -AllDevices:$AllDevices -ProblemsOnly:$ProblemsOnly -CacheRoot $CacheRoot)
$inventory = New-InventoryEnvelope -Devices $inventoryDevices -Mode $Mode -AllDevices ([bool]$AllDevices) -ProblemsOnly ([bool]$ProblemsOnly) -CacheRoot $CacheRoot

if ($AsJson) {
    $inventory | ConvertTo-Json -Depth 32
    return
}

Write-InventorySummary -Inventory $inventory

if (-not $NoReport) {
    $reports = Save-InventoryReports -Inventory $inventory -OutputRoot $OutputRoot
    Write-Host ''
    Write-Host 'Reports' -ForegroundColor Green
    Write-Host ("JSON     : {0}" -f $reports.JsonPath) -ForegroundColor DarkGray
    Write-Host ("Markdown : {0}" -f $reports.MarkdownPath) -ForegroundColor DarkGray
}
