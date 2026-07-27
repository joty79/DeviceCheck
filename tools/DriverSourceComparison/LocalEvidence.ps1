Set-StrictMode -Version Latest

function Get-DriverComparisonPnpProperty {
    param(
        [hashtable]$PropertyMap,
        [string]$KeyName
    )

    if ($PropertyMap.ContainsKey($KeyName)) { return $PropertyMap[$KeyName] }
    return $null
}

function ConvertTo-DriverComparisonStringArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    return @(
        foreach ($item in @($Value)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$item)) {
                ([string]$item).Trim()
            }
        }
    )
}

function Get-DriverComparisonLocalEvidence {
    param(
        [AllowEmptyString()]
        [string]$Filter,

        [AllowEmptyString()]
        [string]$InstanceId,

        [AllowEmptyString()]
        [string]$KnownActiveSource,

        $BenchmarkRecorder,

        [switch]$IncludeSignatureEvidence
    )

    $pnpStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $devices = if (-not [string]::IsNullOrWhiteSpace($InstanceId)) {
        @(Get-PnpDevice -InstanceId $InstanceId -ErrorAction Stop)
    }
    else {
        @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object {
                $_.FriendlyName -like "*$Filter*" -or $_.InstanceId -like "*$Filter*"
            })
    }
    $pnpStopwatch.Stop()
    if ($null -ne $BenchmarkRecorder) {
        Add-DriverBenchmarkPhase -Recorder $BenchmarkRecorder -Name 'GetPnpDevice' -ElapsedMilliseconds $pnpStopwatch.ElapsedMilliseconds
    }

    if ($devices.Count -eq 0) {
        throw "No present PnP device matched '$Filter'."
    }
    if ($devices.Count -gt 1) {
        $matchDescriptions = ($devices | Select-Object -First 8 | ForEach-Object { "'$($_.FriendlyName)' [$($_.InstanceId)]" }) -join ', '
        throw "Device filter '$Filter' is ambiguous. Matches: $matchDescriptions"
    }

    $device = $devices[0]
    $propertyStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $allProperties = @(Get-PnpDeviceProperty -InstanceId $device.InstanceId -ErrorAction Stop)
    $propertyStopwatch.Stop()
    if ($null -ne $BenchmarkRecorder) {
        Add-DriverBenchmarkPhase -Recorder $BenchmarkRecorder -Name 'PnpPropertyBulk' -ElapsedMilliseconds $propertyStopwatch.ElapsedMilliseconds -Detail "$($allProperties.Count) properties"
    }
    $propertyMap = @{}
    foreach ($property in $allProperties) { $propertyMap[[string]$property.KeyName] = $property.Data }

    $signedDriver = @()
    if ($IncludeSignatureEvidence) {
        $wqlDeviceId = $device.InstanceId.Replace('\', '\\').Replace("'", "''")
        $cimStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $signedDriver = @(Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceID = '$wqlDeviceId'" -ErrorAction Stop | Select-Object -First 1)
        $cimStopwatch.Stop()
        if ($null -ne $BenchmarkRecorder) {
            Add-DriverBenchmarkPhase -Recorder $BenchmarkRecorder -Name 'Win32PnpSignedDriver' -ElapsedMilliseconds $cimStopwatch.ElapsedMilliseconds
        }
    }

    $driverDate = Get-DriverComparisonPnpProperty -PropertyMap $propertyMap -KeyName 'DEVPKEY_Device_DriverDate'
    $problemCode = Get-DriverComparisonPnpProperty -PropertyMap $propertyMap -KeyName 'DEVPKEY_Device_ProblemCode'

    [pscustomobject]@{
        Source            = 'ActiveStack'
        Confidence        = 'Observed'
        EvidenceSource    = @('Get-PnpDevice', 'Get-PnpDeviceProperty (bulk)', $(if ($IncludeSignatureEvidence) { 'Win32_PnPSignedDriver' }))
        KnownProvenance   = $KnownActiveSource
        Device            = [pscustomobject]@{
            FriendlyName  = [string]$device.FriendlyName
            InstanceId    = [string]$device.InstanceId
            Class         = [string]$device.Class
            Status        = [string]$device.Status
            ProblemCode   = if ($null -eq $problemCode) { $device.Problem } else { $problemCode }
            HardwareIds   = @(ConvertTo-DriverComparisonStringArray -Value (Get-DriverComparisonPnpProperty -PropertyMap $propertyMap -KeyName 'DEVPKEY_Device_HardwareIds'))
            CompatibleIds = @(ConvertTo-DriverComparisonStringArray -Value (Get-DriverComparisonPnpProperty -PropertyMap $propertyMap -KeyName 'DEVPKEY_Device_CompatibleIds'))
        }
        ActiveDriver      = [pscustomobject]@{
            PublishedInf     = [string](Get-DriverComparisonPnpProperty -PropertyMap $propertyMap -KeyName 'DEVPKEY_Device_DriverInfPath')
            Provider         = [string](Get-DriverComparisonPnpProperty -PropertyMap $propertyMap -KeyName 'DEVPKEY_Device_DriverProvider')
            Version          = [string](Get-DriverComparisonPnpProperty -PropertyMap $propertyMap -KeyName 'DEVPKEY_Device_DriverVersion')
            Date             = if ($driverDate -is [datetime]) { $driverDate.ToString('yyyy-MM-dd') } else { [string]$driverDate }
            MatchingDeviceId = [string](Get-DriverComparisonPnpProperty -PropertyMap $propertyMap -KeyName 'DEVPKEY_Device_MatchingDeviceId')
            Signer           = if ($signedDriver.Count -gt 0) { [string]$signedDriver[0].Signer } else { '' }
            IsSigned         = if ($signedDriver.Count -gt 0) { [bool]$signedDriver[0].IsSigned } else { $null }
            ActiveState      = 'Active'
            PackageRole      = 'BaseOrFunctionDriver'
        }
    }
}
