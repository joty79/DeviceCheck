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
. (Join-Path -Path $repoRoot -ChildPath 'internal\DeviceCheck\06-RemoteConnectionOfflineMenu.ps1')

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
        $computerName = [string](Get-NotePropertyValue -Object $computerSystem -Name 'Name')
        $deviceKind = Get-DeviceCheckSnapshotDeviceKind -Snapshot $snapshot -SnapshotLabel $label -ComputerName $computerName

        if (-not $NoWrite) {
            $existing = [string](Get-NotePropertyValue -Object $collector -Name 'SnapshotLabel')
            $existingKind = [string](Get-NotePropertyValue -Object $collector -Name 'DeviceKind')
            $existingGroup = [string](Get-NotePropertyValue -Object $collector -Name 'DeviceKindGroup')
            $existingConfidence = [string](Get-NotePropertyValue -Object $collector -Name 'DeviceKindConfidence')
            $existingReason = [string](Get-NotePropertyValue -Object $collector -Name 'DeviceKindReason')
            $needsWrite = (
                ((-not [string]::IsNullOrWhiteSpace($label)) -and $existing -ne $label) -or
                $existingKind -ne $deviceKind.Kind -or
                $existingGroup -ne $deviceKind.Group -or
                $existingConfidence -ne $deviceKind.Confidence -or
                $existingReason -ne $deviceKind.Reason
            )
            if ($needsWrite -and $PSCmdlet.ShouldProcess($file.FullName, "Update SnapshotLabel and DeviceKind metadata")) {
                if (-not [string]::IsNullOrWhiteSpace($label)) {
                    Add-Member -InputObject $collector -MemberType NoteProperty -Name SnapshotLabel -Value $label -Force
                }
                Add-Member -InputObject $collector -MemberType NoteProperty -Name DeviceKind -Value $deviceKind.Kind -Force
                Add-Member -InputObject $collector -MemberType NoteProperty -Name DeviceKindGroup -Value $deviceKind.Group -Force
                Add-Member -InputObject $collector -MemberType NoteProperty -Name DeviceKindConfidence -Value $deviceKind.Confidence -Force
                Add-Member -InputObject $collector -MemberType NoteProperty -Name DeviceKindReason -Value $deviceKind.Reason -Force
                $snapshot | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $file.FullName -Encoding UTF8
            }
        }

        $rows.Add([PSCustomObject]@{
            SnapshotLabel   = $label
            ComputerName    = $computerName
            DeviceKind      = $deviceKind.Kind
            DeviceKindGroup = $deviceKind.Group
            DeviceKindHint  = "$($deviceKind.Confidence): $($deviceKind.Reason)"
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
