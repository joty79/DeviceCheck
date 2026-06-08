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
$script:DeviceCheckRepoRoot = $PSScriptRoot
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
$env:DEVICECHECK_CHROME_PROFILE = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'browser-profile'

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

function Clear-TuiScreen {
    try {
        [Console]::Clear()
    } catch {
        try {
            [Console]::Write("$([char]27)[H$([char]27)[2J$([char]27)[3J")
        } catch {
            try { Clear-Host } catch {}
        }
    }
}

function Get-DeviceCheckStoredCredential {
    param([string]$ComputerName)

    if ([string]::IsNullOrWhiteSpace($ComputerName)) { return $null }
    $credFolder = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'credentials'
    $credPath = Join-Path -Path $credFolder -ChildPath "$($ComputerName.ToLower()).xml"
    if (Test-Path -LiteralPath $credPath -PathType Leaf) {
        try {
            return Import-Clixml -Path $credPath -ErrorAction Stop
        } catch {
            return $null
        }
    }
    return $null
}

function Save-DeviceCheckStoredCredential {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential
    )

    if ([string]::IsNullOrWhiteSpace($ComputerName) -or $null -eq $Credential) { return }
    $credFolder = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'credentials'
    try {
        $null = New-Item -ItemType Directory -Path $credFolder -Force -ErrorAction SilentlyContinue
        $credPath = Join-Path -Path $credFolder -ChildPath "$($ComputerName.ToLower()).xml"
        $Credential | Export-Clixml -Path $credPath
    } catch {}
}

function Remove-DeviceCheckStoredCredential {
    param([string]$ComputerName)

    if ([string]::IsNullOrWhiteSpace($ComputerName)) { return }
    $credFolder = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'credentials'
    $credPath = Join-Path -Path $credFolder -ChildPath "$($ComputerName.ToLower()).xml"
    if (Test-Path -LiteralPath $credPath -PathType Leaf) {
        try {
            Remove-Item -LiteralPath $credPath -Force -ErrorAction SilentlyContinue
        } catch {}
    }
    if ($null -ne $script:CredentialCache) {
        $script:CredentialCache.Remove($ComputerName.ToLower())
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
        $targetName = if (-not [string]::IsNullOrWhiteSpace($script:TargetComputerName)) { $script:TargetComputerName } else { Get-MachineDisplayName -MachineEvidence $script:MachineEvidence }
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
    $candidates = @(
        Get-ChildItem -LiteralPath $snapshotRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$target-*" } |
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
            if ($snapshotName.Equals($target, [System.StringComparison]::OrdinalIgnoreCase) -or $folder.Name.StartsWith("$target-", [System.StringComparison]::OrdinalIgnoreCase)) {
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

$script:MachineEvidence = Get-MachineEvidence
$script:MachineCacheRoot = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath "machines\$($script:MachineEvidence.MachineId)"
try { $null = New-Item -ItemType Directory -Path $script:MachineCacheRoot -Force } catch {}
$script:SystemScanMessage = "Welcome to DeviceCheck Manager. Navigate the tree to inspect device properties."
$script:TargetMode = 'Local'
$script:TargetComputerName = Get-MachineDisplayName -MachineEvidence $script:MachineEvidence
$script:TargetCredential = $null
$script:CredentialCache = @{}
$script:TargetSnapshot = $null
$script:TargetSnapshotPath = $null
$script:HardwareIdResolverState = 'NotLoaded'
$script:HardwareIdResolverError = ''
$script:HardwareIdDatabaseCache = $null
$script:HardwareIdResolutionDisplayCache = @{}
$script:HardwareIdResolutionDetailCache = @{}
$script:BoardModelEvidenceState = 'NotLoaded'
$script:BoardModelEvidenceError = ''
$script:BoardModelEvidenceIndex = @{}
$script:AlsaUcmResolverState = 'NotLoaded'
$script:AlsaUcmResolverError = ''
$script:AlsaUcmUsbAudioProfileCache = $null
$script:MonitorEdidResolverState = 'NotLoaded'
$script:MonitorEdidResolverError = ''
$script:MonitorEdidIdentityCache = @{}
$script:MonitorWmiEvidenceCache = @{}
$script:MonitorInfEvidenceCache = @{}
$script:EvidenceCacheMemory = @{}
$script:SdioAuditCacheMemory = @{}
$script:AnsiOscRegex = [regex]::new([string]([char]27) + '\][^\a]*(\a|' + [string]([char]27) + '\\)', 'Compiled')
$script:AnsiCsiRegex = [regex]::new([string]([char]27) + '\[[0-9;?]*[A-Za-z]', 'Compiled')
$script:VisibleRowsDirty = $true
$script:RequestForceClear = $true
$script:BenchmarkLog = [System.Collections.Generic.List[string]]::new()
$script:LastKeyTimestamp = [datetime]::MinValue
$script:TuiPerfLast = $null

function Test-HardwareIdCacheReady {
    param(
        [string]$CacheRoot
    )

    if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
        return $false
    }

    $normalizedRoot = Join-Path -Path $CacheRoot -ChildPath 'normalized'
    foreach ($fileName in @('pci.json', 'usb.json', 'pnp.json')) {
        $filePath = Join-Path -Path $normalizedRoot -ChildPath $fileName
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            return $false
        }
    }

    return $true
}

function Update-HardwareIdCacheIfMissing {
    param(
        [string]$CacheRoot
    )

    if (Test-HardwareIdCacheReady -CacheRoot $CacheRoot) {
        return
    }

    $updateScriptPath = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'internal\Update-HardwareIdDatabases.ps1'
    if (-not (Test-Path -LiteralPath $updateScriptPath -PathType Leaf)) {
        throw "Hardware ID cache is missing and updater was not found: $updateScriptPath"
    }

    $null = & $updateScriptPath -OutputRoot $CacheRoot -ErrorAction Stop *>&1

    if (-not (Test-HardwareIdCacheReady -CacheRoot $CacheRoot)) {
        throw "Hardware ID cache updater completed, but normalized cache files are still missing under: $CacheRoot"
    }
}

function Initialize-HardwareIdResolver {
    if ($script:HardwareIdResolverState -ne 'NotLoaded') {
        return
    }

    $script:HardwareIdResolverState = 'Unavailable'
    $script:HardwareIdResolverError = ''

    try {
        $modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'internal\HardwareIdResolver.psm1'
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            $script:HardwareIdResolverError = "Resolver module not found: $modulePath"
            return
        }

        Import-Module -Name $modulePath -Force -ErrorAction Stop
        $cacheRoot = Join-Path -Path $PSScriptRoot -ChildPath 'data\hwdb'
        Update-HardwareIdCacheIfMissing -CacheRoot $cacheRoot
        $script:HardwareIdDatabaseCache = Import-HardwareIdDatabaseCache -CacheRoot $cacheRoot
        $script:HardwareIdResolverState = 'Ready'
    }
    catch {
        $script:HardwareIdResolverError = $_.Exception.Message
        $script:HardwareIdResolverState = 'Unavailable'
    }
}

function Test-AlsaUcmCacheReady {
    param(
        [string]$CacheRoot
    )

    $cachePath = Join-Path -Path $CacheRoot -ChildPath 'normalized\alsa-ucm-usb-audio.json'
    return (Test-Path -LiteralPath $cachePath -PathType Leaf)
}

function Update-AlsaUcmCacheIfMissing {
    param(
        [string]$CacheRoot
    )

    if (Test-AlsaUcmCacheReady -CacheRoot $CacheRoot) {
        return
    }

    $sourcePath = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'source\alsa-ucm-conf\USB-Audio.conf'
    $updateScriptPath = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'internal\Update-AlsaUcmProfiles.ps1'
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf) -or -not (Test-Path -LiteralPath $updateScriptPath -PathType Leaf)) {
        return
    }

    & $updateScriptPath -OutputRoot $CacheRoot > $null
}

function Initialize-AlsaUcmResolver {
    if ($script:AlsaUcmResolverState -ne 'NotLoaded') {
        return
    }

    $script:AlsaUcmResolverState = 'Unavailable'
    $script:AlsaUcmResolverError = ''
    $script:AlsaUcmUsbAudioProfileCache = $null

    try {
        $modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'internal\AlsaUcmResolver.psm1'
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            $script:AlsaUcmResolverError = "ALSA UCM resolver module not found: $modulePath"
            return
        }

        Import-Module -Name $modulePath -Force -ErrorAction Stop
        $cacheRoot = Join-Path -Path $PSScriptRoot -ChildPath 'data\hwdb'
        Update-AlsaUcmCacheIfMissing -CacheRoot $cacheRoot
        if (-not (Test-AlsaUcmCacheReady -CacheRoot $cacheRoot)) {
            $script:AlsaUcmResolverError = 'ALSA UCM source/cache is not available.'
            return
        }

        $script:AlsaUcmUsbAudioProfileCache = Import-AlsaUcmUsbAudioProfileCache -CacheRoot $cacheRoot
        $script:AlsaUcmResolverState = 'Ready'
    }
    catch {
        $script:AlsaUcmResolverError = $_.Exception.Message
        $script:AlsaUcmResolverState = 'Unavailable'
    }
}

function Initialize-MonitorEdidResolver {
    if ($script:MonitorEdidResolverState -ne 'NotLoaded') {
        return
    }

    $script:MonitorEdidResolverState = 'Unavailable'
    $script:MonitorEdidResolverError = ''
    $script:MonitorEdidIdentityCache = @{}
    $script:MonitorWmiEvidenceCache = @{}
    $script:MonitorInfEvidenceCache = @{}

    try {
        $modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'internal\MonitorEdidResolver.psm1'
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            $script:MonitorEdidResolverError = "Monitor EDID resolver module not found: $modulePath"
            return
        }

        Import-Module -Name $modulePath -Force -ErrorAction Stop
        $script:MonitorEdidResolverState = 'Ready'
    }
    catch {
        $script:MonitorEdidResolverError = $_.Exception.Message
        $script:MonitorEdidResolverState = 'Unavailable'
    }
}

function Get-HardwareResolutionDisplayName {
    param(
        [object]$Resolution
    )

    $lookup = Get-NotePropertyValue -Object $Resolution -Name 'Lookup'
    foreach ($name in @('SubsystemName', 'DeviceName', 'ProductName', 'InterfaceName', 'VendorName')) {
        $value = [string](Get-NotePropertyValue -Object $lookup -Name $name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return ''
}

function Get-HardwareResolutionDisplayText {
    param(
        [object]$Resolution
    )

    $bus = [string](Get-NotePropertyValue -Object $Resolution -Name 'Bus')
    $confidence = [string](Get-NotePropertyValue -Object $Resolution -Name 'Confidence')
    $displayName = Get-HardwareResolutionDisplayName -Resolution $Resolution
    $lookup = Get-NotePropertyValue -Object $Resolution -Name 'Lookup'
    $fields = Get-NotePropertyValue -Object $Resolution -Name 'Fields'
    $subvendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'SubvendorName')
    $subdeviceId = [string](Get-NotePropertyValue -Object $fields -Name 'SubdeviceId')
    $productId = [string](Get-NotePropertyValue -Object $fields -Name 'ProductId')
    $textParts = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($bus)) {
        $textParts.Add($bus)
    }
    if (-not [string]::IsNullOrWhiteSpace($confidence)) {
        $textParts.Add($confidence)
    }
    if (-not [string]::IsNullOrWhiteSpace($displayName)) {
        $textParts.Add($displayName)
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-NotePropertyValue -Object $lookup -Name 'SubsystemName')) -and
        -not [string]::IsNullOrWhiteSpace($subvendorName)) {
        $boardText = "board $subvendorName"
        if (-not [string]::IsNullOrWhiteSpace($subdeviceId)) {
            $boardText = "$boardText $subdeviceId"
        }
        $textParts.Add($boardText)
    }
    if ($bus -eq 'DISPLAY' -and -not [string]::IsNullOrWhiteSpace($productId)) {
        $textParts.Add("EDID product $productId")
    }

    if ($textParts.Count -eq 0) {
        return ''
    }

    return ($textParts -join ' / ')
}

function Get-ShortHardwareVendorName {
    param(
        [AllowEmptyString()][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }
    if ($Name -match '\[([^\]]+)\]\s*$') {
        return $Matches[1]
    }

    $shortName = $Name -replace '\s+Corporation$', ''
    $shortName = $shortName -replace '\s+Co\.,?\s+Ltd\.?$', ''
    $shortName = $shortName -replace ',.*$', ''
    return $shortName.Trim()
}


function Get-FormattedHardwareVendorName {
    param(
        [AllowEmptyString()][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }

    $bracketName = ''
    $baseName = $Name
    if ($Name -match '^(.*?)\s*\[([^\]]+)\]\s*$') {
        $baseName = $Matches[1]
        $bracketName = $Matches[2].Trim()
    }

    $baseName = $baseName -replace '\s+Corporation$', ''
    $baseName = $baseName -replace '\s+Co\.,?\s+Ltd\.?$', ''
    $baseName = $baseName -replace ',.*$', ''
    $baseName = $baseName.Trim()

    if ($bracketName -and $bracketName -ne $baseName) {
        return "$baseName / $bracketName"
    }

    return $baseName
}


function New-HardwareIdentityRow {
    param(
        [string]$Key,
        [AllowEmptyString()][string]$Value,
        [string]$Color = 'White'
    )

    return [PSCustomObject]@{
        Key   = $Key
        Value = $Value
        Color = $Color
    }
}

function Normalize-HardwareEvidenceId {
    param(
        [AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return (($Value -replace '^(?i:0x)', '').Trim()).ToUpperInvariant()
}

function Get-BoardModelEvidenceKey {
    param(
        [AllowEmptyString()][string]$Bus,
        [AllowEmptyString()][string]$VendorId,
        [AllowEmptyString()][string]$DeviceId,
        [AllowEmptyString()][string]$ProductId,
        [AllowEmptyString()][string]$SubvendorId,
        [AllowEmptyString()][string]$SubdeviceId,
        [AllowEmptyString()][string]$InterfaceId,
        [AllowEmptyString()][string]$Revision
    )

    $keyParts = @(
        (Normalize-HardwareEvidenceId -Value $Bus),
        (Normalize-HardwareEvidenceId -Value $VendorId),
        (Normalize-HardwareEvidenceId -Value $DeviceId),
        (Normalize-HardwareEvidenceId -Value $ProductId),
        (Normalize-HardwareEvidenceId -Value $SubvendorId),
        (Normalize-HardwareEvidenceId -Value $SubdeviceId),
        (Normalize-HardwareEvidenceId -Value $InterfaceId),
        (Normalize-HardwareEvidenceId -Value $Revision)
    )

    return ($keyParts -join '|')
}

function Add-BoardModelEvidenceIndexEntry {
    param(
        [object]$Entry
    )

    $bus = [string](Get-NotePropertyValue -Object $Entry -Name 'Bus')
    $vendorId = [string](Get-NotePropertyValue -Object $Entry -Name 'VendorId')
    $deviceId = [string](Get-NotePropertyValue -Object $Entry -Name 'DeviceId')
    $productId = [string](Get-NotePropertyValue -Object $Entry -Name 'ProductId')
    $subvendorId = [string](Get-NotePropertyValue -Object $Entry -Name 'SubvendorId')
    $subdeviceId = [string](Get-NotePropertyValue -Object $Entry -Name 'SubdeviceId')
    $interfaceId = [string](Get-NotePropertyValue -Object $Entry -Name 'InterfaceId')
    $revision = [string](Get-NotePropertyValue -Object $Entry -Name 'Revision')

    $normalizedBus = (Normalize-HardwareEvidenceId -Value $bus)
    $hasPciTuple = (
        $normalizedBus -eq 'PCI' -and
        -not [string]::IsNullOrWhiteSpace($vendorId) -and
        -not [string]::IsNullOrWhiteSpace($deviceId) -and
        -not [string]::IsNullOrWhiteSpace($subvendorId) -and
        -not [string]::IsNullOrWhiteSpace($subdeviceId)
    )
    $hasUsbTuple = (
        $normalizedBus -in @('USB', 'HID') -and
        -not [string]::IsNullOrWhiteSpace($vendorId) -and
        -not [string]::IsNullOrWhiteSpace($productId)
    )
    $hasHdAudioTuple = (
        $normalizedBus -eq 'HDAUDIO' -and
        -not [string]::IsNullOrWhiteSpace($vendorId) -and
        -not [string]::IsNullOrWhiteSpace($deviceId) -and
        -not [string]::IsNullOrWhiteSpace($subvendorId) -and
        -not [string]::IsNullOrWhiteSpace($subdeviceId)
    )
    $hasDisplayTuple = (
        $normalizedBus -eq 'DISPLAY' -and
        -not [string]::IsNullOrWhiteSpace($vendorId) -and
        -not [string]::IsNullOrWhiteSpace($productId)
    )

    if (-not ($hasPciTuple -or $hasUsbTuple -or $hasHdAudioTuple -or $hasDisplayTuple)) {
        return
    }

    foreach ($entryInterfaceId in @($interfaceId, '')) {
        foreach ($entryRevision in @($revision, '')) {
            $key = Get-BoardModelEvidenceKey -Bus $bus -VendorId $vendorId -DeviceId $deviceId -ProductId $productId -SubvendorId $subvendorId -SubdeviceId $subdeviceId -InterfaceId $entryInterfaceId -Revision $entryRevision
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                $script:BoardModelEvidenceIndex[$key] = $Entry
            }
        }
    }
}

function Initialize-BoardModelEvidenceStore {
    if ($script:BoardModelEvidenceState -ne 'NotLoaded') {
        return
    }

    $script:BoardModelEvidenceState = 'Unavailable'
    $script:BoardModelEvidenceError = ''
    $script:BoardModelEvidenceIndex = @{}

    $evidencePath = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'config\board-model-evidence.json'
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        $script:BoardModelEvidenceState = 'Ready'
        return
    }

    try {
        $payload = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($entry in @($payload.Evidence)) {
            Add-BoardModelEvidenceIndexEntry -Entry $entry
        }
        $script:BoardModelEvidenceState = 'Ready'
    }
    catch {
        $script:BoardModelEvidenceError = $_.Exception.Message
        $script:BoardModelEvidenceState = 'Unavailable'
    }
}

function Get-BoardModelEvidenceForResolution {
    param(
        [object]$Resolution
    )

    if ($script:BoardModelEvidenceState -ne 'Ready') {
        return $null
    }

    $fields = Get-NotePropertyValue -Object $Resolution -Name 'Fields'
    $bus = [string](Get-NotePropertyValue -Object $Resolution -Name 'Bus')
    $vendorId = [string](Get-NotePropertyValue -Object $fields -Name 'VendorId')
    $deviceId = [string](Get-NotePropertyValue -Object $fields -Name 'DeviceId')
    $productId = [string](Get-NotePropertyValue -Object $fields -Name 'ProductId')
    $subvendorId = [string](Get-NotePropertyValue -Object $fields -Name 'SubvendorId')
    $subdeviceId = [string](Get-NotePropertyValue -Object $fields -Name 'SubdeviceId')
    $interfaceId = [string](Get-NotePropertyValue -Object $fields -Name 'InterfaceId')
    $revision = [string](Get-NotePropertyValue -Object $fields -Name 'Revision')

    foreach ($candidateInterfaceId in @($interfaceId, '')) {
        foreach ($candidateRevision in @($revision, '')) {
            $key = Get-BoardModelEvidenceKey -Bus $bus -VendorId $vendorId -DeviceId $deviceId -ProductId $productId -SubvendorId $subvendorId -SubdeviceId $subdeviceId -InterfaceId $candidateInterfaceId -Revision $candidateRevision
            if ($script:BoardModelEvidenceIndex.ContainsKey($key)) {
                return $script:BoardModelEvidenceIndex[$key]
            }
        }
    }

    return $null
}

function Add-BoardModelEvidenceRows {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [object]$Resolution
    )

    $evidence = Get-BoardModelEvidenceForResolution -Resolution $Resolution
    if ($null -eq $evidence) {
        return $false
    }

    $resolutionBus = [string](Get-NotePropertyValue -Object $Resolution -Name 'Bus')
    $modelName = [string](Get-NotePropertyValue -Object $evidence -Name 'ModelName')
    $modelKey = [string](Get-NotePropertyValue -Object $evidence -Name 'ModelKey')
    $source = Get-NotePropertyValue -Object $evidence -Name 'Source'
    $sourceName = [string](Get-NotePropertyValue -Object $source -Name 'Name')
    $sourceType = [string](Get-NotePropertyValue -Object $source -Name 'Type')
    $sourceUrl = [string](Get-NotePropertyValue -Object $source -Name 'Url')
    $confidence = [string](Get-NotePropertyValue -Object $evidence -Name 'Confidence')
    $confidenceScore = [string](Get-NotePropertyValue -Object $evidence -Name 'ConfidenceScore')
    $sourceDisplay = if ($sourceType -eq 'UserConfirmedExternalPage' -and $sourceUrl -match 'techpowerup\.com') {
        'User-confirmed + TechPowerUp GPU Database'
    } else {
        $sourceName
    }
    if ([string]::IsNullOrWhiteSpace($modelKey)) {
        $modelKey = if ($resolutionBus -in @('USB', 'HID')) { 'Product Model' } else { 'Board Model' }
    }

    if (-not [string]::IsNullOrWhiteSpace($modelName)) {
        $Rows.Add((New-HardwareIdentityRow -Key $modelKey -Value $modelName -Color 'OK'))
    }

    $confidenceText = @(
        $confidence
        $(if (-not [string]::IsNullOrWhiteSpace($confidenceScore)) { "$confidenceScore/100" })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (@($confidenceText).Count -gt 0) {
        $Rows.Add((New-HardwareIdentityRow -Key 'Confidence' -Value ($confidenceText -join ' / ') -Color 'OK'))
    }

    if (-not [string]::IsNullOrWhiteSpace($sourceDisplay)) {
        $Rows.Add((New-HardwareIdentityRow -Key 'Source' -Value $sourceDisplay -Color 'White'))
    }

    if (-not [string]::IsNullOrWhiteSpace($sourceUrl)) {
        $Rows.Add((New-HardwareIdentityRow -Key 'URL' -Value $sourceUrl -Color 'Info'))
    }

    return $true
}

function Add-AlsaUcmAudioProfileRows {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [object]$Resolution
    )

    if ($script:AlsaUcmResolverState -ne 'Ready' -or $null -eq $script:AlsaUcmUsbAudioProfileCache) {
        return $false
    }

    $inputId = [string](Get-NotePropertyValue -Object $Resolution -Name 'Input')
    if ([string]::IsNullOrWhiteSpace($inputId)) {
        return $false
    }

    $profileMatch = @(Resolve-AlsaUcmUsbAudioProfile -HardwareId $inputId -Cache $script:AlsaUcmUsbAudioProfileCache | Select-Object -First 1)
    if ($profileMatch.Count -eq 0) {
        return $false
    }

    $profile = $profileMatch[0]
    if (-not [string]::IsNullOrWhiteSpace([string]$profile.ProfileName)) {
        $Rows.Add((New-HardwareIdentityRow -Key 'Audio Profile' -Value ([string]$profile.ProfileName) -Color 'OK'))
    }

    $matchParts = @(
        ([string]$profile.UsbId)
        ([string]$profile.EvidenceLabel)
        ([string]$profile.SourceId)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (@($matchParts).Count -gt 0) {
        $Rows.Add((New-HardwareIdentityRow -Key 'Profile Match' -Value ($matchParts -join ' / ') -Color 'Info'))
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$profile.CommentLabel)) {
        $Rows.Add((New-HardwareIdentityRow -Key 'Profile Note' -Value ([string]$profile.CommentLabel) -Color 'Dim'))
    }

    $sourceVersion = [string]$profile.SourceVersion
    $sourceCommit = [string]$profile.SourceCommit
    $sourceDisplay = 'ALSA UCM'
    if (-not [string]::IsNullOrWhiteSpace($sourceVersion)) {
        $sourceDisplay = "$sourceDisplay $sourceVersion"
    }
    if (-not [string]::IsNullOrWhiteSpace($sourceCommit) -and $sourceCommit.Length -ge 8) {
        $sourceDisplay = "$sourceDisplay / $($sourceCommit.Substring(0, 8))"
    }
    $Rows.Add((New-HardwareIdentityRow -Key 'Evidence' -Value "$sourceDisplay; audio profile, not usb.ids product" -Color 'White'))

    return $true
}

function Get-MonitorEdidIdentityForResolution {
    param(
        [object]$Resolution,
        [object]$Evidence
    )

    if ($script:MonitorEdidResolverState -ne 'Ready') {
        return $null
    }

    $candidateSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $candidates = [System.Collections.Generic.List[string]]::new()

    function Add-MonitorEdidCandidate {
        param([AllowEmptyString()][string]$Value)
        if (-not [string]::IsNullOrWhiteSpace($Value) -and $candidateSet.Add($Value)) {
            $candidates.Add($Value)
        }
    }

    $device = Get-NotePropertyValue -Object $Evidence -Name 'Device'
    Add-MonitorEdidCandidate -Value ([string](Get-NotePropertyValue -Object $device -Name 'InstanceId'))
    Add-MonitorEdidCandidate -Value ([string](Get-NotePropertyValue -Object $Resolution -Name 'Input'))
    Add-MonitorEdidCandidate -Value ([string](Get-NotePropertyValue -Object $Resolution -Name 'Normalized'))

    $fields = Get-NotePropertyValue -Object $Resolution -Name 'Fields'
    $vendorId = [string](Get-NotePropertyValue -Object $fields -Name 'VendorId')
    $productId = [string](Get-NotePropertyValue -Object $fields -Name 'ProductId')
    if (-not [string]::IsNullOrWhiteSpace($vendorId) -and -not [string]::IsNullOrWhiteSpace($productId)) {
        Add-MonitorEdidCandidate -Value "DISPLAY\$vendorId$productId"
    }

    foreach ($candidate in @($candidates)) {
        if ($script:MonitorEdidIdentityCache.ContainsKey($candidate)) {
            $cached = $script:MonitorEdidIdentityCache[$candidate]
            if ($null -ne $cached) {
                return $cached
            }
            continue
        }

        try {
            $edid = Get-MonitorEdidFromRegistry -InstanceId $candidate
            $script:MonitorEdidIdentityCache[$candidate] = $edid
            if ($null -ne $edid) {
                return $edid
            }
        }
        catch {
            $script:MonitorEdidResolverError = $_.Exception.Message
            $script:MonitorEdidIdentityCache[$candidate] = $null
        }
    }

    return $null
}

function Get-MonitorWmiIdentityForResolution {
    param(
        [object]$Resolution,
        [object]$Evidence
    )

    if ($script:MonitorEdidResolverState -ne 'Ready') {
        return $null
    }

    $candidateSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $candidates = [System.Collections.Generic.List[string]]::new()

    function Add-MonitorWmiCandidate {
        param([AllowEmptyString()][string]$Value)
        if (-not [string]::IsNullOrWhiteSpace($Value) -and $candidateSet.Add($Value)) {
            $candidates.Add($Value)
        }
    }

    $device = Get-NotePropertyValue -Object $Evidence -Name 'Device'
    Add-MonitorWmiCandidate -Value ([string](Get-NotePropertyValue -Object $device -Name 'InstanceId'))
    Add-MonitorWmiCandidate -Value ([string](Get-NotePropertyValue -Object $Resolution -Name 'Input'))
    Add-MonitorWmiCandidate -Value ([string](Get-NotePropertyValue -Object $Resolution -Name 'Normalized'))

    $fields = Get-NotePropertyValue -Object $Resolution -Name 'Fields'
    $vendorId = [string](Get-NotePropertyValue -Object $fields -Name 'VendorId')
    $productId = [string](Get-NotePropertyValue -Object $fields -Name 'ProductId')
    if (-not [string]::IsNullOrWhiteSpace($vendorId) -and -not [string]::IsNullOrWhiteSpace($productId)) {
        Add-MonitorWmiCandidate -Value "DISPLAY\$vendorId$productId"
    }

    foreach ($candidate in @($candidates)) {
        if ($script:MonitorWmiEvidenceCache.ContainsKey($candidate)) {
            $cached = $script:MonitorWmiEvidenceCache[$candidate]
            if ($null -ne $cached) {
                return $cached
            }
            continue
        }

        try {
            $wmiData = Get-MonitorWmiEvidence -InstanceId $candidate
            $script:MonitorWmiEvidenceCache[$candidate] = $wmiData
            if ($null -ne $wmiData) {
                return $wmiData
            }
        }
        catch {
            $script:MonitorWmiEvidenceCache[$candidate] = $null
        }
    }

    return $null
}

function Get-MonitorInfIdentityForResolution {
    param(
        [object]$Resolution,
        [object]$Evidence
    )

    if ($script:MonitorEdidResolverState -ne 'Ready') {
        return $null
    }

    $device = Get-NotePropertyValue -Object $Evidence -Name 'Device'
    $instanceId = [string](Get-NotePropertyValue -Object $device -Name 'InstanceId')
    if ([string]::IsNullOrWhiteSpace($instanceId)) {
        return $null
    }

    if ($script:MonitorInfEvidenceCache.ContainsKey($instanceId)) {
        return $script:MonitorInfEvidenceCache[$instanceId]
    }

    $driver = Get-InstalledDriverEvidenceFields -Evidence $Evidence
    $hardwareIds = @(Get-CandidateEvidenceHardwareIds -Evidence $Evidence -InstanceId $instanceId)

    try {
        $infData = Get-MonitorInfEvidence -InfName $driver.InfName -SectionName $driver.InfSection -HardwareIds $hardwareIds
        $script:MonitorInfEvidenceCache[$instanceId] = $infData
        return $infData
    }
    catch {
        $script:MonitorInfEvidenceCache[$instanceId] = $null
        return $null
    }
}

function Add-MonitorEdidRows {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [object]$Resolution,
        [object]$Evidence
    )

    $edid = Get-MonitorEdidIdentityForResolution -Resolution $Resolution -Evidence $Evidence
    if ($null -eq $edid) {
        return $false
    }

    $monitorName = [string](Get-NotePropertyValue -Object $edid -Name 'MonitorName')
    $manufacturerId = [string](Get-NotePropertyValue -Object $edid -Name 'ManufacturerId')
    $productCode = [string](Get-NotePropertyValue -Object $edid -Name 'ProductCode')
    $widthCm = [int](Get-NotePropertyValue -Object $edid -Name 'WidthCm')
    $heightCm = [int](Get-NotePropertyValue -Object $edid -Name 'HeightCm')
    $manufactureWeek = [int](Get-NotePropertyValue -Object $edid -Name 'ManufactureWeek')
    $manufactureYear = [int](Get-NotePropertyValue -Object $edid -Name 'ManufactureYear')
    $serialDescriptor = [string](Get-NotePropertyValue -Object $edid -Name 'SerialText')
    $serialNumber = [uint32](Get-NotePropertyValue -Object $edid -Name 'SerialNumber')
    $checksumValid = [bool](Get-NotePropertyValue -Object $edid -Name 'ChecksumValid')
    $source = [string](Get-NotePropertyValue -Object $edid -Name 'Source')

    if (-not [string]::IsNullOrWhiteSpace($monitorName)) {
        $Rows.Add((New-HardwareIdentityRow -Key 'EDID Name' -Value $monitorName -Color 'OK'))
    }

    $edidIdParts = @(
        $manufacturerId
        $productCode
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (@($edidIdParts).Count -gt 0) {
        $Rows.Add((New-HardwareIdentityRow -Key 'EDID ID' -Value ($edidIdParts -join ' ') -Color 'Info'))
    }

    if ($widthCm -gt 0 -or $heightCm -gt 0) {
        $Rows.Add((New-HardwareIdentityRow -Key 'Panel Size' -Value ("{0} x {1} cm" -f $widthCm, $heightCm) -Color 'White'))
    }

    if ($manufactureYear -gt 1990) {
        $madeText = if ($manufactureWeek -gt 0) {
            "week $manufactureWeek / $manufactureYear"
        } else {
            [string]$manufactureYear
        }
        $Rows.Add((New-HardwareIdentityRow -Key 'Made' -Value $madeText -Color 'Dim'))
    }

    $timing = Get-NotePropertyValue -Object $edid -Name 'PreferredTiming'
    if ($null -ne $timing -and $timing.Width -gt 0 -and $timing.Height -gt 0) {
        $timingText = "{0}x{1}" -f $timing.Width, $timing.Height
        if ($null -ne $timing.RefreshRateHz) {
            $timingText = "$timingText @ $($timing.RefreshRateHz)Hz"
        }
        $Rows.Add((New-HardwareIdentityRow -Key 'Native Timing' -Value $timingText -Color 'White'))
    }

    $checksumText = if ($checksumValid) { 'OK' } else { 'Invalid' }
    $checksumColor = if ($checksumValid) { 'OK' } else { 'Warn' }
    $Rows.Add((New-HardwareIdentityRow -Key 'EDID Checksum' -Value $checksumText -Color $checksumColor))

    return $true
}

function Get-VideoOutputTechnologyName {
    param(
        [int]$Technology
    )
    switch ($Technology) {
        -2 { "Other" }
        -1 { "Uninitialized" }
        0  { "HD15 (VGA)" }
        1  { "S-Video" }
        2  { "Composite Video" }
        3  { "Component Video" }
        4  { "DVI" }
        5  { "HDMI" }
        6  { "LVDS" }
        8  { "D-JPN" }
        9  { "SDI" }
        10 { "DisplayPort External" }
        11 { "DisplayPort Embedded" }
        12 { "UDI External" }
        13 { "UDI Embedded" }
        14 { "SDTV Dongle" }
        15 { "Miracast" }
        20 { "Indirect Wired" }
        21 { "Indirect Virtual" }
        -2147483648 { "Internal" }
        2147483648  { "Internal" }
        Default { "Unknown ($Technology)" }
    }
}

function Add-MonitorWmiAndInfRows {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [object]$Resolution,
        [object]$Evidence
    )

    $hasInf = $false
    $infData = Get-MonitorInfIdentityForResolution -Resolution $Resolution -Evidence $Evidence
    if ($null -ne $infData) {
        $hasInf = $true
        if (-not $infData.IsGeneric) {
            $Rows.Add((New-HardwareIdentityRow -Key 'INF Name' -Value $infData.ModelName -Color 'Info'))
        }
        else {
            $Rows.Add((New-HardwareIdentityRow -Key 'INF Name' -Value "$($infData.ModelName) (Generic)" -Color 'Dim'))
        }
    }

    $hasWmi = $false
    $wmi = Get-MonitorWmiIdentityForResolution -Resolution $Resolution -Evidence $Evidence
    if ($null -ne $wmi) {
        $hasWmi = $true
        $friendlyName = [string](Get-NotePropertyValue -Object $wmi -Name 'UserFriendlyName')
        $manufacturerId = [string](Get-NotePropertyValue -Object $wmi -Name 'ManufacturerId')
        $productCode = [string](Get-NotePropertyValue -Object $wmi -Name 'ProductCode')
        $widthCm = Get-NotePropertyValue -Object $wmi -Name 'MaxHorizontalCm'
        $heightCm = Get-NotePropertyValue -Object $wmi -Name 'MaxVerticalCm'
        $videoOutputTech = Get-NotePropertyValue -Object $wmi -Name 'VideoOutputTechnology'
        $timing = Get-NotePropertyValue -Object $wmi -Name 'PreferredTiming'

        $nameAlreadyShown = @($Rows | Where-Object { $_.Key -match 'Name$' -and $_.Value -eq $friendlyName }).Count -gt 0
        if (-not [string]::IsNullOrWhiteSpace($friendlyName) -and -not $nameAlreadyShown) {
            $Rows.Add((New-HardwareIdentityRow -Key 'WMI Name' -Value $friendlyName -Color 'OK'))
        }

        if ($null -ne $videoOutputTech) {
            $portName = Get-VideoOutputTechnologyName -Technology $videoOutputTech
            $Rows.Add((New-HardwareIdentityRow -Key 'Connection' -Value $portName -Color 'White'))
        }

        $hasPanelSize = @($Rows | Where-Object { $_.Key -eq 'Panel Size' }).Count -gt 0
        if (-not $hasPanelSize -and $null -ne $widthCm -and $null -ne $heightCm -and ($widthCm -gt 0 -or $heightCm -gt 0)) {
            $Rows.Add((New-HardwareIdentityRow -Key 'Panel Size' -Value ("{0} x {1} cm" -f $widthCm, $heightCm) -Color 'White'))
        }

        $hasNativeTiming = @($Rows | Where-Object { $_.Key -eq 'Native Timing' }).Count -gt 0
        if (-not $hasNativeTiming -and $null -ne $timing -and $timing.Width -gt 0 -and $timing.Height -gt 0) {
            $timingText = "{0}x{1}" -f $timing.Width, $timing.Height
            if ($null -ne $timing.RefreshRateHz) {
                $timingText = "$timingText @ $($timing.RefreshRateHz)Hz"
            }
            $Rows.Add((New-HardwareIdentityRow -Key 'Native Timing' -Value $timingText -Color 'White'))
        }
    }

    return ($hasInf -or $hasWmi)
}

function Get-HardwareResolutionDetailRows {
    param(
        [object]$Resolution,
        [object]$Evidence
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $lookup = Get-NotePropertyValue -Object $Resolution -Name 'Lookup'
    $fields = Get-NotePropertyValue -Object $Resolution -Name 'Fields'
    $bus = [string](Get-NotePropertyValue -Object $Resolution -Name 'Bus')
    $confidence = [string](Get-NotePropertyValue -Object $Resolution -Name 'Confidence')
    $sourceName = [string](Get-NotePropertyValue -Object $lookup -Name 'Source')
    $matchParts = @($bus, $confidence, $sourceName) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (@($matchParts).Count -gt 0) {
        $rows.Add((New-HardwareIdentityRow -Key 'Local Match' -Value ($matchParts -join ' / ') -Color 'Info'))
    }

    if ($bus -ne 'PCI') {
        $hasEvidence = Add-BoardModelEvidenceRows -Rows $rows -Resolution $Resolution
        if (-not $hasEvidence -and $bus -in @('USB', 'HID')) {
            [void](Add-AlsaUcmAudioProfileRows -Rows $rows -Resolution $Resolution)
            $vendorId = [string](Get-NotePropertyValue -Object $fields -Name 'VendorId')
            $productId = [string](Get-NotePropertyValue -Object $fields -Name 'ProductId')
            $interfaceId = [string](Get-NotePropertyValue -Object $fields -Name 'InterfaceId')
            $productName = [string](Get-NotePropertyValue -Object $lookup -Name 'ProductName')
            $vendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'VendorName')
            $driver = Get-InstalledDriverEvidenceFields -Evidence $Evidence
            $safeVendorName = Get-ShortHardwareVendorName -Name $vendorName
            if (-not [string]::IsNullOrWhiteSpace($safeVendorName) -and -not [string]::IsNullOrWhiteSpace($driver.DeviceName)) {
                $safeKind = if ($driver.DeviceName -match '(?i)audio') { 'USB Audio device' } else { 'USB device' }
                $rows.Add((New-HardwareIdentityRow -Key 'Safe Label' -Value "$safeVendorName $safeKind, $($driver.DeviceName) driver" -Color 'White'))
            }
            $busPrefix = if ($bus -eq 'HID') { 'HID' } else { 'USB' }
            $tupleHint = ''
            if (-not [string]::IsNullOrWhiteSpace($vendorId) -and -not [string]::IsNullOrWhiteSpace($productId)) {
                $tupleHint = "$busPrefix\VID_$vendorId&PID_$productId"
                if (-not [string]::IsNullOrWhiteSpace($interfaceId)) {
                    $tupleHint = "$tupleHint&MI_$interfaceId"
                }
            }
            $searchParts = @(
                $tupleHint
                (Get-ShortHardwareVendorName -Name $vendorName)
                $productName
                $vendorId
                $productId
                $(if (-not [string]::IsNullOrWhiteSpace($interfaceId)) { "MI_$interfaceId" })
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if ([string]::IsNullOrWhiteSpace($productName)) {
                $rows.Add((New-HardwareIdentityRow -Key 'Coverage' -Value 'No exact product model in local usb.ids' -Color 'Dim'))
            }
            if (@($searchParts).Count -gt 0) {
                $rows.Add((New-HardwareIdentityRow -Key 'Search Hint' -Value (($searchParts | Select-Object -Unique) -join ' ') -Color 'Info'))
            }
        }
        elseif ($bus -eq 'HDAUDIO') {
            $codecName = ''
            $boardProduct = ''
            $boardManufacturer = ''
            $evidence = Get-BoardModelEvidenceForResolution -Resolution $Resolution
            if ($null -ne $evidence) {
                $codecName = [string](Get-NotePropertyValue -Object $evidence -Name 'CodecName')
                $boardProduct = [string](Get-NotePropertyValue -Object $evidence -Name 'BoardProduct')
                $boardManufacturer = [string](Get-NotePropertyValue -Object $evidence -Name 'BoardManufacturer')
            }

            $vendorId = [string](Get-NotePropertyValue -Object $fields -Name 'VendorId')
            $deviceId = [string](Get-NotePropertyValue -Object $fields -Name 'DeviceId')
            $functionId = [string](Get-NotePropertyValue -Object $fields -Name 'FunctionId')
            $subvendorId = [string](Get-NotePropertyValue -Object $fields -Name 'SubvendorId')
            $subdeviceId = [string](Get-NotePropertyValue -Object $fields -Name 'SubdeviceId')
            $controllerVendorId = [string](Get-NotePropertyValue -Object $fields -Name 'ControllerVendorId')
            $controllerDeviceId = [string](Get-NotePropertyValue -Object $fields -Name 'ControllerDeviceId')
            $vendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'VendorName')
            $subvendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'SubvendorName')
            $controllerVendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'ControllerVendorName')
            $controllerDeviceName = [string](Get-NotePropertyValue -Object $lookup -Name 'ControllerDeviceName')

            if (-not [string]::IsNullOrWhiteSpace($codecName)) {
                $rows.Add((New-HardwareIdentityRow -Key 'Codec' -Value $codecName -Color 'OK'))
            }
            if (-not [string]::IsNullOrWhiteSpace($vendorName)) {
                $rows.Add((New-HardwareIdentityRow -Key 'Codec Vendor' -Value (Get-FormattedHardwareVendorName -Name $vendorName) -Color 'Dim'))
            }
            if (-not [string]::IsNullOrWhiteSpace($subvendorName) -or -not [string]::IsNullOrWhiteSpace($subdeviceId)) {
                $subsystemParts = @(
                    (Get-FormattedHardwareVendorName -Name $subvendorName)
                    $(if (-not [string]::IsNullOrWhiteSpace($subvendorId) -or -not [string]::IsNullOrWhiteSpace($subdeviceId)) { "$subvendorId`:$subdeviceId" })
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                $rows.Add((New-HardwareIdentityRow -Key 'Subsystem' -Value (($subsystemParts | Select-Object -Unique) -join ' / ') -Color 'Info'))
            }
            if (-not [string]::IsNullOrWhiteSpace($controllerVendorId) -or -not [string]::IsNullOrWhiteSpace($controllerDeviceId)) {
                $controllerText = @(
                    (Get-FormattedHardwareVendorName -Name $controllerVendorName)
                    $controllerDeviceName
                    $(if (-not [string]::IsNullOrWhiteSpace($controllerVendorId) -or -not [string]::IsNullOrWhiteSpace($controllerDeviceId)) { "$controllerVendorId`:$controllerDeviceId" })
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                $rows.Add((New-HardwareIdentityRow -Key 'Controller' -Value (($controllerText | Select-Object -Unique) -join ' / ') -Color 'Dim'))
            }
            if (-not $hasEvidence) {
                $rows.Add((New-HardwareIdentityRow -Key 'Coverage' -Value 'HDAUDIO codec/subsystem parsed; exact codec model needs board/OEM/open-source evidence' -Color 'Dim'))
            }

            $tupleFunctionId = if ([string]::IsNullOrWhiteSpace($functionId)) { '01' } else { $functionId }
            $tupleHint = "HDAUDIO\FUNC_$tupleFunctionId&VEN_$vendorId&DEV_$deviceId"
            if (-not [string]::IsNullOrWhiteSpace($subvendorId) -and -not [string]::IsNullOrWhiteSpace($subdeviceId)) {
                $tupleHint = "$tupleHint&SUBSYS_$subvendorId$subdeviceId"
            }
            $searchParts = @(
                $tupleHint
                (Get-ShortHardwareVendorName -Name $subvendorName)
                $boardManufacturer
                $boardProduct
                $codecName
                $vendorId
                $deviceId
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if (@($searchParts).Count -gt 0) {
                $rows.Add((New-HardwareIdentityRow -Key 'Search Hint' -Value (($searchParts | Select-Object -Unique) -join ' ') -Color 'Info'))
            }
        }
        elseif ($bus -eq 'DISPLAY') {
            $vendorId = [string](Get-NotePropertyValue -Object $fields -Name 'VendorId')
            $productId = [string](Get-NotePropertyValue -Object $fields -Name 'ProductId')
            $vendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'VendorName')
            $hasEdid = Add-MonitorEdidRows -Rows $rows -Resolution $Resolution -Evidence $Evidence
            $hasWmiOrInf = Add-MonitorWmiAndInfRows -Rows $rows -Resolution $Resolution -Evidence $Evidence
            $displayVendor = if (-not [string]::IsNullOrWhiteSpace($vendorName)) {
                Get-FormattedHardwareVendorName -Name $vendorName
            } else {
                $vendorId
            }
            if (-not ($hasEdid -or $hasWmiOrInf) -and -not [string]::IsNullOrWhiteSpace($displayVendor)) {
                $rows.Add((New-HardwareIdentityRow -Key 'Display Vendor' -Value $displayVendor -Color 'White'))
            }
            if (-not ($hasEdid -or $hasWmiOrInf) -and -not [string]::IsNullOrWhiteSpace($productId)) {
                $rows.Add((New-HardwareIdentityRow -Key 'EDID Product' -Value $productId -Color 'Info'))
            }
            $coverageText = if ($hasEdid -or $hasWmiOrInf) {
                'Registry EDID + WMI + INF'
            } else {
                'DISPLAY ID gives EDID vendor/product code; exact monitor model needs EDID/INF/WMI/OEM evidence'
            }
            $rows.Add((New-HardwareIdentityRow -Key 'Evidence' -Value $coverageText -Color 'Dim'))
            $searchParts = @(
                $(if (-not [string]::IsNullOrWhiteSpace($vendorId) -and -not [string]::IsNullOrWhiteSpace($productId)) { "DISPLAY\$vendorId$productId" })
                $displayVendor
                $vendorId
                $productId
                'monitor'
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if (-not ($hasEdid -or $hasWmiOrInf) -and @($searchParts).Count -gt 0) {
                $rows.Add((New-HardwareIdentityRow -Key 'Search Hint' -Value (($searchParts | Select-Object -Unique) -join ' ') -Color 'Info'))
            }
        }
        elseif ($bus -in @('SCSI', 'USBSTOR', 'IDE')) {
            $deviceTypeName = [string](Get-NotePropertyValue -Object $lookup -Name 'DeviceTypeName')
            $vendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'VendorName')
            $productName = [string](Get-NotePropertyValue -Object $lookup -Name 'ProductName')
            $device = Get-NotePropertyValue -Object $Evidence -Name 'Device'
            $friendlyName = [string](Get-NotePropertyValue -Object $device -Name 'FriendlyName')
            $displayModel = if (-not [string]::IsNullOrWhiteSpace($friendlyName)) { $friendlyName } else { $productName }
            if (-not [string]::IsNullOrWhiteSpace($displayModel)) {
                $rows.Add((New-HardwareIdentityRow -Key 'Storage Model' -Value $displayModel -Color 'White'))
            }
            if (-not [string]::IsNullOrWhiteSpace($vendorName)) {
                if ($vendorName -match '^(?i:NVME)$') {
                    $rows.Add((New-HardwareIdentityRow -Key 'Storage Stack' -Value 'NVMe surfaced through Windows SCSI storage stack' -Color 'Dim'))
                }
                else {
                    $rows.Add((New-HardwareIdentityRow -Key 'Storage Vendor' -Value $vendorName -Color 'Dim'))
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($deviceTypeName)) {
                $rows.Add((New-HardwareIdentityRow -Key 'Storage Type' -Value $deviceTypeName -Color 'Dim'))
            }
            $rows.Add((New-HardwareIdentityRow -Key 'Evidence' -Value "Windows $bus storage ID" -Color 'Dim'))
        }
        return @($rows)
    }

    $deviceName = [string](Get-NotePropertyValue -Object $lookup -Name 'DeviceName')
    $subsystemName = [string](Get-NotePropertyValue -Object $lookup -Name 'SubsystemName')
    $subvendorName = [string](Get-NotePropertyValue -Object $lookup -Name 'SubvendorName')
    $vendorId = [string](Get-NotePropertyValue -Object $fields -Name 'VendorId')
    $deviceId = [string](Get-NotePropertyValue -Object $fields -Name 'DeviceId')
    $subvendorId = [string](Get-NotePropertyValue -Object $fields -Name 'SubvendorId')
    $subdeviceId = [string](Get-NotePropertyValue -Object $fields -Name 'SubdeviceId')

    if (-not [string]::IsNullOrWhiteSpace($subsystemName)) {
        $rows.Add((New-HardwareIdentityRow -Key 'Exact Model' -Value $subsystemName -Color 'OK'))
    }

    $hasBoardEvidence = Add-BoardModelEvidenceRows -Rows $rows -Resolution $Resolution

    if (-not $hasBoardEvidence -and [string]::IsNullOrWhiteSpace($subsystemName) -and
        (-not [string]::IsNullOrWhiteSpace($subvendorName) -or -not [string]::IsNullOrWhiteSpace($subdeviceId))) {
        $rows.Add((New-HardwareIdentityRow -Key 'Coverage' -Value 'No exact board model in local pci.ids' -Color 'Dim'))
    }

    $searchParts = @(
        (Get-ShortHardwareVendorName -Name $subvendorName)
        $deviceName
        $subdeviceId
        $subvendorId
        $deviceId
        $vendorId
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (-not $hasBoardEvidence -and [string]::IsNullOrWhiteSpace($subsystemName) -and @($searchParts).Count -gt 0) {
        $rows.Add((New-HardwareIdentityRow -Key 'Search Hint' -Value (($searchParts | Select-Object -Unique) -join ' ') -Color 'Info'))
    }

    return @($rows)
}

function Get-CandidateEvidenceHardwareIds {
    param(
        [object]$Evidence,
        [string]$InstanceId
    )

    $idSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ids = [System.Collections.Generic.List[string]]::new()

    function Add-DeviceCheckHardwareId {
        param([AllowEmptyString()][string]$Value)
        if (-not [string]::IsNullOrWhiteSpace($Value) -and $idSet.Add($Value)) {
            $ids.Add($Value)
        }
    }

    if ($InstanceId -match '^(?i:SCSI|USBSTOR|IDE)\\[A-Z0-9]+&VEN_[^&\\]+&PROD_[^&\\]+') {
        Add-DeviceCheckHardwareId -Value $InstanceId
    }

    $importantProperties = Get-NotePropertyValue -Object $Evidence -Name 'ImportantProperties'
    foreach ($propertyName in @('DEVPKEY_Device_HardwareIds', 'DEVPKEY_Device_CompatibleIds', 'DEVPKEY_Device_MatchingDeviceId')) {
        $propertyValue = Get-NotePropertyValue -Object $importantProperties -Name $propertyName
        foreach ($item in @($propertyValue)) {
            Add-DeviceCheckHardwareId -Value ([string]$item)
        }
    }

    $signedDriver = Get-NotePropertyValue -Object $Evidence -Name 'SignedDriver'
    foreach ($propertyName in @('HardwareID', 'CompatID')) {
        $propertyValue = Get-NotePropertyValue -Object $signedDriver -Name $propertyName
        foreach ($item in @($propertyValue)) {
            Add-DeviceCheckHardwareId -Value ([string]$item)
        }
    }

    Add-DeviceCheckHardwareId -Value $InstanceId
    return @($ids)
}

function Get-LocalHardwareIdentitySummaries {
    param(
        [object]$Evidence,
        [string]$InstanceId,
        [int]$MaxCount = 3
    )

    if ($script:HardwareIdResolverState -ne 'Ready') {
        return @()
    }

    $ids = @(Get-CandidateEvidenceHardwareIds -Evidence $Evidence -InstanceId $InstanceId | Select-Object -First 12)
    if ($ids.Count -eq 0) {
        return @()
    }

    $cacheKey = ($ids | ForEach-Object { [string]$_ }) -join "`n"
    if ($script:HardwareIdResolutionDisplayCache.ContainsKey($cacheKey)) {
        return @($script:HardwareIdResolutionDisplayCache[$cacheKey])
    }

    $summaries = [System.Collections.Generic.List[string]]::new()
    try {
        $resolutions = @(Resolve-HardwareId -HardwareId $ids -Cache $script:HardwareIdDatabaseCache)
        foreach ($resolution in @($resolutions)) {
            $confidence = [string](Get-NotePropertyValue -Object $resolution -Name 'Confidence')
            if ($confidence -in @('UNSUPPORTED', 'NO-ID')) {
                continue
            }

            $displayText = Get-HardwareResolutionDisplayText -Resolution $resolution
            if (-not [string]::IsNullOrWhiteSpace($displayText) -and -not $summaries.Contains($displayText)) {
                $summaries.Add($displayText)
            }
            if ($summaries.Count -ge $MaxCount) {
                break
            }
        }
    }
    catch {
        $script:HardwareIdResolverError = $_.Exception.Message
        $script:HardwareIdResolverState = 'Unavailable'
        return @()
    }

    $script:HardwareIdResolutionDisplayCache[$cacheKey] = @($summaries)
    return @($summaries)
}

function Get-LocalHardwareIdentityRows {
    param(
        [object]$Evidence,
        [string]$InstanceId,
        [int]$MaxCount = 3
    )

    if ($script:HardwareIdResolverState -ne 'Ready') {
        return @()
    }

    $ids = @(Get-CandidateEvidenceHardwareIds -Evidence $Evidence -InstanceId $InstanceId | Select-Object -First 12)
    if ($ids.Count -eq 0) {
        return @()
    }

    $cacheKey = ($ids | ForEach-Object { [string]$_ }) -join "`n"
    if ($script:HardwareIdResolutionDetailCache.ContainsKey($cacheKey)) {
        return @($script:HardwareIdResolutionDetailCache[$cacheKey])
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    try {
        $resolutions = @(Resolve-HardwareId -HardwareId $ids -Cache $script:HardwareIdDatabaseCache)
        foreach ($resolution in @($resolutions)) {
            $confidence = [string](Get-NotePropertyValue -Object $resolution -Name 'Confidence')
            if ($confidence -in @('UNSUPPORTED', 'NO-ID')) {
                continue
            }

            foreach ($row in @(Get-HardwareResolutionDetailRows -Resolution $resolution -Evidence $Evidence)) {
                $duplicate = @($rows | Where-Object { $_.Key -eq $row.Key -and $_.Value -eq $row.Value }).Count -gt 0
                if (-not $duplicate) {
                    $rows.Add($row)
                }
            }

            # Stop after the first successfully resolved hardware ID to avoid duplicate and overlapping rows
            break
        }
    }
    catch {
        $script:HardwareIdResolverError = $_.Exception.Message
        $script:HardwareIdResolverState = 'Unavailable'
        return @()
    }

    $script:HardwareIdResolutionDetailCache[$cacheKey] = @($rows)
    return @($rows)
}

function Get-FirstNonEmptyEvidenceValue {
    param(
        [object[]]$Values
    )

    foreach ($value in @($Values)) {
        foreach ($item in @($value)) {
            if ($null -eq $item) {
                continue
            }

            $text = [string]$item
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                return $text.Trim()
            }
        }
    }

    return ''
}

function Get-InstalledDriverEvidenceFields {
    param(
        [object]$Evidence
    )

    $importantProperties = Get-NotePropertyValue -Object $Evidence -Name 'ImportantProperties'
    $signedDriver = Get-NotePropertyValue -Object $Evidence -Name 'SignedDriver'

    $provider = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $signedDriver -Name 'DriverProviderName'),
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_DriverProvider')
    )
    $version = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $signedDriver -Name 'DriverVersion'),
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_DriverVersion')
    )
    $date = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $signedDriver -Name 'DriverDate'),
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_DriverDate')
    )
    $infName = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $signedDriver -Name 'InfName'),
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_DriverInfPath')
    )
    $deviceName = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $signedDriver -Name 'DeviceName')
    )
    $manufacturer = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $signedDriver -Name 'Manufacturer'),
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_Manufacturer')
    )
    $service = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_Service')
    )
    $driverKey = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_Driver')
    )
    $infSection = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_DriverInfSection')
    )
    $signedDriverError = Get-FirstNonEmptyEvidenceValue -Values @(
        (Get-NotePropertyValue -Object $Evidence -Name 'SignedDriverError')
    )

    $hasAny = -not [string]::IsNullOrWhiteSpace((@(
        $provider
        $version
        $date
        $infName
        $deviceName
        $manufacturer
        $service
        $driverKey
        $infSection
        $signedDriverError
    ) -join ''))

    return [PSCustomObject]@{
        HasAny            = $hasAny
        DeviceName        = $deviceName
        Manufacturer      = $manufacturer
        Provider          = $provider
        Version           = $version
        Date              = $date
        InfName           = $infName
        InfSection        = $infSection
        Service           = $service
        DriverKey         = $driverKey
        SignedDriverError = $signedDriverError
    }
}

function Add-InstalledDriverDetailLines {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[string]]$Lines,
        [object]$Evidence,
        [int]$Width
    )

    $driver = Get-InstalledDriverEvidenceFields -Evidence $Evidence
    if (-not $driver.HasAny) {
        return
    }

    $Lines.Add((New-SectionLine -Title 'Installed Driver' -Width $Width))

    if (-not [string]::IsNullOrWhiteSpace($driver.Provider)) {
        Add-KeyValueLines -Lines $Lines -Key 'Provider' -Value $driver.Provider -Width $Width
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.Version)) {
        Add-KeyValueLines -Lines $Lines -Key 'Version' -Value $driver.Version -Width $Width -ValueColor $_C.OK
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.Date)) {
        Add-KeyValueLines -Lines $Lines -Key 'Date' -Value $driver.Date -Width $Width
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.InfName)) {
        Add-KeyValueLines -Lines $Lines -Key 'INF' -Value $driver.InfName -Width $Width -ValueColor $_C.Info
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.InfSection)) {
        Add-KeyValueLines -Lines $Lines -Key 'INF Section' -Value $driver.InfSection -Width $Width -ValueColor $_C.Info
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.Service)) {
        Add-KeyValueLines -Lines $Lines -Key 'Service' -Value $driver.Service -Width $Width
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.DriverKey)) {
        Add-KeyValueLines -Lines $Lines -Key 'Driver Key' -Value $driver.DriverKey -Width $Width -ValueColor $_C.Dim
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.DeviceName)) {
        Add-KeyValueLines -Lines $Lines -Key 'Driver Name' -Value $driver.DeviceName -Width $Width
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.Manufacturer) -and $driver.Manufacturer -ne $driver.Provider) {
        Add-KeyValueLines -Lines $Lines -Key 'Maker' -Value $driver.Manufacturer -Width $Width
    }
    if (-not [string]::IsNullOrWhiteSpace($driver.SignedDriverError)) {
        Add-KeyValueLines -Lines $Lines -Key 'Driver CIM' -Value $driver.SignedDriverError -Width $Width -ValueColor $_C.Warn
    }
}

function Get-SdioCandidateColor {
    param($Candidate)

    $labels = @(Get-NotePropertyValue -Object $Candidate -Name 'StatusLabels')
    if ($labels -contains 'BETTER' -or $labels -contains 'NEW') { return $_C.OK }
    if ($labels -contains 'WORSE' -or $labels -contains 'INVALID') { return $_C.Warn }
    if ($labels -contains 'CURRENT' -or $labels -contains 'SAME') { return $_C.Info }
    return $_C.White
}

function Add-SdioDriverMatchDetailLines {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[string]]$Lines,
        [string]$InstanceId,
        [int]$Width,
        [int]$MaxCandidates = 3
    )

    $audit = Read-CachedSdioAudit -InstanceId $InstanceId
    if ($null -eq $audit) {
        return
    }

    $devices = @(Get-NotePropertyValue -Object $audit -Name 'Devices')
    if ($devices.Count -eq 0) {
        return
    }

    $device = $devices | Where-Object { [int](Get-NotePropertyValue -Object $_ -Name 'CandidateCount') -gt 0 } | Select-Object -First 1
    if ($null -eq $device) {
        $device = $devices | Select-Object -First 1
    }

    $candidates = @(Get-NotePropertyValue -Object $device -Name 'Candidates')
    if ($candidates.Count -eq 0) {
        return
    }

    $Lines.Add((New-SectionLine -Title 'SDIO Matches' -Width $Width))

    $generatedAt = [string](Get-NotePropertyValue -Object $audit -Name 'GeneratedAt')
    if (-not [string]::IsNullOrWhiteSpace($generatedAt)) {
        Add-KeyValueLines -Lines $Lines -Key 'Audit' -Value $generatedAt -Width $Width -ValueColor $_C.Dim
    }

    $candidateCount = [int](Get-NotePropertyValue -Object $device -Name 'CandidateCount')
    if ($candidateCount -gt 0) {
        Add-KeyValueLines -Lines $Lines -Key 'Candidates' -Value "$candidateCount indexed matches" -Width $Width -ValueColor $_C.Info
    }

    $installed = Get-NotePropertyValue -Object $device -Name 'Installed'
    $installedHardwareId = [string](Get-NotePropertyValue -Object $installed -Name 'HardwareId')
    if (-not [string]::IsNullOrWhiteSpace($installedHardwareId)) {
        Add-KeyValueLines -Lines $Lines -Key 'Installed ID' -Value $installedHardwareId -Width $Width -ValueColor $_C.Info
    }

    $warnings = @(Get-NotePropertyValue -Object $audit -Name 'Warning')
    if ($warnings.Count -gt 0) {
        Add-KeyValueLines -Lines $Lines -Key 'Caution' -Value ([string]$warnings[0]) -Width $Width -ValueColor $_C.Warn
    }

    $index = 1
    foreach ($candidate in @($candidates | Select-Object -First $MaxCandidates)) {
        $labels = @(Get-NotePropertyValue -Object $candidate -Name 'StatusLabels') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        $statusText = if ($labels.Count -gt 0) { $labels -join '+' } else { [string](Get-NotePropertyValue -Object $candidate -Name 'Status') }
        $matchKind = [string](Get-NotePropertyValue -Object $candidate -Name 'MatchKind')
        if ([string]::IsNullOrWhiteSpace($matchKind)) { $matchKind = 'Unknown' }
        $candidateColor = Get-SdioCandidateColor -Candidate $candidate

        Add-KeyValueLines -Lines $Lines -Key "#$index" -Value "$matchKind / $statusText" -Width $Width -ValueColor $candidateColor

        $version = [string](Get-NotePropertyValue -Object $candidate -Name 'Version')
        $date = [string](Get-NotePropertyValue -Object $candidate -Name 'Date')
        $versionText = (@($version, $date) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' / '
        if (-not [string]::IsNullOrWhiteSpace($versionText)) {
            Add-KeyValueLines -Lines $Lines -Key 'Version' -Value $versionText -Width $Width -ValueColor $_C.OK
        }

        $description = [string](Get-NotePropertyValue -Object $candidate -Name 'Description')
        if (-not [string]::IsNullOrWhiteSpace($description)) {
            Add-KeyValueLines -Lines $Lines -Key 'Name' -Value $description -Width $Width
        }

        $hardwareId = [string](Get-NotePropertyValue -Object $candidate -Name 'HardwareId')
        if (-not [string]::IsNullOrWhiteSpace($hardwareId)) {
            Add-KeyValueLines -Lines $Lines -Key 'INF HWID' -Value $hardwareId -Width $Width -ValueColor $_C.Info
        }

        $infFile = [string](Get-NotePropertyValue -Object $candidate -Name 'InfFile')
        if (-not [string]::IsNullOrWhiteSpace($infFile)) {
            Add-KeyValueLines -Lines $Lines -Key 'INF' -Value $infFile -Width $Width -ValueColor $_C.Dim
        }

        $packName = [string](Get-NotePropertyValue -Object $candidate -Name 'PackName')
        if (-not [string]::IsNullOrWhiteSpace($packName)) {
            Add-KeyValueLines -Lines $Lines -Key 'Pack' -Value (Split-Path -Path $packName -Leaf) -Width $Width -ValueColor $_C.Dim
        }

        $index++
    }
}

function Get-SdioAuditCachePath {
    param([string]$InstanceId)

    $deviceHash = New-DeviceCheckHash -Text $InstanceId
    return (Join-Path -Path $script:MachineCacheRoot -ChildPath "sdio-audit\$deviceHash.json")
}

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

    # In-memory cache: avoid disk I/O + JSON parse on every render frame
    if ($script:EvidenceCacheMemory.ContainsKey($InstanceId)) {
        return $script:EvidenceCacheMemory[$InstanceId]
    }

    $cachePath = Get-DeviceEvidenceCachePath -InstanceId $InstanceId
    if (-not (Test-Path -LiteralPath $cachePath)) { return $null }

    try {
        $parsed = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
        $script:EvidenceCacheMemory[$InstanceId] = $parsed
        return $parsed
    } catch {
        return $null
    }
}

function Read-CachedSdioAudit {
    param([string]$InstanceId)

    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return $null }
    if ($script:SdioAuditCacheMemory.ContainsKey($InstanceId)) {
        return $script:SdioAuditCacheMemory[$InstanceId]
    }

    $cachePath = Get-SdioAuditCachePath -InstanceId $InstanceId
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { return $null }

    try {
        $parsed = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
        $script:SdioAuditCacheMemory[$InstanceId] = $parsed
        return $parsed
    } catch {
        return $null
    }
}

function Invalidate-EvidenceCache {
    param([string]$InstanceId)

    if (-not [string]::IsNullOrWhiteSpace($InstanceId)) {
        $script:EvidenceCacheMemory.Remove($InstanceId)
        $script:SdioAuditCacheMemory.Remove($InstanceId)
    } else {
        $script:EvidenceCacheMemory.Clear()
        $script:SdioAuditCacheMemory.Clear()
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
    $withoutOsc = $script:AnsiOscRegex.Replace($Text, '')
    return $script:AnsiCsiRegex.Replace($withoutOsc, '')
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

function Get-DeviceLookupDisplayName {
    param($Device)

    $friendlyName = [string](Get-NotePropertyValue -Object $Device -Name 'FriendlyName')
    if (-not [string]::IsNullOrWhiteSpace($friendlyName)) { return $friendlyName }

    $instanceId = [string](Get-NotePropertyValue -Object $Device -Name 'InstanceId')
    if (-not [string]::IsNullOrWhiteSpace($instanceId)) { return $instanceId }

    return 'selected device'
}

function Set-SystemStatusMessage {
    param(
        [AllowEmptyString()][string]$Message,
        [switch]$NoTimestamp
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        $script:SystemScanMessage = ''
        return
    }

    $Message = ($Message -replace '[\r\n\t]+', ' ') -replace '\s{2,}', ' '
    $Message = $Message.Trim()
    $suffix = if ($NoTimestamp) { '' } else { " | $(Get-Date -Format 'HH:mm:ss')" }
    $script:SystemScanMessage = "$Message$suffix"
}

function Get-SystemStatusColor {
    param([AllowEmptyString()][string]$StatusText)

    if ([string]::IsNullOrWhiteSpace($StatusText)) { return $_C.Dim }
    if ($StatusText -match '(?i)\b(failed|failure|error|missing|blocked|denied|forbidden|unavailable|terminated unexpectedly)\b') { return $_C.Fail }
    if ($StatusText -match '(?i)\b(cancelled|ignored|confirmation|local-target only|already includes|available only|paused)\b') { return $_C.Warn }
    if ($StatusText -match '(?i)\b(running|collecting|queued|refresh|connected|complete|updated|done)\b') { return $_C.OK }
    return $_C.Dim
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
    $line = (Get-UiGlyph -Name HLine) * [Math]::Max(0, $Width - $prefix.Length)
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
    $keyWidth = if ($Width -ge 56) { 14 } else { 13 }
    $keyText = Format-PlainToWidth -Text $Key -Width $keyWidth
    $valueWidth = [Math]::Max(8, $Width - ($keyWidth + 4))
    $valueText = Format-UiValue -Text $Value -MaxLength $valueWidth
    return " $($_C.Dim)$keyText :$($_C.Reset) $ValueColor$valueText$($_C.Reset)"
}

function Get-KeyValueLayout {
    param([int]$Width)

    $keyWidth = if ($Width -ge 56) { 14 } else { 13 }
    $valueWidth = [Math]::Max(8, $Width - ($keyWidth + 4))
    [pscustomobject]@{
        KeyWidth           = $keyWidth
        ValueWidth         = $valueWidth
        ContinuationIndent = (' ' * ($keyWidth + 4))
    }
}

function Split-DetailValueText {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width
    )

    $Width = [Math]::Max(8, $Width)
    $cleanText = Remove-AnsiSequence -Text $Text
    if ([string]::IsNullOrEmpty($cleanText)) { return @('') }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($paragraph in (($cleanText -replace "`r", '') -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($paragraph)) {
            $lines.Add('')
            continue
        }

        $current = ''
        foreach ($word in ($paragraph -split '\s+')) {
            if ([string]::IsNullOrWhiteSpace($word)) { continue }

            while ($word.Length -gt $Width) {
                if (-not [string]::IsNullOrWhiteSpace($current)) {
                    $lines.Add($current)
                    $current = ''
                }
                $lines.Add($word.Substring(0, $Width))
                $word = $word.Substring($Width)
            }

            $candidate = if ($current) { "$current $word" } else { $word }
            if ($candidate.Length -gt $Width) {
                if ($current) { $lines.Add($current) }
                $current = $word
            } else {
                $current = $candidate
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($current)) {
            $lines.Add($current)
        }
    }

    if ($lines.Count -eq 0) { return @('') }
    return @($lines)
}

function Add-KeyValueLines {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Key,
        [AllowEmptyString()][string]$Value,
        [int]$Width,
        [string]$ValueColor = $null
    )

    if (-not $ValueColor) { $ValueColor = $_C.White }
    $layout = Get-KeyValueLayout -Width $Width
    $keyText = Format-PlainToWidth -Text $Key -Width $layout.KeyWidth
    $valueLines = @(Split-DetailValueText -Text $Value -Width $layout.ValueWidth)
    $Lines.Add(" $($_C.Dim)$keyText :$($_C.Reset) $ValueColor$($valueLines[0])$($_C.Reset)")

    for ($i = 1; $i -lt $valueLines.Count; $i++) {
        $Lines.Add("$($layout.ContinuationIndent)$ValueColor$($valueLines[$i])$($_C.Reset)")
    }
}

function Add-WrappedPathLine {
    param(
        [Parameter(Mandatory)]
        $Lines,
        [string]$Key,
        [string]$Path,
        [int]$Width
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $layout = Get-KeyValueLayout -Width $Width
        $keyText = Format-PlainToWidth -Text $Key -Width $layout.KeyWidth
        $Lines.Add(" $($_C.Dim)$keyText :$($_C.Reset) -")
        return
    }

    $layout = Get-KeyValueLayout -Width $Width
    $keyText = Format-PlainToWidth -Text $Key -Width $layout.KeyWidth
    $valueWidth = $layout.ValueWidth

    # Wrap the path into pieces of $valueWidth length
    $wrapped = [System.Collections.Generic.List[string]]::new()
    $tempPath = $Path
    while ($tempPath.Length -gt 0) {
        $chunkSize = [Math]::Min($tempPath.Length, $valueWidth)
        $wrapped.Add($tempPath.Substring(0, $chunkSize))
        $tempPath = $tempPath.Substring($chunkSize)
    }

    $fileUrl = "file:///" + ($Path -replace '\\', '/')
    
    # First line has the key
    $first = $wrapped[0]
    $clickableFirst = New-TerminalHyperlink -Label $first -Url $fileUrl
    $Lines.Add(" $($_C.Dim)$keyText :$($_C.Reset) $($_C.White)$clickableFirst$($_C.Reset)")

    # Subsequent lines are indented by 15 spaces (13 key + 2 padding/separator)
    for ($i = 1; $i -lt $wrapped.Count; $i++) {
        $indent = $layout.ContinuationIndent
        $clickableChunk = New-TerminalHyperlink -Label $wrapped[$i] -Url $fileUrl
        $Lines.Add("$indent$($_C.White)$clickableChunk$($_C.Reset)")
    }
}


function Get-HardwareIdBreakdownLines {
    param(
        [string]$HardwareId,
        [int]$Width,
        [object]$Evidence = $null
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($HardwareId) -or $script:HardwareIdResolverState -ne 'Ready') {
        return @()
    }

    try {
        $resolutions = @(Resolve-HardwareId -HardwareId $HardwareId -Cache $script:HardwareIdDatabaseCache)
        if ($resolutions.Count -eq 0) {
            return @()
        }

        $res = $resolutions[0]
        $pad = ' ' * 17
        $valueWidth = [Math]::Max(8, $Width - 35)

        if ($res.Bus -eq 'PCI') {
            $vendorId = $res.Fields.VendorId
            $deviceId = $res.Fields.DeviceId
            $subsysRaw = $res.Fields.SubsystemRaw
            $subvendorId = $res.Fields.SubvendorId
            $subdeviceId = $res.Fields.SubdeviceId
            $revision = $res.Fields.Revision

            $vendorName = if ($res.Lookup.VendorName) { Get-FormattedHardwareVendorName -Name $res.Lookup.VendorName } else { 'Unknown Vendor' }
            $deviceName = if ($res.Lookup.DeviceName) { $res.Lookup.DeviceName } else { 'Unknown Device' }
            $subvendorName = if ($res.Lookup.SubvendorName) { Get-FormattedHardwareVendorName -Name $res.Lookup.SubvendorName } else { '' }
            $subsystemName = if ($res.Lookup.SubsystemName) { $res.Lookup.SubsystemName } else { '' }

            # 1. VEN
            $venText = "VEN_$vendorId"
            $venVal = Format-UiValue -Text $vendorName -MaxLength $valueWidth
            $venLine = "{0,-15} = {1}" -f $venText, $venVal
            $lines.Add("$pad$($_C.Dim)$($venLine)$($_C.Reset)")

            # 2. DEV
            $devText = "DEV_$deviceId"
            $devVal = Format-UiValue -Text $deviceName -MaxLength $valueWidth
            $devLine = "{0,-15} = {1}" -f $devText, $devVal
            $lines.Add("$pad$($_C.White)$($devLine)$($_C.Reset)")

            # 3. SUBSYS (if present)
            if (-not [string]::IsNullOrWhiteSpace($subsysRaw)) {
                $subvendorShort = Get-ShortHardwareVendorName -Name $subvendorName
                $subsysDesc = if (-not [string]::IsNullOrWhiteSpace($subsystemName)) {
                    $subsystemName
                } elseif (-not [string]::IsNullOrWhiteSpace($subvendorShort)) {
                    "$subvendorShort board-specific model"
                } else {
                    "board-specific model"
                }

                $subsysText = "SUBSYS_$subsysRaw"
                $subsysVal = Format-UiValue -Text $subsysDesc -MaxLength $valueWidth
                $subsysLine = "{0,-15} = {1}" -f $subsysText, $subsysVal
                $lines.Add("$pad$($_C.Info)$($subsysLine)$($_C.Reset)")

                # Subdevice ID
                $subdevDesc = "subsystem / board ID"
                $subdevLine = "   {0,-12} = {1}" -f $subdeviceId, $subdevDesc
                $lines.Add("$pad$($_C.Dim)$($subdevLine)$($_C.Reset)")

                # Subvendor ID
                $subvendorDesc = if (-not [string]::IsNullOrWhiteSpace($subvendorName)) {
                    "subvendor = $subvendorName"
                } else {
                    "subvendor"
                }
                $subvendorVal = Format-UiValue -Text $subvendorDesc -MaxLength ($valueWidth - 3)
                $subvendorLine = "   {0,-12} = {1}" -f $subvendorId, $subvendorVal
                $lines.Add("$pad$($_C.Dim)$($subvendorLine)$($_C.Reset)")
            }

            # 4. REV (if present)
            if (-not [string]::IsNullOrWhiteSpace($revision)) {
                $revText = "REV_$revision"
                $revLine = "{0,-15} = {1}" -f $revText, "hardware rev"
                $lines.Add("$pad$($_C.Dim)$($revLine)$($_C.Reset)")
            }
        }
        elseif ($res.Bus -in @('USB', 'HID') -and $res.IdType -ne 'USB_CLASS') {
            $vendorId = $res.Fields.VendorId
            $productId = $res.Fields.ProductId
            $interfaceId = $res.Fields.InterfaceId
            $revision = $res.Fields.Revision
            $evidence = Get-BoardModelEvidenceForResolution -Resolution $res

            $vendorName = if ($res.Lookup.VendorName) { Get-FormattedHardwareVendorName -Name $res.Lookup.VendorName } else { 'Unknown Vendor' }
            $productName = if ($res.Lookup.ProductName) {
                $res.Lookup.ProductName
            } elseif ($null -ne $evidence) {
                [string](Get-NotePropertyValue -Object $evidence -Name 'ModelName')
            } else {
                'Unknown Product'
            }
            $interfaceName = if ($res.Lookup.InterfaceName) {
                $res.Lookup.InterfaceName
            } elseif ($null -ne $evidence) {
                [string](Get-NotePropertyValue -Object $evidence -Name 'InterfaceName')
            } else {
                ''
            }

            # 1. VID
            $vidText = "VID_$vendorId"
            $vidVal = Format-UiValue -Text $vendorName -MaxLength $valueWidth
            $vidLine = "{0,-15} = {1}" -f $vidText, $vidVal
            $lines.Add("$pad$($_C.Dim)$($vidLine)$($_C.Reset)")

            # 2. PID
            $pidText = "PID_$productId"
            $pidVal = Format-UiValue -Text $productName -MaxLength $valueWidth
            $pidLine = "{0,-15} = {1}" -f $pidText, $pidVal
            $lines.Add("$pad$($_C.White)$($pidLine)$($_C.Reset)")

            # 3. MI (if present)
            if (-not [string]::IsNullOrWhiteSpace($interfaceId)) {
                $miText = "MI_$interfaceId"
                $miVal = if ($interfaceName) { $interfaceName } else { "interface" }
                $miLine = "{0,-15} = {1}" -f $miText, (Format-UiValue -Text $miVal -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($miLine)$($_C.Reset)")
            }

            # 4. REV (if present)
            if (-not [string]::IsNullOrWhiteSpace($revision)) {
                $revText = "REV_$revision"
                $revLine = "{0,-15} = {1}" -f $revText, "device revision / bcdDevice"
                $lines.Add("$pad$($_C.Dim)$($revLine)$($_C.Reset)")
            }
        }
        elseif ($res.Bus -in @('USB', 'HID') -and $res.IdType -eq 'USB_CLASS') {
            $classId = $res.Fields.ClassId
            $subclassId = $res.Fields.SubclassId
            $protocolId = $res.Fields.ProtocolId
            $className = if ($res.Lookup.ClassName) { $res.Lookup.ClassName } else { 'USB class' }
            $subclassName = if ($res.Lookup.SubclassName) { $res.Lookup.SubclassName } else { 'subclass' }
            $protocolName = if ($res.Lookup.ProtocolName) { $res.Lookup.ProtocolName } else { 'protocol' }

            if (-not [string]::IsNullOrWhiteSpace($classId)) {
                $classLine = "{0,-15} = {1}" -f "Class_$classId", (Format-UiValue -Text $className -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.White)$($classLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($subclassId)) {
                $subclassLine = "{0,-15} = {1}" -f "SubClass_$subclassId", (Format-UiValue -Text $subclassName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($subclassLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($protocolId)) {
                $protocolLine = "{0,-15} = {1}" -f "Prot_$protocolId", (Format-UiValue -Text $protocolName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($protocolLine)$($_C.Reset)")
            }
        }
        elseif ($res.Bus -eq 'HDAUDIO') {
            $functionId = $res.Fields.FunctionId
            $vendorId = $res.Fields.VendorId
            $deviceId = $res.Fields.DeviceId
            $subsysRaw = $res.Fields.SubsystemRaw
            $subvendorId = $res.Fields.SubvendorId
            $subdeviceId = $res.Fields.SubdeviceId
            $revision = $res.Fields.Revision
            $controllerVendorId = $res.Fields.ControllerVendorId
            $controllerDeviceId = $res.Fields.ControllerDeviceId
            $evidence = Get-BoardModelEvidenceForResolution -Resolution $res

            $functionName = if ($res.Lookup.FunctionName) { $res.Lookup.FunctionName } else { 'HD Audio function' }
            $vendorName = if ($res.Lookup.VendorName) { Get-FormattedHardwareVendorName -Name $res.Lookup.VendorName } else { 'Unknown codec vendor' }
            $codecName = if ($null -ne $evidence) { [string](Get-NotePropertyValue -Object $evidence -Name 'CodecName') } else { '' }
            $deviceName = if (-not [string]::IsNullOrWhiteSpace($codecName)) {
                $codecName
            } elseif ($res.Lookup.DeviceName) {
                $res.Lookup.DeviceName
            } else {
                'codec device id'
            }
            $subvendorName = if ($res.Lookup.SubvendorName) { Get-FormattedHardwareVendorName -Name $res.Lookup.SubvendorName } else { '' }
            $controllerVendorName = if ($res.Lookup.ControllerVendorName) { Get-FormattedHardwareVendorName -Name $res.Lookup.ControllerVendorName } else { '' }
            $controllerDeviceName = if ($res.Lookup.ControllerDeviceName) { $res.Lookup.ControllerDeviceName } else { '' }

            if (-not [string]::IsNullOrWhiteSpace($functionId)) {
                $functionLine = "{0,-15} = {1}" -f "FUNC_$functionId", (Format-UiValue -Text $functionName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($functionLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($vendorId)) {
                $vendorLine = "{0,-15} = {1}" -f "VEN_$vendorId", (Format-UiValue -Text $vendorName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($vendorLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($deviceId)) {
                $deviceLine = "{0,-15} = {1}" -f "DEV_$deviceId", (Format-UiValue -Text $deviceName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.White)$($deviceLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($subsysRaw)) {
                $subsystemDesc = if (-not [string]::IsNullOrWhiteSpace($subvendorName)) {
                    "$subvendorName audio implementation"
                } else {
                    'board audio implementation'
                }
                $subsysLine = "{0,-15} = {1}" -f "SUBSYS_$subsysRaw", (Format-UiValue -Text $subsystemDesc -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Info)$($subsysLine)$($_C.Reset)")

                $subvendorDesc = if (-not [string]::IsNullOrWhiteSpace($subvendorName)) {
                    "subsystem vendor = $subvendorName"
                } else {
                    'subsystem vendor'
                }
                $subvendorLine = "   {0,-12} = {1}" -f $subvendorId, (Format-UiValue -Text $subvendorDesc -MaxLength ($valueWidth - 3))
                $lines.Add("$pad$($_C.Dim)$($subvendorLine)$($_C.Reset)")

                $subdeviceLine = "   {0,-12} = {1}" -f $subdeviceId, 'board/implementation ID'
                $lines.Add("$pad$($_C.Dim)$($subdeviceLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($revision)) {
                $revisionLine = "{0,-15} = {1}" -f "REV_$revision", 'codec revision'
                $lines.Add("$pad$($_C.Dim)$($revisionLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($controllerVendorId)) {
                $controllerVendorText = if (-not [string]::IsNullOrWhiteSpace($controllerVendorName)) { $controllerVendorName } else { 'controller vendor' }
                $controllerVendorLine = "{0,-15} = {1}" -f "CTLR_VEN_$controllerVendorId", (Format-UiValue -Text $controllerVendorText -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($controllerVendorLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($controllerDeviceId)) {
                $controllerDeviceText = if (-not [string]::IsNullOrWhiteSpace($controllerDeviceName)) { $controllerDeviceName } else { 'controller device' }
                $controllerDeviceLine = "{0,-15} = {1}" -f "CTLR_DEV_$controllerDeviceId", (Format-UiValue -Text $controllerDeviceText -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($controllerDeviceLine)$($_C.Reset)")
            }
        }
        elseif ($res.Bus -eq 'DISPLAY') {
            $vendorId = $res.Fields.VendorId
            $productId = $res.Fields.ProductId
            $importantProperties = Get-NotePropertyValue -Object $Evidence -Name 'ImportantProperties'
            $localManufacturer = [string](Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_Manufacturer')
            $vendorName = if ($res.Lookup.VendorName) {
                Get-FormattedHardwareVendorName -Name $res.Lookup.VendorName
            } elseif (-not [string]::IsNullOrWhiteSpace($localManufacturer)) {
                "$localManufacturer (Windows)"
            } else {
                'display vendor code'
            }

            if (-not [string]::IsNullOrWhiteSpace($vendorId)) {
                $vendorLine = "{0,-15} = {1}" -f $vendorId, (Format-UiValue -Text $vendorName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($vendorLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($productId)) {
                $productLine = "{0,-15} = {1}" -f $productId, 'EDID/product code'
                $lines.Add("$pad$($_C.White)$($productLine)$($_C.Reset)")
            }
        }
        elseif ($res.Bus -in @('SCSI', 'USBSTOR', 'IDE')) {
            $isCompactStorageId = ([string]$res.IdType -match 'COMPACT')
            $deviceType = $res.Fields.DeviceType
            $vendorId = $res.Fields.VendorId
            $vendorDisplayId = [string](Get-NotePropertyValue -Object $res.Fields -Name 'VendorDisplayId')
            $productId = $res.Fields.ProductId
            $productDisplayId = [string](Get-NotePropertyValue -Object $res.Fields -Name 'ProductDisplayId')
            $revision = $res.Fields.Revision
            $deviceTypeName = if ($res.Lookup.DeviceTypeName) { $res.Lookup.DeviceTypeName } else { 'storage device' }
            $vendorName = if ($res.Lookup.VendorName) { $res.Lookup.VendorName } else { '' }
            $productName = if ($res.Lookup.ProductName) { $res.Lookup.ProductName } else { '' }
            $device = Get-NotePropertyValue -Object $Evidence -Name 'Device'
            $friendlyName = [string](Get-NotePropertyValue -Object $device -Name 'FriendlyName')
            if (-not [string]::IsNullOrWhiteSpace($friendlyName)) {
                $productName = $friendlyName
            }
            if ([string]::IsNullOrWhiteSpace($vendorDisplayId)) { $vendorDisplayId = $vendorId }
            if ([string]::IsNullOrWhiteSpace($productDisplayId)) { $productDisplayId = $productId }

            if (-not [string]::IsNullOrWhiteSpace($deviceType)) {
                $typeLine = "{0,-15} = {1}" -f $deviceType, (Format-UiValue -Text $deviceTypeName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.White)$($typeLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($vendorDisplayId)) {
                $vendorDisplayName = if ($vendorName -match '^(?i:NVME)$') { 'NVMe storage stack' } else { $vendorName }
                $vendorToken = if ($vendorName -match '^(?i:NVME)$') { "STACK_$vendorDisplayId" } else { "VEN_$vendorDisplayId" }
                $vendorLine = "{0,-15} = {1}" -f $vendorToken, (Format-UiValue -Text $vendorDisplayName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Dim)$($vendorLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($productDisplayId)) {
                $productToken = if ($isCompactStorageId) { 'MODEL' } else { "PROD_$productDisplayId" }
                $productLine = "{0,-15} = {1}" -f $productToken, (Format-UiValue -Text $productName -MaxLength $valueWidth)
                $lines.Add("$pad$($_C.Info)$($productLine)$($_C.Reset)")
            }
            if (-not [string]::IsNullOrWhiteSpace($revision)) {
                $revisionLine = "{0,-15} = {1}" -f "REV_$revision", 'storage device revision'
                $lines.Add("$pad$($_C.Dim)$($revisionLine)$($_C.Reset)")
            }
        }
        elseif ($res.Bus -in @('ACPI', 'PNP')) {
            $vendorId = $res.Fields.VendorId
            $deviceId = $res.Fields.DeviceId
            $vendorName = if ($res.Lookup.VendorName) { Get-FormattedHardwareVendorName -Name $res.Lookup.VendorName } else { 'Unknown Vendor' }
            $deviceName = if ($res.Lookup.DeviceName) { $res.Lookup.DeviceName } else { '' }

            # 1. VEN
            $venText = "VEN_$vendorId"
            $venVal = Format-UiValue -Text $vendorName -MaxLength $valueWidth
            $venLine = "{0,-15} = {1}" -f $venText, $venVal
            $lines.Add("$pad$($_C.Dim)$($venLine)$($_C.Reset)")

            # 2. DEV
            $devText = "DEV_$deviceId"
            $devVal = if ($deviceName) { $deviceName } else { "device code" }
            $devLine = "{0,-15} = {1}" -f $devText, (Format-UiValue -Text $devVal -MaxLength $valueWidth)
            $lines.Add("$pad$($_C.White)$($devLine)$($_C.Reset)")
        }
    }
    catch {
        # Silent fail
    }

    return @($lines)
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

function Convert-MarkdownResultToDisplayText {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $plain = [regex]::Replace($Text, '\[([^\]]+)\]\((https?://[^)]+)\)', '$1 - $2')
    $plain = $plain -replace '\*\*', ''
    return $plain.Trim()
}

function Convert-MarkdownInlineToAnsi {
    param(
        [AllowEmptyString()][string]$Text,
        [string]$BaseColor = $null
    )

    if (-not $BaseColor) { $BaseColor = $_C.White }
    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $ansiText = [string]$Text
    $ansiText = [regex]::Replace($ansiText, '`([^`]+)`', {
        param($match)
        return "$($_C.Info)$($match.Groups[1].Value)$BaseColor"
    })
    $ansiText = [regex]::Replace($ansiText, '(https?://[^\s\]\)\}>"]+)', {
        param($match)
        $url = $match.Groups[1].Value.TrimEnd('.', ',', ';', ':')
        $suffix = $match.Groups[1].Value.Substring($url.Length)
        $label = New-TerminalHyperlink -Label $url -Url $url
        return "$($_C.Info)$label$BaseColor$suffix"
    })

    return $ansiText
}

function Add-WrappedMarkdownParagraphLines {
    param(
        [Parameter(Mandatory)]$Lines,
        [AllowEmptyString()][string]$Text,
        [int]$Width,
        [int]$MaxLines,
        [string]$Color = $null,
        [string]$FirstPrefix = '  ',
        [string]$RestPrefix = '  '
    )

    $remaining = [Math]::Max(0, $MaxLines)
    if ($remaining -le 0 -or [string]::IsNullOrWhiteSpace($Text)) { return 0 }
    if (-not $Color) { $Color = $_C.White }

    $firstPrefixPlain = Remove-AnsiSequence -Text $FirstPrefix
    $restPrefixPlain = Remove-AnsiSequence -Text $RestPrefix
    $bodyWidth = [Math]::Max(8, $Width - [Math]::Max($firstPrefixPlain.Length, $restPrefixPlain.Length))
    $wrapped = @(Wrap-PlainText -Text $Text -Width $bodyWidth -MaxLines $remaining)
    $written = 0

    for ($i = 0; $i -lt $wrapped.Count -and $written -lt $remaining; $i++) {
        $prefix = if ($i -eq 0) { $FirstPrefix } else { $RestPrefix }
        $prefixPlainLength = (Remove-AnsiSequence -Text $prefix).Length
        $lineWidth = [Math]::Max(1, $Width - $prefixPlainLength)
        $lineText = Convert-MarkdownInlineToAnsi -Text (Format-PlainToWidth -Text $wrapped[$i] -Width $lineWidth) -BaseColor $Color
        $Lines.Add("$prefix$Color$lineText$($_C.Reset)")
        $written++
    }

    return $written
}

function Add-MarkdownDetailTextLines {
    param(
        [Parameter(Mandatory)]$Lines,
        [AllowEmptyString()][string]$Text,
        [int]$Width,
        [int]$MaxLines
    )

    $remaining = [Math]::Max(0, $MaxLines)
    if ($remaining -le 0 -or [string]::IsNullOrWhiteSpace($Text)) { return }

    $normalized = $Text -replace "`r", ''
    foreach ($rawLine in ($normalized -split "`n")) {
        if ($remaining -le 0) { break }
        $line = $rawLine.TrimEnd()

        if ([string]::IsNullOrWhiteSpace($line)) {
            $Lines.Add('')
            $remaining--
            continue
        }

        if ($line -match '^\s{0,3}#{1,6}\s+(.+)$') {
            $heading = Convert-MarkdownResultToDisplayText -Text $Matches[1]
            $remaining -= Add-WrappedMarkdownParagraphLines -Lines $Lines -Text $heading -Width $Width -MaxLines $remaining -Color "$($_C.Bold)$($_C.H1)" -FirstPrefix '  ' -RestPrefix '  '
            continue
        }

        if ($line -match '^\s{0,3}(\d+)\.\s+(.+)$') {
            $number = $Matches[1]
            $body = Convert-MarkdownResultToDisplayText -Text $Matches[2]
            $remaining -= Add-WrappedMarkdownParagraphLines -Lines $Lines -Text $body -Width $Width -MaxLines $remaining -Color "$($_C.Bold)$($_C.White)" -FirstPrefix "  $($_C.Gold)$number.$($_C.Reset) " -RestPrefix '     '
            continue
        }

        if ($line -match '^\s{0,3}[*+-]\s+(.+)$') {
            $body = Convert-MarkdownResultToDisplayText -Text $Matches[1]
            $remaining -= Add-WrappedMarkdownParagraphLines -Lines $Lines -Text $body -Width $Width -MaxLines $remaining -Color $_C.White -FirstPrefix "  $($_C.OK)*$($_C.Reset) " -RestPrefix '    '
            continue
        }

        $display = Convert-MarkdownResultToDisplayText -Text $line
        $color = if ($display -match ':\s*$') { "$($_C.Bold)$($_C.H1)" } elseif ($display -match 'https?://') { $_C.Info } else { $_C.White }
        $remaining -= Add-WrappedMarkdownParagraphLines -Lines $Lines -Text $display -Width $Width -MaxLines $remaining -Color $color -FirstPrefix '  ' -RestPrefix '  '
    }
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

    if (Test-RemoteSnapshotTargetActive) {
        return Get-DeviceCategoriesFromSnapshot -Snapshot $script:TargetSnapshot
    }

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

function Get-SnapshotDevicePropertyMap {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][string]$InstanceId
    )

    $propertiesRoot = Get-NotePropertyValue -Object (Get-NotePropertyValue -Object $Snapshot -Name 'Devices') -Name 'Properties'
    $properties = Get-NotePropertyValue -Object $propertiesRoot -Name $InstanceId
    $map = [ordered]@{}

    foreach ($property in @($properties)) {
        $keyName = [string](Get-NotePropertyValue -Object $property -Name 'KeyName')
        if ([string]::IsNullOrWhiteSpace($keyName)) {
            continue
        }

        $map[$keyName] = Get-NotePropertyValue -Object $property -Name 'Data'
    }

    return $map
}

function New-SnapshotDeviceEvidence {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$Device
    )

    $instanceId = [string](Get-NotePropertyValue -Object $Device -Name 'InstanceId')
    $importantData = Get-SnapshotDevicePropertyMap -Snapshot $Snapshot -InstanceId $instanceId

    if (-not $importantData.Contains('DEVPKEY_Device_HardwareIds')) {
        $hardwareIds = Get-NotePropertyValue -Object $Device -Name 'HardwareId'
        if ($hardwareIds) { $importantData['DEVPKEY_Device_HardwareIds'] = $hardwareIds }
    }
    if (-not $importantData.Contains('DEVPKEY_Device_CompatibleIds')) {
        $compatibleIds = Get-NotePropertyValue -Object $Device -Name 'CompatibleId'
        if ($compatibleIds) { $importantData['DEVPKEY_Device_CompatibleIds'] = $compatibleIds }
    }
    if (-not $importantData.Contains('DEVPKEY_Device_Manufacturer')) {
        $manufacturer = Get-NotePropertyValue -Object $Device -Name 'Manufacturer'
        if ($manufacturer) { $importantData['DEVPKEY_Device_Manufacturer'] = $manufacturer }
    }
    if (-not $importantData.Contains('DEVPKEY_Device_Service')) {
        $service = Get-NotePropertyValue -Object $Device -Name 'Service'
        if ($service) { $importantData['DEVPKEY_Device_Service'] = $service }
    }

    $collector = Get-NotePropertyValue -Object $Snapshot -Name 'Collector'
    $capturedAt = Get-NotePropertyValue -Object $collector -Name 'FinishedAt'
    if ([string]::IsNullOrWhiteSpace([string]$capturedAt)) {
        $capturedAt = Get-NotePropertyValue -Object $collector -Name 'StartedAt'
    }

    return [PSCustomObject]@{
        SchemaVersion       = 'DeviceCheckSnapshotEvidence/0.1'
        CapturedAt          = $capturedAt
        Source              = 'Snapshot'
        SnapshotPath        = $script:TargetSnapshotPath
        Device              = $Device
        Machine             = $script:MachineEvidence
        ImportantProperties = [PSCustomObject]$importantData
        PnpUtil             = Get-NotePropertyValue -Object $Snapshot -Name 'PnpUtil'
    }
}

function Set-SnapshotEvidenceCache {
    param([Parameter(Mandatory)]$Snapshot)

    Invalidate-EvidenceCache
    $devices = @((Get-NotePropertyValue -Object (Get-NotePropertyValue -Object $Snapshot -Name 'Devices') -Name 'Present'))
    foreach ($device in $devices) {
        $instanceId = [string](Get-NotePropertyValue -Object $device -Name 'InstanceId')
        if ([string]::IsNullOrWhiteSpace($instanceId)) {
            continue
        }

        $script:EvidenceCacheMemory[$instanceId] = New-SnapshotDeviceEvidence -Snapshot $Snapshot -Device $device
    }
}

function Get-DeviceCategoriesFromSnapshot {
    param([Parameter(Mandatory)]$Snapshot)

    $devicesRoot = Get-NotePropertyValue -Object $Snapshot -Name 'Devices'
    $snapshotDevices = @((Get-NotePropertyValue -Object $devicesRoot -Name 'Present'))
    $grouped = @{}

    foreach ($dev in $snapshotDevices) {
        $classKey = [string](Get-NotePropertyValue -Object $dev -Name 'Class')
        $className = Get-DeviceManagerClassName -ClassName $classKey
        if ([string]::IsNullOrWhiteSpace($className)) {
            $className = 'Other devices'
        }

        $errorCodeText = [string](Get-NotePropertyValue -Object $dev -Name 'ConfigManagerErrorCode')
        $errorCode = 0
        if (-not [string]::IsNullOrWhiteSpace($errorCodeText)) {
            try { $errorCode = [int]$errorCodeText } catch { $errorCode = 0 }
        }

        $instanceId = [string](Get-NotePropertyValue -Object $dev -Name 'InstanceId')
        $friendlyName = [string](Get-NotePropertyValue -Object $dev -Name 'FriendlyName')
        if ([string]::IsNullOrWhiteSpace($friendlyName)) {
            $friendlyName = $instanceId
        }

        $devInfo = [PSCustomObject]@{
            InstanceId             = $instanceId
            FriendlyName           = $friendlyName
            Class                  = $className
            ClassKey               = $classKey
            Status                 = Get-NotePropertyValue -Object $dev -Name 'Status'
            ConfigManagerErrorCode = $errorCode
            IsProblem              = ($errorCode -ne 0)
            SearchStatus           = $null
            SearchResults          = @()
            SearchKind             = $null
            SearchDetail           = $null
            SearchTracePath        = $null
            SearchCheckpointPath   = $null
            EvidenceCached         = $true
        }

        if (-not $grouped.ContainsKey($className)) {
            $grouped[$className] = [System.Collections.Generic.List[object]]::new()
        }
        $grouped[$className].Add($devInfo)
    }

    $categories = [System.Collections.Generic.List[object]]::new()
    foreach ($key in ($grouped.Keys | Sort-Object)) {
        $categories.Add([PSCustomObject]@{
            Name       = $key
            IsExpanded = $false
            Devices    = @($grouped[$key] | Sort-Object FriendlyName)
        })
    }

    Set-SnapshotEvidenceCache -Snapshot $Snapshot
    return $categories
}

function Invoke-SystemScan {
    param([switch]$Quiet)

    if (Test-RemoteSnapshotTargetActive) {
        $targetName = if (-not [string]::IsNullOrWhiteSpace($script:TargetComputerName)) { $script:TargetComputerName } else { 'remote target' }
        try { [Console]::CursorVisible = $true } catch {}
        
        if ($null -eq $script:TargetCredential -and -not [string]::IsNullOrWhiteSpace($targetName)) {
            $script:TargetCredential = $script:CredentialCache[$targetName.ToLower()]
            if ($null -eq $script:TargetCredential) {
                $script:TargetCredential = Get-DeviceCheckStoredCredential -ComputerName $targetName
            }
        }
        
        $collection = Invoke-RemoteSnapshotCollectionScreen -ComputerName $targetName -Credential $script:TargetCredential -PromptForCredential:($null -eq $script:TargetCredential)
        if ($collection.Success) {
            Set-ActiveSnapshotTarget -Snapshot $collection.Export.Snapshot -SnapshotPath $collection.Export.LatestPath -ComputerName $targetName -Credential $collection.Credential
        } else {
            $script:SystemScanMessage = "Remote refresh failed or cancelled: $targetName | $(Get-Date -Format 'HH:mm:ss')"
            $script:RequestForceClear = $true
            $script:TargetCredential = $null
        }
        try { Initialize-TuiHost } catch {}
        try { [Console]::CursorVisible = $false } catch {}
        return
    }

    $scanStarted = Get-Date
    $script:TargetMode = 'Local'
    $script:TargetSnapshot = $null
    $script:TargetSnapshotPath = $null
    $script:TargetComputerName = $env:COMPUTERNAME
    $script:MachineEvidence = Get-MachineEvidence
    $script:MachineCacheRoot = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath "machines\$($script:MachineEvidence.MachineId)"
    try { $null = New-Item -ItemType Directory -Path $script:MachineCacheRoot -Force } catch {}
    Invalidate-EvidenceCache  # clear all in-memory evidence on rescan

    $script:categories = Get-DeviceCategories -Quiet:$Quiet
    $deviceCount = 0
    foreach ($category in $script:categories) {
        $deviceCount += @($category.Devices).Count
    }

    $elapsedMs = [int]((Get-Date) - $scanStarted).TotalMilliseconds
    $summary = Get-MachineSummary -MachineEvidence $script:MachineEvidence -DeviceCount $deviceCount -CategoryCount @($script:categories).Count -ElapsedMs $elapsedMs
    $script:SystemScanMessage = "Local system scan complete | $(Get-Date -Format 'HH:mm:ss')"
}

function Invoke-DeviceCheckSnapshotExport {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential,
        [scriptblock]$OnProgress
    )

    $exportScript = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'internal\Export-DeviceCheckEvidence.ps1'
    if (-not (Test-Path -LiteralPath $exportScript -PathType Leaf)) {
        throw "Remote evidence exporter not found: $exportScript"
    }

    $script:RemoteConnectionLog = [System.Collections.Generic.List[string]]::new()
    $exportParams = @{
        ComputerName = $ComputerName
        AsJson       = $true
        Verbose      = $true
    }
    if ($null -ne $Credential) {
        $exportParams.Credential = $Credential
    } else {
        $exportParams.UseCurrentCredentials = $true
    }

    if ($null -ne $OnProgress) {
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript({
            param($scriptPath, $params)
            $ProgressPreference = 'SilentlyContinue'
            $VerbosePreference = 'Continue'
            & $scriptPath @params
        }).AddArgument($exportScript).AddArgument($exportParams)

        $asyncResult = $ps.BeginInvoke()
        
        $spinnerChars = @('|', '/', '-', '\')
        $spinnerIdx = 0
        
        $progressWidth = 20
        $pos = 0
        $direction = 1
        
        $verboseCount = 0
        $currentActivity = "Initiating connection"
        
        try {
            while (-not $asyncResult.IsCompleted) {
                while ($ps.Streams.Verbose.Count -gt $verboseCount) {
                    $msg = $ps.Streams.Verbose[$verboseCount].Message
                    $verboseCount++
                    $script:RemoteConnectionLog.Add($msg)
                    $currentActivity = $msg
                }

                $bar = [System.Text.StringBuilder]::new()
                for ($i = 0; $i -lt $progressWidth; $i++) {
                    if ($i -ge $pos -and $i -lt ($pos + 4)) {
                        $null = $bar.Append('#')
                    } else {
                        $null = $bar.Append('-')
                    }
                }
                $pos += $direction
                if ($pos -eq ($progressWidth - 4) -or $pos -eq 0) {
                    $direction = -$direction
                }
                
                $spinner = $spinnerChars[$spinnerIdx]
                $spinnerIdx = ($spinnerIdx + 1) % $spinnerChars.Count
                
                $loadingText = "[$($bar.ToString())] $currentActivity... $spinner"
                & $OnProgress $loadingText
                
                if ([Console]::KeyAvailable) {
                    $keyInfo = $null
                    try {
                        $keyInfo = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                    } catch {
                        $keyInfo = [Console]::ReadKey($true)
                    }
                    if ($null -ne $keyInfo -and ($keyInfo.Key -eq 'Escape' -or $keyInfo.KeyChar -eq [char]27)) {
                        $ps.Stop()
                        throw "Connection cancelled by user."
                    }
                }
                if (Test-WindowResized) {
                    $script:RequestForceClear = $true
                }
                
                Start-Sleep -Milliseconds 100
            }
            $output = $ps.EndInvoke($asyncResult)
            if ($ps.HadErrors) {
                $errorMsg = $ps.Streams.Error | ForEach-Object { $_.ToString() } | Out-String
                throw $errorMsg
            }
        } finally {
            $ps.Dispose()
        }
        $summaryJson = @($output) -join "`n"
    } else {
        $summaryJson = @(& $exportScript @exportParams) -join "`n"
    }

    $summary = $summaryJson | ConvertFrom-Json -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$summary.LatestPath) -or -not (Test-Path -LiteralPath $summary.LatestPath -PathType Leaf)) {
        throw "Remote snapshot export completed but latest snapshot was not found for $ComputerName."
    }

    $snapshot = Get-Content -LiteralPath $summary.LatestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    return [PSCustomObject]@{
        Summary    = $summary
        Snapshot   = $snapshot
        LatestPath = [string]$summary.LatestPath
    }
}

function Read-TuiLine {
    param(
        [Parameter(Mandatory)][scriptblock]$RenderBlock,
        [string]$DefaultValue = '',
        [bool]$IsPassword = $false
    )

    $inputVal = $DefaultValue
    
    try {
        [Console]::CursorVisible = $true
        while ($true) {
            $displayInput = if ($IsPassword) { '*' * $inputVal.Length } else { $inputVal }
            & $RenderBlock $displayInput
            
            $key = Read-ConsoleKey
            if ($null -eq $key -or -not $key.PSObject.Properties['Key']) {
                Start-Sleep -Milliseconds 10
                continue
            }
            
            switch ($key.Key) {
                'Enter' {
                    return $inputVal
                }
                'Escape' {
                    return $null
                }
                'Backspace' {
                    if ($inputVal.Length -gt 0) {
                        $inputVal = $inputVal.Substring(0, $inputVal.Length - 1)
                    }
                }
                'ResizeEvent' {
                    $script:RequestForceClear = $true
                    continue
                }
                default {
                    if ($key.KeyChar -ne [char]0 -and -not [char]::IsControl($key.KeyChar) -and -not $key.ControlPressed) {
                        $inputVal += [string]$key.KeyChar
                    }
                }
            }
        }
    } finally {
        try { [Console]::CursorVisible = $false } catch {}
    }
}

function New-DeviceCheckCredentialFromPrompt {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [string]$DefaultUserName
    )

    $script:RequestForceClear = $true
    if ([string]::IsNullOrWhiteSpace($DefaultUserName)) {
        $DefaultUserName = "$ComputerName\joty79"
    }

    # Prompt for Username
    $renderUserBlock = {
        param($currentInput)
        $width = Get-UiWidth
        $frame = New-UiFrame
        Add-UiFrameBanner -Frame $frame -Title "Credentials Required" -Subtitle "Connecting to $ComputerName" -Width $width
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Enter credentials for WinRM management on target PC.$($_C.Reset)$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Target :$($_C.Reset) $($_C.Info)$ComputerName$($_C.Reset)$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Bold)$($_C.White)Username [$DefaultUserName]:$($_C.Reset)$($_C.EraseLn)"
        $null = $frame.Append("  Username: $currentInput")
        Write-UiFrame -Frame $frame
    }
    $userName = Read-TuiLine -RenderBlock $renderUserBlock -DefaultValue ''
    if ($null -eq $userName) {
        throw "Connection cancelled by user."
    }
    if ([string]::IsNullOrWhiteSpace($userName)) {
        $userName = $DefaultUserName
    }

    # Prompt for Password
    $script:RequestForceClear = $true
    $renderPasswordBlock = {
        param($currentInput)
        $width = Get-UiWidth
        $frame = New-UiFrame
        Add-UiFrameBanner -Frame $frame -Title "Credentials Required" -Subtitle "Connecting to $ComputerName" -Width $width
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Enter credentials for WinRM management on target PC.$($_C.Reset)$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Target :$($_C.Reset) $($_C.Info)$ComputerName$($_C.Reset)$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)User   :$($_C.Reset) $($_C.White)$userName$($_C.Reset)$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Bold)$($_C.White)Password for $($userName):$($_C.Reset)$($_C.EraseLn)"
        $null = $frame.Append("  Password: $currentInput")
        Write-UiFrame -Frame $frame
    }
    $passwordStr = Read-TuiLine -RenderBlock $renderPasswordBlock -DefaultValue '' -IsPassword $true
    if ($null -eq $passwordStr) {
        throw "Connection cancelled by user."
    }
    $password = if ([string]::IsNullOrEmpty($passwordStr)) {
        [System.Security.SecureString]::new()
    } else {
        ConvertTo-SecureString $passwordStr -AsPlainText -Force
    }
    return [System.Management.Automation.PSCredential]::new($userName, $password)
}

function Show-RemoteSnapshotCollectionScreen {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [string]$UserName,
        [string]$Subtitle = 'Collecting full remote snapshot over WinRM.',
        [switch]$ShowCollecting,
        [string]$ProgressText
    )

    $frame = New-Object System.Text.StringBuilder
    $width = Get-UiWidth
    Add-UiFrameBanner -Frame $frame -Title "Refresh $ComputerName" -Subtitle $Subtitle -Width $width

    $null = $frame.AppendLine('')
    $null = $frame.AppendLine("  $($_C.Dim)Target :$($_C.Reset) $($_C.Info)$ComputerName$($_C.Reset)$($_C.EraseLn)")
    if (-not [string]::IsNullOrWhiteSpace($UserName)) {
        $null = $frame.AppendLine("  $($_C.Dim)User   :$($_C.Reset) $($_C.White)$UserName$($_C.Reset)$($_C.EraseLn)")
    }
    $null = $frame.AppendLine('')

    if ($ShowCollecting) {
        $barText = if (-not [string]::IsNullOrWhiteSpace($ProgressText)) { $ProgressText } else { '[##########----------] Collecting system, devices, properties, pnputil, monitors...' }
        $null = $frame.AppendLine("  $($_C.Info)$barText$($_C.Reset)$($_C.EraseLn)")
        $null = $frame.AppendLine('')
        $null = $frame.AppendLine("  $($_C.Dim)This can take a few seconds on LAN. Press ESC to cancel.$($_C.Reset)$($_C.EraseLn)")
    }
    
    Write-UiFrame -Frame $frame
}

function Invoke-RemoteSnapshotCollectionScreen {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$PromptForCredential
    )

    try {
        Clear-TuiScreen
        $defaultUserName = "$ComputerName\joty79"
        if ($PromptForCredential -or $null -eq $Credential) {
            Show-RemoteSnapshotCollectionScreen -ComputerName $ComputerName -UserName $defaultUserName -Subtitle 'Enter credentials for this LAN target.'
            $Credential = New-DeviceCheckCredentialFromPrompt -ComputerName $ComputerName -DefaultUserName $defaultUserName
            Clear-TuiScreen
        }

        $progressCallback = {
            param($progressText)
            Show-RemoteSnapshotCollectionScreen -ComputerName $ComputerName -UserName $Credential.UserName -ShowCollecting -ProgressText $progressText
        }

        $export = Invoke-DeviceCheckSnapshotExport -ComputerName $ComputerName -Credential $Credential -OnProgress $progressCallback
        return [PSCustomObject]@{
            Success    = $true
            Credential = $Credential
            Export     = $export
            Error      = $null
        }
    } catch {
        $message = $_.Exception.Message
        Remove-DeviceCheckStoredCredential -ComputerName $ComputerName
        
        $renderErrorBlock = {
            param()
            Clear-TuiScreen
            $width = Get-UiWidth
            $frame = New-Object System.Text.StringBuilder
            Add-UiFrameBanner -Frame $frame -Title "Cannot connect to $ComputerName" -Subtitle 'The target may be asleep, offline, blocked by firewall, or rejecting credentials.' -Width $width
            
            $null = $frame.AppendLine('')
            $null = $frame.AppendLine("  $($_C.Fail)Connection failed.$($_C.Reset)$($_C.EraseLn)")
            $null = $frame.AppendLine('')
            
            foreach ($line in (Wrap-PlainText -Text $message -Width ([Math]::Max(50, $width - 6)) -MaxLines 8)) {
                $null = $frame.AppendLine("  $($_C.Warn)$line$($_C.Reset)$($_C.EraseLn)")
            }
            $null = $frame.AppendLine('')
            
            if ($script:RemoteConnectionLog -and $script:RemoteConnectionLog.Count -gt 0) {
                $null = $frame.AppendLine("  $($_C.Bold)$($_C.White)Connection Log:$($_C.Reset)$($_C.EraseLn)")
                foreach ($logLine in $script:RemoteConnectionLog) {
                    $null = $frame.AppendLine("    $($_C.Dim)> $logLine$($_C.Reset)$($_C.EraseLn)")
                }
                $null = $frame.AppendLine('')
            }
            
            $null = $frame.AppendLine("  $($_C.Dim)No target switch was made. Wake the PC / check WinRM, then try again.$($_C.Reset)$($_C.EraseLn)")
            $null = $frame.AppendLine('')
            $null = $frame.AppendLine("  $($_C.Info)Press Enter to return$($_C.Reset)$($_C.EraseLn)")
            $null = $frame.AppendLine('')
            $null = $frame.AppendLine("$($_E)[J")
            
            try { [Console]::Write($frame.ToString()) } catch { $frame.ToString() | Write-Host }
        }

        while ($true) {
            & $renderErrorBlock
            $key = Read-ConsoleKey
            if ($null -eq $key -or -not $key.PSObject.Properties['Key']) {
                Start-Sleep -Milliseconds 10
                continue
            }
            if ($key.Key -eq 'Enter') {
                break
            }
            if ($key.Key -eq 'ResizeEvent') {
                $script:RequestForceClear = $true
                continue
            }
        }

        return [PSCustomObject]@{
            Success    = $false
            Credential = $Credential
            Export     = $null
            Error      = $message
        }
    }
}

function Set-ActiveSnapshotTarget {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][string]$SnapshotPath,
        [Parameter(Mandatory)][string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential
    )

    foreach ($id in @($script:ActiveSearches.Keys)) {
        Stop-DeviceLookup -InstanceId $id
    }
    if ($null -ne $script:EvidenceBatchQueue) { $script:EvidenceBatchQueue.Clear() }
    if ($null -ne $script:EvidenceBatchQueuedIds) { $script:EvidenceBatchQueuedIds.Clear() }
    $script:EvidenceBatchState = $null

    $script:TargetMode = 'RemoteSnapshot'
    $script:TargetComputerName = $ComputerName
    $script:TargetCredential = $Credential
    if ($null -ne $Credential -and -not [string]::IsNullOrWhiteSpace($ComputerName)) {
        $script:CredentialCache[$ComputerName.ToLower()] = $Credential
        Save-DeviceCheckStoredCredential -ComputerName $ComputerName -Credential $Credential
    }
    $script:TargetSnapshot = $Snapshot
    $script:TargetSnapshotPath = $SnapshotPath
    $script:MachineEvidence = Convert-SnapshotMachineToMachineEvidence -Snapshot $Snapshot
    $script:MachineCacheRoot = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath "machines\$($script:MachineEvidence.MachineId)"
    try { $null = New-Item -ItemType Directory -Path $script:MachineCacheRoot -Force } catch {}

    $script:categories = Get-DeviceCategoriesFromSnapshot -Snapshot $Snapshot
    $script:selectedIndex = 0
    $script:DetailScrollOffset = 0
    $script:DetailCursorIndex = 0
    $script:ActivePane = 'Tree'
    $script:VisibleRowsDirty = $true
    $script:visibleRows = Update-VisibleRows
    $script:VisibleRowsDirty = $false
    $script:RequestForceClear = $true

    $deviceCount = 0
    foreach ($category in $script:categories) {
        $deviceCount += @($category.Devices).Count
    }
    $script:SystemScanMessage = "Connected to $ComputerName snapshot: $deviceCount devices | $(Get-Date -Format 'HH:mm:ss')"
}

function Invoke-ConnectLanTarget {
    Reset-AllEvidenceScanConfirmation
    try { [Console]::CursorVisible = $true } catch {}
    $script:RequestForceClear = $true
    
    $renderBlock = {
        param($currentInput)
        $width = Get-UiWidth
        $frame = New-UiFrame
        Add-UiFrameBanner -Frame $frame -Title 'Connect to LAN PC' -Subtitle 'Open cached snapshots instantly; refresh only when you ask.' -Width $width
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Current target :$($_C.Reset) $($_C.Info)$(Get-TargetStatusText)$($_C.Reset)$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Bold)$($_C.White)Enter Computer name or IP (default: PALIOS - Use IP to bypass Kerberos lag):$($_C.Reset)$($_C.EraseLn)"
        $null = $frame.Append("  Target: $currentInput")
        Write-UiFrame -Frame $frame
    }
    $target = Read-TuiLine -RenderBlock $renderBlock -DefaultValue ''
    if ($null -eq $target) {
        $script:SystemScanMessage = "Connect cancelled. | $(Get-Date -Format 'HH:mm:ss')"
        $script:RequestForceClear = $true
        try { Initialize-TuiHost } catch {}
        try { [Console]::CursorVisible = $false } catch {}
        return
    }
    if ([string]::IsNullOrWhiteSpace($target)) {
        $target = 'PALIOS'
    }
    $target = $target.Trim()

    if (Test-DeviceCheckLocalTargetName -ComputerName $target) {
        $frame = New-UiFrame
        Add-UiFrameBanner -Frame $frame -Title 'Connect to LAN PC' -Subtitle 'Switching back to local host...' -Width (Get-UiWidth)
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  $($_C.OK)Re-initializing local system scan...$($_C.Reset)$($_C.EraseLn)"
        Write-UiFrame -Frame $frame
        
        $script:TargetMode = 'Local'
        $script:TargetCredential = $null
        $script:TargetSnapshot = $null
        $script:TargetSnapshotPath = $null
        Invoke-SystemScan -Quiet
        $script:selectedIndex = 0
        $script:DetailScrollOffset = 0
        $script:DetailCursorIndex = 0
        $script:ActivePane = 'Tree'
        $script:VisibleRowsDirty = $true
        $script:visibleRows = Update-VisibleRows
        $script:VisibleRowsDirty = $false
        $script:RequestForceClear = $true
        try { Initialize-TuiHost } catch {}
        try { [Console]::CursorVisible = $false } catch {}
        return
    }

    $cached = Find-LatestSnapshotForComputerName -ComputerName $target
    if ($null -ne $cached) {
        $collector = Get-NotePropertyValue -Object $cached.Snapshot -Name 'Collector'
        $finishedAt = [string](Get-NotePropertyValue -Object $collector -Name 'FinishedAt')
        $devicesRoot = Get-NotePropertyValue -Object $cached.Snapshot -Name 'Devices'
        $deviceCount = [string](Get-NotePropertyValue -Object $devicesRoot -Name 'Count')
        if ([string]::IsNullOrWhiteSpace($deviceCount)) {
            $deviceCount = [string](@((Get-NotePropertyValue -Object $devicesRoot -Name 'Present')).Count)
        }

        $script:RequestForceClear = $true
        $renderChoiceBlock = {
            param($currentInput)
            $width = Get-UiWidth
            $frame = New-UiFrame
            Add-UiFrameBanner -Frame $frame -Title "Cached Snapshot Found" -Subtitle "Target computer: $target" -Width $width
            Add-UiFrameLine -Frame $frame
            Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Target :$($_C.Reset) $($_C.Info)$target$($_C.Reset)$($_C.EraseLn)"
            Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Time   :$($_C.Reset) $($_C.White)$finishedAt$($_C.Reset)$($_C.EraseLn)"
            Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Devices:$($_C.Reset) $($_C.White)$deviceCount$($_C.Reset)$($_C.EraseLn)"
            Add-UiFrameLine -Frame $frame
            Add-UiFrameLine -Frame $frame -Text "  $($_C.Bold)$($_C.White)Choose Action:$($_C.Reset)$($_C.EraseLn)"
            Add-UiFrameLine -Frame $frame -Text "  $($_C.OK)Enter$($_C.Reset) = Open cached snapshot$($_C.EraseLn)"
            Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)R$($_C.Reset)     = Connect and refresh snapshot now$($_C.EraseLn)"
            Add-UiFrameLine -Frame $frame -Text "  $($_C.Fail)C$($_C.Reset)     = Cancel connection$($_C.EraseLn)"
            Add-UiFrameLine -Frame $frame
            $null = $frame.Append("  Select option: $currentInput")
            Write-UiFrame -Frame $frame
        }
        
        $choice = Read-TuiLine -RenderBlock $renderChoiceBlock -DefaultValue ''
        if ($null -eq $choice) {
            $script:SystemScanMessage = "Connect cancelled. | $(Get-Date -Format 'HH:mm:ss')"
            $script:RequestForceClear = $true
            try { Initialize-TuiHost } catch {}
            try { [Console]::CursorVisible = $false } catch {}
            return
        }
        
        if ([string]::IsNullOrWhiteSpace($choice)) {
            $cachedCredential = $script:TargetCredential
            if ($null -eq $cachedCredential) {
                $cachedCredential = $script:CredentialCache[$target.ToLower()]
            }
            if ($null -eq $cachedCredential) {
                $cachedCredential = Get-DeviceCheckStoredCredential -ComputerName $target
            }
            Set-ActiveSnapshotTarget -Snapshot $cached.Snapshot -SnapshotPath $cached.LatestPath -ComputerName $target -Credential $cachedCredential
            try { Initialize-TuiHost } catch {}
            try { [Console]::CursorVisible = $false } catch {}
            return
        }
        if ($choice.Trim().Equals('C', [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:SystemScanMessage = "Connect cancelled. | $(Get-Date -Format 'HH:mm:ss')"
            $script:RequestForceClear = $true
            try { Initialize-TuiHost } catch {}
            try { [Console]::CursorVisible = $false } catch {}
            return
        }
        if (-not $choice.Trim().Equals('R', [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:SystemScanMessage = "Connect cancelled: unknown choice '$choice'. | $(Get-Date -Format 'HH:mm:ss')"
            $script:RequestForceClear = $true
            try { Initialize-TuiHost } catch {}
            try { [Console]::CursorVisible = $false } catch {}
            return
        }
    }

    try {
        $existingCredential = $script:TargetCredential
        if ($null -eq $existingCredential) {
            $existingCredential = $script:CredentialCache[$target.ToLower()]
        }
        if ($null -eq $existingCredential) {
            $existingCredential = Get-DeviceCheckStoredCredential -ComputerName $target
        }
        $collection = Invoke-RemoteSnapshotCollectionScreen -ComputerName $target -Credential $existingCredential -PromptForCredential:($null -eq $existingCredential)
        if ($collection.Success) {
            Set-ActiveSnapshotTarget -Snapshot $collection.Export.Snapshot -SnapshotPath $collection.Export.LatestPath -ComputerName $target -Credential $collection.Credential
        } else {
            $script:SystemScanMessage = "Connect cancelled or failed: $target | $(Get-Date -Format 'HH:mm:ss')"
            $script:RequestForceClear = $true
        }
    } catch {
        $script:SystemScanMessage = "Connect failed: $target | $(Get-Date -Format 'HH:mm:ss')"
        $script:RequestForceClear = $true
    } finally {
        try { Initialize-TuiHost } catch {}
        try { [Console]::CursorVisible = $false } catch {}
    }
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
                        $statusName = 'Search failed'
                        if ($d.SearchResults -and $d.SearchResults.Count -gt 0) {
                            $statusName = [string]$d.SearchResults[0]
                        }
                        $rows.Add([PSCustomObject]@{
                            Type         = 'Status'
                            Name         = $statusName
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
    $script:VisibleRowsDirty = $true
}

function Expand-SelectedNode {
    param($Row)

    if ($null -eq $Row) { return }
    if ($Row.Type -eq 'Root') {
        Set-AllCategoriesExpanded -Expanded $true
    } elseif ($Row.Type -eq 'Category') {
        $Row.Ref.IsExpanded = $true
        $script:VisibleRowsDirty = $true
    }
}

function Collapse-SelectedNode {
    param($Row)

    if ($null -eq $Row) { return }
    if ($Row.Type -eq 'Root') {
        Set-AllCategoriesExpanded -Expanded $false
    } elseif ($Row.Type -eq 'Category') {
        $Row.Ref.IsExpanded = $false
        $script:VisibleRowsDirty = $true
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
            $script:VisibleRowsDirty = $true
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
        $icon = if ($Row.IsExpanded) { Get-UiGlyph -Name Expanded } else { Get-UiGlyph -Name Collapsed }
        $plainText = " $icon  $($Row.Name)"
        $ansiText = "$($_C.White)$plainText$($_C.Reset)"
    }
    elseif ($Row.Type -eq 'Category') {
        $icon = if ($Row.IsExpanded) { Get-UiGlyph -Name Expanded } else { Get-UiGlyph -Name Collapsed }
        $plainText = "   $icon  $($Row.Name)"
        $ansiText = "$($_C.White)$plainText$($_C.Reset)"
    }
    elseif ($Row.Type -eq 'Device') {
        $branch = if ($Row.IsLast) { Get-UiGlyph -Name BranchLast } else { Get-UiGlyph -Name Branch }
        $warning = if ($Row.IsProblem) { "[!] " } else { "" }
        $plainText = "       $branch$warning$($Row.Name) [$($Row.Class)]"
        if ($Row.IsProblem) {
            $ansiText = "$($_C.Dim)       $branch$($_C.Reset)$($_C.Warn)[!] $($_C.Reset)$($_C.White)$($Row.Name) $($_C.Dim)[$($Row.Class)]$($_C.Reset)"
        } else {
            $ansiText = "$($_C.Dim)       $branch$($_C.Reset)$($_C.White)$($Row.Name) $($_C.Dim)[$($Row.Class)]$($_C.Reset)"
        }
    }
    elseif ($Row.Type -eq 'Status') {
        $parentPrefix = if ($Row.ParentIsLast) { "            " } else { "       $(Get-UiGlyph -Name VLine)    " }
        $branchLast = Get-UiGlyph -Name BranchLast
        $plainText = "$parentPrefix$branchLast[$($Row.Name)]"
        $ansiText = "$($_C.Dim)$parentPrefix$branchLast$($_C.Reset)$($_C.Warn)[$($Row.Name)]$($_C.Reset)"
    }
    elseif ($Row.Type -eq 'Result') {
        $parentPrefix = if ($Row.ParentIsLast) { "            " } else { "       $(Get-UiGlyph -Name VLine)    " }
        $text = [string]$Row.Name
        $isSubResult = $text.StartsWith('  ')
        if ($isSubResult) {
            $text = $text.Substring(2)
            $branch = if ($Row.IsLastResult) { "    $(Get-UiGlyph -Name BranchLast)" } else { "$(Get-UiGlyph -Name VLine)   $(Get-UiGlyph -Name BranchLast)" }
        } else {
            $branch = if ($Row.IsLastResult) { Get-UiGlyph -Name BranchLast } else { Get-UiGlyph -Name Branch }
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
    Add-KeyValueLines -Lines $lines -Key 'State' -Value $stateText -Width $Width -ValueColor $stateColor
    if (-not [string]::IsNullOrWhiteSpace($ActiveSearch.AgentTracePath)) {
        Add-WrappedPathLine -Lines $lines -Key 'Log' -Path $ActiveSearch.AgentTracePath -Width $Width
    }
    $checkpointPath = Get-NotePropertyValue -Object $ActiveSearch -Name 'AgentCheckpointPath'
    if (-not [string]::IsNullOrWhiteSpace($checkpointPath)) {
        Add-WrappedPathLine -Lines $lines -Key 'Checkpoint' -Path $checkpointPath -Width $Width
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
        $targetColor = if (Test-RemoteSnapshotTargetActive) { $_C.Info } else { $_C.OK }
        Add-KeyValueLines -Lines $lines -Key 'Target' -Value (Get-TargetStatusText) -Width $Width -ValueColor $targetColor
        if (Test-RemoteSnapshotTargetActive -and -not [string]::IsNullOrWhiteSpace($script:TargetSnapshotPath)) {
            Add-WrappedPathLine -Lines $lines -Key 'Snapshot' -Path $script:TargetSnapshotPath -Width $Width
        }
        Add-KeyValueLines -Lines $lines -Key 'System Name' -Value (Get-MachineDisplayName -MachineEvidence $machine) -Width $Width
        Add-KeyValueLines -Lines $lines -Key 'OS' -Value "$($machine.OperatingSystem.Caption) $($machine.OperatingSystem.Version) Build $($machine.OperatingSystem.BuildNumber)" -Width $Width
        Add-KeyValueLines -Lines $lines -Key 'System' -Value "$($machine.ComputerSystem.Manufacturer) $($machine.ComputerSystem.Model) [$($machine.ComputerSystem.SystemType)]" -Width $Width
        Add-KeyValueLines -Lines $lines -Key 'BaseBoard' -Value "$($machine.BaseBoard.Manufacturer) $($machine.BaseBoard.Product)" -Width $Width
        Add-KeyValueLines -Lines $lines -Key 'Processor' -Value $machine.Processor.Name -Width $Width
        Add-KeyValueLines -Lines $lines -Key 'BIOS' -Value "$($machine.BIOS.Manufacturer) $($machine.BIOS.SMBIOSBIOSVersion)" -Width $Width

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
            Add-KeyValueLines -Lines $lines -Key 'Evidence' -Value $evidenceText -Width $Width -ValueColor $evidenceColor
        }
    }
    elseif ($SelectedRow.Type -eq 'Device') {
        $lines.Add((New-SectionLine -Title 'Device Properties' -Width $Width))
        Add-KeyValueLines -Lines $lines -Key 'FriendlyName' -Value $SelectedRow.Ref.FriendlyName -Width $Width
        Add-KeyValueLines -Lines $lines -Key 'InstanceId' -Value $SelectedRow.Ref.InstanceId -Width $Width

        $errCode = [int]$SelectedRow.Ref.ConfigManagerErrorCode
        $errDesc = Get-DeviceProblemDescription -ErrorCode $errCode
        $statusColor = if ($errCode -eq 0) { $_C.OK } else { $_C.Fail }
        $statusValue = if ($errCode -eq 0) { "OK ($errDesc)" } else { "Error (Code ${errCode}: $errDesc)" }
        Add-KeyValueLines -Lines $lines -Key 'Status' -Value $statusValue -Width $Width -ValueColor $statusColor

        $activeSearch = if ($script:ActiveSearches.Contains($SelectedRow.Ref.InstanceId)) { $script:ActiveSearches[$SelectedRow.Ref.InstanceId] } else { $null }
        if ($null -ne $activeSearch -and $activeSearch.EvidenceState -eq 'Searching') {
            Add-KeyValueLines -Lines $lines -Key 'Evidence' -Value 'Collecting local evidence...' -Width $Width -ValueColor $_C.Warn
        } elseif ($null -ne $activeSearch -and $activeSearch.EvidenceState -eq 'Error') {
            Add-KeyValueLines -Lines $lines -Key 'Evidence' -Value "Error: $($activeSearch.EvidenceVal)" -Width $Width -ValueColor $_C.Fail
        }

        $cachedEvidence = Read-CachedDeviceEvidence -InstanceId $SelectedRow.Ref.InstanceId
        if ($null -ne $cachedEvidence) {
            $capturedAt = Get-NotePropertyValue -Object $cachedEvidence -Name 'CapturedAt'
            $capturedText = if ($capturedAt) { $capturedAt } else { 'unknown time' }
            if ($null -eq $activeSearch -or $activeSearch.EvidenceState -ne 'Searching') {
                Add-KeyValueLines -Lines $lines -Key 'Evidence' -Value "Cached ($capturedText)" -Width $Width -ValueColor $_C.OK
            }

            $importantProperties = Get-NotePropertyValue -Object $cachedEvidence -Name 'ImportantProperties'
            $hardwareIds = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_HardwareIds'
            if ($hardwareIds) {
                $firstHardwareId = if ($hardwareIds -is [array]) { $hardwareIds[0] } else { $hardwareIds }
                Add-KeyValueLines -Lines $lines -Key 'HardwareId' -Value $firstHardwareId -Width $Width
                foreach ($breakdownLine in (Get-HardwareIdBreakdownLines -HardwareId $firstHardwareId -Width $Width -Evidence $cachedEvidence)) {
                    $lines.Add($breakdownLine)
                }
            }

            $manufacturer = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_Manufacturer'
            if ($manufacturer) {
                Add-KeyValueLines -Lines $lines -Key 'Manufacturer' -Value $manufacturer -Width $Width
            }

            $compatibleIds = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_CompatibleIds'
            if ($compatibleIds) {
                $firstCompatibleId = if ($compatibleIds -is [array]) { $compatibleIds[0] } else { $compatibleIds }
                Add-KeyValueLines -Lines $lines -Key 'CompatibleId' -Value $firstCompatibleId -Width $Width
                foreach ($breakdownLine in (Get-HardwareIdBreakdownLines -HardwareId $firstCompatibleId -Width $Width -Evidence $cachedEvidence)) {
                    $lines.Add($breakdownLine)
                }
            }

            $localIdentityRows = @(Get-LocalHardwareIdentityRows -Evidence $cachedEvidence -InstanceId $SelectedRow.Ref.InstanceId -MaxCount 3)
            if ($localIdentityRows.Count -gt 0) {
                $lines.Add((New-SectionLine -Title 'Local Hardware Identity' -Width $Width))
                foreach ($row in $localIdentityRows) {
                    $rowColorName = [string](Get-NotePropertyValue -Object $row -Name 'Color')
                    $rowColor = if ($rowColorName -and $_C.ContainsKey($rowColorName)) { $_C[$rowColorName] } else { $_C.White }
                    Add-KeyValueLines -Lines $lines -Key ([string]$row.Key) -Value ([string]$row.Value) -Width $Width -ValueColor $rowColor
                }
            }
            elseif ($script:HardwareIdResolverState -eq 'Unavailable' -and -not [string]::IsNullOrWhiteSpace($script:HardwareIdResolverError)) {
                Add-KeyValueLines -Lines $lines -Key 'Local ID' -Value 'Unavailable; run internal\Update-HardwareIdDatabases.ps1' -Width $Width -ValueColor $_C.Dim
            }

            Add-InstalledDriverDetailLines -Lines $lines -Evidence $cachedEvidence -Width $Width
            Add-SdioDriverMatchDetailLines -Lines $lines -InstanceId $SelectedRow.Ref.InstanceId -Width $Width

            $snapshotPath = Get-NotePropertyValue -Object $cachedEvidence -Name 'SnapshotPath'
            if (-not [string]::IsNullOrWhiteSpace([string]$snapshotPath)) {
                Add-WrappedPathLine -Lines $lines -Key 'Snapshot' -Path $snapshotPath -Width $Width
            } else {
                $cachePath = Get-DeviceEvidenceCachePath -InstanceId $SelectedRow.Ref.InstanceId
                Add-WrappedPathLine -Lines $lines -Key 'Cache' -Path $cachePath -Width $Width
            }
        } elseif ($null -eq $activeSearch) {
            Add-KeyValueLines -Lines $lines -Key 'Evidence' -Value 'Not scanned yet. Press E for local evidence or S for search.' -Width $Width -ValueColor $_C.Warn
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
                Add-KeyValueLines -Lines $lines -Key 'State' -Value $stateText -Width $Width -ValueColor $stateColor
            }

            $tracePath = if ($null -ne $resultSearch -and -not [string]::IsNullOrWhiteSpace($resultSearch.AgentTracePath)) {
                $resultSearch.AgentTracePath
            } else {
                Get-NotePropertyValue -Object $parentDevice -Name 'SearchTracePath'
            }
            if (-not [string]::IsNullOrWhiteSpace($tracePath)) {
                Add-WrappedPathLine -Lines $lines -Key 'Log' -Path $tracePath -Width $Width
            }
            $checkpointPath = if ($null -ne $resultSearch) {
                Get-NotePropertyValue -Object $resultSearch -Name 'AgentCheckpointPath'
            } else {
                Get-NotePropertyValue -Object $parentDevice -Name 'SearchCheckpointPath'
            }
            if (-not [string]::IsNullOrWhiteSpace($checkpointPath)) {
                Add-WrappedPathLine -Lines $lines -Key 'Checkpoint' -Path $checkpointPath -Width $Width
            }

            $detailText = if ($null -ne $resultSearch -and -not [string]::IsNullOrWhiteSpace($resultSearch.AgentVal)) {
                $resultSearch.AgentVal
            } else {
                Get-NotePropertyValue -Object $parentDevice -Name 'SearchDetail'
            }

            if (-not [string]::IsNullOrWhiteSpace($detailText)) {
                $lines.Add((New-SectionLine -Title 'Answer' -Width $Width))
                Add-MarkdownDetailTextLines -Lines $lines -Text $detailText -Width $Width -MaxLines ([Math]::Max(2, $MaxLines - $lines.Count - 5))

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
        Add-KeyValueLines -Lines $lines -Key 'Group' -Value $SelectedRow.Name -Width $Width
        if ($SelectedRow.Type -eq 'Category' -and $SelectedRow.Ref.Devices) {
            $categoryDevices = @($SelectedRow.Ref.Devices)
            Add-KeyValueLines -Lines $lines -Key 'Devices' -Value ([string]$categoryDevices.Count) -Width $Width

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
            Add-KeyValueLines -Lines $lines -Key 'Evidence' -Value $evidenceText -Width $Width -ValueColor $evidenceColor
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
    $modelSelectorFirstRender = $true
    try {
        while ($true) {
            Lock-ViewportToWindow

            try {
                $maxVisible = [Math]::Max(3, $Host.UI.RawUI.WindowSize.Height - 14)
            }
            catch {
                $maxVisible = 10
            }

            $viewTop = [Math]::Max(0, [Math]::Min($cursor - [int]($maxVisible / 2), [Math]::Max(0, $script:AvailableModels.Count - $maxVisible)))
            $viewBot = [Math]::Min($viewTop + $maxVisible - 1, $script:AvailableModels.Count - 1)

            Begin-SyncRender
            try {
                if ($modelSelectorFirstRender) {
                    Clear-TuiScreen
                    $modelSelectorFirstRender = $false
                } else {
                    [Console]::Write("$($_E)[H")
                }
            } catch {}

            Write-UiBanner -Title 'Model Selector' -Subtitle 'Space to toggle selection. Enter/Esc to confirm and return.'
            Write-UiSection -Title 'Available AI Models for Scan' -Icon ''
            Write-Host ''

            $aboveMessage = if ($viewTop -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Up) $viewTop more above$($_C.Reset)" } else { '' }
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
                    Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $(Get-UiGlyph -Name SelectionArrow) $(Remove-AnsiSequence -Text $displayText) $($_C.Reset)$($_C.EraseLn)"
                }
                else {
                    Write-Host "    $displayText$($_C.EraseLn)"
                }
            }

            $below = $script:AvailableModels.Count - 1 - $viewBot
            $belowMessage = if ($below -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Down) $below more below$($_C.Reset)" } else { '' }
            Write-Host "$belowMessage$($_C.EraseLn)"
            Write-Host "$($_C.EraseLn)"

            # Nav footer
            $segments = @(
                New-UiShortcutSegment -Text "$(Get-UiGlyph -Name Up)$(Get-UiGlyph -Name Down)" -Color $_C.White
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
                'ResizeEvent' {
                    $modelSelectorFirstRender = $true
                    continue
                }
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
    Clear-TuiScreen

    # Header
    Write-UiBanner -Title "DeviceCheck Manager" -Subtitle "R rescans the present PnP device tree. E scans evidence; root/all requires E twice. S adds web/AI."
    $statusColor = Get-SystemStatusColor -StatusText $script:SystemScanMessage
    Write-Host "  $statusColor$($script:SystemScanMessage)$($_C.Reset)$($_C.EraseLn)"
    Write-UiSection -Title "Device Connection Tree"
    Write-Host ''

    # Scrolling indicators above
    $aboveCount = $viewTop
    $aboveMessage = if ($aboveCount -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Up) $aboveCount more above$($_C.Reset)" } else { '' }
    Write-Host "$aboveMessage$($_C.EraseLn)"

    # Render visible rows
    for ($index = $viewTop; $index -le $viewBot; $index++) {
        $row = $script:visibleRows[$index]
        $isSelected = ($index -eq $selectedIndex)

        if ($row.Type -eq 'Root') {
            $icon = if ($row.IsExpanded) { Get-UiGlyph -Name Expanded } else { Get-UiGlyph -Name Collapsed }
            $displayText = " $icon  $($row.Name)"

            if ($isSelected) {
                Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $displayText $($_C.Reset)$($_C.EraseLn)"
            } else {
                Write-Host "  $($_C.White)$displayText$($_C.Reset)$($_C.EraseLn)"
            }
        }
        elseif ($row.Type -eq 'Category') {
            $icon = if ($row.IsExpanded) { Get-UiGlyph -Name Expanded } else { Get-UiGlyph -Name Collapsed }
            $displayText = "   $icon  $($row.Name)"

            if ($isSelected) {
                Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $displayText $($_C.Reset)$($_C.EraseLn)"
            } else {
                Write-Host "  $($_C.White)$displayText$($_C.Reset)$($_C.EraseLn)"
            }
        }
        elseif ($row.Type -eq 'Device') {
            $branch = if ($row.IsLast) { Get-UiGlyph -Name BranchLast } else { Get-UiGlyph -Name Branch }
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
            $parentPrefix = if ($row.ParentIsLast) { "            " } else { "       $(Get-UiGlyph -Name VLine)    " }
            Write-Host "$($_C.Dim)$parentPrefix$(Get-UiGlyph -Name BranchLast)$($_C.Reset)$($_C.Warn)[$($row.Name)]$($_C.Reset)$($_C.EraseLn)"
        }
        elseif ($row.Type -eq 'Result') {
            $parentPrefix = if ($row.ParentIsLast) { "            " } else { "       $(Get-UiGlyph -Name VLine)    " }

            $text = $row.Name
            $isSubResult = $text.StartsWith("  ")

            if ($isSubResult) {
                $text = $text.Substring(2)
                $branch = if ($row.IsLastResult) { "    $(Get-UiGlyph -Name BranchLast)" } else { "$(Get-UiGlyph -Name VLine)   $(Get-UiGlyph -Name BranchLast)" }
            } else {
                $branch = if ($row.IsLastResult) { Get-UiGlyph -Name BranchLast } else { Get-UiGlyph -Name Branch }
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
    $belowMessage = if ($belowCount -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Down) $belowCount more below$($_C.Reset)" } else { '' }
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
            $capturedAt = Get-NotePropertyValue -Object $cachedEvidence -Name 'CapturedAt'
            $capturedText = if ($capturedAt) { $capturedAt } else { 'unknown time' }
            Write-Host "  $($_C.Dim)Evidence     :$($_C.Reset) $($_C.OK)Cached ($capturedText)$($_C.Reset)$($_C.EraseLn)"

            $importantProperties = Get-NotePropertyValue -Object $cachedEvidence -Name 'ImportantProperties'
            $hardwareIds = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_HardwareIds'
            if ($hardwareIds) {
                $firstHardwareId = if ($hardwareIds -is [array]) { $hardwareIds[0] } else { $hardwareIds }
                Write-Host "  $($_C.Dim)HardwareId   :$($_C.Reset) $($_C.White)$(Format-UiValue -Text $firstHardwareId -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
                foreach ($breakdownLine in (Get-HardwareIdBreakdownLines -HardwareId $firstHardwareId -Width (Get-UiWidth) -Evidence $cachedEvidence)) {
                    Write-Host "$breakdownLine$($_C.EraseLn)"
                }
            }

            $manufacturer = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_Manufacturer'
            if ($manufacturer) {
                Write-Host "  $($_C.Dim)Manufacturer :$($_C.Reset) $($_C.White)$(Format-UiValue -Text $manufacturer -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
            }

            $compatibleIds = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_CompatibleIds'
            if ($compatibleIds) {
                $firstCompatibleId = if ($compatibleIds -is [array]) { $compatibleIds[0] } else { $compatibleIds }
                Write-Host "  $($_C.Dim)CompatibleId :$($_C.Reset) $($_C.White)$(Format-UiValue -Text $firstCompatibleId -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
                foreach ($breakdownLine in (Get-HardwareIdBreakdownLines -HardwareId $firstCompatibleId -Width (Get-UiWidth) -Evidence $cachedEvidence)) {
                    Write-Host $breakdownLine
                }
            }

            $localIdentityRows = @(Get-LocalHardwareIdentityRows -Evidence $cachedEvidence -InstanceId $selectedRow.Ref.InstanceId -MaxCount 3)
            if ($localIdentityRows.Count -gt 0) {
                Write-Host "  $($_C.H1)Local Hardware Identity$($_C.Reset)$($_C.EraseLn)"
                foreach ($row in $localIdentityRows) {
                    $rowColorName = [string](Get-NotePropertyValue -Object $row -Name 'Color')
                    $rowColor = if ($rowColorName -and $_C.ContainsKey($rowColorName)) { $_C[$rowColorName] } else { $_C.White }
                    $keyText = Format-PlainToWidth -Text ([string]$row.Key) -Width 13
                    Write-Host "  $($_C.Dim)$keyText :$($_C.Reset) $rowColor$(Format-UiValue -Text ([string]$row.Value) -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
                }
            }

            $installedDriverLines = [System.Collections.Generic.List[string]]::new()
            Add-InstalledDriverDetailLines -Lines $installedDriverLines -Evidence $cachedEvidence -Width (Get-UiWidth)
            foreach ($installedDriverLine in $installedDriverLines) {
                Write-Host "$installedDriverLine$($_C.EraseLn)"
            }

            $sdioDriverLines = [System.Collections.Generic.List[string]]::new()
            Add-SdioDriverMatchDetailLines -Lines $sdioDriverLines -InstanceId $selectedRow.Ref.InstanceId -Width (Get-UiWidth)
            foreach ($sdioDriverLine in $sdioDriverLines) {
                Write-Host "$sdioDriverLine$($_C.EraseLn)"
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
        New-UiShortcutSegment -Text "$(Get-UiGlyph -Name Up)$(Get-UiGlyph -Name Down)" -Color $_C.White
        New-UiShortcutSegment -Text ' navigate   ' -Color $_C.Dim
        New-UiShortcutSegment -Text "$(Get-UiGlyph -Name Left)$(Get-UiGlyph -Name Right)" -Color $_C.White
        New-UiShortcutSegment -Text ' pane   ' -Color $_C.Dim
        New-UiShortcutSegment -Text '+ / -' -Color $_C.OK
        New-UiShortcutSegment -Text ' = expand/collapse   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'Ctrl+L' -Color $_C.Gold
        New-UiShortcutSegment -Text ' = connect   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'M' -Color $_C.White
        New-UiShortcutSegment -Text ' = models   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'A' -Color $_C.Info
        New-UiShortcutSegment -Text ' = agent   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'S' -Color $_C.Gold
        New-UiShortcutSegment -Text ' = web/AI   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'R' -Color $_C.Info
        New-UiShortcutSegment -Text ' = refresh   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'E' -Color $_C.OK
        New-UiShortcutSegment -Text ' = evidence   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
        New-UiShortcutSegment -Text ' = exit' -Color $_C.Dim
    )
    Write-UiShortcutSegments -Segments $segments
    Write-Host "$($_E)[J" -NoNewline

    End-SyncRender
}

function Test-TuiPerfEnabled {
    $value = [Environment]::GetEnvironmentVariable('DEVICECHECK_TUI_PERF')
    return (-not [string]::IsNullOrWhiteSpace($value) -and $value -notin @('0', 'false', 'False', 'FALSE', 'off', 'Off', 'OFF'))
}

function Get-TuiPerfStatusText {
    if (-not (Test-TuiPerfEnabled)) { return '' }
    if ($null -eq $script:TuiPerfLast) { return 'perf warming' }

    return "render $($script:TuiPerfLast.RenderMs)ms / chars $($script:TuiPerfLast.FrameChars) / writes $($script:TuiPerfLast.ConsoleWrites) / rows $($script:TuiPerfLast.VisibleRows) / details $($script:TuiPerfLast.DetailLines)"
}

function Add-FrameLine {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Frame,
        [AllowEmptyString()][string]$Text = ''
    )

    $null = $Frame.Append($Text)
    $null = $Frame.Append([Environment]::NewLine)
}

function Add-FrameBanner {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Frame,
        [string]$Title,
        [string]$Subtitle,
        [int]$Width
    )

    $border = (Get-UiGlyph -Name BoxH) * [Math]::Max(0, $Width - 2)
    $maxTextWidth = [Math]::Max(1, $Width - 3)

    $displayTitle = if ($null -eq $Title) { '' } else { $Title }
    if ($displayTitle.Length -gt $maxTextWidth) {
        $ellipsis = Get-UiGlyph -Name Ellipsis
        $displayTitle = $displayTitle.Substring(0, [Math]::Max(1, $maxTextWidth - $ellipsis.Length)) + $ellipsis
    }
    $titlePad = [Math]::Max(0, $maxTextWidth - $displayTitle.Length)

    $displaySubtitle = if ($null -eq $Subtitle) { '' } else { $Subtitle }
    $subtitlePad = 0
    if (-not [string]::IsNullOrWhiteSpace($displaySubtitle)) {
        if ($displaySubtitle.Length -gt $maxTextWidth) {
            $ellipsis = Get-UiGlyph -Name Ellipsis
            $displaySubtitle = $displaySubtitle.Substring(0, [Math]::Max(1, $maxTextWidth - $ellipsis.Length)) + $ellipsis
        }
        $subtitlePad = [Math]::Max(0, $maxTextWidth - $displaySubtitle.Length)
    }

    Add-FrameLine -Frame $Frame
    Add-FrameLine -Frame $Frame -Text "$($_C.H1)$(Get-UiGlyph -Name BoxTopLeft)$border$(Get-UiGlyph -Name BoxTopRight)$($_C.Reset)$($_C.EraseLn)"
    Add-FrameLine -Frame $Frame -Text "$($_C.H1)$(Get-UiGlyph -Name BoxV)$($_C.Bold)$($_C.White) $displayTitle$($_C.Reset)$(' ' * $titlePad)$($_C.H1)$(Get-UiGlyph -Name BoxV)$($_C.Reset)$($_C.EraseLn)"
    if (-not [string]::IsNullOrWhiteSpace($displaySubtitle)) {
        Add-FrameLine -Frame $Frame -Text "$($_C.H1)$(Get-UiGlyph -Name BoxV)$($_C.Dim) $displaySubtitle$($_C.Reset)$(' ' * $subtitlePad)$($_C.H1)$(Get-UiGlyph -Name BoxV)$($_C.Reset)$($_C.EraseLn)"
    }
    Add-FrameLine -Frame $Frame -Text "$($_C.H1)$(Get-UiGlyph -Name BoxBottomLeft)$border$(Get-UiGlyph -Name BoxBottomRight)$($_C.Reset)$($_C.EraseLn)"
    Add-FrameLine -Frame $Frame
}

function Add-FrameSection {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Frame,
        [string]$Title,
        [int]$Width,
        [string]$Icon = (Get-UiGlyph -Name Diamond)
    )

    $prefix = if ($Icon) { " $Icon $Title " } else { " $Title " }
    $remaining = [Math]::Max(0, $Width - $prefix.Length - 1)
    $line = (Get-UiGlyph -Name HLine) * $remaining

    Add-FrameLine -Frame $Frame
    Add-FrameLine -Frame $Frame -Text "$($_C.H1)$prefix$($_C.Dim)$line$($_C.Reset)$($_C.EraseLn)"
}

function Add-FrameShortcutSegments {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Frame,
        [Parameter(Mandatory)][object[]]$Segments,
        [int]$Width = (Get-UiWidth)
    )

    $line = [System.Text.StringBuilder]::new()
    $null = $line.Append('  ')
    $remaining = [Math]::Max(1, $Width - 3)
    foreach ($segment in $Segments) {
        if ($remaining -le 0) { break }
        $text = [string]$segment.Text
        if ($text.Length -gt $remaining) {
            $text = if ($remaining -eq 1) { $text.Substring(0, 1) } else { $text.Substring(0, $remaining - 1) + '~' }
        }
        $null = $line.Append("$($segment.Color)$text$($_C.Reset)")
        $remaining -= $text.Length
    }
    Add-FrameLine -Frame $Frame -Text "$($line.ToString())$($_C.EraseLn)"
}

function Render-Frame {
    param([switch]$ForceClear)

    $renderStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $detailLinesBuilt = 0
    Lock-ViewportToWindow
    $shouldClear = $ForceClear -or $script:RequestForceClear
    $script:RequestForceClear = $false

    $uiWidth = Get-UiWidth
    try { $windowHeight = $Host.UI.RawUI.WindowSize.Height } catch { $windowHeight = 32 }
    $frameHeightBudget = [Math]::Max(8, $windowHeight - 1)

    $useDualPane = ($uiWidth -ge 136)
    $batchStatus = Get-EvidenceBatchStatusText
    if ($frameHeightBudget -lt 16) {
        $batchStatus = ''
    }
    $batchRows = if ([string]::IsNullOrWhiteSpace($batchStatus)) { 0 } else { 1 }
    $footerRows = 3
    $narrowDetailMaxLines = 0

    if ($useDualPane) {
        $dividerWidth = 3
        $availablePaneWidth = [Math]::Max(80, $uiWidth - $dividerWidth)
        $leftWidth = [int][Math]::Floor($availablePaneWidth / 2)
        $rightWidth = $availablePaneWidth - $leftWidth
        $maxVisible = [Math]::Max(0, $frameHeightBudget - 10 - $batchRows - $footerRows)
    } else {
        $leftWidth = $uiWidth
        $rightWidth = $uiWidth
        if ($frameHeightBudget -ge 30) {
            $narrowDetailMaxLines = [Math]::Min(11, $frameHeightBudget - 22)
        } elseif ($frameHeightBudget -ge 24) {
            $narrowDetailMaxLines = [Math]::Min(5, $frameHeightBudget - 20)
        }
        $narrowDetailMaxLines = [Math]::Max(0, $narrowDetailMaxLines)

        # Narrow/short terminals must not write past the viewport or cursor-home redraws corrupt the header.
        $fixedNarrowRows = 12 + $footerRows + $batchRows
        $maxVisible = [Math]::Max(0, $frameHeightBudget - $fixedNarrowRows - $narrowDetailMaxLines)
    }

    $viewTop = [Math]::Max(0, [Math]::Min($selectedIndex - [int]($maxVisible / 2), [Math]::Max(0, $script:visibleRows.Count - $maxVisible)))
    $viewBot = [Math]::Min($viewTop + $maxVisible - 1, $script:visibleRows.Count - 1)
    $selectedRow = if ($script:visibleRows.Count -gt 0) { $script:visibleRows[$selectedIndex] } else { $null }

    $deviceCount = 0
    if ($null -ne $script:categories) {
        foreach ($category in $script:categories) {
            $deviceCount += @($category.Devices).Count
        }
    }
    $categoryCount = if ($null -ne $script:categories) { @($script:categories).Count } else { 0 }
    $headerSummary = Get-MachineSummary -MachineEvidence $script:MachineEvidence -DeviceCount $deviceCount -CategoryCount $categoryCount
    $subtitleText = $headerSummary

    $frame = [System.Text.StringBuilder]::new()
    $null = $frame.Append("$($_E)[?2026h")
    if ($shouldClear) {
        $null = $frame.Append("$($_E)[H$($_E)[2J$($_E)[3J")
    } else {
        $null = $frame.Append("$($_E)[H")
    }

    Add-FrameBanner -Frame $frame -Title 'DeviceCheck Manager' -Subtitle $subtitleText -Width $uiWidth
    $statusWidth = [Math]::Max(10, $uiWidth - 2)
    $compactStatus = Get-CompactSystemStatus -StatusText $script:SystemScanMessage
    $perfStatus = Get-TuiPerfStatusText
    if (-not [string]::IsNullOrWhiteSpace($perfStatus)) {
        $compactStatus = "$compactStatus | $perfStatus"
    }
    $targetStatus = Get-TargetStatusText
    if (-not [string]::IsNullOrWhiteSpace($targetStatus)) {
        $compactStatus = "$targetStatus | $compactStatus"
    }
    $statusColor = Get-SystemStatusColor -StatusText $script:SystemScanMessage
    Add-FrameLine -Frame $frame -Text "  $statusColor$(Format-UiValue -Text $compactStatus -MaxLength $statusWidth)$($_C.Reset)$($_C.EraseLn)"
    if (-not [string]::IsNullOrWhiteSpace($batchStatus)) {
        Add-FrameLine -Frame $frame -Text "  $($_C.Warn)$(Format-UiValue -Text $batchStatus -MaxLength $statusWidth)$($_C.Reset)$($_C.EraseLn)"
    }

    if ($useDualPane) {
        $leftTitleColor = if ($script:ActivePane -eq 'Tree') { $_C.H1 } else { $_C.Dim }
        $rightTitleColor = if ($script:ActivePane -eq 'Detail') { $_C.H1 } else { $_C.Dim }
        $leftIndicator = if ($script:ActivePane -eq 'Tree') { "$(Get-UiGlyph -Name Diamond) " } else { '  ' }
        $rightIndicator = if ($script:ActivePane -eq 'Detail') { "$(Get-UiGlyph -Name Diamond) " } else { '  ' }
        $leftTitleText = "${leftIndicator}Device Connection Tree"
        $rightTitleText = "${rightIndicator}Selected Details"
        $leftPrefix = " $leftTitleText "
        $leftLine = (Get-UiGlyph -Name HLine) * [Math]::Max(0, $leftWidth - $leftPrefix.Length)
        $leftTitle = "$leftTitleColor$leftPrefix$($_C.Dim)$leftLine$($_C.Reset)"
        $rightPrefix = " $rightTitleText "
        $rightLine = (Get-UiGlyph -Name HLine) * [Math]::Max(0, $rightWidth - $rightPrefix.Length)
        $rightTitle = "$rightTitleColor$rightPrefix$($_C.Dim)$rightLine$($_C.Reset)"
        Add-FrameLine -Frame $frame -Text "$(Format-AnsiToWidth -Text $leftTitle -Width $leftWidth)$($_C.Dim) $(Get-UiGlyph -Name VLine) $($_C.Reset)$(Format-AnsiToWidth -Text $rightTitle -Width $rightWidth)$($_C.EraseLn)"

        $treeLines = [System.Collections.Generic.List[string]]::new()
        $aboveCount = $viewTop
        $aboveMessage = if ($aboveCount -gt 0) { "$(Get-UiGlyph -Name Up) $aboveCount more above" } else { '' }
        $treeLines.Add("$($_C.Dim)$(Format-PlainToWidth -Text $aboveMessage -Width $leftWidth)$($_C.Reset)")

        for ($index = $viewTop; $index -le $viewBot; $index++) {
            $row = $script:visibleRows[$index]
            $treeLines.Add((Get-TreeDisplayLine -Row $row -IsSelected:($index -eq $selectedIndex) -Width $leftWidth))
        }

        $belowCount = $script:visibleRows.Count - 1 - $viewBot
        $belowMessage = if ($belowCount -gt 0) { "$(Get-UiGlyph -Name Down) $belowCount more below" } else { '' }
        $treeLines.Add("$($_C.Dim)$(Format-PlainToWidth -Text $belowMessage -Width $leftWidth)$($_C.Reset)")

        # Generate all detail lines (generous MaxLines for scrolling)
        $detailMaxLines = [Math]::Max($treeLines.Count, 200)
        $allDetailLines = if ($null -ne $selectedRow) {
            @(Get-DetailDisplayLines -SelectedRow $selectedRow -Width $rightWidth -MaxLines $detailMaxLines)
        } else {
            @((New-SectionLine -Title 'Selected Details' -Width $rightWidth))
        }
        $detailLinesBuilt = $allDetailLines.Count
        # Trim trailing empty lines to get true content count
        $detailContentCount = $allDetailLines.Count
        while ($detailContentCount -gt 0 -and [string]::IsNullOrWhiteSpace($allDetailLines[$detailContentCount - 1])) {
            $detailContentCount--
        }
        $script:LastDetailLineCount = $detailContentCount

        # Clamp cursor within content bounds
        if ($script:DetailCursorIndex -ge $detailContentCount) {
            $script:DetailCursorIndex = [Math]::Max(0, $detailContentCount - 1)
        }

        # Auto-scroll viewport to keep cursor visible
        $detailViewSize = $treeLines.Count
        $maxDetailScroll = [Math]::Max(0, $detailContentCount - $detailViewSize)
        # Ensure cursor is within visible slice
        if ($script:DetailCursorIndex -lt $script:DetailScrollOffset) {
            $script:DetailScrollOffset = $script:DetailCursorIndex
        } elseif ($script:DetailCursorIndex -ge ($script:DetailScrollOffset + $detailViewSize)) {
            $script:DetailScrollOffset = $script:DetailCursorIndex - $detailViewSize + 1
        }
        if ($script:DetailScrollOffset -gt $maxDetailScroll) {
            $script:DetailScrollOffset = $maxDetailScroll
        }
        if ($script:DetailScrollOffset -lt 0) {
            $script:DetailScrollOffset = 0
        }

        # Slice visible detail lines
        $detailSlice = @()
        if ($allDetailLines.Count -gt 0) {
            $sliceEnd = [Math]::Min($script:DetailScrollOffset + $detailViewSize - 1, $allDetailLines.Count - 1)
            $detailSlice = @($allDetailLines[$script:DetailScrollOffset..$sliceEnd])
        }

        # Apply cursor highlight when detail pane is focused
        if ($script:ActivePane -eq 'Detail' -and $detailSlice.Count -gt 0) {
            $cursorInSlice = $script:DetailCursorIndex - $script:DetailScrollOffset
            if ($cursorInSlice -ge 0 -and $cursorInSlice -lt $detailSlice.Count) {
                $detailSlice[$cursorInSlice] = New-SelectedLine -Text $detailSlice[$cursorInSlice] -Width $rightWidth
            }
        }

        # Add detail scroll indicators
        if ($script:DetailScrollOffset -gt 0 -and $detailSlice.Count -gt 0) {
            # Only show if the cursor is not on the first visible line
            $cursorInSlice = $script:DetailCursorIndex - $script:DetailScrollOffset
            if ($cursorInSlice -ne 0) {
                $detailSlice[0] = "$($_C.Dim)$(Format-PlainToWidth -Text "$(Get-UiGlyph -Name Up) $($script:DetailScrollOffset) more above" -Width $rightWidth)$($_C.Reset)"
            }
        }
        if ($script:DetailScrollOffset -lt $maxDetailScroll -and $detailSlice.Count -gt 1) {
            $cursorInSlice = $script:DetailCursorIndex - $script:DetailScrollOffset
            if ($cursorInSlice -ne ($detailSlice.Count - 1)) {
                $belowDetailCount = $detailContentCount - $script:DetailScrollOffset - $detailViewSize
                $detailSlice[$detailSlice.Count - 1] = "$($_C.Dim)$(Format-PlainToWidth -Text "$(Get-UiGlyph -Name Down) $belowDetailCount more below" -Width $rightWidth)$($_C.Reset)"
            }
        }

        $lineCount = [Math]::Max($treeLines.Count, $detailSlice.Count)
        for ($i = 0; $i -lt $lineCount; $i++) {
            $leftLine = if ($i -lt $treeLines.Count) { $treeLines[$i] } else { '' }
            $rightLine = if ($i -lt $detailSlice.Count) { $detailSlice[$i] } else { '' }
            Add-FrameLine -Frame $frame -Text "$(Format-AnsiToWidth -Text $leftLine -Width $leftWidth)$($_C.Dim) $(Get-UiGlyph -Name VLine) $($_C.Reset)$(Format-AnsiToWidth -Text $rightLine -Width $rightWidth)$($_C.EraseLn)"
        }
    } else {
        Add-FrameSection -Frame $frame -Title 'Device Connection Tree' -Width $uiWidth
        Add-FrameLine -Frame $frame

        $aboveCount = $viewTop
        $aboveMessage = if ($aboveCount -gt 0) { "  $(Get-UiGlyph -Name Up) $aboveCount more above" } else { '' }
        Add-FrameLine -Frame $frame -Text "$($_C.Dim)$(Format-PlainToWidth -Text $aboveMessage -Width $leftWidth)$($_C.Reset)$($_C.EraseLn)"

        for ($index = $viewTop; $index -le $viewBot; $index++) {
            $row = $script:visibleRows[$index]
            Add-FrameLine -Frame $frame -Text "$(Get-TreeDisplayLine -Row $row -IsSelected:($index -eq $selectedIndex) -Width $leftWidth)$($_C.EraseLn)"
        }

        $belowCount = $script:visibleRows.Count - 1 - $viewBot
        $belowMessage = if ($belowCount -gt 0) { "  $(Get-UiGlyph -Name Down) $belowCount more below" } else { '' }
        Add-FrameLine -Frame $frame -Text "$($_C.Dim)$(Format-PlainToWidth -Text $belowMessage -Width $leftWidth)$($_C.Reset)$($_C.EraseLn)"

        if ($narrowDetailMaxLines -gt 0 -and $null -ne $selectedRow) {
            $stackedDetailLines = @(Get-DetailDisplayLines -SelectedRow $selectedRow -Width $rightWidth -MaxLines $narrowDetailMaxLines)
            $detailLinesBuilt = $stackedDetailLines.Count
            foreach ($line in $stackedDetailLines) {
                Add-FrameLine -Frame $frame -Text "$(Format-AnsiToWidth -Text $line -Width $rightWidth)$($_C.EraseLn)"
            }
        }
    }

    $footerRow1 = @(
        New-UiShortcutSegment -Text "$(Get-UiGlyph -Name Up)$(Get-UiGlyph -Name Down)" -Color $_C.White
        New-UiShortcutSegment -Text ' navigate   ' -Color $_C.Dim
        New-UiShortcutSegment -Text "$(Get-UiGlyph -Name Left)$(Get-UiGlyph -Name Right)" -Color $_C.White
        New-UiShortcutSegment -Text ' pane   ' -Color $_C.Dim
        New-UiShortcutSegment -Text '+ / -' -Color $_C.OK
        New-UiShortcutSegment -Text ' = expand/collapse   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'Ctrl+L' -Color $_C.Gold
        New-UiShortcutSegment -Text ' = connect' -Color $_C.Dim
    )
    $footerRow2 = @(
        New-UiShortcutSegment -Text 'M' -Color $_C.White
        New-UiShortcutSegment -Text ' = models   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'A' -Color $_C.Info
        New-UiShortcutSegment -Text ' = agent   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'S' -Color $_C.Gold
        New-UiShortcutSegment -Text ' = web/AI' -Color $_C.Dim
    )
    $footerRow3 = @(
        New-UiShortcutSegment -Text 'R' -Color $_C.Info
        New-UiShortcutSegment -Text ' = refresh   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'E' -Color $_C.OK
        New-UiShortcutSegment -Text ' = evidence   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
        New-UiShortcutSegment -Text ' = exit' -Color $_C.Dim
    )
    Add-FrameShortcutSegments -Frame $frame -Segments $footerRow1 -Width $uiWidth
    Add-FrameShortcutSegments -Frame $frame -Segments $footerRow2 -Width $uiWidth
    Add-FrameShortcutSegments -Frame $frame -Segments $footerRow3 -Width $uiWidth
    $null = $frame.Append("$($_E)[J")
    $null = $frame.Append("$($_E)[?2026l")

    $frameText = $frame.ToString()
    [Console]::Write($frameText)
    $renderStopwatch.Stop()

    if (Test-TuiPerfEnabled) {
        $script:TuiPerfLast = [pscustomobject]@{
            RenderMs      = [Math]::Round($renderStopwatch.Elapsed.TotalMilliseconds, 1)
            FrameChars    = $frameText.Length
            ConsoleWrites = 1
            VisibleRows   = $script:visibleRows.Count
            DetailLines   = $detailLinesBuilt
        }
    }
}

function Invoke-SystemScanWithFeedback {
    param([switch]$Quiet)

    $script:SystemScanMessage = "System scan running... | $(Get-Date -Format 'HH:mm:ss')"
    if ($script:visibleRows -and $script:visibleRows.Count -gt 0) {
        Render-Frame
    }

    Invoke-SystemScan -Quiet:$Quiet
    $script:selectedIndex = 0
    $script:DetailScrollOffset = 0
    $script:DetailCursorIndex = 0
    $script:ActivePane = 'Tree'
    $script:VisibleRowsDirty = $true
    $script:visibleRows = Update-VisibleRows
    $script:VisibleRowsDirty = $false
    $script:RequestForceClear = $true
}

function Get-SelectedTreeRow {
    param(
        [array]$Rows,
        [int]$Index
    )

    if ($null -eq $Rows -or $Rows.Count -eq 0) { return $null }
    if ($Index -lt 0 -or $Index -ge $Rows.Count) { return $null }
    return $Rows[$Index]
}

function Reset-AllEvidenceScanConfirmation {
    $script:PendingAllEvidenceScanConfirmUntil = [datetime]::MinValue
}

function Invoke-SelectedEvidenceScan {
    param(
        [array]$Rows,
        [int]$Index
    )

    if (Test-RemoteSnapshotTargetActive) {
        $script:SystemScanMessage = "Remote snapshot already includes collected evidence. Press R to refresh $($script:TargetComputerName). | $(Get-Date -Format 'HH:mm:ss')"
        return
    }

    $currentRow = Get-SelectedTreeRow -Rows $Rows -Index $Index
    if ($null -eq $currentRow) { return }

    if ($currentRow.Type -eq 'Root') {
        if ($script:ActivePane -eq 'Detail') {
            Reset-AllEvidenceScanConfirmation
            $script:SystemScanMessage = "All-device evidence scan is available only from the left tree root. Press Left, then E twice to confirm. | $(Get-Date -Format 'HH:mm:ss')"
            return
        }

        $now = Get-Date
        if ($script:PendingAllEvidenceScanConfirmUntil -gt $now) {
            Reset-AllEvidenceScanConfirmation
            Start-AllEvidenceScan
            return
        }

        $script:PendingAllEvidenceScanConfirmUntil = $now.AddSeconds(4)
        $script:SystemScanMessage = "All-device evidence scan needs confirmation: press E again within 4s, or select a category/device. | $(Get-Date -Format 'HH:mm:ss')"
        return
    }

    Reset-AllEvidenceScanConfirmation

    if ($currentRow.Type -eq 'Category') {
        Start-CategoryEvidenceScan -Category $currentRow.Ref
    } elseif ($currentRow.Type -eq 'Device') {
        Start-DeviceLookup -Dev $currentRow.Ref -EvidenceOnly -ForceEvidenceRefresh
    } elseif ($currentRow.Type -in @('Result', 'Status') -and $null -ne $currentRow.ParentDevice) {
        Start-DeviceLookup -Dev $currentRow.ParentDevice -EvidenceOnly -ForceEvidenceRefresh
    }
}

function Invoke-SelectedWebScan {
    param(
        [array]$Rows,
        [int]$Index,
        [switch]$UseAgent
    )

    Reset-AllEvidenceScanConfirmation

    $currentRow = Get-SelectedTreeRow -Rows $Rows -Index $Index
    if ($null -eq $currentRow) {
        $lookupLabel = if ($UseAgent) { 'Agent' } else { 'Web/AI lookup' }
        Set-SystemStatusMessage -Message "$lookupLabel needs a selected device row."
        return
    }

    if ($currentRow.Type -eq 'Device') {
        Start-DeviceLookup -Dev $currentRow.Ref -UseAgent:$UseAgent -ForceEvidenceRefresh
    } elseif ($currentRow.Type -in @('Result', 'Status') -and $null -ne $currentRow.ParentDevice) {
        Start-DeviceLookup -Dev $currentRow.ParentDevice -UseAgent:$UseAgent -ForceEvidenceRefresh
    } else {
        $lookupLabel = if ($UseAgent) { 'Agent' } else { 'Web/AI lookup' }
        Set-SystemStatusMessage -Message "$lookupLabel needs a device row. Select a device or an existing lookup result."
    }
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
        $deviceName = Get-DeviceLookupDisplayName -Device $Dev
        Stop-DeviceLookup -InstanceId $instanceId
        Set-SystemStatusMessage -Message "Lookup cancelled: $deviceName"
        $script:VisibleRowsDirty = $true
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

    # Resolve Agent model if using agent
    $agentModel = 'gemini-3.1-flash-lite'
    if ($UseAgent) {
        $selectedGemini = $script:AvailableModels | Where-Object { $_.Selected -and $_.Provider -eq 'Gemini' } | Select-Object -First 1
        if ($null -ne $selectedGemini) {
            $agentModel = $selectedGemini.ApiId
        }
    }

    if ($UseAgent -and [string]::IsNullOrWhiteSpace($apiKey)) {
        $deviceName = Get-DeviceLookupDisplayName -Device $Dev
        $message = "Agent blocked: Google/Gemini API key missing. Set GOOGLE_API_KEY or GEMINI_API_KEY, then restart PowerShell."
        Set-SystemStatusMessage -Message "$message | $deviceName"
        $Dev.SearchStatus = 'Error'
        $Dev.SearchKind = 'Agent'
        $Dev.SearchDetail = $message
        $Dev.SearchTracePath = $null
        $Dev.SearchCheckpointPath = $null
        $Dev.SearchResults = @("[Agent: $agentModel] (Blocked: missing API key)")
        $script:VisibleRowsDirty = $true
        return
    }

    $preloadedEvidence = $null
    if (Test-RemoteSnapshotTargetActive) {
        try {
            $preloadedEvidence = New-SnapshotDeviceEvidence -Snapshot $script:TargetSnapshot -Device $Dev
        } catch {
            $deviceName = Get-DeviceLookupDisplayName -Device $Dev
            Set-SystemStatusMessage -Message "Remote snapshot evidence unavailable for ${deviceName}: $($_.Exception.Message)"
            $Dev.SearchStatus = 'Error'
            $Dev.SearchKind = if ($UseAgent) { 'Agent' } else { $null }
            $Dev.SearchDetail = $_.Exception.Message
            $Dev.SearchTracePath = $null
            $Dev.SearchCheckpointPath = $null
            $Dev.SearchResults = @("[Remote Snapshot] (Evidence unavailable)")
            $script:VisibleRowsDirty = $true
            return
        }
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
        $newResults.Add("[Agent: $agentModel] (Waiting for local evidence...)")
    } else {
        $newResults.AddRange($activeResults)
        if ($webState -eq 'Searching') { $newResults.Add("[Web Snippet] (Searching...)") }
    }
    $Dev.SearchResults = $newResults
    if ([string]::IsNullOrWhiteSpace($EvidenceBatchId)) {
        $deviceName = Get-DeviceLookupDisplayName -Device $Dev
        $sourceText = if ($null -ne $preloadedEvidence) { 'remote snapshot' } else { 'local evidence' }
        if ($UseAgent) {
            Set-SystemStatusMessage -Message "Agent queued: $deviceName | $agentModel | $sourceText"
        } elseif ($EvidenceOnly) {
            Set-SystemStatusMessage -Message "Evidence refresh queued: $deviceName | $sourceText"
        } else {
            Set-SystemStatusMessage -Message "Web/AI lookup queued: $deviceName | $sourceText"
        }
    }
    $script:VisibleRowsDirty = $true

    # Start background runspace for Web and Local Search
    $psWeb = [PowerShell]::Create()
    $null = $psWeb.AddScript({
        param($DeviceBasics, $MachineEvidence, [string]$MachineCacheRoot, [bool]$EvidenceOnly, [bool]$ForceEvidenceRefresh, $PreloadedEvidence)
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
                    'DEVPKEY_Device_DriverInfSection',
                    'DEVPKEY_Device_DriverProvider',
                    'DEVPKEY_Device_DriverVersion',
                    'DEVPKEY_Device_DriverDate',
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

            if ($null -ne $PreloadedEvidence) {
                $snapshotPath = $PreloadedEvidence.SnapshotPath
                $resultText = if ([string]::IsNullOrWhiteSpace([string]$snapshotPath)) {
                    "[Evidence Snapshot] Loaded remote snapshot evidence."
                } else {
                    "[Evidence Snapshot] Loaded remote snapshot evidence: $snapshotPath"
                }
                Write-Output ([PSCustomObject]@{
                    Source   = 'Evidence'
                    Status   = 'Done'
                    Result   = $resultText
                    Path     = $snapshotPath
                    Evidence = $PreloadedEvidence
                })
            } else {
                Write-Output (Get-DeviceEvidence -DeviceBasics $DeviceBasics -MachineEvidence $MachineEvidence -MachineCacheRoot $MachineCacheRoot -ForceEvidenceRefresh $ForceEvidenceRefresh)
            }

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
    $null = $psWeb.AddArgument($preloadedEvidence)

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
        EvidenceSource     = if ($null -ne $preloadedEvidence) { 'remote snapshot' } else { 'local evidence' }
        UseAgent           = [bool]$UseAgent
        AgentModelName     = $agentModel
        ApiKey             = $apiKey
        AgentLogs          = [System.Collections.Generic.List[string]]::new()
        AgentState         = if ($UseAgent) { 'Waiting' } else { 'None' }
        AgentCurrentActivity = $null
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
        $mName = $search.AgentModelName
        if ([string]::IsNullOrWhiteSpace($mName)) { $mName = 'gemini-3.1-flash-lite' }
        if ($search.AgentState -in @('Searching', 'Waiting')) {
            $newResults.Add("[Agent: $mName] (Cancelled)")
            $search.Device.SearchDetail = "Cancelled by user."
        } elseif ($search.AgentState -eq 'Done') {
            $newResults.Add("[Agent: $mName] (Done)")
            $search.Device.SearchDetail = $search.AgentVal
        } elseif ($search.AgentState -eq 'Error') {
            $newResults.Add("[Agent: $mName] (Failed)")
            $search.Device.SearchDetail = $search.AgentVal
        } elseif ($search.AgentState -eq 'PausedRateLimit') {
            $newResults.Add("[Agent: $mName] (Paused: Rate limit)")
            $search.Device.SearchDetail = $search.AgentVal
        } elseif ($search.AgentState -eq 'PausedBudget') {
            $newResults.Add("[Agent: $mName] (Paused: Budget)")
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

function Update-SearchFromPipelineOutput {
    param(
        [Parameter(Mandatory)]$Search,
        [Parameter(Mandatory)]$Data
    )

    if ($Data.Source -eq 'Local') {
        $Search.LocalVal = $Data.Result
        $Search.LocalState = $Data.Status
    }
    elseif ($Data.Source -eq 'Evidence') {
        $Search.EvidenceVal = $Data.Result
        $Search.EvidenceState = $Data.Status
        $Search.EvidencePath = $Data.Path
        $Search.DeviceEvidence = $Data.Evidence

        if ($Data.Status -eq 'Done' -and -not [string]::IsNullOrWhiteSpace([string]$Data.Path)) {
            $Search.Device.EvidenceCached = $true
            Invalidate-EvidenceCache -InstanceId $Search.Device.InstanceId
            $script:VisibleRowsDirty = $true
            if ([bool](Get-NotePropertyValue -Object $Search -Name 'EvidenceOnly') -and
                [string]::IsNullOrWhiteSpace([string](Get-NotePropertyValue -Object $Search -Name 'EvidenceBatchId'))) {
                $deviceName = [string](Get-NotePropertyValue -Object $Search.Device -Name 'FriendlyName')
                if ([string]::IsNullOrWhiteSpace($deviceName)) { $deviceName = 'selected device' }
                $script:SystemScanMessage = "Local evidence updated: $deviceName | $(Get-Date -Format 'HH:mm:ss')"
            }
        }
    }
    elseif ($Data.Source -eq 'Web') {
        $Search.WebVal = $Data.Result
        $Search.WebState = $Data.Status
        if ($Data.Snippets) {
            $Search.WebSnippets = $Data.Snippets
        }
    }
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
                    Update-SearchFromPipelineOutput -Search $search -Data $data
                }
            }

            if ($search.AsyncWeb.IsCompleted) {
                try {
                    $resList = $search.PsWeb.EndInvoke($search.AsyncWeb)
                    if ($null -ne $resList) {
                        foreach ($data in $resList) {
                            if ($null -ne $data) {
                                Update-SearchFromPipelineOutput -Search $search -Data $data
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
                $script:VisibleRowsDirty = $true
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
                    param($DeviceName, $InstanceId, $HardwareId, $Manufacturer, $InstalledDriver, $Motherboard, $Cpu, $Os, $EvidenceJson, $ApiKey, $AgentScriptPath, $TracePath, $CheckpointPath, $ToolCacheRoot, $ModelName, $MaxIterations)
                    $ProgressPreference = 'SilentlyContinue'
                    & $AgentScriptPath -DeviceName $DeviceName -InstanceId $InstanceId -HardwareId $HardwareId -Manufacturer $Manufacturer -InstalledDriver $InstalledDriver -Motherboard $Motherboard -Cpu $Cpu -Os $Os -EvidenceJson $EvidenceJson -ApiKey $ApiKey -TracePath $TracePath -CheckpointPath $CheckpointPath -ToolCacheRoot $ToolCacheRoot -ModelName $ModelName -MaxIterations $MaxIterations
                })

                $agentScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Get-DriverUpdateAgent.ps1'
                $evidenceJson = ''
                if ($search.DeviceEvidence) {
                    try { $evidenceJson = $search.DeviceEvidence | ConvertTo-Json -Depth 30 -Compress } catch {}
                }
                $null = $psAgent.AddArgument($deviceName)
                $null = $psAgent.AddArgument($instanceId)
                $null = $psAgent.AddArgument($hardwareId)
                $null = $psAgent.AddArgument($manufacturer)
                $null = $psAgent.AddArgument($installedDriver)
                $null = $psAgent.AddArgument($motherboard)
                $null = $psAgent.AddArgument($cpu)
                $null = $psAgent.AddArgument($os)
                $null = $psAgent.AddArgument($evidenceJson)
                $null = $psAgent.AddArgument($search.ApiKey)
                $null = $psAgent.AddArgument($agentScriptPath)
                $null = $psAgent.AddArgument($search.AgentTracePath)
                $null = $psAgent.AddArgument($search.AgentCheckpointPath)
                $null = $psAgent.AddArgument($search.AgentToolCacheRoot)
                $null = $psAgent.AddArgument($search.AgentModelName)
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
                        $logMessage = [string]$data.Message
                        $search.AgentLogs.Add($logMessage)
                        if (-not [string]::IsNullOrWhiteSpace($logMessage)) {
                            $search.AgentCurrentActivity = (($logMessage -replace '[\r\n\t]+', ' ') -replace '\s{2,}', ' ').Trim()
                        }
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
            $mName = $search.AgentModelName
            if ([string]::IsNullOrWhiteSpace($mName)) { $mName = 'gemini-3.1-flash-lite' }
            if ($search.AgentState -eq 'Waiting') {
                $newResults.Add("[Agent: $mName] (Waiting for local evidence...)")
                $search.Device.SearchDetail = $null
            } elseif ($search.AgentState -eq 'Searching') {
                $newResults.Add("[Agent: $mName] (Running... $spChar ${elapsed}s)")
                $search.Device.SearchDetail = $null
            } elseif ($search.AgentState -eq 'Done') {
                $newResults.Add("[Agent: $mName] (Done)")
                $search.Device.SearchDetail = $search.AgentVal
            } elseif ($search.AgentState -eq 'Error') {
                $newResults.Add("[Agent: $mName] (Failed)")
                $search.Device.SearchDetail = $search.AgentVal
            } elseif ($search.AgentState -eq 'PausedRateLimit') {
                $newResults.Add("[Agent: $mName] (Paused: Rate limit)")
                $search.Device.SearchDetail = $search.AgentVal
            } elseif ($search.AgentState -eq 'PausedBudget') {
                $newResults.Add("[Agent: $mName] (Paused: Budget)")
                $search.Device.SearchDetail = $search.AgentVal
            }
            if ([string]::IsNullOrWhiteSpace([string](Get-NotePropertyValue -Object $search -Name 'EvidenceBatchId'))) {
                $deviceName = Get-DeviceLookupDisplayName -Device $search.Device
                $sourceText = [string](Get-NotePropertyValue -Object $search -Name 'EvidenceSource')
                if ([string]::IsNullOrWhiteSpace($sourceText)) { $sourceText = 'local evidence' }
                $activityText = [string](Get-NotePropertyValue -Object $search -Name 'AgentCurrentActivity')
                if (-not [string]::IsNullOrWhiteSpace($activityText) -and $activityText.Length -gt 110) {
                    $activityText = $activityText.Substring(0, 107) + '...'
                }
                $activitySuffix = if ([string]::IsNullOrWhiteSpace($activityText)) { '' } else { " | $activityText" }
                if ($search.AgentState -eq 'Waiting') {
                    Set-SystemStatusMessage -Message "Agent preparing evidence: $deviceName | $mName | $sourceText | ${elapsed}s$activitySuffix"
                } elseif ($search.AgentState -eq 'Searching') {
                    Set-SystemStatusMessage -Message "Agent running: $deviceName | $mName | $sourceText | ${elapsed}s$activitySuffix"
                } elseif ($search.AgentState -eq 'Done') {
                    Set-SystemStatusMessage -Message "Agent complete: $deviceName | $mName | $sourceText | ${elapsed}s"
                } elseif ($search.AgentState -eq 'Error') {
                    Set-SystemStatusMessage -Message "Agent failed: $deviceName | $mName | $sourceText | $($search.AgentVal)"
                } elseif ($search.AgentState -eq 'PausedRateLimit') {
                    Set-SystemStatusMessage -Message "Agent paused by rate limit: $deviceName | $mName | $sourceText"
                } elseif ($search.AgentState -eq 'PausedBudget') {
                    Set-SystemStatusMessage -Message "Agent paused by step budget: $deviceName | $mName | $sourceText"
                }
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
            Invalidate-EvidenceCache -InstanceId $id
        }
        $completedBatchId = Get-NotePropertyValue -Object $completedSearch -Name 'EvidenceBatchId'
        if ($null -ne $script:EvidenceBatchState -and $completedBatchId -eq $script:EvidenceBatchState.BatchId) {
            $script:EvidenceBatchState.Completed++
            if ($completedSearch.EvidenceState -eq 'Error') {
                $script:EvidenceBatchState.Errors++
            }
        }
        $script:ActiveSearches.Remove($id)
        $script:VisibleRowsDirty = $true
    }

    Start-PendingEvidenceBatchScans
    Complete-EvidenceBatchIfFinished
}

function Clear-PendingConsoleInput {
    param([int]$MaxCount = 64)

    $drained = 0
    while ([Console]::KeyAvailable -and $drained -lt $MaxCount) {
        try {
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }
        catch {
            try { $null = [Console]::ReadKey($true) } catch { break }
        }
        $drained++
    }

    return $drained
}

# Override Read-ConsoleKey to support background search ticks & smooth rendering
function Read-ConsoleKey {
    try { [Console]::CursorVisible = $false } catch {}

    $keyName = $null
    $keyChar = [char]0
    $virtualKeyCode = $null
    $controlPressed = $false

    try {
        while (-not [Console]::KeyAvailable) {
            if (Test-WindowResized) {
                return [pscustomobject]@{
                    Key            = 'ResizeEvent'
                    KeyChar        = [char]0
                    VirtualKeyCode = 0
                    ControlPressed = $false
                }
            }

            # Update active/pending background searches and redraw
            if ($script:ActiveSearches.Count -gt 0 -or $script:EvidenceBatchQueue.Count -gt 0) {
                Update-ActiveSearches
                if ($script:VisibleRowsDirty) {
                    $script:visibleRows = Update-VisibleRows
                    $script:VisibleRowsDirty = $false
                }
                if ($script:visibleRows.Count -gt 0) {
                    $script:selectedIndex = [Math]::Max(0, [Math]::Min($script:selectedIndex, $script:visibleRows.Count - 1))
                } else {
                    $script:selectedIndex = 0
                }
                Render-Frame
                Start-Sleep -Milliseconds 150
            } else {
                Start-Sleep -Milliseconds 10
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

            if ($keyInfo.PSObject.Properties['Modifiers']) {
                $controlPressed = (([string]$keyInfo.Modifiers) -match 'Control')
            }
            elseif ($keyInfo.PSObject.Properties['ControlKeyState']) {
                $controlPressed = (([string]$keyInfo.ControlKeyState) -match 'CtrlPressed')
            }
        }

        if ($keyChar -ne [char]0 -and -not [char]::IsControl($keyChar) -and [Console]::KeyAvailable) {
            $drained = Clear-PendingConsoleInput
            $script:SystemScanMessage = "Ignored pasted/input burst ($($drained + 1) keys). Use keyboard shortcuts one at a time; right-click paste is ignored. | $(Get-Date -Format 'HH:mm:ss')"
            return [pscustomobject]@{
                Key            = 'IgnoredInputBurst'
                KeyChar        = [char]0
                VirtualKeyCode = 0
                ControlPressed = $false
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
        ControlPressed = $controlPressed
    }
}

# Initial categories detection
Write-Host 'Loading local hardware ID cache...' -ForegroundColor DarkCyan
Initialize-HardwareIdResolver
Initialize-BoardModelEvidenceStore
Initialize-AlsaUcmResolver
Initialize-MonitorEdidResolver
if ($script:HardwareIdResolverState -eq 'Ready') {
    Write-Host 'Local hardware ID cache ready.' -ForegroundColor DarkCyan
} elseif (-not [string]::IsNullOrWhiteSpace($script:HardwareIdResolverError)) {
    Write-Host "Local hardware ID cache unavailable: $($script:HardwareIdResolverError)" -ForegroundColor Yellow
} else {
    Write-Host 'Local hardware ID cache unavailable.' -ForegroundColor Yellow
}
if ($script:BoardModelEvidenceState -eq 'Unavailable' -and -not [string]::IsNullOrWhiteSpace($script:BoardModelEvidenceError)) {
    Write-Host "Board model evidence unavailable: $($script:BoardModelEvidenceError)" -ForegroundColor Yellow
}
if ($script:AlsaUcmResolverState -eq 'Ready') {
    Write-Host 'ALSA UCM audio profile cache ready.' -ForegroundColor DarkCyan
}
elseif (-not [string]::IsNullOrWhiteSpace($script:AlsaUcmResolverError)) {
    Write-Host "ALSA UCM audio profile cache unavailable: $($script:AlsaUcmResolverError)" -ForegroundColor Yellow
}
if ($script:MonitorEdidResolverState -eq 'Ready') {
    Write-Host 'Monitor EDID registry reader ready.' -ForegroundColor DarkCyan
}
elseif (-not [string]::IsNullOrWhiteSpace($script:MonitorEdidResolverError)) {
    Write-Host "Monitor EDID registry reader unavailable: $($script:MonitorEdidResolverError)" -ForegroundColor Yellow
}
Invoke-SystemScan
$selectedIndex = 0
$script:ActivePane = 'Tree'
$script:DetailScrollOffset = 0
$script:DetailCursorIndex = 0
$script:LastDetailLineCount = 0
$script:PendingAllEvidenceScanConfirmUntil = [datetime]::MinValue
$running = $true

try {
    [Console]::CursorVisible = $false

    while ($running) {
        Lock-ViewportToWindow

        # Measure pre-render tasks
        $swPrep = [System.Diagnostics.Stopwatch]::StartNew()
        if ($script:VisibleRowsDirty) {
            $script:visibleRows = Update-VisibleRows
            $script:VisibleRowsDirty = $false
        }

        if ($visibleRows.Count -eq 0) {
            $selectedIndex = 0
        } else {
            $selectedIndex = [Math]::Max(0, [Math]::Min($selectedIndex, $visibleRows.Count - 1))
            while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Root', 'Category', 'Device', 'Result')) {
                $selectedIndex--
            }
        }
        $prepMs = $swPrep.Elapsed.TotalMilliseconds

        # Measure Render
        $swRender = [System.Diagnostics.Stopwatch]::StartNew()
        Render-Frame
        $renderMs = $swRender.Elapsed.TotalMilliseconds

        # Key Handling
        $swKey = [System.Diagnostics.Stopwatch]::StartNew()
        $key = Read-ConsoleKey
        $keyReadMs = $swKey.Elapsed.TotalMilliseconds
        
        if ($null -eq $key -or -not $key.PSObject.Properties['Key']) {
            Start-Sleep -Milliseconds 50
            continue
        }

        $swProcess = [System.Diagnostics.Stopwatch]::StartNew()
        if ($key.Key -ne 'E' -and $key.KeyChar -ne 'e') {
            Reset-AllEvidenceScanConfirmation
        }
        if ($key.KeyChar -eq [char]12 -or ($key.ControlPressed -and $key.Key -eq 'L')) {
            Invoke-ConnectLanTarget
            $selectedIndex = $script:selectedIndex
            continue
        }
        switch ($key.Key) {
            'UpArrow' {
                if ($script:ActivePane -eq 'Detail') {
                    $script:DetailCursorIndex = [Math]::Max(0, $script:DetailCursorIndex - 1)
                } else {
                    if ($selectedIndex -gt 0) {
                        $idx = $selectedIndex - 1
                        while ($idx -gt 0 -and $visibleRows[$idx].Type -notin @('Root', 'Category', 'Device', 'Result')) {
                            $idx--
                        }
                        if ($visibleRows[$idx].Type -in @('Root', 'Category', 'Device', 'Result')) {
                            $selectedIndex = $idx
                        }
                    }
                    $script:DetailScrollOffset = 0
                    $script:DetailCursorIndex = 0
                }
            }
            'DownArrow' {
                if ($script:ActivePane -eq 'Detail') {
                    $maxCursor = [Math]::Max(0, $script:LastDetailLineCount - 1)
                    $script:DetailCursorIndex = [Math]::Min($maxCursor, $script:DetailCursorIndex + 1)
                } else {
                    if ($selectedIndex -lt ($visibleRows.Count - 1)) {
                        $idx = $selectedIndex + 1
                        while ($idx -lt ($visibleRows.Count - 1) -and $visibleRows[$idx].Type -notin @('Root', 'Category', 'Device', 'Result')) {
                            $idx++
                        }
                        if ($visibleRows[$idx].Type -in @('Root', 'Category', 'Device', 'Result')) {
                            $selectedIndex = $idx
                        }
                    }
                    $script:DetailScrollOffset = 0
                    $script:DetailCursorIndex = 0
                }
            }
            'PageUp' {
                if ($script:ActivePane -eq 'Detail') {
                    $script:DetailCursorIndex = [Math]::Max(0, $script:DetailCursorIndex - 10)
                } else {
                    $selectedIndex = [Math]::Max(0, $selectedIndex - 10)
                    while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Root', 'Category', 'Device', 'Result')) {
                        $selectedIndex--
                    }
                    $script:DetailScrollOffset = 0
                    $script:DetailCursorIndex = 0
                }
            }
            'PageDown' {
                if ($script:ActivePane -eq 'Detail') {
                    $maxCursor = [Math]::Max(0, $script:LastDetailLineCount - 1)
                    $script:DetailCursorIndex = [Math]::Min($maxCursor, $script:DetailCursorIndex + 10)
                } else {
                    $selectedIndex = [Math]::Min($visibleRows.Count - 1, $selectedIndex + 10)
                    while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Root', 'Category', 'Device', 'Result')) {
                        $selectedIndex--
                    }
                    $script:DetailScrollOffset = 0
                    $script:DetailCursorIndex = 0
                }
            }
            'Home' {
                if ($script:ActivePane -eq 'Detail') {
                    $script:DetailCursorIndex = 0
                    $script:DetailScrollOffset = 0
                } else {
                    $selectedIndex = 0
                    $script:DetailScrollOffset = 0
                    $script:DetailCursorIndex = 0
                }
            }
            'End' {
                if ($script:ActivePane -eq 'Detail') {
                    $script:DetailCursorIndex = [Math]::Max(0, $script:LastDetailLineCount - 1)
                } else {
                    $selectedIndex = $visibleRows.Count - 1
                    while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Root', 'Category', 'Device', 'Result')) {
                        $selectedIndex--
                    }
                    $script:DetailScrollOffset = 0
                    $script:DetailCursorIndex = 0
                }
            }
            'RightArrow' {
                $script:ActivePane = 'Detail'
            }
            'LeftArrow' {
                $script:ActivePane = 'Tree'
                $script:DetailScrollOffset = 0
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
                Reset-AllEvidenceScanConfirmation
                Invoke-SystemScanWithFeedback -Quiet
                $selectedIndex = $script:selectedIndex
            }
            'E' {
                Invoke-SelectedEvidenceScan -Rows $visibleRows -Index $selectedIndex
            }
            'S' {
                Invoke-SelectedWebScan -Rows $visibleRows -Index $selectedIndex
            }
            'A' {
                Invoke-SelectedWebScan -Rows $visibleRows -Index $selectedIndex -UseAgent
            }
            'M' {
                Reset-AllEvidenceScanConfirmation
                Invoke-ModelSelector
                $script:RequestForceClear = $true
            }
            'Escape' {
                $running = $false
            }
            'q' {
                $running = $false
            }
            'ResizeEvent' {
                $script:RequestForceClear = $true
                continue
            }
            'IgnoredInputBurst' {
                Reset-AllEvidenceScanConfirmation
                continue
            }
            default {
                # Handle lowercase hotkeys from hosts that do not map Key names consistently.
                if ($key.KeyChar -eq 'r') {
                    Reset-AllEvidenceScanConfirmation
                    Invoke-SystemScanWithFeedback -Quiet
                    $selectedIndex = $script:selectedIndex
                } elseif ($key.KeyChar -eq 'e') {
                    Invoke-SelectedEvidenceScan -Rows $visibleRows -Index $selectedIndex
                } elseif ($key.KeyChar -eq 's') {
                    Invoke-SelectedWebScan -Rows $visibleRows -Index $selectedIndex
                } elseif ($key.KeyChar -eq 'a') {
                    Invoke-SelectedWebScan -Rows $visibleRows -Index $selectedIndex -UseAgent
                } elseif ($key.KeyChar -eq 'm') {
                    Reset-AllEvidenceScanConfirmation
                    Invoke-ModelSelector
                } elseif ($key.KeyChar -eq '+') {
                    Reset-AllEvidenceScanConfirmation
                    $currentRow = $visibleRows[$selectedIndex]
                    Expand-SelectedNode -Row $currentRow
                } elseif ($key.KeyChar -eq '-') {
                    Reset-AllEvidenceScanConfirmation
                    $currentRow = $visibleRows[$selectedIndex]
                    Collapse-SelectedNode -Row $currentRow
                    $selectedIndex = $script:selectedIndex
                }
            }
        }
        $processMs = $swProcess.Elapsed.TotalMilliseconds
        $swProcess.Stop()

        # Log entry
        $now = [datetime]::Now
        $repeatDelayMs = if ($script:LastKeyTimestamp -ne [datetime]::MinValue) {
            ($now - $script:LastKeyTimestamp).TotalMilliseconds
        } else {
            0
        }
        $script:LastKeyTimestamp = $now

        $logEntry = "[$(Get-Date -Format 'HH:mm:ss.fff')] Key: $($key.Key) (char: '$($key.KeyChar)') | KeyRead: $([Math]::Round($keyReadMs, 1))ms | EventProcess: $([Math]::Round($processMs, 1))ms | Render: $([Math]::Round($renderMs, 1))ms | Prep: $([Math]::Round($prepMs, 1))ms | KeyDelay: $([Math]::Round($repeatDelayMs, 1))ms"
        $script:BenchmarkLog.Add($logEntry)
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
    
    # Save TUI benchmark log
    if ($script:BenchmarkLog -and $script:BenchmarkLog.Count -gt 0) {
        $benchmarkFile = Join-Path -Path $PSScriptRoot -ChildPath 'tui_benchmark.log'
        try {
            $script:BenchmarkLog | Set-Content -LiteralPath $benchmarkFile -Encoding UTF8
            Write-Host "TUI benchmark log saved to: $benchmarkFile" -ForegroundColor Green
        } catch {
            Write-Host "Failed to save benchmark log: $_" -ForegroundColor Yellow
        }
    }
    Write-Host 'DeviceCheck closed.'
}
