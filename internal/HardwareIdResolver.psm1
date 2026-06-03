Set-StrictMode -Version Latest

function Get-JsonObjectPropertyValue {
    param(
        [object]$InputObject,
        [string]$PropertyName
    )

    if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace($PropertyName)) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-HardwareIdCacheRoot {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return (Join-Path $repoRoot 'data\hwdb')
}

function Import-HardwareIdDatabaseCache {
    param(
        [string]$CacheRoot = (Get-HardwareIdCacheRoot)
    )

    $normalizedRoot = Join-Path $CacheRoot 'normalized'
    $requiredFiles = [ordered]@{
        Pci = Join-Path $normalizedRoot 'pci.json'
        Usb = Join-Path $normalizedRoot 'usb.json'
        Pnp = Join-Path $normalizedRoot 'pnp.json'
    }

    foreach ($fileKey in $requiredFiles.Keys) {
        $filePath = $requiredFiles[$fileKey]
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "Missing hardware ID cache file: $filePath. Run internal\Update-HardwareIdDatabases.ps1 first."
        }
    }

    [pscustomobject]@{
        CacheRoot = (Resolve-Path -LiteralPath $CacheRoot).ProviderPath
        Pci = Get-Content -LiteralPath $requiredFiles.Pci -Raw | ConvertFrom-Json
        Usb = Get-Content -LiteralPath $requiredFiles.Usb -Raw | ConvertFrom-Json
        Pnp = Get-Content -LiteralPath $requiredFiles.Pnp -Raw | ConvertFrom-Json
    }
}

function ConvertTo-NormalizedHardwareId {
    param(
        [string]$HardwareId
    )

    if ($null -eq $HardwareId) {
        return ''
    }

    return $HardwareId.Trim().Trim('"').ToUpperInvariant()
}

function New-ResolutionObject {
    param(
        [string]$InputId,
        [string]$NormalizedId,
        [string]$Bus,
        [string]$IdType,
        [object]$Fields,
        [string]$Confidence,
        [object]$Lookup,
        [string[]]$Notes
    )

    [pscustomobject]@{
        Input = $InputId
        Normalized = $NormalizedId
        Bus = $Bus
        IdType = $IdType
        Fields = [pscustomobject]$Fields
        Confidence = $Confidence
        Lookup = [pscustomobject]$Lookup
        Notes = @($Notes)
    }
}

function Resolve-PciHardwareId {
    param(
        [string]$InputId,
        [string]$NormalizedId,
        [object]$Cache
    )

    $idMatch = [regex]::Match($NormalizedId, '^PCI\\.*?VEN_(?<vendor>[0-9A-F]{4}).*?DEV_(?<device>[0-9A-F]{4})(?:.*?SUBSYS_(?<subsys>[0-9A-F]{8}))?(?:.*?REV_(?<revision>[0-9A-F]{2}))?')
    if (-not $idMatch.Success) {
        return $null
    }

    $vendorId = $idMatch.Groups['vendor'].Value
    $deviceId = $idMatch.Groups['device'].Value
    $subsystemRaw = $idMatch.Groups['subsys'].Value
    $revision = $idMatch.Groups['revision'].Value
    $subdeviceId = ''
    $subvendorId = ''
    $subsystemKey = ''

    if (-not [string]::IsNullOrWhiteSpace($subsystemRaw)) {
        $subdeviceId = $subsystemRaw.Substring(0, 4)
        $subvendorId = $subsystemRaw.Substring(4, 4)
        $subsystemKey = "$subvendorId`:$subdeviceId"
    }

    $vendorEntry = Get-JsonObjectPropertyValue -InputObject $Cache.Pci.Data.Vendors -PropertyName $vendorId
    $subvendorEntry = $null
    $deviceEntry = $null
    $subsystemEntry = $null
    if ($null -ne $vendorEntry) {
        $deviceEntry = Get-JsonObjectPropertyValue -InputObject $vendorEntry.Devices -PropertyName $deviceId
    }
    if (-not [string]::IsNullOrWhiteSpace($subvendorId)) {
        $subvendorEntry = Get-JsonObjectPropertyValue -InputObject $Cache.Pci.Data.Vendors -PropertyName $subvendorId
    }
    if ($null -ne $deviceEntry -and -not [string]::IsNullOrWhiteSpace($subsystemKey)) {
        $subsystemEntry = Get-JsonObjectPropertyValue -InputObject $deviceEntry.Subsystems -PropertyName $subsystemKey
    }

    $confidence = 'PARSED-ONLY'
    if ($null -ne $subsystemEntry) {
        $confidence = 'EXACT-SUBSYSTEM'
    }
    elseif ($null -ne $deviceEntry -and $null -ne $subvendorEntry) {
        $confidence = 'EXACT-DEVICE+SUBVENDOR'
    }
    elseif ($null -ne $deviceEntry) {
        $confidence = 'EXACT-DEVICE'
    }
    elseif ($null -ne $vendorEntry) {
        $confidence = 'VENDOR-ONLY'
    }

    $notes = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($subsystemRaw)) {
        $notes.Add('Windows PCI SUBSYS is parsed as subdevice(first 4) + subvendor(last 4); pci.ids lookup uses subvendor:subdevice.')
        if ($null -ne $subvendorEntry -and $null -eq $subsystemEntry) {
            $notes.Add('Exact subsystem model is not present in pci.ids, but the subsystem vendor was resolved from the PCI vendor table.')
        }
    }

    New-ResolutionObject -InputId $InputId -NormalizedId $NormalizedId -Bus 'PCI' -IdType 'PCI_DEVICE' -Fields ([ordered]@{
        VendorId = $vendorId
        DeviceId = $deviceId
        SubsystemRaw = $subsystemRaw
        SubvendorId = $subvendorId
        SubdeviceId = $subdeviceId
        Revision = $revision
    }) -Confidence $confidence -Lookup ([ordered]@{
        VendorName = if ($null -ne $vendorEntry) { $vendorEntry.Name } else { '' }
        DeviceName = if ($null -ne $deviceEntry) { $deviceEntry.Name } else { '' }
        SubsystemName = if ($null -ne $subsystemEntry) { $subsystemEntry.Name } else { '' }
        SubvendorName = if ($null -ne $subvendorEntry) { $subvendorEntry.Name } else { '' }
        Source = 'pci.ids'
    }) -Notes $notes.ToArray()
}

function Resolve-UsbHardwareId {
    param(
        [string]$InputId,
        [string]$NormalizedId,
        [object]$Cache
    )

    $idMatch = [regex]::Match($NormalizedId, '^(?<bus>USB|HID)\\.*?VID_(?<vendor>[0-9A-F]{4}).*?PID_(?<product>[0-9A-F]{4})(?:.*?MI_(?<interface>[0-9A-F]{2}))?(?:.*?REV_(?<revision>[0-9A-F]{4}))?')
    if (-not $idMatch.Success) {
        return $null
    }

    $bus = $idMatch.Groups['bus'].Value
    $vendorId = $idMatch.Groups['vendor'].Value
    $productId = $idMatch.Groups['product'].Value
    $interfaceId = $idMatch.Groups['interface'].Value
    $revision = $idMatch.Groups['revision'].Value

    $vendorEntry = Get-JsonObjectPropertyValue -InputObject $Cache.Usb.Data.Vendors -PropertyName $vendorId
    $productEntry = $null
    $interfaceEntry = $null
    if ($null -ne $vendorEntry) {
        $productEntry = Get-JsonObjectPropertyValue -InputObject $vendorEntry.Products -PropertyName $productId
    }
    if ($null -ne $productEntry -and -not [string]::IsNullOrWhiteSpace($interfaceId)) {
        $interfaceEntry = Get-JsonObjectPropertyValue -InputObject $productEntry.Interfaces -PropertyName $interfaceId
    }

    $confidence = 'PARSED-ONLY'
    if ($null -ne $interfaceEntry) {
        $confidence = 'EXACT-INTERFACE'
    }
    elseif ($null -ne $productEntry) {
        $confidence = 'EXACT-PRODUCT'
    }
    elseif ($null -ne $vendorEntry) {
        $confidence = 'VENDOR-ONLY'
    }

    $notes = [System.Collections.Generic.List[string]]::new()
    if ($bus -eq 'HID') {
        $notes.Add('HID VID/PID IDs are resolved through the USB database when present.')
    }

    New-ResolutionObject -InputId $InputId -NormalizedId $NormalizedId -Bus $bus -IdType 'USB_OR_HID_DEVICE' -Fields ([ordered]@{
        VendorId = $vendorId
        ProductId = $productId
        InterfaceId = $interfaceId
        Revision = $revision
    }) -Confidence $confidence -Lookup ([ordered]@{
        VendorName = if ($null -ne $vendorEntry) { $vendorEntry.Name } else { '' }
        ProductName = if ($null -ne $productEntry) { $productEntry.Name } else { '' }
        InterfaceName = if ($null -ne $interfaceEntry) { $interfaceEntry.Name } else { '' }
        Source = 'usb.ids'
    }) -Notes $notes.ToArray()
}

function Resolve-PnpVendor {
    param(
        [string]$VendorId,
        [object]$Cache
    )

    if ([string]::IsNullOrWhiteSpace($VendorId) -or $VendorId.Length -ne 3) {
        return $null
    }

    return (Get-JsonObjectPropertyValue -InputObject $Cache.Pnp.Data.Vendors -PropertyName $VendorId)
}

function Resolve-AcpiOrPnpHardwareId {
    param(
        [string]$InputId,
        [string]$NormalizedId,
        [object]$Cache
    )

    $newAcpiMatch = [regex]::Match($NormalizedId, '^ACPI\\VEN_(?<vendor>[A-Z0-9]{3,4})&DEV_(?<device>[A-Z0-9]{4})')
    if ($newAcpiMatch.Success) {
        $vendorId = $newAcpiMatch.Groups['vendor'].Value
        $deviceId = $newAcpiMatch.Groups['device'].Value
        $vendorEntry = Resolve-PnpVendor -VendorId $vendorId -Cache $Cache
        $confidence = if ($null -ne $vendorEntry) { 'VENDOR-ONLY' } else { 'PARSED-ONLY' }
        $notes = [System.Collections.Generic.List[string]]::new()
        if ($vendorId.Length -ne 3) {
            $notes.Add('This ACPI vendor code is not a three-character PNP vendor ID; no trusted PNP lookup was applied.')
        }

        return (New-ResolutionObject -InputId $InputId -NormalizedId $NormalizedId -Bus 'ACPI' -IdType 'ACPI_VEN_DEV' -Fields ([ordered]@{
            VendorId = $vendorId
            DeviceId = $deviceId
        }) -Confidence $confidence -Lookup ([ordered]@{
            VendorName = if ($null -ne $vendorEntry) { $vendorEntry.Name } else { '' }
            DeviceName = ''
            Source = if ($null -ne $vendorEntry) { 'pnp.ids' } else { '' }
        }) -Notes $notes.ToArray())
    }

    $compactMatch = [regex]::Match($NormalizedId, '^(?:(?<bus>ACPI)\\|\*)?(?<compact>[A-Z0-9]{7,8})(?:\\|$)')
    if (-not $compactMatch.Success) {
        return $null
    }

    $bus = if ([string]::IsNullOrWhiteSpace($compactMatch.Groups['bus'].Value)) { 'PNP' } else { $compactMatch.Groups['bus'].Value }
    $compactId = $compactMatch.Groups['compact'].Value
    $vendorId = ''
    $deviceId = ''
    $notes = [System.Collections.Generic.List[string]]::new()

    if ($compactId.Length -eq 7) {
        $vendorId = $compactId.Substring(0, 3)
        $deviceId = $compactId.Substring(3, 4)
    }
    else {
        $vendorId = $compactId.Substring(0, 4)
        $deviceId = $compactId.Substring(4, 4)
        $notes.Add('Four-character ACPI compact vendor codes are parsed but not resolved through pnp.ids to avoid false vendor matches.')
    }

    $vendorEntry = Resolve-PnpVendor -VendorId $vendorId -Cache $Cache
    $confidence = if ($null -ne $vendorEntry) { 'VENDOR-ONLY' } else { 'PARSED-ONLY' }

    New-ResolutionObject -InputId $InputId -NormalizedId $NormalizedId -Bus $bus -IdType 'ACPI_OR_PNP_COMPACT' -Fields ([ordered]@{
        VendorId = $vendorId
        DeviceId = $deviceId
    }) -Confidence $confidence -Lookup ([ordered]@{
        VendorName = if ($null -ne $vendorEntry) { $vendorEntry.Name } else { '' }
        DeviceName = ''
        Source = if ($null -ne $vendorEntry) { 'pnp.ids' } else { '' }
    }) -Notes $notes.ToArray()
}

function Resolve-UnsupportedHardwareId {
    param(
        [string]$InputId,
        [string]$NormalizedId
    )

    $bus = 'UNKNOWN'
    $busMatch = [regex]::Match($NormalizedId, '^(?<bus>[^\\]+)\\')
    if ($busMatch.Success) {
        $bus = $busMatch.Groups['bus'].Value
    }

    New-ResolutionObject -InputId $InputId -NormalizedId $NormalizedId -Bus $bus -IdType 'UNSUPPORTED_OR_UNRECOGNIZED' -Fields ([ordered]@{}) -Confidence 'UNSUPPORTED' -Lookup ([ordered]@{
        Source = ''
    }) -Notes @('No supported PCI/USB/HID/ACPI/PNP parser matched this hardware ID yet.')
}

function Resolve-HardwareId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [string[]]$HardwareId,

        [string]$CacheRoot = (Get-HardwareIdCacheRoot),

        [object]$Cache
    )

    begin {
        if ($null -eq $Cache) {
            $Cache = Import-HardwareIdDatabaseCache -CacheRoot $CacheRoot
        }
    }

    process {
        foreach ($hardwareIdValue in $HardwareId) {
            $normalizedId = ConvertTo-NormalizedHardwareId -HardwareId $hardwareIdValue
            if ([string]::IsNullOrWhiteSpace($normalizedId)) {
                continue
            }

            $resolution = Resolve-PciHardwareId -InputId $hardwareIdValue -NormalizedId $normalizedId -Cache $Cache
            if ($null -eq $resolution) {
                $resolution = Resolve-UsbHardwareId -InputId $hardwareIdValue -NormalizedId $normalizedId -Cache $Cache
            }
            if ($null -eq $resolution) {
                $resolution = Resolve-AcpiOrPnpHardwareId -InputId $hardwareIdValue -NormalizedId $normalizedId -Cache $Cache
            }
            if ($null -eq $resolution) {
                $resolution = Resolve-UnsupportedHardwareId -InputId $hardwareIdValue -NormalizedId $normalizedId
            }

            $resolution
        }
    }
}

function Format-HardwareIdResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$Resolution
    )

    process {
        foreach ($resolutionItem in $Resolution) {
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add($resolutionItem.Normalized)
            $lines.Add(("  Type       : {0} / {1}" -f $resolutionItem.Bus, $resolutionItem.IdType))
            $lines.Add(("  Confidence : {0}" -f $resolutionItem.Confidence))

            $fieldProperties = @($resolutionItem.Fields.PSObject.Properties)
            if ($fieldProperties.Count -gt 0) {
                $fieldText = [System.Collections.Generic.List[string]]::new()
                foreach ($fieldProperty in $fieldProperties) {
                    if ($null -ne $fieldProperty.Value -and -not [string]::IsNullOrWhiteSpace([string]$fieldProperty.Value)) {
                        $fieldText.Add(("{0}={1}" -f $fieldProperty.Name, $fieldProperty.Value))
                    }
                }
                if ($fieldText.Count -gt 0) {
                    $lines.Add(("  Fields     : {0}" -f ($fieldText -join ', ')))
                }
            }

            $lookupProperties = @($resolutionItem.Lookup.PSObject.Properties)
            foreach ($lookupProperty in $lookupProperties) {
                if ($lookupProperty.Name -eq 'Source') {
                    continue
                }
                if ($null -ne $lookupProperty.Value -and -not [string]::IsNullOrWhiteSpace([string]$lookupProperty.Value)) {
                    $lines.Add(("  {0,-11}: {1}" -f $lookupProperty.Name, $lookupProperty.Value))
                }
            }

            $sourceProperty = $resolutionItem.Lookup.PSObject.Properties['Source']
            if ($null -ne $sourceProperty -and -not [string]::IsNullOrWhiteSpace([string]$sourceProperty.Value)) {
                $lines.Add(("  Source     : {0}" -f $sourceProperty.Value))
            }

            foreach ($note in @($resolutionItem.Notes)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$note)) {
                    $lines.Add(("  Note       : {0}" -f $note))
                }
            }

            $lines -join [Environment]::NewLine
        }
    }
}

Export-ModuleMember -Function @(
    'Import-HardwareIdDatabaseCache',
    'ConvertTo-NormalizedHardwareId',
    'Resolve-HardwareId',
    'Format-HardwareIdResolution'
)
