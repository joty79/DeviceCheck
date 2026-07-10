[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TraceDirectory,

    [switch]$PauseAtEnd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-ObjectValue {
    param(
        [AllowNull()][object]$InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-MarkdownCell {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", '<br>')
}

function Get-PnpUtilDriverStack {
    $output = @(& pnputil.exe /enum-devices /drivers 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        throw "pnputil /enum-devices /drivers exited with code $LASTEXITCODE"
    }

    $rows = New-Object System.Collections.Generic.List[object]
    $instanceId = ''
    $deviceName = ''
    $current = $null
    foreach ($line in $output) {
        if ($line -match '^Instance ID:\s*(.+?)\s*$') {
            $nextInstanceId = $Matches[1].Trim()
            if ($null -ne $current) { $rows.Add([pscustomobject]$current) | Out-Null }
            $current = $null
            $instanceId = $nextInstanceId
            $deviceName = ''
            continue
        }
        if ($line -match '^Device Description:\s*(.*?)\s*$') {
            $deviceName = $Matches[1].Trim()
            continue
        }
        if ($line -match '^\s{4}Driver Name:\s*(.+?)\s*$') {
            $driverName = $Matches[1].Trim()
            if ($null -ne $current) { $rows.Add([pscustomobject]$current) | Out-Null }
            $current = [ordered]@{
                InstanceId = $InstanceId
                DeviceName = $DeviceName
                DriverName = $driverName
                OriginalName = ''
                ProviderName = ''
                ClassName = ''
                DriverVersion = ''
                ExtensionId = ''
                DriverStatus = ''
            }
            continue
        }
        if ($null -eq $current) { continue }

        if ($line -match '^\s{4}(Original Name|Provider Name|Class Name|Driver Version|Extension ID|Driver Status):\s*(.*?)\s*$') {
            $propertyName = switch ($Matches[1]) {
                'Original Name' { 'OriginalName' }
                'Provider Name' { 'ProviderName' }
                'Class Name' { 'ClassName' }
                'Driver Version' { 'DriverVersion' }
                'Extension ID' { 'ExtensionId' }
                'Driver Status' { 'DriverStatus' }
            }
            $current[$propertyName] = $Matches[2].Trim()
        }
    }
    if ($null -ne $current) { $rows.Add([pscustomobject]$current) | Out-Null }
    return $rows.ToArray()
}

function Get-RelevantPostBootEvents {
    param(
        [datetime]$BootTime,
        [string[]]$SearchTerms
    )

    $terms = @($SearchTerms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($terms.Count -eq 0) { return @() }

    $events = New-Object System.Collections.Generic.List[object]
    foreach ($logName in @('System', 'Application')) {
        try {
            $candidates = @(Get-WinEvent -FilterHashtable @{
                LogName = $logName
                Level = 2, 3
                StartTime = $BootTime
            } -ErrorAction Stop)
        } catch {
            continue
        }

        foreach ($event in $candidates) {
            $message = [string]$event.Message
            $matchedTerm = $terms | Where-Object {
                $message.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            } | Select-Object -First 1
            if ($null -eq $matchedTerm) { continue }
            $events.Add([pscustomobject]@{
                TimeCreated = $event.TimeCreated
                LogName = $logName
                Id = $event.Id
                ProviderName = $event.ProviderName
                Level = $event.LevelDisplayName
                MatchedTerm = $matchedTerm
                Message = ($message -replace '\s+', ' ').Trim()
            }) | Out-Null
        }
    }
    return @($events.ToArray() | Sort-Object TimeCreated)
}

$resolvedTraceDirectory = (Resolve-Path -LiteralPath $TraceDirectory).Path
$previewPath = Join-Path $resolvedTraceDirectory 'package-preview.json'
$afterPath = Join-Path $resolvedTraceDirectory 'after.snapshot.json'
$diffPath = Join-Path $resolvedTraceDirectory 'diff.json'

if (-not (Test-Path -LiteralPath $previewPath)) { throw "Missing package preview: $previewPath" }
$preview = Get-Content -LiteralPath $previewPath -Raw | ConvertFrom-Json
$after = if (Test-Path -LiteralPath $afterPath) { Get-Content -LiteralPath $afterPath -Raw | ConvertFrom-Json } else { $null }
$diff = if (Test-Path -LiteralPath $diffPath) { Get-Content -LiteralPath $diffPath -Raw | ConvertFrom-Json } else { $null }

Write-Host ''
Write-Host ('=' * 78) -ForegroundColor DarkCyan
Write-Host 'DeviceCheck Driver Package Post-Reboot Audit' -ForegroundColor Cyan
Write-Host ('=' * 78) -ForegroundColor DarkCyan
Write-Host "Trace   : $resolvedTraceDirectory"
Write-Host "Package : $($preview.InstallerPath)"

$matches = @(Get-ObjectValue -InputObject $preview -Name 'Matches')
$matchDevices = @($matches | Group-Object { ([string]$_.InstanceId).ToUpperInvariant() } | ForEach-Object { $_.Group[0] })
$allPnpDriverRows = @(Get-PnpUtilDriverStack)
$liveSignedDrivers = @(Get-CimInstance Win32_PnPSignedDriver | ForEach-Object {
    [pscustomobject]@{
        DeviceName = $_.DeviceName
        DeviceClass = $_.DeviceClass
        DeviceId = $_.DeviceID
        InfName = $_.InfName
        DriverProviderName = $_.DriverProviderName
        DriverVersion = $_.DriverVersion
        DriverDate = $_.DriverDate
        Manufacturer = $_.Manufacturer
    }
})
$liveSignedByDevice = @{}
foreach ($driver in $liveSignedDrivers) {
    if (-not [string]::IsNullOrWhiteSpace([string]$driver.DeviceId)) {
        $liveSignedByDevice[[string]$driver.DeviceId.ToUpperInvariant()] = $driver
    }
}

$afterSignedByDevice = @{}
if ($null -ne $after) {
    foreach ($driver in @(Get-ObjectValue -InputObject $after -Name 'SignedDrivers')) {
        $deviceId = [string](Get-ObjectValue -InputObject $driver -Name 'DeviceID')
        if (-not [string]::IsNullOrWhiteSpace($deviceId)) { $afterSignedByDevice[$deviceId.ToUpperInvariant()] = $driver }
    }
}

$deviceRows = New-Object System.Collections.Generic.List[object]
foreach ($matchDevice in $matchDevices) {
    $instanceId = [string]$matchDevice.InstanceId
    $key = $instanceId.ToUpperInvariant()
    $pnpDevice = Get-PnpDevice -InstanceId $instanceId -ErrorAction SilentlyContinue
    $liveDriver = $liveSignedByDevice[$key]
    $afterDriver = $afterSignedByDevice[$key]
    $changedSinceAfter = $false
    if ($null -ne $afterDriver -or $null -ne $liveDriver) {
        $changedSinceAfter = ([string](Get-ObjectValue $afterDriver 'InfName') -ne [string](Get-ObjectValue $liveDriver 'InfName')) -or
            ([string](Get-ObjectValue $afterDriver 'DriverVersion') -ne [string](Get-ObjectValue $liveDriver 'DriverVersion'))
    }
    $problemProperty = if ($null -ne $pnpDevice) {
        Get-PnpDeviceProperty -InstanceId $instanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue
    } else { $null }
    $problem = if ($null -ne $problemProperty) { [string]$problemProperty.Data } else { '' }

    $deviceRows.Add([pscustomobject]@{
        DeviceName = $matchDevice.DeviceName
        InstanceId = $instanceId
        Status = if ($null -ne $pnpDevice) { [string]$pnpDevice.Status } else { 'Not present' }
        ProblemCode = $problem
        ActiveInf = [string](Get-ObjectValue $liveDriver 'InfName')
        ActiveProvider = [string](Get-ObjectValue $liveDriver 'DriverProviderName')
        ActiveVersion = [string](Get-ObjectValue $liveDriver 'DriverVersion')
        ActiveDate = [string](Get-ObjectValue $liveDriver 'DriverDate')
        AfterInf = [string](Get-ObjectValue $afterDriver 'InfName')
        AfterVersion = [string](Get-ObjectValue $afterDriver 'DriverVersion')
        ChangedSinceAfter = $changedSinceAfter
    }) | Out-Null
}

$matchDeviceIdSet = @{}
foreach ($matchDevice in $matchDevices) { $matchDeviceIdSet[[string]$matchDevice.InstanceId.ToUpperInvariant()] = $true }
$installedMatchingDrivers = @($allPnpDriverRows | Where-Object {
    $_.DriverStatus -match 'Installed' -and $matchDeviceIdSet.ContainsKey(([string]$_.InstanceId).ToUpperInvariant())
})
$allInstalledDrivers = @($allPnpDriverRows | Where-Object { $_.DriverStatus -match 'Installed' })
$addedPackages = if ($null -ne $diff) { @(Get-ObjectValue -InputObject $diff -Name 'AddedPublishedDrivers') } else { @() }
$packageRows = New-Object System.Collections.Generic.List[object]
foreach ($package in $addedPackages) {
    $publishedName = [string]$package.PublishedName
    $activeBindings = @($liveSignedDrivers | Where-Object { [string]$_.InfName -ieq $publishedName })
    $installedBindings = @($allInstalledDrivers | Where-Object { [string]$_.DriverName -ieq $publishedName })
    $classification = if ($activeBindings.Count -gt 0) {
        'Active function driver'
    } elseif ($installedBindings.Count -gt 0) {
        'Installed extension/configuration'
    } elseif (Test-Path -LiteralPath (Join-Path $env:windir "INF\$publishedName")) {
        'Stored-only'
    } else {
        'Missing from Driver Store'
    }
    $boundDevices = @(
        @($activeBindings | ForEach-Object { $_.DeviceName }) +
        @($installedBindings | ForEach-Object { $_.DeviceName }) |
        Where-Object { $_ } |
        Sort-Object -Unique
    ) -join '; '
    $packageRows.Add([pscustomobject]@{
        PublishedName = $publishedName
        OriginalName = $package.OriginalName
        ClassName = $package.ClassName
        ProviderName = $package.ProviderName
        DriverVersion = $package.DriverVersion
        Classification = $classification
        BoundDevices = $boundDevices
    }) | Out-Null
}

$bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$searchTerms = @($deviceRows.ToArray() | ForEach-Object { $_.InstanceId; $_.DeviceName })
$events = @(Get-RelevantPostBootEvents -BootTime $bootTime -SearchTerms $searchTerms)
$problemDevices = @($deviceRows.ToArray() | Where-Object { $_.Status -notin @('OK', 'Unknown') -or ($_.ProblemCode -and $_.ProblemCode -ne '0') })
$changedDevices = @($deviceRows.ToArray() | Where-Object ChangedSinceAfter)
$appliedPackages = @($packageRows.ToArray() | Where-Object Classification -in @('Active function driver', 'Installed extension/configuration'))

$verdict = if ($problemDevices.Count -gt 0) {
    'Attention: one or more matched devices report a current problem'
} elseif ($changedDevices.Count -gt 0) {
    'Post-reboot active driver state differs from the original after snapshot'
} elseif ($appliedPackages.Count -gt 0) {
    'A package component remains actively applied after reboot'
} else {
    'No post-reboot active driver change detected; newly staged packages are stored-only or absent'
}

$snapshot = [pscustomobject]@{
    GeneratedAt = (Get-Date).ToString('o')
    TraceDirectory = $resolvedTraceDirectory
    InstallerPath = $preview.InstallerPath
    BootTime = $bootTime
    Verdict = $verdict
    MatchedDevices = $deviceRows.ToArray()
    InstalledMatchingDrivers = $installedMatchingDrivers
    AddedPackageStatus = $packageRows.ToArray()
    RelevantPostBootEvents = $events
    PnpUtilParsingNote = 'Global installed-driver detection expects the current English pnputil field labels.'
}
$snapshotPath = Join-Path $resolvedTraceDirectory 'post-reboot.snapshot.json'
$snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $snapshotPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Driver Package Post-Reboot Audit')
$lines.Add('')
$lines.Add(('Generated: `{0}`' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
$lines.Add(('- Package: `{0}`' -f $preview.InstallerPath))
$lines.Add(('- Boot time: `{0}`' -f $bootTime))
$lines.Add(('- Verdict: **{0}**' -f (ConvertTo-MarkdownCell $verdict)))
$lines.Add('')
$lines.Add('## Matched Devices: Current Active Function Drivers')
$lines.Add('')
if ($deviceRows.Count -eq 0) {
    $lines.Add('The package preview had no local device matches.')
} else {
    $lines.Add('| Device | Status / problem | Active INF | Provider | Version | Changed since after snapshot |')
    $lines.Add('|---|---|---|---|---|---|')
    foreach ($row in $deviceRows) {
        $lines.Add(('| {0} | {1} / `{2}` | `{3}` | {4} | `{5}` | {6} |' -f
            (ConvertTo-MarkdownCell $row.DeviceName), (ConvertTo-MarkdownCell $row.Status),
            (ConvertTo-MarkdownCell $row.ProblemCode), (ConvertTo-MarkdownCell $row.ActiveInf),
            (ConvertTo-MarkdownCell $row.ActiveProvider), (ConvertTo-MarkdownCell $row.ActiveVersion),
            $row.ChangedSinceAfter))
    }
}
$lines.Add('')
$lines.Add('## Packages Added During the Trace')
$lines.Add('')
if ($packageRows.Count -eq 0) {
    $lines.Add('No newly published Driver Store packages were recorded in this trace.')
} else {
    $lines.Add('| Published INF | Original INF | Class | Version | Current state | Device |')
    $lines.Add('|---|---|---|---|---|---|')
    foreach ($row in $packageRows) {
        $lines.Add(('| `{0}` | `{1}` | {2} | `{3}` | **{4}** | {5} |' -f
            (ConvertTo-MarkdownCell $row.PublishedName), (ConvertTo-MarkdownCell $row.OriginalName),
            (ConvertTo-MarkdownCell $row.ClassName), (ConvertTo-MarkdownCell $row.DriverVersion),
            (ConvertTo-MarkdownCell $row.Classification), (ConvertTo-MarkdownCell $row.BoundDevices)))
    }
}
$lines.Add('')
$lines.Add('## Relevant Warning/Error Events Since Boot')
$lines.Add('')
if ($events.Count -eq 0) {
    $lines.Add('No System/Application warning or error directly mentioning a matched device name or instance ID was found since boot.')
} else {
    $lines.Add('| Time | Log | Provider / ID | Matched term | Message |')
    $lines.Add('|---|---|---|---|---|')
    foreach ($event in $events) {
        $lines.Add(('| `{0}` | {1} | {2} / `{3}` | `{4}` | {5} |' -f
            $event.TimeCreated, (ConvertTo-MarkdownCell $event.LogName),
            (ConvertTo-MarkdownCell $event.ProviderName), $event.Id,
            (ConvertTo-MarkdownCell $event.MatchedTerm), (ConvertTo-MarkdownCell $event.Message)))
    }
}
$lines.Add('')
$lines.Add('## Interpretation Guardrail')
$lines.Add('')
$lines.Add('A package listed as **Stored-only** is present in the Driver Store but is not the current function driver or an installed Extension/configuration driver for the matched devices. This audit is read-only and does not recommend deleting packages.')
$lines.Add('')
$lines.Add('Global installed-driver detection expects the current English `pnputil` field labels.')

$reportPath = Join-Path $resolvedTraceDirectory 'post-reboot-report.md'
Set-Content -LiteralPath $reportPath -Value $lines -Encoding UTF8

Write-Host ''
Write-Host "Verdict : $verdict" -ForegroundColor Green
Write-Host "Report  : $reportPath" -ForegroundColor Green
Write-Host "Evidence: $snapshotPath" -ForegroundColor Green

if ($PauseAtEnd) { [void](Read-Host 'Press Enter to close') }
