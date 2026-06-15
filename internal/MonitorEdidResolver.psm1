Set-StrictMode -Version Latest

function ConvertFrom-EdidManufacturerCode {
    param(
        [byte] $High,
        [byte] $Low
    )

    $word = ([int]$High -shl 8) -bor [int]$Low
    $chars = @(
        (($word -shr 10) -band 0x1F),
        (($word -shr 5) -band 0x1F),
        ($word -band 0x1F)
    )

    return (($chars | ForEach-Object {
        if ($_ -ge 1 -and $_ -le 26) {
            [char]($_ + 64)
        }
        else {
            '?'
        }
    }) -join '')
}

function ConvertTo-EdidText {
    param(
        [byte[]] $Bytes
    )

    if ($null -eq $Bytes -or $Bytes.Count -eq 0) {
        return ''
    }

    $text = [System.Text.Encoding]::ASCII.GetString($Bytes)
    $text = $text -replace "[`0`r`n]", ''
    return $text.Trim()
}

function ConvertFrom-EdidDetailedTiming {
    param(
        [byte[]] $Descriptor
    )

    if ($null -eq $Descriptor -or $Descriptor.Count -lt 18) {
        return $null
    }

    $pixelClock10Khz = [int]$Descriptor[0] + ([int]$Descriptor[1] -shl 8)
    if ($pixelClock10Khz -le 0) {
        return $null
    }

    $hActive = [int]$Descriptor[2] + (([int]$Descriptor[4] -band 0xF0) -shl 4)
    $hBlank = [int]$Descriptor[3] + (([int]$Descriptor[4] -band 0x0F) -shl 8)
    $vActive = [int]$Descriptor[5] + (([int]$Descriptor[7] -band 0xF0) -shl 4)
    $vBlank = [int]$Descriptor[6] + (([int]$Descriptor[7] -band 0x0F) -shl 8)
    $refreshRate = $null

    if (($hActive + $hBlank) -gt 0 -and ($vActive + $vBlank) -gt 0) {
        $refreshRate = [Math]::Round(($pixelClock10Khz * 10000.0) / (($hActive + $hBlank) * ($vActive + $vBlank)), 2)
    }

    return [pscustomobject]@{
        Width         = $hActive
        Height        = $vActive
        RefreshRateHz = $refreshRate
        PixelClockKHz = $pixelClock10Khz * 10
    }
}

function ConvertFrom-EdidBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [byte[]] $Edid
    )

    $bytes = @($Edid)
    $isLongEnough = $bytes.Count -ge 128
    $headerValid = $false
    if ($isLongEnough) {
        $expectedHeader = [byte[]](0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00)
        $headerValid = $true
        for ($i = 0; $i -lt $expectedHeader.Count; $i++) {
            if ($bytes[$i] -ne $expectedHeader[$i]) {
                $headerValid = $false
                break
            }
        }
    }

    $checksumValid = $false
    if ($isLongEnough) {
        $sum = 0
        for ($i = 0; $i -lt 128; $i++) {
            $sum += [int]$bytes[$i]
        }
        $checksumValid = (($sum % 256) -eq 0)
    }

    if (-not $isLongEnough) {
        return [pscustomobject]@{
            IsValid       = $false
            HeaderValid   = $false
            ChecksumValid = $false
            Error         = "EDID is too short: $($bytes.Count) bytes"
        }
    }

    $manufacturerId = ConvertFrom-EdidManufacturerCode -High $bytes[8] -Low $bytes[9]
    $productCodeValue = [int]$bytes[10] + ([int]$bytes[11] -shl 8)
    $serialNumber = [uint32]([uint32]$bytes[12] -bor ([uint32]$bytes[13] -shl 8) -bor ([uint32]$bytes[14] -shl 16) -bor ([uint32]$bytes[15] -shl 24))
    $monitorName = ''
    $serialText = ''
    $asciiText = [System.Collections.Generic.List[string]]::new()
    $preferredTiming = $null

    foreach ($offset in 54, 72, 90, 108) {
        $descriptor = [byte[]]($bytes[$offset..($offset + 17)])
        if ($null -eq $preferredTiming) {
            $preferredTiming = ConvertFrom-EdidDetailedTiming -Descriptor $descriptor
        }

        if ($descriptor[0] -eq 0x00 -and $descriptor[1] -eq 0x00 -and $descriptor[2] -eq 0x00) {
            $textBytes = [byte[]]($descriptor[5..17])
            switch ($descriptor[3]) {
                0xFC {
                    $monitorName = ConvertTo-EdidText -Bytes $textBytes
                    break
                }
                0xFF {
                    $serialText = ConvertTo-EdidText -Bytes $textBytes
                    break
                }
                0xFE {
                    $text = ConvertTo-EdidText -Bytes $textBytes
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        $asciiText.Add($text)
                    }
                    break
                }
            }
        }
    }

    $gamma = $null
    if ($bytes[23] -ne 0xFF) {
        $gamma = [Math]::Round(([int]$bytes[23] + 100) / 100.0, 2)
    }

    return [pscustomobject]@{
        IsValid           = ($headerValid -and $checksumValid)
        HeaderValid       = $headerValid
        ChecksumValid     = $checksumValid
        ManufacturerId    = $manufacturerId
        ProductCode       = ('{0:X4}' -f $productCodeValue)
        SerialNumber      = $serialNumber
        ManufactureWeek   = [int]$bytes[16]
        ManufactureYear   = 1990 + [int]$bytes[17]
        EdidVersion       = ('{0}.{1}' -f $bytes[18], $bytes[19])
        InputType         = if (($bytes[20] -band 0x80) -ne 0) { 'Digital' } else { 'Analog' }
        WidthCm           = [int]$bytes[21]
        HeightCm          = [int]$bytes[22]
        Gamma             = $gamma
        MonitorName       = $monitorName
        SerialText        = $serialText
        AsciiText         = @($asciiText)
        PreferredTiming   = $preferredTiming
        ExtensionCount    = [int]$bytes[126]
        RawLength         = $bytes.Count
    }
}

function Get-MonitorEdidFromRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $InstanceId
    )

    if ([string]::IsNullOrWhiteSpace($InstanceId)) {
        return $null
    }

    $candidatePaths = [System.Collections.Generic.List[string]]::new()
    if ($InstanceId -match '^(?i:DISPLAY)\\') {
        $candidatePaths.Add("Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\$InstanceId\Device Parameters")
    }
    elseif ($InstanceId -match '^(?i:DISPLAY\\)?(?<DisplayId>[A-Z]{3}[0-9A-F]{4})$') {
        $displayId = $Matches.DisplayId.ToUpperInvariant()
        $displayRoot = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\DISPLAY\$displayId"
        try {
            foreach ($child in @(Get-ChildItem -LiteralPath $displayRoot -ErrorAction Stop)) {
                $candidatePaths.Add((Join-Path -Path $child.PSPath -ChildPath 'Device Parameters'))
            }
        }
        catch {
            return $null
        }
    }
    else {
        return $null
    }

    foreach ($path in @($candidatePaths | Select-Object -Unique)) {
        try {
            $item = Get-ItemProperty -LiteralPath $path -Name 'EDID' -ErrorAction Stop
            $edid = [byte[]]$item.EDID
            if ($null -eq $edid -or $edid.Count -eq 0) {
                continue
            }

            $decoded = ConvertFrom-EdidBytes -Edid $edid
            $decoded | Add-Member -NotePropertyName 'Source' -NotePropertyValue 'Windows Registry EDID' -Force
            $decoded | Add-Member -NotePropertyName 'RegistryPath' -NotePropertyValue $path -Force
            return $decoded
        }
        catch {
            continue
        }
    }

    return $null
}

function Get-MonitorWmiEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InstanceId
    )

    if ([string]::IsNullOrWhiteSpace($InstanceId)) {
        return $null
    }

    function Convert-CharCodesToString {
        param($Codes)
        if ($null -eq $Codes -or $Codes.Count -eq 0) { return '' }
        try {
            $bytes = [byte[]]@($Codes)
            $str = [System.Text.Encoding]::ASCII.GetString($bytes)
            return $str.Trim(([char]0), ' ', "`r", "`n", "`t")
        }
        catch {
            return ''
        }
    }

    if ($null -eq $script:GlobalWmiMonitorIDs) {
        $script:GlobalWmiMonitorIDs = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue)
    }
    if ($null -eq $script:GlobalWmiMonitorBasics) {
        $script:GlobalWmiMonitorBasics = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue)
    }
    if ($null -eq $script:GlobalWmiMonitorConnections) {
        $script:GlobalWmiMonitorConnections = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction SilentlyContinue)
    }
    if ($null -eq $script:GlobalWmiMonitorModes) {
        $script:GlobalWmiMonitorModes = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction SilentlyContinue)
    }

    $wmiId = $null
    $wmiBasic = $null
    $wmiConn = $null
    $wmiModes = $null

    if ($script:GlobalWmiMonitorIDs) {
        $wmiId = $script:GlobalWmiMonitorIDs |
            Where-Object { $_.InstanceName -like "*$InstanceId*" -or $InstanceId -like "*$($_.InstanceName -replace '_\d+$', '')*" } |
            Select-Object -First 1
    }
    if ($script:GlobalWmiMonitorBasics) {
        $wmiBasic = $script:GlobalWmiMonitorBasics |
            Where-Object { $_.InstanceName -like "*$InstanceId*" -or $InstanceId -like "*$($_.InstanceName -replace '_\d+$', '')*" } |
            Select-Object -First 1
    }
    if ($script:GlobalWmiMonitorConnections) {
        $wmiConn = $script:GlobalWmiMonitorConnections |
            Where-Object { $_.InstanceName -like "*$InstanceId*" -or $InstanceId -like "*$($_.InstanceName -replace '_\d+$', '')*" } |
            Select-Object -First 1
    }
    if ($script:GlobalWmiMonitorModes) {
        $wmiModes = $script:GlobalWmiMonitorModes |
            Where-Object { $_.InstanceName -like "*$InstanceId*" -or $InstanceId -like "*$($_.InstanceName -replace '_\d+$', '')*" } |
            Select-Object -First 1
    }

    if ($null -eq $wmiId -and $null -eq $wmiBasic -and $null -eq $wmiConn -and $null -eq $wmiModes) {
        return $null
    }

    $manufacturerId = ''
    $productCode = ''
    $userFriendlyName = ''
    $serialNumber = ''
    $weekOfManufacture = $null
    $yearOfManufacture = $null

    if ($wmiId) {
        $manufacturerId = Convert-CharCodesToString -Codes $wmiId.ManufacturerName
        $productCode = Convert-CharCodesToString -Codes $wmiId.ProductCodeID
        $userFriendlyName = Convert-CharCodesToString -Codes $wmiId.UserFriendlyName
        $serialNumber = Convert-CharCodesToString -Codes $wmiId.SerialNumberID
        $weekOfManufacture = $wmiId.WeekOfManufacture
        $yearOfManufacture = $wmiId.YearOfManufacture
    }

    $maxHorizontalCm = $null
    $maxVerticalCm = $null
    if ($wmiBasic) {
        $maxHorizontalCm = $wmiBasic.MaxHorizontalImageSize
        $maxVerticalCm = $wmiBasic.MaxVerticalImageSize
    }

    $videoOutputTech = $null
    if ($wmiConn) {
        $videoOutputTech = $wmiConn.VideoOutputTechnology
    }

    $preferredTiming = $null
    if ($wmiModes) {
        $idx = $wmiModes.PreferredMonitorSourceModeIndex
        if ($null -ne $idx -and $idx -lt $wmiModes.MonitorSourceModes.Count) {
            $prefMode = $wmiModes.MonitorSourceModes[$idx]
            $refreshRate = $null
            if ($prefMode.VerticalRefreshRateDenominator -gt 0) {
                $refreshRate = [Math]::Round($prefMode.VerticalRefreshRateNumerator / $prefMode.VerticalRefreshRateDenominator, 2)
            }
            $preferredTiming = [pscustomobject]@{
                Width = $prefMode.HorizontalActivePixels
                Height = $prefMode.VerticalActivePixels
                RefreshRateHz = $refreshRate
                PixelClockKHz = [Math]::Round($prefMode.PixelClockRate / 1000.0)
            }
        }
    }

    return [pscustomobject]@{
        InstanceName          = if ($wmiId) { $wmiId.InstanceName } elseif ($wmiBasic) { $wmiBasic.InstanceName } else { '' }
        ManufacturerId        = $manufacturerId
        ProductCode           = $productCode
        UserFriendlyName      = $userFriendlyName
        SerialNumber          = $serialNumber
        ManufactureWeek       = $weekOfManufacture
        ManufactureYear       = $yearOfManufacture
        MaxHorizontalCm       = $maxHorizontalCm
        MaxVerticalCm         = $maxVerticalCm
        VideoOutputTechnology = $videoOutputTech
        PreferredTiming       = $preferredTiming
        Source                = 'WMI Monitor Core'
    }
}

function Get-MonitorInfEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InfName,
        [Parameter(Mandatory)]
        [string]$SectionName,
        [Parameter(Mandatory)]
        [string[]]$HardwareIds
    )

    $infDir = "C:\Windows\INF"

    function Get-ModelNameFromInf {
        param([string]$Path, [string]$Section)
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $lines = Get-Content -LiteralPath $Path
        $token = $null
        foreach ($line in $lines) {
            if ($line -match '^\s*%([^%]+)%\s*=\s*([A-Za-z0-9_.-]+)') {
                if ($Matches[2].Trim() -ieq $Section) {
                    $token = $Matches[1].Trim()
                    break
                }
            }
        }
        if (-not $token) {
            foreach ($line in $lines) {
                if ($line -match '^\s*%([^%]+)%\s*=\s*([^,\s]+)') {
                    $s = $Matches[2].Trim()
                    if ($Section -like "$s*") {
                        $token = $Matches[1].Trim()
                        break
                    }
                }
            }
        }
        if ($token) {
            foreach ($line in $lines) {
                if ($line -match ('^\s*' + [regex]::Escape($token) + '\s*=\s*"(.*)"') -or
                    $line -match ('^\s*' + [regex]::Escape($token) + '\s*=\s*(.*)')) {
                    return $Matches[1].Trim('"').Trim()
                }
            }
        }
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($InfName)) {
        if ($InfName -ine 'monitor.inf') {
            $assignedPath = Join-Path $infDir $InfName
            $model = Get-ModelNameFromInf -Path $assignedPath -Section $SectionName
            if ($model) {
                return [pscustomobject]@{
                    ModelName = $model
                    InfPath   = $assignedPath
                    IsGeneric = $false
                    Source    = "Installed monitor INF ($InfName)"
                }
            }
        }
    }

    $targetMode = 'Local'
    if (Get-Variable -Name 'TargetMode' -Scope Global -ErrorAction SilentlyContinue) {
        $targetMode = $global:TargetMode
    }
    if ($targetMode -ne 'Local') {
        # Bypass local INF folder scans for remote snapshot and offline targets
        $HardwareIds = $null
    }

    if ($HardwareIds) {
        $cleanIds = @($HardwareIds | ForEach-Object { ($_ -replace '^MONITOR\\', '') })
        try {
            $patterns = [System.Collections.Generic.List[string]]::new()
            foreach ($id in $cleanIds) {
                $escaped = [regex]::Escape($id)
                $patterns.Add("Monitor\\$escaped")
                $patterns.Add("^$escaped")
            }
            $patternStr = $patterns -join '|'

            # Fast path: use compiled C# Select-String to pinpoint the matching oem*.inf file
            $match = Select-String -Path (Join-Path -Path $infDir -ChildPath 'oem*.inf') -Pattern $patternStr -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $match) {
                $matchedInfPath = $match.Path
                $lines = Get-Content -LiteralPath $matchedInfPath -ErrorAction SilentlyContinue
                if ($lines) {
                    # Once matched, parse only this specific file to extract the friendly model name
                    foreach ($line in $lines) {
                        foreach ($id in $cleanIds) {
                            if ($line -match ('Monitor\\' + [regex]::Escape($id)) -or $line -match [regex]::Escape($id)) {
                                if ($line -match '^\s*%([^%]+)%\s*=\s*([A-Za-z0-9_.-]+)') {
                                    $token = $Matches[1].Trim()
                                    $section = $Matches[2].Trim()
                                    foreach ($strLine in $lines) {
                                        if ($strLine -match ('^\s*' + [regex]::Escape($token) + '\s*=\s*"(.*)"') -or
                                            $strLine -match ('^\s*' + [regex]::Escape($token) + '\s*=\s*(.*)')) {
                                            return [pscustomobject]@{
                                                ModelName = $Matches[1].Trim('"').Trim()
                                                InfPath   = $matchedInfPath
                                                IsGeneric = $false
                                                Source    = "Found in monitor INF ($(Split-Path -Leaf $matchedInfPath))"
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch {}
    }

    if ($InfName -eq 'monitor.inf') {
        $monitorInfPath = Join-Path $infDir 'monitor.inf'
        $model = Get-ModelNameFromInf -Path $monitorInfPath -Section $SectionName
        if (-not $model) { $model = "Generic PnP Monitor" }
        return [pscustomobject]@{
            ModelName = $model
            InfPath   = $monitorInfPath
            IsGeneric = $true
            Source    = "Generic System INF (monitor.inf)"
        }
    }

    return $null
}

function Clear-MonitorWmiModuleCache {
    $script:GlobalWmiMonitorIDs = $null
    $script:GlobalWmiMonitorBasics = $null
    $script:GlobalWmiMonitorConnections = $null
    $script:GlobalWmiMonitorModes = $null
}

function Initialize-MonitorWmiModuleCache {
    if ($global:TargetMode -and $global:TargetMode -ne 'Local') {
        return
    }
    if ($null -eq $script:GlobalWmiMonitorIDs) {
        $script:GlobalWmiMonitorIDs = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue)
    }
    if ($null -eq $script:GlobalWmiMonitorBasics) {
        $script:GlobalWmiMonitorBasics = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue)
    }
    if ($null -eq $script:GlobalWmiMonitorConnections) {
        $script:GlobalWmiMonitorConnections = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction SilentlyContinue)
    }
    if ($null -eq $script:GlobalWmiMonitorModes) {
        $script:GlobalWmiMonitorModes = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction SilentlyContinue)
    }
}

Export-ModuleMember -Function ConvertFrom-EdidBytes, Get-MonitorEdidFromRegistry, Get-MonitorWmiEvidence, Get-MonitorInfEvidence, Clear-MonitorWmiModuleCache, Initialize-MonitorWmiModuleCache
