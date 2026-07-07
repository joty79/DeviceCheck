# Part of DeviceCheck.ps1. Dot-sourced by the root entrypoint; keep script-scope state shared.
# Purpose: Local PnP inventory, snapshot import, and snapshot export helpers.
function Get-DeviceCategories {
    param([switch]$Quiet)

    if (Test-RemoteSnapshotTargetActive) {
        return Get-DeviceCategoriesFromSnapshot -Snapshot $script:TargetSnapshot
    }

    if (-not $Quiet) {
        Write-Host "Detecting connected PnP hardware..." -ForegroundColor Cyan
    }
    $pnpDevices = Get-PnpDevice -PresentOnly

    $grouped = @{}
    foreach ($dev in $pnpDevices) {
        $guid = $(if ($dev.ClassGuid) { $dev.ClassGuid.ToLower() } else { "" })
        $classKey = $(if (-not [string]::IsNullOrWhiteSpace($dev.Class)) { $dev.Class } elseif ($classMap.ContainsKey($guid)) { $classMap[$guid] } else { 'Other devices' })
        $className = Get-DeviceManagerClassName -ClassName $classKey
        if ([string]::IsNullOrWhiteSpace($className)) {
            $className = "Other devices"
        }

        $devInfo = [PSCustomObject]@{
            InstanceId             = $dev.InstanceId
            FriendlyName           = $dev.FriendlyName
            Class                  = $className
            ClassKey               = $classKey
            Status                 = $dev.Status
            ConfigManagerErrorCode = $dev.ConfigManagerErrorCode
            IsProblem              = ($dev.ConfigManagerErrorCode -ne 0)
            SearchStatus           = $null      # $null, 'Searching', 'Done', 'Error'
            SearchResults          = @()        # Array of strings
            SearchKind             = $null
            SearchDetail           = $null
            SearchTracePath        = $null
            SearchCheckpointPath   = $null
            EvidenceCached         = (Test-Path -LiteralPath (Get-DeviceEvidenceCachePath -InstanceId $dev.InstanceId))
        }

        if (-not $grouped.ContainsKey($className)) {
            $grouped[$className] = [System.Collections.Generic.List[object]]::new()
        }
        $grouped[$className].Add($devInfo)
    }

    # Create sorted Category objects
    $categories = [System.Collections.Generic.List[object]]::new()
    foreach ($key in ($grouped.Keys | Sort-Object)) {
        # Sort devices in category by friendly name
        $sortedDevices = $grouped[$key] | Sort-Object FriendlyName
        $categories.Add([PSCustomObject]@{
            Name       = $key
            IsExpanded = $false
            Devices    = $sortedDevices
        })
    }
    return $categories
}

function Get-SnapshotDevicePropertyMap {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][string]$InstanceId
    )

    $propertiesRoot = Get-NotePropertyValue -Object (Get-NotePropertyValue -Object $Snapshot -Name 'Devices') -Name 'Properties'
    $properties = Get-NotePropertyValue -Object $propertiesRoot -Name $InstanceId
    $map = [ordered]@{}

    foreach ($property in @($properties)) {
        $keyName = [string](Get-NotePropertyValue -Object $property -Name 'KeyName')
        if ([string]::IsNullOrWhiteSpace($keyName)) {
            continue
        }

        $map[$keyName] = Get-NotePropertyValue -Object $property -Name 'Data'
    }

    return $map
}

function New-SnapshotDeviceEvidence {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$Device
    )

    $instanceId = [string](Get-NotePropertyValue -Object $Device -Name 'InstanceId')
    $importantData = Get-SnapshotDevicePropertyMap -Snapshot $Snapshot -InstanceId $instanceId

    if (-not $importantData.Contains('DEVPKEY_Device_HardwareIds')) {
        $hardwareIds = Get-NotePropertyValue -Object $Device -Name 'HardwareId'
        if ($hardwareIds) { $importantData['DEVPKEY_Device_HardwareIds'] = $hardwareIds }
    }
    if (-not $importantData.Contains('DEVPKEY_Device_CompatibleIds')) {
        $compatibleIds = Get-NotePropertyValue -Object $Device -Name 'CompatibleId'
        if ($compatibleIds) { $importantData['DEVPKEY_Device_CompatibleIds'] = $compatibleIds }
    }
    if (-not $importantData.Contains('DEVPKEY_Device_Manufacturer')) {
        $manufacturer = Get-NotePropertyValue -Object $Device -Name 'Manufacturer'
        if ($manufacturer) { $importantData['DEVPKEY_Device_Manufacturer'] = $manufacturer }
    }
    if (-not $importantData.Contains('DEVPKEY_Device_Service')) {
        $service = Get-NotePropertyValue -Object $Device -Name 'Service'
        if ($service) { $importantData['DEVPKEY_Device_Service'] = $service }
    }

    $collector = Get-NotePropertyValue -Object $Snapshot -Name 'Collector'
    $capturedAt = Get-NotePropertyValue -Object $collector -Name 'FinishedAt'
    if ([string]::IsNullOrWhiteSpace([string]$capturedAt)) {
        $capturedAt = Get-NotePropertyValue -Object $collector -Name 'StartedAt'
    }

    return [PSCustomObject]@{
        SchemaVersion       = 'DeviceCheckSnapshotEvidence/0.1'
        CapturedAt          = $capturedAt
        Source              = 'Snapshot'
        SnapshotPath        = $script:TargetSnapshotPath
        Device              = $Device
        Machine             = $script:MachineEvidence
        ImportantProperties = [PSCustomObject]$importantData
        PnpUtil             = Get-NotePropertyValue -Object $Snapshot -Name 'PnpUtil'
    }
}

function Set-SnapshotEvidenceCache {
    param([Parameter(Mandatory)]$Snapshot)

    Invalidate-EvidenceCache
    $devices = @((Get-NotePropertyValue -Object (Get-NotePropertyValue -Object $Snapshot -Name 'Devices') -Name 'Present'))
    foreach ($device in $devices) {
        $instanceId = [string](Get-NotePropertyValue -Object $device -Name 'InstanceId')
        if ([string]::IsNullOrWhiteSpace($instanceId)) {
            continue
        }

        $script:EvidenceCacheMemory[$instanceId] = New-SnapshotDeviceEvidence -Snapshot $Snapshot -Device $device
    }
}

function Get-DeviceCategoriesFromSnapshot {
    param([Parameter(Mandatory)]$Snapshot)

    $devicesRoot = Get-NotePropertyValue -Object $Snapshot -Name 'Devices'
    $snapshotDevices = @((Get-NotePropertyValue -Object $devicesRoot -Name 'Present'))
    $grouped = @{}

    foreach ($dev in $snapshotDevices) {
        $classKey = [string](Get-NotePropertyValue -Object $dev -Name 'Class')
        $className = Get-DeviceManagerClassName -ClassName $classKey
        if ([string]::IsNullOrWhiteSpace($className)) {
            $className = 'Other devices'
        }

        $errorCodeText = [string](Get-NotePropertyValue -Object $dev -Name 'ConfigManagerErrorCode')
        $errorCode = 0
        if (-not [string]::IsNullOrWhiteSpace($errorCodeText)) {
            try { $errorCode = [int]$errorCodeText } catch { $errorCode = 0 }
        }

        $instanceId = [string](Get-NotePropertyValue -Object $dev -Name 'InstanceId')
        $friendlyName = [string](Get-NotePropertyValue -Object $dev -Name 'FriendlyName')
        if ([string]::IsNullOrWhiteSpace($friendlyName)) {
            $friendlyName = $instanceId
        }

        $devInfo = [PSCustomObject]@{
            InstanceId             = $instanceId
            FriendlyName           = $friendlyName
            Class                  = $className
            ClassKey               = $classKey
            Status                 = Get-NotePropertyValue -Object $dev -Name 'Status'
            ConfigManagerErrorCode = $errorCode
            IsProblem              = ($errorCode -ne 0)
            SearchStatus           = $null
            SearchResults          = @()
            SearchKind             = $null
            SearchDetail           = $null
            SearchTracePath        = $null
            SearchCheckpointPath   = $null
            EvidenceCached         = $true
        }

        if (-not $grouped.ContainsKey($className)) {
            $grouped[$className] = [System.Collections.Generic.List[object]]::new()
        }
        $grouped[$className].Add($devInfo)
    }

    $categories = [System.Collections.Generic.List[object]]::new()
    foreach ($key in ($grouped.Keys | Sort-Object)) {
        $categories.Add([PSCustomObject]@{
            Name       = $key
            IsExpanded = $false
            Devices    = @($grouped[$key] | Sort-Object FriendlyName)
        })
    }

    Set-SnapshotEvidenceCache -Snapshot $Snapshot
    return $categories
}

function Invoke-SystemScan {
    param([switch]$Quiet)

    if (Test-RemoteSnapshotTargetActive) {
        $targetName = $(if (-not [string]::IsNullOrWhiteSpace($script:TargetComputerName)) { $script:TargetComputerName } else { 'remote target' })
        try { [Console]::CursorVisible = $true } catch {}
        
        if ($null -eq $script:TargetCredential -and -not [string]::IsNullOrWhiteSpace($targetName)) {
            $script:TargetCredential = $script:CredentialCache[$targetName.ToLower()]
            if ($null -eq $script:TargetCredential) {
                $script:TargetCredential = Get-DeviceCheckStoredCredential -ComputerName $targetName
            }
        }
        
        $collection = Invoke-RemoteSnapshotCollectionScreen -ComputerName $targetName -Credential $script:TargetCredential -PromptForCredential:($null -eq $script:TargetCredential)
        if ($collection.Success) {
            $actualTargetName = $targetName
            if ($null -ne $collection.Export -and $null -ne $collection.Export.Summary -and -not [string]::IsNullOrWhiteSpace($collection.Export.Summary.ComputerName)) {
                $actualTargetName = $collection.Export.Summary.ComputerName
            }
            Set-ActiveSnapshotTarget -Snapshot $collection.Export.Snapshot -SnapshotPath $collection.Export.LatestPath -ComputerName $actualTargetName -Credential $collection.Credential
        } else {
            $script:SystemScanMessage = "Remote refresh failed or cancelled: $targetName | $(Get-Date -Format 'HH:mm:ss')"
            $script:RequestForceClear = $true
            $script:TargetCredential = $null
        }
        try { Initialize-TuiHost } catch {}
        try { [Console]::CursorVisible = $false } catch {}
        return
    }

    $scanStarted = Get-Date
    $script:TargetMode = 'Local'
    $global:TargetMode = 'Local'
    $script:TargetSnapshot = $null
    $script:TargetSnapshotPath = $null
    $script:TargetComputerName = $env:COMPUTERNAME
    $script:MachineEvidence = Get-MachineEvidence
    $script:MachineCacheRoot = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath "machines\$($script:MachineEvidence.MachineId)"
    try { $null = New-Item -ItemType Directory -Path $script:MachineCacheRoot -Force } catch {}
    Invalidate-EvidenceCache  # clear all in-memory evidence on rescan
    if (Get-Command -Name 'Initialize-MonitorWmiModuleCache' -ErrorAction SilentlyContinue) {
        Initialize-MonitorWmiModuleCache
    }

    $script:categories = Get-DeviceCategories -Quiet:$Quiet
    $deviceCount = 0
    foreach ($category in $script:categories) {
        $deviceCount += @($category.Devices).Count
    }

    $elapsedMs = [int]((Get-Date) - $scanStarted).TotalMilliseconds
    $summary = Get-MachineSummary -MachineEvidence $script:MachineEvidence -DeviceCount $deviceCount -CategoryCount @($script:categories).Count -ElapsedMs $elapsedMs
    $script:SystemScanMessage = "Local system scan complete | $(Get-Date -Format 'HH:mm:ss')"
}

function Invoke-DeviceCheckSnapshotExport {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential,
        [scriptblock]$OnProgress,
        [switch]$Quick,
        [switch]$ArchiveSample,
        [string]$OutputRoot
    )

    $exportScript = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'internal\Export-DeviceCheckEvidence.ps1'
    if (-not (Test-Path -LiteralPath $exportScript -PathType Leaf)) {
        throw "Remote evidence exporter not found: $exportScript"
    }

    $script:RemoteConnectionLog = [System.Collections.Generic.List[string]]::new()
    $exportParams = @{
        ComputerName = $ComputerName
        AsJson       = $true
        Verbose      = $true
    }
    if ($Quick) {
        $exportParams.Quick = $true
    }
    $resolvedOutputRoot = $OutputRoot
    if ([string]::IsNullOrWhiteSpace($resolvedOutputRoot)) {
        $resolvedOutputRoot = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'snapshots'
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedOutputRoot)) {
        $exportParams.OutputRoot = $resolvedOutputRoot
    }
    if ($null -ne $Credential) {
        $exportParams.Credential = $Credential
    } else {
        $exportParams.UseCurrentCredentials = $true
    }

    if ($null -ne $OnProgress) {
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript({
            param($scriptPath, $params)
            $ProgressPreference = 'SilentlyContinue'
            $VerbosePreference = 'Continue'
            & $scriptPath @params
        }).AddArgument($exportScript).AddArgument($exportParams)

        $asyncResult = $ps.BeginInvoke()
        
        $spinnerChars = @('|', '/', '-', '\')
        $spinnerIdx = 0
        
        $progressWidth = 20
        $pos = 0
        $direction = 1
        
        $verboseCount = 0
        $currentActivity = "Initiating connection"
        
        try {
            while (-not $asyncResult.IsCompleted) {
                while ($ps.Streams.Verbose.Count -gt $verboseCount) {
                    $msg = $ps.Streams.Verbose[$verboseCount].Message
                    $verboseCount++
                    $script:RemoteConnectionLog.Add($msg)
                    $currentActivity = $msg
                }

                $bar = [System.Text.StringBuilder]::new()
                for ($i = 0; $i -lt $progressWidth; $i++) {
                    if ($i -ge $pos -and $i -lt ($pos + 4)) {
                        $null = $bar.Append('#')
                    } else {
                        $null = $bar.Append('-')
                    }
                }
                $pos += $direction
                if ($pos -eq ($progressWidth - 4) -or $pos -eq 0) {
                    $direction = -$direction
                }
                
                $spinner = $spinnerChars[$spinnerIdx]
                $spinnerIdx = ($spinnerIdx + 1) % $spinnerChars.Count
                
                $loadingText = "[$($bar.ToString())] $currentActivity... $spinner"
                & $OnProgress $loadingText
                
                if ([Console]::KeyAvailable) {
                    $key = Read-ConsoleKey
                    if ($null -ne $key -and ($key.Key -eq 'Escape' -or $key.KeyChar -eq [char]27)) {
                        $ps.Stop()
                        throw "Connection cancelled by user."
                    }
                }
                if (Test-WindowResized) {
                    $script:RequestForceClear = $true
                }
                
                Start-Sleep -Milliseconds 100
            }
            $output = $ps.EndInvoke($asyncResult)
            if ($ps.HadErrors) {
                $errorMsg = $ps.Streams.Error | ForEach-Object { $_.ToString() } | Out-String
                throw $errorMsg
            }
        } finally {
            $ps.Dispose()
        }
        $summaryJson = @($output) -join "`n"
    } else {
        $summaryJson = @(& $exportScript @exportParams) -join "`n"
    }

    $summary = $summaryJson | ConvertFrom-Json -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$summary.LatestPath) -or -not (Test-Path -LiteralPath $summary.LatestPath -PathType Leaf)) {
        throw "Remote snapshot export completed but latest snapshot was not found for $ComputerName."
    }

    $snapshot = Get-Content -LiteralPath $summary.LatestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($ArchiveSample) {
        $archiveAt = (Get-Date).ToString('o')
        Add-Member -InputObject $snapshot.Collector -MemberType NoteProperty -Name SnapshotMode -Value 'FullArchive' -Force
        Add-Member -InputObject $snapshot.Collector -MemberType NoteProperty -Name CapturePurpose -Value 'RepairShopSample' -Force
        Add-Member -InputObject $snapshot.Collector -MemberType NoteProperty -Name ArchivedAt -Value $archiveAt -Force
        Add-Member -InputObject $summary -MemberType NoteProperty -Name SnapshotMode -Value 'FullArchive' -Force
        Add-Member -InputObject $summary -MemberType NoteProperty -Name CapturePurpose -Value 'RepairShopSample' -Force

        $archiveJson = $snapshot | ConvertTo-Json -Depth 40
        $archiveJson | Set-Content -LiteralPath $summary.LatestPath -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace([string]$summary.OutputPath) -and (Test-Path -LiteralPath $summary.OutputPath -PathType Leaf)) {
            $archiveJson | Set-Content -LiteralPath $summary.OutputPath -Encoding UTF8
        }
    }
    return [PSCustomObject]@{
        Summary    = $summary
        Snapshot   = $snapshot
        LatestPath = [string]$summary.LatestPath
    }
}
