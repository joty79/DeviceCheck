[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '', Justification = 'Repository policy uses UTF-8 without BOM for PowerShell source.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-* functions build evidence models and optionally persist the caller-requested JSON artifact; they do not mutate driver or system state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The plural helper names accurately describe the collections returned from INF parsing.')]
param()

Set-StrictMode -Version Latest

function Get-DriverPackageViewValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Test-DriverPackageViewIdRelated {
    param(
        [AllowEmptyString()][string]$Left,
        [AllowEmptyString()][string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    $leftValue = $Left.Trim().ToUpperInvariant()
    $rightValue = $Right.Trim().ToUpperInvariant()
    return $leftValue -eq $rightValue -or $leftValue.StartsWith($rightValue) -or $rightValue.StartsWith($leftValue)
}

function Get-DriverPackageInfRole {
    param([AllowEmptyString()][string]$Class)

    switch -Regex ($Class.Trim()) {
        '^(?i)Extension$'             { return 'Extension' }
        '^(?i)SoftwareComponent$'     { return 'ComponentDriver' }
        '^(?i)AudioProcessingObject$' { return 'ComponentDriver' }
        default                       { return 'FunctionDriver' }
    }
}

function Get-DriverPackageInfExtensionId {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $result = [regex]::Match($Text, '(?im)^\s*ExtensionId\s*=\s*([^;\r\n]+)')
    if (-not $result.Success) { return '' }
    return $result.Groups[1].Value.Trim().Trim('"')
}

function Get-DriverPackageInfComponentIds {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $componentIds = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($Text -split "`r?`n")) {
        $trimmed = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith(';')) { continue }
        $result = [regex]::Match($trimmed, '^(?i)ComponentIDs?\s*=\s*([^;]+)')
        if (-not $result.Success) { continue }
        foreach ($field in @($result.Groups[1].Value.Split(','))) {
            $componentId = $field.Trim().Trim('"')
            if ([string]::IsNullOrWhiteSpace($componentId)) { continue }
            if ($componentId -notmatch '^(?i)(SWC|ROOT|ACPI|PCI|USB|HDAUDIO)\\') {
                $componentId = "SWC\$componentId"
            }
            $componentIds.Add($componentId.ToUpperInvariant())
        }
    }
    return @($componentIds | Sort-Object -Unique)
}

function Get-DriverPackageInfAddComponents {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $componentNames = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($Text -split "`r?`n")) {
        $trimmed = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith(';')) { continue }
        $result = [regex]::Match($trimmed, '^(?i)AddComponent\s*=\s*([^,;]+)')
        if ($result.Success) { $componentNames.Add($result.Groups[1].Value.Trim()) }
    }
    return @($componentNames | Sort-Object -Unique)
}

function Resolve-DriverPackageInfPath {
    param(
        [AllowEmptyString()][string]$ExtractedRoot,
        [AllowEmptyString()][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($ExtractedRoot) -or [string]::IsNullOrWhiteSpace($RelativePath)) { return '' }
    $path = Join-Path $ExtractedRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    return (Resolve-Path -LiteralPath $path).ProviderPath
}

function New-DriverPackageTopology {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Preview,
        [AllowEmptyString()][string]$OutputPath = ''
    )

    $extractedRoot = [string](Get-DriverPackageViewValue $Preview 'ExistingExtractedRoot' '')
    $previewInfFiles = @(Get-DriverPackageViewValue $Preview 'InfFiles' @())
    $previewMatches = @(Get-DriverPackageViewValue $Preview 'Matches' @())
    $infPackages = [System.Collections.Generic.List[object]]::new()
    $infByPath = @{}

    foreach ($previewInf in $previewInfFiles) {
        $relativePath = [string](Get-DriverPackageViewValue $previewInf 'RelativePath' '')
        $class = [string](Get-DriverPackageViewValue $previewInf 'Class' '')
        $fullPath = Resolve-DriverPackageInfPath -ExtractedRoot $extractedRoot -RelativePath $relativePath
        $text = if (-not [string]::IsNullOrWhiteSpace($fullPath)) {
            [string](Get-Content -LiteralPath $fullPath -Raw -ErrorAction SilentlyContinue)
        } else { '' }
        $package = [pscustomobject]@{
            Inf                 = $relativePath
            FileName            = [string](Get-DriverPackageViewValue $previewInf 'FileName' (Split-Path $relativePath -Leaf))
            FullPath            = $fullPath
            Class               = $class
            Role                = Get-DriverPackageInfRole -Class $class
            DriverVer           = [string](Get-DriverPackageViewValue $previewInf 'DriverVer' '')
            Provider            = [string](Get-DriverPackageViewValue $previewInf 'Provider' '')
            CatalogFile         = [string](Get-DriverPackageViewValue $previewInf 'CatalogFile' '')
            Hash                = [string](Get-DriverPackageViewValue $previewInf 'Hash' '')
            SupportedDeviceIds  = @((Get-DriverPackageViewValue $previewInf 'SupportedDeviceIds' @()) | ForEach-Object { ([string]$_).ToUpperInvariant() })
            ExtensionId         = Get-DriverPackageInfExtensionId -Text $text
            AddComponents       = @(Get-DriverPackageInfAddComponents -Text $text)
            DeclaredComponentIds = @(Get-DriverPackageInfComponentIds -Text $text)
        }
        $infPackages.Add($package)
        if (-not [string]::IsNullOrWhiteSpace($relativePath)) { $infByPath[$relativePath.ToUpperInvariant()] = $package }
    }

    $matchApplications = [System.Collections.Generic.List[object]]::new()
    foreach ($previewMatch in $previewMatches) {
        $relativePath = [string](Get-DriverPackageViewValue $previewMatch 'Inf' '')
        $infPackage = $infByPath[$relativePath.ToUpperInvariant()]
        if ($null -eq $infPackage) { continue }
        $matchedId = ([string](Get-DriverPackageViewValue $previewMatch 'MatchedId' '')).ToUpperInvariant()
        $isSupportedModel = @($infPackage.SupportedDeviceIds | Where-Object {
            Test-DriverPackageViewIdRelated -Left ([string]$_) -Right $matchedId
        }).Count -gt 0
        $isDeclaredComponent = @($infPackage.DeclaredComponentIds | Where-Object {
            ([string]$_).Equals($matchedId, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0

        $relation = switch ($infPackage.Role) {
            'Extension' {
                if ($isDeclaredComponent -and -not $isSupportedModel) { 'ComponentDeclaration' }
                else { 'ExtensionApplication' }
            }
            'ComponentDriver' { 'ComponentBinding' }
            default { 'FunctionBinding' }
        }

        $matchApplications.Add([pscustomobject]@{
            DeviceName  = [string](Get-DriverPackageViewValue $previewMatch 'DeviceName' '')
            DeviceClass = [string](Get-DriverPackageViewValue $previewMatch 'DeviceClass' '')
            InstanceId  = [string](Get-DriverPackageViewValue $previewMatch 'InstanceId' '')
            MatchKind   = [string](Get-DriverPackageViewValue $previewMatch 'MatchKind' '')
            MatchedId   = $matchedId
            Inf         = $relativePath
            InfFileName = $infPackage.FileName
            InfClass    = $infPackage.Class
            InfRole     = $infPackage.Role
            Relation    = $relation
            DriverVer   = $infPackage.DriverVer
            Provider    = $infPackage.Provider
            ExtensionId = $infPackage.ExtensionId
            IsDirect    = $relation -ne 'ComponentDeclaration'
        })
    }

    $devices = [System.Collections.Generic.List[object]]::new()
    foreach ($deviceGroup in @($matchApplications | Group-Object InstanceId)) {
        $applications = @($deviceGroup.Group | Sort-Object @{
            Expression = {
                switch ($_.Relation) {
                    'FunctionBinding'      { 0 }
                    'ExtensionApplication' { 1 }
                    'ComponentBinding'     { 2 }
                    default                { 3 }
                }
            }
        }, Inf -Unique)
        $first = $applications | Select-Object -First 1
        $devices.Add([pscustomobject]@{
            InstanceId       = [string]$first.InstanceId
            DeviceName       = [string]$first.DeviceName
            DeviceClass      = [string]$first.DeviceClass
            StackRootId      = [string]$first.InstanceId
            StackRootName    = [string]$first.DeviceName
            IsStackRoot      = @($applications | Where-Object Relation -in @('FunctionBinding','ExtensionApplication')).Count -gt 0
            DirectMatches    = @($applications | Where-Object IsDirect)
            DeclarationMatches = @($applications | Where-Object { -not $_.IsDirect })
            AllMatches       = $applications
        })
    }

    $edges = [System.Collections.Generic.List[object]]::new()
    foreach ($extension in @($infPackages | Where-Object Role -eq 'Extension')) {
        $parentApplications = @($matchApplications | Where-Object {
            $_.Inf -eq $extension.Inf -and $_.Relation -eq 'ExtensionApplication'
        })
        if ($parentApplications.Count -eq 0) { continue }

        foreach ($componentId in @($extension.DeclaredComponentIds)) {
            $childDevices = @($devices | Where-Object {
                $candidateDevice = $_
                @($candidateDevice.AllMatches | Where-Object {
                    ([string]$_.MatchedId).Equals([string]$componentId, [StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0
            })
            foreach ($parentApplication in $parentApplications) {
                foreach ($childDevice in $childDevices) {
                    if ($parentApplication.InstanceId -eq $childDevice.InstanceId) { continue }
                    $edges.Add([pscustomobject]@{
                        FromInstanceId = [string]$parentApplication.InstanceId
                        ToInstanceId   = [string]$childDevice.InstanceId
                        Kind           = 'DeclaresComponent'
                        Inf            = $extension.Inf
                        ExtensionId    = $extension.ExtensionId
                        ComponentId    = [string]$componentId
                        Confidence     = if ($parentApplications.Count -eq 1) { 'Exact' } else { 'MultipleParentTargets' }
                    })
                    $childDevice.StackRootId = [string]$parentApplication.InstanceId
                    $childDevice.StackRootName = [string]$parentApplication.DeviceName
                    $childDevice.IsStackRoot = $false
                }
            }
        }
    }

    $categories = @($devices | Group-Object DeviceClass | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            Name = if ([string]::IsNullOrWhiteSpace($_.Name)) { 'Unknown class' } else { $_.Name }
            Devices = @($_.Group | Sort-Object DeviceName, InstanceId)
        }
    })
    $directBindings = @($matchApplications | Where-Object Relation -in @('FunctionBinding','ComponentBinding'))
    $extensionApplications = @($matchApplications | Where-Object Relation -eq 'ExtensionApplication')
    $declarationRows = @($matchApplications | Where-Object Relation -eq 'ComponentDeclaration')
    $uniqueApplicationKeys = @($directBindings + $extensionApplications | ForEach-Object { "$($_.Inf)|$($_.InstanceId)|$($_.Relation)" } | Sort-Object -Unique)
    $linkedEdges = @($edges | ForEach-Object { "$($_.FromInstanceId)|$($_.ToInstanceId)|$($_.Inf)" } | Sort-Object -Unique)

    $topology = [pscustomobject]@{
        SchemaVersion = 1
        GeneratedAt = (Get-Date).ToString('o')
        InstallerPath = [string](Get-DriverPackageViewValue $Preview 'InstallerPath' '')
        InstallerName = [string](Get-DriverPackageViewValue $Preview 'InstallerName' '')
        InstallerHash = [string](Get-DriverPackageViewValue $Preview 'InstallerHash' '')
        TracePreviewMatchCount = $previewMatches.Count
        Summary = [pscustomobject]@{
            InfCount                    = $infPackages.Count
            RelatedInfCount             = @($matchApplications | ForEach-Object { $_.Inf } | Sort-Object -Unique).Count
            PresentDeviceCount          = $devices.Count
            StackRootCount               = @($devices | Where-Object IsStackRoot).Count
            DirectBindingCount           = @($directBindings | ForEach-Object { "$($_.Inf)|$($_.InstanceId)" } | Sort-Object -Unique).Count
            ExtensionApplicationCount    = @($extensionApplications | ForEach-Object { "$($_.Inf)|$($_.InstanceId)" } | Sort-Object -Unique).Count
            PotentialApplicationCount    = $uniqueApplicationKeys.Count
            DeclarationMatchRowCount     = $declarationRows.Count
            LinkedComponentEdgeCount     = $linkedEdges.Count
        }
        InfPackages = @($infPackages)
        Applications = @($matchApplications)
        Devices = @($devices)
        Categories = $categories
        Edges = @($edges)
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $parent = Split-Path -Parent $OutputPath
        if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        $topology | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    }
    return $topology
}
