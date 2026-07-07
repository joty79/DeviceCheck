#requires -version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [string[]]$SourcePath,

    [string]$DestinationRoot,

    [switch]$IncludeMachines,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-DeviceCheckRepoRoot {
    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Path }
    return (Split-Path -Parent (Split-Path -Parent $scriptPath))
}

function Resolve-DeviceCheckDatabaseRoot {
    param([string]$Root)

    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $expanded = [Environment]::ExpandEnvironmentVariables($Root.Trim())
        if ([System.IO.Path]::IsPathRooted($expanded)) { return $expanded }
        return (Join-Path -Path (Resolve-DeviceCheckRepoRoot) -ChildPath $expanded)
    }

    $repoRoot = Resolve-DeviceCheckRepoRoot
    $overrideRoot = @($env:DEVICECHECK_CACHE_ROOT, $env:DEVICECHECK_DATA_ROOT) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -First 1
    if (-not [string]::IsNullOrWhiteSpace($overrideRoot)) {
        $expanded = [Environment]::ExpandEnvironmentVariables($overrideRoot.Trim())
        if ([System.IO.Path]::IsPathRooted($expanded)) { return $expanded }
        return (Join-Path -Path $repoRoot -ChildPath $expanded)
    }

    return (Join-Path -Path $repoRoot -ChildPath '.devicecheck-data')
}

function Get-DeviceCheckSourceRoots {
    param([Parameter(Mandatory)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if (-not (Test-Path -LiteralPath $expanded)) {
        Write-Warning "Source path not found: $Path"
        return @()
    }

    $item = Get-Item -LiteralPath $expanded -Force
    if (-not $item.PSIsContainer) {
        Write-Warning "Source path is not a folder: $expanded"
        return @()
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($item.Name -ieq 'snapshots') {
        $candidates.Add((Split-Path -Parent $item.FullName))
    }

    foreach ($candidate in @($item.FullName, (Join-Path -Path $item.FullName -ChildPath 'DeviceCheck'), (Join-Path -Path $item.FullName -ChildPath '.devicecheck-data'))) {
        if ((Test-Path -LiteralPath (Join-Path -Path $candidate -ChildPath 'snapshots')) -or
            (Test-Path -LiteralPath (Join-Path -Path $candidate -ChildPath 'connection-history.json')) -or
            (Test-Path -LiteralPath (Join-Path -Path $candidate -ChildPath 'hosts-cache.json'))) {
            $candidates.Add($candidate)
        }
    }

    foreach ($found in @(Get-ChildItem -LiteralPath $item.FullName -Recurse -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @('DeviceCheck', '.devicecheck-data') })) {
        if ((Test-Path -LiteralPath (Join-Path -Path $found.FullName -ChildPath 'snapshots')) -or
            (Test-Path -LiteralPath (Join-Path -Path $found.FullName -ChildPath 'connection-history.json')) -or
            (Test-Path -LiteralPath (Join-Path -Path $found.FullName -ChildPath 'hosts-cache.json'))) {
            $candidates.Add($found.FullName)
        }
    }

    return @($candidates | Select-Object -Unique)
}

function Copy-NewerTree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExcludeDirectoryNames = @()
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return 0 }
    $count = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $relative = $file.FullName.Substring($Source.Length).TrimStart('\', '/')
        if ($ExcludeDirectoryNames.Count -gt 0) {
            $parts = $relative -split '[\\/]'
            if (@($parts | Where-Object { $_ -in $ExcludeDirectoryNames }).Count -gt 0) { continue }
        }

        $destPath = Join-Path -Path $Destination -ChildPath $relative
        $shouldCopy = $true
        if (Test-Path -LiteralPath $destPath -PathType Leaf) {
            $destFile = Get-Item -LiteralPath $destPath -Force
            $shouldCopy = ($file.LastWriteTimeUtc -gt $destFile.LastWriteTimeUtc -or $file.Length -ne $destFile.Length)
        }

        if ($shouldCopy -and $PSCmdlet.ShouldProcess($destPath, "Copy from $($file.FullName)")) {
            $destDir = Split-Path -Parent $destPath
            $null = New-Item -ItemType Directory -Path $destDir -Force
            Copy-Item -LiteralPath $file.FullName -Destination $destPath -Force
            $count++
        }
    }
    return $count
}

function Merge-JsonArrayFile {
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$DestinationFile,
        [Parameter(Mandatory)][string[]]$KeyProperties
    )

    if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) { return 0 }
    $sourceRows = @(Get-Content -LiteralPath $SourceFile -Raw | ConvertFrom-Json -ErrorAction Stop)
    $destRows = @()
    if (Test-Path -LiteralPath $DestinationFile -PathType Leaf) {
        $destRows = @(Get-Content -LiteralPath $DestinationFile -Raw | ConvertFrom-Json -ErrorAction Stop)
    }

    $merged = [ordered]@{}
    foreach ($row in @($destRows + $sourceRows)) {
        if ($null -eq $row) { continue }
        $parts = foreach ($property in $KeyProperties) {
            $value = ''
            if ($row.PSObject.Properties[$property]) { $value = [string]$row.PSObject.Properties[$property].Value }
            $value
        }
        $key = ($parts -join '|').ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($key.Replace('|', ''))) {
            $key = ($row | ConvertTo-Json -Depth 8 -Compress)
        }
        $merged[$key] = $row
    }

    $added = [Math]::Max(0, $merged.Count - $destRows.Count)
    if ($added -gt 0 -and $PSCmdlet.ShouldProcess($DestinationFile, "Merge $added history rows")) {
        $destDir = Split-Path -Parent $DestinationFile
        $null = New-Item -ItemType Directory -Path $destDir -Force
        @($merged.Values) | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $DestinationFile -Encoding UTF8
    }
    return $added
}

function Merge-JsonObjectFile {
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$DestinationFile
    )

    if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) { return 0 }
    $source = Get-Content -LiteralPath $SourceFile -Raw | ConvertFrom-Json -ErrorAction Stop
    $dest = $null
    if (Test-Path -LiteralPath $DestinationFile -PathType Leaf) {
        $dest = Get-Content -LiteralPath $DestinationFile -Raw | ConvertFrom-Json -ErrorAction Stop
    }

    $hash = [ordered]@{}
    if ($null -ne $dest) {
        foreach ($property in $dest.PSObject.Properties) { $hash[$property.Name] = $property.Value }
    }

    $changed = 0
    foreach ($property in $source.PSObject.Properties) {
        if (-not $hash.Contains($property.Name)) {
            $hash[$property.Name] = $property.Value
            $changed++
        } else {
            $existing = $hash[$property.Name]
            if ($existing -is [pscustomobject] -and $property.Value -is [pscustomobject]) {
                $inner = [ordered]@{}
                foreach ($innerProperty in $existing.PSObject.Properties) { $inner[$innerProperty.Name] = $innerProperty.Value }
                foreach ($innerProperty in $property.Value.PSObject.Properties) {
                    if (-not $inner.Contains($innerProperty.Name)) {
                        $inner[$innerProperty.Name] = $innerProperty.Value
                        $changed++
                    }
                }
                $hash[$property.Name] = [pscustomobject]$inner
            }
        }
    }

    if ($changed -gt 0 -and $PSCmdlet.ShouldProcess($DestinationFile, "Merge $changed object entries")) {
        $destDir = Split-Path -Parent $DestinationFile
        $null = New-Item -ItemType Directory -Path $destDir -Force
        ([pscustomobject]$hash) | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $DestinationFile -Encoding UTF8
    }
    return $changed
}

$destination = Resolve-DeviceCheckDatabaseRoot -Root $DestinationRoot
$null = New-Item -ItemType Directory -Path $destination -Force

$summary = [System.Collections.Generic.List[object]]::new()
foreach ($source in $SourcePath) {
    foreach ($sourceRoot in @(Get-DeviceCheckSourceRoots -Path $source)) {
        $sourceFull = (Resolve-Path -LiteralPath $sourceRoot).Path
        $snapshotsCopied = Copy-NewerTree -Source (Join-Path -Path $sourceFull -ChildPath 'snapshots') -Destination (Join-Path -Path $destination -ChildPath 'snapshots')
        $machinesCopied = 0
        if ($IncludeMachines) {
            $machinesCopied = Copy-NewerTree -Source (Join-Path -Path $sourceFull -ChildPath 'machines') -Destination (Join-Path -Path $destination -ChildPath 'machines')
        }
        $historyAdded = Merge-JsonArrayFile -SourceFile (Join-Path -Path $sourceFull -ChildPath 'connection-history.json') -DestinationFile (Join-Path -Path $destination -ChildPath 'connection-history.json') -KeyProperties @('ComputerName', 'LastIPAddress', 'MACAddress', 'NetworkId')
        $hostsAdded = Merge-JsonObjectFile -SourceFile (Join-Path -Path $sourceFull -ChildPath 'hosts-cache.json') -DestinationFile (Join-Path -Path $destination -ChildPath 'hosts-cache.json')

        $summary.Add([PSCustomObject]@{
            SourceRoot      = $sourceFull
            DestinationRoot = $destination
            SnapshotsCopied = $snapshotsCopied
            MachinesCopied  = $machinesCopied
            HistoryAdded    = $historyAdded
            HostsAdded      = $hostsAdded
        })
    }
}

if ($summary.Count -eq 0) {
    Write-Warning 'No DeviceCheck database roots were found in the provided source paths.'
}

if ($PassThru) {
    return @($summary)
}

@($summary) | Format-Table -AutoSize
