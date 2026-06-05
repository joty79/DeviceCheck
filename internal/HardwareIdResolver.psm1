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

function Get-HardwareIdTokenValue {
    param(
        [string]$NormalizedId,
        [string]$TokenName,
        [int]$Length
    )

    $pattern = '(?:^|[\\&]){0}_(?<value>[0-9A-F]{{{1}}})(?:[\\&]|$)' -f [regex]::Escape($TokenName.ToUpperInvariant()), $Length
    $tokenMatch = [regex]::Match($NormalizedId, $pattern)
    if (-not $tokenMatch.Success) {
        return ''
    }

    return $tokenMatch.Groups['value'].Value
}

function Get-UsbClassName {
    param([string]$ClassId)

    switch ($ClassId.ToUpperInvariant()) {
        '00' { return '(Defined at Interface level)' }
        '01' { return 'Audio' }
        '02' { return 'Communications' }
        '03' { return 'Human Interface Device' }
        '05' { return 'Physical Interface Device' }
        '06' { return 'Imaging' }
        '07' { return 'Printer' }
        '08' { return 'Mass Storage' }
        '09' { return 'Hub' }
        '0A' { return 'CDC Data' }
        '0B' { return 'Smart Card' }
        '0D' { return 'Content Security' }
        '0E' { return 'Video' }
        '0F' { return 'Personal Healthcare' }
        '10' { return 'Audio/Video' }
        'DC' { return 'Diagnostic Device' }
        'E0' { return 'Wireless Controller' }
        'EF' { return 'Miscellaneous Device' }
        'FE' { return 'Application Specific' }
        'FF' { return 'Vendor Specific' }
        default { return '' }
    }
}

function Get-UsbSubclassName {
    param(
        [string]$ClassId,
        [string]$SubclassId
    )

    if ([string]::IsNullOrWhiteSpace($SubclassId)) {
        return ''
    }

    $class = $ClassId.ToUpperInvariant()
    $subclass = $SubclassId.ToUpperInvariant()
    if ($class -eq '01') {
        switch ($subclass) {
            '00' { return 'No subclass / unspecified' }
            '01' { return 'Audio Control' }
            '02' { return 'Audio Streaming' }
            '03' { return 'MIDI Streaming' }
        }
    }
    elseif ($class -eq '03') {
        switch ($subclass) {
            '00' { return 'No subclass' }
            '01' { return 'Boot Interface Subclass' }
        }
    }

    return ''
}

function Get-UsbProtocolName {
    param(
        [string]$ClassId,
        [string]$ProtocolId
    )

    if ([string]::IsNullOrWhiteSpace($ProtocolId)) {
        return ''
    }

    $class = $ClassId.ToUpperInvariant()
    $protocol = $ProtocolId.ToUpperInvariant()
    if ($class -eq '01') {
        switch ($protocol) {
            '00' { return 'No class-specific protocol' }
            '20' { return 'USB Audio 2.0-style class match' }
            '30' { return 'USB Audio 3.0-style class match' }
        }
    }

    return ''
}

function Resolve-UsbHardwareId {
    param(
        [string]$InputId,
        [string]$NormalizedId,
        [object]$Cache
    )

    $idMatch = [regex]::Match($NormalizedId, '^(?<bus>USB|HID)\\.*?VID_(?<vendor>[0-9A-F]{4}).*?PID_(?<product>[0-9A-F]{4})')
    if (-not $idMatch.Success) {
        return $null
    }

    $bus = $idMatch.Groups['bus'].Value
    $vendorId = $idMatch.Groups['vendor'].Value
    $productId = $idMatch.Groups['product'].Value
    $interfaceId = Get-HardwareIdTokenValue -NormalizedId $NormalizedId -TokenName 'MI' -Length 2
    $revision = Get-HardwareIdTokenValue -NormalizedId $NormalizedId -TokenName 'REV' -Length 4

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

function Resolve-UsbClassHardwareId {
    param(
        [string]$InputId,
        [string]$NormalizedId
    )

    $idMatch = [regex]::Match($NormalizedId, '^(?<bus>USB|HID)\\.*?CLASS_(?<class>[0-9A-F]{2})')
    if (-not $idMatch.Success) {
        return $null
    }

    $bus = $idMatch.Groups['bus'].Value
    $classId = $idMatch.Groups['class'].Value
    $subclassId = Get-HardwareIdTokenValue -NormalizedId $NormalizedId -TokenName 'SUBCLASS' -Length 2
    $protocolId = Get-HardwareIdTokenValue -NormalizedId $NormalizedId -TokenName 'PROT' -Length 2

    $className = Get-UsbClassName -ClassId $classId
    $subclassName = Get-UsbSubclassName -ClassId $classId -SubclassId $subclassId
    $protocolName = Get-UsbProtocolName -ClassId $classId -ProtocolId $protocolId
    $confidence = if (-not [string]::IsNullOrWhiteSpace($className)) { 'CLASS-MATCH' } else { 'PARSED-ONLY' }

    New-ResolutionObject -InputId $InputId -NormalizedId $NormalizedId -Bus $bus -IdType 'USB_CLASS' -Fields ([ordered]@{
        ClassId = $classId
        SubclassId = $subclassId
        ProtocolId = $protocolId
    }) -Confidence $confidence -Lookup ([ordered]@{
        ClassName = $className
        SubclassName = $subclassName
        ProtocolName = $protocolName
        Source = 'USB class codes'
    }) -Notes @('Class/Protocol IDs describe a generic USB function, not an exact vendor product model.')
}

function ConvertFrom-ScsiIdentifierText {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return (($Value -replace '_+', ' ') -replace '\s+', ' ').Trim()
}

function Get-ScsiDeviceTypeName {
    param(
        [AllowEmptyString()]
        [string]$DeviceType
    )

    switch ($DeviceType.ToUpperInvariant()) {
        'DISK' { return 'Disk drive' }
        'CDROM' { return 'CD/DVD drive' }
        'TAPE' { return 'Tape drive' }
        'PRINTER' { return 'Printer' }
        'SCANNER' { return 'Scanner' }
        'CHANGER' { return 'Media changer' }
        'ENCLOSURE' { return 'Storage enclosure' }
        default { return 'SCSI storage/function' }
    }
}

function Resolve-ScsiHardwareId {
    param(
        [string]$InputId,
        [string]$NormalizedId
    )

    $structuredMatch = [regex]::Match($NormalizedId, '^SCSI\\(?<type>[A-Z0-9]+)&VEN_(?<vendor>[^&\\]+)&PROD_(?<product>[^&\\]+)(?:&REV_(?<revision>[^&\\]+))?')
    if ($structuredMatch.Success) {
        $deviceType = $structuredMatch.Groups['type'].Value
        $vendorId = $structuredMatch.Groups['vendor'].Value
        $productId = $structuredMatch.Groups['product'].Value
        $revision = $structuredMatch.Groups['revision'].Value
        $vendorName = ConvertFrom-ScsiIdentifierText -Value $vendorId
        $productName = ConvertFrom-ScsiIdentifierText -Value $productId

        return (New-ResolutionObject -InputId $InputId -NormalizedId $NormalizedId -Bus 'SCSI' -IdType 'SCSI_STORAGE_ID' -Fields ([ordered]@{
                    DeviceType = $deviceType
                    VendorId = $vendorId
                    ProductId = $productId
                    Revision = $revision
                }) -Confidence 'PARSED-STORAGE' -Lookup ([ordered]@{
                    DeviceTypeName = Get-ScsiDeviceTypeName -DeviceType $deviceType
                    VendorName = $vendorName
                    ProductName = $productName
                    Source = 'Windows storage ID'
                }) -Notes @('Windows exposes many SATA/NVMe disks through SCSI-style storage IDs; this is a storage stack identity, not a PCI/USB database lookup.'))
    }

    $compactMatch = [regex]::Match($NormalizedId, '^SCSI\\(?<type>DISK|CDROM|TAPE|PRINTER|SCANNER|CHANGER|ENCLOSURE)(?<payload>.+)$')
    if (-not $compactMatch.Success) {
        return $null
    }

    $compactType = $compactMatch.Groups['type'].Value
    $payload = $compactMatch.Groups['payload'].Value
    $vendorId = ''
    $productId = $payload
    if ($payload.Length -ge 8) {
        $vendorId = $payload.Substring(0, 8)
        $productId = $payload.Substring(8)
    }

    $compactVendorName = ConvertFrom-ScsiIdentifierText -Value $vendorId
    $compactProductName = ConvertFrom-ScsiIdentifierText -Value $productId

    New-ResolutionObject -InputId $InputId -NormalizedId $NormalizedId -Bus 'SCSI' -IdType 'SCSI_STORAGE_COMPACT' -Fields ([ordered]@{
        DeviceType = $compactType
        VendorId = $vendorId
        ProductId = $productId
        Revision = ''
    }) -Confidence 'PARSED-STORAGE' -Lookup ([ordered]@{
        DeviceTypeName = Get-ScsiDeviceTypeName -DeviceType $compactType
        VendorName = $compactVendorName
        ProductName = $compactProductName
        Source = 'Windows storage ID'
    }) -Notes @('Compact SCSI storage IDs carry a padded vendor/model string; prefer structured VEN/PROD IDs when Windows exposes them.')
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
                $resolution = Resolve-UsbClassHardwareId -InputId $hardwareIdValue -NormalizedId $normalizedId
            }
            if ($null -eq $resolution) {
                $resolution = Resolve-ScsiHardwareId -InputId $hardwareIdValue -NormalizedId $normalizedId
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
