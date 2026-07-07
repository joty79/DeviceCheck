#requires -version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$DatabaseRoot,
    [switch]$NoWrite,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path -Path $repoRoot -ChildPath 'internal\DeviceCheck\04-UiTextFormatting.ps1')
. (Join-Path -Path $repoRoot -ChildPath 'internal\DeviceCheck\02-MachineAndTarget.ps1')

function Resolve-DeviceCheckDatabaseRoot {
    param([string]$Root)

    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $expanded = [Environment]::ExpandEnvironmentVariables($Root.Trim())
        if ([System.IO.Path]::IsPathRooted($expanded)) { return $expanded }
        return (Join-Path -Path $repoRoot -ChildPath $expanded)
    }

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

$resolvedRoot = Resolve-DeviceCheckDatabaseRoot -Root $DatabaseRoot
$snapshotsRoot = Join-Path -Path $resolvedRoot -ChildPath 'snapshots'
if (-not (Test-Path -LiteralPath $snapshotsRoot -PathType Container)) {
    throw "Snapshots folder not found: $snapshotsRoot"
}

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($file in @(Get-ChildItem -LiteralPath $snapshotsRoot -Recurse -Filter 'latest.json' -File -ErrorAction SilentlyContinue)) {
    try {
        $snapshot = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
        $collector = Get-NotePropertyValue -Object $snapshot -Name 'Collector'
        $machine = Get-NotePropertyValue -Object $snapshot -Name 'Machine'
        $computerSystem = Get-NotePropertyValue -Object $machine -Name 'ComputerSystem'
        $devicesRoot = Get-NotePropertyValue -Object $snapshot -Name 'Devices'
        $label = Get-DeviceCheckSnapshotHardwareLabel -Snapshot $snapshot

        if (-not [string]::IsNullOrWhiteSpace($label) -and -not $NoWrite) {
            $existing = [string](Get-NotePropertyValue -Object $collector -Name 'SnapshotLabel')
            if ($existing -ne $label -and $PSCmdlet.ShouldProcess($file.FullName, "Set SnapshotLabel to '$label'")) {
                Add-Member -InputObject $collector -MemberType NoteProperty -Name SnapshotLabel -Value $label -Force
                $snapshot | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $file.FullName -Encoding UTF8
            }
        }

        $rows.Add([PSCustomObject]@{
            SnapshotLabel   = $label
            ComputerName    = [string](Get-NotePropertyValue -Object $computerSystem -Name 'Name')
            RequestedTarget = [string](Get-NotePropertyValue -Object $collector -Name 'RequestedComputerName')
            FinishedAt      = [string](Get-NotePropertyValue -Object $collector -Name 'FinishedAt')
            DeviceCount     = [string](Get-NotePropertyValue -Object $devicesRoot -Name 'Count')
            SnapshotPath    = $file.FullName
        })
    } catch {
        Write-Warning "Could not update snapshot label for $($file.FullName): $($_.Exception.Message)"
    }
}

$indexPath = Join-Path -Path $resolvedRoot -ChildPath 'snapshot-index.csv'
if (-not $NoWrite -and $PSCmdlet.ShouldProcess($indexPath, 'Write snapshot index')) {
    @($rows | Sort-Object FinishedAt -Descending) | Export-Csv -LiteralPath $indexPath -NoTypeInformation -Encoding UTF8
}

if ($PassThru) {
    return @($rows | Sort-Object FinishedAt -Descending)
}

@($rows | Sort-Object FinishedAt -Descending) | Format-Table -AutoSize
Write-Host "Snapshot index: $indexPath"
