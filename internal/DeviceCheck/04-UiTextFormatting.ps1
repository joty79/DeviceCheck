# Part of DeviceCheck.ps1. Dot-sourced by the root entrypoint; keep script-scope state shared.
# Purpose: TUI-safe text, detail-row, markdown, status, and wrapping helpers.
function Format-UiValue {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$MaxLength = 90
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return '-' }
    $MaxLength = [Math]::Max(8, $MaxLength)
    if ($Text.Length -le $MaxLength) { return $Text }
    return ($Text.Substring(0, [Math]::Max(5, $MaxLength - 3)) + '...')
}

function Remove-AnsiSequence {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $withoutOsc = $script:AnsiOscRegex.Replace($Text, '')
    return $script:AnsiCsiRegex.Replace($withoutOsc, '')
}

function Get-PrintableLength {
    param([AllowEmptyString()][string]$Text)

    return (Remove-AnsiSequence -Text $Text).Length
}

function Get-NotePropertyValue {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-DeviceLookupDisplayName {
    param($Device)

    $friendlyName = [string](Get-NotePropertyValue -Object $Device -Name 'FriendlyName')
    if (-not [string]::IsNullOrWhiteSpace($friendlyName)) { return $friendlyName }

    $instanceId = [string](Get-NotePropertyValue -Object $Device -Name 'InstanceId')
    if (-not [string]::IsNullOrWhiteSpace($instanceId)) { return $instanceId }

    return 'selected device'
}

function Set-SystemStatusMessage {
    param(
        [AllowEmptyString()][string]$Message,
        [switch]$NoTimestamp
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        $script:SystemScanMessage = ''
        return
    }

    $Message = ($Message -replace '[\r\n\t]+', ' ') -replace '\s{2,}', ' '
    $Message = $Message.Trim()
    $suffix = $(if ($NoTimestamp) { '' } else { " | $(Get-Date -Format 'HH:mm:ss')" })
    $script:SystemScanMessage = "$Message$suffix"
}

function Get-SystemStatusColor {
    param([AllowEmptyString()][string]$StatusText)

    if ([string]::IsNullOrWhiteSpace($StatusText)) { return $_C.Dim }
    if ($StatusText -match '(?i)\b(failed|failure|error|missing|blocked|denied|forbidden|unavailable|terminated unexpectedly)\b') { return $_C.Fail }
    if ($StatusText -match '(?i)\b(cancelled|ignored|confirmation|local-target only|already includes|available only|paused)\b') { return $_C.Warn }
    if ($StatusText -match '(?i)\b(running|collecting|queued|refresh|connected|complete|updated|done)\b') { return $_C.OK }
    return $_C.Dim
}

function Format-PlainToWidth {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width
    )

    $Width = [Math]::Max(1, $Width)
    if ([string]::IsNullOrEmpty($Text)) { return (' ' * $Width) }
    if ($Text.Length -gt $Width) {
        if ($Width -le 1) { return $Text.Substring(0, 1) }
        return ($Text.Substring(0, [Math]::Max(1, $Width - 1)) + [char]0x2026)
    }
    return $Text.PadRight($Width)
}

function Format-AnsiToWidth {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width
    )

    $Width = [Math]::Max(1, $Width)
    $printableLength = Get-PrintableLength -Text $Text
    if ($printableLength -gt $Width) {
        return (Format-PlainToWidth -Text (Remove-AnsiSequence -Text $Text) -Width $Width)
    }
    return ($Text + (' ' * ($Width - $printableLength)))
}

function New-SelectedLine {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width
    )

    return "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)$(Format-PlainToWidth -Text (Remove-AnsiSequence -Text $Text) -Width $Width)$($_C.Reset)"
}

function New-SectionLine {
    param(
        [string]$Title,
        [int]$Width
    )

    $prefix = " $Title "
    $line = (Get-UiGlyph -Name HLine) * [Math]::Max(0, $Width - $prefix.Length)
    return "$($_C.H1)$prefix$($_C.Dim)$line$($_C.Reset)"
}

function New-KeyValueLine {
    param(
        [string]$Key,
        [AllowEmptyString()][string]$Value,
        [int]$Width,
        [string]$ValueColor = $null
    )

    if (-not $ValueColor) { $ValueColor = $_C.White }
    $keyWidth = $(if ($Width -ge 56) { 14 } else { 13 })
    $keyText = Format-PlainToWidth -Text $Key -Width $keyWidth
    $valueWidth = [Math]::Max(8, $Width - ($keyWidth + 4))
    $valueText = Format-UiValue -Text $Value -MaxLength $valueWidth
    return " $($_C.Dim)$keyText :$($_C.Reset) $ValueColor$valueText$($_C.Reset)"
}

function Get-KeyValueLayout {
    param([int]$Width)

    $keyWidth = $(if ($Width -ge 56) { 14 } else { 13 })
    $valueWidth = [Math]::Max(8, $Width - ($keyWidth + 4))
    [pscustomobject]@{
        KeyWidth           = $keyWidth
        ValueWidth         = $valueWidth
        ContinuationIndent = (' ' * ($keyWidth + 4))
    }
}

function Split-DetailValueText {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width
    )

    $Width = [Math]::Max(8, $Width)
    $cleanText = Remove-AnsiSequence -Text $Text
    if ([string]::IsNullOrEmpty($cleanText)) { return @('') }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($paragraph in (($cleanText -replace "`r", '') -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($paragraph)) {
            $lines.Add('')
            continue
        }

        $current = ''
        foreach ($word in ($paragraph -split '\s+')) {
            if ([string]::IsNullOrWhiteSpace($word)) { continue }

            while ($word.Length -gt $Width) {
                if (-not [string]::IsNullOrWhiteSpace($current)) {
                    $lines.Add($current)
                    $current = ''
                }
                $lines.Add($word.Substring(0, $Width))
                $word = $word.Substring($Width)
            }

            $candidate = $(if ($current) { "$current $word" } else { $word })
            if ($candidate.Length -gt $Width) {
                if ($current) { $lines.Add($current) }
                $current = $word
            } else {
                $current = $candidate
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($current)) {
            $lines.Add($current)
        }
    }

    if ($lines.Count -eq 0) { return @('') }
    return @($lines)
}

function Add-KeyValueLines {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Key,
        [AllowEmptyString()][string]$Value,
        [int]$Width,
        [string]$ValueColor = $null
    )

    if (-not $ValueColor) { $ValueColor = $_C.White }
    $layout = Get-KeyValueLayout -Width $Width
    $keyText = Format-PlainToWidth -Text $Key -Width $layout.KeyWidth
    $valueLines = @(Split-DetailValueText -Text $Value -Width $layout.ValueWidth)
    $Lines.Add(" $($_C.Dim)$keyText :$($_C.Reset) $ValueColor$($valueLines[0])$($_C.Reset)")

    for ($i = 1; $i -lt $valueLines.Count; $i++) {
        $Lines.Add("$($layout.ContinuationIndent)$ValueColor$($valueLines[$i])$($_C.Reset)")
    }
}

function Add-WrappedPathLine {
    param(
        [Parameter(Mandatory)]
        $Lines,
        [string]$Key,
        [string]$Path,
        [int]$Width
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $layout = Get-KeyValueLayout -Width $Width
        $keyText = Format-PlainToWidth -Text $Key -Width $layout.KeyWidth
        $Lines.Add(" $($_C.Dim)$keyText :$($_C.Reset) -")
        return
    }

    $layout = Get-KeyValueLayout -Width $Width
    $keyText = Format-PlainToWidth -Text $Key -Width $layout.KeyWidth
    $valueWidth = $layout.ValueWidth

    # Wrap the path into pieces of $valueWidth length
    $wrapped = [System.Collections.Generic.List[string]]::new()
    $tempPath = $Path
    while ($tempPath.Length -gt 0) {
        $chunkSize = [Math]::Min($tempPath.Length, $valueWidth)
        $wrapped.Add($tempPath.Substring(0, $chunkSize))
        $tempPath = $tempPath.Substring($chunkSize)
    }

    $fileUrl = "file:///" + ($Path -replace '\\', '/')
    
    # First line has the key
    $first = $wrapped[0]
    $clickableFirst = New-TerminalHyperlink -Label $first -Url $fileUrl
    $Lines.Add(" $($_C.Dim)$keyText :$($_C.Reset) $($_C.White)$clickableFirst$($_C.Reset)")

    # Subsequent lines are indented by 15 spaces (13 key + 2 padding/separator)
    for ($i = 1; $i -lt $wrapped.Count; $i++) {
        $indent = $layout.ContinuationIndent
        $clickableChunk = New-TerminalHyperlink -Label $wrapped[$i] -Url $fileUrl
        $Lines.Add("$indent$($_C.White)$clickableChunk$($_C.Reset)")
    }
}


function Get-HardwareIdBreakdownLines {
    param(
        [string]$HardwareId,
        [int]$Width,
        [object]$Evidence = $null
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($HardwareId) -or $script:HardwareIdResolverState -ne 'Ready') {
        return @()
    }

    try {
        $resolutions = @(Resolve-HardwareId -HardwareId $HardwareId -Cache $script:HardwareIdDatabaseCache)
        if ($resolutions.Count -eq 0) {
            return @()
        }

        $res = $resolutions[0]
        $pad = ' ' * 17
        $valueWidth = [Math]::Max(8, $Width - 35)

        if ($res.Bus -eq 'PCI') {
            $vendorId = $res.Fields.VendorId
            $deviceId = $res.Fields.DeviceId
            $subsysRaw = $res.Fields.SubsystemRaw
            $subvendorId = $res.Fields.SubvendorId
            $subdeviceId = $res.Fields.SubdeviceId
            $revision = $res.Fields.Revision

            $vendorName = $(if ($res.Lookup.VendorName) { Get-FormattedHardwareVendorName -Name $res.Lookup.VendorName } else { 'Unknown Vendor' })
            $deviceName = $(if ($res.Lookup.DeviceName) { $res.Lookup.DeviceName } else { 'Unknown Device' })
            $subvendorName = $(if ($res.Lookup.SubvendorName) { Get-FormattedHardwareVendorName -Name $res.Lookup.SubvendorName } else { '' })
            $subsystemName = $(if ($res.Lookup.SubsystemName) { $res.Lookup.SubsystemName } else { '' })

            # 1. VEN
            $venText = "VEN_$vendorId"
            $venVal = Format-UiValue -Text $vendorName -MaxLength $valueWidth
            $venLine = "{0,-15} = {1}" -f $venText, $venVal
            $lines.Add("$pad$($_C.Dim)$($venLine)$($_C.Reset)")

            # 2. DEV
            $devText = "DEV_$deviceId"
            $devVal = Format-UiValue -Text $deviceName -MaxLength $valueWidth
            $devLine = "{0,-15} = {1}" -f $devText, $devVal
            $lines.Add("$pad$($_C.White)$($devLine)$($_C.Reset)")

            # 3. SUBSYS (if present)
            if (-not [string]::IsNullOrWhiteSpace($subsysRaw)) {
                $subvendorShort = Get-ShortHardwareVendorName -Name $subvendorName
                $subsysDesc = $(if (-not [string]::IsNullOrWhiteSpace($subsystemName)) {
                    $subsystemName
                } elseif (-not [string]::IsNullOrWhiteSpace($subvendorShort)) {
                    "$subvendorShort board-specific model"
                } else {
                    "board-specific model"
                })

                $subsysText = "SUBSYS_$subsysRaw"
                $subsysVal = Format-UiValue -Text $subsysDesc -MaxLength $valueWidth
                $subsysLine = "{0,-15} = {1}" -f $subsysText, $subsysVal
                $lines.Add("$pad$($_C.Info)$($subsysLine)$($_C.Reset)")

                # Subdevice ID
                $subdevDesc = "subsystem / board ID"
                $subdevLine = "   {0,-12} = {1}" -f $subdeviceId, $subdevDesc
                $lines.Add("$pad$($_C.Dim)$($subdevLine)$($_C.Reset)")

                # Subvendor ID
                $subvendorDesc = $(if (-not [string]::IsNullOrWhiteSpace($subvendorName)) {
                    "subvendor = $subvendorName"
                } else {
                    "subvendor"
                })
                $subvendorVal = Format-UiValue -Text $subvendorDesc -MaxLength ($valueWidth - 3)
                $subvendorLine = "   {0,-12} = {1}" -f $subvendorId, $subvendorVal
                $lines.Add("$pad$($_C.Dim)$($subvendorLine)$($_C.Reset)")
            }

            # 4. REV (if present)
            if (-not [string]::IsNullOrWhiteSpace($revision)) {
                $revText = "REV_$revision"
                $revLine = "{0,-15} = {1}" -f $revText, "hardware rev"
                $lines.Add("$pad$($_C.Dim)$($revLine)$($_C.Reset)")
            }
        }
        elseif ($res.Bus -in @('USB', 'HID') -and $res.IdType -ne 'USB_CLASS') {
            $vendorId = $res.Fields.VendorId
            $productId = $res.Fields.ProductId
            $interfaceId = $res.Fields.InterfaceId
            $revision = $res.Fields.Revision
            $evidence = Get-BoardModelEvidenceForResolution -Resolution $res

            $vendorName = $(if ($res.Lookup.VendorName) { Get-FormattedHardwareVendorName -Name $res.Lookup.VendorName } else { 'Unknown Vendor' })
            $productName = $(if ($res.Lookup.ProductName) {
                $res.Lookup.ProductName
            } elseif ($null -ne $evidence) {
                [string](Get-NotePropertyValue -Object $evidence -Name 'ModelName')
            } else {
                'Unknown Product'
            })
            $interfaceName = $(if ($res.Lookup.InterfaceName) {
                $res.Lookup.InterfaceName
            } elseif ($null -ne $evidence) {
                [string](Get-NotePropertyValue -Object $evidence -Name 'InterfaceName')
            } else {
                ''
            })

            # 1. VID
            $vidText = "VID_$vendorId"
            $vidVal = Format-UiValue -Text $vendorName -MaxLength $valueWidth
            $vidLine = "{0,-15} = {1}" -f $vidText, $vidVal
            $lines.Add("$pad$($_C.Dim)$($vidLine)$($_C.Reset)")

            # 2. PID
            $pidText = "PID_$productId"
            $pidVal = Format-UiValue -Text $productName -MaxLength $valueWidth
            $pidLine = "{0,-15} = {1}" -f $pidText, $pidVal
            $lines.Add("$pad$($_C.White)$($pidLine)$($_C.Reset)")

            # 3. MI (if present)
            if (-not [string]::IsNullOrWhiteSpace($interfaceId)) {
                $miText = "MI_$interfaceId"
                $miVal = $(if ($interfaceName) { $interfaceName } else { "interface" })
                $miLine = "{0,-15} = {1}" -f $miText, (Format-UiValue -Text $miVal -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($miLine)$($_C.Reset)")
            }

            # 4. REV (if present)
            if (-not [string]::IsNullOrWhiteSpace($revision)) {
                $revText = "REV_$revision"
                $revLine = "{0,-15} = {1}" -f $revText, "device revision / bcdDevice"
                $lines.Add("$pad$($_C.Dim)$($revLine)$($_C.Reset)")
            }
        }
        elseif ($res.Bus -in @('USB', 'HID') -and $res.IdType -eq 'USB_CLASS') {
            $classId = $res.Fields.ClassId
            $subclassId = $res.Fields.SubclassId
            $protocolId = $res.Fields.ProtocolId
            $className = $(if ($res.Lookup.ClassName) { $res.Lookup.ClassName } else { 'USB class' })
            $subclassName = $(if ($res.Lookup.SubclassName) { $res.Lookup.SubclassName } else { 'subclass' })
            $protocolName = $(if ($res.Lookup.ProtocolName) { $res.Lookup.ProtocolName } else { 'protocol' })

            if (-not [string]::IsNullOrWhiteSpace($classId)) {
                $classLine = "{0,-15} = {1}" -f "Class_$classId", (Format-UiValue -Text $className -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.White)$($classLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($subclassId)) {
                $subclassLine = "{0,-15} = {1}" -f "SubClass_$subclassId", (Format-UiValue -Text $subclassName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($subclassLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($protocolId)) {
                $protocolLine = "{0,-15} = {1}" -f "Prot_$protocolId", (Format-UiValue -Text $protocolName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($protocolLine)$($_C.Reset)")
            }
        }
        elseif ($res.Bus -eq 'HDAUDIO') {
            $functionId = $res.Fields.FunctionId
            $vendorId = $res.Fields.VendorId
            $deviceId = $res.Fields.DeviceId
            $subsysRaw = $res.Fields.SubsystemRaw
            $subvendorId = $res.Fields.SubvendorId
            $subdeviceId = $res.Fields.SubdeviceId
            $revision = $res.Fields.Revision
            $controllerVendorId = $res.Fields.ControllerVendorId
            $controllerDeviceId = $res.Fields.ControllerDeviceId
            $evidence = Get-BoardModelEvidenceForResolution -Resolution $res

            $functionName = $(if ($res.Lookup.FunctionName) { $res.Lookup.FunctionName } else { 'HD Audio function' })
            $vendorName = $(if ($res.Lookup.VendorName) { Get-FormattedHardwareVendorName -Name $res.Lookup.VendorName } else { 'Unknown codec vendor' })
            $codecName = $(if ($null -ne $evidence) { [string](Get-NotePropertyValue -Object $evidence -Name 'CodecName') } else { '' })
            $deviceName = $(if (-not [string]::IsNullOrWhiteSpace($codecName)) {
                $codecName
            } elseif ($res.Lookup.DeviceName) {
                $res.Lookup.DeviceName
            } else {
                'codec device id'
            })
            $subvendorName = $(if ($res.Lookup.SubvendorName) { Get-FormattedHardwareVendorName -Name $res.Lookup.SubvendorName } else { '' })
            $controllerVendorName = $(if ($res.Lookup.ControllerVendorName) { Get-FormattedHardwareVendorName -Name $res.Lookup.ControllerVendorName } else { '' })
            $controllerDeviceName = $(if ($res.Lookup.ControllerDeviceName) { $res.Lookup.ControllerDeviceName } else { '' })

            if (-not [string]::IsNullOrWhiteSpace($functionId)) {
                $functionLine = "{0,-15} = {1}" -f "FUNC_$functionId", (Format-UiValue -Text $functionName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($functionLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($vendorId)) {
                $vendorLine = "{0,-15} = {1}" -f "VEN_$vendorId", (Format-UiValue -Text $vendorName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($vendorLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($deviceId)) {
                $deviceLine = "{0,-15} = {1}" -f "DEV_$deviceId", (Format-UiValue -Text $deviceName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.White)$($deviceLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($subsysRaw)) {
                $subsystemDesc = $(if (-not [string]::IsNullOrWhiteSpace($subvendorName)) {
                    "$subvendorName audio implementation"
                } else {
                    'board audio implementation'
                })
                $subsysLine = "{0,-15} = {1}" -f "SUBSYS_$subsysRaw", (Format-UiValue -Text $subsystemDesc -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Info)$($subsysLine)$($_C.Reset)")

                $subvendorDesc = $(if (-not [string]::IsNullOrWhiteSpace($subvendorName)) {
                    "subsystem vendor = $subvendorName"
                } else {
                    'subsystem vendor'
                })
                $subvendorLine = "   {0,-12} = {1}" -f $subvendorId, (Format-UiValue -Text $subvendorDesc -MaxLength ($valueWidth - 3))
                $lines.Add("$pad$($_C.Dim)$($subvendorLine)$($_C.Reset)")

                $subdeviceLine = "   {0,-12} = {1}" -f $subdeviceId, 'board/implementation ID'
                $lines.Add("$pad$($_C.Dim)$($subdeviceLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($revision)) {
                $revisionLine = "{0,-15} = {1}" -f "REV_$revision", 'codec revision'
                $lines.Add("$pad$($_C.Dim)$($revisionLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($controllerVendorId)) {
                $controllerVendorText = $(if (-not [string]::IsNullOrWhiteSpace($controllerVendorName)) { $controllerVendorName } else { 'controller vendor' })
                $controllerVendorLine = "{0,-15} = {1}" -f "CTLR_VEN_$controllerVendorId", (Format-UiValue -Text $controllerVendorText -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($controllerVendorLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($controllerDeviceId)) {
                $controllerDeviceText = $(if (-not [string]::IsNullOrWhiteSpace($controllerDeviceName)) { $controllerDeviceName } else { 'controller device' })
                $controllerDeviceLine = "{0,-15} = {1}" -f "CTLR_DEV_$controllerDeviceId", (Format-UiValue -Text $controllerDeviceText -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($controllerDeviceLine)$($_C.Reset)")
            }
        }
        elseif ($res.Bus -eq 'DISPLAY') {
            $vendorId = $res.Fields.VendorId
            $productId = $res.Fields.ProductId
            $importantProperties = Get-NotePropertyValue -Object $Evidence -Name 'ImportantProperties'
            $localManufacturer = [string](Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_Manufacturer')
            $vendorName = $(if ($res.Lookup.VendorName) {
                Get-FormattedHardwareVendorName -Name $res.Lookup.VendorName
            } elseif (-not [string]::IsNullOrWhiteSpace($localManufacturer)) {
                "$localManufacturer (Windows)"
            } else {
                'display vendor code'
            })

            if (-not [string]::IsNullOrWhiteSpace($vendorId)) {
                $vendorLine = "{0,-15} = {1}" -f $vendorId, (Format-UiValue -Text $vendorName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($vendorLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($productId)) {
                $productLine = "{0,-15} = {1}" -f $productId, 'EDID/product code'
                $lines.Add("$pad$($_C.White)$($productLine)$($_C.Reset)")
            }
        }
        elseif ($res.Bus -in @('SCSI', 'USBSTOR', 'IDE')) {
            $isCompactStorageId = ([string]$res.IdType -match 'COMPACT')
            $deviceType = $res.Fields.DeviceType
            $vendorId = $res.Fields.VendorId
            $vendorDisplayId = [string](Get-NotePropertyValue -Object $res.Fields -Name 'VendorDisplayId')
            $productId = $res.Fields.ProductId
            $productDisplayId = [string](Get-NotePropertyValue -Object $res.Fields -Name 'ProductDisplayId')
            $revision = $res.Fields.Revision
            $deviceTypeName = $(if ($res.Lookup.DeviceTypeName) { $res.Lookup.DeviceTypeName } else { 'storage device' })
            $vendorName = $(if ($res.Lookup.VendorName) { $res.Lookup.VendorName } else { '' })
            $productName = $(if ($res.Lookup.ProductName) { $res.Lookup.ProductName } else { '' })
            $device = Get-NotePropertyValue -Object $Evidence -Name 'Device'
            $friendlyName = [string](Get-NotePropertyValue -Object $device -Name 'FriendlyName')
            if (-not [string]::IsNullOrWhiteSpace($friendlyName)) {
                $productName = $friendlyName
            }
            if ([string]::IsNullOrWhiteSpace($vendorDisplayId)) { $vendorDisplayId = $vendorId }
            if ([string]::IsNullOrWhiteSpace($productDisplayId)) { $productDisplayId = $productId }

            if (-not [string]::IsNullOrWhiteSpace($deviceType)) {
                $typeLine = "{0,-15} = {1}" -f $deviceType, (Format-UiValue -Text $deviceTypeName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.White)$($typeLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($vendorDisplayId)) {
                $vendorDisplayName = $(if ($vendorName -match '^(?i:NVME)$') { 'NVMe storage stack' } else { $vendorName })
                $vendorToken = $(if ($vendorName -match '^(?i:NVME)$') { "STACK_$vendorDisplayId" } else { "VEN_$vendorDisplayId" })
                $vendorLine = "{0,-15} = {1}" -f $vendorToken, (Format-UiValue -Text $vendorDisplayName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($vendorLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($productDisplayId)) {
                $productToken = $(if ($isCompactStorageId) { 'MODEL' } else { "PROD_$productDisplayId" })
                $productLine = "{0,-15} = {1}" -f $productToken, (Format-UiValue -Text $productName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Info)$($productLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($revision)) {
                $revisionLine = "{0,-15} = {1}" -f "REV_$revision", 'storage device revision'
                $lines.Add("$pad$($_C.Dim)$($revisionLine)$($_C.Reset)")
            }
        }
        elseif ($res.Bus -in @('ACPI', 'PNP')) {
            $vendorId = $res.Fields.VendorId
            $deviceId = $res.Fields.DeviceId
            $vendorName = $(if ($res.Lookup.VendorName) { Get-FormattedHardwareVendorName -Name $res.Lookup.VendorName } else { 'Unknown Vendor' })
            $deviceName = $(if ($res.Lookup.DeviceName) { $res.Lookup.DeviceName } else { '' })

            # 1. VEN
            $venText = "VEN_$vendorId"
            $venVal = Format-UiValue -Text $vendorName -MaxLength $valueWidth
            $venLine = "{0,-15} = {1}" -f $venText, $venVal
            $lines.Add("$pad$($_C.Dim)$($venLine)$($_C.Reset)")

            # 2. DEV
            $devText = "DEV_$deviceId"
            $devVal = $(if ($deviceName) { $deviceName } else { "device code" })
            $devLine = "{0,-15} = {1}" -f $devText, (Format-UiValue -Text $devVal -MaxLength $valueWidth)
            $lines.Add("$pad$($_C.White)$($devLine)$($_C.Reset)")
        }
    }
    catch {
        # Silent fail
    }

    return @($lines)
}




function Get-CompactSystemStatus {
    param([AllowEmptyString()][string]$StatusText)

    if ([string]::IsNullOrWhiteSpace($StatusText)) { return '' }
    $text = $StatusText -replace '^System scan complete:\s*', ''
    $text = $text -replace '\s*\|\s*\d+ms(?=\s*\|)', ''
    return $text
}

function Get-ActiveEvidenceBatchCount {
    if ($null -eq $script:EvidenceBatchState) { return 0 }

    $batchId = $script:EvidenceBatchState.BatchId
    return @(
        $script:ActiveSearches.Values | Where-Object {
            (Get-NotePropertyValue -Object $_ -Name 'EvidenceBatchId') -eq $batchId
        }
    ).Count
}

function Get-EvidenceBatchStatusText {
    if ($null -eq $script:EvidenceBatchState) { return '' }

    $state = $script:EvidenceBatchState
    $activeCount = Get-ActiveEvidenceBatchCount
    $queuedCount = $script:EvidenceBatchQueue.Count
    $total = [Math]::Max(1, [int]$state.Total)
    $completed = [Math]::Min([int]$state.Completed, $total)
    $elapsed = [int]((Get-Date) - $state.StartedAt).TotalSeconds
    $barWidth = 18
    $filled = [Math]::Min($barWidth, [int][Math]::Floor(($completed / $total) * $barWidth))
    $bar = ('#' * $filled) + ('-' * ($barWidth - $filled))

    if ($queuedCount -eq 0 -and $activeCount -eq 0 -and $completed -ge $total) {
        return "Evidence complete: $($state.Label) [$bar] $completed/$total | ${elapsed}s"
    }

    return "Evidence scan: $($state.Label) [$bar] $completed/$total | active $activeCount | queued $queuedCount | ${elapsed}s"
}

function Complete-EvidenceBatchIfFinished {
    if ($null -eq $script:EvidenceBatchState) { return }
    if ($script:EvidenceBatchQueue.Count -gt 0) { return }
    if ((Get-ActiveEvidenceBatchCount) -gt 0) { return }

    $state = $script:EvidenceBatchState
    $total = [Math]::Max(0, [int]$state.Total)
    if ([int]$state.Completed -lt $total) { return }

    $elapsed = [int]((Get-Date) - $state.StartedAt).TotalSeconds
    $errorText = $(if ([int]$state.Errors -gt 0) { " | $($state.Errors) errors" } else { '' })
    $script:SystemScanMessage = "Evidence scan complete: $($state.Label) | $($state.Completed)/$total devices | ${elapsed}s$errorText | $(Get-Date -Format 'HH:mm:ss')"
    $script:EvidenceBatchState = $null
    $script:EvidenceBatchQueuedIds.Clear()
}

function Wrap-PlainText {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width,
        [int]$MaxLines = 6
    )

    $Width = [Math]::Max(8, $Width)
    $words = (Remove-AnsiSequence -Text $Text) -split '\s+'
    $lines = [System.Collections.Generic.List[string]]::new()
    $current = ''

    foreach ($word in $words) {
        if ([string]::IsNullOrWhiteSpace($word)) { continue }
        $candidate = $(if ($current) { "$current $word" } else { $word })
        if ($candidate.Length -gt $Width) {
            if ($current) { $lines.Add($current) }
            $current = $word
            if ($current.Length -gt $Width) {
                $lines.Add((Format-PlainToWidth -Text $current -Width $Width).TrimEnd())
                $current = ''
            }
        } else {
            $current = $candidate
        }
        if ($lines.Count -ge $MaxLines) { break }
    }

    if ($current -and $lines.Count -lt $MaxLines) { $lines.Add($current) }
    return $lines
}

function Convert-MarkdownResultToDisplayText {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $plain = [regex]::Replace($Text, '\[([^\]]+)\]\((https?://[^)]+)\)', '$1 - $2')
    $plain = $plain -replace '\*\*', ''
    return $plain.Trim()
}

function Convert-MarkdownInlineToAnsi {
    param(
        [AllowEmptyString()][string]$Text,
        [string]$BaseColor = $null
    )

    if (-not $BaseColor) { $BaseColor = $_C.White }
    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $ansiText = [string]$Text
    $ansiText = [regex]::Replace($ansiText, '`([^`]+)`', {
        param($match)
        return "$($_C.Info)$($match.Groups[1].Value)$BaseColor"
    })
    $ansiText = [regex]::Replace($ansiText, '(https?://[^\s\]\)\}>"]+)', {
        param($match)
        $url = $match.Groups[1].Value.TrimEnd('.', ',', ';', ':')
        $suffix = $match.Groups[1].Value.Substring($url.Length)
        $label = New-TerminalHyperlink -Label $url -Url $url
        return "$($_C.Info)$label$BaseColor$suffix"
    })

    return $ansiText
}

function Add-WrappedMarkdownParagraphLines {
    param(
        [Parameter(Mandatory)]$Lines,
        [AllowEmptyString()][string]$Text,
        [int]$Width,
        [int]$MaxLines,
        [string]$Color = $null,
        [string]$FirstPrefix = '  ',
        [string]$RestPrefix = '  '
    )

    $remaining = [Math]::Max(0, $MaxLines)
    if ($remaining -le 0 -or [string]::IsNullOrWhiteSpace($Text)) { return 0 }
    if (-not $Color) { $Color = $_C.White }

    $firstPrefixPlain = Remove-AnsiSequence -Text $FirstPrefix
    $restPrefixPlain = Remove-AnsiSequence -Text $RestPrefix
    $bodyWidth = [Math]::Max(8, $Width - [Math]::Max($firstPrefixPlain.Length, $restPrefixPlain.Length))
    $wrapped = @(Wrap-PlainText -Text $Text -Width $bodyWidth -MaxLines $remaining)
    $written = 0

    for ($i = 0; $i -lt $wrapped.Count -and $written -lt $remaining; $i++) {
        $prefix = $(if ($i -eq 0) { $FirstPrefix } else { $RestPrefix })
        $prefixPlainLength = (Remove-AnsiSequence -Text $prefix).Length
        $lineWidth = [Math]::Max(1, $Width - $prefixPlainLength)
        $lineText = Convert-MarkdownInlineToAnsi -Text (Format-PlainToWidth -Text $wrapped[$i] -Width $lineWidth) -BaseColor $Color
        $Lines.Add("$prefix$Color$lineText$($_C.Reset)")
        $written++
    }

    return $written
}

function Add-MarkdownDetailTextLines {
    param(
        [Parameter(Mandatory)]$Lines,
        [AllowEmptyString()][string]$Text,
        [int]$Width,
        [int]$MaxLines
    )

    $remaining = [Math]::Max(0, $MaxLines)
    if ($remaining -le 0 -or [string]::IsNullOrWhiteSpace($Text)) { return }

    $normalized = $Text -replace "`r", ''
    foreach ($rawLine in ($normalized -split "`n")) {
        if ($remaining -le 0) { break }
        $line = $rawLine.TrimEnd()

        if ([string]::IsNullOrWhiteSpace($line)) {
            $Lines.Add('')
            $remaining--
            continue
        }

        if ($line -match '^\s{0,3}#{1,6}\s+(.+)$') {
            $heading = Convert-MarkdownResultToDisplayText -Text $Matches[1]
            $remaining -= Add-WrappedMarkdownParagraphLines -Lines $Lines -Text $heading -Width $Width -MaxLines $remaining -Color "$($_C.Bold)$($_C.H1)" -FirstPrefix '  ' -RestPrefix '  '
            continue
        }

        if ($line -match '^\s{0,3}(\d+)\.\s+(.+)$') {
            $number = $Matches[1]
            $body = Convert-MarkdownResultToDisplayText -Text $Matches[2]
            $remaining -= Add-WrappedMarkdownParagraphLines -Lines $Lines -Text $body -Width $Width -MaxLines $remaining -Color "$($_C.Bold)$($_C.White)" -FirstPrefix "  $($_C.Gold)$number.$($_C.Reset) " -RestPrefix '     '
            continue
        }

        if ($line -match '^\s{0,3}[*+-]\s+(.+)$') {
            $body = Convert-MarkdownResultToDisplayText -Text $Matches[1]
            $remaining -= Add-WrappedMarkdownParagraphLines -Lines $Lines -Text $body -Width $Width -MaxLines $remaining -Color $_C.White -FirstPrefix "  $($_C.OK)*$($_C.Reset) " -RestPrefix '    '
            continue
        }

        $display = Convert-MarkdownResultToDisplayText -Text $line
        $color = $(if ($display -match ':\s*$') { "$($_C.Bold)$($_C.H1)" } elseif ($display -match 'https?://') { $_C.Info } else { $_C.White })
        $remaining -= Add-WrappedMarkdownParagraphLines -Lines $Lines -Text $display -Width $Width -MaxLines $remaining -Color $color -FirstPrefix '  ' -RestPrefix '  '
    }
}

function Get-UrlsFromText {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $urls = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Text, 'https?://[^\s\]\)\}>"]+')) {
        $url = $match.Value.TrimEnd('.', ',', ';', ':')
        if (-not [string]::IsNullOrWhiteSpace($url) -and -not $urls.Contains($url)) {
            $urls.Add($url)
        }
    }
    return @($urls)
}

function New-TerminalHyperlink {
    param(
        [string]$Label,
        [string]$Url
    )

    $esc = [char]27
    $bel = [char]7
    return "$esc]8;;$Url$bel$Label$esc]8;;$bel"
}

function Add-WrappedDetailTextLines {
    param(
        [Parameter(Mandatory)]$Lines,
        [AllowEmptyString()][string]$Text,
        [int]$Width,
        [int]$MaxLines
    )

    $remaining = [Math]::Max(0, $MaxLines)
    if ($remaining -le 0 -or [string]::IsNullOrWhiteSpace($Text)) { return }

    $bodyWidth = [Math]::Max(8, $Width - 2)
    foreach ($paragraph in (($Text -replace "`r", '') -split "`n")) {
        if ($remaining -le 0) { break }
        if ([string]::IsNullOrWhiteSpace($paragraph)) {
            $lines.Add('')
            $remaining--
            continue
        }

        foreach ($line in (Wrap-PlainText -Text $paragraph -Width $bodyWidth -MaxLines $remaining)) {
            if ($remaining -le 0) { break }
            $lines.Add("$($_C.White)  $(Format-PlainToWidth -Text $line -Width $bodyWidth)$($_C.Reset)")
            $remaining--
        }
    }
}
