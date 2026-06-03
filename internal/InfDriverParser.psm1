Set-StrictMode -Version Latest

function Split-InfLineComment {
    param(
        [AllowEmptyString()]
        [string]$Line
    )

    $inQuote = $false
    for ($index = 0; $index -lt $Line.Length; $index++) {
        $character = $Line[$index]
        if ($character -eq '"') {
            $inQuote = -not $inQuote
            continue
        }
        if (-not $inQuote -and $character -eq ';') {
            return [pscustomobject]@{
                Body = $Line.Substring(0, $index)
                Comment = $Line.Substring($index + 1)
            }
        }
    }

    [pscustomobject]@{
        Body = $Line
        Comment = ''
    }
}

function Split-InfCsv {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    $values = [System.Collections.Generic.List[string]]::new()
    $buffer = [System.Text.StringBuilder]::new()
    $inQuote = $false

    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($character -eq '"') {
            $inQuote = -not $inQuote
            [void]$buffer.Append($character)
            continue
        }

        if (-not $inQuote -and $character -eq ',') {
            $values.Add(($buffer.ToString()).Trim())
            [void]$buffer.Clear()
            continue
        }

        [void]$buffer.Append($character)
    }

    $values.Add(($buffer.ToString()).Trim())
    return @($values)
}

function ConvertTo-InfHardwareId {
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
    $busMatch = [regex]::Match($trimmed, '^(?i)(PCI|USB|HID|ACPI|ROOT|SWD|BTH|BTHENUM)\\(.+)$')
    if ($busMatch.Success) {
        return ('{0}\{1}' -f $busMatch.Groups[1].Value.ToUpperInvariant(), $busMatch.Groups[2].Value.ToUpperInvariant())
    }

    if ($trimmed -match '^(?i)\*[A-Z0-9]{7,8}$') {
        return $trimmed.ToUpperInvariant()
    }

    return ''
}

function Resolve-InfStringToken {
    param(
        [AllowEmptyString()]
        [string]$Value,
        [hashtable]$Strings
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $trimmed = $Value.Trim().Trim('"')
    $tokenMatch = [regex]::Match($trimmed, '^%(.+)%$')
    if (-not $tokenMatch.Success) {
        return $trimmed
    }

    $key = $tokenMatch.Groups[1].Value
    if ($Strings.ContainsKey($key)) {
        return [string]$Strings[$key]
    }

    return $trimmed
}

function Get-InfSections {
    param(
        [string[]]$Lines
    )

    $sections = [ordered]@{}
    $currentSection = ''
    $currentEntries = $null

    for ($lineIndex = 0; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $rawLine = [string]$Lines[$lineIndex]
        $trimmed = $rawLine.Trim()
        $sectionMatch = [regex]::Match($trimmed, '^\[([^\]]+)\]')
        if ($sectionMatch.Success) {
            $currentSection = $sectionMatch.Groups[1].Value.Trim()
            if (-not $sections.Contains($currentSection)) {
                $sections[$currentSection] = [System.Collections.Generic.List[object]]::new()
            }
            $currentEntries = $sections[$currentSection]
            continue
        }

        if ([string]::IsNullOrWhiteSpace($currentSection) -or $null -eq $currentEntries) {
            continue
        }

        $splitLine = Split-InfLineComment -Line $rawLine
        $body = ([string]$splitLine.Body).Trim()
        if ([string]::IsNullOrWhiteSpace($body)) {
            continue
        }

        $equalsIndex = $body.IndexOf('=')
        if ($equalsIndex -lt 0) {
            $currentEntries.Add([pscustomobject]@{
                Section = $currentSection
                LineNumber = $lineIndex + 1
                RawLine = $rawLine
                Body = $body
                Key = ''
                Value = $body
                Values = @(Split-InfCsv -Text $body)
                Comment = [string]$splitLine.Comment
            })
            continue
        }

        $key = $body.Substring(0, $equalsIndex).Trim()
        $value = $body.Substring($equalsIndex + 1).Trim()
        $currentEntries.Add([pscustomobject]@{
            Section = $currentSection
            LineNumber = $lineIndex + 1
            RawLine = $rawLine
            Body = $body
            Key = $key
            Value = $value
            Values = @(Split-InfCsv -Text $value)
            Comment = [string]$splitLine.Comment
        })
    }

    return $sections
}

function Get-InfVersionMetadataFromSections {
    param(
        [hashtable]$Sections,
        [hashtable]$Strings
    )

    $metadata = [ordered]@{
        Provider = ''
        Class = ''
        ClassGuid = ''
        DriverVer = ''
        CatalogFile = ''
        Signature = ''
    }

    foreach ($sectionName in $Sections.Keys) {
        if ($sectionName -ne 'Version') {
            continue
        }

        foreach ($entry in @($Sections[$sectionName])) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.Key)) {
                continue
            }

            foreach ($metadataKey in @($metadata.Keys)) {
                if ([string]::Equals([string]$entry.Key, [string]$metadataKey, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $metadata[$metadataKey] = Resolve-InfStringToken -Value ([string]$entry.Value) -Strings $Strings
                }
            }
        }
    }

    return [pscustomobject]$metadata
}

function Get-InfStrings {
    param(
        [hashtable]$Sections
    )

    $strings = @{}
    foreach ($sectionName in $Sections.Keys) {
        if ($sectionName -notmatch '^(?i)Strings(\.|$)') {
            continue
        }

        foreach ($entry in @($Sections[$sectionName])) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.Key)) {
                continue
            }

            $strings[[string]$entry.Key] = ([string]$entry.Value).Trim().Trim('"')
        }
    }

    return $strings
}

function Get-InfManufacturerModelSectionNames {
    param(
        [hashtable]$Sections
    )

    $sectionSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($sectionName in $Sections.Keys) {
        if ($sectionName -ne 'Manufacturer') {
            continue
        }

        foreach ($entry in @($Sections[$sectionName])) {
            $values = @($entry.Values)
            if ($values.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$values[0])) {
                continue
            }

            $baseSection = ([string]$values[0]).Trim().Trim('"')
            if ([string]::IsNullOrWhiteSpace($baseSection)) {
                continue
            }

            [void]$sectionSet.Add($baseSection)
            if ($values.Count -gt 1) {
                foreach ($decoration in @($values | Select-Object -Skip 1)) {
                    $cleanDecoration = ([string]$decoration).Trim().Trim('"')
                    if (-not [string]::IsNullOrWhiteSpace($cleanDecoration)) {
                        [void]$sectionSet.Add(('{0}.{1}' -f $baseSection, $cleanDecoration))
                    }
                }
            }
        }
    }

    return @($sectionSet | Sort-Object)
}

function Get-InfModelHardwareIds {
    param(
        [hashtable]$Sections,
        [hashtable]$Strings,
        [string[]]$ModelSectionNames
    )

    $modelSectionSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($modelSectionName in @($ModelSectionNames)) {
        if (-not [string]::IsNullOrWhiteSpace($modelSectionName)) {
            [void]$modelSectionSet.Add($modelSectionName)
        }
    }

    $idSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ids = [System.Collections.Generic.List[object]]::new()
    foreach ($sectionName in $Sections.Keys) {
        if (-not $modelSectionSet.Contains([string]$sectionName)) {
            continue
        }

        foreach ($entry in @($Sections[$sectionName])) {
            $values = @($entry.Values)
            if ($values.Count -lt 2) {
                continue
            }

            $installSection = ([string]$values[0]).Trim().Trim('"')
            $descriptionToken = [string]$entry.Key
            $description = Resolve-InfStringToken -Value $descriptionToken -Strings $Strings
            foreach ($rawId in @($values | Select-Object -Skip 1)) {
                $hardwareId = ConvertTo-InfHardwareId -Value ([string]$rawId)
                if ([string]::IsNullOrWhiteSpace($hardwareId) -or -not $idSet.Add(('{0}|{1}|{2}' -f $sectionName, $installSection, $hardwareId))) {
                    continue
                }

                $ids.Add([pscustomobject]@{
                    HardwareId = $hardwareId
                    Label = $descriptionToken
                    ResolvedLabel = $description
                    Line = ([string]$entry.Body).Trim()
                    LineNumber = [int]$entry.LineNumber
                    ModelSection = [string]$sectionName
                    InstallSection = $installSection
                    Source = 'ManufacturerModelSection'
                })
            }
        }
    }

    return @($ids)
}

function Get-InfFallbackHardwareIds {
    param(
        [hashtable]$Sections,
        [hashtable]$Strings,
        [object[]]$ExistingHardwareIds
    )

    $existingSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($existingHardwareId in @($ExistingHardwareIds)) {
        [void]$existingSet.Add([string]$existingHardwareId.HardwareId)
    }

    $ids = [System.Collections.Generic.List[object]]::new()
    foreach ($sectionName in $Sections.Keys) {
        foreach ($entry in @($Sections[$sectionName])) {
            foreach ($value in @($entry.Values)) {
                $hardwareId = ConvertTo-InfHardwareId -Value ([string]$value)
                if ([string]::IsNullOrWhiteSpace($hardwareId) -or $existingSet.Contains($hardwareId)) {
                    continue
                }

                [void]$existingSet.Add($hardwareId)
                $description = Resolve-InfStringToken -Value ([string]$entry.Key) -Strings $Strings
                $ids.Add([pscustomobject]@{
                    HardwareId = $hardwareId
                    Label = [string]$entry.Key
                    ResolvedLabel = $description
                    Line = ([string]$entry.Body).Trim()
                    LineNumber = [int]$entry.LineNumber
                    ModelSection = [string]$sectionName
                    InstallSection = ''
                    Source = 'FallbackLineScan'
                })
            }
        }
    }

    return @($ids)
}

function ConvertFrom-InfDriverFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    $lines = @(Get-Content -LiteralPath $resolvedPath -ErrorAction Stop)
    $sections = Get-InfSections -Lines $lines
    $strings = Get-InfStrings -Sections $sections
    $modelSectionNames = @(Get-InfManufacturerModelSectionNames -Sections $sections)
    $modelHardwareIds = @(Get-InfModelHardwareIds -Sections $sections -Strings $strings -ModelSectionNames $modelSectionNames)
    $fallbackHardwareIds = if ($modelHardwareIds.Count -eq 0) {
        @(Get-InfFallbackHardwareIds -Sections $sections -Strings $strings -ExistingHardwareIds $modelHardwareIds)
    }
    else {
        @()
    }
    $metadata = Get-InfVersionMetadataFromSections -Sections $sections -Strings $strings
    $allHardwareIds = @($modelHardwareIds + $fallbackHardwareIds)

    [pscustomobject]@{
        Path = $resolvedPath
        SectionCount = $sections.Count
        StringCount = $strings.Count
        ModelSectionNames = @($modelSectionNames)
        ModelHardwareIds = @($modelHardwareIds)
        FallbackHardwareIds = @($fallbackHardwareIds)
        HardwareIds = @($allHardwareIds)
        Metadata = $metadata
        ParseMode = 'SectionAware'
    }
}

Export-ModuleMember -Function ConvertFrom-InfDriverFile
