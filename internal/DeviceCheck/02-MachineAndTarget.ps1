# Part of DeviceCheck.ps1. Dot-sourced by the root entrypoint; keep script-scope state shared.
# Purpose: Machine identity, target naming, and snapshot machine conversion helpers.
$deviceManagerClassNames = @{
    AudioEndpoint     = 'Audio inputs and outputs'
    Computer          = 'Computer'
    DiskDrive         = 'Disk drives'
    Display           = 'Display adapters'
    Firmware          = 'Firmware'
    HDC               = 'IDE ATA/ATAPI controllers'
    HIDClass          = 'Human Interface Devices'
    Keyboard          = 'Keyboards'
    MEDIA             = 'Sound, video and game controllers'
    Monitor           = 'Monitors'
    Mouse             = 'Mice and other pointing devices'
    Net               = 'Network adapters'
    PrintQueue        = 'Print queues'
    Processor         = 'Processors'
    SCSIAdapter       = 'Storage controllers'
    SecurityDevices   = 'Security devices'
    SoftwareComponent = 'Software components'
    SoftwareDevice    = 'Software devices'
    System            = 'System devices'
    USB               = 'Universal Serial Bus controllers'
    Volume            = 'Storage volumes'
}

function New-DeviceCheckHash {
    param([AllowEmptyString()][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hashBytes = $sha.ComputeHash($bytes)
        return (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 24)
    } finally {
        $sha.Dispose()
    }
}

function Get-ObjectPropertyValue {
    param(
        $Object,
        [string]$PropertyName
    )

    if ($null -eq $Object) { return $null }
    try {
        return $Object.$PropertyName
    } catch {
        return $null
    }
}

function ConvertTo-PlainEvidenceValue {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [array]) {
        return @($Value | ForEach-Object { if ($null -eq $_) { $null } else { $_.ToString() } })
    }
    return $Value.ToString()
}

function Get-CimFirstOrNull {
    param([string]$ClassName)

    try {
        return Get-CimInstance -ClassName $ClassName -ErrorAction Stop | Select-Object -First 1
    } catch {
        return $null
    }
}

function Get-DeviceManagerClassName {
    param([AllowEmptyString()][string]$ClassName)

    if ([string]::IsNullOrWhiteSpace($ClassName)) { return 'Other devices' }
    if ($deviceManagerClassNames.ContainsKey($ClassName)) {
        return $deviceManagerClassNames[$ClassName]
    }
    return $ClassName
}

function Get-MachineEvidence {
    $computerSystem = Get-CimFirstOrNull -ClassName 'Win32_ComputerSystem'
    $computerProduct = Get-CimFirstOrNull -ClassName 'Win32_ComputerSystemProduct'
    $baseBoard = Get-CimFirstOrNull -ClassName 'Win32_BaseBoard'
    $bios = Get-CimFirstOrNull -ClassName 'Win32_BIOS'
    $operatingSystem = Get-CimFirstOrNull -ClassName 'Win32_OperatingSystem'
    $processor = Get-CimFirstOrNull -ClassName 'Win32_Processor'

    $fingerprintParts = @(
        (Get-ObjectPropertyValue -Object $computerSystem -PropertyName 'Manufacturer')
        (Get-ObjectPropertyValue -Object $computerSystem -PropertyName 'Model')
        (Get-ObjectPropertyValue -Object $computerProduct -PropertyName 'Vendor')
        (Get-ObjectPropertyValue -Object $computerProduct -PropertyName 'Name')
        (Get-ObjectPropertyValue -Object $computerProduct -PropertyName 'UUID')
        (Get-ObjectPropertyValue -Object $computerProduct -PropertyName 'IdentifyingNumber')
        (Get-ObjectPropertyValue -Object $baseBoard -PropertyName 'Manufacturer')
        (Get-ObjectPropertyValue -Object $baseBoard -PropertyName 'Product')
        (Get-ObjectPropertyValue -Object $baseBoard -PropertyName 'SerialNumber')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.ToString().Trim() }

    if (@($fingerprintParts).Count -eq 0) {
        $fingerprintParts = @($env:COMPUTERNAME)
    }

    $machineId = New-DeviceCheckHash -Text (($fingerprintParts -join '|').ToLowerInvariant())

    return [PSCustomObject]@{
        SchemaVersion         = 1
        MachineId             = $machineId
        CapturedAt            = (Get-Date).ToString('o')
        ComputerSystem        = [PSCustomObject]@{
            Manufacturer = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $computerSystem -PropertyName 'Manufacturer')
            Model        = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $computerSystem -PropertyName 'Model')
            Name         = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $computerSystem -PropertyName 'Name')
            SystemType   = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $computerSystem -PropertyName 'SystemType')
        }
        ComputerSystemProduct = [PSCustomObject]@{
            Vendor            = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $computerProduct -PropertyName 'Vendor')
            Name              = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $computerProduct -PropertyName 'Name')
            Version           = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $computerProduct -PropertyName 'Version')
            IdentifyingNumber = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $computerProduct -PropertyName 'IdentifyingNumber')
            UUID              = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $computerProduct -PropertyName 'UUID')
            SKUNumber         = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $computerProduct -PropertyName 'SKUNumber')
        }
        BaseBoard             = [PSCustomObject]@{
            Manufacturer = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $baseBoard -PropertyName 'Manufacturer')
            Product      = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $baseBoard -PropertyName 'Product')
            Version      = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $baseBoard -PropertyName 'Version')
            SerialNumber = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $baseBoard -PropertyName 'SerialNumber')
        }
        BIOS                  = [PSCustomObject]@{
            Manufacturer      = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $bios -PropertyName 'Manufacturer')
            SMBIOSBIOSVersion = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $bios -PropertyName 'SMBIOSBIOSVersion')
            ReleaseDate       = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $bios -PropertyName 'ReleaseDate')
        }
        Processor             = [PSCustomObject]@{
            Name                      = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $processor -PropertyName 'Name')
            NumberOfCores             = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $processor -PropertyName 'NumberOfCores')
            NumberOfLogicalProcessors = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $processor -PropertyName 'NumberOfLogicalProcessors')
            MaxClockSpeed             = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $processor -PropertyName 'MaxClockSpeed')
        }
        OperatingSystem       = [PSCustomObject]@{
            Caption        = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $operatingSystem -PropertyName 'Caption')
            Version        = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $operatingSystem -PropertyName 'Version')
            BuildNumber    = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $operatingSystem -PropertyName 'BuildNumber')
            OSArchitecture = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $operatingSystem -PropertyName 'OSArchitecture')
        }
    }
}

function Get-MachineDisplayName {
    param($MachineEvidence)

    $name = $MachineEvidence.ComputerSystem.Name
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $env:COMPUTERNAME }
    if ([string]::IsNullOrWhiteSpace($name)) { return 'Computer' }
    return $name.ToUpperInvariant()
}

function Test-GenericHeaderValue {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    $normalized = ($Text -replace '\s+', ' ').Trim()
    return ($normalized -in @(
            'System manufacturer',
            'System Product Name',
            'To Be Filled By O.E.M.',
            'To Be Filled By OEM',
            'Default string',
            'Default System',
            'Not Applicable',
            'None'
        ))
}

function Format-HeaderBoardProduct {
    param(
        [AllowEmptyString()][string]$Product,
        [AllowEmptyString()][string]$SystemModel
    )

    if (Test-GenericHeaderValue -Text $Product) { return '' }

    $board = ($Product -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($board)) { return '' }

    if (-not [string]::IsNullOrWhiteSpace($SystemModel)) {
        $model = [regex]::Escape(($SystemModel -replace '\s+', ' ').Trim())
        if (-not [string]::IsNullOrWhiteSpace($model)) {
            $board = ($board -replace "\s*\($model\)\s*$", '').Trim()
        }
    }

    $board = ($board -replace '\s*\((MS-[^)]+)\)\s*$', '').Trim()
    if ([string]::IsNullOrWhiteSpace($board)) { return '' }
    return "Board $board"
}

function Format-HeaderCpuName {
    param([AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $cpu = ($Name -replace '\(R\)|\(TM\)|\(C\)', '' -replace '\s+', ' ').Trim()

    if ($cpu -match '(?i)\bRyzen\s+(?:\d|[A-Z])\s+\d{4,5}[A-Z0-9]*\b') {
        return $Matches[0]
    }
    if ($cpu -match '(?i)\bUltra\s+\d\s+\d{3,4}[A-Z0-9]*\b') {
        return $Matches[0]
    }
    if ($cpu -match '(?i)\bi[3579][- ]\d{4,5}[A-Z0-9]*\b') {
        return ($Matches[0] -replace ' ', '-')
    }

    $cpu = $cpu -replace '(?i)\b(Intel|AMD)\b', ''
    $cpu = $cpu -replace '(?i)\b\d+\s*-\s*Core\b', ''
    $cpu = $cpu -replace '(?i)\bCPU\b.*$', ''
    $cpu = $cpu -replace '(?i)\bProcessor\b', ''
    $cpu = ($cpu -replace '\s+', ' ').Trim()
    return $cpu
}

function Format-HeaderOsName {
    param([AllowEmptyString()][string]$Caption)

    if ([string]::IsNullOrWhiteSpace($Caption)) { return '' }
    $os = ($Caption -replace '\s+', ' ').Trim()
    $os = $os -replace '^(?i)Microsoft\s+', ''
    if ($os -match '^(?i)Windows\s+(\d+)\s+(.+)$') {
        return "Win$($Matches[1]) $($Matches[2])"
    }
    return $os
}

function Get-MachineSummary {
    param(
        $MachineEvidence,
        [int]$DeviceCount = 0,
        [int]$CategoryCount = 0,
        [Nullable[int]]$ElapsedMs = $null
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $systemName = Get-MachineDisplayName -MachineEvidence $MachineEvidence
    $parts.Add($systemName)

    $boardText = Format-HeaderBoardProduct -Product $MachineEvidence.BaseBoard.Product -SystemModel $MachineEvidence.ComputerSystem.Model
    if (-not [string]::IsNullOrWhiteSpace($boardText)) {
        $parts.Add($boardText)
    }
    $cpuText = Format-HeaderCpuName -Name $MachineEvidence.Processor.Name
    if (-not [string]::IsNullOrWhiteSpace($cpuText)) {
        $parts.Add($cpuText)
    }
    $osText = Format-HeaderOsName -Caption $MachineEvidence.OperatingSystem.Caption
    if (-not [string]::IsNullOrWhiteSpace($osText)) {
        $parts.Add($osText)
    }
    if ($DeviceCount -gt 0 -or $CategoryCount -gt 0) {
        $parts.Add("$DeviceCount dev / $CategoryCount cat")
    }
    if ($null -ne $ElapsedMs) {
        $parts.Add("${ElapsedMs}ms")
    }

    return ($parts -join ' | ')
}

function Test-RemoteSnapshotTargetActive {
    return ($script:TargetMode -eq 'RemoteSnapshot' -and $null -ne $script:TargetSnapshot)
}

function Get-TargetStatusText {
    if (Test-RemoteSnapshotTargetActive) {
        $targetName = $(if (-not [string]::IsNullOrWhiteSpace($script:TargetComputerName)) { $script:TargetComputerName } else { Get-MachineDisplayName -MachineEvidence $script:MachineEvidence })
        return "Target $targetName (remote snapshot)"
    }

    return 'Target local host'
}

function Test-DeviceCheckLocalTargetName {
    param([AllowEmptyString()][string]$ComputerName)

    if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        return $false
    }

    $target = $ComputerName.Trim()
    if ($target -in @('.', 'local', 'localhost', '127.0.0.1', '::1')) {
        return $true
    }

    $localNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
        [void]$localNames.Add($env:COMPUTERNAME)
    }
    try {
        $hostName = [System.Net.Dns]::GetHostName()
        if (-not [string]::IsNullOrWhiteSpace($hostName)) {
            [void]$localNames.Add($hostName)
        }
    } catch {}

    return $localNames.Contains($target)
}

function Convert-SnapshotMachineToMachineEvidence {
    param([Parameter(Mandatory)]$Snapshot)

    $machine = Get-NotePropertyValue -Object $Snapshot -Name 'Machine'
    if ($null -eq $machine) {
        throw 'Snapshot is missing Machine data.'
    }

    if ($null -eq (Get-NotePropertyValue -Object $machine -Name 'MachineId')) {
        $name = Get-NotePropertyValue -Object (Get-NotePropertyValue -Object $machine -Name 'ComputerSystem') -Name 'Name'
        Add-Member -InputObject $machine -MemberType NoteProperty -Name MachineId -Value (New-DeviceCheckHash -Text ([string]$name)) -Force
    }

    if ($null -eq (Get-NotePropertyValue -Object $machine -Name 'CapturedAt')) {
        $capturedAt = Get-NotePropertyValue -Object (Get-NotePropertyValue -Object $Snapshot -Name 'Collector') -Name 'FinishedAt'
        if ([string]::IsNullOrWhiteSpace([string]$capturedAt)) {
            $capturedAt = (Get-Date).ToString('o')
        }
        Add-Member -InputObject $machine -MemberType NoteProperty -Name CapturedAt -Value $capturedAt -Force
    }

    return $machine
}

function Find-LatestSnapshotForComputerName {
    param([Parameter(Mandatory)][string]$ComputerName)

    if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        return $null
    }

    $snapshotRoot = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'snapshots'
    if (-not (Test-Path -LiteralPath $snapshotRoot -PathType Container)) {
        return $null
    }

    $target = $ComputerName.Trim()
    $isIp = $target -match '^\d+\.\d+\.\d+\.\d+$'

    $candidates = @(
        Get-ChildItem -LiteralPath $snapshotRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { 
                if ($isIp) {
                    $true
                } else {
                    $_.Name -like "$target-*"
                }
            } |
            Sort-Object LastWriteTime -Descending
    )

    foreach ($folder in $candidates) {
        $latestPath = Join-Path -Path $folder.FullName -ChildPath 'latest.json'
        if (-not (Test-Path -LiteralPath $latestPath -PathType Leaf)) {
            continue
        }

        try {
            $snapshot = Get-Content -LiteralPath $latestPath -Raw | ConvertFrom-Json -ErrorAction Stop
            $snapshotName = [string](Get-NotePropertyValue -Object (Get-NotePropertyValue -Object (Get-NotePropertyValue -Object $snapshot -Name 'Machine') -Name 'ComputerSystem') -Name 'Name')
            $collector = Get-NotePropertyValue -Object $snapshot -Name 'Collector'
            $requestedTarget = [string](Get-NotePropertyValue -Object $collector -Name 'RequestedComputerName')

            $match = $false
            if ($isIp) {
                if ($requestedTarget.Equals($target, [System.StringComparison]::OrdinalIgnoreCase) -or $snapshotName.Equals($target, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $match = $true
                }
            } else {
                if ($snapshotName.Equals($target, [System.StringComparison]::OrdinalIgnoreCase) -or $folder.Name.StartsWith("$target-", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $match = $true
                }
            }

            if ($match) {
                return [PSCustomObject]@{
                    Snapshot   = $snapshot
                    LatestPath = $latestPath
                    Folder     = $folder.FullName
                }
            }
        } catch {
            continue
        }
    }

    return $null
}
