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

Export-ModuleMember -Function ConvertFrom-EdidBytes, Get-MonitorEdidFromRegistry
