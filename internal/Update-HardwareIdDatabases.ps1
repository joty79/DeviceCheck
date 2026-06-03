[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$SourceRoot = '',

    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data\hwdb'),

    [switch]$SkipRawCopy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-HwDataSourceRoot {
    param(
        [AllowEmptyString()]
        [string]$RequestedSourceRoot
    )

    $candidatePaths = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($RequestedSourceRoot)) {
        $candidatePaths.Add($RequestedSourceRoot)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:DRIVERCHECK_HWDATA_SOURCE)) {
        $candidatePaths.Add($env:DRIVERCHECK_HWDATA_SOURCE)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $candidatePaths.Add((Join-Path $env:USERPROFILE 'scripts\DeviceCheck\source\hwdata'))
    }

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scriptsRoot = Split-Path -Parent $repoRoot
    if (-not [string]::IsNullOrWhiteSpace($scriptsRoot)) {
        $candidatePaths.Add((Join-Path $scriptsRoot 'DeviceCheck\source\hwdata'))
    }

    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidatePath in $candidatePaths) {
        if ([string]::IsNullOrWhiteSpace($candidatePath)) {
            continue
        }

        $expandedPath = [Environment]::ExpandEnvironmentVariables($candidatePath)
        if (-not $seenPaths.Add($expandedPath)) {
            continue
        }

        if (Test-Path -LiteralPath $expandedPath -PathType Container) {
            $requiredFiles = @('pci.ids', 'usb.ids', 'pnp.ids')
            $missingFiles = [System.Collections.Generic.List[string]]::new()
            foreach ($requiredFile in $requiredFiles) {
                $requiredPath = Join-Path $expandedPath $requiredFile
                if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
                    $missingFiles.Add($requiredFile)
                }
            }

            if ($missingFiles.Count -eq 0) {
                return (Resolve-Path -LiteralPath $expandedPath).ProviderPath
            }
        }
    }

    $searched = ($candidatePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n  - "
    throw "Could not find a hwdata source root with pci.ids, usb.ids, and pnp.ids. Searched:`n  - $searched"
}

function Invoke-GitText {
    param(
        [string]$RepositoryPath,
        [string[]]$GitArguments
    )

    $gitOutput = & git -C $RepositoryPath @GitArguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ''
    }

    return (($gitOutput -join "`n").Trim())
}

function Get-SourceMetadata {
    param(
        [string]$SourceRootPath,
        [string]$FileName
    )

    $sourcePath = Join-Path $SourceRootPath $FileName
    $sourceItem = Get-Item -LiteralPath $sourcePath
    $hash = Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256

    [ordered]@{
        FileName = $FileName
        Path = $sourceItem.FullName
        Length = $sourceItem.Length
        LastWriteTimeUtc = $sourceItem.LastWriteTimeUtc.ToString('o')
        Sha256 = $hash.Hash
    }
}

function Get-HwDataGitMetadata {
    param(
        [string]$SourceRootPath
    )

    $metadata = [ordered]@{
        RepositoryRoot = ''
        Branch = ''
        Commit = ''
        Remote = ''
        IsGitRepository = $false
    }

    $repositoryRoot = Invoke-GitText -RepositoryPath $SourceRootPath -GitArguments @('rev-parse', '--show-toplevel')
    if ([string]::IsNullOrWhiteSpace($repositoryRoot)) {
        return $metadata
    }

    $metadata.RepositoryRoot = $repositoryRoot
    $metadata.Branch = Invoke-GitText -RepositoryPath $SourceRootPath -GitArguments @('branch', '--show-current')
    $metadata.Commit = Invoke-GitText -RepositoryPath $SourceRootPath -GitArguments @('rev-parse', 'HEAD')
    $metadata.Remote = Invoke-GitText -RepositoryPath $SourceRootPath -GitArguments @('remote', 'get-url', 'origin')
    $metadata.IsGitRepository = $true
    return $metadata
}

function New-DatabaseEnvelope {
    param(
        [string]$DatabaseName,
        [hashtable]$SourceMetadata,
        [hashtable]$Counts,
        [object]$Data
    )

    [ordered]@{
        SchemaVersion = 1
        Database = $DatabaseName
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Source = $SourceMetadata
        Counts = $Counts
        Data = $Data
    }
}

function ConvertTo-JsonFile {
    param(
        [object]$InputObject,
        [string]$Path
    )

    $json = $InputObject | ConvertTo-Json -Depth 64
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Convert-PciIdsFile {
    param(
        [string]$Path,
        [hashtable]$SourceMetadata
    )

    $vendors = [ordered]@{}
    $vendorCount = 0
    $deviceCount = 0
    $subsystemCount = 0
    $currentVendorId = ''
    $currentDeviceId = ''

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }

        $vendorMatch = [regex]::Match($line, '^(?<id>[0-9A-Fa-f]{4})\s{2,}(?<name>.+)$')
        if ($vendorMatch.Success) {
            $currentVendorId = $vendorMatch.Groups['id'].Value.ToUpperInvariant()
            $currentDeviceId = ''
            $vendors[$currentVendorId] = [ordered]@{
                Id = $currentVendorId
                Name = $vendorMatch.Groups['name'].Value.Trim()
                Devices = [ordered]@{}
            }
            $vendorCount++
            continue
        }

        $deviceMatch = [regex]::Match($line, '^\t(?<id>[0-9A-Fa-f]{4})\s{2,}(?<name>.+)$')
        if ($deviceMatch.Success -and -not [string]::IsNullOrWhiteSpace($currentVendorId)) {
            $currentDeviceId = $deviceMatch.Groups['id'].Value.ToUpperInvariant()
            $vendors[$currentVendorId].Devices[$currentDeviceId] = [ordered]@{
                Id = $currentDeviceId
                Name = $deviceMatch.Groups['name'].Value.Trim()
                Subsystems = [ordered]@{}
            }
            $deviceCount++
            continue
        }

        $subsystemMatch = [regex]::Match($line, '^\t\t(?<subvendor>[0-9A-Fa-f]{4})\s+(?<subdevice>[0-9A-Fa-f]{4})\s{2,}(?<name>.+)$')
        if ($subsystemMatch.Success -and -not [string]::IsNullOrWhiteSpace($currentVendorId) -and -not [string]::IsNullOrWhiteSpace($currentDeviceId)) {
            $subvendorId = $subsystemMatch.Groups['subvendor'].Value.ToUpperInvariant()
            $subdeviceId = $subsystemMatch.Groups['subdevice'].Value.ToUpperInvariant()
            $subsystemKey = "$subvendorId`:$subdeviceId"
            $vendors[$currentVendorId].Devices[$currentDeviceId].Subsystems[$subsystemKey] = [ordered]@{
                SubvendorId = $subvendorId
                SubdeviceId = $subdeviceId
                Name = $subsystemMatch.Groups['name'].Value.Trim()
            }
            $subsystemCount++
            continue
        }
    }

    New-DatabaseEnvelope -DatabaseName 'pci.ids' -SourceMetadata $SourceMetadata -Counts ([ordered]@{
        Vendors = $vendorCount
        Devices = $deviceCount
        Subsystems = $subsystemCount
    }) -Data ([ordered]@{
        Vendors = $vendors
    })
}

function Convert-UsbIdsFile {
    param(
        [string]$Path,
        [hashtable]$SourceMetadata
    )

    $vendors = [ordered]@{}
    $vendorCount = 0
    $productCount = 0
    $interfaceCount = 0
    $currentVendorId = ''
    $currentProductId = ''

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }

        $vendorMatch = [regex]::Match($line, '^(?<id>[0-9A-Fa-f]{4})\s{2,}(?<name>.+)$')
        if ($vendorMatch.Success) {
            $currentVendorId = $vendorMatch.Groups['id'].Value.ToUpperInvariant()
            $currentProductId = ''
            $vendors[$currentVendorId] = [ordered]@{
                Id = $currentVendorId
                Name = $vendorMatch.Groups['name'].Value.Trim()
                Products = [ordered]@{}
            }
            $vendorCount++
            continue
        }

        $productMatch = [regex]::Match($line, '^\t(?<id>[0-9A-Fa-f]{4})\s{2,}(?<name>.+)$')
        if ($productMatch.Success -and -not [string]::IsNullOrWhiteSpace($currentVendorId)) {
            $currentProductId = $productMatch.Groups['id'].Value.ToUpperInvariant()
            $vendors[$currentVendorId].Products[$currentProductId] = [ordered]@{
                Id = $currentProductId
                Name = $productMatch.Groups['name'].Value.Trim()
                Interfaces = [ordered]@{}
            }
            $productCount++
            continue
        }

        $interfaceMatch = [regex]::Match($line, '^\t\t(?<id>[0-9A-Fa-f]{2})\s{2,}(?<name>.+)$')
        if ($interfaceMatch.Success -and -not [string]::IsNullOrWhiteSpace($currentVendorId) -and -not [string]::IsNullOrWhiteSpace($currentProductId)) {
            $interfaceId = $interfaceMatch.Groups['id'].Value.ToUpperInvariant()
            $vendors[$currentVendorId].Products[$currentProductId].Interfaces[$interfaceId] = [ordered]@{
                Id = $interfaceId
                Name = $interfaceMatch.Groups['name'].Value.Trim()
            }
            $interfaceCount++
            continue
        }
    }

    New-DatabaseEnvelope -DatabaseName 'usb.ids' -SourceMetadata $SourceMetadata -Counts ([ordered]@{
        Vendors = $vendorCount
        Products = $productCount
        Interfaces = $interfaceCount
    }) -Data ([ordered]@{
        Vendors = $vendors
    })
}

function Convert-PnpIdsFile {
    param(
        [string]$Path,
        [hashtable]$SourceMetadata
    )

    $vendors = [ordered]@{}
    $vendorCount = 0

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }

        $vendorMatch = [regex]::Match($line, '^(?<id>[A-Za-z0-9]{3})\t(?<name>.+)$')
        if (-not $vendorMatch.Success) {
            continue
        }

        $vendorId = $vendorMatch.Groups['id'].Value.ToUpperInvariant()
        $vendors[$vendorId] = [ordered]@{
            Id = $vendorId
            Name = $vendorMatch.Groups['name'].Value.Trim()
        }
        $vendorCount++
    }

    New-DatabaseEnvelope -DatabaseName 'pnp.ids' -SourceMetadata $SourceMetadata -Counts ([ordered]@{
        Vendors = $vendorCount
    }) -Data ([ordered]@{
        Vendors = $vendors
    })
}

function Copy-RawDatabaseFiles {
    param(
        [string]$SourceRootPath,
        [string]$RawOutputRoot
    )

    New-Item -ItemType Directory -Path $RawOutputRoot -Force | Out-Null
    foreach ($fileName in @('pci.ids', 'usb.ids', 'pnp.ids')) {
        $sourcePath = Join-Path $SourceRootPath $fileName
        $targetPath = Join-Path $RawOutputRoot $fileName
        Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
    }
}

$resolvedSourceRoot = Resolve-HwDataSourceRoot -RequestedSourceRoot $SourceRoot
$resolvedOutputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
$rawOutputRoot = Join-Path $resolvedOutputRoot 'raw'
$normalizedOutputRoot = Join-Path $resolvedOutputRoot 'normalized'
$metadataOutputRoot = Join-Path $resolvedOutputRoot 'metadata'

New-Item -ItemType Directory -Path $normalizedOutputRoot -Force | Out-Null
New-Item -ItemType Directory -Path $metadataOutputRoot -Force | Out-Null

if (-not $SkipRawCopy) {
    Copy-RawDatabaseFiles -SourceRootPath $resolvedSourceRoot -RawOutputRoot $rawOutputRoot
}

$sourceFiles = [ordered]@{
    Pci = Get-SourceMetadata -SourceRootPath $resolvedSourceRoot -FileName 'pci.ids'
    Usb = Get-SourceMetadata -SourceRootPath $resolvedSourceRoot -FileName 'usb.ids'
    Pnp = Get-SourceMetadata -SourceRootPath $resolvedSourceRoot -FileName 'pnp.ids'
}

$sourceManifest = [ordered]@{
    SchemaVersion = 1
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    SourceRoot = $resolvedSourceRoot
    OutputRoot = $resolvedOutputRoot
    RawFilesCopied = -not [bool]$SkipRawCopy
    Git = Get-HwDataGitMetadata -SourceRootPath $resolvedSourceRoot
    Files = $sourceFiles
}

Write-Host "Source : $resolvedSourceRoot" -ForegroundColor Cyan
Write-Host "Output : $resolvedOutputRoot" -ForegroundColor Cyan

$pciEnvelope = Convert-PciIdsFile -Path (Join-Path $resolvedSourceRoot 'pci.ids') -SourceMetadata $sourceFiles.Pci
ConvertTo-JsonFile -InputObject $pciEnvelope -Path (Join-Path $normalizedOutputRoot 'pci.json')
Write-Host ("PCI    : {0} vendors, {1} devices, {2} subsystems" -f $pciEnvelope.Counts.Vendors, $pciEnvelope.Counts.Devices, $pciEnvelope.Counts.Subsystems) -ForegroundColor Green

$usbEnvelope = Convert-UsbIdsFile -Path (Join-Path $resolvedSourceRoot 'usb.ids') -SourceMetadata $sourceFiles.Usb
ConvertTo-JsonFile -InputObject $usbEnvelope -Path (Join-Path $normalizedOutputRoot 'usb.json')
Write-Host ("USB    : {0} vendors, {1} products, {2} interfaces" -f $usbEnvelope.Counts.Vendors, $usbEnvelope.Counts.Products, $usbEnvelope.Counts.Interfaces) -ForegroundColor Green

$pnpEnvelope = Convert-PnpIdsFile -Path (Join-Path $resolvedSourceRoot 'pnp.ids') -SourceMetadata $sourceFiles.Pnp
ConvertTo-JsonFile -InputObject $pnpEnvelope -Path (Join-Path $normalizedOutputRoot 'pnp.json')
Write-Host ("PNP    : {0} vendors" -f $pnpEnvelope.Counts.Vendors) -ForegroundColor Green

ConvertTo-JsonFile -InputObject $sourceManifest -Path (Join-Path $metadataOutputRoot 'sources.json')
Write-Host "Done   : hardware ID database cache refreshed" -ForegroundColor Green
