#requires -version 5.1
[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$InstanceId = '',

    [string[]]$HardwareId = @(),

    [string[]]$CompatibleId = @(),

    [AllowEmptyString()]
    [string]$MatchingDeviceId = '',

    [AllowEmptyString()]
    [string]$EvidencePath = '',

    [AllowEmptyString()]
    [string]$ExistingLog = '',

    [switch]$RunSdio,

    [string]$SdioExe = 'D:\Programs\SDIO\SDIO_x64_R830.exe',

    [string]$DriverPackRoot = '\\palios\SDIO\drivers',

    [string]$IndexRoot = '\\palios\SDIO\indexes\SDIO',

    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DeviceCheck\sdio-audit'),

    [switch]$UpdateDeviceCheckCache,

    [switch]$UpdateAllDeviceCheckCaches,

    [AllowEmptyString()]
    [string]$MachineCacheRoot = '',

    [int]$TopCandidateCount = 8,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-DeviceCheckShortHash {
    param([AllowEmptyString()][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hashBytes = $sha.ComputeHash($bytes)
        return (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 24)
    }
    finally {
        $sha.Dispose()
    }
}

function Get-ObjectPropertyValue {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-PlainValue {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [array]) {
        return @($Value | ForEach-Object { ConvertTo-PlainValue -Value $_ })
    }
    return [string]$Value
}

function ConvertTo-NormalizedSdioId {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    return (($Text.Trim() -replace '^"|"$', '') -replace '\s+', '').ToUpperInvariant()
}

function Add-NormalizedId {
    param(
        [System.Collections.Generic.List[string]]$List,
        [AllowEmptyString()][string]$Value
    )

    $normalized = ConvertTo-NormalizedSdioId -Text $Value
    if (-not [string]::IsNullOrWhiteSpace($normalized) -and -not $List.Contains($normalized)) {
        $List.Add($normalized)
    }
}

function ConvertTo-StringArray {
    param($Value)

    if ($null -eq $Value) { return @() }
    $items = if ($Value -is [array]) { @($Value) } else { @($Value) }
    return @(
        foreach ($item in $items) {
            if ($null -eq $item) { continue }
            $text = [string]$item
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $text.Trim()
            }
        }
    )
}

function Get-PnpPropertyValueSafe {
    param(
        [string]$TargetInstanceId,
        [string]$KeyName
    )

    if ([string]::IsNullOrWhiteSpace($TargetInstanceId)) { return $null }
    try {
        $property = Get-PnpDeviceProperty -InstanceId $TargetInstanceId -KeyName $KeyName -ErrorAction Stop
        return ConvertTo-PlainValue -Value $property.Data
    }
    catch {
        return $null
    }
}

function Get-CimValue {
    param(
        [string]$ClassName,
        [string]$PropertyName
    )

    try {
        $item = Get-CimInstance -ClassName $ClassName -ErrorAction Stop | Select-Object -First 1
        return [string](Get-ObjectPropertyValue -Object $item -Name $PropertyName)
    }
    catch {
        return ''
    }
}

function Get-LocalDeviceCheckMachineCacheRoot {
    $computerSystem = $null
    $computerProduct = $null
    $baseBoard = $null
    try { $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop | Select-Object -First 1 } catch {}
    try { $computerProduct = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop | Select-Object -First 1 } catch {}
    try { $baseBoard = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1 } catch {}

    $fingerprintParts = @(
        (Get-ObjectPropertyValue -Object $computerSystem -Name 'Manufacturer')
        (Get-ObjectPropertyValue -Object $computerSystem -Name 'Model')
        (Get-ObjectPropertyValue -Object $computerProduct -Name 'Vendor')
        (Get-ObjectPropertyValue -Object $computerProduct -Name 'Name')
        (Get-ObjectPropertyValue -Object $computerProduct -Name 'UUID')
        (Get-ObjectPropertyValue -Object $computerProduct -Name 'IdentifyingNumber')
        (Get-ObjectPropertyValue -Object $baseBoard -Name 'Manufacturer')
        (Get-ObjectPropertyValue -Object $baseBoard -Name 'Product')
        (Get-ObjectPropertyValue -Object $baseBoard -Name 'SerialNumber')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { $_.ToString().Trim() }

    if (@($fingerprintParts).Count -eq 0) {
        $fingerprintParts = @($env:COMPUTERNAME)
    }

    $machineId = New-DeviceCheckShortHash -Text (($fingerprintParts -join '|').ToLowerInvariant())
    $cacheRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DeviceCheck'
    if ([string]::IsNullOrWhiteSpace($cacheRoot)) {
        $cacheRoot = Join-Path $env:TEMP 'DeviceCheck'
    }
    return (Join-Path $cacheRoot "machines\$machineId")
}

function Get-TargetEvidence {
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Evidence file not found: $Path"
    }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop)
}

function New-SdioTarget {
    param(
        [AllowEmptyString()][string]$TargetInstanceId,
        [string[]]$TargetHardwareIds,
        [string[]]$TargetCompatibleIds,
        [AllowEmptyString()][string]$TargetMatchingDeviceId,
        $Evidence
    )

    if ($null -ne $Evidence) {
        $device = Get-ObjectPropertyValue -Object $Evidence -Name 'Device'
        $important = Get-ObjectPropertyValue -Object $Evidence -Name 'ImportantProperties'
        if ([string]::IsNullOrWhiteSpace($TargetInstanceId)) {
            $TargetInstanceId = [string](Get-ObjectPropertyValue -Object $device -Name 'InstanceId')
        }
        if (@($TargetHardwareIds).Count -eq 0) {
            $TargetHardwareIds = @(ConvertTo-StringArray -Value (Get-ObjectPropertyValue -Object $important -Name 'DEVPKEY_Device_HardwareIds'))
        }
        if (@($TargetCompatibleIds).Count -eq 0) {
            $TargetCompatibleIds = @(ConvertTo-StringArray -Value (Get-ObjectPropertyValue -Object $important -Name 'DEVPKEY_Device_CompatibleIds'))
        }
        if ([string]::IsNullOrWhiteSpace($TargetMatchingDeviceId)) {
            $TargetMatchingDeviceId = [string](Get-ObjectPropertyValue -Object $important -Name 'DEVPKEY_Device_MatchingDeviceId')
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetInstanceId)) {
        if (@($TargetHardwareIds).Count -eq 0) {
            $TargetHardwareIds = @(ConvertTo-StringArray -Value (Get-PnpPropertyValueSafe -TargetInstanceId $TargetInstanceId -KeyName 'DEVPKEY_Device_HardwareIds'))
        }
        if (@($TargetCompatibleIds).Count -eq 0) {
            $TargetCompatibleIds = @(ConvertTo-StringArray -Value (Get-PnpPropertyValueSafe -TargetInstanceId $TargetInstanceId -KeyName 'DEVPKEY_Device_CompatibleIds'))
        }
        if ([string]::IsNullOrWhiteSpace($TargetMatchingDeviceId)) {
            $TargetMatchingDeviceId = [string](Get-PnpPropertyValueSafe -TargetInstanceId $TargetInstanceId -KeyName 'DEVPKEY_Device_MatchingDeviceId')
        }
    }

    $candidateIds = [System.Collections.Generic.List[string]]::new()
    Add-NormalizedId -List $candidateIds -Value $TargetInstanceId
    Add-NormalizedId -List $candidateIds -Value $TargetMatchingDeviceId
    foreach ($id in @($TargetHardwareIds)) { Add-NormalizedId -List $candidateIds -Value $id }
    foreach ($id in @($TargetCompatibleIds)) { Add-NormalizedId -List $candidateIds -Value $id }

    return [PSCustomObject]@{
        InstanceId       = $TargetInstanceId
        HardwareIds      = @($TargetHardwareIds)
        CompatibleIds    = @($TargetCompatibleIds)
        MatchingDeviceId = $TargetMatchingDeviceId
        CandidateIds     = @($candidateIds)
    }
}

function Get-LocalSdioTargets {
    $targets = [System.Collections.Generic.List[object]]::new()
    $devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Sort-Object Class, FriendlyName, InstanceId)

    foreach ($device in $devices) {
        $instance = [string](Get-ObjectPropertyValue -Object $device -Name 'InstanceId')
        if ([string]::IsNullOrWhiteSpace($instance)) { continue }

        $target = New-SdioTarget -TargetInstanceId $instance -TargetHardwareIds @() -TargetCompatibleIds @() -TargetMatchingDeviceId '' -Evidence $null
        if (@($target.CandidateIds).Count -eq 0) { continue }

        $targets.Add([PSCustomObject]@{
            Device = [PSCustomObject]@{
                FriendlyName             = [string](Get-ObjectPropertyValue -Object $device -Name 'FriendlyName')
                InstanceId               = $instance
                Class                    = [string](Get-ObjectPropertyValue -Object $device -Name 'Class')
                Status                   = [string](Get-ObjectPropertyValue -Object $device -Name 'Status')
                ConfigManagerErrorCode   = Get-ObjectPropertyValue -Object $device -Name 'ConfigManagerErrorCode'
                Present                  = $true
            }
            Target = $target
        })
    }

    return @($targets)
}

function Get-SdioStatusLabels {
    param([AllowEmptyString()][string]$StatusText)

    if ([string]::IsNullOrWhiteSpace($StatusText)) { return @() }
    $value = 0
    try {
        $value = [Convert]::ToInt32($StatusText.Trim(), 16)
    }
    catch {
        try { $value = [int]$StatusText.Trim() } catch { return @('UNKNOWN') }
    }

    $labels = [System.Collections.Generic.List[string]]::new()
    $map = @(
        @{ Bit = 0x001; Label = 'BETTER' },
        @{ Bit = 0x002; Label = 'SAME' },
        @{ Bit = 0x004; Label = 'WORSE' },
        @{ Bit = 0x008; Label = 'INVALID' },
        @{ Bit = 0x010; Label = 'MISSING' },
        @{ Bit = 0x020; Label = 'NEW' },
        @{ Bit = 0x040; Label = 'CURRENT' },
        @{ Bit = 0x080; Label = 'OLD' },
        @{ Bit = 0x800; Label = 'DUP' }
    )
    foreach ($entry in $map) {
        if (($value -band [int]$entry.Bit) -ne 0) {
            $labels.Add([string]$entry.Label)
        }
    }
    if ($labels.Count -eq 0) {
        $labels.Add('NONE')
    }
    return @($labels)
}

function Get-SdioMatchKind {
    param(
        [AllowEmptyString()][string]$CandidateHardwareId,
        $Target
    )

    $candidate = ConvertTo-NormalizedSdioId -Text $CandidateHardwareId
    if ([string]::IsNullOrWhiteSpace($candidate)) { return 'Unknown' }

    $matching = ConvertTo-NormalizedSdioId -Text ([string]$Target.MatchingDeviceId)
    if (-not [string]::IsNullOrWhiteSpace($matching) -and $candidate -eq $matching) {
        return 'InstalledMatchingDeviceId'
    }

    $hardwareSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($Target.HardwareIds)) {
        $normalized = ConvertTo-NormalizedSdioId -Text $id
        if (-not [string]::IsNullOrWhiteSpace($normalized)) { [void]$hardwareSet.Add($normalized) }
    }
    if ($hardwareSet.Contains($candidate)) { return 'HardwareId' }

    $compatibleSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($Target.CompatibleIds)) {
        $normalized = ConvertTo-NormalizedSdioId -Text $id
        if (-not [string]::IsNullOrWhiteSpace($normalized)) { [void]$compatibleSet.Add($normalized) }
    }
    if ($compatibleSet.Contains($candidate)) { return 'CompatibleId' }

    return 'Unknown'
}

function New-EmptySdioDevice {
    return [PSCustomObject]@{
        DeviceInfo    = [ordered]@{}
        DriverInfo    = [ordered]@{}
        HardwareIds   = [System.Collections.Generic.List[string]]::new()
        CompatibleIds = [System.Collections.Generic.List[string]]::new()
        Candidates    = [System.Collections.Generic.List[object]]::new()
    }
}

function ConvertFrom-SdioMatcherLog {
    param([string]$LogPath)

    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        throw "SDIO log not found: $LogPath"
    }

    $devices = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $current = $null
    $section = ''
    $insideMatcher = $false

    foreach ($line in [System.IO.File]::ReadLines($LogPath)) {
        if ($line -match 'ERROR:|ERROR with ') {
            if ($warnings.Count -lt 25) {
                $warnings.Add($line.Trim())
            }
        }

        if (-not $insideMatcher) {
            if ($line -match '^\{matcher_print') {
                $insideMatcher = $true
            }
            continue
        }

        if ($line -match '^\}matcher_print') {
            if ($null -ne $current) {
                $devices.Add($current)
                $current = $null
            }
            break
        }

        if ($line -eq 'DeviceInfo') {
            if ($null -ne $current) {
                $devices.Add($current)
            }
            $current = New-EmptySdioDevice
            $section = 'DeviceInfo'
            continue
        }

        if ($null -eq $current) { continue }

        if ($line -eq 'DriverInfo') {
            $section = 'DriverInfo'
            continue
        }
        if ($line -eq 'HardwareID') {
            $section = 'HardwareID'
            continue
        }
        if ($line -eq 'CompatibleID') {
            $section = 'CompatibleID'
            continue
        }
        if ($line -match '^\s*altsectscore\s+\|') {
            $section = 'Candidates'
            continue
        }

        if ($section -eq 'Candidates') {
            if ($line -match '^\s*(?<AltSectScore>\d+)\s*\|\s*(?<Score>[0-9A-Fa-f]+)\s*\|\s*(?<Date>[^|]*)\|\s*(?<DecorScore>\d+)\s*\|\s*(?<MarkerScore>\d+)\s*\|\s*(?<Status>[0-9A-Fa-f]+)\s*\|\s*(?<DriverSection>[^|]*)\|\s*(?<PackName>[^|]*)\|\s*(?<InfCrc>[0-9A-Fa-f]+)\s*\|\s*(?<InfFile>[^|]*)\|\s*(?<Manufacturer>[^|]*)\|\s*(?<Version>[^|]*)\|\s*(?<HardwareId>[^|]*)\|\s*(?<Description>.*)$') {
                $status = $Matches.Status.Trim()
                $current.Candidates.Add([PSCustomObject]@{
                    AltSectScore  = [int]$Matches.AltSectScore
                    Score         = $Matches.Score.Trim().ToUpperInvariant()
                    Date          = $Matches.Date.Trim()
                    DecorScore    = [int]$Matches.DecorScore
                    MarkerScore   = [int]$Matches.MarkerScore
                    Status        = $status.ToUpperInvariant()
                    StatusLabels  = @(Get-SdioStatusLabels -StatusText $status)
                    DriverSection = $Matches.DriverSection.Trim()
                    PackName      = $Matches.PackName.Trim()
                    InfCrc        = $Matches.InfCrc.Trim().ToUpperInvariant()
                    InfFile       = $Matches.InfFile.Trim()
                    Manufacturer  = $Matches.Manufacturer.Trim()
                    Version       = $Matches.Version.Trim()
                    HardwareId    = $Matches.HardwareId.Trim()
                    Description   = $Matches.Description.Trim()
                })
            }
            continue
        }

        if ($section -eq 'DeviceInfo' -or $section -eq 'DriverInfo') {
            if ($line -match '^\s{2}(?<Key>[^:]+):\s*(?<Value>.*)$') {
                $key = $Matches.Key.Trim()
                $value = $Matches.Value.Trim()
                if ($section -eq 'DeviceInfo') {
                    $current.DeviceInfo[$key] = $value
                }
                else {
                    $current.DriverInfo[$key] = $value
                }
            }
            elseif ($line -match '^\s{2}(?<Key>\S+)\s+(?<Value>\S.*)$') {
                $key = $Matches.Key.Trim()
                $value = $Matches.Value.Trim()
                if ($section -eq 'DeviceInfo') {
                    $current.DeviceInfo[$key] = $value
                }
                else {
                    $current.DriverInfo[$key] = $value
                }
            }
            continue
        }

        if ($section -eq 'HardwareID' -or $section -eq 'CompatibleID') {
            $id = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if ($section -eq 'HardwareID') {
                $current.HardwareIds.Add($id)
            }
            else {
                $current.CompatibleIds.Add($id)
            }
        }
    }

    return [PSCustomObject]@{
        Devices  = @($devices)
        Warnings = @($warnings)
    }
}

function Test-SdioDeviceMatchesTarget {
    param(
        $Device,
        $Target
    )

    $targetSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($Target.CandidateIds)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$id)) { [void]$targetSet.Add([string]$id) }
    }
    if ($targetSet.Count -eq 0) { return $true }

    $deviceIds = [System.Collections.Generic.List[string]]::new()
    Add-NormalizedId -List $deviceIds -Value ([string]$Device.DriverInfo['HWID'])
    foreach ($id in @($Device.HardwareIds)) { Add-NormalizedId -List $deviceIds -Value $id }
    foreach ($id in @($Device.CompatibleIds)) { Add-NormalizedId -List $deviceIds -Value $id }
    foreach ($candidate in @($Device.Candidates)) { Add-NormalizedId -List $deviceIds -Value ([string]$candidate.HardwareId) }

    foreach ($id in @($deviceIds)) {
        if ($targetSet.Contains($id)) { return $true }
    }
    return $false
}

function ConvertTo-SdioAuditDevice {
    param(
        $Device,
        $Target,
        [int]$CandidateLimit
    )

    $candidateRows = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in @($Device.Candidates | Select-Object -First $CandidateLimit)) {
        $candidateRows.Add([PSCustomObject]@{
            MatchKind     = Get-SdioMatchKind -CandidateHardwareId ([string]$candidate.HardwareId) -Target $Target
            AltSectScore  = $candidate.AltSectScore
            Score         = $candidate.Score
            Date          = $candidate.Date
            DecorScore    = $candidate.DecorScore
            MarkerScore   = $candidate.MarkerScore
            Status        = $candidate.Status
            StatusLabels  = @($candidate.StatusLabels)
            DriverSection = $candidate.DriverSection
            PackName      = $candidate.PackName
            InfCrc        = $candidate.InfCrc
            InfFile       = $candidate.InfFile
            Manufacturer  = $candidate.Manufacturer
            Version       = $candidate.Version
            HardwareId    = $candidate.HardwareId
            Description   = $candidate.Description
        })
    }

    return [PSCustomObject]@{
        DeviceName     = [string]$Device.DeviceInfo['Name']
        DeviceClass    = [string]$Device.DeviceInfo['Class']
        Manufacturer   = [string]$Device.DeviceInfo['Manufacturer']
        Installed      = [PSCustomObject]@{
            Name        = [string]$Device.DriverInfo['Name']
            Provider    = [string]$Device.DriverInfo['Provider']
            Date        = [string]$Device.DriverInfo['Date']
            Version     = [string]$Device.DriverInfo['Version']
            HardwareId  = [string]$Device.DriverInfo['HWID']
            Inf         = [string]$Device.DriverInfo['inf']
            Score       = [string]$Device.DriverInfo['Score']
            Signature   = [string]$Device.DriverInfo['Signat']
        }
        HardwareIds    = @($Device.HardwareIds)
        CompatibleIds  = @($Device.CompatibleIds)
        CandidateCount = @($Device.Candidates).Count
        Candidates     = @($candidateRows)
    }
}

function Invoke-SdioReadOnlyAuditRun {
    param(
        [string]$ExePath,
        [string]$DriverRoot,
        [string]$IndexDirectory,
        [string]$RunRoot
    )

    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        throw "SDIO executable not found: $ExePath"
    }
    if (-not (Test-Path -LiteralPath $DriverRoot -PathType Container)) {
        throw "Driver pack root not found: $DriverRoot"
    }
    if (-not (Test-Path -LiteralPath $IndexDirectory -PathType Container)) {
        throw "Index root not found: $IndexDirectory"
    }

    $textRoot = Join-Path $RunRoot 'txt'
    $logRoot = Join-Path $RunRoot 'logs'
    $devicesPath = Join-Path $RunRoot 'devices.txt'
    $null = New-Item -ItemType Directory -Path $textRoot -Force
    $null = New-Item -ItemType Directory -Path $logRoot -Force

    $arguments = @(
        '-preservecfg',
        '-license:1',
        '-disableinstall',
        '-nogui',
        '-nosnapshot',
        '-nostamp',
        "-drp_dir:$DriverRoot",
        "-index_dir:$IndexDirectory",
        "-output_dir:$textRoot",
        "-log_dir:$logRoot",
        "-getdevicelist:$devicesPath"
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $ExePath -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    $stopwatch.Stop()

    $logPath = Join-Path $logRoot 'log.txt'
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        throw "SDIO finished with exit code $($process.ExitCode), but no log was written at $logPath"
    }

    return [PSCustomObject]@{
        ExitCode       = $process.ExitCode
        ElapsedMs      = [int]$stopwatch.ElapsedMilliseconds
        LogPath        = $logPath
        DeviceListPath = $devicesPath
        RunRoot        = $RunRoot
        Arguments      = @($arguments)
    }
}

function Resolve-DeviceCheckMachineCacheRoot {
    param(
        [AllowEmptyString()][string]$RequestedMachineCacheRoot,
        $EvidenceObject
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedMachineCacheRoot)) {
        return $RequestedMachineCacheRoot
    }

    $machine = if ($null -ne $EvidenceObject) { Get-ObjectPropertyValue -Object $EvidenceObject -Name 'Machine' } else { $null }
    $machineId = if ($null -ne $machine) { [string](Get-ObjectPropertyValue -Object $machine -Name 'MachineId') } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($machineId)) {
        $cacheRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DeviceCheck'
        if ([string]::IsNullOrWhiteSpace($cacheRoot)) {
            $cacheRoot = Join-Path $env:TEMP 'DeviceCheck'
        }
        return (Join-Path $cacheRoot "machines\$machineId")
    }

    return (Get-LocalDeviceCheckMachineCacheRoot)
}

function Write-SdioDeviceCache {
    param(
        [string]$ResolvedMachineCacheRoot,
        $BaseReport,
        $Target,
        [object[]]$DevicesForTarget
    )

    if ([string]::IsNullOrWhiteSpace([string]$Target.InstanceId)) {
        throw 'Cannot update DeviceCheck cache without an InstanceId.'
    }

    $deviceHash = New-DeviceCheckShortHash -Text ([string]$Target.InstanceId)
    $deviceAuditRoot = Join-Path $ResolvedMachineCacheRoot 'sdio-audit'
    $deviceAuditPath = Join-Path $deviceAuditRoot "$deviceHash.json"
    $null = New-Item -ItemType Directory -Path $deviceAuditRoot -Force

    $deviceReport = [PSCustomObject]@{
        SchemaVersion      = $BaseReport.SchemaVersion
        GeneratedAt        = $BaseReport.GeneratedAt
        Source             = $BaseReport.Source
        Target             = $Target
        Paths              = [PSCustomObject]@{
            ExistingLog = $BaseReport.Paths.ExistingLog
            Log         = $BaseReport.Paths.Log
            OutputRoot  = $BaseReport.Paths.OutputRoot
            RunRoot     = $BaseReport.Paths.RunRoot
            Report      = $BaseReport.Paths.Report
            DeviceCache = $deviceAuditPath
        }
        Run                = $BaseReport.Run
        Warning            = @($BaseReport.Warning)
        ParserWarnings     = @($BaseReport.ParserWarnings)
        TotalDeviceCount   = $BaseReport.TotalDeviceCount
        MatchedDeviceCount = @($DevicesForTarget).Count
        Devices            = @($DevicesForTarget)
    }

    $deviceReport | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $deviceAuditPath -Encoding UTF8
    return $deviceAuditPath
}

$evidence = Get-TargetEvidence -Path $EvidencePath
$target = New-SdioTarget -TargetInstanceId $InstanceId -TargetHardwareIds $HardwareId -TargetCompatibleIds $CompatibleId -TargetMatchingDeviceId $MatchingDeviceId -Evidence $evidence

if ([string]::IsNullOrWhiteSpace($ExistingLog) -and -not $RunSdio) {
    throw 'Pass -ExistingLog to parse a captured SDIO log, or pass -RunSdio to start an audit-only SDIO device-list run.'
}

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$runRoot = Join-Path $OutputRoot "runs\$stamp"
$null = New-Item -ItemType Directory -Path $runRoot -Force

$runInfo = $null
$logPath = $ExistingLog
$source = 'ExistingLog'
if ($RunSdio) {
    # If using defaults and they don't exist, check local SDIO folder fallbacks
    $exeDir = Split-Path -Parent $SdioExe
    if ($DriverPackRoot -eq '\\palios\SDIO\drivers' -and -not (Test-Path -LiteralPath $DriverPackRoot -ErrorAction SilentlyContinue)) {
        $localDrivers = Join-Path $exeDir 'drivers'
        if (Test-Path -LiteralPath $localDrivers -PathType Container) {
            $DriverPackRoot = $localDrivers
        }
    }
    if ($IndexRoot -eq '\\palios\SDIO\indexes\SDIO' -and -not (Test-Path -LiteralPath $IndexRoot -ErrorAction SilentlyContinue)) {
        $localIndexes = Join-Path $exeDir 'indexes\SDIO'
        if (Test-Path -LiteralPath $localIndexes -PathType Container) {
            $IndexRoot = $localIndexes
        }
    }

    $runInfo = Invoke-SdioReadOnlyAuditRun -ExePath $SdioExe -DriverRoot $DriverPackRoot -IndexDirectory $IndexRoot -RunRoot $runRoot
    $logPath = $runInfo.LogPath
    $source = 'SdioRun'
}

$parsed = ConvertFrom-SdioMatcherLog -LogPath $logPath
$matchedDevices = @(
    foreach ($device in @($parsed.Devices)) {
        if (Test-SdioDeviceMatchesTarget -Device $device -Target $target) {
            ConvertTo-SdioAuditDevice -Device $device -Target $target -CandidateLimit $TopCandidateCount
        }
    }
)

$report = [PSCustomObject]@{
    SchemaVersion      = 1
    GeneratedAt        = (Get-Date).ToString('o')
    Source             = $source
    Target             = $target
    Paths              = [PSCustomObject]@{
        ExistingLog = $ExistingLog
        Log         = $logPath
        OutputRoot  = $OutputRoot
        RunRoot     = $runRoot
        Report      = ''
        DeviceCache = ''
        DeviceCaches = @()
    }
    Run                = if ($null -eq $runInfo) {
        [PSCustomObject]@{
            SdioExe        = $SdioExe
            DriverPackRoot = $DriverPackRoot
            IndexRoot      = $IndexRoot
            ExitCode       = $null
            ElapsedMs      = $null
            Arguments      = @()
        }
    } else {
        [PSCustomObject]@{
            SdioExe        = $SdioExe
            DriverPackRoot = $DriverPackRoot
            IndexRoot      = $IndexRoot
            ExitCode       = $runInfo.ExitCode
            ElapsedMs      = $runInfo.ElapsedMs
            Arguments      = @($runInfo.Arguments)
        }
    }
    Warning            = @(
        'Audit-only for driver installation: SDIO is launched with -disableinstall when -RunSdio is used.'
        'SDIO may still refresh/write index metadata if it decides indexes are stale; use -ExistingLog for fully passive parsing.'
    )
    ParserWarnings     = @($parsed.Warnings)
    TotalDeviceCount   = @($parsed.Devices).Count
    MatchedDeviceCount = @($matchedDevices).Count
    CacheWriteCount    = 0
    Devices            = @($matchedDevices)
}

$reportRoot = Join-Path $OutputRoot 'reports'
$null = New-Item -ItemType Directory -Path $reportRoot -Force
$reportPath = Join-Path $reportRoot "sdio-audit-$stamp.json"
$report.Paths.Report = $reportPath
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding UTF8

if ($UpdateDeviceCheckCache -or $UpdateAllDeviceCheckCaches) {
    $resolvedMachineCacheRoot = Resolve-DeviceCheckMachineCacheRoot -RequestedMachineCacheRoot $MachineCacheRoot -EvidenceObject $evidence
}

if ($UpdateDeviceCheckCache) {
    if ([string]::IsNullOrWhiteSpace($target.InstanceId)) {
        throw 'Cannot update DeviceCheck cache without -InstanceId or an evidence file containing Device.InstanceId.'
    }

    $deviceCachePath = Write-SdioDeviceCache -ResolvedMachineCacheRoot $resolvedMachineCacheRoot -BaseReport $report -Target $target -DevicesForTarget $matchedDevices
    $report.Paths.DeviceCache = $deviceCachePath
    $report.Paths.DeviceCaches = @($report.Paths.DeviceCaches + $deviceCachePath)
    $report.CacheWriteCount = @($report.Paths.DeviceCaches).Count
}

if ($UpdateAllDeviceCheckCaches) {
    $localTargets = @(Get-LocalSdioTargets)
    $cachePaths = [System.Collections.Generic.List[string]]::new()

    foreach ($targetRow in $localTargets) {
        $localTarget = $targetRow.Target
        $devicesForTarget = @(
            foreach ($device in @($parsed.Devices)) {
                if (Test-SdioDeviceMatchesTarget -Device $device -Target $localTarget) {
                    $converted = ConvertTo-SdioAuditDevice -Device $device -Target $localTarget -CandidateLimit $TopCandidateCount
                    if ([int]$converted.CandidateCount -gt 0) {
                        $converted
                    }
                }
            }
        )

        if ($devicesForTarget.Count -eq 0) {
            continue
        }

        $path = Write-SdioDeviceCache -ResolvedMachineCacheRoot $resolvedMachineCacheRoot -BaseReport $report -Target $localTarget -DevicesForTarget $devicesForTarget
        $cachePaths.Add($path)
    }

    $combinedCachePaths = @($report.Paths.DeviceCaches) + @($cachePaths)
    $report.Paths.DeviceCaches = @($combinedCachePaths | Select-Object -Unique)
    if ([string]::IsNullOrWhiteSpace($report.Paths.DeviceCache) -and @($report.Paths.DeviceCaches).Count -gt 0) {
        $report.Paths.DeviceCache = @($report.Paths.DeviceCaches)[0]
    }
    $report.CacheWriteCount = @($report.Paths.DeviceCaches).Count
}

$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding UTF8

if ($AsJson) {
    $report | ConvertTo-Json -Depth 12
    return
}

Write-Host "SDIO audit report: $reportPath"
if (-not [string]::IsNullOrWhiteSpace($report.Paths.DeviceCache)) {
    Write-Host "DeviceCheck cache: $($report.Paths.DeviceCache)"
}
if ([int]$report.CacheWriteCount -gt 1) {
    Write-Host "DeviceCheck caches written: $($report.CacheWriteCount)"
}
Write-Host "Matched devices: $($report.MatchedDeviceCount) / $($report.TotalDeviceCount)"
foreach ($device in @($report.Devices | Select-Object -First 3)) {
    Write-Host ""
    Write-Host "$($device.DeviceName) [$($device.DeviceClass)]"
    Write-Host "Installed: $($device.Installed.Provider) $($device.Installed.Version) $($device.Installed.Date) $($device.Installed.HardwareId)"
    foreach ($candidate in @($device.Candidates | Select-Object -First 3)) {
        $statusText = (@($candidate.StatusLabels) -join '+')
        Write-Host "  $($candidate.MatchKind) $statusText $($candidate.Version) $($candidate.Date) $($candidate.HardwareId)"
        Write-Host "    $($candidate.PackName) :: $($candidate.InfFile)"
    }
}
