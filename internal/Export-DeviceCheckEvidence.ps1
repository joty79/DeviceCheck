#requires -version 5.1
[CmdletBinding()]
param(
    [string]$ComputerName = $env:COMPUTERNAME,

    [System.Management.Automation.PSCredential]$Credential,

    [string]$UserName,

    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DeviceCheck\snapshots'),

    [switch]$Quick,

    [switch]$SkipTrustedHosts,

    [switch]$NoSave,

    [switch]$PassThru,

    [switch]$AsJson,

    [switch]$UseCurrentCredentials
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CollectorVersion = '0.1.0'

function Test-LocalTarget {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $true
    }

    $normalized = $Name.Trim()
    if ($normalized -in @('.', 'localhost', '127.0.0.1', '::1')) {
        return $true
    }

    $localNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void]$localNames.Add($env:COMPUTERNAME)
    try { [void]$localNames.Add([System.Net.Dns]::GetHostName()) } catch {}
    try {
        $fqdn = [System.Net.Dns]::GetHostEntry('localhost').HostName
        if (-not [string]::IsNullOrWhiteSpace($fqdn)) {
            [void]$localNames.Add($fqdn)
        }
    } catch {}

    return $localNames.Contains($normalized)
}

function ConvertTo-SafeFileName {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return 'unknown'
    }

    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = [System.Text.StringBuilder]::new()
    foreach ($ch in $Text.ToCharArray()) {
        if ($invalid -contains $ch) {
            [void]$builder.Append('_')
        } else {
            [void]$builder.Append($ch)
        }
    }

    return ($builder.ToString() -replace '\s+', '_').Trim('_')
}

function Get-TrustedHostValues {
    try {
        $value = (Get-Item -Path 'WSMan:\localhost\Client\TrustedHosts' -ErrorAction Stop).Value
    } catch {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        return @()
    }

    return @(
        $value -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Add-TrustedHostExact {
    param([string]$Target)

    if ([string]::IsNullOrWhiteSpace($Target)) {
        throw 'TrustedHosts target cannot be empty.'
    }

    if ($Target -eq '*') {
        throw 'Refusing to add wildcard TrustedHosts entry.'
    }

    $current = @(Get-TrustedHostValues)
    foreach ($entry in $current) {
        if ($entry -eq '*' -or $entry.Equals($Target, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]@{
                Changed = $false
                Value   = ($current -join ',')
            }
        }
    }

    $updated = @($current + $Target)
    $newValue = ($updated | Select-Object -Unique) -join ','

    try {
        Set-Item -Path 'WSMan:\localhost\Client\TrustedHosts' -Value $newValue -Force -ErrorAction Stop
        return [PSCustomObject]@{
            Changed = $true
            Value   = $newValue
        }
    } catch {
        $firstError = $_.Exception.Message
        $gsudo = Get-Command gsudo.exe -ErrorAction SilentlyContinue
        if ($null -eq $gsudo) {
            throw "Adding '$Target' to TrustedHosts requires elevation. gsudo.exe was not found. Original error: $firstError"
        }

        $escapedValue = $newValue.Replace("'", "''")
        $commandText = "Set-Item -Path 'WSMan:\localhost\Client\TrustedHosts' -Value '$escapedValue' -Force -ErrorAction Stop"
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($commandText))
        $shellPath = Join-Path $PSHOME $(if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh.exe' } else { 'powershell.exe' })

        & $gsudo.Source $shellPath -NoProfile -EncodedCommand $encoded
        if ($LASTEXITCODE -ne 0) {
            throw "gsudo.exe failed while adding '$Target' to TrustedHosts. Original error: $firstError"
        }

        $verified = @(Get-TrustedHostValues)
        $found = $false
        foreach ($entry in $verified) {
            if ($entry.Equals($Target, [System.StringComparison]::OrdinalIgnoreCase)) {
                $found = $true
                break
            }
        }
        if (-not $found) {
            throw "TrustedHosts update completed but '$Target' was not visible afterward."
        }

        return [PSCustomObject]@{
            Changed = $true
            Value   = ($verified -join ',')
        }
    }
}

function New-CollectorScriptBlock {
    {
        param(
            [string]$RequestedComputerName,
            [bool]$QuickMode,
            [string]$CollectorVersion,
            [string]$Stage
        )

        $ErrorActionPreference = 'Stop'
        $VerbosePreference = 'Continue'

        $importantKeys = @(
            'DEVPKEY_Device_DeviceDesc',
            'DEVPKEY_Device_BusReportedDeviceDesc',
            'DEVPKEY_Device_HardwareIds',
            'DEVPKEY_Device_CompatibleIds',
            'DEVPKEY_Device_Manufacturer',
            'DEVPKEY_Device_Service',
            'DEVPKEY_Device_Class',
            'DEVPKEY_Device_ClassGuid',
            'DEVPKEY_Device_Driver',
            'DEVPKEY_Device_DriverInfPath',
            'DEVPKEY_Device_DriverInfSection',
            'DEVPKEY_Device_DriverProvider',
            'DEVPKEY_Device_DriverVersion',
            'DEVPKEY_Device_DriverDate',
            'DEVPKEY_Device_ProblemCode',
            'DEVPKEY_Device_Parent',
            'DEVPKEY_Device_LocationPaths',
            'DEVPKEY_Device_ContainerId'
        )

        function ConvertTo-PlainSnapshotValue {
            param($Value)

            if ($null -eq $Value) {
                return $null
            }

            if ($Value -is [System.Array]) {
                return @(
                    foreach ($item in @($Value)) {
                        if ($null -eq $item) {
                            $null
                        } elseif ($item -is [byte]) {
                            [int]$item
                        } else {
                            [string]$item
                        }
                    }
                )
            }

            if ($Value -is [System.DateTime]) {
                return $Value.ToString('o')
            }

            return [string]$Value
        }

        function Get-CimFirstOrNull {
            param([string]$ClassName, [string]$Namespace = 'root\cimv2')

            try {
                return Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop | Select-Object -First 1
            } catch {
                return $null
            }
        }

        function Get-ObjectPropertyValue {
            param($InputObject, [string]$PropertyName)

            if ($null -eq $InputObject) {
                return $null
            }

            $property = $InputObject.PSObject.Properties[$PropertyName]
            if ($null -eq $property) {
                return $null
            }

            return $property.Value
        }

        function New-ShortHash {
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

        function Get-CimSnapshot {
            param($InputObject, [string[]]$PropertyNames)

            $result = [ordered]@{}
            foreach ($name in $PropertyNames) {
                $result[$name] = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $InputObject -PropertyName $name)
            }
            return [PSCustomObject]$result
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

        function Get-MachineMemorySnapshot {
            param($ComputerSystem)

            $physicalMemory = @(Get-CimListOrEmpty -ClassName 'Win32_PhysicalMemory')
            $memoryArrays = @(Get-CimListOrEmpty -ClassName 'Win32_PhysicalMemoryArray')
            [UInt64]$installedBytes = 0
            $slotsUsed = 0

            $modules = @(
                foreach ($module in $physicalMemory) {
                    $capacity = ConvertTo-UInt64OrNull -Value (Get-ObjectPropertyValue -InputObject $module -PropertyName 'Capacity')
                    if ($null -ne $capacity -and $capacity -gt 0) {
                        $installedBytes += $capacity
                        $slotsUsed++
                    }

                    $smbiosType = Get-ObjectPropertyValue -InputObject $module -PropertyName 'SMBIOSMemoryType'
                    $formFactor = Get-ObjectPropertyValue -InputObject $module -PropertyName 'FormFactor'
                    [PSCustomObject]@{
                        BankLabel            = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $module -PropertyName 'BankLabel')
                        DeviceLocator        = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $module -PropertyName 'DeviceLocator')
                        Capacity             = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $module -PropertyName 'Capacity')
                        Manufacturer         = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $module -PropertyName 'Manufacturer')
                        PartNumber           = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $module -PropertyName 'PartNumber')
                        SerialNumber         = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $module -PropertyName 'SerialNumber')
                        Speed                = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $module -PropertyName 'Speed')
                        ConfiguredClockSpeed = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $module -PropertyName 'ConfiguredClockSpeed')
                        MemoryType           = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $module -PropertyName 'MemoryType')
                        SMBIOSMemoryType     = ConvertTo-PlainSnapshotValue $smbiosType
                        SMBIOSMemoryTypeName = Get-MemoryTypeName -Value $smbiosType
                        FormFactor           = ConvertTo-PlainSnapshotValue $formFactor
                        FormFactorName       = Get-MemoryFormFactorName -Value $formFactor
                        DataWidth            = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $module -PropertyName 'DataWidth')
                        TotalWidth           = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $module -PropertyName 'TotalWidth')
                        InterleavePosition   = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $module -PropertyName 'InterleavePosition')
                        Tag                  = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $module -PropertyName 'Tag')
                    }
                }
            )

            $totalSlots = 0
            $arrays = @(
                foreach ($array in $memoryArrays) {
                    $memoryDevices = ConvertTo-UInt64OrNull -Value (Get-ObjectPropertyValue -InputObject $array -PropertyName 'MemoryDevices')
                    if ($null -ne $memoryDevices -and $memoryDevices -gt 0) {
                        $totalSlots += [int]$memoryDevices
                    }

                    [PSCustomObject]@{
                        Location      = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $array -PropertyName 'Location')
                        Use           = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $array -PropertyName 'Use')
                        MemoryDevices = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $array -PropertyName 'MemoryDevices')
                        MaxCapacity   = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $array -PropertyName 'MaxCapacity')
                        MaxCapacityEx = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $array -PropertyName 'MaxCapacityEx')
                    }
                }
            )

            if ($totalSlots -le 0) {
                $totalSlots = $slotsUsed
            }

            return [PSCustomObject]@{
                SchemaVersion      = 1
                TotalPhysicalBytes = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $ComputerSystem -PropertyName 'TotalPhysicalMemory')
                InstalledBytes     = $(if ($installedBytes -gt 0) { [string]$installedBytes } else { $null })
                SlotsUsed          = $slotsUsed
                TotalSlots         = $totalSlots
                Modules            = @($modules)
                Arrays             = @($arrays)
            }
        }

        function Get-PnpDevicePropertiesSafe {
            param([string]$InstanceId)

            try {
                return @(
                    Get-PnpDeviceProperty -InstanceId $InstanceId -ErrorAction Stop |
                        ForEach-Object {
                            [PSCustomObject]@{
                                KeyName = ConvertTo-PlainSnapshotValue $_.KeyName
                                Type    = ConvertTo-PlainSnapshotValue $_.Type
                                Data    = ConvertTo-PlainSnapshotValue $_.Data
                            }
                        }
                )
            } catch {
                return [PSCustomObject]@{
                    Error = $_.Exception.Message
                }
            }
        }

        function Get-MonitorRegistryEvidence {
            $displayRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'
            if (-not (Test-Path -LiteralPath $displayRoot)) {
                return @()
            }

            $items = [System.Collections.Generic.List[object]]::new()
            foreach ($vendorKey in @(Get-ChildItem -LiteralPath $displayRoot -ErrorAction SilentlyContinue)) {
                foreach ($instanceKey in @(Get-ChildItem -LiteralPath $vendorKey.PSPath -ErrorAction SilentlyContinue)) {
                    $parametersPath = Join-Path -Path $instanceKey.PSPath -ChildPath 'Device Parameters'
                    $edid = $null
                    $edidError = $null
                    if (Test-Path -LiteralPath $parametersPath) {
                        try {
                            $props = Get-ItemProperty -LiteralPath $parametersPath -ErrorAction Stop
                            $rawEdid = Get-ObjectPropertyValue -InputObject $props -PropertyName 'EDID'
                            if ($rawEdid) {
                                $edid = ConvertTo-PlainSnapshotValue $rawEdid
                            }
                        } catch {
                            $edidError = $_.Exception.Message
                        }
                    }

                    $items.Add([PSCustomObject]@{
                        DisplayId     = $vendorKey.PSChildName
                        InstanceKey   = $instanceKey.PSChildName
                        InstancePath  = $instanceKey.Name
                        HasEdid       = ($null -ne $edid)
                        Edid          = $edid
                        Error         = $edidError
                    })
                }
            }

            return @($items)
        }

        function Get-WmiMonitorEvidence {
            $classes = @(
                'WmiMonitorID',
                'WmiMonitorBasicDisplayParams',
                'WmiMonitorConnectionParams'
            )

            $result = [ordered]@{}
            foreach ($className in $classes) {
                try {
                    $result[$className] = @(
                        Get-CimInstance -Namespace 'root\wmi' -ClassName $className -ErrorAction Stop |
                            ForEach-Object {
                                $entry = [ordered]@{}
                                foreach ($property in $_.PSObject.Properties) {
                                    if ($property.Name -in @('CimClass', 'CimInstanceProperties', 'CimSystemProperties', 'PSComputerName', 'RunspaceId')) {
                                        continue
                                    }
                                    $entry[$property.Name] = ConvertTo-PlainSnapshotValue $property.Value
                                }
                                [PSCustomObject]$entry
                            }
                    )
                } catch {
                    $result[$className] = [PSCustomObject]@{
                        Error = $_.Exception.Message
                    }
                }
            }

            return [PSCustomObject]$result
        }

        if ($Stage -eq 'System') {
            $computerSystem = Get-CimFirstOrNull -ClassName 'Win32_ComputerSystem'
            $computerProduct = Get-CimFirstOrNull -ClassName 'Win32_ComputerSystemProduct'
            $baseBoard = Get-CimFirstOrNull -ClassName 'Win32_BaseBoard'
            $bios = Get-CimFirstOrNull -ClassName 'Win32_BIOS'
            $operatingSystem = Get-CimFirstOrNull -ClassName 'Win32_OperatingSystem'
            $processor = Get-CimFirstOrNull -ClassName 'Win32_Processor'
            $memory = Get-MachineMemorySnapshot -ComputerSystem $computerSystem

            $identitySeed = @(
                Get-ObjectPropertyValue -InputObject $computerProduct -PropertyName 'UUID'
                Get-ObjectPropertyValue -InputObject $baseBoard -PropertyName 'SerialNumber'
                Get-ObjectPropertyValue -InputObject $bios -PropertyName 'SerialNumber'
                Get-ObjectPropertyValue -InputObject $computerSystem -PropertyName 'Name'
            ) -join '|'
            $machineId = New-ShortHash -Text $identitySeed

            return [PSCustomObject]@{
                MachineId             = $machineId
                ComputerSystem        = Get-CimSnapshot -InputObject $computerSystem -PropertyNames @('Name', 'Manufacturer', 'Model', 'SystemType', 'TotalPhysicalMemory', 'Domain', 'Workgroup')
                ComputerSystemProduct = Get-CimSnapshot -InputObject $computerProduct -PropertyNames @('Name', 'Vendor', 'Version', 'UUID', 'IdentifyingNumber')
                BaseBoard             = Get-CimSnapshot -InputObject $baseBoard -PropertyNames @('Manufacturer', 'Product', 'Version', 'SerialNumber')
                BIOS                  = Get-CimSnapshot -InputObject $bios -PropertyNames @('Manufacturer', 'SMBIOSBIOSVersion', 'ReleaseDate', 'SerialNumber')
                OperatingSystem       = Get-CimSnapshot -InputObject $operatingSystem -PropertyNames @('Caption', 'Version', 'BuildNumber', 'OSArchitecture', 'InstallDate', 'LastBootUpTime')
                Processor             = Get-CimSnapshot -InputObject $processor -PropertyNames @('Name', 'Manufacturer', 'NumberOfCores', 'NumberOfLogicalProcessors')
                Memory                = $memory
            }
        }

        if ($Stage -eq 'Devices') {
            $devices = @()
            try {
                $rawDevices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Sort-Object Class, FriendlyName, InstanceId)
                foreach ($device in $rawDevices) {
                    $instanceId = [string](Get-ObjectPropertyValue -InputObject $device -PropertyName 'InstanceId')
                    if ([string]::IsNullOrWhiteSpace($instanceId)) {
                        $instanceId = [string](Get-ObjectPropertyValue -InputObject $device -PropertyName 'PNPDeviceID')
                    }

                    $devices += [PSCustomObject]@{
                        Class                     = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'Class')
                        FriendlyName              = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'FriendlyName')
                        InstanceId                = ConvertTo-PlainSnapshotValue $instanceId
                        Status                    = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'Status')
                        Problem                   = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'Problem')
                        ProblemDescription        = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'ProblemDescription')
                        ConfigManagerErrorCode    = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'ConfigManagerErrorCode')
                        Manufacturer              = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'Manufacturer')
                        Service                   = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'Service')
                        HardwareId                = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'HardwareID')
                        CompatibleId              = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'CompatibleID')
                    }
                }
            } catch {}
            return $devices
        }

        if ($Stage -eq 'Properties') {
            $deviceProperties = [ordered]@{}
            if (-not $QuickMode) {
                try {
                    $rawDevices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
                    $instanceIds = @()
                    foreach ($device in $rawDevices) {
                        $instanceId = [string](Get-ObjectPropertyValue -InputObject $device -PropertyName 'InstanceId')
                        if (-not [string]::IsNullOrWhiteSpace($instanceId)) {
                            $instanceIds += $instanceId
                        }
                    }
                    if ($instanceIds.Count -gt 0) {
                        $allProps = Get-PnpDeviceProperty -InstanceId $instanceIds -KeyName $importantKeys -ErrorAction SilentlyContinue
                        $grouped = $allProps | Group-Object -Property InstanceId -AsHashTable -AsString
                        foreach ($instId in $instanceIds) {
                            $propsList = $grouped[$instId]
                            if ($propsList) {
                                $deviceProperties[$instId] = @(
                                    foreach ($p in $propsList) {
                                        [PSCustomObject]@{
                                            KeyName = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $p -PropertyName 'KeyName')
                                            Type    = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $p -PropertyName 'Type')
                                            Data    = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $p -PropertyName 'Data')
                                        }
                                    }
                                )
                            } else {
                                $deviceProperties[$instId] = @()
                            }
                        }
                    }
                } catch {}
            }
            return [PSCustomObject]$deviceProperties
        }

        if ($Stage -eq 'PnpUtil') {
            $pnputilOutput = $null
            $pnputilError = $null
            try {
                $pnputilOutput = (& pnputil.exe /enum-devices /connected 2>&1) -join "`n"
            } catch {
                $pnputilError = $_.Exception.Message
            }
            return [PSCustomObject]@{
                Command = 'pnputil.exe /enum-devices /connected'
                Output  = $pnputilOutput
                Error   = $pnputilError
            }
        }

        if ($Stage -eq 'Monitors') {
            return [PSCustomObject]@{
                Registry = @(Get-MonitorRegistryEvidence)
                Wmi      = Get-WmiMonitorEvidence
            }
        }

        $started = Get-Date
        Write-Verbose "Remote: Collecting system identification via CIM..."
        $computerSystem = Get-CimFirstOrNull -ClassName 'Win32_ComputerSystem'
        $computerProduct = Get-CimFirstOrNull -ClassName 'Win32_ComputerSystemProduct'
        $baseBoard = Get-CimFirstOrNull -ClassName 'Win32_BaseBoard'
        $bios = Get-CimFirstOrNull -ClassName 'Win32_BIOS'
        $operatingSystem = Get-CimFirstOrNull -ClassName 'Win32_OperatingSystem'
        $processor = Get-CimFirstOrNull -ClassName 'Win32_Processor'
        $memory = Get-MachineMemorySnapshot -ComputerSystem $computerSystem

        $identitySeed = @(
            Get-ObjectPropertyValue -InputObject $computerProduct -PropertyName 'UUID'
            Get-ObjectPropertyValue -InputObject $baseBoard -PropertyName 'SerialNumber'
            Get-ObjectPropertyValue -InputObject $bios -PropertyName 'SerialNumber'
            Get-ObjectPropertyValue -InputObject $computerSystem -PropertyName 'Name'
        ) -join '|'
        $machineId = New-ShortHash -Text $identitySeed

        $devices = @()
        $deviceProperties = [ordered]@{}
        $deviceErrors = [System.Collections.Generic.List[object]]::new()

        try {
            Write-Verbose "Remote: Scanning present PnP devices..."
            $rawDevices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Sort-Object Class, FriendlyName, InstanceId)
            $deviceCount = @($rawDevices).Count
            Write-Verbose "Remote: Found $deviceCount present devices. Processing..."
            
            $i = 0
            foreach ($device in $rawDevices) {
                $i++
                $instanceId = [string](Get-ObjectPropertyValue -InputObject $device -PropertyName 'InstanceId')
                if ([string]::IsNullOrWhiteSpace($instanceId)) {
                    $instanceId = [string](Get-ObjectPropertyValue -InputObject $device -PropertyName 'PNPDeviceID')
                }

                $devices += [PSCustomObject]@{
                    Class                     = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'Class')
                    FriendlyName              = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'FriendlyName')
                    InstanceId                = ConvertTo-PlainSnapshotValue $instanceId
                    Status                    = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'Status')
                    Problem                   = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'Problem')
                    ProblemDescription        = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'ProblemDescription')
                    ConfigManagerErrorCode    = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'ConfigManagerErrorCode')
                    Manufacturer              = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'Manufacturer')
                    Service                   = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'Service')
                    HardwareId                = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'HardwareID')
                    CompatibleId              = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $device -PropertyName 'CompatibleID')
                }

            }

            if (-not $QuickMode -and $rawDevices.Count -gt 0) {
                Write-Verbose "Remote: Batch collecting PnP properties for all devices..."
                try {
                    $instanceIds = @()
                    foreach ($d in $rawDevices) {
                        $instanceId = [string](Get-ObjectPropertyValue -InputObject $d -PropertyName 'InstanceId')
                        if ([string]::IsNullOrWhiteSpace($instanceId)) {
                            $instanceId = [string](Get-ObjectPropertyValue -InputObject $d -PropertyName 'PNPDeviceID')
                        }
                        if (-not [string]::IsNullOrWhiteSpace($instanceId)) {
                            $instanceIds += $instanceId
                        }
                    }
                    if ($instanceIds.Count -gt 0) {
                        $allProps = Get-PnpDeviceProperty -InstanceId $instanceIds -KeyName $importantKeys -ErrorAction SilentlyContinue
                        $grouped = $allProps | Group-Object -Property InstanceId -AsHashTable -AsString
                        foreach ($instId in $instanceIds) {
                            $propsList = $grouped[$instId]
                            if ($propsList) {
                                $deviceProperties[$instId] = @(
                                    foreach ($p in $propsList) {
                                        [PSCustomObject]@{
                                            KeyName = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $p -PropertyName 'KeyName')
                                            Type    = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $p -PropertyName 'Type')
                                            Data    = ConvertTo-PlainSnapshotValue (Get-ObjectPropertyValue -InputObject $p -PropertyName 'Data')
                                        }
                                    }
                                )
                            } else {
                                $deviceProperties[$instId] = @()
                            }
                        }
                    }
                } catch {
                    Write-Verbose "Error batch collecting properties in main flow: $_"
                }
            }
        } catch {
            $deviceErrors.Add([PSCustomObject]@{
                Stage = 'Get-PnpDevice'
                Error = $_.Exception.Message
            })
        }

        Write-Verbose "Remote: Enumerating active driver packages via pnputil..."
        $pnputilOutput = $null
        $pnputilError = $null
        try {
            $pnputilOutput = (& pnputil.exe /enum-devices /connected 2>&1) -join "`n"
        } catch {
            $pnputilError = $_.Exception.Message
        }

        $isAdmin = $false
        try {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = [Security.Principal.WindowsPrincipal]::new($identity)
            $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch {}

        Write-Verbose "Remote: Collecting monitor and display EDID/WMI details..."
        $monRegistry = @(Get-MonitorRegistryEvidence)
        $monWmi = Get-WmiMonitorEvidence
        Write-Verbose "Remote: Snapshot collection completed successfully."

        $finished = Get-Date
        return [PSCustomObject]@{
            SchemaVersion = 'DeviceCheckEvidenceSnapshot/0.1'
            Collector     = [PSCustomObject]@{
                Name                  = 'DeviceCheckEvidenceExporter'
                Version               = $CollectorVersion
                RequestedComputerName = $RequestedComputerName
                TargetComputerName    = $env:COMPUTERNAME
                UserName              = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                IsAdmin               = $isAdmin
                PowerShellVersion     = $PSVersionTable.PSVersion.ToString()
                StartedAt             = $started.ToString('o')
                FinishedAt            = $finished.ToString('o')
                DurationMs            = [int](New-TimeSpan -Start $started -End $finished).TotalMilliseconds
                QuickMode             = $QuickMode
            }
            Machine       = [PSCustomObject]@{
                MachineId             = $machineId
                ComputerSystem        = Get-CimSnapshot -InputObject $computerSystem -PropertyNames @('Name', 'Manufacturer', 'Model', 'SystemType', 'TotalPhysicalMemory', 'Domain', 'Workgroup')
                ComputerSystemProduct = Get-CimSnapshot -InputObject $computerProduct -PropertyNames @('Name', 'Vendor', 'Version', 'UUID', 'IdentifyingNumber')
                BaseBoard             = Get-CimSnapshot -InputObject $baseBoard -PropertyNames @('Manufacturer', 'Product', 'Version', 'SerialNumber')
                BIOS                  = Get-CimSnapshot -InputObject $bios -PropertyNames @('Manufacturer', 'SMBIOSBIOSVersion', 'ReleaseDate', 'SerialNumber')
                OperatingSystem       = Get-CimSnapshot -InputObject $operatingSystem -PropertyNames @('Caption', 'Version', 'BuildNumber', 'OSArchitecture', 'InstallDate', 'LastBootUpTime')
                Processor             = Get-CimSnapshot -InputObject $processor -PropertyNames @('Name', 'Manufacturer', 'NumberOfCores', 'NumberOfLogicalProcessors')
                Memory                = $memory
            }
            Devices       = [PSCustomObject]@{
                Count      = @($devices).Count
                Present    = @($devices)
                Properties = [PSCustomObject]$deviceProperties
                Errors     = @($deviceErrors)
            }
            PnpUtil       = [PSCustomObject]@{
                Command = 'pnputil.exe /enum-devices /connected'
                Output  = $pnputilOutput
                Error   = $pnputilError
            }
            Monitors      = [PSCustomObject]@{
                Registry = $monRegistry
                Wmi      = $monWmi
            }
        }
    }
}

$isLocal = Test-LocalTarget -Name $ComputerName

if (-not $isLocal -and -not $SkipTrustedHosts) {
    if (-not $AsJson) {
        Write-Host "Checking TrustedHosts for '$ComputerName'..." -ForegroundColor Cyan
    }
    $trustResult = Add-TrustedHostExact -Target $ComputerName
    if (-not $AsJson) {
        if ($trustResult.Changed) {
            Write-Host "TrustedHosts updated: $($trustResult.Value)" -ForegroundColor Yellow
        } else {
            Write-Host "TrustedHosts already includes '$ComputerName'." -ForegroundColor DarkGray
        }
    }
}

if (-not $isLocal -and $null -eq $Credential -and -not $UseCurrentCredentials) {
    $cacheRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'DeviceCheck'
    if ([string]::IsNullOrWhiteSpace($cacheRoot)) {
        $cacheRoot = Join-Path -Path $env:TEMP -ChildPath 'DeviceCheck'
    }
    $credFolder = Join-Path -Path $cacheRoot -ChildPath 'credentials'
    $credPath = Join-Path -Path $credFolder -ChildPath "$($ComputerName.ToLower()).xml"
    if (Test-Path -LiteralPath $credPath -PathType Leaf) {
        try {
            $Credential = Import-Clixml -Path $credPath -ErrorAction Stop
        } catch {}
    }

    if ($null -eq $Credential) {
        if ([string]::IsNullOrWhiteSpace($UserName)) {
            $UserName = "$ComputerName\joty79"
        }
        $Credential = Get-Credential -UserName $UserName -Message "Enter credentials for $ComputerName"
        if ($null -ne $Credential) {
            try {
                $null = New-Item -ItemType Directory -Path $credFolder -Force -ErrorAction SilentlyContinue
                $Credential | Export-Clixml -Path $credPath
            } catch {}
        }
    }
} elseif (-not $isLocal -and $null -ne $Credential) {
    $cacheRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'DeviceCheck'
    if ([string]::IsNullOrWhiteSpace($cacheRoot)) {
        $cacheRoot = Join-Path -Path $env:TEMP -ChildPath 'DeviceCheck'
    }
    $credFolder = Join-Path -Path $cacheRoot -ChildPath 'credentials'
    $credPath = Join-Path -Path $credFolder -ChildPath "$($ComputerName.ToLower()).xml"
    try {
        $null = New-Item -ItemType Directory -Path $credFolder -Force -ErrorAction SilentlyContinue
        $Credential | Export-Clixml -Path $credPath
    } catch {}
}

$collector = New-CollectorScriptBlock

if (-not $AsJson) {
    Write-Host "Collecting DeviceCheck evidence from $ComputerName..." -ForegroundColor Cyan
}
if ($isLocal) {
    Write-Verbose "Starting local snapshot collection..."
    $snapshot = & $collector $ComputerName ([bool]$Quick) $script:CollectorVersion
} else {
    Write-Verbose "Connecting to target PC $ComputerName via WinRM..."
    $sessionOption = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 15000
    $sessionParams = @{
        ComputerName  = $ComputerName
        SessionOption = $sessionOption
        ErrorAction   = 'Stop'
    }
    if ($null -ne $Credential) {
        $sessionParams.Credential = $Credential
    }
    $session = New-PSSession @sessionParams

    try {
        Write-Verbose "Remote: Collecting system identification..."
        $machine = Invoke-Command -Session $session -ScriptBlock $collector -ArgumentList @($ComputerName, [bool]$Quick, $script:CollectorVersion, 'System')

        Write-Verbose "Remote: Scanning present PnP devices..."
        $presentDevices = Invoke-Command -Session $session -ScriptBlock $collector -ArgumentList @($ComputerName, [bool]$Quick, $script:CollectorVersion, 'Devices')

        $deviceProperties = [ordered]@{}
        if (-not $Quick) {
            Write-Verbose "Remote: Collecting PnP device properties..."
            $deviceProperties = Invoke-Command -Session $session -ScriptBlock $collector -ArgumentList @($ComputerName, [bool]$Quick, $script:CollectorVersion, 'Properties')
        }

        Write-Verbose "Remote: Enumerating active driver packages via pnputil..."
        $pnpUtil = Invoke-Command -Session $session -ScriptBlock $collector -ArgumentList @($ComputerName, [bool]$Quick, $script:CollectorVersion, 'PnpUtil')

        Write-Verbose "Remote: Collecting monitor and display EDID/WMI details..."
        $monitors = Invoke-Command -Session $session -ScriptBlock $collector -ArgumentList @($ComputerName, [bool]$Quick, $script:CollectorVersion, 'Monitors')

        Write-Verbose "Remote: Snapshot collection completed successfully."

        $isAdmin = $false
        try {
            $isAdmin = Invoke-Command -Session $session -ScriptBlock {
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                $principal = [Security.Principal.WindowsPrincipal]::new($identity)
                $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            }
        } catch {}

        $snapshot = [PSCustomObject]@{
            SchemaVersion = 'DeviceCheckEvidenceSnapshot/0.1'
            Collector     = [PSCustomObject]@{
                Name                  = 'DeviceCheckEvidenceExporter'
                Version               = $script:CollectorVersion
                RequestedComputerName = $ComputerName
                TargetComputerName    = $machine.ComputerSystem.Name
                UserName              = $Credential.UserName
                IsAdmin               = $isAdmin
                PowerShellVersion     = (Invoke-Command -Session $session -ScriptBlock { $PSVersionTable.PSVersion.ToString() })
                StartedAt             = (Get-Date).ToString('o')
                FinishedAt            = (Get-Date).ToString('o')
                DurationMs            = 0
                QuickMode             = [bool]$Quick
            }
            Machine       = $machine
            Devices       = [PSCustomObject]@{
                Count      = @($presentDevices).Count
                Present    = @($presentDevices)
                Properties = $deviceProperties
                Errors     = @()
            }
            PnpUtil       = $pnpUtil
            Monitors      = $monitors
        }
    } finally {
        Remove-PSSession $session
    }
}

$snapshotJson = $snapshot | ConvertTo-Json -Depth 40
$outputPath = $null
$latestPath = $null

if (-not $NoSave) {
    Write-Verbose "Saving snapshot JSON files to disk..."
    $machineName = $snapshot.Machine.ComputerSystem.Name
    if ([string]::IsNullOrWhiteSpace($machineName)) {
        $machineName = $ComputerName
    }
    $machineId = $snapshot.Machine.MachineId
    if ([string]::IsNullOrWhiteSpace($machineId)) {
        $machineId = 'unknown-machine'
    }

    $targetFolder = Join-Path -Path $OutputRoot -ChildPath (ConvertTo-SafeFileName -Text "$machineName-$machineId")
    if (-not (Test-Path -LiteralPath $targetFolder)) {
        $null = New-Item -ItemType Directory -Path $targetFolder -Force
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outputPath = Join-Path -Path $targetFolder -ChildPath "$stamp.json"
    $latestPath = Join-Path -Path $targetFolder -ChildPath 'latest.json'
    $snapshotJson | Set-Content -LiteralPath $outputPath -Encoding UTF8
    $snapshotJson | Set-Content -LiteralPath $latestPath -Encoding UTF8
}

$summary = [PSCustomObject]@{
    ComputerName        = $snapshot.Machine.ComputerSystem.Name
    RequestedTarget     = $ComputerName
    UserName            = $snapshot.Collector.UserName
    PowerShellVersion   = $snapshot.Collector.PowerShellVersion
    IsAdmin             = $snapshot.Collector.IsAdmin
    QuickMode           = $snapshot.Collector.QuickMode
    DeviceCount         = $snapshot.Devices.Count
    MonitorRegistryKeys = @($snapshot.Monitors.Registry).Count
    DurationMs          = $snapshot.Collector.DurationMs
    OutputPath          = $outputPath
    LatestPath          = $latestPath
}

if ($AsJson) {
    $summary | ConvertTo-Json -Depth 8
} else {
    Write-Host ''
    Write-Host 'DeviceCheck evidence export complete.' -ForegroundColor Green
    $summary | Format-List
}

if ($PassThru) {
    $snapshot
}
