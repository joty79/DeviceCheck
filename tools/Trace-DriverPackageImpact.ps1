[CmdletBinding(DefaultParameterSetName = 'Trace')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Trace')]
    [string]$InstallerPath,

    [Parameter(Mandatory, ParameterSetName = 'Regenerate')]
    [string]$RegenerateTraceDirectory,

    [Parameter(Mandatory, ParameterSetName = 'PostReboot')]
    [string]$PostRebootTraceDirectory,

    [Parameter(ParameterSetName = 'Trace')]
    [switch]$RunInstaller,

    [Parameter(ParameterSetName = 'Trace')]
    [switch]$PreviewOnly,

    [Parameter(ParameterSetName = 'Trace')]
    [ValidateSet('None', 'Safe', 'Extended')]
    [string]$ExtractionMode = 'Safe',

    [Parameter(ParameterSetName = 'Trace')]
    [switch]$ForceReextract,

    [Parameter(ParameterSetName = 'Trace')]
    [ValidateRange(0, 4)]
    [int]$MaxExtractionDepth = 2,

    [Parameter(ParameterSetName = 'Trace')]
    [switch]$PromptForExtendedExtraction,

    [switch]$PauseAtEnd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$traceHelperRoot = Join-Path $PSScriptRoot 'DriverPackageTrace'
$traceHelperFiles = @(
    (Join-Path $traceHelperRoot 'PackageExtraction.ps1'),
    (Join-Path $traceHelperRoot 'ExtractionGuard.ps1'),
    (Join-Path $traceHelperRoot 'TraceExtractionCoordinator.ps1')
)
foreach ($traceHelperFile in $traceHelperFiles) {
    if (-not (Test-Path -LiteralPath $traceHelperFile)) {
        throw "Missing driver package trace helper: $traceHelperFile"
    }
    . $traceHelperFile
}

function Write-TraceTitle {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

function Write-TraceSection {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Yellow
    Write-Host ('-' * $Text.Length) -ForegroundColor DarkYellow
}

function Get-TraceConsoleWidth {
    $width = 120
    try {
        if ([Console]::WindowWidth -gt 0) { $width = [Console]::WindowWidth }
    } catch {
        $width = 120
    }
    return [Math]::Max(80, [Math]::Min(240, $width - 1))
}

function Split-TraceDisplayText {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width
    )

    if ([string]::IsNullOrEmpty($Text)) { return @('') }
    $safeWidth = [Math]::Max(20, $Width)
    $remaining = $Text
    $lines = New-Object System.Collections.Generic.List[string]
    while ($remaining.Length -gt $safeWidth) {
        $take = $safeWidth
        $searchLength = [Math]::Min($safeWidth, $remaining.Length)
        $breakIndex = $remaining.LastIndexOfAny([char[]]@(' ', '\', '/'), $searchLength - 1, $searchLength)
        if ($breakIndex -ge [Math]::Floor($safeWidth * 0.55)) { $take = $breakIndex + 1 }
        $lines.Add($remaining.Substring(0, $take).TrimEnd()) | Out-Null
        $remaining = $remaining.Substring($take).TrimStart()
    }
    $lines.Add($remaining) | Out-Null
    return $lines.ToArray()
}

function Write-TracePreviewField {
    param(
        [string]$Label,
        [AllowNull()][object]$Value,
        [int]$ConsoleWidth
    )

    $prefix = '  {0,-9}: ' -f $Label
    $continuationPrefix = ' ' * $prefix.Length
    $availableWidth = [Math]::Max(20, $ConsoleWidth - $prefix.Length)
    $displayLines = @(Split-TraceDisplayText -Text ([string]$Value) -Width $availableWidth)
    for ($index = 0; $index -lt $displayLines.Count; $index++) {
        $linePrefix = if ($index -eq 0) { $prefix } else { $continuationPrefix }
        Write-Host ($linePrefix + $displayLines[$index])
    }
}

function Write-TracePreviewMatchList {
    param([object[]]$MatchRows)

    $rows = @($MatchRows | Sort-Object DeviceName, MatchKind, Inf)
    $consoleWidth = Get-TraceConsoleWidth
    Write-Host ("Matched package candidates: {0}" -f $rows.Count) -ForegroundColor Green
    Write-Host ''
    for ($index = 0; $index -lt $rows.Count; $index++) {
        $row = $rows[$index]
        Write-Host ('[{0}] {1}' -f ($index + 1), $row.DeviceName) -ForegroundColor Cyan
        Write-TracePreviewField -Label 'Match' -Value $row.MatchKind -ConsoleWidth $consoleWidth
        Write-TracePreviewField -Label 'ID' -Value $row.MatchedId -ConsoleWidth $consoleWidth
        Write-TracePreviewField -Label 'INF' -Value $row.Inf -ConsoleWidth $consoleWidth
        Write-TracePreviewField -Label 'DriverVer' -Value $row.DriverVer -ConsoleWidth $consoleWidth
        Write-TracePreviewField -Label 'Provider' -Value $row.Provider -ConsoleWidth $consoleWidth
        if ($index -lt ($rows.Count - 1)) { Write-Host '' }
    }
}

function ConvertTo-SafeFileName {
    param([string]$Text)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $chars = foreach ($char in $Text.ToCharArray()) {
        if ($invalid -contains $char) { '_' } else { $char }
    }
    return (-join $chars).Trim()
}

function Get-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SafeModeState {
    $safeBootOptionPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option'
    $safeBootEnvironment = [Environment]::GetEnvironmentVariable('SAFEBOOT_OPTION')
    $registryPresent = Test-Path -LiteralPath $safeBootOptionPath
    return [pscustomobject]@{
        IsLikelySafeMode = [bool]($registryPresent -or -not [string]::IsNullOrWhiteSpace($safeBootEnvironment))
        RegistryOptionPresent = $registryPresent
        EnvironmentOption = $safeBootEnvironment
    }
}

function Get-DriverVerFromInfText {
    param([AllowEmptyString()][string]$Text)
    $match = [regex]::Match($Text, '(?im)^\s*DriverVer\s*=\s*(.+)$')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return ''
}

function ConvertFrom-InfLiteralValue {
    param([AllowEmptyString()][string]$Value)

    $text = $Value.Trim()
    $quotedMatch = [regex]::Match($text, '^"((?:""|[^"])*)"')
    if ($quotedMatch.Success) { return $quotedMatch.Groups[1].Value.Replace('""', '"') }
    return ($text -split ';', 2)[0].Trim()
}

function Get-InfValueFromText {
    param(
        [AllowEmptyString()][string]$Text,
        [string]$Name
    )
    $pattern = '(?im)^\s*' + [regex]::Escape($Name) + '\s*=\s*(.+)$'
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) {
        $value = ConvertFrom-InfLiteralValue $match.Groups[1].Value
        $tokenMatch = [regex]::Match($value, '^%([^%]+)%$')
        if ($tokenMatch.Success) {
            $tokenName = $tokenMatch.Groups[1].Value
            $stringSections = [regex]::Matches($Text, '(?ims)^\s*\[Strings(?:\.[^\]]+)?\]\s*(?<Body>.*?)(?=^\s*\[|\z)')
            foreach ($stringSection in $stringSections) {
                $stringPattern = '(?im)^\s*' + [regex]::Escape($tokenName) + '\s*=\s*(.+)$'
                $stringMatch = [regex]::Match($stringSection.Groups['Body'].Value, $stringPattern)
                if ($stringMatch.Success) { return ConvertFrom-InfLiteralValue $stringMatch.Groups[1].Value }
            }
        }
        return $value
    }
    return ''
}

function Get-PublishedDriverPackages {
    $output = & pnputil.exe /enum-drivers /files 2>&1
    $textLines = @($output | ForEach-Object { [string]$_ })
    $blocks = New-Object System.Collections.Generic.List[object]
    $current = New-Object System.Collections.Generic.List[string]

    foreach ($line in $textLines) {
        if ($line -match '^Published Name:\s+') {
            if ($current.Count -gt 0) {
                $blocks.Add(($current.ToArray() -join "`n"))
                $current.Clear()
            }
        }
        $current.Add($line)
    }
    if ($current.Count -gt 0) {
        $blocks.Add(($current.ToArray() -join "`n"))
    }

    $rows = foreach ($block in $blocks) {
        $published = [regex]::Match($block, '(?m)^Published Name:\s+(.+)$').Groups[1].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($published)) { continue }
        [pscustomobject]@{
            PublishedName = $published
            OriginalName = [regex]::Match($block, '(?m)^Original Name:\s+(.+)$').Groups[1].Value.Trim()
            ProviderName = [regex]::Match($block, '(?m)^Provider Name:\s+(.+)$').Groups[1].Value.Trim()
            ClassName = [regex]::Match($block, '(?m)^Class Name:\s+(.+)$').Groups[1].Value.Trim()
            ClassGuid = [regex]::Match($block, '(?m)^Class GUID:\s+(.+)$').Groups[1].Value.Trim()
            ExtensionId = [regex]::Match($block, '(?m)^Extension ID:\s+(.+)$').Groups[1].Value.Trim()
            DriverVersion = [regex]::Match($block, '(?m)^Driver Version:\s+(.+)$').Groups[1].Value.Trim()
            SignerName = [regex]::Match($block, '(?m)^Signer Name:\s+(.+)$').Groups[1].Value.Trim()
            CatalogFile = [regex]::Match($block, '(?m)^Catalog File:\s+(.+)$').Groups[1].Value.Trim()
            RawBlock = $block
        }
    }

    return @($rows)
}

function Get-InfInventory {
    $infRoot = Join-Path $env:WINDIR 'INF'
    $rows = Get-ChildItem -LiteralPath $infRoot -Filter 'oem*.inf' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $text = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Name = $_.Name
            Path = $_.FullName
            Length = $_.Length
            LastWriteTime = $_.LastWriteTime.ToString('o')
            Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            DriverVer = Get-DriverVerFromInfText -Text $text
            Provider = Get-InfValueFromText -Text $text -Name 'Provider'
            Class = Get-InfValueFromText -Text $text -Name 'Class'
            ClassGuid = Get-InfValueFromText -Text $text -Name 'ClassGuid'
            CatalogFile = Get-InfValueFromText -Text $text -Name 'CatalogFile'
        }
    }
    return @($rows)
}

function Get-DriverStoreInventory {
    $driverStoreRoot = Join-Path $env:WINDIR 'System32\DriverStore\FileRepository'
    $rows = Get-ChildItem -LiteralPath $driverStoreRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Name
            FullName = $_.FullName
            LastWriteTime = $_.LastWriteTime.ToString('o')
        }
    }
    return @($rows)
}

function Get-PnpDeviceSnapshot {
    $rows = Get-PnpDevice -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            InstanceId = $_.InstanceId
            FriendlyName = $_.FriendlyName
            Class = $_.Class
            Status = $_.Status
            Problem = $_.Problem
            ConfigManagerErrorCode = $_.ConfigManagerErrorCode
        }
    }
    return @($rows)
}

function Get-PnpDeviceIdEvidence {
    $output = @(pnputil.exe /enum-devices /connected /ids 2>&1 | ForEach-Object { [string]$_ })
    $rows = @()
    $current = $null
    $currentList = ''

    foreach ($line in $output) {
        $instanceMatch = [regex]::Match($line, '^Instance ID:\s+(.+)$')
        if ($instanceMatch.Success) {
            if ($null -ne $current) { $rows += [pscustomobject]$current }
            $current = [ordered]@{
                InstanceId = $instanceMatch.Groups[1].Value.Trim()
                FriendlyName = ''
                Class = ''
                HardwareIds = @()
                CompatibleIds = @()
            }
            $currentList = ''
            continue
        }

        if ($null -eq $current) { continue }

        $descriptionMatch = [regex]::Match($line, '^Device Description:\s+(.+)$')
        if ($descriptionMatch.Success) {
            $current['FriendlyName'] = $descriptionMatch.Groups[1].Value.Trim()
            $currentList = ''
            continue
        }

        $classMatch = [regex]::Match($line, '^Class Name:\s+(.+)$')
        if ($classMatch.Success) {
            $current['Class'] = $classMatch.Groups[1].Value.Trim()
            $currentList = ''
            continue
        }

        $hardwareMatch = [regex]::Match($line, '^Hardware IDs:\s*(.*)$')
        if ($hardwareMatch.Success) {
            $currentList = 'HardwareIds'
            $value = $hardwareMatch.Groups[1].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) { $current['HardwareIds'] = @($current['HardwareIds'] + $value) }
            continue
        }

        $compatibleMatch = [regex]::Match($line, '^Compatible IDs:\s*(.*)$')
        if ($compatibleMatch.Success) {
            $currentList = 'CompatibleIds'
            $value = $compatibleMatch.Groups[1].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) { $current['CompatibleIds'] = @($current['CompatibleIds'] + $value) }
            continue
        }

        if ($line -match '^[A-Za-z ]+:\s*') {
            $currentList = ''
            continue
        }

        $continuationMatch = [regex]::Match($line, '^\s+(.+)$')
        if ($continuationMatch.Success -and -not [string]::IsNullOrWhiteSpace($currentList)) {
            $value = $continuationMatch.Groups[1].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                if ($currentList -eq 'HardwareIds') { $current['HardwareIds'] = @($current['HardwareIds'] + $value) }
                if ($currentList -eq 'CompatibleIds') { $current['CompatibleIds'] = @($current['CompatibleIds'] + $value) }
            }
        }
    }

    if ($null -ne $current) { $rows += [pscustomobject]$current }

    return @($rows | ForEach-Object {
        [pscustomobject]@{
            InstanceId = $_.InstanceId
            FriendlyName = $_.FriendlyName
            Class = $_.Class
            HardwareIds = @($_.HardwareIds)
            CompatibleIds = @($_.CompatibleIds)
        }
    })
}

function Get-SignedDriverSnapshot {
    $rows = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            DeviceName = $_.DeviceName
            DeviceClass = $_.DeviceClass
            Manufacturer = $_.Manufacturer
            DriverProviderName = $_.DriverProviderName
            DriverVersion = $_.DriverVersion
            DriverDate = if ($_.DriverDate) { ([datetime]$_.DriverDate).ToString('o') } else { '' }
            InfName = $_.InfName
            HardwareID = $_.HardwareID
            DeviceID = $_.DeviceID
            IsSigned = $_.IsSigned
            Signer = $_.Signer
        }
    }
    return @($rows)
}

function Get-SystemDriverSnapshot {
    $rows = Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Name
            DisplayName = $_.DisplayName
            State = $_.State
            Status = $_.Status
            StartMode = $_.StartMode
            PathName = $_.PathName
            ServiceType = $_.ServiceType
        }
    }
    return @($rows)
}

function Get-SetupApiMarker {
    $path = Join-Path $env:WINDIR 'INF\setupapi.dev.log'
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ Path = $path; Exists = $false; Length = 0; LastWriteTime = '' }
    }
    $item = Get-Item -LiteralPath $path
    return [pscustomobject]@{
        Path = $item.FullName
        Exists = $true
        Length = $item.Length
        LastWriteTime = $item.LastWriteTime.ToString('o')
    }
}

function Get-SetupApiDeltaText {
    param($BeforeMarker)

    if (-not $BeforeMarker.Exists) { return '' }
    if (-not (Test-Path -LiteralPath $BeforeMarker.Path)) { return '' }

    $item = Get-Item -LiteralPath $BeforeMarker.Path
    if ($item.Length -le [int64]$BeforeMarker.Length) { return '' }

    $stream = [System.IO.File]::Open($item.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        [void]$stream.Seek([int64]$BeforeMarker.Length, [System.IO.SeekOrigin]::Begin)
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::Default, $true)
        try {
            return $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)][string]$Path
    )
    $Data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-DriverTraceSnapshot {
    param(
        [string]$Name,
        [string]$OutputDirectory
    )

    Write-TraceSection "Collecting $Name snapshot"
    $setupMarker = Get-SetupApiMarker
    $snapshot = [pscustomobject]@{
        Name = $Name
        CapturedAt = (Get-Date).ToString('o')
        ComputerName = $env:COMPUTERNAME
        UserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        IsAdministrator = Get-IsAdministrator
        SafeMode = Get-SafeModeState
        SetupApiMarker = $setupMarker
        PublishedDrivers = @(Get-PublishedDriverPackages)
        InfInventory = @(Get-InfInventory)
        DriverStore = @(Get-DriverStoreInventory)
        PnpDevices = @(Get-PnpDeviceSnapshot)
        SignedDrivers = @(Get-SignedDriverSnapshot)
        SystemDrivers = @(Get-SystemDriverSnapshot)
    }

    $path = Join-Path $OutputDirectory "$Name.snapshot.json"
    Save-JsonFile -Data $snapshot -Path $path
    Write-Host "Saved $Name snapshot: $path" -ForegroundColor DarkGray
    return $snapshot
}

function Find-ExistingExtractedPackageRoot {
    param([string]$PackagePath)

    $item = Get-Item -LiteralPath $PackagePath
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
    $candidates = @(
        (Join-Path $item.DirectoryName "extracted\$baseName"),
        (Join-Path (Split-Path -Parent $item.DirectoryName) "extracted\$baseName"),
        (Join-Path $item.DirectoryName $baseName)
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return ''
}

function Get-MsiPropertyValue {
    param(
        [string]$MsiPath,
        [string]$PropertyName
    )

    $installer = $null
    $database = $null
    $view = $null
    $record = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.OpenDatabase($MsiPath, 0)
        $escapedPropertyName = $PropertyName.Replace("'", "''")
        $view = $database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$escapedPropertyName'")
        $view.Execute()
        $record = $view.Fetch()
        if ($null -ne $record) { return [string]$record.StringData(1) }
    } catch {
        return ''
    } finally {
        if ($null -ne $record) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($record) }
        if ($null -ne $view) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view) }
        if ($null -ne $database) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($database) }
        if ($null -ne $installer) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer) }
    }

    return ''
}

function Get-PayloadFileSummary {
    param([string]$ExtractedRoot)

    if ([string]::IsNullOrWhiteSpace($ExtractedRoot) -or -not (Test-Path -LiteralPath $ExtractedRoot)) {
        return @()
    }

    $files = @(Get-ChildItem -LiteralPath $ExtractedRoot -Recurse -File -ErrorAction SilentlyContinue)
    $rows = foreach ($file in $files) {
        $extension = $file.Extension.ToLowerInvariant()
        $type = switch ($extension) {
            '.inf' { 'Driver INF' }
            '.cat' { 'Catalog' }
            '.sys' { 'Kernel driver binary' }
            '.dll' { 'Library' }
            '.exe' { 'Executable utility' }
            '.msi' { 'MSI installer' }
            '.mst' { 'MSI transform' }
            '.cab' { 'Cabinet archive' }
            '.xml' { 'Configuration' }
            '.json' { 'Configuration' }
            default { if ([string]::IsNullOrWhiteSpace($extension)) { 'File' } else { $extension.TrimStart('.').ToUpperInvariant() + ' file' } }
        }

        $msiProductName = ''
        $msiProductVersion = ''
        $msiManufacturer = ''
        $msiProductCode = ''
        $productName = ''
        $productVersion = ''
        $manufacturer = ''
        $fileDescription = ''
        if ($extension -eq '.msi') {
            $msiProductName = Get-MsiPropertyValue -MsiPath $file.FullName -PropertyName 'ProductName'
            $msiProductVersion = Get-MsiPropertyValue -MsiPath $file.FullName -PropertyName 'ProductVersion'
            $msiManufacturer = Get-MsiPropertyValue -MsiPath $file.FullName -PropertyName 'Manufacturer'
            $msiProductCode = Get-MsiPropertyValue -MsiPath $file.FullName -PropertyName 'ProductCode'
            $productName = $msiProductName
            $productVersion = $msiProductVersion
            $manufacturer = $msiManufacturer
        } elseif ($extension -eq '.exe') {
            $productName = [string]$file.VersionInfo.ProductName
            $productVersion = [string]$file.VersionInfo.ProductVersion
            $manufacturer = [string]$file.VersionInfo.CompanyName
            $fileDescription = [string]$file.VersionInfo.FileDescription
        }

        [pscustomobject]@{
            RelativePath = $file.FullName.Substring($ExtractedRoot.Length).TrimStart('\')
            Name = $file.Name
            Extension = $extension
            Type = $type
            Length = $file.Length
            MsiProductName = $msiProductName
            MsiProductVersion = $msiProductVersion
            MsiManufacturer = $msiManufacturer
            MsiProductCode = $msiProductCode
            ProductName = $productName
            ProductVersion = $productVersion
            Manufacturer = $manufacturer
            FileDescription = $fileDescription
        }
    }

    return @($rows)
}

function Get-PayloadKind {
    param(
        [object[]]$PayloadFiles,
        [int]$InfCount
    )

    if ($InfCount -gt 0) { return 'Driver INF payload' }
    if (@($PayloadFiles | Where-Object { $_.Extension -eq '.msi' }).Count -gt 0) { return 'MSI provisioning/application payload' }
    $nestedInstallerExecutables = @($PayloadFiles | Where-Object {
        $_.Extension -eq '.exe' -and
        $_.Name -notmatch '^(?i:vc_redist|vcredist)' -and
        ('{0} {1} {2} {3}' -f $_.Name,
            (Get-TraceObjectValue $_ 'ProductName'),
            (Get-TraceObjectValue $_ 'FileDescription'),
            $_.RelativePath) -match '(?i)(setup|install|driver|chipset)'
    })
    if ($nestedInstallerExecutables.Count -gt 0) { return 'Nested installer/bootstrapper payload' }
    if (@($PayloadFiles | Where-Object { $_.Extension -eq '.exe' }).Count -gt 0) { return 'Executable utility payload' }
    if (@($PayloadFiles).Count -gt 0) { return 'Non-driver payload' }
    return 'No extracted payload'
}

function Get-InfSupportedDeviceIds {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($Text -split "`r?`n")) {
        $textLine = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($textLine) -or $textLine.StartsWith(';') -or $textLine.StartsWith('[')) { continue }
        $equalsIndex = $textLine.IndexOf('=')
        if ($equalsIndex -lt 0) { continue }

        $fields = @($textLine.Substring($equalsIndex + 1).Split(','))
        if ($fields.Count -lt 2) { continue }
        foreach ($field in @($fields | Select-Object -Skip 1)) {
            $candidate = ([string]$field).Trim().Trim('"')
            if ($candidate -match '^(?i)(PCI|USB|HID|ACPI|HDAUDIO|SWC|ROOT|BTHENUM|SCSI|IDE|SD|UEFI|DISPLAY|MONITOR)\\[^\s,;]+$') {
                $ids.Add($candidate.ToUpperInvariant()) | Out-Null
            }
        }
    }

    return @($ids | Sort-Object -Unique)
}

function Get-PciBaseIds {
    param([string[]]$Ids)

    $rows = foreach ($id in $Ids) {
        $match = [regex]::Match($id, '^(PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4})', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) { $match.Groups[1].Value.ToUpperInvariant() }
    }
    return @($rows | Sort-Object -Unique)
}

function Test-IsUsefulDeviceIdForPreview {
    param([AllowEmptyString()][string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    $text = $Id.Trim()

    # Vendor-only or class-only IDs are too broad for package preview matching.
    if ($text -match '^(?i)PCI\\VEN_[0-9A-F]{4}$') { return $false }
    if ($text -match '^(?i)PCI\\CC_[0-9A-F]+$') { return $false }
    if ($text -match '^(?i)USB\\Class_[0-9A-F]{2}(&SubClass_[0-9A-F]{2})?(&Prot_[0-9A-F]{2})?$') { return $false }
    if ($text -match '^(?i)USB\\ROOT_HUB(20|30)?$') { return $false }
    if ($text -match '^(?i)HDAUDIO\\FUNC_[0-9A-F]{2}$') { return $false }
    if ($text -match '^(?i)SensorGroup$') { return $false }

    return $true
}

function New-PackagePreview {
    param(
        [string]$PackagePath,
        [string]$OutputDirectory,
        [AllowEmptyString()][string]$ExtractedRootOverride = '',
        [AllowNull()][object]$ExtractionManifest = $null
    )

    Write-TraceSection 'Package preview'
    $installer = Get-Item -LiteralPath $PackagePath
    $extractedRoot = ''
    if (-not [string]::IsNullOrWhiteSpace($ExtractedRootOverride) -and (Test-Path -LiteralPath $ExtractedRootOverride)) {
        $extractedRoot = (Resolve-Path -LiteralPath $ExtractedRootOverride).Path
    } else {
        $extractedRoot = Find-ExistingExtractedPackageRoot -PackagePath $installer.FullName
    }
    $deviceEvidence = @(Get-PnpDeviceIdEvidence)
    $infRows = @()
    $payloadFileCount = 0
    $payloadFiles = @()
    $matchRows = New-Object System.Collections.Generic.List[object]

    if (-not [string]::IsNullOrWhiteSpace($extractedRoot)) {
        Write-Host "Using existing extracted payload: $extractedRoot" -ForegroundColor Green
        $payloadFiles = @(Get-PayloadFileSummary -ExtractedRoot $extractedRoot)
        $payloadFileCount = $payloadFiles.Count
        $infFiles = @(Get-ChildItem -LiteralPath $extractedRoot -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue)
        if ($infFiles.Count -eq 0) {
            $payloadKind = Get-PayloadKind -PayloadFiles $payloadFiles -InfCount 0
            Write-Host "Extracted payload exists, but it contains no INF files. Payload kind: $payloadKind." -ForegroundColor Yellow
            if ($payloadKind -eq 'Nested installer/bootstrapper payload') {
                Write-Host 'The driver INFs may be unpacked only when the nested installer runs; before/after and SetupAPI evidence remain authoritative.' -ForegroundColor Yellow
            }
        }

        $infRows = @($infFiles | ForEach-Object {
            $text = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
            [pscustomobject]@{
                FileName = $_.Name
                Path = $_.FullName
                RelativePath = $_.FullName.Substring($extractedRoot.Length).TrimStart('\')
                DriverVer = Get-DriverVerFromInfText -Text $text
                Provider = Get-InfValueFromText -Text $text -Name 'Provider'
                Class = Get-InfValueFromText -Text $text -Name 'Class'
                ClassGuid = Get-InfValueFromText -Text $text -Name 'ClassGuid'
                CatalogFile = Get-InfValueFromText -Text $text -Name 'CatalogFile'
                SupportedDeviceIds = @(Get-InfSupportedDeviceIds -Text $text)
                Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                Text = $text
            }
        })

        foreach ($inf in $infRows) {
            foreach ($device in $deviceEvidence) {
                $hardwareIds = @($device.HardwareIds)
                $compatibleIds = @($device.CompatibleIds)
                $pciBaseIds = @(Get-PciBaseIds -Ids @($hardwareIds + $compatibleIds))
                $matchKind = ''
                $matchedId = ''

                foreach ($id in $hardwareIds) {
                    if (-not (Test-IsUsefulDeviceIdForPreview -Id $id)) { continue }
                    if ($inf.Text.IndexOf($id, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $matchKind = 'ExactHardwareId'
                        $matchedId = $id
                        break
                    }
                }

                if ([string]::IsNullOrWhiteSpace($matchKind)) {
                    foreach ($id in $compatibleIds) {
                        if (-not (Test-IsUsefulDeviceIdForPreview -Id $id)) { continue }
                        if ($inf.Text.IndexOf($id, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                            $matchKind = 'CompatibleId'
                            $matchedId = $id
                            break
                        }
                    }
                }

                if ([string]::IsNullOrWhiteSpace($matchKind)) {
                    foreach ($id in $pciBaseIds) {
                        if ($inf.Text.IndexOf($id, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                            $matchKind = 'PciVenDevFallback'
                            $matchedId = $id
                            break
                        }
                    }
                }

                if (-not [string]::IsNullOrWhiteSpace($matchKind)) {
                    $matchRows.Add([pscustomobject]@{
                        DeviceName = $device.FriendlyName
                        DeviceClass = $device.Class
                        InstanceId = $device.InstanceId
                        MatchKind = $matchKind
                        MatchedId = $matchedId
                        Inf = $inf.RelativePath
                        InfPath = $inf.Path
                        DriverVer = $inf.DriverVer
                        Provider = $inf.Provider
                        Class = $inf.Class
                        CatalogFile = $inf.CatalogFile
                        InfHash = $inf.Hash
                    })
                }
            }
        }
    } else {
        Write-Host 'No existing extracted payload was found beside this installer.' -ForegroundColor Yellow
    }

    $infFileSummaries = foreach ($inf in @($infRows)) {
        [pscustomobject]@{
            FileName = $inf.FileName
            RelativePath = $inf.RelativePath
            DriverVer = $inf.DriverVer
            Provider = $inf.Provider
            Class = $inf.Class
            ClassGuid = $inf.ClassGuid
            CatalogFile = $inf.CatalogFile
            SupportedDeviceIds = @($inf.SupportedDeviceIds)
            Hash = $inf.Hash
        }
    }

    $preview = [pscustomobject]@{
        InstallerPath = $installer.FullName
        InstallerName = $installer.Name
        InstallerLength = $installer.Length
        InstallerHash = (Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256).Hash
        ExistingExtractedRoot = $extractedRoot
        PayloadFileCount = $payloadFileCount
        PayloadKind = Get-PayloadKind -PayloadFiles $payloadFiles -InfCount @($infRows).Count
        PayloadFiles = @($payloadFiles)
        InfCount = @($infRows).Count
        MatchCount = $matchRows.Count
        InfFiles = @($infFileSummaries)
        Matches = @($matchRows.ToArray())
        Extraction = $ExtractionManifest
    }

    $path = Join-Path $OutputDirectory 'package-preview.json'
    Save-JsonFile -Data $preview -Path $path

    if ($matchRows.Count -gt 0) {
        Write-TracePreviewMatchList -MatchRows $matchRows.ToArray()
    } else {
        Write-Host 'No local device ID matches found in extracted INF payload.' -ForegroundColor Yellow
    }

    return $preview
}

function Compare-ByKey {
    param(
        [object[]]$Before,
        [object[]]$After,
        [string]$Key
    )

    $beforeMap = @{}
    foreach ($item in @($Before)) {
        $value = [string]$item.$Key
        if (-not [string]::IsNullOrWhiteSpace($value)) { $beforeMap[$value] = $item }
    }

    $afterMap = @{}
    foreach ($item in @($After)) {
        $value = [string]$item.$Key
        if (-not [string]::IsNullOrWhiteSpace($value)) { $afterMap[$value] = $item }
    }

    $added = foreach ($keyValue in $afterMap.Keys) {
        if (-not $beforeMap.ContainsKey($keyValue)) { $afterMap[$keyValue] }
    }
    $removed = foreach ($keyValue in $beforeMap.Keys) {
        if (-not $afterMap.ContainsKey($keyValue)) { $beforeMap[$keyValue] }
    }

    return [pscustomobject]@{
        Added = @($added)
        Removed = @($removed)
    }
}

function Compare-TraceSnapshots {
    param(
        $Before,
        $After,
        [string]$SetupApiDelta
    )

    $published = Compare-ByKey -Before $Before.PublishedDrivers -After $After.PublishedDrivers -Key 'PublishedName'
    $inf = Compare-ByKey -Before $Before.InfInventory -After $After.InfInventory -Key 'Name'
    $store = Compare-ByKey -Before $Before.DriverStore -After $After.DriverStore -Key 'Name'
    $services = Compare-ByKey -Before $Before.SystemDrivers -After $After.SystemDrivers -Key 'Name'
    $devices = Compare-ByKey -Before $Before.PnpDevices -After $After.PnpDevices -Key 'InstanceId'
    $signed = Compare-ByKey -Before $Before.SignedDrivers -After $After.SignedDrivers -Key 'DeviceID'

    $beforeSigned = @{}
    foreach ($driver in @($Before.SignedDrivers)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$driver.DeviceID)) { $beforeSigned[[string]$driver.DeviceID] = $driver }
    }

    $changedSigned = foreach ($driver in @($After.SignedDrivers)) {
        $key = [string]$driver.DeviceID
        if ([string]::IsNullOrWhiteSpace($key) -or -not $beforeSigned.ContainsKey($key)) { continue }
        $old = $beforeSigned[$key]
        if ($old.DriverVersion -ne $driver.DriverVersion -or $old.DriverDate -ne $driver.DriverDate -or $old.InfName -ne $driver.InfName -or $old.DriverProviderName -ne $driver.DriverProviderName) {
            [pscustomobject]@{
                DeviceName = $driver.DeviceName
                DeviceID = $key
                BeforeInf = $old.InfName
                AfterInf = $driver.InfName
                BeforeVersion = $old.DriverVersion
                AfterVersion = $driver.DriverVersion
                BeforeDate = $old.DriverDate
                AfterDate = $driver.DriverDate
                BeforeProvider = $old.DriverProviderName
                AfterProvider = $driver.DriverProviderName
            }
        }
    }

    return [pscustomobject]@{
        GeneratedAt = (Get-Date).ToString('o')
        AddedPublishedDrivers = @($published.Added)
        RemovedPublishedDrivers = @($published.Removed)
        AddedInfFiles = @($inf.Added)
        RemovedInfFiles = @($inf.Removed)
        AddedDriverStoreFolders = @($store.Added)
        RemovedDriverStoreFolders = @($store.Removed)
        AddedSystemDrivers = @($services.Added)
        RemovedSystemDrivers = @($services.Removed)
        AddedPnpDevices = @($devices.Added)
        RemovedPnpDevices = @($devices.Removed)
        AddedSignedDrivers = @($signed.Added)
        RemovedSignedDrivers = @($signed.Removed)
        ChangedSignedDrivers = @($changedSigned)
        SetupApiDeltaLength = $SetupApiDelta.Length
        SetupApiInterestingLines = @($SetupApiDelta -split "`r?`n" | Where-Object { $_ -match 'inf:|dvi:|sto:|idb:|sig:|dvs:|utl:|Driver Node|Driver Extension Node|Driver Version|Driver INF|Extension ID|Driver Rank|Signer Score|Configuration|Published|Installing driver|Copying|Device install|>>>|<<<' })
        SetupApiDriverNodes = @(Get-SetupApiDriverNodeRowsFromText -SetupApiText $SetupApiDelta -PublishedDrivers $After.PublishedDrivers)
        SetupApiDeviceInstallActions = @(Get-SetupApiDeviceInstallRowsFromText -SetupApiText $SetupApiDelta -PublishedDrivers $After.PublishedDrivers -AddedPublishedDrivers $published.Added)
    }
}

function ConvertTo-MarkdownCell {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ').Trim()
}

function Normalize-InfName {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim().ToLowerInvariant()
}

function Normalize-DriverVersionNumber {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    $text = ([string]$Value).Trim()
    $matchResult = [regex]::Match($text, '^\d{1,2}/\d{1,2}/\d{4}[,\s]+(.+)$')
    if ($matchResult.Success) { return $matchResult.Groups[1].Value.Trim() }
    return $text
}

function Split-DriverVersionText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return [pscustomobject]@{ DateText = ''; VersionText = '' }
    }

    $text = ([string]$Value).Trim()
    $matchResult = [regex]::Match($text, '^(\d{1,2}/\d{1,2}/\d{4})[,\s]+(.+)$')
    if ($matchResult.Success) {
        return [pscustomobject]@{
            DateText = $matchResult.Groups[1].Value.Trim()
            VersionText = $matchResult.Groups[2].Value.Trim()
        }
    }

    return [pscustomobject]@{ DateText = ''; VersionText = $text }
}

function ConvertTo-DriverDateObject {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $parsedDate = [datetime]::MinValue
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $styles = [Globalization.DateTimeStyles]::AssumeLocal
    if ([datetime]::TryParse($text, $culture, $styles, [ref]$parsedDate)) {
        return $parsedDate.Date
    }

    return $null
}

function Format-DriverDate {
    param([AllowNull()][object]$Value)

    $dateObject = ConvertTo-DriverDateObject $Value
    if ($null -eq $dateObject) { return '' }
    return $dateObject.ToString('yyyy-MM-dd')
}

function Get-TraceObjectValue {
    param(
        [AllowNull()][object]$InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject) { return '' }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return '' }
    return $property.Value
}

function Get-InstallerExitCodeInterpretation {
    param([AllowNull()][object]$ExitCode)

    $exitCodeNumber = 0
    if ($null -eq $ExitCode -or
        [string]::IsNullOrWhiteSpace([string]$ExitCode) -or
        -not [int]::TryParse([string]$ExitCode, [ref]$exitCodeNumber)) {
        return 'Not recorded'
    }

    switch ($exitCodeNumber) {
        0 { return 'Success' }
        259 { return 'Ambiguous wrapper/child-process result; confirm that any child installer UI completed and rely on the captured evidence' }
        1223 { return 'Cancelled by the user' }
        1641 { return 'Success; restart initiated' }
        3010 { return 'Success; restart required' }
        default { return 'Non-zero result; inspect the installer output and captured driver evidence' }
    }
}

function New-PublishedDriverLookup {
    param([object[]]$PublishedDrivers)

    $lookup = @{}
    foreach ($driver in @($PublishedDrivers)) {
        $publishedName = Normalize-InfName (Get-TraceObjectValue -InputObject $driver -Name 'PublishedName')
        if (-not [string]::IsNullOrWhiteSpace($publishedName)) {
            $lookup[$publishedName] = $driver
        }
    }
    return $lookup
}

function Add-SetupApiDriverNodeRow {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [AllowNull()][object]$CurrentNode,
        [hashtable]$PublishedLookup
    )

    if ($null -eq $CurrentNode) { return }
    $publishedName = Normalize-InfName $CurrentNode['PublishedName']
    if ([string]::IsNullOrWhiteSpace($publishedName)) { return }

    if ($PublishedLookup.ContainsKey($publishedName)) {
        $publishedPackage = $PublishedLookup[$publishedName]
        $CurrentNode['OriginalName'] = Get-TraceObjectValue -InputObject $publishedPackage -Name 'OriginalName'
        $CurrentNode['ProviderName'] = Get-TraceObjectValue -InputObject $publishedPackage -Name 'ProviderName'
        $CurrentNode['ClassName'] = Get-TraceObjectValue -InputObject $publishedPackage -Name 'ClassName'
        $packageExtensionId = Get-TraceObjectValue -InputObject $publishedPackage -Name 'ExtensionId'
        if ([string]::IsNullOrWhiteSpace([string]$CurrentNode['ExtensionId']) -and -not [string]::IsNullOrWhiteSpace([string]$packageExtensionId)) {
            $CurrentNode['ExtensionId'] = $packageExtensionId
        }
    }

    $Rows.Add([pscustomobject]$CurrentNode) | Out-Null
}

function Get-SetupApiUpdateDeviceIdFromLine {
    param([AllowEmptyString()][string]$Text)

    $matchResult = [regex]::Match($Text, 'Driver Setup Update Device:\s+(.+)\}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?$')
    if ($matchResult.Success) { return $matchResult.Groups[1].Value.Trim() }
    return ''
}

function Add-SetupApiDeviceInstallRows {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [AllowNull()][object]$CurrentInstall,
        [hashtable]$PublishedLookup,
        [hashtable]$AddedPublishedLookup
    )

    if ($null -eq $CurrentInstall) { return }
    $actions = New-Object System.Collections.Generic.List[string]
    $actions.Add('Configured') | Out-Null
    if ([bool]$CurrentInstall['RemovedDeviceTree']) { $actions.Add('Device subtree removed') | Out-Null }
    if ([bool]$CurrentInstall['RestartedDevice']) { $actions.Add('Device restarted') | Out-Null }

    $configurations = [System.Collections.Generic.List[object]]$CurrentInstall['Configurations']
    foreach ($configuration in $configurations.ToArray()) {
        $publishedName = Normalize-InfName (Get-TraceObjectValue -InputObject $configuration -Name 'PublishedName')
        if ([string]::IsNullOrWhiteSpace($publishedName)) { continue }
        $originalName = ''
        $className = ''
        if ($PublishedLookup.ContainsKey($publishedName)) {
            $publishedPackage = $PublishedLookup[$publishedName]
            $originalName = [string](Get-TraceObjectValue -InputObject $publishedPackage -Name 'OriginalName')
            $className = [string](Get-TraceObjectValue -InputObject $publishedPackage -Name 'ClassName')
        }
        $Rows.Add([pscustomobject]@{
            DeviceID = [string]$CurrentInstall['DeviceID']
            PublishedName = $publishedName
            OriginalName = $originalName
            ClassName = $className
            Configuration = Get-TraceObjectValue -InputObject $configuration -Name 'Configuration'
            IsNewlyStaged = [bool]$AddedPublishedLookup.ContainsKey($publishedName)
            Actions = $actions.ToArray() -join '; '
            ExitStatus = [string]$CurrentInstall['ExitStatus']
        }) | Out-Null
    }
}

function Get-SetupApiDeviceInstallRowsFromText {
    param(
        [AllowEmptyString()][string]$SetupApiText,
        [object[]]$PublishedDrivers = @(),
        [object[]]$AddedPublishedDrivers = @()
    )

    if ([string]::IsNullOrWhiteSpace($SetupApiText)) { return @() }

    $publishedLookup = New-PublishedDriverLookup -PublishedDrivers $PublishedDrivers
    $addedPublishedLookup = @{}
    foreach ($driver in @($AddedPublishedDrivers)) {
        $publishedName = Normalize-InfName (Get-TraceObjectValue -InputObject $driver -Name 'PublishedName')
        if (-not [string]::IsNullOrWhiteSpace($publishedName)) { $addedPublishedLookup[$publishedName] = $true }
    }

    $rows = New-Object System.Collections.Generic.List[object]
    $currentDeviceId = ''
    $currentInstall = $null
    foreach ($line in @($SetupApiText -split "`r?`n")) {
        $text = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $updateDeviceId = Get-SetupApiUpdateDeviceIdFromLine -Text $text
        if (-not [string]::IsNullOrWhiteSpace($updateDeviceId)) { $currentDeviceId = $updateDeviceId }

        if ($text -match 'Install Device:\s+Configuring device\.') {
            Add-SetupApiDeviceInstallRows -Rows $rows -CurrentInstall $currentInstall -PublishedLookup $publishedLookup -AddedPublishedLookup $addedPublishedLookup
            $currentInstall = [ordered]@{
                DeviceID = $currentDeviceId
                Configurations = New-Object System.Collections.Generic.List[object]
                RemovedDeviceTree = $false
                RestartedDevice = $false
                ExitStatus = ''
            }
            continue
        }

        if ($null -eq $currentInstall) { continue }

        $configurationMatch = [regex]::Match($text, 'Configuration:\s+([^:]+\.inf):(.+)$')
        if ($configurationMatch.Success) {
            $currentInstall['Configurations'].Add([pscustomobject]@{
                PublishedName = $configurationMatch.Groups[1].Value.Trim()
                Configuration = $configurationMatch.Groups[2].Value.Trim()
            }) | Out-Null
            continue
        }

        $removeMatch = [regex]::Match($text, "Install Device:\s+Removing device '(.+)' and sub-tree")
        if ($removeMatch.Success) {
            $currentInstall['DeviceID'] = $removeMatch.Groups[1].Value.Trim()
            $currentInstall['RemovedDeviceTree'] = $true
            continue
        }

        if ($text -match 'Install Device:\s+Restarting device(?: completed)?\.') {
            $currentInstall['RestartedDevice'] = $true
            continue
        }

        $exitMatch = [regex]::Match($text, 'Plug and Play Service:\s+Device Install exit\(([^)]+)\)')
        if ($exitMatch.Success) {
            $currentInstall['ExitStatus'] = $exitMatch.Groups[1].Value.Trim()
            Add-SetupApiDeviceInstallRows -Rows $rows -CurrentInstall $currentInstall -PublishedLookup $publishedLookup -AddedPublishedLookup $addedPublishedLookup
            $currentInstall = $null
            continue
        }

        if ($text -match '^<<<\s+Section end') {
            Add-SetupApiDeviceInstallRows -Rows $rows -CurrentInstall $currentInstall -PublishedLookup $publishedLookup -AddedPublishedLookup $addedPublishedLookup
            $currentInstall = $null
        }
    }

    Add-SetupApiDeviceInstallRows -Rows $rows -CurrentInstall $currentInstall -PublishedLookup $publishedLookup -AddedPublishedLookup $addedPublishedLookup
    $seen = @{}
    return @($rows.ToArray() | Where-Object {
        $key = @($_.DeviceID, $_.PublishedName, $_.Configuration, $_.Actions, $_.ExitStatus) -join '|'
        if ($seen.ContainsKey($key)) { return $false }
        $seen[$key] = $true
        return $true
    })
}

function Get-SetupApiDriverNodeRowsFromText {
    param(
        [AllowEmptyString()][string]$SetupApiText,
        [object[]]$PublishedDrivers = @()
    )

    if ([string]::IsNullOrWhiteSpace($SetupApiText)) { return @() }

    $publishedLookup = New-PublishedDriverLookup -PublishedDrivers $PublishedDrivers
    $rows = New-Object System.Collections.Generic.List[object]
    $currentDeviceId = ''
    $currentNode = $null

    foreach ($line in @($SetupApiText -split "`r?`n")) {
        $text = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        if ($text -match '^>>>' -or $text -match '^<<<\s+Section end' -or $text -match '\{Select Drivers - exit' -or $text -match '\{Driver Setup Update Device - exit') {
            Add-SetupApiDriverNodeRow -Rows $rows -CurrentNode $currentNode -PublishedLookup $publishedLookup
            $currentNode = $null
            if ($text -match '^>>>|^<<<\s+Section end') { $currentDeviceId = '' }
            continue
        }

        $updateDeviceId = Get-SetupApiUpdateDeviceIdFromLine -Text $text
        if (-not [string]::IsNullOrWhiteSpace($updateDeviceId)) {
            Add-SetupApiDriverNodeRow -Rows $rows -CurrentNode $currentNode -PublishedLookup $publishedLookup
            $currentNode = $null
            $currentDeviceId = $updateDeviceId
            continue
        }

        $matchResult = [regex]::Match($text, 'Driver Extension Node:\s*$')
        if ($matchResult.Success) {
            Add-SetupApiDriverNodeRow -Rows $rows -CurrentNode $currentNode -PublishedLookup $publishedLookup
            $currentNode = [ordered]@{
                NodeKind = 'Extension'
                DeviceID = $currentDeviceId
                Status = ''
                PublishedName = ''
                OriginalName = ''
                ProviderName = ''
                ClassName = ''
                ClassGuid = ''
                ExtensionId = ''
                DriverDate = ''
                DriverVersion = ''
                Configuration = ''
                DriverRank = ''
                SignerScore = ''
                StorePath = ''
            }
            continue
        }

        $matchResult = [regex]::Match($text, 'Driver Node:\s*$')
        if ($matchResult.Success) {
            Add-SetupApiDriverNodeRow -Rows $rows -CurrentNode $currentNode -PublishedLookup $publishedLookup
            $currentNode = [ordered]@{
                NodeKind = 'Driver'
                DeviceID = $currentDeviceId
                Status = ''
                PublishedName = ''
                OriginalName = ''
                ProviderName = ''
                ClassName = ''
                ClassGuid = ''
                ExtensionId = ''
                DriverDate = ''
                DriverVersion = ''
                Configuration = ''
                DriverRank = ''
                SignerScore = ''
                StorePath = ''
            }
            continue
        }

        if ($null -eq $currentNode) { continue }

        $matchResult = [regex]::Match($text, 'Status\s+-\s+(.+)$')
        if ($matchResult.Success) {
            $currentNode.Status = $matchResult.Groups[1].Value.Trim()
            continue
        }

        $matchResult = [regex]::Match($text, 'Driver INF\s+-\s+([^\s]+)(?:\s+\((.+)\))?')
        if ($matchResult.Success) {
            $currentNode.PublishedName = $matchResult.Groups[1].Value.Trim()
            if ($matchResult.Groups.Count -gt 2) {
                $currentNode.StorePath = $matchResult.Groups[2].Value.Trim()
            }
            continue
        }

        $matchResult = [regex]::Match($text, 'Class GUID\s+-\s+(.+)$')
        if ($matchResult.Success) {
            $currentNode.ClassGuid = $matchResult.Groups[1].Value.Trim()
            continue
        }

        $matchResult = [regex]::Match($text, 'Extension ID\s+-\s+(.+)$')
        if ($matchResult.Success) {
            $currentNode.ExtensionId = $matchResult.Groups[1].Value.Trim()
            continue
        }

        $matchResult = [regex]::Match($text, 'Driver Version\s+-\s+(.+)$')
        if ($matchResult.Success) {
            $versionParts = Split-DriverVersionText $matchResult.Groups[1].Value.Trim()
            $currentNode.DriverDate = Format-DriverDate $versionParts.DateText
            $currentNode.DriverVersion = $versionParts.VersionText
            continue
        }

        $matchResult = [regex]::Match($text, 'Configuration\s+-\s+(.+)$')
        if ($matchResult.Success) {
            $currentNode.Configuration = $matchResult.Groups[1].Value.Trim()
            continue
        }

        $matchResult = [regex]::Match($text, 'Driver Rank\s+-\s+(.+)$')
        if ($matchResult.Success) {
            $currentNode.DriverRank = $matchResult.Groups[1].Value.Trim()
            continue
        }

        $matchResult = [regex]::Match($text, 'Signer Score\s+-\s+(.+)$')
        if ($matchResult.Success) {
            $currentNode.SignerScore = $matchResult.Groups[1].Value.Trim()
            continue
        }
    }

    Add-SetupApiDriverNodeRow -Rows $rows -CurrentNode $currentNode -PublishedLookup $publishedLookup

    $seenRows = @{}
    $uniqueRows = New-Object System.Collections.Generic.List[object]
    foreach ($row in $rows.ToArray()) {
        $dedupeKey = @(
            [string]$row.NodeKind,
            [string]$row.Status,
            [string]$row.DeviceID,
            [string]$row.PublishedName,
            [string]$row.OriginalName,
            [string]$row.DriverDate,
            [string]$row.DriverVersion,
            [string]$row.DriverRank,
            [string]$row.ExtensionId,
            [string]$row.Configuration
        ) -join '|'
        if ($seenRows.ContainsKey($dedupeKey)) { continue }
        $seenRows[$dedupeKey] = $true
        $uniqueRows.Add($row) | Out-Null
    }

    return $uniqueRows.ToArray()
}

function Get-SetupApiNoMatchingInfLookup {
    param($Diff)

    $lookup = @{}
    if ($null -eq $Diff) { return $lookup }

    $currentOriginal = ''
    $currentPublished = ''
    $insideDriverNode = $false
    foreach ($line in @($Diff.SetupApiInterestingLines)) {
        $text = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        if ($text -match '^>>>|^<<<\s+Section end') {
            $currentOriginal = ''
            $currentPublished = ''
            $insideDriverNode = $false
            continue
        }
        if ($text -match '^dvs:') { $insideDriverNode = $false }
        if ($text -match 'Driver Extension Node:\s*$|Driver Node:\s*$') {
            $insideDriverNode = $true
            continue
        }

        $matchResult = if (-not $insideDriverNode) {
            [regex]::Match($text, 'Driver INF\s+-\s+([^\s(]+)(?:\s+\(([^)]+)\))?')
        } else {
            [System.Text.RegularExpressions.Match]::Empty
        }
        if ($matchResult.Success) {
            $currentOriginal = Normalize-InfName $matchResult.Groups[1].Value
            $currentPublished = ''
            if ($matchResult.Groups.Count -gt 2) {
                $currentPublished = Normalize-InfName $matchResult.Groups[2].Value
            }
            continue
        }

        if ($text -match 'Unable to find any matching devices') {
            foreach ($key in @($currentOriginal, $currentPublished)) {
                if (-not [string]::IsNullOrWhiteSpace($key)) {
                    $lookup[$key] = $true
                }
            }
        }
    }

    return $lookup
}

function Get-ActiveDriverPackageImpact {
    param(
        $After,
        $Diff,
        [object[]]$DeviceInstallRows = @()
    )

    if ($null -eq $After -or $null -eq $Diff) { return @() }

    $publishedLookup = New-PublishedDriverLookup -PublishedDrivers $After.PublishedDrivers
    $activeDrivers = @($After.SignedDrivers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.InfName) })
    $noMatchingInfLookup = Get-SetupApiNoMatchingInfLookup -Diff $Diff

    $rows = foreach ($staged in @($Diff.AddedPublishedDrivers)) {
        $publishedName = [string](Get-TraceObjectValue -InputObject $staged -Name 'PublishedName')
        $originalName = [string](Get-TraceObjectValue -InputObject $staged -Name 'OriginalName')
        $stagedVersion = [string](Get-TraceObjectValue -InputObject $staged -Name 'DriverVersion')
        $stagedProvider = [string](Get-TraceObjectValue -InputObject $staged -Name 'ProviderName')
        $stagedVersionParts = Split-DriverVersionText $stagedVersion
        $stagedDateText = Format-DriverDate $stagedVersionParts.DateText
        $stagedVersionNumber = $stagedVersionParts.VersionText
        $stagedDateObject = ConvertTo-DriverDateObject $stagedVersionParts.DateText
        $normalizedPublished = Normalize-InfName $publishedName
        $normalizedOriginal = Normalize-InfName $originalName
        $appliedConfigurations = @($DeviceInstallRows | Where-Object { (Normalize-InfName $_.PublishedName) -eq $normalizedPublished })

        $activeExact = @($activeDrivers | Where-Object { (Normalize-InfName $_.InfName) -eq $normalizedPublished })
        $activeSameOriginal = @($activeDrivers | Where-Object {
            $activePublishedName = Normalize-InfName $_.InfName
            if (-not $publishedLookup.ContainsKey($activePublishedName)) { return $false }
            $activePackage = $publishedLookup[$activePublishedName]
            (Normalize-InfName (Get-TraceObjectValue -InputObject $activePackage -Name 'OriginalName')) -eq $normalizedOriginal
        })

        $activeDifferentPublished = @($activeSameOriginal | Where-Object { (Normalize-InfName $_.InfName) -ne $normalizedPublished })
        $normalizedStagedVersion = Normalize-DriverVersionNumber $stagedVersion
        $sameVersionActive = @($activeDifferentPublished | Where-Object {
            $activeVersion = Normalize-DriverVersionNumber (Get-TraceObjectValue -InputObject $_ -Name 'DriverVersion')
            -not [string]::IsNullOrWhiteSpace($activeVersion) -and $activeVersion -eq $normalizedStagedVersion
        })

        $status = 'Staged only'
        if ($appliedConfigurations.Count -gt 0) {
            $status = if ([string](Get-TraceObjectValue -InputObject $staged -Name 'ClassName') -eq 'Extension') {
                'Applied Extension INF configuration'
            } else {
                'Applied device configuration'
            }
        } elseif ($activeExact.Count -gt 0) {
            $status = 'Active'
        } elseif ($sameVersionActive.Count -gt 0) {
            $newerActiveDateCount = 0
            $sameActiveDateCount = 0
            foreach ($activeDriver in $sameVersionActive) {
                $activeDateObject = ConvertTo-DriverDateObject (Get-TraceObjectValue -InputObject $activeDriver -Name 'DriverDate')
                if ($null -eq $activeDateObject -or $null -eq $stagedDateObject) { continue }
                if ($activeDateObject -gt $stagedDateObject) { $newerActiveDateCount++ }
                if ($activeDateObject -eq $stagedDateObject) { $sameActiveDateCount++ }
            }
            if ($newerActiveDateCount -gt 0) {
                $status = 'Staged only; same version already active with newer date'
            } elseif ($sameActiveDateCount -gt 0) {
                $status = 'Staged only; same version/date already active'
            } else {
                $status = 'Staged only; same version already active'
            }
        } elseif ($activeDifferentPublished.Count -gt 0) {
            $status = 'Staged only; same original INF already active'
        } elseif ($noMatchingInfLookup.ContainsKey($normalizedPublished) -or $noMatchingInfLookup.ContainsKey($normalizedOriginal)) {
            $status = 'Staged only; no matching present device'
        }

        $activeSummary = ''
        $activeEvidence = if ($activeExact.Count -gt 0) { $activeExact } elseif ($activeDifferentPublished.Count -gt 0) { $activeDifferentPublished } else { @() }
        if (@($activeEvidence).Count -gt 0) {
            $activeSummary = (@($activeEvidence | Select-Object -First 3 | ForEach-Object {
                $activeDateText = Format-DriverDate (Get-TraceObjectValue -InputObject $_ -Name 'DriverDate')
                if ([string]::IsNullOrWhiteSpace($activeDateText)) {
                    '{0} via {1} / {2}' -f $_.DeviceName, $_.InfName, $_.DriverVersion
                } else {
                    '{0} via {1} / {2} / {3}' -f $_.DeviceName, $_.InfName, $activeDateText, $_.DriverVersion
                }
            }) -join '; ')
            if (@($activeEvidence).Count -gt 3) { $activeSummary += ('; +{0} more' -f (@($activeEvidence).Count - 3)) }
        }

        [pscustomobject]@{
            PublishedName = $publishedName
            OriginalName = $originalName
            ProviderName = $stagedProvider
            DriverVersion = $stagedVersion
            StagedDate = $stagedDateText
            StagedVersion = $stagedVersionNumber
            Status = $status
            ActiveEvidence = $activeSummary
            SameVersionAlreadyActive = [bool]($sameVersionActive.Count -gt 0)
        }
    }

    return @($rows)
}

function Get-MatchedDeviceActiveDrivers {
    param(
        $Preview,
        $After
    )

    if ($null -eq $Preview -or $null -eq $After) { return @() }

    $publishedLookup = New-PublishedDriverLookup -PublishedDrivers $After.PublishedDrivers
    $signedByDeviceId = @{}
    foreach ($driver in @($After.SignedDrivers)) {
        $deviceId = [string](Get-TraceObjectValue -InputObject $driver -Name 'DeviceID')
        if (-not [string]::IsNullOrWhiteSpace($deviceId)) { $signedByDeviceId[$deviceId] = $driver }
    }

    $seen = @{}
    $rows = foreach ($previewMatch in @($Preview.Matches)) {
        $instanceId = [string](Get-TraceObjectValue -InputObject $previewMatch -Name 'InstanceId')
        if ([string]::IsNullOrWhiteSpace($instanceId) -or $seen.ContainsKey($instanceId) -or -not $signedByDeviceId.ContainsKey($instanceId)) {
            continue
        }
        $seen[$instanceId] = $true

        $activeDriver = $signedByDeviceId[$instanceId]
        $activePublishedName = Normalize-InfName (Get-TraceObjectValue -InputObject $activeDriver -Name 'InfName')
        $activeOriginal = ''
        if ($publishedLookup.ContainsKey($activePublishedName)) {
            $activeOriginal = [string](Get-TraceObjectValue -InputObject $publishedLookup[$activePublishedName] -Name 'OriginalName')
        }

        [pscustomobject]@{
            DeviceName = Get-TraceObjectValue -InputObject $activeDriver -Name 'DeviceName'
            DeviceID = $instanceId
            ActivePublishedName = Get-TraceObjectValue -InputObject $activeDriver -Name 'InfName'
            ActiveOriginalName = $activeOriginal
            ActiveProvider = Get-TraceObjectValue -InputObject $activeDriver -Name 'DriverProviderName'
            ActiveVersion = Get-TraceObjectValue -InputObject $activeDriver -Name 'DriverVersion'
            ActiveDate = Format-DriverDate (Get-TraceObjectValue -InputObject $activeDriver -Name 'DriverDate')
        }
    }

    return @($rows)
}

function ConvertTo-DriverVersionObject {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    try {
        return [version]$text
    } catch {
        return $null
    }
}

function Get-MatchedPackageActiveComparisons {
    param(
        $Preview,
        [object[]]$MatchedActiveDrivers
    )

    if ($null -eq $Preview -or @($MatchedActiveDrivers).Count -eq 0) { return @() }

    $activeByDeviceId = @{}
    foreach ($activeDriver in @($MatchedActiveDrivers)) {
        $deviceId = [string](Get-TraceObjectValue -InputObject $activeDriver -Name 'DeviceID')
        if (-not [string]::IsNullOrWhiteSpace($deviceId)) { $activeByDeviceId[$deviceId] = $activeDriver }
    }

    $seen = @{}
    $rows = foreach ($previewMatch in @($Preview.Matches)) {
        $deviceId = [string](Get-TraceObjectValue -InputObject $previewMatch -Name 'InstanceId')
        if ([string]::IsNullOrWhiteSpace($deviceId) -or -not $activeByDeviceId.ContainsKey($deviceId)) { continue }

        $packageInf = [System.IO.Path]::GetFileName([string](Get-TraceObjectValue -InputObject $previewMatch -Name 'Inf'))
        $activeDriver = $activeByDeviceId[$deviceId]
        $activeOriginalInf = [string](Get-TraceObjectValue -InputObject $activeDriver -Name 'ActiveOriginalName')
        if ([string]::IsNullOrWhiteSpace($packageInf) -or (Normalize-InfName $packageInf) -ne (Normalize-InfName $activeOriginalInf)) { continue }

        $dedupeKey = $deviceId + '|' + (Normalize-InfName $packageInf)
        if ($seen.ContainsKey($dedupeKey)) { continue }
        $seen[$dedupeKey] = $true

        $packageVersionParts = Split-DriverVersionText (Get-TraceObjectValue -InputObject $previewMatch -Name 'DriverVer')
        $packageDate = ConvertTo-DriverDateObject $packageVersionParts.DateText
        $activeDate = ConvertTo-DriverDateObject (Get-TraceObjectValue -InputObject $activeDriver -Name 'ActiveDate')
        $packageVersion = ConvertTo-DriverVersionObject $packageVersionParts.VersionText
        $activeVersion = ConvertTo-DriverVersionObject (Get-TraceObjectValue -InputObject $activeDriver -Name 'ActiveVersion')
        $relationship = 'Unknown'
        $comparisonBasis = ''

        if ($null -ne $packageDate -and $null -ne $activeDate -and $packageDate -ne $activeDate) {
            $relationship = if ($packageDate -lt $activeDate) { 'Older' } else { 'Newer' }
            $comparisonBasis = 'Driver date'
        } elseif ($null -ne $packageVersion -and $null -ne $activeVersion) {
            $versionComparison = $packageVersion.CompareTo($activeVersion)
            $relationship = if ($versionComparison -lt 0) { 'Older' } elseif ($versionComparison -gt 0) { 'Newer' } else { 'Same' }
            $comparisonBasis = if ($null -ne $packageDate -and $null -ne $activeDate) { 'Same date; driver version' } else { 'Driver version' }
        } elseif ($null -ne $packageDate -and $null -ne $activeDate) {
            $relationship = 'Same'
            $comparisonBasis = 'Driver date'
        }

        [pscustomobject]@{
            DeviceName = Get-TraceObjectValue -InputObject $previewMatch -Name 'DeviceName'
            DeviceID = $deviceId
            PackageInf = $packageInf
            PackageDate = Format-DriverDate $packageVersionParts.DateText
            PackageVersion = $packageVersionParts.VersionText
            ActivePublishedInf = Get-TraceObjectValue -InputObject $activeDriver -Name 'ActivePublishedName'
            ActiveOriginalInf = $activeOriginalInf
            ActiveDate = Get-TraceObjectValue -InputObject $activeDriver -Name 'ActiveDate'
            ActiveVersion = Get-TraceObjectValue -InputObject $activeDriver -Name 'ActiveVersion'
            Relationship = $relationship
            ComparisonBasis = $comparisonBasis
        }
    }

    return @($rows)
}

function Get-TraceVerdict {
    param(
        [bool]$InstallerWasRun,
        [AllowNull()][object]$Preview,
        $Diff,
        [object[]]$PackageImpactRows,
        [object[]]$PackageActiveComparisonRows = @(),
        [object[]]$SetupApiDeviceInstallRows = @(),
        [object[]]$SetupApiOutcomeRows = @(),
        [object[]]$SetupApiDriverNodeRows = @()
    )

    if (-not $InstallerWasRun -or $null -eq $Diff) {
        return 'Preview only: no after snapshot exists, so no actual install impact was measured.'
    }

    $stagedCount = @($Diff.AddedPublishedDrivers).Count
    $changedActiveCount = @($Diff.ChangedSignedDrivers).Count
    $addedActiveCount = @($Diff.AddedSignedDrivers).Count
    $removedActiveCount = @($Diff.RemovedSignedDrivers).Count
    $activeStateChangeCount = $changedActiveCount + $addedActiveCount + $removedActiveCount
    $sameVersionAlreadyActiveCount = @($PackageImpactRows | Where-Object { $_.SameVersionAlreadyActive }).Count
    $noMatchingPresentDeviceCount = @($PackageImpactRows | Where-Object { $_.Status -eq 'Staged only; no matching present device' }).Count
    $matchedDeviceCount = [int](Get-TraceObjectValue -InputObject $Preview -Name 'MatchCount')
    $setupApiSignals = @($SetupApiOutcomeRows | ForEach-Object { [string]$_.Detail })

    if ($activeStateChangeCount -gt 0) {
        return ('Active driver state changed ({0} updated, {1} added, {2} removed binding(s)). Inspect the active-driver tables before deciding whether this was a useful update.' -f $changedActiveCount, $addedActiveCount, $removedActiveCount)
    }

    $newlyAppliedConfigurationRows = @($SetupApiDeviceInstallRows | Where-Object { $_.IsNewlyStaged })
    $newlyAppliedExtensionCount = @($newlyAppliedConfigurationRows | Where-Object { $_.ClassName -eq 'Extension' }).Count
    if ($newlyAppliedConfigurationRows.Count -gt 0) {
        if ($newlyAppliedExtensionCount -gt 0) {
            return 'A newly staged Extension INF was applied to the device configuration even though the active function-driver binding did not change. This is a real extension/configuration update, not staging-only; inspect the applied-configuration and selected-driver-stack tables.'
        }
        return 'A newly staged driver package was applied to device configuration even though no Win32_PnPSignedDriver binding changed. This is a real device-configuration change, not staging-only; inspect the applied-configuration table.'
    }

    $infCount = [int](Get-TraceObjectValue -InputObject $Preview -Name 'InfCount')
    $payloadFileCountText = [string](Get-TraceObjectValue -InputObject $Preview -Name 'PayloadFileCount')
    $payloadKind = [string](Get-TraceObjectValue -InputObject $Preview -Name 'PayloadKind')
    $payloadFileCount = 0
    [void][int]::TryParse($payloadFileCountText, [ref]$payloadFileCount)
    $meaningfulSetupApiLineCount = @($Diff.SetupApiInterestingLines).Count
    if ($infCount -eq 0 -and $payloadFileCount -gt 0 -and $stagedCount -eq 0 -and $meaningfulSetupApiLineCount -eq 0) {
        if ([string]::IsNullOrWhiteSpace($payloadKind)) { $payloadKind = 'non-driver payload' }
        if ($payloadKind -eq 'Nested installer/bootstrapper payload') {
            return 'A nested installer/bootstrapper ran, but no DriverStore, SetupAPI, or active-driver state change was detected. Confirm that its child installer completed before treating this as a no-change result.'
        }
        $article = if ($payloadKind -match '^(?i:msi|application|executable|archive)') { 'an' } else { 'a' }
        return "Extracted payload exists but contains no INF files, and no driver state changed. This looks like $article $payloadKind, not a driver package."
    }

    $olderSameFamilyCount = @($PackageActiveComparisonRows | Where-Object { $_.Relationship -eq 'Older' }).Count
    $newerSameFamilyCount = @($PackageActiveComparisonRows | Where-Object { $_.Relationship -eq 'Newer' }).Count
    $sameSameFamilyCount = @($PackageActiveComparisonRows | Where-Object { $_.Relationship -eq 'Same' }).Count
    if ($stagedCount -eq 0 -and $activeStateChangeCount -eq 0 -and $olderSameFamilyCount -gt 0 -and $newerSameFamilyCount -eq 0) {
        return 'The package exactly matches a present device and the active original INF, but its same-family driver is older than the active driver. No driver state changed, so this package is not useful for this machine.'
    }
    if ($stagedCount -eq 0 -and $activeStateChangeCount -eq 0 -and $newerSameFamilyCount -gt 0) {
        return 'The package contains a newer same-family driver for a matched present device, but no driver state changed. Inspect installer execution and SetupAPI evidence before deciding whether to retry it.'
    }
    if ($stagedCount -eq 0 -and $activeStateChangeCount -eq 0 -and $sameSameFamilyCount -gt 0 -and $olderSameFamilyCount -eq 0 -and $newerSameFamilyCount -eq 0) {
        return 'The package exactly matches a present device and the same driver version/date is already active. No driver state changed, so this package is already satisfied on this machine.'
    }

    if ($stagedCount -gt 0 -and $matchedDeviceCount -gt 0 -and $noMatchingPresentDeviceCount -gt 0 -and $setupApiSignals -match 'Already Imported|No better matching drivers|Device does not need an update|No devices were updated') {
        return 'A matched device was checked, but SetupAPI kept the existing active driver because the package was already imported or not a better match. The newly staged package(s) did not match present hardware, so this does not look useful for this machine.'
    }

    if ($stagedCount -gt 0 -and $sameVersionAlreadyActiveCount -gt 0) {
        return 'Driver packages were staged in DriverStore, but no active device driver changed. At least one staged package matches an already-active original INF/version, so this looks like duplicate availability rather than a practical update.'
    }

    if ($stagedCount -gt 0 -and $noMatchingPresentDeviceCount -eq $stagedCount) {
        return 'Driver packages were staged in DriverStore, but SetupAPI found no matching present devices for the staged packages and no active device driver changed.'
    }

    if ($stagedCount -gt 0) {
        return 'Driver packages were staged in DriverStore, but no active device driver changed. This may be normal for packages that include drivers for related hardware variants or inactive devices.'
    }

    $selectedExtensionNodeCount = @($SetupApiDriverNodeRows | Where-Object {
        $_.NodeKind -eq 'Extension' -and $_.Status -match 'Selected' -and $_.Status -match 'Installed'
    }).Count
    if ($selectedExtensionNodeCount -gt 0 -and $setupApiSignals -match 'Already Imported|No better matching drivers|Device does not need an update|No devices were updated') {
        return 'No DriverStore or active-driver state changed. SetupAPI shows an Extension INF already selected/installed for the matched device, so this looks like an already-installed extension package rather than a practical update.'
    }

    if ($setupApiSignals -match 'Already Imported|No better matching drivers|Device does not need an update|No devices were updated') {
        return 'No DriverStore or active-driver state changed. SetupAPI still logged installer activity, but it reported already-imported/no-better-match outcomes rather than a practical update.'
    }

    return 'No new published drivers and no active driver changes were detected.'
}

function Get-SetupApiOutcomeRows {
    param($Diff)

    if ($null -eq $Diff) { return @() }

    $seen = @{}
    $insideDriverNode = $false
    $rows = foreach ($line in @($Diff.SetupApiInterestingLines)) {
        $text = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match '^dvs:') { $insideDriverNode = $false }
        if ($text -match 'Driver Extension Node:\s*$|Driver Node:\s*$') {
            $insideDriverNode = $true
            continue
        }

        $signal = ''
        $detail = ''

        $matchResult = [regex]::Match($text, 'Outcome\s+-\s+(.+)$')
        if ($matchResult.Success) {
            $signal = 'Import outcome'
            $detail = $matchResult.Groups[1].Value.Trim()
        }

        if ([string]::IsNullOrWhiteSpace($signal) -and -not $insideDriverNode) {
            $matchResult = [regex]::Match($text, 'Driver INF\s+-\s+(.+)$')
            if ($matchResult.Success) {
                $signal = 'Driver INF'
                $detail = $matchResult.Groups[1].Value.Trim()
            }
        }

        if ([string]::IsNullOrWhiteSpace($signal)) {
            $matchResult = [regex]::Match($text, "No better matching drivers found for device '(.+)'")
            if ($matchResult.Success) {
                $signal = 'Driver ranking'
                $detail = 'No better matching drivers found for ' + $matchResult.Groups[1].Value.Trim()
            }
        }

        if ([string]::IsNullOrWhiteSpace($signal) -and $text -match 'Device does not need an update') {
            $signal = 'Device update'
            $detail = 'Device does not need an update'
        }

        if ([string]::IsNullOrWhiteSpace($signal) -and $text -match 'No devices were updated') {
            $signal = 'Device update'
            $detail = 'No devices were updated'
        }

        if ([string]::IsNullOrWhiteSpace($signal) -and $text -match 'Unable to find any matching devices') {
            $signal = 'Device matching'
            $detail = 'Unable to find any matching devices'
        }

        if ([string]::IsNullOrWhiteSpace($signal)) {
            $matchResult = [regex]::Match($text, "Marking non-present device '(.+)' for reinstall")
            if ($matchResult.Success) {
                $signal = 'Non-present device'
                $detail = 'Marked for reinstall: ' + $matchResult.Groups[1].Value.Trim()
            }
        }

        if ([string]::IsNullOrWhiteSpace($signal)) {
            $matchResult = [regex]::Match($text, 'Exit status:\s+([^\]]+)')
            if ($matchResult.Success) {
                $signal = 'Section exit'
                $detail = $matchResult.Groups[1].Value.Trim()
            }
        }

        if ([string]::IsNullOrWhiteSpace($signal)) { continue }

        $key = $signal + '|' + $detail
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        [pscustomobject]@{
            Signal = $signal
            Detail = $detail
        }
    }

    return @($rows | Select-Object -First 16)
}

function New-MarkdownReport {
    param(
        $Preview,
        $Before,
        $After,
        $Diff,
        [AllowNull()][object]$RunMetadata,
        [string]$OutputDirectory,
        [bool]$InstallerWasRun
    )

    $reportPath = Join-Path $OutputDirectory 'report.md'
    $lines = New-Object System.Collections.Generic.List[string]
    $existingExtractedRoot = [string](Get-TraceObjectValue -InputObject $Preview -Name 'ExistingExtractedRoot')
    if ([string]::IsNullOrWhiteSpace($existingExtractedRoot)) {
        $previewInstallerPath = [string](Get-TraceObjectValue -InputObject $Preview -Name 'InstallerPath')
        if (-not [string]::IsNullOrWhiteSpace($previewInstallerPath) -and (Test-Path -LiteralPath $previewInstallerPath)) {
            $existingExtractedRoot = Find-ExistingExtractedPackageRoot -PackagePath $previewInstallerPath
        }
    }

    $payloadFiles = @()
    $payloadFilesProperty = $Preview.PSObject.Properties['PayloadFiles']
    if ($null -ne $payloadFilesProperty -and $null -ne $payloadFilesProperty.Value) {
        $payloadFiles = @($payloadFilesProperty.Value)
    } elseif (-not [string]::IsNullOrWhiteSpace($existingExtractedRoot)) {
        $payloadFiles = @(Get-PayloadFileSummary -ExtractedRoot $existingExtractedRoot)
    }

    $payloadFileCountText = [string](Get-TraceObjectValue -InputObject $Preview -Name 'PayloadFileCount')
    $payloadFileCount = 0
    if (-not [int]::TryParse($payloadFileCountText, [ref]$payloadFileCount) -and -not [string]::IsNullOrWhiteSpace($existingExtractedRoot)) {
        $payloadFileCount = $payloadFiles.Count
    }
    if ($payloadFileCount -eq 0 -and $payloadFiles.Count -gt 0) { $payloadFileCount = $payloadFiles.Count }

    $payloadKind = [string](Get-TraceObjectValue -InputObject $Preview -Name 'PayloadKind')
    if ([string]::IsNullOrWhiteSpace($payloadKind)) {
        $payloadKind = Get-PayloadKind -PayloadFiles $payloadFiles -InfCount ([int]$Preview.InfCount)
    }
    $extractionManifest = Get-TraceObjectValue -InputObject $Preview -Name 'Extraction'
    if ($extractionManifest -is [string] -and [string]::IsNullOrWhiteSpace($extractionManifest)) {
        $extractionManifest = $null
    }

    $lines.Add('# Driver Package Impact Trace')
    $lines.Add('')
    $lines.Add(('Generated: `{0}`' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
    $lines.Add('')
    $lines.Add('## Summary')
    $lines.Add('')
    $lines.Add(('- Package: `{0}`' -f $Preview.InstallerPath))
    $lines.Add(('- Extracted payload: `{0}`' -f $(if ($existingExtractedRoot) { $existingExtractedRoot } else { 'not found' })))
    $lines.Add(('- Extracted payload files: `{0}`' -f $payloadFileCount))
    $lines.Add(('- Payload kind: `{0}`' -f $payloadKind))
    $lines.Add(('- INF files inspected: `{0}`' -f $Preview.InfCount))
    $lines.Add(('- Local INF/device matches: `{0}`' -f $Preview.MatchCount))
    if ($null -ne $extractionManifest) {
        $lines.Add(('- Extraction mode: `{0}`' -f (Get-TraceObjectValue -InputObject $extractionManifest -Name 'CompletedMode')))
        $identification = Get-TraceObjectValue -InputObject $extractionManifest -Name 'Identification'
        $lines.Add(('- Detected installer engine: `{0} {1}`' -f
            (Get-TraceObjectValue -InputObject $identification -Name 'Engine'),
            (Get-TraceObjectValue -InputObject $identification -Name 'EngineVersion')))
        $lines.Add(('- Extraction cache reused: `{0}`' -f (Get-TraceObjectValue -InputObject $extractionManifest -Name 'CacheReused')))
    }
    $lines.Add(('- Installer run: `{0}`' -f $InstallerWasRun))
    if ($InstallerWasRun) {
        $installerExitCode = [string](Get-TraceObjectValue -InputObject $RunMetadata -Name 'InstallerExitCode')
        if ([string]::IsNullOrWhiteSpace($installerExitCode)) { $installerExitCode = 'not recorded' }
        $lines.Add(('- Installer exit code: `{0}`' -f $installerExitCode))
        $installerExitInterpretation = [string](Get-TraceObjectValue -InputObject $RunMetadata -Name 'InstallerExitInterpretation')
        if ([string]::IsNullOrWhiteSpace($installerExitInterpretation)) {
            $installerExitInterpretation = Get-InstallerExitCodeInterpretation -ExitCode $installerExitCode
        }
        $lines.Add(('- Exit-code interpretation: **{0}**' -f (ConvertTo-MarkdownCell $installerExitInterpretation)))
    }
    $lines.Add('')

    Add-TraceDriverPackageExtractionMarkdown -Lines $lines -Manifest $extractionManifest

    $lines.Add('## Package Preview Matches')
    $lines.Add('')
    if (@($Preview.Matches).Count -eq 0) {
        if ($Preview.InfCount -eq 0 -and -not [string]::IsNullOrWhiteSpace($existingExtractedRoot)) {
            $lines.Add(('Extracted payload exists, but it contains no INF files. Payload kind: **{0}**.' -f (ConvertTo-MarkdownCell $payloadKind)))
            if ($payloadKind -eq 'Nested installer/bootstrapper payload') {
                $lines.Add('The visible extraction contains another installer rather than the final INF payload. Driver INFs may appear only while that child installer runs, so before/after snapshots and SetupAPI evidence are the authoritative result.')
            }
        } else {
            $lines.Add('No local device ID matches were found in extracted INF files.')
        }
    } else {
        $lines.Add('| Device | Match | INF | DriverVer | Provider |')
        $lines.Add('|---|---|---|---|---|')
        foreach ($match in @($Preview.Matches | Sort-Object DeviceName, MatchKind, Inf)) {
            $lines.Add(('| {0} | {1} `{2}` | `{3}` | `{4}` | `{5}` |' -f $match.DeviceName, $match.MatchKind, $match.MatchedId, $match.Inf, $match.DriverVer, $match.Provider))
        }
    }
    $lines.Add('')

    $supportedIdRows = New-Object System.Collections.Generic.List[object]
    if (@($Preview.Matches).Count -eq 0) {
        foreach ($infFile in @($Preview.InfFiles)) {
            foreach ($supportedId in @(Get-TraceObjectValue -InputObject $infFile -Name 'SupportedDeviceIds')) {
                $supportedIdRows.Add([pscustomobject]@{
                    Inf = Get-TraceObjectValue -InputObject $infFile -Name 'RelativePath'
                    Provider = Get-TraceObjectValue -InputObject $infFile -Name 'Provider'
                    DriverVer = Get-TraceObjectValue -InputObject $infFile -Name 'DriverVer'
                    DeviceId = $supportedId
                }) | Out-Null
            }
        }
    }
    if ($supportedIdRows.Count -gt 0) {
        $lines.Add('### Package INF Supported Device IDs (No Local Match)')
        $lines.Add('')
        $lines.Add('| INF | Provider | DriverVer | Supported device ID |')
        $lines.Add('|---|---|---|---|')
        foreach ($supportedRow in @($supportedIdRows.ToArray() | Select-Object -First 80)) {
            $lines.Add(('| `{0}` | {1} | `{2}` | `{3}` |' -f
                (ConvertTo-MarkdownCell $supportedRow.Inf),
                (ConvertTo-MarkdownCell $supportedRow.Provider),
                (ConvertTo-MarkdownCell $supportedRow.DriverVer),
                (ConvertTo-MarkdownCell $supportedRow.DeviceId)))
        }
        if ($supportedIdRows.Count -gt 80) {
            $lines.Add(('| ... |  |  | `{0} more IDs` |' -f ($supportedIdRows.Count - 80)))
        }
        $lines.Add('')
    }

    $lines.Add('## Actual Changes')
    $lines.Add('')
    if (-not $InstallerWasRun -or $null -eq $After -or $null -eq $Diff) {
        $lines.Add('The installer was not run, so no after snapshot exists.')
    } else {
        $setupApiDeviceInstallRows = @()
        $deviceInstallProperty = $Diff.PSObject.Properties['SetupApiDeviceInstallActions']
        if ($null -ne $deviceInstallProperty -and $null -ne $deviceInstallProperty.Value) {
            $setupApiDeviceInstallRows = @($deviceInstallProperty.Value)
        } else {
            $setupApiDeltaPath = Join-Path $OutputDirectory 'setupapi.delta.log'
            if (Test-Path -LiteralPath $setupApiDeltaPath) {
                $setupApiDeviceInstallRows = @(Get-SetupApiDeviceInstallRowsFromText -SetupApiText (Get-Content -LiteralPath $setupApiDeltaPath -Raw) -PublishedDrivers $After.PublishedDrivers -AddedPublishedDrivers $Diff.AddedPublishedDrivers)
            }
        }
        $packageImpactRows = @(Get-ActiveDriverPackageImpact -After $After -Diff $Diff -DeviceInstallRows $setupApiDeviceInstallRows)
        $matchedActiveDrivers = @(Get-MatchedDeviceActiveDrivers -Preview $Preview -After $After)
        $packageActiveComparisonRows = @(Get-MatchedPackageActiveComparisons -Preview $Preview -MatchedActiveDrivers $matchedActiveDrivers)
        $setupApiOutcomeRows = @(Get-SetupApiOutcomeRows -Diff $Diff)
        $setupApiDriverNodeRows = @()
        $driverNodeProperty = $Diff.PSObject.Properties['SetupApiDriverNodes']
        if ($null -ne $driverNodeProperty -and $null -ne $driverNodeProperty.Value) {
            $setupApiDriverNodeRows = @($driverNodeProperty.Value)
        } else {
            $setupApiDeltaPath = Join-Path $OutputDirectory 'setupapi.delta.log'
            if ((Test-Path -LiteralPath $setupApiDeltaPath) -and $null -ne $After) {
                $setupApiDriverNodeRows = @(Get-SetupApiDriverNodeRowsFromText -SetupApiText (Get-Content -LiteralPath $setupApiDeltaPath -Raw) -PublishedDrivers $After.PublishedDrivers)
            }
        }
        $verdict = Get-TraceVerdict -InstallerWasRun $InstallerWasRun -Preview ([pscustomobject]@{
            InfCount = $Preview.InfCount
            MatchCount = $Preview.MatchCount
            PayloadFileCount = $payloadFileCount
            PayloadKind = $payloadKind
        }) -Diff $Diff -PackageImpactRows $packageImpactRows -PackageActiveComparisonRows $packageActiveComparisonRows -SetupApiDeviceInstallRows $setupApiDeviceInstallRows -SetupApiOutcomeRows $setupApiOutcomeRows -SetupApiDriverNodeRows $setupApiDriverNodeRows

        $lines.Add(('**Verdict:** {0}' -f $verdict))
        $lines.Add('')
        $lines.Add(('- New published drivers: `{0}`' -f @($Diff.AddedPublishedDrivers).Count))
        $lines.Add(('- Removed published drivers: `{0}`' -f @($Diff.RemovedPublishedDrivers).Count))
        $lines.Add(('- New `C:\Windows\INF\oem*.inf`: `{0}`' -f @($Diff.AddedInfFiles).Count))
        $lines.Add(('- New DriverStore folders: `{0}`' -f @($Diff.AddedDriverStoreFolders).Count))
        $lines.Add(('- Updated active driver bindings: `{0}`' -f @($Diff.ChangedSignedDrivers).Count))
        $lines.Add(('- Added active driver bindings: `{0}`' -f @($Diff.AddedSignedDrivers).Count))
        $lines.Add(('- Removed active driver bindings: `{0}`' -f @($Diff.RemovedSignedDrivers).Count))
        $lines.Add(('- SetupAPI delta characters: `{0}`' -f $Diff.SetupApiDeltaLength))
        $lines.Add('')

        if ($setupApiOutcomeRows.Count -gt 0) {
            $lines.Add('### SetupAPI Outcome Signals')
            $lines.Add('')
            $lines.Add('| Signal | Detail |')
            $lines.Add('|---|---|')
            foreach ($outcome in $setupApiOutcomeRows) {
                $lines.Add(('| {0} | {1} |' -f
                    (ConvertTo-MarkdownCell $outcome.Signal),
                    (ConvertTo-MarkdownCell $outcome.Detail)))
            }
            $lines.Add('')
        }

        if ($setupApiDeviceInstallRows.Count -gt 0) {
            $lines.Add('### SetupAPI Applied Device Configurations')
            $lines.Add('')
            $lines.Add('| Device ID | Published INF | Original INF | Class | Newly staged | Configuration | Actions | PnP result |')
            $lines.Add('|---|---|---|---|---|---|---|---|')
            foreach ($installRow in $setupApiDeviceInstallRows) {
                $lines.Add(('| `{0}` | `{1}` | `{2}` | {3} | `{4}` | {5} | {6} | `{7}` |' -f
                    (ConvertTo-MarkdownCell $installRow.DeviceID),
                    (ConvertTo-MarkdownCell $installRow.PublishedName),
                    (ConvertTo-MarkdownCell $installRow.OriginalName),
                    (ConvertTo-MarkdownCell $installRow.ClassName),
                    (ConvertTo-MarkdownCell $installRow.IsNewlyStaged),
                    (ConvertTo-MarkdownCell $installRow.Configuration),
                    (ConvertTo-MarkdownCell $installRow.Actions),
                    (ConvertTo-MarkdownCell $installRow.ExitStatus)))
            }
            $lines.Add('')
        }

        if ($payloadFiles.Count -gt 0 -and $Preview.InfCount -eq 0) {
            $lines.Add('### Non-INF Payload Files')
            $lines.Add('')
            $lines.Add('| Type | File | Size | Product | Version | Manufacturer |')
            $lines.Add('|---|---|---:|---|---|---|')
            foreach ($payloadFile in @($payloadFiles | Select-Object -First 20)) {
                $productName = [string](Get-TraceObjectValue $payloadFile 'ProductName')
                if ([string]::IsNullOrWhiteSpace($productName)) { $productName = [string](Get-TraceObjectValue $payloadFile 'MsiProductName') }
                $productVersion = [string](Get-TraceObjectValue $payloadFile 'ProductVersion')
                if ([string]::IsNullOrWhiteSpace($productVersion)) { $productVersion = [string](Get-TraceObjectValue $payloadFile 'MsiProductVersion') }
                $manufacturer = [string](Get-TraceObjectValue $payloadFile 'Manufacturer')
                if ([string]::IsNullOrWhiteSpace($manufacturer)) { $manufacturer = [string](Get-TraceObjectValue $payloadFile 'MsiManufacturer') }
                $lines.Add(('| {0} | `{1}` | {2} | {3} | `{4}` | {5} |' -f
                    (ConvertTo-MarkdownCell $payloadFile.Type),
                    (ConvertTo-MarkdownCell $payloadFile.RelativePath),
                    (ConvertTo-MarkdownCell $payloadFile.Length),
                    (ConvertTo-MarkdownCell $productName),
                    (ConvertTo-MarkdownCell $productVersion),
                    (ConvertTo-MarkdownCell $manufacturer)))
            }
            if ($payloadFiles.Count -gt 20) {
                $lines.Add(('| ... | `{0} more files` |  |  |  |  |' -f ($payloadFiles.Count - 20)))
            }
            $lines.Add('')
        }

        if ($setupApiDriverNodeRows.Count -gt 0) {
            $lines.Add('### SetupAPI Selected Driver Stack')
            $lines.Add('')
            $lines.Add('| Node | Status | Device ID | Published INF | Original INF | Provider | Class | Date | Version | Rank | Extension ID | Configuration |')
            $lines.Add('|---|---|---|---|---|---|---|---|---|---|---|---|')
            foreach ($node in $setupApiDriverNodeRows) {
                $lines.Add(('| {0} | {1} | `{2}` | `{3}` | `{4}` | {5} | {6} | `{7}` | `{8}` | `{9}` | `{10}` | {11} |' -f
                    (ConvertTo-MarkdownCell $node.NodeKind),
                    (ConvertTo-MarkdownCell $node.Status),
                    (ConvertTo-MarkdownCell $node.DeviceID),
                    (ConvertTo-MarkdownCell $node.PublishedName),
                    (ConvertTo-MarkdownCell $node.OriginalName),
                    (ConvertTo-MarkdownCell $node.ProviderName),
                    (ConvertTo-MarkdownCell $node.ClassName),
                    (ConvertTo-MarkdownCell $node.DriverDate),
                    (ConvertTo-MarkdownCell $node.DriverVersion),
                    (ConvertTo-MarkdownCell $node.DriverRank),
                    (ConvertTo-MarkdownCell $node.ExtensionId),
                    (ConvertTo-MarkdownCell $node.Configuration)))
            }
            $lines.Add('')
        }

        if ($matchedActiveDrivers.Count -gt 0) {
            $lines.Add('### Current Active Drivers For Matched Devices')
            $lines.Add('')
            $lines.Add('| Device | Active published INF | Active original INF | Provider | Date | Version |')
            $lines.Add('|---|---|---|---|---|---|')
            foreach ($activeDriver in $matchedActiveDrivers) {
                $lines.Add(('| {0} | `{1}` | `{2}` | {3} | `{4}` | `{5}` |' -f
                    (ConvertTo-MarkdownCell $activeDriver.DeviceName),
                    (ConvertTo-MarkdownCell $activeDriver.ActivePublishedName),
                    (ConvertTo-MarkdownCell $activeDriver.ActiveOriginalName),
                    (ConvertTo-MarkdownCell $activeDriver.ActiveProvider),
                    (ConvertTo-MarkdownCell $activeDriver.ActiveDate),
                    (ConvertTo-MarkdownCell $activeDriver.ActiveVersion)))
            }
            $lines.Add('')
        }

        if ($packageActiveComparisonRows.Count -gt 0) {
            $lines.Add('### Package vs Active Same-INF Comparison')
            $lines.Add('')
            $lines.Add('| Device | Package INF | Package date/version | Active INF | Active date/version | Result | Basis |')
            $lines.Add('|---|---|---|---|---|---|---|')
            foreach ($comparison in $packageActiveComparisonRows) {
                $packageText = '{0} / {1}' -f $comparison.PackageDate, $comparison.PackageVersion
                $activeText = '{0} / {1}' -f $comparison.ActiveDate, $comparison.ActiveVersion
                $lines.Add(('| {0} | `{1}` | `{2}` | `{3}` | `{4}` | **{5}** | {6} |' -f
                    (ConvertTo-MarkdownCell $comparison.DeviceName),
                    (ConvertTo-MarkdownCell $comparison.PackageInf),
                    (ConvertTo-MarkdownCell $packageText),
                    (ConvertTo-MarkdownCell $comparison.ActivePublishedInf),
                    (ConvertTo-MarkdownCell $activeText),
                    (ConvertTo-MarkdownCell $comparison.Relationship),
                    (ConvertTo-MarkdownCell $comparison.ComparisonBasis)))
            }
            $lines.Add('')
        }

        if ($packageImpactRows.Count -gt 0) {
            $lines.Add('### Staged Package Impact')
            $lines.Add('')
            $lines.Add('| Staged published INF | Original INF | Staged date | Staged version | Status | Active evidence |')
            $lines.Add('|---|---|---|---|---|---|')
            foreach ($impact in $packageImpactRows) {
                $lines.Add(('| `{0}` | `{1}` | `{2}` | `{3}` | {4} | {5} |' -f
                    (ConvertTo-MarkdownCell $impact.PublishedName),
                    (ConvertTo-MarkdownCell $impact.OriginalName),
                    (ConvertTo-MarkdownCell $impact.StagedDate),
                    (ConvertTo-MarkdownCell $impact.StagedVersion),
                    (ConvertTo-MarkdownCell $impact.Status),
                    (ConvertTo-MarkdownCell $impact.ActiveEvidence)))
            }
            $lines.Add('')
        }

        if (@($Diff.AddedPublishedDrivers).Count -gt 0) {
            $lines.Add('### New Published Drivers Raw List')
            $lines.Add('')
            $lines.Add('| Published | Original | Provider | Class | Version |')
            $lines.Add('|---|---|---|---|---|')
            foreach ($driver in @($Diff.AddedPublishedDrivers)) {
                $lines.Add(('| `{0}` | `{1}` | {2} | {3} | `{4}` |' -f
                    (ConvertTo-MarkdownCell $driver.PublishedName),
                    (ConvertTo-MarkdownCell $driver.OriginalName),
                    (ConvertTo-MarkdownCell $driver.ProviderName),
                    (ConvertTo-MarkdownCell $driver.ClassName),
                    (ConvertTo-MarkdownCell $driver.DriverVersion)))
            }
            $lines.Add('')
        }

        if (@($Diff.ChangedSignedDrivers).Count -gt 0) {
            $lines.Add('### Changed Active Drivers')
            $lines.Add('')
            $lines.Add('| Device | Before | After |')
            $lines.Add('|---|---|---|')
            foreach ($driver in @($Diff.ChangedSignedDrivers)) {
                $beforeText = '{0} / {1}' -f $driver.BeforeInf, $driver.BeforeVersion
                $afterText = '{0} / {1}' -f $driver.AfterInf, $driver.AfterVersion
                $lines.Add(('| {0} | `{1}` | `{2}` |' -f (ConvertTo-MarkdownCell $driver.DeviceName), (ConvertTo-MarkdownCell $beforeText), (ConvertTo-MarkdownCell $afterText)))
            }
            $lines.Add('')
        }

        if (@($Diff.AddedSignedDrivers).Count -gt 0) {
            $lines.Add('### Added Active Driver Bindings')
            $lines.Add('')
            $lines.Add('| Device | Published INF | Provider | Date | Version |')
            $lines.Add('|---|---|---|---|---|')
            foreach ($driver in @($Diff.AddedSignedDrivers)) {
                $lines.Add(('| {0} | `{1}` | {2} | `{3}` | `{4}` |' -f
                    (ConvertTo-MarkdownCell $driver.DeviceName),
                    (ConvertTo-MarkdownCell $driver.InfName),
                    (ConvertTo-MarkdownCell $driver.DriverProviderName),
                    (ConvertTo-MarkdownCell (Format-DriverDate $driver.DriverDate)),
                    (ConvertTo-MarkdownCell $driver.DriverVersion)))
            }
            $lines.Add('')
        }

        if (@($Diff.RemovedSignedDrivers).Count -gt 0) {
            $lines.Add('### Removed Active Driver Bindings')
            $lines.Add('')
            $lines.Add('| Device | Published INF | Provider | Date | Version |')
            $lines.Add('|---|---|---|---|---|')
            foreach ($driver in @($Diff.RemovedSignedDrivers)) {
                $lines.Add(('| {0} | `{1}` | {2} | `{3}` | `{4}` |' -f
                    (ConvertTo-MarkdownCell $driver.DeviceName),
                    (ConvertTo-MarkdownCell $driver.InfName),
                    (ConvertTo-MarkdownCell $driver.DriverProviderName),
                    (ConvertTo-MarkdownCell (Format-DriverDate $driver.DriverDate)),
                    (ConvertTo-MarkdownCell $driver.DriverVersion)))
            }
            $lines.Add('')
        }
    }

    $lines.Add('## Raw Evidence Files')
    $lines.Add('')
    $lines.Add('- `package-preview.json`')
    if (Test-Path -LiteralPath (Join-Path $OutputDirectory 'extraction-manifest.json')) {
        $lines.Add('- `extraction-manifest.json`')
    }
    $lines.Add('- `before.snapshot.json`')
    if ($InstallerWasRun) {
        $lines.Add('- `after.snapshot.json`')
        $lines.Add('- `diff.json`')
        $lines.Add('- `setupapi.delta.log`')
        if ($null -ne $RunMetadata) { $lines.Add('- `run-metadata.json`') }
    }
    $lines.Add('')
    $lines.Add('## Note')
    $lines.Add('')
    $lines.Add('This tool is an evidence tracer, not an install recommendation engine. A package can be staged without becoming active, and an Extension INF can install without changing the visible Device Manager Driver tab.')

    Set-Content -LiteralPath $reportPath -Value $lines -Encoding UTF8
    return $reportPath
}

if ($PSCmdlet.ParameterSetName -eq 'PostReboot') {
    $postRebootScript = Join-Path $PSScriptRoot 'Invoke-DriverPackagePostRebootAudit.ps1'
    if (-not (Test-Path -LiteralPath $postRebootScript)) {
        throw "Missing post-reboot audit helper: $postRebootScript"
    }
    & $postRebootScript -TraceDirectory $PostRebootTraceDirectory -PauseAtEnd:$PauseAtEnd
    return
}

if ($PSCmdlet.ParameterSetName -eq 'Regenerate') {
    $outputDirectory = (Resolve-Path -LiteralPath $RegenerateTraceDirectory).Path
    $previewPath = Join-Path $outputDirectory 'package-preview.json'
    $beforePath = Join-Path $outputDirectory 'before.snapshot.json'
    $afterPath = Join-Path $outputDirectory 'after.snapshot.json'
    $diffPath = Join-Path $outputDirectory 'diff.json'
    $setupApiDeltaPath = Join-Path $outputDirectory 'setupapi.delta.log'
    $runMetadataPath = Join-Path $outputDirectory 'run-metadata.json'
    $extractionManifestPath = Join-Path $outputDirectory 'extraction-manifest.json'

    if (-not (Test-Path -LiteralPath $previewPath)) { throw "Missing package preview: $previewPath" }
    if (-not (Test-Path -LiteralPath $beforePath)) { throw "Missing before snapshot: $beforePath" }

    $preview = Get-Content -LiteralPath $previewPath -Raw | ConvertFrom-Json
    $previewInstallerPath = [string](Get-TraceObjectValue -InputObject $preview -Name 'InstallerPath')
    $storedExtractionManifest = Get-TraceObjectValue -InputObject $preview -Name 'Extraction'
    if (Test-Path -LiteralPath $extractionManifestPath) {
        $storedExtractionManifest = Get-Content -LiteralPath $extractionManifestPath -Raw | ConvertFrom-Json
    }
    $storedPayloadRoot = [string](Get-TraceObjectValue -InputObject $storedExtractionManifest -Name 'PayloadRoot')
    if (-not [string]::IsNullOrWhiteSpace($previewInstallerPath) -and (Test-Path -LiteralPath $previewInstallerPath)) {
        $preview = New-PackagePreview -PackagePath $previewInstallerPath -OutputDirectory $outputDirectory -ExtractedRootOverride $storedPayloadRoot -ExtractionManifest $storedExtractionManifest
    } else {
        Write-Host "Using stored package preview because installer path is unavailable: $previewInstallerPath" -ForegroundColor Yellow
    }

    $before = Get-Content -LiteralPath $beforePath -Raw | ConvertFrom-Json
    $after = $null
    $diff = $null
    $setupApiDelta = ''
    $runMetadata = $null

    if (Test-Path -LiteralPath $afterPath) {
        $after = Get-Content -LiteralPath $afterPath -Raw | ConvertFrom-Json
    }
    if (Test-Path -LiteralPath $setupApiDeltaPath) {
        $setupApiDelta = Get-Content -LiteralPath $setupApiDeltaPath -Raw
    }
    if (Test-Path -LiteralPath $runMetadataPath) {
        $runMetadata = Get-Content -LiteralPath $runMetadataPath -Raw | ConvertFrom-Json
    }
    if ($null -ne $after) {
        $diff = Compare-TraceSnapshots -Before $before -After $after -SetupApiDelta $setupApiDelta
        $diff | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $diffPath -Encoding UTF8
    }

    $reportPath = New-MarkdownReport -Preview $preview -Before $before -After $after -Diff $diff -RunMetadata $runMetadata -OutputDirectory $outputDirectory -InstallerWasRun ($null -ne $after)
    Write-Host "Regenerated trace report: $reportPath" -ForegroundColor Green
    return
}

$resolvedInstaller = (Resolve-Path -LiteralPath $InstallerPath).Path
$installerItem = Get-Item -LiteralPath $resolvedInstaller
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$traceRoot = Join-Path $repoRoot '.devicecheck-data\driver-package-traces'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeName = ConvertTo-SafeFileName -Text ([System.IO.Path]::GetFileNameWithoutExtension($installerItem.Name))
$outputDirectory = Join-Path $traceRoot "$stamp-$safeName"
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

Write-TraceTitle 'DeviceCheck Driver Package Impact Trace'
Write-Host "Package : $resolvedInstaller"
Write-Host "Output  : $outputDirectory"
Write-Host "Admin   : $(Get-IsAdministrator)"
Write-Host "SafeMode: $((Get-SafeModeState).IsLikelySafeMode)"
Write-Host "Extract : $ExtractionMode (max depth $MaxExtractionDepth)"

try {
    $extractionResult = Invoke-TraceDriverPackagePayloadExtraction -InstallerPath $resolvedInstaller -OutputDirectory $outputDirectory -RepoRoot $repoRoot -Mode $ExtractionMode -ForceReextract:$ForceReextract -MaxDepth $MaxExtractionDepth -PromptForExtendedExtraction:$PromptForExtendedExtraction
    $preview = New-PackagePreview -PackagePath $resolvedInstaller -OutputDirectory $outputDirectory -ExtractedRootOverride ([string]$extractionResult.PayloadRoot) -ExtractionManifest $extractionResult.Manifest
    $before = New-DriverTraceSnapshot -Name 'before' -OutputDirectory $outputDirectory
} catch {
    Write-Host ''
    Write-Host 'Trace failed during preview/before snapshot.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($_.InvocationInfo) {
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkRed
    }
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    }
    throw
}

$installerWasRun = $false
$after = $null
$diff = $null
$runMetadata = $null

if (-not $PreviewOnly) {
    if (-not $RunInstaller) {
        Write-TraceSection 'Run installer?'
        Write-Host 'Preview and before snapshot are done.' -ForegroundColor Green
        Write-Host 'Type Y to run the installer and capture after/diff, or anything else to stop here.' -ForegroundColor Yellow
        $answer = Read-Host 'Run installer now'
        if ($answer -match '^(y|yes)$') {
            $RunInstaller = $true
        }
    }

    if ($RunInstaller) {
        if (-not (Get-IsAdministrator)) {
            throw 'Running the installer trace requires an elevated PowerShell session.'
        }

        Write-TraceSection 'Running installer'
        $beforeSetupApiMarker = $before.SetupApiMarker
        $installerStartedAt = Get-Date
        $process = Start-Process -FilePath $resolvedInstaller -Wait -PassThru
        $installerExitedAt = Get-Date
        $runMetadata = [pscustomobject]@{
            InstallerPath = $resolvedInstaller
            InstallerStartedAt = $installerStartedAt.ToString('o')
            InstallerExitedAt = $installerExitedAt.ToString('o')
            InstallerExitCode = $process.ExitCode
            InstallerExitInterpretation = Get-InstallerExitCodeInterpretation -ExitCode $process.ExitCode
            AfterSnapshotCapturedAt = ''
        }
        Save-JsonFile -Data $runMetadata -Path (Join-Path $outputDirectory 'run-metadata.json')
        Write-Host "Installer process exited with code: $($process.ExitCode)" -ForegroundColor Cyan
        Write-Host "Interpretation: $($runMetadata.InstallerExitInterpretation)" -ForegroundColor Cyan
        Write-Host 'If the installer spawned a child UI/process, wait until it is fully finished before continuing.' -ForegroundColor Yellow
        [void](Read-Host 'Press Enter to capture after snapshot')

        $after = New-DriverTraceSnapshot -Name 'after' -OutputDirectory $outputDirectory
        $runMetadata.AfterSnapshotCapturedAt = (Get-Date).ToString('o')
        Save-JsonFile -Data $runMetadata -Path (Join-Path $outputDirectory 'run-metadata.json')
        $setupApiDelta = Get-SetupApiDeltaText -BeforeMarker $beforeSetupApiMarker
        $setupApiDeltaPath = Join-Path $outputDirectory 'setupapi.delta.log'
        Set-Content -LiteralPath $setupApiDeltaPath -Value $setupApiDelta -Encoding UTF8
        $diff = Compare-TraceSnapshots -Before $before -After $after -SetupApiDelta $setupApiDelta
        Save-JsonFile -Data $diff -Path (Join-Path $outputDirectory 'diff.json')
        $installerWasRun = $true

        Write-TraceSection 'Actual changes'
        [pscustomobject]@{
            NewPublishedDrivers = @($diff.AddedPublishedDrivers).Count
            NewInfFiles = @($diff.AddedInfFiles).Count
            NewDriverStoreFolders = @($diff.AddedDriverStoreFolders).Count
            UpdatedActiveDriverBindings = @($diff.ChangedSignedDrivers).Count
            AddedActiveDriverBindings = @($diff.AddedSignedDrivers).Count
            RemovedActiveDriverBindings = @($diff.RemovedSignedDrivers).Count
            SetupApiDeltaLength = $diff.SetupApiDeltaLength
        } | Format-List
    }
}

$reportPath = New-MarkdownReport -Preview $preview -Before $before -After $after -Diff $diff -RunMetadata $runMetadata -OutputDirectory $outputDirectory -InstallerWasRun $installerWasRun

Write-TraceSection 'Report'
Write-Host "Human report: $reportPath" -ForegroundColor Green
Write-Host "Raw evidence : $outputDirectory" -ForegroundColor Green

if ($PauseAtEnd) {
    [void](Read-Host 'Press Enter to close')
}
