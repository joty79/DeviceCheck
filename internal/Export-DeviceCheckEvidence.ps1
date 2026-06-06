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
        $shellPath = [System.Diagnostics.Process]::GetCurrentProcess().Path

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
            [string]$CollectorVersion
        )

        $ErrorActionPreference = 'Stop'

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

        $started = Get-Date
        $computerSystem = Get-CimFirstOrNull -ClassName 'Win32_ComputerSystem'
        $computerProduct = Get-CimFirstOrNull -ClassName 'Win32_ComputerSystemProduct'
        $baseBoard = Get-CimFirstOrNull -ClassName 'Win32_BaseBoard'
        $bios = Get-CimFirstOrNull -ClassName 'Win32_BIOS'
        $operatingSystem = Get-CimFirstOrNull -ClassName 'Win32_OperatingSystem'
        $processor = Get-CimFirstOrNull -ClassName 'Win32_Processor'

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

                if (-not $QuickMode -and -not [string]::IsNullOrWhiteSpace($instanceId)) {
                    $deviceProperties[$instanceId] = Get-PnpDevicePropertiesSafe -InstanceId $instanceId
                }
            }
        } catch {
            $deviceErrors.Add([PSCustomObject]@{
                Stage = 'Get-PnpDevice'
                Error = $_.Exception.Message
            })
        }

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
                Registry = @(Get-MonitorRegistryEvidence)
                Wmi      = Get-WmiMonitorEvidence
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
    $snapshot = & $collector $ComputerName ([bool]$Quick) $script:CollectorVersion
} else {
    $invokeParams = @{
        ComputerName = $ComputerName
        ScriptBlock  = $collector
        ArgumentList  = @($ComputerName, [bool]$Quick, $script:CollectorVersion)
        ErrorAction   = 'Stop'
    }
    if ($null -ne $Credential) {
        $invokeParams.Credential = $Credential
    }

    $snapshot = Invoke-Command @invokeParams
}

$snapshotJson = $snapshot | ConvertTo-Json -Depth 40
$outputPath = $null
$latestPath = $null

if (-not $NoSave) {
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
