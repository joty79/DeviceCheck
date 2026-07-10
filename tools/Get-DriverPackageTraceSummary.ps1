[CmdletBinding()]
param(
    [string]$TraceRoot,
    [string]$OutputDirectory,
    [switch]$PauseAtEnd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-ObjectValue {
    param([AllowNull()][object]$InputObject, [string]$Name)
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

function Get-InstalledMatchingDrivers {
    $rows = New-Object System.Collections.Generic.List[object]
    $output = @(& pnputil.exe /enum-devices /drivers 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "pnputil /enum-devices /drivers exited with code $LASTEXITCODE" }

    $instanceId = ''
    $deviceName = ''
    $current = $null
    foreach ($line in $output) {
        if ($line -match '^Instance ID:\s*(.+?)\s*$') {
            $nextInstanceId = $Matches[1].Trim()
            if ($null -ne $current -and $current.DriverStatus -match 'Installed') {
                $rows.Add([pscustomobject]$current) | Out-Null
            }
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
            if ($null -ne $current -and $current.DriverStatus -match 'Installed') {
                $rows.Add([pscustomobject]$current) | Out-Null
            }
            $current = [ordered]@{
                InstanceId = $instanceId
                DeviceName = $deviceName
                DriverName = $driverName
                OriginalName = ''
                ClassName = ''
                DriverVersion = ''
                DriverStatus = ''
            }
            continue
        }
        if ($null -eq $current) { continue }
        if ($line -match '^\s{4}(Original Name|Class Name|Driver Version|Driver Status):\s*(.*?)\s*$') {
            $propertyName = switch ($Matches[1]) {
                'Original Name' { 'OriginalName' }
                'Class Name' { 'ClassName' }
                'Driver Version' { 'DriverVersion' }
                'Driver Status' { 'DriverStatus' }
            }
            $current[$propertyName] = $Matches[2].Trim()
        }
    }
    if ($null -ne $current -and $current.DriverStatus -match 'Installed') {
        $rows.Add([pscustomobject]$current) | Out-Null
    }
    return $rows.ToArray()
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if ([string]::IsNullOrWhiteSpace($TraceRoot)) {
    $TraceRoot = Join-Path $repoRoot '.devicecheck-data\driver-package-traces'
}
$resolvedTraceRoot = (Resolve-Path -LiteralPath $TraceRoot).Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = $resolvedTraceRoot }
if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
}
$resolvedOutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

Write-Host ''
Write-Host ('=' * 78) -ForegroundColor DarkCyan
Write-Host 'DeviceCheck Driver Package Trace Summary' -ForegroundColor Cyan
Write-Host ('=' * 78) -ForegroundColor DarkCyan
Write-Host "Trace root: $resolvedTraceRoot"

$traceRecords = New-Object System.Collections.Generic.List[object]
foreach ($directory in @(Get-ChildItem -LiteralPath $resolvedTraceRoot -Directory)) {
    $previewPath = Join-Path $directory.FullName 'package-preview.json'
    $afterPath = Join-Path $directory.FullName 'after.snapshot.json'
    $diffPath = Join-Path $directory.FullName 'diff.json'
    if (-not (Test-Path -LiteralPath $previewPath)) { continue }

    try {
        $preview = Get-Content -LiteralPath $previewPath -Raw | ConvertFrom-Json
        $after = if (Test-Path -LiteralPath $afterPath) { Get-Content -LiteralPath $afterPath -Raw | ConvertFrom-Json } else { $null }
        $diff = if (Test-Path -LiteralPath $diffPath) { Get-Content -LiteralPath $diffPath -Raw | ConvertFrom-Json } else { $null }
        $capturedAt = if ($null -ne $after) { [datetime]$after.CapturedAt } else { $directory.CreationTime }
        $traceRecords.Add([pscustomobject]@{
            Directory = $directory.FullName
            Name = $directory.Name
            CapturedAt = $capturedAt
            InstallerPath = [string]$preview.InstallerPath
            Preview = $preview
            After = $after
            Diff = $diff
        }) | Out-Null
    } catch {
        Write-Warning "Skipping unreadable trace '$($directory.FullName)': $($_.Exception.Message)"
    }
}

if ($traceRecords.Count -eq 0) { throw "No readable traces found under: $resolvedTraceRoot" }

$latestTraces = @($traceRecords.ToArray() |
    Group-Object { if ([string]::IsNullOrWhiteSpace($_.InstallerPath)) { $_.Name } else { $_.InstallerPath.ToUpperInvariant() } } |
    ForEach-Object { $_.Group | Sort-Object CapturedAt -Descending | Select-Object -First 1 } |
    Sort-Object InstallerPath)

$allMatchDevices = @($traceRecords.ToArray() | ForEach-Object { @(Get-ObjectValue $_.Preview 'Matches') } |
    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.InstanceId) } |
    Group-Object { ([string]$_.InstanceId).ToUpperInvariant() } | ForEach-Object { $_.Group[0] })
$installedDrivers = @(Get-InstalledMatchingDrivers)
$liveSignedDrivers = @(Get-CimInstance Win32_PnPSignedDriver | ForEach-Object {
    [pscustomobject]@{
        DeviceName = $_.DeviceName
        DeviceClass = $_.DeviceClass
        DeviceId = $_.DeviceID
        InfName = $_.InfName
        DriverProviderName = $_.DriverProviderName
        DriverVersion = $_.DriverVersion
        DriverDate = $_.DriverDate
    }
})

$packageOutcomeRows = New-Object System.Collections.Generic.List[object]
foreach ($trace in $latestTraces) {
    $matches = @(Get-ObjectValue $trace.Preview 'Matches')
    $added = @(if ($null -ne $trace.Diff) { Get-ObjectValue $trace.Diff 'AddedPublishedDrivers' })
    $actions = @(if ($null -ne $trace.Diff) { Get-ObjectValue $trace.Diff 'SetupApiDeviceInstallActions' })
    $appliedActions = @($actions | Where-Object { $_.IsNewlyStaged -and [string]$_.ExitStatus -eq '00000000' })
    $activeChanges = if ($null -ne $trace.Diff) {
        @(Get-ObjectValue $trace.Diff 'ChangedSignedDrivers').Count +
        @(Get-ObjectValue $trace.Diff 'AddedSignedDrivers').Count +
        @(Get-ObjectValue $trace.Diff 'RemovedSignedDrivers').Count
    } else { 0 }
    $payloadKind = [string](Get-ObjectValue $trace.Preview 'PayloadKind')
    $verdict = if ($activeChanges -gt 0) {
        'Active function binding changed'
    } elseif ($appliedActions.Count -gt 0) {
        'Extension/configuration applied'
    } elseif ($added.Count -gt 0) {
        'Packages staged; no active binding change'
    } elseif ([int](Get-ObjectValue $trace.Preview 'InfCount') -eq 0) {
        'No-INF utility/provisioning payload'
    } else {
        'No driver state change detected'
    }
    $packageOutcomeRows.Add([pscustomobject]@{
        Package = [System.IO.Path]::GetFileName([string]$trace.InstallerPath)
        InstallerPath = $trace.InstallerPath
        Trace = $trace.Name
        CapturedAt = $trace.CapturedAt
        PayloadKind = $payloadKind
        LocalMatches = $matches.Count
        StagedPackages = $added.Count
        AppliedConfigurations = $appliedActions.Count
        ActiveBindingChanges = $activeChanges
        Verdict = $verdict
    }) | Out-Null
}

$addedOccurrences = New-Object System.Collections.Generic.List[object]
foreach ($trace in $traceRecords) {
    if ($null -eq $trace.Diff) { continue }
    foreach ($package in @(Get-ObjectValue $trace.Diff 'AddedPublishedDrivers')) {
        $addedOccurrences.Add([pscustomobject]@{
            PublishedName = [string]$package.PublishedName
            OriginalName = [string]$package.OriginalName
            ProviderName = [string]$package.ProviderName
            ClassName = [string]$package.ClassName
            DriverVersion = [string]$package.DriverVersion
            SourcePackage = [System.IO.Path]::GetFileName([string]$trace.InstallerPath)
            CapturedAt = $trace.CapturedAt
        }) | Out-Null
    }
}

$addedPackageRows = New-Object System.Collections.Generic.List[object]
foreach ($group in @($addedOccurrences.ToArray() | Group-Object { $_.PublishedName.ToUpperInvariant() })) {
    $latest = $group.Group | Sort-Object CapturedAt -Descending | Select-Object -First 1
    $activeBindings = @($liveSignedDrivers | Where-Object { [string]$_.InfName -ieq $latest.PublishedName })
    $installedBindings = @($installedDrivers | Where-Object { [string]$_.DriverName -ieq $latest.PublishedName })
    $classification = if ($activeBindings.Count -gt 0) {
        'Active function driver'
    } elseif ($installedBindings.Count -gt 0) {
        'Installed extension/configuration'
    } elseif (Test-Path -LiteralPath (Join-Path $env:windir "INF\$($latest.PublishedName)")) {
        'Stored-only'
    } else {
        'Missing from Driver Store'
    }
    $addedPackageRows.Add([pscustomobject]@{
        PublishedName = $latest.PublishedName
        OriginalName = $latest.OriginalName
        ProviderName = $latest.ProviderName
        ClassName = $latest.ClassName
        DriverVersion = $latest.DriverVersion
        Classification = $classification
        BoundDevices = @(
            @($activeBindings | ForEach-Object { $_.DeviceName }) +
            @($installedBindings | ForEach-Object { $_.DeviceName }) |
            Where-Object { $_ } |
            Sort-Object -Unique
        ) -join '; '
        SourcePackages = @($group.Group.SourcePackage | Sort-Object -Unique) -join '; '
    }) | Out-Null
}

$matchedDeviceIds = @{}
foreach ($device in $allMatchDevices) { $matchedDeviceIds[[string]$device.InstanceId.ToUpperInvariant()] = $true }
$activeMatchedRows = @($liveSignedDrivers | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_.DeviceId) -and $matchedDeviceIds.ContainsKey($_.DeviceId.ToUpperInvariant())
} | Sort-Object DeviceClass, DeviceName)

$summary = [pscustomobject]@{
    GeneratedAt = (Get-Date).ToString('o')
    TraceRoot = $resolvedTraceRoot
    ReadableTraceCount = $traceRecords.Count
    LatestPackageTraceCount = $latestTraces.Count
    PackageOutcomes = $packageOutcomeRows.ToArray()
    CurrentActiveDriversForMatchedDevices = $activeMatchedRows
    AuditAddedPackageStatus = $addedPackageRows.ToArray()
    InstalledMatchingDrivers = $installedDrivers
    PnpUtilParsingNote = 'Global installed-driver detection expects the current English pnputil field labels.'
}
$jsonPath = Join-Path $resolvedOutputDirectory 'driver-trace-summary.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Driver Package Trace Summary')
$lines.Add('')
$lines.Add(('Generated: `{0}`' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
$lines.Add(('- Trace root: `{0}`' -f $resolvedTraceRoot))
$lines.Add(('- Readable traces: `{0}`' -f $traceRecords.Count))
$lines.Add(('- Latest package traces: `{0}`' -f $latestTraces.Count))
$lines.Add('')
$lines.Add('## Latest Outcome Per Installer')
$lines.Add('')
$lines.Add('| Package | Matches | Staged | Applied config | Active changes | Evidence verdict |')
$lines.Add('|---|---|---|---|---|---|')
foreach ($row in $packageOutcomeRows) {
    $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f
        (ConvertTo-MarkdownCell $row.Package), $row.LocalMatches, $row.StagedPackages,
        $row.AppliedConfigurations, $row.ActiveBindingChanges, (ConvertTo-MarkdownCell $row.Verdict)))
}
$lines.Add('')
$lines.Add('## Current Active Function Drivers for Previously Matched Devices')
$lines.Add('')
if ($activeMatchedRows.Count -eq 0) {
    $lines.Add('No current active function-driver records were found for previously matched device IDs.')
} else {
    $lines.Add('| Device | Class | Active INF | Provider | Version | Date |')
    $lines.Add('|---|---|---|---|---|---|')
    foreach ($row in $activeMatchedRows) {
        $lines.Add(('| {0} | {1} | `{2}` | {3} | `{4}` | `{5}` |' -f
            (ConvertTo-MarkdownCell $row.DeviceName), (ConvertTo-MarkdownCell $row.DeviceClass),
            (ConvertTo-MarkdownCell $row.InfName), (ConvertTo-MarkdownCell $row.DriverProviderName),
            (ConvertTo-MarkdownCell $row.DriverVersion), (ConvertTo-MarkdownCell $row.DriverDate)))
    }
}
$lines.Add('')
$lines.Add('## Current State of Packages Added During Traces')
$lines.Add('')
if ($addedPackageRows.Count -eq 0) {
    $lines.Add('No newly published packages were recorded.')
} else {
    $lines.Add('| Published INF | Original INF | Class | Version | Current state | Device | Source package |')
    $lines.Add('|---|---|---|---|---|---|---|')
    foreach ($row in $addedPackageRows) {
        $lines.Add(('| `{0}` | `{1}` | {2} | `{3}` | **{4}** | {5} | {6} |' -f
            (ConvertTo-MarkdownCell $row.PublishedName), (ConvertTo-MarkdownCell $row.OriginalName),
            (ConvertTo-MarkdownCell $row.ClassName), (ConvertTo-MarkdownCell $row.DriverVersion),
            (ConvertTo-MarkdownCell $row.Classification), (ConvertTo-MarkdownCell $row.BoundDevices),
            (ConvertTo-MarkdownCell $row.SourcePackages)))
    }
}
$lines.Add('')
$lines.Add('## Guardrails')
$lines.Add('')
$lines.Add('- **Stored-only** means present in the Driver Store but not detected as a current function driver or installed Extension/configuration driver for the traced devices.')
$lines.Add('- The summary is evidence, not a driver recommendation and not a cleanup list.')
$lines.Add('- Global installed-driver detection expects the current English `pnputil` field labels.')

$markdownPath = Join-Path $resolvedOutputDirectory 'driver-trace-summary.md'
Set-Content -LiteralPath $markdownPath -Value $lines -Encoding UTF8

$storedOnlyCount = @($addedPackageRows.ToArray() | Where-Object Classification -eq 'Stored-only').Count
$appliedCount = @($addedPackageRows.ToArray() | Where-Object Classification -in @('Active function driver', 'Installed extension/configuration')).Count
Write-Host ''
Write-Host "Latest installers : $($latestTraces.Count)" -ForegroundColor Green
Write-Host "Applied now       : $appliedCount" -ForegroundColor Green
Write-Host "Stored-only now   : $storedOnlyCount" -ForegroundColor Yellow
Write-Host "Report            : $markdownPath" -ForegroundColor Green
Write-Host "Evidence          : $jsonPath" -ForegroundColor Green

if ($PauseAtEnd) { [void](Read-Host 'Press Enter to close') }
