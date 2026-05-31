#requires -version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load the TUI Blueprint (using Invoke-Expression to inherit script-scoped variables)
$blueprintPath = Join-Path -Path $PSScriptRoot -ChildPath 'PS_UI_Blueprint.psm1'
if (-not (Test-Path -LiteralPath $blueprintPath)) {
    throw "Required UI Blueprint not found at: $blueprintPath"
}
Invoke-Expression (Get-Content -LiteralPath $blueprintPath -Raw)

# Initialize Host Settings
Initialize-TuiHost

# Cache Class GUID to Friendly Name registry mappings
Write-Host "Caching system device classes..." -ForegroundColor Cyan
$classMap = @{}
$script:ActiveSearches = [ordered]@{}
$script:EvidenceBatchQueue = [System.Collections.Generic.Queue[object]]::new()
$script:EvidenceBatchQueuedIds = [System.Collections.Generic.HashSet[string]]::new()
$script:EvidenceBatchState = $null
$script:EvidenceBatchMaxConcurrent = 4
$script:RootExpanded = $true
$script:DeviceCheckCacheRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'DeviceCheck'
if ([string]::IsNullOrWhiteSpace($script:DeviceCheckCacheRoot)) {
    $script:DeviceCheckCacheRoot = Join-Path -Path $env:TEMP -ChildPath 'DeviceCheck'
}

function Initialize-AvailableModels {
    $script:AvailableModels = [System.Collections.Generic.List[object]]::new()

    $csvPath = Join-Path -Path $PSScriptRoot -ChildPath 'data\google-ai-studio-rate-limits-only free.csv'
    $loadedFromCsv = $false

    if (Test-Path -LiteralPath $csvPath) {
        try {
            $csvData = Import-Csv -LiteralPath $csvPath
            # Filter rows where section is 'Models' and category is 'Text-out models' or it's Gemma in 'Other models'
            $filteredRows = $csvData | Where-Object {
                $_.section -eq 'Models' -and (
                    $_.category -eq 'Text-out models' -or
                    ($_.category -eq 'Other models' -and $_.model -like '*Gemma*')
                )
            }
            foreach ($row in $filteredRows) {
                if ([string]::IsNullOrWhiteSpace($row.model)) { continue }

                $apiName = if ($row.model -like '*Gemma*') {
                    if ($row.model -like '*26B*') { 'gemma-4-26b-a4b-it' } else { 'gemma-4-31b-it' }
                } else {
                    ($row.model -replace ' ', '-').ToLower()
                }

                # Check for duplicate API IDs
                $existing = $script:AvailableModels | Where-Object { $_.ApiId -eq $apiName }
                if ($null -ne $existing) { continue }

                $script:AvailableModels.Add([pscustomobject]@{
                    Provider     = 'Gemini'
                    FriendlyName = $row.model
                    ApiId        = $apiName
                    Selected     = ($apiName -eq 'gemini-3.1-flash-lite')
                    RpmLimit     = $row.rpm_limit
                    TpmLimit     = $row.tpm_limit
                    RpdLimit     = $row.rpd_limit
                })
            }
            if ($script:AvailableModels.Count -gt 0) {
                $loadedFromCsv = $true
            }
        } catch {
            # Fallback will run below
        }
    }

    if (-not $loadedFromCsv) {
        $fallbackModels = @(
            @{ Name = 'Gemini 3.1 Flash Lite'; Id = 'gemini-3.1-flash-lite'; Selected = $true; RPM = 15; TPM = 250000; RPD = 500 }
            @{ Name = 'Gemini 2.5 Flash'; Id = 'gemini-2.5-flash'; Selected = $false; RPM = 5; TPM = 250000; RPD = 20 }
            @{ Name = 'Gemini 3.5 Flash'; Id = 'gemini-3.5-flash'; Selected = $false; RPM = 5; TPM = 250000; RPD = 20 }
            @{ Name = 'Gemini 2.5 Flash Lite'; Id = 'gemini-2.5-flash-lite'; Selected = $false; RPM = 10; TPM = 250000; RPD = 20 }
            @{ Name = 'Gemini 3 Flash'; Id = 'gemini-3-flash'; Selected = $false; RPM = 5; TPM = 250000; RPD = 20 }
            @{ Name = 'Gemma 4 26B'; Id = 'gemma-4-26b-a4b-it'; Selected = $false; RPM = 15; TPM = 0; RPD = 1500 }
            @{ Name = 'Gemma 4 31B'; Id = 'gemma-4-31b-it'; Selected = $false; RPM = 15; TPM = 0; RPD = 1500 }
        )

        foreach ($m in $fallbackModels) {
            $script:AvailableModels.Add([pscustomobject]@{
                Provider     = 'Gemini'
                FriendlyName = $m.Name
                ApiId        = $m.Id
                Selected     = $m.Selected
                RpmLimit     = $m.RPM
                TpmLimit     = $m.TPM
                RpdLimit     = $m.RPD
            })
        }
    }

    # Add OpenRouter models
    $script:AvailableModels.Add([pscustomobject]@{
        Provider     = 'OpenRouter'
        FriendlyName = 'Nvidia Nemotron 3 Super 120B (Free)'
        ApiId        = 'nvidia/nemotron-3-super-120b-a12b:free'
        Selected     = $true
        RpmLimit     = ''
        TpmLimit     = ''
        RpdLimit     = ''
    })

    # Load persisted selection if exists
    $configPath = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'config.json'
    if (Test-Path -LiteralPath $configPath) {
        try {
            $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            if ($null -ne $config -and $config.SelectedModelIds) {
                $selectedIds = [System.Collections.Generic.HashSet[string]]::new([string[]]$config.SelectedModelIds, [System.StringComparer]::OrdinalIgnoreCase)
                foreach ($model in $script:AvailableModels) {
                    $model.Selected = $selectedIds.Contains($model.ApiId)
                }
            }
        } catch {
            # Fallback to default selection if config is corrupt
        }
    }
}

function Save-ModelSelection {
    try {
        if (-not (Test-Path -LiteralPath $script:DeviceCheckCacheRoot)) {
            $null = New-Item -ItemType Directory -Path $script:DeviceCheckCacheRoot -Force
        }
        $selectedIds = @(
            $script:AvailableModels | Where-Object { $_.Selected } | ForEach-Object { $_.ApiId }
        )
        $config = [pscustomobject]@{
            SelectedModelIds = $selectedIds
        }
        $configPath = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'config.json'
        $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
    } catch {
        # Silent fallback
    }
}

Initialize-AvailableModels

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

    $systemMakerModel = (@(
            $MachineEvidence.ComputerSystem.Manufacturer
            $MachineEvidence.ComputerSystem.Model
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
    if (-not [string]::IsNullOrWhiteSpace($systemMakerModel)) { $parts.Add($systemMakerModel) }

    if (-not [string]::IsNullOrWhiteSpace($MachineEvidence.BaseBoard.Product)) {
        $parts.Add("Board $($MachineEvidence.BaseBoard.Product)")
    }
    if (-not [string]::IsNullOrWhiteSpace($MachineEvidence.Processor.Name)) {
        $parts.Add($MachineEvidence.Processor.Name.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($MachineEvidence.OperatingSystem.Caption)) {
        $parts.Add($MachineEvidence.OperatingSystem.Caption)
    }
    if ($DeviceCount -gt 0 -or $CategoryCount -gt 0) {
        $parts.Add("$DeviceCount devices / $CategoryCount categories")
    }
    if ($null -ne $ElapsedMs) {
        $parts.Add("${ElapsedMs}ms")
    }

    return ($parts -join ' | ')
}

$script:MachineEvidence = Get-MachineEvidence
$script:MachineCacheRoot = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath "machines\$($script:MachineEvidence.MachineId)"
try { $null = New-Item -ItemType Directory -Path $script:MachineCacheRoot -Force } catch {}
$script:SystemScanMessage = "System: $(Get-MachineSummary -MachineEvidence $script:MachineEvidence)"

function Get-DeviceEvidenceCachePath {
    param([string]$InstanceId)

    $deviceHash = New-DeviceCheckHash -Text $InstanceId
    return (Join-Path -Path $script:MachineCacheRoot -ChildPath "devices\$deviceHash.json")
}

function New-AgentTracePath {
    param([string]$InstanceId)

    $deviceHash = New-DeviceCheckHash -Text $InstanceId
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    return (Join-Path -Path $script:MachineCacheRoot -ChildPath "agent-logs\$deviceHash-$stamp.jsonl")
}

function New-AgentCheckpointPath {
    param([string]$InstanceId)

    $deviceHash = New-DeviceCheckHash -Text $InstanceId
    return (Join-Path -Path $script:MachineCacheRoot -ChildPath "agent-state\$deviceHash.json")
}

function New-AgentToolCacheRoot {
    return (Join-Path -Path $script:MachineCacheRoot -ChildPath 'agent-tool-cache')
}

function Read-CachedDeviceEvidence {
    param([string]$InstanceId)

    $cachePath = Get-DeviceEvidenceCachePath -InstanceId $InstanceId
    if (-not (Test-Path -LiteralPath $cachePath)) { return $null }

    try {
        return (Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Format-UiValue {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$MaxLength = 90
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return '-' }
    $MaxLength = [Math]::Max(8, $MaxLength)
    if ($Text.Length -le $MaxLength) { return $Text }
    return ($Text.Substring(0, [Math]::Max(5, $MaxLength - 3)) + '...')
}

function Remove-AnsiSequence {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $withoutOsc = [regex]::Replace($Text, "$([char]27)\][^\a]*(\a|$([char]27)\\)", '')
    return [regex]::Replace($withoutOsc, "$([char]27)\[[0-9;?]*[A-Za-z]", '')
}

function Get-PrintableLength {
    param([AllowEmptyString()][string]$Text)

    return (Remove-AnsiSequence -Text $Text).Length
}

function Get-NotePropertyValue {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Format-PlainToWidth {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width
    )

    $Width = [Math]::Max(1, $Width)
    if ([string]::IsNullOrEmpty($Text)) { return (' ' * $Width) }
    if ($Text.Length -gt $Width) {
        if ($Width -le 1) { return $Text.Substring(0, 1) }
        return ($Text.Substring(0, [Math]::Max(1, $Width - 1)) + [char]0x2026)
    }
    return $Text.PadRight($Width)
}

function Format-AnsiToWidth {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width
    )

    $Width = [Math]::Max(1, $Width)
    $printableLength = Get-PrintableLength -Text $Text
    if ($printableLength -gt $Width) {
        return (Format-PlainToWidth -Text (Remove-AnsiSequence -Text $Text) -Width $Width)
    }
    return ($Text + (' ' * ($Width - $printableLength)))
}

function New-SelectedLine {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width
    )

    return "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)$(Format-PlainToWidth -Text (Remove-AnsiSequence -Text $Text) -Width $Width)$($_C.Reset)"
}

function New-SectionLine {
    param(
        [string]$Title,
        [int]$Width
    )

    $prefix = " $Title "
    $line = [string]::new([char]0x2500, [Math]::Max(0, $Width - $prefix.Length))
    return "$($_C.H1)$prefix$($_C.Dim)$line$($_C.Reset)"
}

function New-KeyValueLine {
    param(
        [string]$Key,
        [AllowEmptyString()][string]$Value,
        [int]$Width,
        [string]$ValueColor = $null
    )

    if (-not $ValueColor) { $ValueColor = $_C.White }
    $keyText = Format-PlainToWidth -Text $Key -Width 13
    $valueWidth = [Math]::Max(8, $Width - 17)
    $valueText = Format-UiValue -Text $Value -MaxLength $valueWidth
    return " $($_C.Dim)$keyText :$($_C.Reset) $ValueColor$valueText$($_C.Reset)"
}

function Get-CompactSystemStatus {
    param([AllowEmptyString()][string]$StatusText)

    if ([string]::IsNullOrWhiteSpace($StatusText)) { return '' }
    $text = $StatusText -replace '^System scan complete:\s*', ''
    $text = $text -replace '\s*\|\s*\d+ms(?=\s*\|)', ''
    return $text
}

function Get-ActiveEvidenceBatchCount {
    if ($null -eq $script:EvidenceBatchState) { return 0 }

    $batchId = $script:EvidenceBatchState.BatchId
    return @(
        $script:ActiveSearches.Values | Where-Object {
            (Get-NotePropertyValue -Object $_ -Name 'EvidenceBatchId') -eq $batchId
        }
    ).Count
}

function Get-EvidenceBatchStatusText {
    if ($null -eq $script:EvidenceBatchState) { return '' }

    $state = $script:EvidenceBatchState
    $activeCount = Get-ActiveEvidenceBatchCount
    $queuedCount = $script:EvidenceBatchQueue.Count
    $total = [Math]::Max(1, [int]$state.Total)
    $completed = [Math]::Min([int]$state.Completed, $total)
    $elapsed = [int]((Get-Date) - $state.StartedAt).TotalSeconds
    $barWidth = 18
    $filled = [Math]::Min($barWidth, [int][Math]::Floor(($completed / $total) * $barWidth))
    $bar = ('#' * $filled) + ('-' * ($barWidth - $filled))

    if ($queuedCount -eq 0 -and $activeCount -eq 0 -and $completed -ge $total) {
        return "Evidence complete: $($state.Label) [$bar] $completed/$total | ${elapsed}s"
    }

    return "Evidence scan: $($state.Label) [$bar] $completed/$total | active $activeCount | queued $queuedCount | ${elapsed}s"
}

function Complete-EvidenceBatchIfFinished {
    if ($null -eq $script:EvidenceBatchState) { return }
    if ($script:EvidenceBatchQueue.Count -gt 0) { return }
    if ((Get-ActiveEvidenceBatchCount) -gt 0) { return }

    $state = $script:EvidenceBatchState
    $total = [Math]::Max(0, [int]$state.Total)
    if ([int]$state.Completed -lt $total) { return }

    $elapsed = [int]((Get-Date) - $state.StartedAt).TotalSeconds
    $errorText = if ([int]$state.Errors -gt 0) { " | $($state.Errors) errors" } else { '' }
    $script:SystemScanMessage = "Evidence scan complete: $($state.Label) | $($state.Completed)/$total devices | ${elapsed}s$errorText | $(Get-Date -Format 'HH:mm:ss')"
    $script:EvidenceBatchState = $null
    $script:EvidenceBatchQueuedIds.Clear()
}

function Wrap-PlainText {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width,
        [int]$MaxLines = 6
    )

    $Width = [Math]::Max(8, $Width)
    $words = (Remove-AnsiSequence -Text $Text) -split '\s+'
    $lines = [System.Collections.Generic.List[string]]::new()
    $current = ''

    foreach ($word in $words) {
        if ([string]::IsNullOrWhiteSpace($word)) { continue }
        $candidate = if ($current) { "$current $word" } else { $word }
        if ($candidate.Length -gt $Width) {
            if ($current) { $lines.Add($current) }
            $current = $word
            if ($current.Length -gt $Width) {
                $lines.Add((Format-PlainToWidth -Text $current -Width $Width).TrimEnd())
                $current = ''
            }
        } else {
            $current = $candidate
        }
        if ($lines.Count -ge $MaxLines) { break }
    }

    if ($current -and $lines.Count -lt $MaxLines) { $lines.Add($current) }
    return $lines
}

function Convert-MarkdownResultToPlain {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $plain = $Text -replace '\*\*', ''
    $plain = $plain -replace '(?m)^\s{0,3}#{1,6}\s*', ''
    $plain = [regex]::Replace($plain, '\[([^\]]+)\]\((https?://[^)]+)\)', '$1 - $2')
    return $plain.Trim()
}

function Get-UrlsFromText {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $urls = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Text, 'https?://[^\s\]\)\}>"]+')) {
        $url = $match.Value.TrimEnd('.', ',', ';', ':')
        if (-not [string]::IsNullOrWhiteSpace($url) -and -not $urls.Contains($url)) {
            $urls.Add($url)
        }
    }
    return @($urls)
}

function New-TerminalHyperlink {
    param(
        [string]$Label,
        [string]$Url
    )

    $esc = [char]27
    $bel = [char]7
    return "$esc]8;;$Url$bel$Label$esc]8;;$bel"
}

function Add-WrappedDetailTextLines {
    param(
        [Parameter(Mandatory)]$Lines,
        [AllowEmptyString()][string]$Text,
        [int]$Width,
        [int]$MaxLines
    )

    $remaining = [Math]::Max(0, $MaxLines)
    if ($remaining -le 0 -or [string]::IsNullOrWhiteSpace($Text)) { return }

    $bodyWidth = [Math]::Max(8, $Width - 2)
    foreach ($paragraph in (($Text -replace "`r", '') -split "`n")) {
        if ($remaining -le 0) { break }
        if ([string]::IsNullOrWhiteSpace($paragraph)) {
            $lines.Add('')
            $remaining--
            continue
        }

        foreach ($line in (Wrap-PlainText -Text $paragraph -Width $bodyWidth -MaxLines $remaining)) {
            if ($remaining -le 0) { break }
            $lines.Add("$($_C.White)  $(Format-PlainToWidth -Text $line -Width $bodyWidth)$($_C.Reset)")
            $remaining--
        }
    }
}

try {
    Get-ChildItem -Path "HKLM:\System\CurrentControlSet\Control\Class" -ErrorAction SilentlyContinue | ForEach-Object {
        $g = $_.PSChildName.ToLower()
        $n = $_.GetValue("")
        if ([string]::IsNullOrWhiteSpace($n)) {
            $n = $_.GetValue("Class")
        }
        if (-not [string]::IsNullOrWhiteSpace($n)) {
            $classMap[$g] = $n
        }
    }
} catch {}

# Load PnP devices and build categories
function Get-DeviceCategories {
    param([switch]$Quiet)

    if (-not $Quiet) {
        Write-Host "Detecting connected PnP hardware..." -ForegroundColor Cyan
    }
    $pnpDevices = Get-PnpDevice -PresentOnly

    $grouped = @{}
    foreach ($dev in $pnpDevices) {
        $guid = if ($dev.ClassGuid) { $dev.ClassGuid.ToLower() } else { "" }
        $classKey = if (-not [string]::IsNullOrWhiteSpace($dev.Class)) { $dev.Class } elseif ($classMap.ContainsKey($guid)) { $classMap[$guid] } else { 'Other devices' }
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

function Invoke-SystemScan {
    param([switch]$Quiet)

    $scanStarted = Get-Date
    $script:MachineEvidence = Get-MachineEvidence
    $script:MachineCacheRoot = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath "machines\$($script:MachineEvidence.MachineId)"
    try { $null = New-Item -ItemType Directory -Path $script:MachineCacheRoot -Force } catch {}

    $script:categories = Get-DeviceCategories -Quiet:$Quiet
    $deviceCount = 0
    foreach ($category in $script:categories) {
        $deviceCount += @($category.Devices).Count
    }

    $elapsedMs = [int]((Get-Date) - $scanStarted).TotalMilliseconds
    $summary = Get-MachineSummary -MachineEvidence $script:MachineEvidence -DeviceCount $deviceCount -CategoryCount @($script:categories).Count -ElapsedMs $elapsedMs
    $script:SystemScanMessage = "System scan complete: $summary | $(Get-Date -Format 'HH:mm:ss')"
}

# Helper to generate visible rows list
function Update-VisibleRows {
    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add([PSCustomObject]@{
        Type       = 'Root'
        Name       = Get-MachineDisplayName -MachineEvidence $script:MachineEvidence
        IsExpanded = $script:RootExpanded
        Ref        = $script:MachineEvidence
    })

    if (-not $script:RootExpanded) {
        return $rows
    }

    foreach ($cat in $categories) {
        $rows.Add([PSCustomObject]@{
            Type       = 'Category'
            Name       = $cat.Name
            IsExpanded = $cat.IsExpanded
            Ref        = $cat
        })
        if ($cat.IsExpanded) {
            $devicesCount = $cat.Devices.Count
            for ($i = 0; $i -lt $devicesCount; $i++) {
                $d = $cat.Devices[$i]
                $isLast = ($i -eq ($devicesCount - 1))
                $rows.Add([PSCustomObject]@{
                    Type      = 'Device'
                    Name      = $d.FriendlyName
                    Class     = $d.Class
                    IsLast    = $isLast
                    IsProblem = $d.IsProblem
                    Ref       = $d
                })

                # Check search result sub-nodes
                if ($null -ne $d.SearchStatus) {
                    if ($d.SearchStatus -eq 'Searching') {
                        $rows.Add([PSCustomObject]@{
                            Type         = 'Status'
                            Name         = if ($script:CurrentLoadingText) { $script:CurrentLoadingText } else { 'Searching databases & web...' }
                            ParentIsLast = $isLast
                            ParentDevice = $d
                        })
                    }
                    elseif ($d.SearchStatus -eq 'Error') {
                        $rows.Add([PSCustomObject]@{
                            Type         = 'Status'
                            Name         = 'Search failed'
                            ParentIsLast = $isLast
                            ParentDevice = $d
                        })
                    }
                    elseif ($d.SearchStatus -eq 'Done') {
                        $resCount = $d.SearchResults.Count
                        for ($j = 0; $j -lt $resCount; $j++) {
                            $isLastRes = ($j -eq ($resCount - 1))
                            $rows.Add([PSCustomObject]@{
                                Type         = 'Result'
                                Name         = $d.SearchResults[$j]
                                IsLastResult = $isLastRes
                                ParentIsLast = $isLast
                                ParentDevice = $d
                            })
                        }
                    }
                }
            }
        }
    }
    return $rows
}

function Get-DeviceProblemDescription {
    param([int]$ErrorCode)

    switch ($ErrorCode) {
        0  { "Working properly" }
        10 { "Device cannot start (CM_PROB_FAILED_START)" }
        21 { "Device has been uninstalled (CM_PROB_WILL_BE_REMOVED)" }
        22 { "Device is disabled (CM_PROB_DISABLED)" }
        28 { "Drivers not installed (CM_PROB_FAILED_INSTALL)" }
        43 { "Device reported problems (CM_PROB_FAILED_POST_START)" }
        default { "Unknown problem status" }
    }
}

function Set-AllCategoriesExpanded {
    param([bool]$Expanded)

    $script:RootExpanded = $Expanded
    foreach ($category in $script:categories) {
        $category.IsExpanded = $Expanded
    }
}

function Expand-SelectedNode {
    param($Row)

    if ($null -eq $Row) { return }
    if ($Row.Type -eq 'Root') {
        Set-AllCategoriesExpanded -Expanded $true
    } elseif ($Row.Type -eq 'Category') {
        $Row.Ref.IsExpanded = $true
    }
}

function Collapse-SelectedNode {
    param($Row)

    if ($null -eq $Row) { return }
    if ($Row.Type -eq 'Root') {
        Set-AllCategoriesExpanded -Expanded $false
    } elseif ($Row.Type -eq 'Category') {
        $Row.Ref.IsExpanded = $false
    } elseif ($Row.Type -eq 'Device') {
        $parentCatName = $Row.Class
        $parentIndex = -1
        for ($j = 0; $j -lt $script:visibleRows.Count; $j++) {
            if ($script:visibleRows[$j].Type -eq 'Category' -and $script:visibleRows[$j].Name -eq $parentCatName) {
                $parentIndex = $j
                break
            }
        }
        if ($parentIndex -ne -1) {
            $script:selectedIndex = $parentIndex
            $script:visibleRows[$parentIndex].Ref.IsExpanded = $false
        }
    }
}

function Get-TreeDisplayLine {
    param(
        [Parameter(Mandatory)]$Row,
        [bool]$IsSelected,
        [int]$Width
    )

    $plainText = ''
    $ansiText = ''

    if ($Row.Type -eq 'Root') {
        $icon = if ($Row.IsExpanded) { [char]0x25BC } else { [char]0x25B6 }
        $plainText = " $icon  $($Row.Name)"
        $ansiText = "$($_C.White)$plainText$($_C.Reset)"
    }
    elseif ($Row.Type -eq 'Category') {
        $icon = if ($Row.IsExpanded) { [char]0x25BC } else { [char]0x25B6 }
        $plainText = "   $icon  $($Row.Name)"
        $ansiText = "$($_C.White)$plainText$($_C.Reset)"
    }
    elseif ($Row.Type -eq 'Device') {
        $branch = if ($Row.IsLast) { "└── " } else { "├── " }
        $warning = if ($Row.IsProblem) { "[!] " } else { "" }
        $plainText = "       $branch$warning$($Row.Name) [$($Row.Class)]"
        if ($Row.IsProblem) {
            $ansiText = "$($_C.Dim)       $branch$($_C.Reset)$($_C.Warn)[!] $($_C.Reset)$($_C.White)$($Row.Name) $($_C.Dim)[$($Row.Class)]$($_C.Reset)"
        } else {
            $ansiText = "$($_C.Dim)       $branch$($_C.Reset)$($_C.White)$($Row.Name) $($_C.Dim)[$($Row.Class)]$($_C.Reset)"
        }
    }
    elseif ($Row.Type -eq 'Status') {
        $parentPrefix = if ($Row.ParentIsLast) { "            " } else { "       │    " }
        $plainText = "$parentPrefix└── [$($Row.Name)]"
        $ansiText = "$($_C.Dim)$parentPrefix└── $($_C.Reset)$($_C.Warn)[$($Row.Name)]$($_C.Reset)"
    }
    elseif ($Row.Type -eq 'Result') {
        $parentPrefix = if ($Row.ParentIsLast) { "            " } else { "       │    " }
        $text = [string]$Row.Name
        $isSubResult = $text.StartsWith('  ')
        if ($isSubResult) {
            $text = $text.Substring(2)
            $branch = if ($Row.IsLastResult) { "    └── " } else { "│   └── " }
        } else {
            $branch = if ($Row.IsLastResult) { "└── " } else { "├── " }
        }

        $plainText = "$parentPrefix$branch$text"
        if ($text -match '^(\[([^\]]+)\])(.*)$') {
            $tag = $Matches[1]
            $tagName = $Matches[2]
            $rest = $Matches[3]
            $tagColor = if ($tagName -like '*Error*') {
                $_C.Fail
            } elseif ($tagName -like '*Gemini*') {
                $_C.Info
            } elseif ($tagName -like '*OpenRouter*' -or $tagName -like '*nvidia*' -or $tagName -like '*nemotron*') {
                $_C.OK
            } elseif ($tagName -like '*Local*') {
                $_C.Gold
            } elseif ($tagName -like '*Web*') {
                $_C.Warn
            } else {
                $_C.Info
            }
            $ansiText = "$($_C.Dim)$parentPrefix$branch$($_C.Reset)$tagColor$tag$($_C.Reset)$($_C.White)$rest$($_C.Reset)"
        } else {
            $ansiText = "$($_C.Dim)$parentPrefix$branch$($_C.Reset)$($_C.White)$text$($_C.Reset)"
        }
    }

    if ($IsSelected) { return New-SelectedLine -Text $plainText -Width $Width }
    return Format-AnsiToWidth -Text $ansiText -Width $Width
}

function Add-AgentTraceLines {
    param(
        [Parameter(Mandatory)]$Lines,
        [AllowNull()]$ActiveSearch,
        [int]$Width,
        [int]$MaxLogLines = 10
    )

    if ($null -eq $ActiveSearch -or -not $ActiveSearch.UseAgent) { return }

    $lines.Add((New-SectionLine -Title 'Agent Activity' -Width $Width))
    $stateColor = switch ($ActiveSearch.AgentState) {
        'Done' { $_C.OK }
        'Error' { $_C.Fail }
        'PausedRateLimit' { $_C.Warn }
        'PausedBudget' { $_C.Warn }
        'Waiting' { $_C.Warn }
        default { $_C.Info }
    }
    $stateText = if ($ActiveSearch.AgentState) { $ActiveSearch.AgentState } else { 'Unknown' }
    $lines.Add((New-KeyValueLine -Key 'State' -Value $stateText -Width $Width -ValueColor $stateColor))
    if (-not [string]::IsNullOrWhiteSpace($ActiveSearch.AgentTracePath)) {
        $lines.Add((New-KeyValueLine -Key 'Log' -Value $ActiveSearch.AgentTracePath -Width $Width))
    }
    $checkpointPath = Get-NotePropertyValue -Object $ActiveSearch -Name 'AgentCheckpointPath'
    if (-not [string]::IsNullOrWhiteSpace($checkpointPath)) {
        $lines.Add((New-KeyValueLine -Key 'Checkpoint' -Value $checkpointPath -Width $Width))
    }

    if ($ActiveSearch.AgentLogs.Count -gt 0) {
        $logCount = $ActiveSearch.AgentLogs.Count
        $startIndex = [Math]::Max(0, $logCount - $MaxLogLines)
        for ($i = $startIndex; $i -lt $logCount; $i++) {
            $logLine = $ActiveSearch.AgentLogs[$i]
            $lines.Add("  $($_C.Dim)$(Format-PlainToWidth -Text $logLine -Width ([Math]::Max(1, $Width - 4)))$($_C.Reset)")
        }
    } elseif ($ActiveSearch.AgentState -eq 'Waiting') {
        $lines.Add("  $($_C.Warn)Waiting for local evidence collection...$($_C.Reset)")
    } elseif ($ActiveSearch.AgentState -eq 'Searching') {
        $lines.Add("  $($_C.Warn)Waiting for first Gemini/tool event...$($_C.Reset)")
    }

    if ($ActiveSearch.AgentState -eq 'Done') {
        $lines.Add("  $($_C.OK)Agent finished. Final answer is below/in this details pane.$($_C.Reset)")
    } elseif ($ActiveSearch.AgentState -in @('PausedRateLimit', 'PausedBudget')) {
        $pauseLines = Wrap-PlainText -Text $ActiveSearch.AgentVal -Width ([Math]::Max(8, $Width - 4)) -MaxLines 3
        foreach ($pauseLine in $pauseLines) {
            $lines.Add("  $($_C.Warn)$(Format-PlainToWidth -Text $pauseLine -Width ([Math]::Max(1, $Width - 4)))$($_C.Reset)")
        }
    } elseif ($ActiveSearch.AgentState -eq 'Error') {
        $errorLines = Wrap-PlainText -Text $ActiveSearch.AgentVal -Width ([Math]::Max(8, $Width - 4)) -MaxLines 3
        foreach ($errorLine in $errorLines) {
            $lines.Add("  $($_C.Fail)$(Format-PlainToWidth -Text $errorLine -Width ([Math]::Max(1, $Width - 4)))$($_C.Reset)")
        }
    }
}

function Get-DetailDisplayLines {
    param(
        [Parameter(Mandatory)]$SelectedRow,
        [int]$Width,
        [int]$MaxLines
    )

    $lines = [System.Collections.Generic.List[string]]::new()

    if ($SelectedRow.Type -eq 'Root') {
        $machine = $SelectedRow.Ref
        $lines.Add((New-SectionLine -Title 'Computer Info' -Width $Width))
        $lines.Add((New-KeyValueLine -Key 'System Name' -Value (Get-MachineDisplayName -MachineEvidence $machine) -Width $Width))
        $lines.Add((New-KeyValueLine -Key 'OS' -Value "$($machine.OperatingSystem.Caption) $($machine.OperatingSystem.Version) Build $($machine.OperatingSystem.BuildNumber)" -Width $Width))
        $lines.Add((New-KeyValueLine -Key 'System' -Value "$($machine.ComputerSystem.Manufacturer) $($machine.ComputerSystem.Model) [$($machine.ComputerSystem.SystemType)]" -Width $Width))
        $lines.Add((New-KeyValueLine -Key 'BaseBoard' -Value "$($machine.BaseBoard.Manufacturer) $($machine.BaseBoard.Product)" -Width $Width))
        $lines.Add((New-KeyValueLine -Key 'Processor' -Value $machine.Processor.Name -Width $Width))
        $lines.Add((New-KeyValueLine -Key 'BIOS' -Value "$($machine.BIOS.Manufacturer) $($machine.BIOS.SMBIOSBIOSVersion)" -Width $Width))

        $allDevices = @($script:categories | ForEach-Object { @($_.Devices) })
        if ($allDevices.Count -gt 0) {
            $activeEvidenceCount = @(
                $allDevices | Where-Object {
                    $script:ActiveSearches.Contains($_.InstanceId) -and
                    $script:ActiveSearches[$_.InstanceId].EvidenceState -eq 'Searching'
                }
            ).Count
            $cachedEvidenceCount = @(
                $allDevices | Where-Object {
                    [bool](Get-NotePropertyValue -Object $_ -Name 'EvidenceCached')
                }
            ).Count
            $queuedEvidenceCount = @(
                $allDevices | Where-Object {
                    $script:EvidenceBatchQueuedIds.Contains($_.InstanceId)
                }
            ).Count
            $evidenceText = if ($activeEvidenceCount -gt 0 -or $queuedEvidenceCount -gt 0) {
                "$activeEvidenceCount scanning / $queuedEvidenceCount queued / $cachedEvidenceCount cached"
            } else {
                "$cachedEvidenceCount cached"
            }
            $evidenceColor = if ($activeEvidenceCount -gt 0 -or $queuedEvidenceCount -gt 0) { $_C.Warn } elseif ($cachedEvidenceCount -gt 0) { $_C.OK } else { $_C.Dim }
            $lines.Add((New-KeyValueLine -Key 'Evidence' -Value $evidenceText -Width $Width -ValueColor $evidenceColor))
        }
    }
    elseif ($SelectedRow.Type -eq 'Device') {
        $lines.Add((New-SectionLine -Title 'Device Properties' -Width $Width))
        $lines.Add((New-KeyValueLine -Key 'FriendlyName' -Value $SelectedRow.Ref.FriendlyName -Width $Width))
        $lines.Add((New-KeyValueLine -Key 'InstanceId' -Value $SelectedRow.Ref.InstanceId -Width $Width))

        $errCode = [int]$SelectedRow.Ref.ConfigManagerErrorCode
        $errDesc = Get-DeviceProblemDescription -ErrorCode $errCode
        $statusColor = if ($errCode -eq 0) { $_C.OK } else { $_C.Fail }
        $statusValue = if ($errCode -eq 0) { "OK ($errDesc)" } else { "Error (Code ${errCode}: $errDesc)" }
        $lines.Add((New-KeyValueLine -Key 'Status' -Value $statusValue -Width $Width -ValueColor $statusColor))

        $activeSearch = if ($script:ActiveSearches.Contains($SelectedRow.Ref.InstanceId)) { $script:ActiveSearches[$SelectedRow.Ref.InstanceId] } else { $null }
        if ($null -ne $activeSearch -and $activeSearch.EvidenceState -eq 'Searching') {
            $lines.Add((New-KeyValueLine -Key 'Evidence' -Value 'Collecting local evidence...' -Width $Width -ValueColor $_C.Warn))
        } elseif ($null -ne $activeSearch -and $activeSearch.EvidenceState -eq 'Error') {
            $lines.Add((New-KeyValueLine -Key 'Evidence' -Value "Error: $($activeSearch.EvidenceVal)" -Width $Width -ValueColor $_C.Fail))
        }

        $cachedEvidence = Read-CachedDeviceEvidence -InstanceId $SelectedRow.Ref.InstanceId
        if ($null -ne $cachedEvidence) {
            $capturedText = if ($cachedEvidence.CapturedAt) { $cachedEvidence.CapturedAt } else { 'unknown time' }
            if ($null -eq $activeSearch -or $activeSearch.EvidenceState -ne 'Searching') {
                $lines.Add((New-KeyValueLine -Key 'Evidence' -Value "Cached ($capturedText)" -Width $Width -ValueColor $_C.OK))
            }

            $importantProperties = $cachedEvidence.ImportantProperties
            $hardwareIds = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_HardwareIds'
            if ($hardwareIds) {
                $firstHardwareId = if ($hardwareIds -is [array]) { $hardwareIds[0] } else { $hardwareIds }
                $lines.Add((New-KeyValueLine -Key 'HardwareId' -Value $firstHardwareId -Width $Width))
            }

            $manufacturer = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_Manufacturer'
            if ($manufacturer) {
                $lines.Add((New-KeyValueLine -Key 'Manufacturer' -Value $manufacturer -Width $Width))
            }

            $compatibleIds = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_CompatibleIds'
            if ($compatibleIds) {
                $firstCompatibleId = if ($compatibleIds -is [array]) { $compatibleIds[0] } else { $compatibleIds }
                $lines.Add((New-KeyValueLine -Key 'CompatibleId' -Value $firstCompatibleId -Width $Width))
            }

            $service = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_Service'
            if ($service) {
                $lines.Add((New-KeyValueLine -Key 'Service' -Value $service -Width $Width))
            }

            if ($cachedEvidence.SignedDriver) {
                $driver = $cachedEvidence.SignedDriver
                $driverText = "$($driver.DriverProviderName) $($driver.DriverVersion) ($($driver.InfName))"
                $lines.Add((New-KeyValueLine -Key 'Driver' -Value $driverText -Width $Width))
            }

            $cachePath = Get-DeviceEvidenceCachePath -InstanceId $SelectedRow.Ref.InstanceId
            $lines.Add((New-KeyValueLine -Key 'Cache' -Value $cachePath -Width $Width))
        } elseif ($null -eq $activeSearch) {
            $lines.Add((New-KeyValueLine -Key 'Evidence' -Value 'Not scanned yet. Press E for local evidence or S for search.' -Width $Width -ValueColor $_C.Warn))
        }

        Add-AgentTraceLines -Lines $lines -ActiveSearch $activeSearch -Width $Width -MaxLogLines 10
    }
    elseif ($SelectedRow.Type -eq 'Result') {
        $parentDevice = Get-NotePropertyValue -Object $SelectedRow -Name 'ParentDevice'
        $resultSearch = if ($null -ne $parentDevice -and $script:ActiveSearches.Contains($parentDevice.InstanceId)) { $script:ActiveSearches[$parentDevice.InstanceId] } else { $null }
        $isAgentResult = ([string]$SelectedRow.Name -match '^\[Agent:')

        if ($isAgentResult) {
            $lines.Add((New-SectionLine -Title 'Agent Result' -Width $Width))
            $stateText = ([string]$SelectedRow.Name -replace '^\[Agent:\s*[^\]]+\]\s*', '').Trim()
            if (-not [string]::IsNullOrWhiteSpace($stateText)) {
                $stateColor = if ($stateText -match 'Failed|Error|Cancelled') { $_C.Fail } elseif ($stateText -match 'Done') { $_C.OK } else { $_C.Warn }
                $lines.Add((New-KeyValueLine -Key 'State' -Value $stateText -Width $Width -ValueColor $stateColor))
            }

            $tracePath = if ($null -ne $resultSearch -and -not [string]::IsNullOrWhiteSpace($resultSearch.AgentTracePath)) {
                $resultSearch.AgentTracePath
            } else {
                Get-NotePropertyValue -Object $parentDevice -Name 'SearchTracePath'
            }
            if (-not [string]::IsNullOrWhiteSpace($tracePath)) {
                $lines.Add((New-KeyValueLine -Key 'Log' -Value $tracePath -Width $Width))
            }
            $checkpointPath = if ($null -ne $resultSearch) {
                Get-NotePropertyValue -Object $resultSearch -Name 'AgentCheckpointPath'
            } else {
                Get-NotePropertyValue -Object $parentDevice -Name 'SearchCheckpointPath'
            }
            if (-not [string]::IsNullOrWhiteSpace($checkpointPath)) {
                $lines.Add((New-KeyValueLine -Key 'Checkpoint' -Value $checkpointPath -Width $Width))
            }

            $detailText = if ($null -ne $resultSearch -and -not [string]::IsNullOrWhiteSpace($resultSearch.AgentVal)) {
                $resultSearch.AgentVal
            } else {
                Get-NotePropertyValue -Object $parentDevice -Name 'SearchDetail'
            }

            if (-not [string]::IsNullOrWhiteSpace($detailText)) {
                $plainDetail = Convert-MarkdownResultToPlain -Text $detailText
                $lines.Add((New-SectionLine -Title 'Answer' -Width $Width))
                Add-WrappedDetailTextLines -Lines $lines -Text $plainDetail -Width $Width -MaxLines ([Math]::Max(2, $MaxLines - $lines.Count - 5))

                $urls = @(Get-UrlsFromText -Text $detailText)
                if ($urls.Count -gt 0 -and $lines.Count -lt ($MaxLines - 2)) {
                    $lines.Add((New-SectionLine -Title 'Links' -Width $Width))
                    $linkWidth = [Math]::Max(8, $Width - 4)
                    $maxLinks = [Math]::Min($urls.Count, [Math]::Max(1, $MaxLines - $lines.Count))
                    for ($urlIndex = 0; $urlIndex -lt $maxLinks; $urlIndex++) {
                        $url = $urls[$urlIndex]
                        $label = Format-PlainToWidth -Text ("$($urlIndex + 1). $url") -Width $linkWidth
                        $clickable = New-TerminalHyperlink -Label $label -Url $url
                        $lines.Add("  $($_C.Info)$clickable$($_C.Reset)")
                    }
                }
            } elseif ($null -eq $resultSearch) {
                $cleanText = ([string]$SelectedRow.Name -replace '^\[[^\]]+\]\s*', '').Trim()
                Add-WrappedDetailTextLines -Lines $lines -Text $cleanText -Width $Width -MaxLines ([Math]::Max(3, $MaxLines - $lines.Count))
            }

            Add-AgentTraceLines -Lines $lines -ActiveSearch $resultSearch -Width $Width -MaxLogLines ([Math]::Max(4, $MaxLines - $lines.Count - 2))
        } else {
            $titleText = 'Detailed Info'
            if ($SelectedRow.Name -match '^\[([^\]]+)\]') { $titleText = $Matches[1] }
            $lines.Add((New-SectionLine -Title $titleText -Width $Width))
            $cleanText = ([string]$SelectedRow.Name -replace '^\[[^\]]+\]\s*', '').Trim()
            foreach ($line in (Wrap-PlainText -Text $cleanText -Width ([Math]::Max(8, $Width - 2)) -MaxLines ([Math]::Max(3, $MaxLines - 2)))) {
                $lines.Add("$($_C.White)  $(Format-PlainToWidth -Text $line -Width ([Math]::Max(1, $Width - 2)))$($_C.Reset)")
            }
        }
    }
    else {
        $lines.Add((New-SectionLine -Title 'Category Info' -Width $Width))
        $lines.Add((New-KeyValueLine -Key 'Group' -Value $SelectedRow.Name -Width $Width))
        if ($SelectedRow.Type -eq 'Category' -and $SelectedRow.Ref.Devices) {
            $categoryDevices = @($SelectedRow.Ref.Devices)
            $lines.Add((New-KeyValueLine -Key 'Devices' -Value ([string]$categoryDevices.Count) -Width $Width))

            $activeEvidenceCount = @(
                $categoryDevices | Where-Object {
                    $script:ActiveSearches.Contains($_.InstanceId) -and
                    $script:ActiveSearches[$_.InstanceId].EvidenceState -eq 'Searching'
                }
            ).Count
            $cachedEvidenceCount = @(
                $categoryDevices | Where-Object {
                    [bool](Get-NotePropertyValue -Object $_ -Name 'EvidenceCached')
                }
            ).Count
            $queuedEvidenceCount = @(
                $categoryDevices | Where-Object {
                    $script:EvidenceBatchQueuedIds.Contains($_.InstanceId)
                }
            ).Count
            $evidenceText = if ($activeEvidenceCount -gt 0 -or $queuedEvidenceCount -gt 0) {
                "$activeEvidenceCount scanning / $queuedEvidenceCount queued / $cachedEvidenceCount cached"
            } else {
                "$cachedEvidenceCount cached"
            }
            $evidenceColor = if ($activeEvidenceCount -gt 0 -or $queuedEvidenceCount -gt 0) { $_C.Warn } elseif ($cachedEvidenceCount -gt 0) { $_C.OK } else { $_C.Dim }
            $lines.Add((New-KeyValueLine -Key 'Evidence' -Value $evidenceText -Width $Width -ValueColor $evidenceColor))
        }
    }

    while ($lines.Count -lt $MaxLines) {
        $lines.Add('')
    }
    return @($lines | Select-Object -First $MaxLines)
}

function Invoke-ModelSelector {
    [Console]::CursorVisible = $false
    $cursor = 0
    try {
        while ($true) {
            Lock-ViewportToWindow

            try {
                $maxVisible = [Math]::Max(3, $Host.UI.RawUI.WindowSize.Height - 8)
            }
            catch {
                $maxVisible = 10
            }

            $viewTop = [Math]::Max(0, [Math]::Min($cursor - [int]($maxVisible / 2), [Math]::Max(0, $script:AvailableModels.Count - $maxVisible)))
            $viewBot = [Math]::Min($viewTop + $maxVisible - 1, $script:AvailableModels.Count - 1)

            Begin-SyncRender
            try { Clear-Host } catch {}

            Write-UiBanner -Title 'Model Selector' -Subtitle 'Space to toggle selection. Enter/Esc to confirm and return.'
            Write-UiSection -Title 'Available AI Models for Scan' -Icon ''
            Write-Host ''

            $aboveMessage = if ($viewTop -gt 0) { "  $($_C.Dim)$([char]0x2191) $viewTop more above$($_C.Reset)" } else { '' }
            Write-Host "$aboveMessage$($_C.EraseLn)"

            for ($index = $viewTop; $index -le $viewBot; $index++) {
                $model = $script:AvailableModels[$index]
                $check = if ($model.Selected) { "[x]" } else { "[ ]" }
                $checkColor = if ($model.Selected) { $_C.OK } else { $_C.Dim }
                $providerColor = if ($model.Provider -eq 'Gemini') { $_C.Info } else { $_C.Gold }

                $displayText = " $checkColor$check$($_C.Reset) $providerColor$($model.Provider):$($_C.Reset) $($model.FriendlyName) $($_C.Dim)($($model.ApiId))$($_C.Reset)"

                # Show limits if available
                if ($model.RpmLimit -or $model.RpdLimit) {
                    $limits = @()
                    if ($model.RpmLimit) { $limits += "$($model.RpmLimit) RPM" }
                    if ($model.RpdLimit) { $limits += "$($model.RpdLimit) RPD" }
                    $displayText += " $($_C.Dim)[$($limits -join ', ')]$($_C.Reset)"
                }

                if ($index -eq $cursor) {
                    # Strip ANSI for selection bar
                    Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $([char]0x276F) $(Remove-AnsiSequence -Text $displayText) $($_C.Reset)$($_C.EraseLn)"
                }
                else {
                    Write-Host "    $displayText$($_C.EraseLn)"
                }
            }

            $below = $script:AvailableModels.Count - 1 - $viewBot
            $belowMessage = if ($below -gt 0) { "  $($_C.Dim)$([char]0x2193) $below more below$($_C.Reset)" } else { '' }
            Write-Host "$belowMessage$($_C.EraseLn)"
            Write-Host "$($_C.EraseLn)"

            # Nav footer
            $segments = @(
                New-UiShortcutSegment -Text "$([char]0x2191)$([char]0x2193)" -Color $_C.White
                New-UiShortcutSegment -Text ' navigate   ' -Color $_C.Dim
                New-UiShortcutSegment -Text 'Space' -Color $_C.OK
                New-UiShortcutSegment -Text ' = toggle   ' -Color $_C.Dim
                New-UiShortcutSegment -Text 'Enter / Esc' -Color $_C.Info
                New-UiShortcutSegment -Text ' = confirm/close' -Color $_C.Dim
            )
            Write-UiShortcutSegments -Segments $segments

            Write-Host "$($_E)[J" -NoNewline

            End-SyncRender

            $key = Read-ConsoleKey
            if ($null -eq $key -or -not $key.PSObject.Properties['Key']) {
                Start-Sleep -Milliseconds 50
                continue
            }
            switch ($key.Key) {
                'UpArrow' { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt ($script:AvailableModels.Count - 1)) { $cursor++ } }
                'PageUp' { $cursor = [Math]::Max(0, $cursor - $maxVisible) }
                'PageDown' { $cursor = [Math]::Min($script:AvailableModels.Count - 1, $cursor + $maxVisible) }
                'Home' { $cursor = 0 }
                'End' { $cursor = $script:AvailableModels.Count - 1 }
                'Spacebar' {
                    $script:AvailableModels[$cursor].Selected = -not $script:AvailableModels[$cursor].Selected
                }
                'Space' {
                    $script:AvailableModels[$cursor].Selected = -not $script:AvailableModels[$cursor].Selected
                }
                'Enter' {
                    Save-ModelSelection
                    return
                }
                'Escape' {
                    Save-ModelSelection
                    return
                }
                'ResizeEvent' { continue }
                default {
                    if ($key.KeyChar -eq ' ') {
                        $script:AvailableModels[$cursor].Selected = -not $script:AvailableModels[$cursor].Selected
                    }
                }
            }
        }
    }
    finally {
        try { [Console]::CursorVisible = $true } catch {}
    }
}

# Legacy stacked renderer retained temporarily while the responsive renderer settles.
function Render-FrameLegacy {
    try {
        # Reduce window height dynamically to accommodate details panel
        $maxVisible = [Math]::Max(4, $Host.UI.RawUI.WindowSize.Height - 21)
    } catch {
        $maxVisible = 12
    }

    $viewTop = [Math]::Max(0, [Math]::Min($selectedIndex - [int]($maxVisible / 2), [Math]::Max(0, $script:visibleRows.Count - $maxVisible)))
    $viewBot = [Math]::Min($viewTop + $maxVisible - 1, $script:visibleRows.Count - 1)

    Begin-SyncRender
    try { Clear-Host } catch {}

    # Header
    Write-UiBanner -Title "DeviceCheck Manager" -Subtitle "R rescans the present PnP device tree. E scans selected device locally. S adds web/AI."
    Write-Host "  $($_C.Dim)$($script:SystemScanMessage)$($_C.Reset)$($_C.EraseLn)"
    Write-UiSection -Title "Device Connection Tree"
    Write-Host ''

    # Scrolling indicators above
    $aboveCount = $viewTop
    $aboveMessage = if ($aboveCount -gt 0) { "  $($_C.Dim)$([char]0x2191) $aboveCount more above$($_C.Reset)" } else { '' }
    Write-Host "$aboveMessage$($_C.EraseLn)"

    # Render visible rows
    for ($index = $viewTop; $index -le $viewBot; $index++) {
        $row = $script:visibleRows[$index]
        $isSelected = ($index -eq $selectedIndex)

        if ($row.Type -eq 'Root') {
            $icon = if ($row.IsExpanded) { [char]0x25BC } else { [char]0x25B6 }
            $displayText = " $icon  $($row.Name)"

            if ($isSelected) {
                Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $displayText $($_C.Reset)$($_C.EraseLn)"
            } else {
                Write-Host "  $($_C.White)$displayText$($_C.Reset)$($_C.EraseLn)"
            }
        }
        elseif ($row.Type -eq 'Category') {
            $icon = if ($row.IsExpanded) { [char]0x25BC } else { [char]0x25B6 } # Down or Right arrow
            $displayText = "   $icon  $($row.Name)"

            if ($isSelected) {
                Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $displayText $($_C.Reset)$($_C.EraseLn)"
            } else {
                Write-Host "  $($_C.White)$displayText$($_C.Reset)$($_C.EraseLn)"
            }
        }
        elseif ($row.Type -eq 'Device') {
            $branch = if ($row.IsLast) { "└── " } else { "├── " }
            $warningIcon = if ($row.IsProblem) { "$($_C.Warn)[!]$($_C.Reset) " } else { "" }
            $displayText = "       $branch$warningIcon$($row.Name) [$($row.Class)]"

            if ($isSelected) {
                $cleanWarning = if ($row.IsProblem) { "[!] " } else { "" }
                $cleanText = "       $branch$cleanWarning$($row.Name) [$($row.Class)]"
                Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $cleanText $($_C.Reset)$($_C.EraseLn)"
            } else {
                Write-Host "$($_C.Dim)       $branch$($_C.Reset)$warningIcon$($_C.White)$($row.Name) $($_C.Dim)[$($row.Class)]$($_C.Reset)$($_C.EraseLn)"
            }
        }
        elseif ($row.Type -eq 'Status') {
            $parentPrefix = if ($row.ParentIsLast) { "            " } else { "       │    " }
            Write-Host "$($_C.Dim)$parentPrefix└── $($_C.Reset)$($_C.Warn)[$($row.Name)]$($_C.Reset)$($_C.EraseLn)"
        }
        elseif ($row.Type -eq 'Result') {
            $parentPrefix = if ($row.ParentIsLast) { "            " } else { "       │    " }

            $text = $row.Name
            $isSubResult = $text.StartsWith("  ")

            if ($isSubResult) {
                $text = $text.Substring(2)
                $branch = if ($row.IsLastResult) { "    └── " } else { "│   └── " }
            } else {
                $branch = if ($row.IsLastResult) { "└── " } else { "├── " }
            }

            # Truncate result text to console width dynamically
            $maxTextLen = (Get-UiWidth) - $parentPrefix.Length - $branch.Length - 10
            if ($text.Length -gt $maxTextLen) {
                $text = $text.Substring(0, [Math]::Max(5, $maxTextLen - 3)) + "..."
            }

            # Highlight prefixes like [Local DB] or [Gemini: ...] or [OpenRouter: ...]
            if ($text -match '^(\[([^\]]+)\])(.*)$') {
                $tag = $Matches[1]
                $tagName = $Matches[2]
                $rest = $Matches[3]
                $tagColor = if ($tagName -like '*Error*') {
                    $_C.Fail
                } elseif ($tagName -like '*Gemini*') {
                    $_C.Info    # Blue for Gemini
                } elseif ($tagName -like '*OpenRouter*' -or $tagName -like '*nvidia*' -or $tagName -like '*nemotron*') {
                    $_C.OK      # Green for OpenRouter/Nvidia/Nemotron
                } elseif ($tagName -like '*Local*') {
                    $_C.Gold
                } elseif ($tagName -like '*Web*') {
                    $_C.Warn
                } else {
                    $_C.Info
                }

                $useSameColorForRest = ($tagName -like '*Gemini*' -or $tagName -like '*OpenRouter*' -or $tagName -like '*nvidia*' -or $tagName -like '*nemotron*')

                if ($isSelected) {
                    Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $parentPrefix$branch$tag$rest $($_C.Reset)$($_C.EraseLn)"
                } else {
                    if ($useSameColorForRest) {
                        Write-Host "$($_C.Dim)$parentPrefix$branch$($_C.Reset)$tagColor$tag$rest$($_C.Reset)$($_C.EraseLn)"
                    } else {
                        Write-Host "$($_C.Dim)$parentPrefix$branch$($_C.Reset)$tagColor$tag$($_C.Reset)$($_C.White)$rest$($_C.Reset)$($_C.EraseLn)"
                    }
                }
            } else {
                if ($isSelected) {
                    Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $parentPrefix$branch$text $($_C.Reset)$($_C.EraseLn)"
                } else {
                    Write-Host "$($_C.Dim)$parentPrefix$branch$($_C.Reset)$($_C.White)$text$($_C.Reset)$($_C.EraseLn)"
                }
            }
        }
    }

    # Scrolling indicators below
    $belowCount = $script:visibleRows.Count - 1 - $viewBot
    $belowMessage = if ($belowCount -gt 0) { "  $($_C.Dim)$([char]0x2193) $belowCount more below$($_C.Reset)" } else { '' }
    Write-Host "$belowMessage$($_C.EraseLn)"

    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    #  DETAILS INSPECTOR PANEL
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    $selectedRow = $script:visibleRows[$selectedIndex]
    if ($selectedRow.Type -eq 'Root') {
        $machine = $selectedRow.Ref
        Write-UiSection -Title "Computer Info" -Icon ""
        Write-Host "  $($_C.Dim)System Name  :$($_C.Reset) $($_C.White)$(Get-MachineDisplayName -MachineEvidence $machine)$($_C.Reset)$($_C.EraseLn)"
        Write-Host "  $($_C.Dim)OS           :$($_C.Reset) $($_C.White)$(Format-UiValue -Text "$($machine.OperatingSystem.Caption) $($machine.OperatingSystem.Version) Build $($machine.OperatingSystem.BuildNumber)" -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
        Write-Host "  $($_C.Dim)System       :$($_C.Reset) $($_C.White)$(Format-UiValue -Text "$($machine.ComputerSystem.Manufacturer) $($machine.ComputerSystem.Model) [$($machine.ComputerSystem.SystemType)]" -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
        Write-Host "  $($_C.Dim)BaseBoard    :$($_C.Reset) $($_C.White)$(Format-UiValue -Text "$($machine.BaseBoard.Manufacturer) $($machine.BaseBoard.Product)" -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
        Write-Host "  $($_C.Dim)Processor    :$($_C.Reset) $($_C.White)$(Format-UiValue -Text $machine.Processor.Name -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
        Write-Host "  $($_C.Dim)BIOS         :$($_C.Reset) $($_C.White)$(Format-UiValue -Text "$($machine.BIOS.Manufacturer) $($machine.BIOS.SMBIOSBIOSVersion)" -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
    }
    elseif ($selectedRow.Type -eq 'Device') {
        Write-UiSection -Title "Device Properties" -Icon ""
        Write-Host "  $($_C.Dim)FriendlyName :$($_C.Reset) $($_C.White)$($selectedRow.Ref.FriendlyName)$($_C.Reset)$($_C.EraseLn)"
        Write-Host "  $($_C.Dim)InstanceId   :$($_C.Reset) $($_C.White)$($selectedRow.Ref.InstanceId)$($_C.Reset)$($_C.EraseLn)"

        $errCode = $selectedRow.Ref.ConfigManagerErrorCode
        $errDesc = switch ($errCode) {
            0  { "Working properly" }
            10 { "Device cannot start (CM_PROB_FAILED_START)" }
            21 { "Device has been uninstalled (CM_PROB_WILL_BE_REMOVED)" }
            22 { "Device is disabled (CM_PROB_DISABLED)" }
            28 { "Drivers not installed (CM_PROB_FAILED_INSTALL)" }
            43 { "Device reported problems (CM_PROB_FAILED_POST_START)" }
            default { "Unknown problem status" }
        }

        $statusText = if ($errCode -eq 0) {
            "$($_C.OK)OK ($errDesc)$($_C.Reset)"
        } else {
            "$($_C.Fail)Error (Code ${errCode}: $errDesc)$($_C.Reset)"
        }

        Write-Host "  $($_C.Dim)Status       :$($_C.Reset) $statusText$($_C.EraseLn)"

        $cachedEvidence = Read-CachedDeviceEvidence -InstanceId $selectedRow.Ref.InstanceId
        if ($null -ne $cachedEvidence) {
            $capturedText = if ($cachedEvidence.CapturedAt) { $cachedEvidence.CapturedAt } else { 'unknown time' }
            Write-Host "  $($_C.Dim)Evidence     :$($_C.Reset) $($_C.OK)Cached ($capturedText)$($_C.Reset)$($_C.EraseLn)"

            $hardwareIds = $cachedEvidence.ImportantProperties.DEVPKEY_Device_HardwareIds
            if ($hardwareIds) {
                $firstHardwareId = if ($hardwareIds -is [array]) { $hardwareIds[0] } else { $hardwareIds }
                Write-Host "  $($_C.Dim)HardwareId   :$($_C.Reset) $($_C.White)$(Format-UiValue -Text $firstHardwareId -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
            }

            $manufacturer = $cachedEvidence.ImportantProperties.DEVPKEY_Device_Manufacturer
            if ($manufacturer) {
                Write-Host "  $($_C.Dim)Manufacturer :$($_C.Reset) $($_C.White)$(Format-UiValue -Text $manufacturer -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
            }

            $compatibleIds = $cachedEvidence.ImportantProperties.DEVPKEY_Device_CompatibleIds
            if ($compatibleIds) {
                $firstCompatibleId = if ($compatibleIds -is [array]) { $compatibleIds[0] } else { $compatibleIds }
                Write-Host "  $($_C.Dim)CompatibleId :$($_C.Reset) $($_C.White)$(Format-UiValue -Text $firstCompatibleId -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
            }

            $service = $cachedEvidence.ImportantProperties.DEVPKEY_Device_Service
            if ($service) {
                Write-Host "  $($_C.Dim)Service      :$($_C.Reset) $($_C.White)$(Format-UiValue -Text $service -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
            }

            if ($cachedEvidence.SignedDriver) {
                $driver = $cachedEvidence.SignedDriver
                $driverText = "$($driver.DriverProviderName) $($driver.DriverVersion) ($($driver.InfName))"
                Write-Host "  $($_C.Dim)Driver       :$($_C.Reset) $($_C.White)$(Format-UiValue -Text $driverText -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
            }

            $cachePath = Get-DeviceEvidenceCachePath -InstanceId $selectedRow.Ref.InstanceId
            Write-Host "  $($_C.Dim)Cache        :$($_C.Reset) $($_C.White)$(Format-UiValue -Text $cachePath -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
        } else {
            Write-Host "  $($_C.Dim)Evidence     :$($_C.Reset) $($_C.Warn)Not scanned yet. Press E for local evidence or S for search.$($_C.Reset)$($_C.EraseLn)"
        }
    }
    elseif ($selectedRow.Type -eq 'Result') {
        # Select title prefix based on tag
        $titleText = "Detailed Info"
        if ($selectedRow.Name -match '^\[([^\]]+)\]') {
            $titleText = $Matches[1]
        }
        Write-UiSection -Title $titleText -Icon ""

        $cleanText = ($selectedRow.Name -replace '^\[[^\]]+\]\s*', '').Trim()

        # Word wrap logic for console
        $w = (Get-UiWidth) - 4
        $wrappedLines = @()
        $words = $cleanText -split ' '
        $currentLine = "  "
        foreach ($word in $words) {
            if (($currentLine + $word).Length -gt $w) {
                $wrappedLines += $currentLine
                $currentLine = "  $word"
            } else {
                $currentLine = if ($currentLine -eq "  ") { "  $word" } else { "$currentLine $word" }
            }
        }
        if ($currentLine) { $wrappedLines += $currentLine }

        # Print top 3 wrapped lines to fit details box nicely
        for ($k = 0; $k -lt [Math]::Min(3, $wrappedLines.Count); $k++) {
            Write-Host "$($_C.White)$($wrappedLines[$k])$($_C.Reset)$($_C.EraseLn)"
        }
        if ($wrappedLines.Count -eq 1) { Write-Host "$($_C.EraseLn)" }
        Write-Host "$($_C.EraseLn)"
    }
    else {
        # Category or other type
        Write-UiSection -Title "Category Info" -Icon ""
        Write-Host "  $($_C.White)Group: $($selectedRow.Name)$($_C.Reset)$($_C.EraseLn)"
        if ($selectedRow.Type -eq 'Category' -and $selectedRow.Ref.Devices) {
            Write-Host "  $($_C.Dim)Devices: $(@($selectedRow.Ref.Devices).Count)$($_C.Reset)$($_C.EraseLn)"
        } else {
            Write-Host "$($_C.EraseLn)"
        }
        Write-Host "$($_C.EraseLn)"
        Write-Host "$($_C.EraseLn)"
        Write-Host "$($_C.EraseLn)"
    }

    # Footer
    $segments = @(
        New-UiShortcutSegment -Text "$([char]0x2191)$([char]0x2193)" -Color $_C.White
        New-UiShortcutSegment -Text ' navigate   ' -Color $_C.Dim
        New-UiShortcutSegment -Text '+ / -' -Color $_C.OK
        New-UiShortcutSegment -Text ' = expand/collapse   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'R' -Color $_C.Info
        New-UiShortcutSegment -Text ' = system scan   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'E' -Color $_C.OK
        New-UiShortcutSegment -Text ' = evidence   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'M' -Color $_C.White
        New-UiShortcutSegment -Text ' = models   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'A' -Color $_C.Info
        New-UiShortcutSegment -Text ' = agent   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'S' -Color $_C.Gold
        New-UiShortcutSegment -Text ' = web/AI   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'Q / Esc' -Color $_C.Fail
        New-UiShortcutSegment -Text ' = exit' -Color $_C.Dim
    )
    Write-UiShortcutSegments -Segments $segments
    Write-Host "$($_E)[J" -NoNewline

    End-SyncRender
}

function Render-Frame {
    $uiWidth = Get-UiWidth
    try { $windowHeight = $Host.UI.RawUI.WindowSize.Height } catch { $windowHeight = 32 }

    $useDualPane = ($uiWidth -ge 136)
    $batchStatus = Get-EvidenceBatchStatusText
    $footerHeight = 1
    $headerReserve = if ([string]::IsNullOrWhiteSpace($batchStatus)) { 7 } else { 8 }
    $availableRows = [Math]::Max(8, $windowHeight - $headerReserve - $footerHeight)

    if ($useDualPane) {
        $dividerWidth = 3
        $availablePaneWidth = [Math]::Max(80, $uiWidth - $dividerWidth)
        $leftWidth = [int][Math]::Floor($availablePaneWidth / 2)
        $rightWidth = $availablePaneWidth - $leftWidth
        $maxVisible = $availableRows
    } else {
        $leftWidth = $uiWidth
        $rightWidth = $uiWidth
        $maxVisible = [Math]::Max(4, $windowHeight - 22)
    }

    $viewTop = [Math]::Max(0, [Math]::Min($selectedIndex - [int]($maxVisible / 2), [Math]::Max(0, $script:visibleRows.Count - $maxVisible)))
    $viewBot = [Math]::Min($viewTop + $maxVisible - 1, $script:visibleRows.Count - 1)
    $selectedRow = if ($script:visibleRows.Count -gt 0) { $script:visibleRows[$selectedIndex] } else { $null }

    Begin-SyncRender
    try { Clear-Host } catch {}

    Write-UiBanner -Title 'DeviceCheck Manager' -Subtitle 'R rescans devices. E scans selected device locally. S adds web/AI.'
    $statusWidth = [Math]::Max(10, $uiWidth - 2)
    $compactStatus = Get-CompactSystemStatus -StatusText $script:SystemScanMessage
    Write-Host "  $($_C.Dim)$(Format-UiValue -Text $compactStatus -MaxLength $statusWidth)$($_C.Reset)$($_C.EraseLn)"
    if (-not [string]::IsNullOrWhiteSpace($batchStatus)) {
        Write-Host "  $($_C.Warn)$(Format-UiValue -Text $batchStatus -MaxLength $statusWidth)$($_C.Reset)$($_C.EraseLn)"
    }

    if ($useDualPane) {
        $leftTitle = New-SectionLine -Title 'Device Connection Tree' -Width $leftWidth
        $rightTitle = New-SectionLine -Title 'Selected Details' -Width $rightWidth
        Write-Host "$(Format-AnsiToWidth -Text $leftTitle -Width $leftWidth)$($_C.Dim) │ $($_C.Reset)$(Format-AnsiToWidth -Text $rightTitle -Width $rightWidth)$($_C.EraseLn)"

        $treeLines = [System.Collections.Generic.List[string]]::new()
        $aboveCount = $viewTop
        $aboveMessage = if ($aboveCount -gt 0) { "$([char]0x2191) $aboveCount more above" } else { '' }
        $treeLines.Add("$($_C.Dim)$(Format-PlainToWidth -Text $aboveMessage -Width $leftWidth)$($_C.Reset)")

        for ($index = $viewTop; $index -le $viewBot; $index++) {
            $row = $script:visibleRows[$index]
            $treeLines.Add((Get-TreeDisplayLine -Row $row -IsSelected:($index -eq $selectedIndex) -Width $leftWidth))
        }

        $belowCount = $script:visibleRows.Count - 1 - $viewBot
        $belowMessage = if ($belowCount -gt 0) { "$([char]0x2193) $belowCount more below" } else { '' }
        $treeLines.Add("$($_C.Dim)$(Format-PlainToWidth -Text $belowMessage -Width $leftWidth)$($_C.Reset)")

        $detailLines = if ($null -ne $selectedRow) {
            Get-DetailDisplayLines -SelectedRow $selectedRow -Width $rightWidth -MaxLines $treeLines.Count
        } else {
            @((New-SectionLine -Title 'Selected Details' -Width $rightWidth))
        }

        $lineCount = [Math]::Max($treeLines.Count, $detailLines.Count)
        for ($i = 0; $i -lt $lineCount; $i++) {
            $leftLine = if ($i -lt $treeLines.Count) { $treeLines[$i] } else { '' }
            $rightLine = if ($i -lt $detailLines.Count) { $detailLines[$i] } else { '' }
            Write-Host "$(Format-AnsiToWidth -Text $leftLine -Width $leftWidth)$($_C.Dim) │ $($_C.Reset)$(Format-AnsiToWidth -Text $rightLine -Width $rightWidth)$($_C.EraseLn)"
        }
    } else {
        Write-UiSection -Title 'Device Connection Tree'
        Write-Host ''

        $aboveCount = $viewTop
        $aboveMessage = if ($aboveCount -gt 0) { "  $([char]0x2191) $aboveCount more above" } else { '' }
        Write-Host "$($_C.Dim)$(Format-PlainToWidth -Text $aboveMessage -Width $leftWidth)$($_C.Reset)$($_C.EraseLn)"

        for ($index = $viewTop; $index -le $viewBot; $index++) {
            $row = $script:visibleRows[$index]
            Write-Host "$(Get-TreeDisplayLine -Row $row -IsSelected:($index -eq $selectedIndex) -Width $leftWidth)$($_C.EraseLn)"
        }

        $belowCount = $script:visibleRows.Count - 1 - $viewBot
        $belowMessage = if ($belowCount -gt 0) { "  $([char]0x2193) $belowCount more below" } else { '' }
        Write-Host "$($_C.Dim)$(Format-PlainToWidth -Text $belowMessage -Width $leftWidth)$($_C.Reset)$($_C.EraseLn)"

        if ($null -ne $selectedRow) {
            foreach ($line in (Get-DetailDisplayLines -SelectedRow $selectedRow -Width $rightWidth -MaxLines 11)) {
                Write-Host "$(Format-AnsiToWidth -Text $line -Width $rightWidth)$($_C.EraseLn)"
            }
        }
    }

    $segments = @(
        New-UiShortcutSegment -Text "$([char]0x2191)$([char]0x2193)" -Color $_C.White
        New-UiShortcutSegment -Text ' navigate   ' -Color $_C.Dim
        New-UiShortcutSegment -Text '+ / -' -Color $_C.OK
        New-UiShortcutSegment -Text ' = expand/collapse   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'R' -Color $_C.Info
        New-UiShortcutSegment -Text ' = system scan   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'E' -Color $_C.OK
        New-UiShortcutSegment -Text ' = evidence   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'M' -Color $_C.White
        New-UiShortcutSegment -Text ' = models   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'A' -Color $_C.Info
        New-UiShortcutSegment -Text ' = agent   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'S' -Color $_C.Gold
        New-UiShortcutSegment -Text ' = web/AI   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'Q / Esc' -Color $_C.Fail
        New-UiShortcutSegment -Text ' = exit' -Color $_C.Dim
    )
    Write-UiShortcutSegments -Segments $segments -Width $uiWidth
    Write-Host "$($_E)[J" -NoNewline

    End-SyncRender
}

function Invoke-SystemScanWithFeedback {
    param([switch]$Quiet)

    $script:SystemScanMessage = "System scan running: reading $(Get-MachineDisplayName -MachineEvidence $script:MachineEvidence) and present PnP device tree... | $(Get-Date -Format 'HH:mm:ss')"
    if ($script:visibleRows -and $script:visibleRows.Count -gt 0) {
        Render-Frame
    }

    Invoke-SystemScan -Quiet:$Quiet
    $script:selectedIndex = 0
    $script:visibleRows = Update-VisibleRows
}

# Start background lookup pipeline for a device (Asynchronous, non-blocking)
function Start-DeviceLookup {
    param(
        $Dev,
        [switch]$EvidenceOnly,
        [switch]$ForceEvidenceRefresh,
        [string]$EvidenceBatchId,
        [switch]$UseAgent
    )

    $instanceId = $Dev.InstanceId

    # If already searching, toggle to cancel/stop it
    if ($script:ActiveSearches.Contains($instanceId)) {
        Stop-DeviceLookup -InstanceId $instanceId
        return
    }

    # Resolve API keys
    $apiKey = $env:GEMINI_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey)) { $apiKey = $env:GOOGLE_API_KEY }
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        try { $apiKey = (Get-ItemProperty -Path 'HKCU:\Environment' -ErrorAction SilentlyContinue).GOOGLE_API_KEY } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        try { $apiKey = (Get-ItemProperty -Path 'HKCU:\Environment' -ErrorAction SilentlyContinue).GEMINI_API_KEY } catch {}
    }

    if ($UseAgent -and [string]::IsNullOrWhiteSpace($apiKey)) {
        $message = "Google/Gemini API key is missing (set GEMINI_API_KEY environment variable)."
        $Dev.SearchStatus = 'Done'
        $Dev.SearchKind = 'Agent'
        $Dev.SearchDetail = $message
        $Dev.SearchTracePath = $null
        $Dev.SearchCheckpointPath = $null
        $Dev.SearchResults = @("[Agent: gemini-3.1-flash-lite] (Failed)")
        return
    }

    $openRouterKey = $env:OPENROUTER_API_KEY
    if ([string]::IsNullOrWhiteSpace($openRouterKey)) {
        try { $openRouterKey = (Get-ItemProperty -Path 'HKCU:\Environment' -ErrorAction SilentlyContinue).OPENROUTER_API_KEY } catch {}
    }

    # Initialize model runs for all selected models
    $modelRuns = [System.Collections.Generic.List[object]]::new()
    $activeResults = [System.Collections.Generic.List[string]]::new()

    $selectedModels = if ($UseAgent) { @() } else { $script:AvailableModels | Where-Object { $_.Selected } }
    foreach ($model in $selectedModels) {
        $runKey = if ($model.Provider -eq 'Gemini') { $apiKey } else { $openRouterKey }
        $state = if ((-not $EvidenceOnly) -and $runKey) { 'Waiting' } else { 'None' }

        $run = [pscustomobject]@{
            Provider    = $model.Provider
            ModelName   = $model.ApiId
            State       = $state
            Val         = $null
            Duration    = $null
            Started     = $false
            ApiKey      = $runKey
            Ps          = $null
            Async       = $null
            Output      = $null
        }
        $modelRuns.Add($run)

        if ($state -eq 'Waiting') {
            $activeResults.Add("[$($model.Provider): $($model.ApiId)] (Waiting for web search...)")
        }
    }

    # Initialize search states
    $evidenceState = 'Searching'
    $localState = if ($EvidenceOnly) { 'None' } else { 'Searching' }
    $webState = if ($EvidenceOnly) { 'None' } else { 'Searching' }
    $agentTracePath = if ($UseAgent) { New-AgentTracePath -InstanceId $instanceId } else { $null }
    $agentCheckpointPath = if ($UseAgent) { New-AgentCheckpointPath -InstanceId $instanceId } else { $null }
    $agentToolCacheRoot = if ($UseAgent) { New-AgentToolCacheRoot } else { $null }

    # Pre-populate search rows
    $Dev.SearchStatus = 'Done'
    $Dev.SearchKind = if ($UseAgent) { 'Agent' } else { $null }
    $Dev.SearchDetail = $null
    $Dev.SearchTracePath = $agentTracePath
    $Dev.SearchCheckpointPath = $agentCheckpointPath
    $newResults = [System.Collections.Generic.List[string]]::new()
    if ($UseAgent) {
        $newResults.Add("[Agent: gemini-3.1-flash-lite] (Waiting for local evidence...)")
    } else {
        $newResults.AddRange($activeResults)
        if ($webState -eq 'Searching') { $newResults.Add("[Web Snippet] (Searching...)") }
    }
    $Dev.SearchResults = $newResults

    # Start background runspace for Web and Local Search
    $psWeb = [PowerShell]::Create()
    $null = $psWeb.AddScript({
        param($DeviceBasics, $MachineEvidence, [string]$MachineCacheRoot, [bool]$EvidenceOnly, [bool]$ForceEvidenceRefresh)
        $ProgressPreference = 'SilentlyContinue'
        try {
            $InstanceId = $DeviceBasics.InstanceId

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

            function ConvertTo-PlainEvidenceValue {
                param($Value)

                if ($null -eq $Value) { return $null }
                if ($Value -is [array]) {
                    return @($Value | ForEach-Object { if ($null -eq $_) { $null } else { $_.ToString() } })
                }
                return $Value.ToString()
            }

            function Get-DeviceEvidence {
                param($DeviceBasics, $MachineEvidence, [string]$MachineCacheRoot, [bool]$ForceEvidenceRefresh)

                $deviceHash = New-DeviceCheckHash -Text $DeviceBasics.InstanceId
                $devicesRoot = Join-Path -Path $MachineCacheRoot -ChildPath 'devices'
                $cachePath = Join-Path -Path $devicesRoot -ChildPath "$deviceHash.json"

                if ((-not $ForceEvidenceRefresh) -and (Test-Path -LiteralPath $cachePath)) {
                    try {
                        $cachedEvidence = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
                        return [PSCustomObject]@{
                            Source   = 'Evidence'
                            Status   = 'Done'
                            Result   = "[Evidence Cache] Loaded local evidence: $cachePath"
                            Path     = $cachePath
                            Evidence = $cachedEvidence
                        }
                    } catch {}
                }

                $propertyRows = @()
                $propertyError = $null
                try {
                    $propertyRows = @(
                        Get-PnpDeviceProperty -InstanceId $DeviceBasics.InstanceId -ErrorAction Stop |
                            Sort-Object KeyName |
                            ForEach-Object {
                                [PSCustomObject]@{
                                    KeyName = $_.KeyName
                                    Type    = if ($null -eq $_.Type) { $null } else { $_.Type.ToString() }
                                    Data    = ConvertTo-PlainEvidenceValue $_.Data
                                }
                            }
                    )
                } catch {
                    $propertyError = $_.Exception.Message
                }

                $importantData = [ordered]@{}
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
                    'DEVPKEY_Device_DriverVersion',
                    'DEVPKEY_Device_ProblemCode',
                    'DEVPKEY_Device_Parent',
                    'DEVPKEY_Device_LocationPaths',
                    'DEVPKEY_Device_ContainerId'
                )

                foreach ($importantKey in $importantKeys) {
                    $match = $propertyRows | Where-Object { $_.KeyName -eq $importantKey } | Select-Object -First 1
                    if ($null -ne $match) {
                        $importantData[$importantKey] = $match.Data
                    }
                }

                $signedDriver = $null
                $signedDriverError = $null
                try {
                    $driver = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop |
                        Where-Object { $_.DeviceID -eq $DeviceBasics.InstanceId } |
                        Select-Object -First 1
                    if ($null -ne $driver) {
                        $signedDriver = [PSCustomObject]@{
                            DeviceName         = ConvertTo-PlainEvidenceValue $driver.DeviceName
                            Manufacturer       = ConvertTo-PlainEvidenceValue $driver.Manufacturer
                            DriverProviderName = ConvertTo-PlainEvidenceValue $driver.DriverProviderName
                            DriverVersion      = ConvertTo-PlainEvidenceValue $driver.DriverVersion
                            DriverDate         = ConvertTo-PlainEvidenceValue $driver.DriverDate
                            InfName            = ConvertTo-PlainEvidenceValue $driver.InfName
                            HardwareID         = ConvertTo-PlainEvidenceValue $driver.HardwareID
                            CompatID           = ConvertTo-PlainEvidenceValue $driver.CompatID
                        }
                    }
                } catch {
                    $signedDriverError = $_.Exception.Message
                }

                $pnputilOutput = $null
                $pnputilError = $null
                try {
                    $pnputilArgs = @('/enum-devices', '/instanceid', $DeviceBasics.InstanceId, '/ids', '/relations', '/drivers')
                    $pnputilOutput = (& pnputil.exe @pnputilArgs 2>&1) -join "`n"
                } catch {
                    $pnputilError = $_.Exception.Message
                }

                $evidence = [PSCustomObject]@{
                    SchemaVersion        = 1
                    CapturedAt           = (Get-Date).ToString('o')
                    Machine              = $MachineEvidence
                    Device               = $DeviceBasics
                    DeviceHash           = $deviceHash
                    ImportantProperties  = [PSCustomObject]$importantData
                    PnpProperties        = $propertyRows
                    PnpPropertyError     = $propertyError
                    SignedDriver         = $signedDriver
                    SignedDriverError    = $signedDriverError
                    PnPUtil              = [PSCustomObject]@{
                        Command = "pnputil.exe /enum-devices /instanceid `"$($DeviceBasics.InstanceId)`" /ids /relations /drivers"
                        Output  = $pnputilOutput
                        Error   = $pnputilError
                    }
                }

                try {
                    $null = New-Item -ItemType Directory -Path $devicesRoot -Force
                    $evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $cachePath -Encoding UTF8
                    return [PSCustomObject]@{
                        Source   = 'Evidence'
                        Status   = 'Done'
                        Result   = "[Evidence Cache] Saved local evidence: $cachePath"
                        Path     = $cachePath
                        Evidence = $evidence
                    }
                } catch {
                    return [PSCustomObject]@{
                        Source   = 'Evidence'
                        Status   = 'Error'
                        Result   = "Failed to save local evidence: $($_.Exception.Message)"
                        Path     = $cachePath
                        Evidence = $evidence
                    }
                }
            }

            function Get-LocalDeviceLookup {
                param([string]$InstId)

                $vendorId = $null
                $deviceId = $null
                $dbUrl = $null
                $dbName = $null

                if ($InstId -match 'USB\\VID_([0-9a-fA-F]{4})&PID_([0-9a-fA-F]{4})') {
                    $vendorId = $Matches[1].ToLower()
                    $deviceId = $Matches[2].ToLower()
                    $dbUrl = "http://www.linux-usb.org/usb.ids"
                    $dbName = "usb.ids"
                }
                elseif ($InstId -match 'PCI\\VEN_([0-9a-fA-F]{4})&DEV_([0-9a-fA-F]{4})') {
                    $vendorId = $Matches[1].ToLower()
                    $deviceId = $Matches[2].ToLower()
                    $dbUrl = "https://pci-ids.ucw.cz/v2.2/pci.ids"
                    $dbName = "pci.ids"
                }
                else {
                    return $null
                }

                $dbPath = Join-Path $env:TEMP $dbName
                try {
                    if (-not (Test-Path $dbPath) -or (Get-Item $dbPath).LastWriteTime -lt (Get-Date).AddDays(-30)) {
                        Invoke-WebRequest -Uri $dbUrl -OutFile $dbPath -UserAgent "Mozilla/5.0" -TimeoutSec 15 -UseBasicParsing
                    }

                    $vendorName = $null
                    $deviceName = $null
                    $foundVendor = $false

                    foreach ($line in Get-Content $dbPath) {
                        if ($line.StartsWith("#") -or [string]::IsNullOrWhiteSpace($line)) { continue }

                        if ($line -match "^([0-9a-fA-F]{4})\s+(.+)$") {
                            if ($Matches[1].ToLower() -eq $vendorId) {
                                $vendorName = $Matches[2].Trim()
                                $foundVendor = $true
                                continue
                            } else {
                                $foundVendor = $false
                            }
                        }

                        if ($foundVendor -and $line -match "^\t([0-9a-fA-F]{4})\s+(.+)$") {
                            if ($Matches[1].ToLower() -eq $deviceId) {
                                $deviceName = $Matches[2].Trim()
                                break
                            }
                        }
                    }

                    if ($vendorName) {
                        return [PSCustomObject]@{
                            Vendor = $vendorName
                            Device = if ($deviceName) { $deviceName } else { "Unknown Device" }
                        }
                    }
                } catch {}
                return $null
            }

            function Search-DeviceWeb {
                param([string]$HwId)

                $query = $HwId
                if ($HwId -match '^([^\\]+\\[^\\]+)') {
                    $query = $Matches[1]
                }

                $escapedQuery = [Uri]::EscapeDataString($query)
                $uri = "https://html.duckduckgo.com/html/?q=$escapedQuery"

                $response = Invoke-WebRequest -Uri $uri -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -TimeoutSec 15 -UseBasicParsing
                $content = $response.Content

                $matches = [regex]::Matches($content, '<a class="result__snippet"[^>]*>(.*?)</a>')

                $results = [System.Collections.Generic.List[string]]::new()
                $seen = @{}

                foreach ($m in $matches) {
                    $text = $m.Groups[1].Value -replace '<[^>]+>', ''
                    $text = $text -replace '&amp;', '&' -replace '&#92;', '\' -replace '&quot;', '"' -replace '&#x27;', "'" -replace '&lt;', '<' -replace '&gt;', '>'
                    $text = $text.Trim()

                    if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -lt 10) { continue }

                    $hash = $text.Substring(0, [Math]::Min(30, $text.Length))
                    if ($seen.ContainsKey($hash)) { continue }
                    $seen[$hash] = $true

                    $results.Add($text)
                    if ($results.Count -eq 3) { break }
                }

                if ($results.Count -eq 0) {
                    $results.Add("No Web search descriptions found.")
                }
                return $results
            }

            Write-Output (Get-DeviceEvidence -DeviceBasics $DeviceBasics -MachineEvidence $MachineEvidence -MachineCacheRoot $MachineCacheRoot -ForceEvidenceRefresh $ForceEvidenceRefresh)

            if ($EvidenceOnly) {
                return $null
            }

            $localInfo = Get-LocalDeviceLookup -InstId $InstanceId
            if ($null -ne $localInfo) {
                Write-Output ([PSCustomObject]@{ Source = 'Local'; Status = 'Done'; Result = "[Local DB] Vendor: $($localInfo.Vendor) | Device: $($localInfo.Device)" })
            } else {
                Write-Output ([PSCustomObject]@{ Source = 'Local'; Status = 'Done'; Result = $null })
            }

            $webSnippets = @()
            try {
                $webSnippets = Search-DeviceWeb -HwId $InstanceId
                if ($webSnippets.Count -gt 0) {
                    Write-Output ([PSCustomObject]@{ Source = 'Web'; Status = 'Done'; Snippets = $webSnippets; Result = $webSnippets[0] })
                } else {
                    Write-Output ([PSCustomObject]@{ Source = 'Web'; Status = 'Done'; Snippets = @(); Result = "No web snippets found." })
                }
            } catch {
                Write-Output ([PSCustomObject]@{ Source = 'Web'; Status = 'Error'; Snippets = @(); Result = "Search failed: $($_.Exception.Message)" })
            }
        } catch {
            Write-Output ([PSCustomObject]@{ Source = 'Web'; Status = 'Error'; Snippets = @(); Result = "Runspace crashed: $($_.Exception.Message)" })
        }
        return $null
    })
    $deviceBasics = [PSCustomObject]@{
        InstanceId             = $Dev.InstanceId
        FriendlyName           = $Dev.FriendlyName
        Class                  = $Dev.Class
        Status                 = $Dev.Status
        ConfigManagerErrorCode = $Dev.ConfigManagerErrorCode
    }
    $null = $psWeb.AddArgument($deviceBasics)
    $null = $psWeb.AddArgument($script:MachineEvidence)
    $null = $psWeb.AddArgument($script:MachineCacheRoot)
    $null = $psWeb.AddArgument([bool]$EvidenceOnly)
    $null = $psWeb.AddArgument([bool]$ForceEvidenceRefresh)

    $outputWeb = [System.Management.Automation.PSDataCollection[PSObject]]::new()
    $asyncWeb = $psWeb.BeginInvoke($outputWeb)

    $script:ActiveSearches[$instanceId] = [pscustomobject]@{
        Device             = $Dev
        StartTime          = (Get-Date)

        PsWeb              = $psWeb
        AsyncWeb           = $asyncWeb
        OutputWeb          = $outputWeb

        ModelRuns          = $modelRuns

        LocalState         = $localState
        WebState           = $webState
        EvidenceState      = $evidenceState
        EvidenceOnly       = [bool]$EvidenceOnly
        EvidenceBatchId    = $EvidenceBatchId
        UseAgent           = [bool]$UseAgent
        ApiKey             = $apiKey
        AgentLogs          = [System.Collections.Generic.List[string]]::new()
        AgentState         = if ($UseAgent) { 'Waiting' } else { 'None' }
        AgentPs            = $null
        AgentAsync         = $null
        AgentInput         = $null
        AgentOutput        = $null
        AgentOutputIndex   = 0
        AgentVal           = $null
        AgentTracePath     = $agentTracePath
        AgentCheckpointPath = $agentCheckpointPath
        AgentToolCacheRoot  = $agentToolCacheRoot

        LocalVal           = $null
        WebVal             = $null
        WebSnippets        = @()
        EvidenceVal        = $null
        EvidencePath       = $null
        DeviceEvidence     = $null

        SpinnerIndex       = 0
    }
}

function Start-DeviceEvidenceBatchScan {
    param(
        [array]$Devices,
        [string]$Label
    )

    if ($null -eq $Devices -or $Devices.Count -eq 0) { return }

    $devices = @($Devices)
    if ([string]::IsNullOrWhiteSpace($Label)) { $Label = 'selected group' }

    if ($null -eq $script:EvidenceBatchState -or (
            $script:EvidenceBatchQueue.Count -eq 0 -and
            (Get-ActiveEvidenceBatchCount) -eq 0
        )) {
        $script:EvidenceBatchQueue.Clear()
        $script:EvidenceBatchQueuedIds.Clear()
        $script:EvidenceBatchState = [pscustomobject]@{
            BatchId        = [guid]::NewGuid().ToString('n')
            Label          = $Label
            Total          = 0
            Started        = 0
            Completed      = 0
            Errors         = 0
            AlreadyRunning = 0
            AlreadyQueued  = 0
            StartedAt      = Get-Date
        }
    }

    $batchId = $script:EvidenceBatchState.BatchId
    $queuedCount = 0
    $alreadyRunningCount = 0
    $alreadyQueuedCount = 0

    foreach ($device in $devices) {
        if ($script:ActiveSearches.Contains($device.InstanceId)) {
            $alreadyRunningCount++
            continue
        }
        if ($script:EvidenceBatchQueuedIds.Contains($device.InstanceId)) {
            $alreadyQueuedCount++
            continue
        }

        $script:EvidenceBatchQueue.Enqueue([pscustomobject]@{
                Device  = $device
                BatchId = $batchId
            })
        $null = $script:EvidenceBatchQueuedIds.Add($device.InstanceId)
        $queuedCount++
    }

    $script:EvidenceBatchState.Total += $queuedCount
    $script:EvidenceBatchState.AlreadyRunning += $alreadyRunningCount
    $script:EvidenceBatchState.AlreadyQueued += $alreadyQueuedCount

    Start-PendingEvidenceBatchScans

    $parts = @("Evidence scan queued: $Label", "$queuedCount queued", "$alreadyRunningCount already running", "$alreadyQueuedCount already queued", "$($devices.Count) selected", (Get-Date -Format 'HH:mm:ss'))
    $script:SystemScanMessage = ($parts -join ' | ')
}

function Start-PendingEvidenceBatchScans {
    if ($null -eq $script:EvidenceBatchState) { return }

    while ($script:EvidenceBatchQueue.Count -gt 0 -and (Get-ActiveEvidenceBatchCount) -lt $script:EvidenceBatchMaxConcurrent) {
        $queueItem = $script:EvidenceBatchQueue.Dequeue()
        $device = $queueItem.Device
        $script:EvidenceBatchQueuedIds.Remove($device.InstanceId) | Out-Null

        if ($script:ActiveSearches.Contains($device.InstanceId)) {
            $script:EvidenceBatchState.AlreadyRunning++
            continue
        }

        Start-DeviceLookup -Dev $device -EvidenceOnly -ForceEvidenceRefresh -EvidenceBatchId $queueItem.BatchId
        $script:EvidenceBatchState.Started++
    }
}

function Start-CategoryEvidenceScan {
    param($Category)

    if ($null -eq $Category -or -not $Category.Devices) { return }

    $categoryDisplayName = Get-NotePropertyValue -Object $Category -Name 'DisplayName'
    $categoryName = if (-not [string]::IsNullOrWhiteSpace($categoryDisplayName)) { $categoryDisplayName } else { $Category.Name }
    Start-DeviceEvidenceBatchScan -Devices @($Category.Devices) -Label $categoryName
}

function Start-AllEvidenceScan {
    $devices = @($script:categories | ForEach-Object { @($_.Devices) })
    Start-DeviceEvidenceBatchScan -Devices $devices -Label (Get-MachineDisplayName -MachineEvidence $script:MachineEvidence)
}

# Stop and cleanup an active device lookup (Cancellation)
function Stop-DeviceLookup {
    param([string]$InstanceId)

    if (-not $script:ActiveSearches.Contains($InstanceId)) { return }
    $search = $script:ActiveSearches[$InstanceId]

    # Safely stop and dispose runspaces
    if ($null -ne $search.PsWeb) { try { $search.PsWeb.Stop(); $search.PsWeb.Dispose() } catch {} }
    if ($null -ne $search.AgentPs) { try { $search.AgentPs.Stop(); $search.AgentPs.Dispose() } catch {} }
    foreach ($run in $search.ModelRuns) {
        if ($null -ne $run.Ps) { try { $run.Ps.Stop(); $run.Ps.Dispose() } catch {} }
    }

    # Finalize search results with cancelled messages in split format
    $newResults = [System.Collections.Generic.List[string]]::new()

    if ($search.UseAgent) {
        if ($search.AgentState -in @('Searching', 'Waiting')) {
            $newResults.Add("[Agent: gemini-3.1-flash-lite] (Cancelled)")
            $search.Device.SearchDetail = "Cancelled by user."
        } elseif ($search.AgentState -eq 'Done') {
            $newResults.Add("[Agent: gemini-3.1-flash-lite] (Done)")
            $search.Device.SearchDetail = $search.AgentVal
        } elseif ($search.AgentState -eq 'Error') {
            $newResults.Add("[Agent: gemini-3.1-flash-lite] (Failed)")
            $search.Device.SearchDetail = $search.AgentVal
        } elseif ($search.AgentState -eq 'PausedRateLimit') {
            $newResults.Add("[Agent: gemini-3.1-flash-lite] (Paused: Rate limit)")
            $search.Device.SearchDetail = $search.AgentVal
        } elseif ($search.AgentState -eq 'PausedBudget') {
            $newResults.Add("[Agent: gemini-3.1-flash-lite] (Paused: Budget)")
            $search.Device.SearchDetail = $search.AgentVal
        }
        $search.Device.SearchKind = 'Agent'
        $search.Device.SearchTracePath = $search.AgentTracePath
        $search.Device.SearchCheckpointPath = $search.AgentCheckpointPath
    }

    if (-not $search.UseAgent) {
        foreach ($run in $search.ModelRuns) {
            if ($run.State -in @('Searching', 'Waiting')) {
                $newResults.Add("[$($run.Provider) Error: $($run.ModelName)] (Cancelled)")
                $newResults.Add("  Cancelled by user.")
            } elseif ($run.State -eq 'Done') {
                $durationStr = if ($null -ne $run.Duration) { "in $($run.Duration)s" } else { "Done" }
                $newResults.Add("[$($run.Provider): $($run.ModelName)] (Done $durationStr)")
                $newResults.Add("  $($run.Val)")
            } elseif ($run.State -eq 'Error') {
                $durationStr = if ($null -ne $run.Duration) { " after $($run.Duration)s" } else { "" }
                $newResults.Add("[$($run.Provider) Error: $($run.ModelName)] (Failed$durationStr)")
                $newResults.Add("  $($run.Val)")
            }
        }

        if ($search.LocalVal) {
            $newResults.Add($search.LocalVal)
        }

        if ($search.WebState -eq 'Searching') {
            $newResults.Add("[Web Snippet Error] (Cancelled)")
            $newResults.Add("  Cancelled by user.")
        } elseif ($search.WebSnippets -and $search.WebSnippets.Count -gt 0) {
            for ($snippetIndex = 0; $snippetIndex -lt $search.WebSnippets.Count; $snippetIndex++) {
                $snippetNumber = $snippetIndex + 1
                $newResults.Add("[Web Snippet $snippetNumber/$($search.WebSnippets.Count)] $($search.WebSnippets[$snippetIndex])")
            }
        } elseif ($search.WebVal) {
            $newResults.Add("[Web Snippet 1/1] $($search.WebVal)")
        }
    }

    $search.Device.SearchResults = $newResults

    # Remove from active searches
    $script:ActiveSearches.Remove($InstanceId)
}

# Update all active background lookups (Invoked inside key polling)
function Update-ActiveSearches {
    $completedIds = [System.Collections.Generic.List[string]]::new()

    foreach ($instanceId in @($script:ActiveSearches.Keys)) {
        $search = $script:ActiveSearches[$instanceId]

        $spinner = @('|', '/', '-', '\')
        $search.SpinnerIndex = ($search.SpinnerIndex + 1) % $spinner.Count
        $spChar = $spinner[$search.SpinnerIndex]
        $elapsed = [int]((Get-Date) - $search.StartTime).TotalSeconds

        # 1. Process Web/Local Search
        if ($null -ne $search.PsWeb) {
            while ($search.OutputWeb.Count -gt 0) {
                $data = $search.OutputWeb[0]
                $search.OutputWeb.RemoveAt(0)
                if ($null -ne $data) {
                    if ($data.Source -eq 'Local') {
                        $search.LocalVal = $data.Result
                        $search.LocalState = $data.Status
                    }
                    elseif ($data.Source -eq 'Evidence') {
                        $search.EvidenceVal = $data.Result
                        $search.EvidenceState = $data.Status
                        $search.EvidencePath = $data.Path
                        $search.DeviceEvidence = $data.Evidence
                    }
                    elseif ($data.Source -eq 'Web') {
                        $search.WebVal = $data.Result
                        $search.WebState = $data.Status
                        if ($data.Snippets) {
                            $search.WebSnippets = $data.Snippets
                        }
                    }
                }
            }

            if ($search.AsyncWeb.IsCompleted) {
                try {
                    $resList = $search.PsWeb.EndInvoke($search.AsyncWeb)
                    if ($null -ne $resList) {
                        foreach ($data in $resList) {
                            if ($null -ne $data) {
                                if ($data.Source -eq 'Local') {
                                    $search.LocalVal = $data.Result
                                    $search.LocalState = $data.Status
                                }
                                elseif ($data.Source -eq 'Evidence') {
                                    $search.EvidenceVal = $data.Result
                                    $search.EvidenceState = $data.Status
                                    $search.EvidencePath = $data.Path
                                    $search.DeviceEvidence = $data.Evidence
                                }
                                elseif ($data.Source -eq 'Web') {
                                    $search.WebVal = $data.Result
                                    $search.WebState = $data.Status
                                    if ($data.Snippets) {
                                        $search.WebSnippets = $data.Snippets
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    $search.WebState = 'Error'
                    $search.WebVal = "Runspace failed: $($_.Exception.Message)"
                }
                if ($search.WebState -eq 'Searching') { $search.WebState = 'Done' }
                if ($search.LocalState -eq 'Searching') { $search.LocalState = 'Done' }
                if ($search.EvidenceState -eq 'Searching') { $search.EvidenceState = 'Done' }
                try { $search.PsWeb.Dispose() } catch {}
                $search.PsWeb = $null
                $search.AsyncWeb = $null
            }
        }

        # 2. Trigger AI Runspaces if Web search finished and AI not started yet
        if ($search.UseAgent) {
            if ($search.AgentState -eq 'Waiting' -and ($search.WebState -eq 'Done' -or $search.WebState -eq 'Error')) {
                $search.AgentState = 'Searching'

                $deviceName = $search.Device.FriendlyName
                $instanceId = $search.Device.InstanceId
                $hardwareId = $instanceId

                $manufacturer = ""
                $installedDriver = ""
                if ($search.DeviceEvidence) {
                    try {
                        $importantProperties = $search.DeviceEvidence.ImportantProperties
                        $manufacturer = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_Manufacturer'
                        $hwIds = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_HardwareIds'
                        if ($hwIds) {
                            $hardwareId = if ($hwIds -is [array]) { $hwIds[0] } else { $hwIds }
                        }
                        if ($search.DeviceEvidence.SignedDriver) {
                            $driver = $search.DeviceEvidence.SignedDriver
                            $installedDriver = "$($driver.DriverProviderName) $($driver.DriverVersion) ($($driver.InfName))"
                        }
                    } catch {}
                }

                $motherboard = ""
                $cpu = ""
                $os = ""
                if ($script:MachineEvidence) {
                    try {
                        $motherboard = "$($script:MachineEvidence.ComputerSystem.Manufacturer) $($script:MachineEvidence.ComputerSystem.Model) (Board: $($script:MachineEvidence.BaseBoard.Product))"
                        $cpu = $script:MachineEvidence.Processor.Name
                        $os = "$($script:MachineEvidence.OperatingSystem.Caption) $($script:MachineEvidence.OperatingSystem.OSArchitecture)"
                    } catch {}
                }

                $psAgent = [PowerShell]::Create()
                $psAgent.AddScript({
                    param($DeviceName, $InstanceId, $HardwareId, $Manufacturer, $InstalledDriver, $Motherboard, $Cpu, $Os, $ApiKey, $AgentScriptPath, $TracePath, $CheckpointPath, $ToolCacheRoot, $MaxIterations)
                    $ProgressPreference = 'SilentlyContinue'
                    & $AgentScriptPath -DeviceName $DeviceName -InstanceId $InstanceId -HardwareId $HardwareId -Manufacturer $Manufacturer -InstalledDriver $InstalledDriver -Motherboard $Motherboard -Cpu $Cpu -Os $Os -ApiKey $ApiKey -TracePath $TracePath -CheckpointPath $CheckpointPath -ToolCacheRoot $ToolCacheRoot -MaxIterations $MaxIterations
                })

                $agentScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Get-DriverUpdateAgent.ps1'
                $null = $psAgent.AddArgument($deviceName)
                $null = $psAgent.AddArgument($instanceId)
                $null = $psAgent.AddArgument($hardwareId)
                $null = $psAgent.AddArgument($manufacturer)
                $null = $psAgent.AddArgument($installedDriver)
                $null = $psAgent.AddArgument($motherboard)
                $null = $psAgent.AddArgument($cpu)
                $null = $psAgent.AddArgument($os)
                $null = $psAgent.AddArgument($search.ApiKey)
                $null = $psAgent.AddArgument($agentScriptPath)
                $null = $psAgent.AddArgument($search.AgentTracePath)
                $null = $psAgent.AddArgument($search.AgentCheckpointPath)
                $null = $psAgent.AddArgument($search.AgentToolCacheRoot)
                $null = $psAgent.AddArgument(10)

                $search.AgentInput = [System.Management.Automation.PSDataCollection[PSObject]]::new()
                $search.AgentInput.Complete()
                $search.AgentOutput = [System.Management.Automation.PSDataCollection[PSObject]]::new()
                $search.AgentOutputIndex = 0
                $search.AgentAsync = $psAgent.BeginInvoke($search.AgentInput, $search.AgentOutput)
                $search.AgentPs = $psAgent
            }
            $search.Device.SearchCheckpointPath = $search.AgentCheckpointPath
        } else {
            $hasPendingModel = @($search.ModelRuns | Where-Object { -not $_.Started -and $_.State -ne 'None' }).Count -gt 0
            if (($search.WebState -eq 'Done' -or $search.WebState -eq 'Error') -and $hasPendingModel) {

                $evidenceLines = [System.Collections.Generic.List[string]]::new()
                if ($search.DeviceEvidence) {
                    try {
                        $machine = $search.DeviceEvidence.Machine
                        $evidenceLines.Add("System: $($machine.ComputerSystem.Manufacturer) $($machine.ComputerSystem.Model); Board: $($machine.BaseBoard.Product); BIOS: $($machine.BIOS.SMBIOSBIOSVersion); OS: $($machine.OperatingSystem.Caption) $($machine.OperatingSystem.OSArchitecture)")
                    } catch {}
                    try {
                        $evidenceLines.Add("Device: $($search.DeviceEvidence.Device.FriendlyName); InstanceId: $($search.DeviceEvidence.Device.InstanceId); Class: $($search.DeviceEvidence.Device.Class); Status: $($search.DeviceEvidence.Device.Status); ProblemCode: $($search.DeviceEvidence.Device.ConfigManagerErrorCode)")
                    } catch {}
                    try {
                        $importantProperties = $search.DeviceEvidence.ImportantProperties
                        $hardwareIds = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_HardwareIds'
                        if ($hardwareIds) { $evidenceLines.Add("HardwareIds: $($hardwareIds -join '; ')") }
                    } catch {}
                    try {
                        $importantProperties = $search.DeviceEvidence.ImportantProperties
                        $compatibleIds = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_CompatibleIds'
                        if ($compatibleIds) { $evidenceLines.Add("CompatibleIds: $($compatibleIds -join '; ')") }
                    } catch {}
                    try {
                        $importantProperties = $search.DeviceEvidence.ImportantProperties
                        $service = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_Service'
                        if ($service) { $evidenceLines.Add("Service: $service") }
                    } catch {}
                    try {
                        if ($search.DeviceEvidence.SignedDriver) {
                            $driver = $search.DeviceEvidence.SignedDriver
                            $evidenceLines.Add("InstalledDriver: $($driver.DriverProviderName); $($driver.DriverVersion); INF: $($driver.InfName)")
                        }
                    } catch {}
                }
                if ($evidenceLines.Count -eq 0) {
                    $evidenceLines.Add("Local evidence unavailable.")
                }

                $prompt = "You are a hardware expert. Use local Windows evidence first and web snippets second. For Hardware ID '$($search.Device.InstanceId)', synthesize a single concise line (max 90 chars) with likely manufacturer/model and driver/troubleshooting tip. Do not use markdown, bolding, or lists. Use 'likely' if evidence is weak.`nLocal evidence:`n" + ($evidenceLines -join "`n") + "`nSnippets:`n" + ($search.WebSnippets -join "`n")

                foreach ($run in $search.ModelRuns) {
                if ($run.Started -or $run.State -eq 'None') { continue }
                $run.Started = $true
                $run.State = 'Searching'

                $ps = [PowerShell]::Create()
                if ($run.Provider -eq 'Gemini') {
                    $ps.AddScript({
                        param($PromptText, $resolvedApiKey, $resolvedModelName)
                        $ProgressPreference = 'SilentlyContinue'
                        $body = @{
                            contents = @(
                                @{ parts = @( @{ text = $PromptText } ) }
                            )
                        } | ConvertTo-Json -Depth 5

                        $uri = "https://generativelanguage.googleapis.com/v1beta/models/$($resolvedModelName):generateContent?key=$resolvedApiKey"

                        try {
                            $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 30
                            if ($response -and $response.candidates -and $response.candidates[0].content.parts[0].text) {
                                $geminiSummary = $response.candidates[0].content.parts[0].text.Trim()
                                return [PSCustomObject]@{ Status = 'Done'; Result = $geminiSummary }
                            } else {
                                return [PSCustomObject]@{ Status = 'Error'; Result = "Empty response from Gemini API." }
                            }
                        } catch {
                            $msg = $_.Exception.Message
                            if ($_.Exception.Response) {
                                $status = [int]$_.Exception.Response.StatusCode
                                if ($status -eq 429) {
                                    $msg = "Rate limit exceeded (429 Too Many Requests)."
                                } elseif ($status -eq 403) {
                                    $msg = "Access Forbidden (403). Check API Key validity."
                                } elseif ($status -eq 404) {
                                    $msg = "Model/Endpoint not found (404)."
                                }
                            }
                            return [PSCustomObject]@{ Status = 'Error'; Result = $msg }
                        }
                    })
                } else {
                    $ps.AddScript({
                        param($PromptText, $resolvedOpenRouterKey, $resolvedModelName)
                        $ProgressPreference = 'SilentlyContinue'
                        $orBody = @{
                            model = $resolvedModelName
                            messages = @(
                                @{ role = "user"; content = $PromptText }
                            )
                        } | ConvertTo-Json -Depth 5

                        $headers = @{
                            "Authorization" = "Bearer $resolvedOpenRouterKey"
                            "HTTP-Referer"  = "https://github.com/joty79/DeviceCheck"
                            "X-Title"       = "DeviceCheck Manager"
                        }

                        try {
                            $response = Invoke-RestMethod -Uri "https://openrouter.ai/api/v1/chat/completions" `
                                -Method Post `
                                -Headers $headers `
                                -ContentType "application/json" `
                                -Body $orBody `
                                -TimeoutSec 30

                            if ($response -and $response.choices -and $response.choices[0].message.content) {
                                $openRouterSummary = $response.choices[0].message.content.Trim()
                                return [PSCustomObject]@{ Status = 'Done'; Result = $openRouterSummary }
                            } else {
                                return [PSCustomObject]@{ Status = 'Error'; Result = "Empty response from OpenRouter API." }
                            }
                        } catch {
                            return [PSCustomObject]@{ Status = 'Error'; Result = $_.Exception.Message }
                        }
                    })
                }

                $null = $ps.AddArgument($prompt)
                $null = $ps.AddArgument($run.ApiKey)
                $null = $ps.AddArgument($run.ModelName)

                $run.Output = [System.Management.Automation.PSDataCollection[PSObject]]::new()
                $run.Async = $ps.BeginInvoke($run.Output)
                $run.Ps = $ps
            }
            }
        }

        # 3. Process Agent Runspace Output
        if ($null -ne $search.AgentPs) {
            while ($null -ne $search.AgentOutput -and $search.AgentOutputIndex -lt $search.AgentOutput.Count) {
                $data = $search.AgentOutput[$search.AgentOutputIndex]
                $search.AgentOutputIndex++
                if ($null -ne $data) {
                    if ($data.Type -eq 'Log') {
                        $search.AgentLogs.Add($data.Message)
                    } elseif ($data.Type -eq 'Result') {
                        $search.AgentState = 'Done'
                        $search.AgentVal = $data.Message
                    } elseif ($data.Type -eq 'Error') {
                        $search.AgentState = 'Error'
                        $search.AgentVal = $data.Message
                    } elseif ($data.Type -eq 'PausedRateLimit') {
                        $search.AgentState = 'PausedRateLimit'
                        $search.AgentVal = $data.Message
                    } elseif ($data.Type -eq 'PausedBudget') {
                        $search.AgentState = 'PausedBudget'
                        $search.AgentVal = $data.Message
                    }
                }
            }

            if ($search.AgentAsync.IsCompleted) {
                try {
                    $resList = $search.AgentPs.EndInvoke($search.AgentAsync)
                    if ($search.AgentState -eq 'Searching') {
                        if ($null -ne $resList -and $resList.Count -gt 0) {
                            foreach ($item in $resList) {
                                if ($item.Type -eq 'Result') {
                                    $search.AgentState = 'Done'
                                    $search.AgentVal = $item.Message
                                } elseif ($item.Type -eq 'Error') {
                                    $search.AgentState = 'Error'
                                    $search.AgentVal = $item.Message
                                } elseif ($item.Type -eq 'PausedRateLimit') {
                                    $search.AgentState = 'PausedRateLimit'
                                    $search.AgentVal = $item.Message
                                } elseif ($item.Type -eq 'PausedBudget') {
                                    $search.AgentState = 'PausedBudget'
                                    $search.AgentVal = $item.Message
                                }
                            }
                        }
                        if ($search.AgentState -eq 'Searching') {
                            $search.AgentState = 'Error'
                            $search.AgentVal = "Agent terminated unexpectedly without returning result."
                        }
                    }
                } catch {
                    $search.AgentState = 'Error'
                    $search.AgentVal = $_.Exception.Message
                }
                try { $search.AgentPs.Dispose() } catch {}
                $search.AgentPs = $null
                $search.AgentAsync = $null
                $search.AgentInput = $null
            }
        }

        # 4. Process Model Runspace Output
        foreach ($run in $search.ModelRuns) {
            if ($null -ne $run.Ps) {
                while ($run.Output.Count -gt 0) {
                    $data = $run.Output[0]
                    $run.Output.RemoveAt(0)
                    if ($null -ne $data) {
                        $run.State = $data.Status
                        $run.Val = $data.Result
                    }
                }

                if ($run.Async.IsCompleted) {
                    try {
                        $resList = $run.Ps.EndInvoke($run.Async)
                        if ($run.State -eq 'Searching') {
                            if ($null -ne $resList -and $resList.Count -gt 0 -and $null -ne $resList[0]) {
                                $run.State = $resList[0].Status
                                $run.Val = $resList[0].Result
                                $run.Duration = $elapsed
                            } else {
                                $run.State = 'Error'
                                $run.Val = "Empty response from $($run.Provider) API."
                                $run.Duration = $elapsed
                            }
                        }
                    } catch {
                        $run.State = 'Error'
                        $run.Val = $_.Exception.Message
                        $run.Duration = $elapsed
                    }
                    try { $run.Ps.Dispose() } catch {}
                    $run.Ps = $null
                    $run.Async = $null
                }
            }
        }

        # Rebuild Results list
        $newResults = [System.Collections.Generic.List[string]]::new()

        # Display results for each model run
        if ($search.UseAgent) {
            $search.Device.SearchKind = 'Agent'
            $search.Device.SearchTracePath = $search.AgentTracePath
            $search.Device.SearchCheckpointPath = $search.AgentCheckpointPath
            if ($search.AgentState -eq 'Waiting') {
                $newResults.Add("[Agent: gemini-3.1-flash-lite] (Waiting for local evidence...)")
                $search.Device.SearchDetail = $null
            } elseif ($search.AgentState -eq 'Searching') {
                $newResults.Add("[Agent: gemini-3.1-flash-lite] (Running... $spChar ${elapsed}s)")
                $search.Device.SearchDetail = $null
            } elseif ($search.AgentState -eq 'Done') {
                $newResults.Add("[Agent: gemini-3.1-flash-lite] (Done)")
                $search.Device.SearchDetail = $search.AgentVal
            } elseif ($search.AgentState -eq 'Error') {
                $newResults.Add("[Agent: gemini-3.1-flash-lite] (Failed)")
                $search.Device.SearchDetail = $search.AgentVal
            } elseif ($search.AgentState -eq 'PausedRateLimit') {
                $newResults.Add("[Agent: gemini-3.1-flash-lite] (Paused: Rate limit)")
                $search.Device.SearchDetail = $search.AgentVal
            } elseif ($search.AgentState -eq 'PausedBudget') {
                $newResults.Add("[Agent: gemini-3.1-flash-lite] (Paused: Budget)")
                $search.Device.SearchDetail = $search.AgentVal
            }
        } else {
            foreach ($run in $search.ModelRuns) {
                if ($run.State -eq 'Waiting') {
                    $newResults.Add("[$($run.Provider): $($run.ModelName)] (Waiting for web search...)")
                } elseif ($run.State -eq 'Searching') {
                    $newResults.Add("[$($run.Provider): $($run.ModelName)] (Searching... $spChar ${elapsed}s)")
                } elseif ($run.State -eq 'Done') {
                    $durationStr = if ($null -ne $run.Duration) { "in $($run.Duration)s" } else { "Done" }
                    $newResults.Add("[$($run.Provider): $($run.ModelName)] (Done $durationStr)")
                    $newResults.Add("  $($run.Val)")
                } elseif ($run.State -eq 'Error') {
                    $durationStr = if ($null -ne $run.Duration) { " after $($run.Duration)s" } else { "" }
                    $newResults.Add("[$($run.Provider) Error: $($run.ModelName)] (Failed$durationStr)")
                    $newResults.Add("  $($run.Val)")
                }
            }

            # Local DB display
            if ($search.LocalState -eq 'Done' -and $search.LocalVal) {
                $newResults.Add($search.LocalVal)
            }

            # Web Snippet display
            if ($search.WebState -eq 'Searching') {
                $newResults.Add("[Web Snippet] (Searching... $spChar ${elapsed}s)")
            } elseif ($search.WebState -eq 'Done' -and $search.WebSnippets -and $search.WebSnippets.Count -gt 0) {
                for ($snippetIndex = 0; $snippetIndex -lt $search.WebSnippets.Count; $snippetIndex++) {
                    $snippetNumber = $snippetIndex + 1
                    $newResults.Add("[Web Snippet $snippetNumber/$($search.WebSnippets.Count)] $($search.WebSnippets[$snippetIndex])")
                }
            } elseif ($search.WebState -eq 'Done' -and $search.WebVal) {
                $newResults.Add("[Web Snippet 1/1] $($search.WebVal)")
            } elseif ($search.WebState -eq 'Error') {
                $newResults.Add("[Web Snippet Error] $($search.WebVal)")
            }
        }

        $search.Device.SearchResults = $newResults

        # Check if completed
        $finished = $true
        if ($null -ne $search.PsWeb) { $finished = $false }
        if ($null -ne $search.AgentPs) { $finished = $false }
        foreach ($run in $search.ModelRuns) {
            if ($null -ne $run.Ps) { $finished = $false }
            if ($run.State -eq 'Waiting') { $finished = $false }
        }

        if ($finished) {
            $completedIds.Add($instanceId)
        }
    }

    foreach ($id in $completedIds) {
        $completedSearch = $script:ActiveSearches[$id]
        if ($completedSearch.EvidenceState -eq 'Done' -and $completedSearch.EvidencePath) {
            $completedSearch.Device.EvidenceCached = $true
        }
        $completedBatchId = Get-NotePropertyValue -Object $completedSearch -Name 'EvidenceBatchId'
        if ($null -ne $script:EvidenceBatchState -and $completedBatchId -eq $script:EvidenceBatchState.BatchId) {
            $script:EvidenceBatchState.Completed++
            if ($completedSearch.EvidenceState -eq 'Error') {
                $script:EvidenceBatchState.Errors++
            }
        }
        $script:ActiveSearches.Remove($id)
    }

    Start-PendingEvidenceBatchScans
    Complete-EvidenceBatchIfFinished
}

# Override Read-ConsoleKey to support background search ticks & smooth rendering
function Read-ConsoleKey {
    try { [Console]::CursorVisible = $false } catch {}

    $keyName = $null
    $keyChar = [char]0
    $virtualKeyCode = $null

    try {
        while (-not [Console]::KeyAvailable) {
            if (Test-WindowResized) {
                return [pscustomobject]@{
                    Key            = 'ResizeEvent'
                    KeyChar        = [char]0
                    VirtualKeyCode = 0
                }
            }

            # Update active/pending background searches and redraw
            if ($script:ActiveSearches.Count -gt 0 -or $script:EvidenceBatchQueue.Count -gt 0) {
                Update-ActiveSearches
                $script:visibleRows = Update-VisibleRows
                if ($script:visibleRows.Count -gt 0) {
                    $script:selectedIndex = [Math]::Max(0, [Math]::Min($script:selectedIndex, $script:visibleRows.Count - 1))
                } else {
                    $script:selectedIndex = 0
                }
                Render-Frame
                Start-Sleep -Milliseconds 150
            } else {
                Start-Sleep -Milliseconds 40
            }
        }

        $keyInfo = $null
        try {
            $keyInfo = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }
        catch {
            $keyInfo = [Console]::ReadKey($true)
        }

        if ($null -ne $keyInfo) {
            if ($keyInfo.PSObject.Properties['Key']) {
                $keyName = [string]$keyInfo.Key
            }
            elseif ($keyInfo.PSObject.Properties['VirtualKeyCode']) {
                $virtualKeyCode = [int]$keyInfo.VirtualKeyCode
                try {
                    $keyName = [string][System.Enum]::ToObject([System.ConsoleKey], $virtualKeyCode)
                }
                catch {
                    $keyName = [string]$virtualKeyCode
                }
            }

            if ($keyInfo.PSObject.Properties['KeyChar']) {
                $keyChar = [char]$keyInfo.KeyChar
            }
            elseif ($keyInfo.PSObject.Properties['Character']) {
                $keyChar = [char]$keyInfo.Character
            }
        }
    }
    catch {
        throw $_
    }

    return [pscustomobject]@{
        Key            = $keyName
        KeyChar        = $keyChar
        VirtualKeyCode = $virtualKeyCode
    }
}

# Initial categories detection
Invoke-SystemScan
$selectedIndex = 0
$running = $true

try {
    [Console]::CursorVisible = $false

    while ($running) {
        Lock-ViewportToWindow

        # Calculate current visible rows
        $script:visibleRows = Update-VisibleRows

        # Clamp selected index to selectable types (Root / Category / Device / Result)
        if ($visibleRows.Count -eq 0) {
            $selectedIndex = 0
        } else {
            $selectedIndex = [Math]::Max(0, [Math]::Min($selectedIndex, $visibleRows.Count - 1))
            while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Root', 'Category', 'Device', 'Result')) {
                $selectedIndex--
            }
        }

        # Render viewport
        Render-Frame

        # Key Handling
        $key = Read-ConsoleKey
        if ($null -eq $key -or -not $key.PSObject.Properties['Key']) {
            Start-Sleep -Milliseconds 50
            continue
        }
        switch ($key.Key) {
            'UpArrow' {
                if ($selectedIndex -gt 0) {
                    $idx = $selectedIndex - 1
                    while ($idx -gt 0 -and $visibleRows[$idx].Type -notin @('Root', 'Category', 'Device', 'Result')) {
                        $idx--
                    }
                    if ($visibleRows[$idx].Type -in @('Root', 'Category', 'Device', 'Result')) {
                        $selectedIndex = $idx
                    }
                }
            }
            'DownArrow' {
                if ($selectedIndex -lt ($visibleRows.Count - 1)) {
                    $idx = $selectedIndex + 1
                    while ($idx -lt ($visibleRows.Count - 1) -and $visibleRows[$idx].Type -notin @('Root', 'Category', 'Device', 'Result')) {
                        $idx++
                    }
                    if ($visibleRows[$idx].Type -in @('Root', 'Category', 'Device', 'Result')) {
                        $selectedIndex = $idx
                    }
                }
            }
            'PageUp' {
                $selectedIndex = [Math]::Max(0, $selectedIndex - 10)
                while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Root', 'Category', 'Device', 'Result')) {
                    $selectedIndex--
                }
            }
            'PageDown' {
                $selectedIndex = [Math]::Min($visibleRows.Count - 1, $selectedIndex + 10)
                while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Root', 'Category', 'Device', 'Result')) {
                    $selectedIndex--
                }
            }
            'Home' {
                $selectedIndex = 0
            }
            'End' {
                $selectedIndex = $visibleRows.Count - 1
                while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Root', 'Category', 'Device', 'Result')) {
                    $selectedIndex--
                }
            }
            'RightArrow' {
                $currentRow = $visibleRows[$selectedIndex]
                Expand-SelectedNode -Row $currentRow
            }
            'LeftArrow' {
                $currentRow = $visibleRows[$selectedIndex]
                Collapse-SelectedNode -Row $currentRow
                $selectedIndex = $script:selectedIndex
            }
            'Add' {
                $currentRow = $visibleRows[$selectedIndex]
                Expand-SelectedNode -Row $currentRow
            }
            'OemPlus' {
                $currentRow = $visibleRows[$selectedIndex]
                Expand-SelectedNode -Row $currentRow
            }
            'Subtract' {
                $currentRow = $visibleRows[$selectedIndex]
                Collapse-SelectedNode -Row $currentRow
                $selectedIndex = $script:selectedIndex
            }
            'OemMinus' {
                $currentRow = $visibleRows[$selectedIndex]
                Collapse-SelectedNode -Row $currentRow
                $selectedIndex = $script:selectedIndex
            }
            'R' {
                Invoke-SystemScanWithFeedback -Quiet
                $selectedIndex = $script:selectedIndex
            }
            'E' {
                $currentRow = $visibleRows[$selectedIndex]
                if ($currentRow.Type -eq 'Root') {
                    Start-AllEvidenceScan
                } elseif ($currentRow.Type -eq 'Category') {
                    Start-CategoryEvidenceScan -Category $currentRow.Ref
                } elseif ($currentRow.Type -eq 'Device') {
                    Start-DeviceLookup -Dev $currentRow.Ref -EvidenceOnly -ForceEvidenceRefresh
                } elseif ($currentRow.Type -in @('Result', 'Status') -and $null -ne $currentRow.ParentDevice) {
                    Start-DeviceLookup -Dev $currentRow.ParentDevice -EvidenceOnly -ForceEvidenceRefresh
                }
            }
            'S' {
                $currentRow = $visibleRows[$selectedIndex]
                if ($currentRow.Type -eq 'Device') {
                    Start-DeviceLookup -Dev $currentRow.Ref -ForceEvidenceRefresh
                } elseif ($currentRow.Type -in @('Result', 'Status') -and $null -ne $currentRow.ParentDevice) {
                    Start-DeviceLookup -Dev $currentRow.ParentDevice -ForceEvidenceRefresh
                }
            }
            'A' {
                $currentRow = $visibleRows[$selectedIndex]
                if ($currentRow.Type -eq 'Device') {
                    Start-DeviceLookup -Dev $currentRow.Ref -UseAgent -ForceEvidenceRefresh
                } elseif ($currentRow.Type -in @('Result', 'Status') -and $null -ne $currentRow.ParentDevice) {
                    Start-DeviceLookup -Dev $currentRow.ParentDevice -UseAgent -ForceEvidenceRefresh
                }
            }
            'M' {
                Invoke-ModelSelector
            }
            'Escape' {
                $running = $false
            }
            'q' {
                $running = $false
            }
            'ResizeEvent' {
                continue
            }
            default {
                # Handle lowercase hotkeys from hosts that do not map Key names consistently.
                if ($key.KeyChar -eq 'r') {
                    Invoke-SystemScanWithFeedback -Quiet
                    $selectedIndex = $script:selectedIndex
                } elseif ($key.KeyChar -eq 'e') {
                    $currentRow = $visibleRows[$selectedIndex]
                    if ($currentRow.Type -eq 'Root') {
                        Start-AllEvidenceScan
                    } elseif ($currentRow.Type -eq 'Category') {
                        Start-CategoryEvidenceScan -Category $currentRow.Ref
                    } elseif ($currentRow.Type -eq 'Device') {
                        Start-DeviceLookup -Dev $currentRow.Ref -EvidenceOnly -ForceEvidenceRefresh
                    } elseif ($currentRow.Type -in @('Result', 'Status') -and $null -ne $currentRow.ParentDevice) {
                        Start-DeviceLookup -Dev $currentRow.ParentDevice -EvidenceOnly -ForceEvidenceRefresh
                    }
                } elseif ($key.KeyChar -eq 's') {
                    $currentRow = $visibleRows[$selectedIndex]
                    if ($currentRow.Type -eq 'Device') {
                        Start-DeviceLookup -Dev $currentRow.Ref -ForceEvidenceRefresh
                    } elseif ($currentRow.Type -in @('Result', 'Status') -and $null -ne $currentRow.ParentDevice) {
                        Start-DeviceLookup -Dev $currentRow.ParentDevice -ForceEvidenceRefresh
                    }
                } elseif ($key.KeyChar -eq 'a') {
                    $currentRow = $visibleRows[$selectedIndex]
                    if ($currentRow.Type -eq 'Device') {
                        Start-DeviceLookup -Dev $currentRow.Ref -UseAgent -ForceEvidenceRefresh
                    } elseif ($currentRow.Type -in @('Result', 'Status') -and $null -ne $currentRow.ParentDevice) {
                        Start-DeviceLookup -Dev $currentRow.ParentDevice -UseAgent -ForceEvidenceRefresh
                    }
                } elseif ($key.KeyChar -eq 'm') {
                    Invoke-ModelSelector
                } elseif ($key.KeyChar -eq '+') {
                    $currentRow = $visibleRows[$selectedIndex]
                    Expand-SelectedNode -Row $currentRow
                } elseif ($key.KeyChar -eq '-') {
                    $currentRow = $visibleRows[$selectedIndex]
                    Collapse-SelectedNode -Row $currentRow
                    $selectedIndex = $script:selectedIndex
                }
            }
        }
    }
}
finally {
    # Stop and dispose all active searches
    if ($null -ne $script:ActiveSearches) {
        foreach ($id in @($script:ActiveSearches.Keys)) {
            Stop-DeviceLookup -InstanceId $id
        }
    }
    if ($null -ne $script:EvidenceBatchQueue) { $script:EvidenceBatchQueue.Clear() }
    if ($null -ne $script:EvidenceBatchQueuedIds) { $script:EvidenceBatchQueuedIds.Clear() }
    # Restore Host Settings
    Restore-TuiHost
    Write-Host 'DeviceCheck closed.'
}
