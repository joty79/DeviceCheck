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

function Get-CimListOrEmpty {
    param([string]$ClassName)

    try {
        return @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
    } catch {
        return @()
    }
}

function ConvertTo-UInt64OrNull {
    param($Value)

    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    [UInt64]$parsed = 0
    if ([UInt64]::TryParse($text.Trim(), [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Get-MemoryTypeName {
    param($Value)

    $code = ConvertTo-UInt64OrNull -Value $Value
    if ($null -eq $code) { return '' }

    switch ([int]$code) {
        20 { 'DDR' }
        21 { 'DDR2' }
        22 { 'DDR2 FB-DIMM' }
        24 { 'DDR3' }
        26 { 'DDR4' }
        34 { 'DDR5' }
        35 { 'LPDDR5' }
        default { "Type $code" }
    }
}

function Get-MemoryFormFactorName {
    param($Value)

    $code = ConvertTo-UInt64OrNull -Value $Value
    if ($null -eq $code) { return '' }

    switch ([int]$code) {
        8 { 'DIMM' }
        12 { 'SODIMM' }
        default { "FormFactor $code" }
    }
}

function Get-MachineMemoryEvidence {
    param($ComputerSystem)

    $physicalMemory = @(Get-CimListOrEmpty -ClassName 'Win32_PhysicalMemory')
    $memoryArrays = @(Get-CimListOrEmpty -ClassName 'Win32_PhysicalMemoryArray')
    [UInt64]$installedBytes = 0
    $slotsUsed = 0

    $modules = @(
        foreach ($module in $physicalMemory) {
            $capacity = ConvertTo-UInt64OrNull -Value (Get-ObjectPropertyValue -Object $module -PropertyName 'Capacity')
            if ($null -ne $capacity -and $capacity -gt 0) {
                $installedBytes += $capacity
                $slotsUsed++
            }

            $smbiosType = Get-ObjectPropertyValue -Object $module -PropertyName 'SMBIOSMemoryType'
            $formFactor = Get-ObjectPropertyValue -Object $module -PropertyName 'FormFactor'
            [PSCustomObject]@{
                BankLabel            = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $module -PropertyName 'BankLabel')
                DeviceLocator        = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $module -PropertyName 'DeviceLocator')
                Capacity             = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $module -PropertyName 'Capacity')
                Manufacturer         = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $module -PropertyName 'Manufacturer')
                PartNumber           = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $module -PropertyName 'PartNumber')
                SerialNumber         = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $module -PropertyName 'SerialNumber')
                Speed                = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $module -PropertyName 'Speed')
                ConfiguredClockSpeed = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $module -PropertyName 'ConfiguredClockSpeed')
                MemoryType           = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $module -PropertyName 'MemoryType')
                SMBIOSMemoryType     = ConvertTo-PlainEvidenceValue $smbiosType
                SMBIOSMemoryTypeName = Get-MemoryTypeName -Value $smbiosType
                FormFactor           = ConvertTo-PlainEvidenceValue $formFactor
                FormFactorName       = Get-MemoryFormFactorName -Value $formFactor
                DataWidth            = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $module -PropertyName 'DataWidth')
                TotalWidth           = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $module -PropertyName 'TotalWidth')
                InterleavePosition   = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $module -PropertyName 'InterleavePosition')
                Tag                  = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $module -PropertyName 'Tag')
            }
        }
    )

    $totalSlots = 0
    $arrays = @(
        foreach ($array in $memoryArrays) {
            $memoryDevices = ConvertTo-UInt64OrNull -Value (Get-ObjectPropertyValue -Object $array -PropertyName 'MemoryDevices')
            if ($null -ne $memoryDevices -and $memoryDevices -gt 0) {
                $totalSlots += [int]$memoryDevices
            }

            [PSCustomObject]@{
                Location      = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $array -PropertyName 'Location')
                Use           = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $array -PropertyName 'Use')
                MemoryDevices = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $array -PropertyName 'MemoryDevices')
                MaxCapacity   = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $array -PropertyName 'MaxCapacity')
                MaxCapacityEx = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $array -PropertyName 'MaxCapacityEx')
            }
        }
    )

    if ($totalSlots -le 0) {
        $totalSlots = $slotsUsed
    }

    return [PSCustomObject]@{
        SchemaVersion      = 1
        TotalPhysicalBytes = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $ComputerSystem -PropertyName 'TotalPhysicalMemory')
        InstalledBytes     = $(if ($installedBytes -gt 0) { [string]$installedBytes } else { $null })
        SlotsUsed          = $slotsUsed
        TotalSlots         = $totalSlots
        Modules            = @($modules)
        Arrays             = @($arrays)
    }
}

function Format-MemoryBytesText {
    param($Bytes)

    $parsed = ConvertTo-UInt64OrNull -Value $Bytes
    if ($null -eq $parsed -or $parsed -le 0) { return '' }

    if ($parsed -ge 1GB) {
        $gb = [double]$parsed / 1GB
        $rounded = [Math]::Round($gb)
        if ([Math]::Abs($gb - $rounded) -lt 0.05) {
            return ('{0:N0} GB' -f $rounded)
        }
        return ('{0:N2} GB' -f $gb)
    }

    if ($parsed -ge 1MB) {
        return ('{0:N0} MB' -f ([double]$parsed / 1MB))
    }

    return "$parsed bytes"
}

function Get-MemoryDisplayBytes {
    param(
        $Memory,
        $ComputerSystem
    )

    $installed = ConvertTo-UInt64OrNull -Value (Get-ObjectPropertyValue -Object $Memory -PropertyName 'InstalledBytes')
    if ($null -ne $installed -and $installed -gt 0) {
        return $installed
    }

    $total = ConvertTo-UInt64OrNull -Value (Get-ObjectPropertyValue -Object $Memory -PropertyName 'TotalPhysicalBytes')
    if ($null -ne $total -and $total -gt 0) {
        return $total
    }

    return ConvertTo-UInt64OrNull -Value (Get-ObjectPropertyValue -Object $ComputerSystem -PropertyName 'TotalPhysicalMemory')
}

function Get-MemoryTypeDisplayText {
    param($Memory)

    $types = @(
        @(Get-ObjectPropertyValue -Object $Memory -PropertyName 'Modules') |
            ForEach-Object {
                $type = [string](Get-ObjectPropertyValue -Object $_ -PropertyName 'SMBIOSMemoryTypeName')
                if (-not [string]::IsNullOrWhiteSpace($type) -and $type -notmatch '^Type\s+0$') {
                    $type.Trim()
                }
            } |
            Select-Object -Unique
    )

    return ($types -join '/')
}

function Format-MemorySummaryText {
    param(
        $Memory,
        $ComputerSystem
    )

    $capacity = Format-MemoryBytesText -Bytes (Get-MemoryDisplayBytes -Memory $Memory -ComputerSystem $ComputerSystem)
    if ([string]::IsNullOrWhiteSpace($capacity)) { return '' }

    $slotsUsed = ConvertTo-UInt64OrNull -Value (Get-ObjectPropertyValue -Object $Memory -PropertyName 'SlotsUsed')
    $totalSlots = ConvertTo-UInt64OrNull -Value (Get-ObjectPropertyValue -Object $Memory -PropertyName 'TotalSlots')
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($capacity)

    if ($null -ne $slotsUsed -and $slotsUsed -gt 0 -and $null -ne $totalSlots -and $totalSlots -gt 0) {
        $parts.Add("($slotsUsed/$totalSlots slots)")
    }

    $typeText = Get-MemoryTypeDisplayText -Memory $Memory
    if (-not [string]::IsNullOrWhiteSpace($typeText)) {
        $parts.Add($typeText)
    }

    return ($parts -join ' ')
}

function Format-MemorySpeedText {
    param($Memory)

    $speeds = @(
        @(Get-ObjectPropertyValue -Object $Memory -PropertyName 'Modules') |
            ForEach-Object {
                $configured = ConvertTo-UInt64OrNull -Value (Get-ObjectPropertyValue -Object $_ -PropertyName 'ConfiguredClockSpeed')
                $speed = ConvertTo-UInt64OrNull -Value (Get-ObjectPropertyValue -Object $_ -PropertyName 'Speed')
                if ($null -ne $configured -and $configured -gt 0) {
                    $configured
                } elseif ($null -ne $speed -and $speed -gt 0) {
                    $speed
                }
            } |
            Select-Object -Unique
    )

    if ($speeds.Count -eq 0) { return '' }
    return (($speeds | Sort-Object | ForEach-Object { "$_ MHz" }) -join ' / ')
}

function Format-MemoryPartNumberText {
    param($Memory)

    $partNumbers = @(
        @(Get-ObjectPropertyValue -Object $Memory -PropertyName 'Modules') |
            ForEach-Object {
                $part = [string](Get-ObjectPropertyValue -Object $_ -PropertyName 'PartNumber')
                if (-not [string]::IsNullOrWhiteSpace($part)) {
                    ($part -replace '\s+', ' ').Trim()
                }
            }
    )

    if ($partNumbers.Count -eq 0) { return '' }

    $groups = @($partNumbers | Group-Object | Sort-Object Name)
    return (($groups | ForEach-Object {
        if ($_.Count -gt 1) {
            "$($_.Name) x$($_.Count)"
        } else {
            $_.Name
        }
    }) -join ', ')
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
    $memory = Get-MachineMemoryEvidence -ComputerSystem $computerSystem

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
            TotalPhysicalMemory = ConvertTo-PlainEvidenceValue (Get-ObjectPropertyValue -Object $computerSystem -PropertyName 'TotalPhysicalMemory')
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
        Memory                = $memory
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

function Format-SnapshotLabelToken {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $value = ($Text -replace '\(R\)|\(TM\)|\(C\)', '' -replace '\s+', ' ').Trim()
    $value = $value -replace '(?i)\bwith Radeon Graphics\b', ''
    $value = $value -replace '(?i)\bLaptop GPU\b', ''
    return ($value -replace '\s+', ' ').Trim(' ', '-', '|')
}

function Format-SnapshotBytesShortText {
    param($Bytes)

    $parsed = ConvertTo-UInt64OrNull -Value $Bytes
    if ($null -eq $parsed -or $parsed -le 0) { return '' }
    if ($parsed -ge 1TB) {
        $tb = [double]$parsed / 1TB
        if ([Math]::Abs($tb - [Math]::Round($tb)) -lt 0.05) { return ('{0:N0}TB' -f [Math]::Round($tb)) }
        return ('{0:N1}TB' -f $tb)
    }
    if ($parsed -ge 1GB) {
        return ('{0:N0}GB' -f ([double]$parsed / 1GB))
    }
    return ('{0:N0}MB' -f ([double]$parsed / 1MB))
}

function Get-SnapshotSystemLabel {
    param($Machine)

    $computerSystem = Get-NotePropertyValue -Object $Machine -Name 'ComputerSystem'
    $product = Get-NotePropertyValue -Object $Machine -Name 'ComputerSystemProduct'
    $manufacturer = Format-SnapshotLabelToken -Text (Get-NotePropertyValue -Object $computerSystem -Name 'Manufacturer')
    if (Test-GenericHeaderValue -Text $manufacturer) { $manufacturer = '' }
    if ([string]::IsNullOrWhiteSpace($manufacturer)) {
        $manufacturer = Format-SnapshotLabelToken -Text (Get-NotePropertyValue -Object $product -Name 'Vendor')
        if (Test-GenericHeaderValue -Text $manufacturer) { $manufacturer = '' }
    }

    $modelCandidates = @(
        (Get-NotePropertyValue -Object $product -Name 'Version'),
        (Get-NotePropertyValue -Object $computerSystem -Name 'Model'),
        (Get-NotePropertyValue -Object $product -Name 'Name')
    )
    $model = ''
    foreach ($candidate in $modelCandidates) {
        $text = Format-SnapshotLabelToken -Text $candidate
        if (-not (Test-GenericHeaderValue -Text $text) -and $text -notin @('System Version', '1.0')) {
            $model = $text
            break
        }
    }

    $parts = @($manufacturer, $model) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    return (($parts | Select-Object -Unique) -join ' ')
}

function Get-SnapshotRamLabel {
    param($Machine)

    $memory = Get-NotePropertyValue -Object $Machine -Name 'Memory'
    $computerSystem = Get-NotePropertyValue -Object $Machine -Name 'ComputerSystem'
    $capacity = Format-SnapshotBytesShortText -Bytes (Get-MemoryDisplayBytes -Memory $memory -ComputerSystem $computerSystem)
    if ([string]::IsNullOrWhiteSpace($capacity)) { return '' }
    $type = Get-MemoryTypeDisplayText -Memory $memory
    return (@($capacity, $type) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 2) -join ' '
}

function Get-SnapshotGpuLabel {
    param($DevicesRoot)

    $devices = @(Get-NotePropertyValue -Object $DevicesRoot -Name 'Present')
    $gpus = @(
        $devices |
            Where-Object {
                ([string](Get-NotePropertyValue -Object $_ -Name 'Class')) -eq 'Display' -and
                ([string](Get-NotePropertyValue -Object $_ -Name 'FriendlyName')) -notmatch '(?i)basic display|remote display|miracast|indirect display'
            } |
            ForEach-Object {
                $name = Format-SnapshotLabelToken -Text (Get-NotePropertyValue -Object $_ -Name 'FriendlyName')
                $name = $name -replace '(?i)^AMD\s+', ''
                $name = $name -replace '(?i)^NVIDIA\s+(GeForce\s+)?', ''
                $name = $name -replace '(?i)^Intel\s+', ''
                Format-SnapshotLabelToken -Text $name
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique -First 2
    )
    return ($gpus -join ' + ')
}

function Get-SnapshotDiskSizeFromName {
    param([AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    if ($Name -match '(?i)(?<![A-Z0-9])(\d+(?:\.\d+)?)\s*(TB|T)(?=$|[\s_\-])') { return "$($Matches[1])TB" }
    if ($Name -match '(?i)(?<![A-Z0-9])(\d+(?:\.\d+)?)\s*(GB|G)(?=$|[\s_\-])') { return "$($Matches[1])GB" }
    return ''
}

function Get-SnapshotDiskLabel {
    param($Machine, $DevicesRoot)

    $storage = Get-NotePropertyValue -Object $Machine -Name 'Storage'
    $disks = @(Get-NotePropertyValue -Object $storage -Name 'Disks' | Where-Object { $null -ne $_ })
    if ($disks.Count -eq 0) {
        $disks = @(
            @(Get-NotePropertyValue -Object $DevicesRoot -Name 'Present') |
                Where-Object { ([string](Get-NotePropertyValue -Object $_ -Name 'Class')) -eq 'DiskDrive' } |
                ForEach-Object {
                    [PSCustomObject]@{
                        Model = Get-NotePropertyValue -Object $_ -Name 'FriendlyName'
                        Size  = $null
                    }
                }
        )
    }

    $labels = @(
        $disks |
            ForEach-Object {
                $model = Format-SnapshotLabelToken -Text (Get-NotePropertyValue -Object $_ -Name 'Model')
                if ([string]::IsNullOrWhiteSpace($model)) {
                    $model = Format-SnapshotLabelToken -Text (Get-NotePropertyValue -Object $_ -Name 'FriendlyName')
                }
                $size = Format-SnapshotBytesShortText -Bytes (Get-NotePropertyValue -Object $_ -Name 'Size')
                if ([string]::IsNullOrWhiteSpace($size)) {
                    $size = Get-SnapshotDiskSizeFromName -Name $model
                }
                if (-not [string]::IsNullOrWhiteSpace($size)) {
                    $model = ($model -replace [regex]::Escape($size), '' -replace '(?i)\b\d+(?:\.\d+)?\s*(TB|T|GB|G)\b', '' -replace '\s+', ' ').Trim(' ', '-', '_')
                }
                $model = $model -replace '(?i)^NVMe\s+', ''
                $model = $model -replace '(?i)\bSSD\b', ''
                $model = $model -replace '(?i)\bSDDPMQD[-_]*\d+G[-_]*\d+\b', ''
                $model = ($model -replace '\s+', ' ').Trim(' ', '-', '_')
                (@($size, $model) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 2) -join ' '
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique -First 2
    )
    return ($labels -join ' + ')
}

function Get-DeviceCheckSnapshotHardwareLabel {
    param([Parameter(Mandatory)]$Snapshot)

    $machine = Get-NotePropertyValue -Object $Snapshot -Name 'Machine'
    $devicesRoot = Get-NotePropertyValue -Object $Snapshot -Name 'Devices'
    if ($null -eq $machine) { return '' }

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @(
            (Get-SnapshotSystemLabel -Machine $machine),
            (Format-HeaderCpuName -Name (Get-NotePropertyValue -Object (Get-NotePropertyValue -Object $machine -Name 'Processor') -Name 'Name')),
            (Get-SnapshotGpuLabel -DevicesRoot $devicesRoot),
            (Get-SnapshotRamLabel -Machine $machine),
            (Get-SnapshotDiskLabel -Machine $machine -DevicesRoot $devicesRoot)
        )) {
        $token = Format-SnapshotLabelToken -Text $value
        if (-not [string]::IsNullOrWhiteSpace($token) -and -not $parts.Contains($token)) {
            $parts.Add($token)
        }
    }

    return ($parts -join ' | ')
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
