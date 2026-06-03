[CmdletBinding()]
param(
    [string]$EvidencePath = '',

    [string]$EvidenceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'driver-evidence'),

    [string]$InventoryRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'devices'),

    [string]$Filter = '',

    [switch]$AllDevices,

    [switch]$Refresh,

    [switch]$SkipLiveIdEnrichment,

    [int]$DeviceIndex = 0,

    [switch]$NoDetailPrompt,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LatestEvidencePath {
    param(
        [string]$RootPath
    )

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return ''
    }

    $latest = Get-ChildItem -LiteralPath $RootPath -Filter 'driver-evidence-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $latest) {
        return ''
    }

    return $latest.FullName
}

function Invoke-DriverEvidenceBundleJson {
    param(
        [string]$InventoryRootPath,
        [AllowEmptyString()]
        [string]$FilterText,
        [switch]$AllDevicesValue,
        [switch]$SkipLiveIdEnrichmentValue
    )

    $scriptPath = Join-Path $PSScriptRoot 'New-DriverEvidenceBundle.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Required tool not found: $scriptPath"
    }

    $pwshPath = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($pwshPath)) {
        $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    }

    $toolArguments = @(
        '-NoReport',
        '-AsJson',
        '-InventoryRoot',
        $InventoryRootPath
    )
    if ($AllDevicesValue) {
        $toolArguments += '-AllDevices'
    }
    if ($SkipLiveIdEnrichmentValue) {
        $toolArguments += '-SkipLiveIdEnrichment'
    }
    if (-not [string]::IsNullOrWhiteSpace($FilterText)) {
        $toolArguments += @('-Filter', $FilterText)
    }

    $jsonText = (& $pwshPath @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) @toolArguments | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        throw 'Driver evidence bundle produced no JSON output.'
    }

    return ($jsonText | ConvertFrom-Json)
}

function Get-DriverEvidenceBundle {
    param(
        [AllowEmptyString()]
        [string]$Path,
        [string]$RootPath,
        [string]$InventoryRootPath,
        [AllowEmptyString()]
        [string]$FilterText,
        [switch]$AllDevicesValue,
        [switch]$RefreshValue,
        [switch]$SkipLiveIdEnrichmentValue
    )

    if ($RefreshValue) {
        return [pscustomobject]@{
            Path = ''
            Source = 'GeneratedFresh'
            Bundle = (Invoke-DriverEvidenceBundleJson -InventoryRootPath $InventoryRootPath -FilterText $FilterText -AllDevicesValue:$AllDevicesValue -SkipLiveIdEnrichmentValue:$SkipLiveIdEnrichmentValue)
        }
    }

    $resolvedPath = $Path
    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        $resolvedPath = Get-LatestEvidencePath -RootPath $RootPath
    }

    if ([string]::IsNullOrWhiteSpace($resolvedPath) -or -not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        return [pscustomobject]@{
            Path = ''
            Source = 'GeneratedFresh'
            Bundle = (Invoke-DriverEvidenceBundleJson -InventoryRootPath $InventoryRootPath -FilterText $FilterText -AllDevicesValue:$AllDevicesValue -SkipLiveIdEnrichmentValue:$SkipLiveIdEnrichmentValue)
        }
    }

    [pscustomobject]@{
        Path = (Resolve-Path -LiteralPath $resolvedPath).ProviderPath
        Source = 'LatestSaved'
        Bundle = (Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json)
    }
}

function Get-ObjectPropertyValue {
    param(
        [object]$InputObject,
        [string]$PropertyName,
        [object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Get-ObjectArrayPropertyValue {
    param(
        [object]$InputObject,
        [string]$PropertyName
    )

    $value = Get-ObjectPropertyValue -InputObject $InputObject -PropertyName $PropertyName -DefaultValue $null
    if ($null -eq $value) {
        return @()
    }

    return @($value)
}

function Get-ShortText {
    param(
        [AllowEmptyString()]
        [string]$Text,
        [int]$Width
    )

    $value = if ($null -eq $Text) { '' } else { $Text }
    $value = ($value -replace '\s+', ' ').Trim()
    if ($Width -le 0) {
        return ''
    }
    if ($value.Length -le $Width) {
        return $value.PadRight($Width)
    }
    if ($Width -le 1) {
        return $value.Substring(0, $Width)
    }

    return ($value.Substring(0, $Width - 1) + '...')
}

function Get-DeviceStatusText {
    param(
        [object]$Device
    )

    $problem = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'Problem' -DefaultValue '')
    $status = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'Status' -DefaultValue '')
    if ($problem -eq 'CM_PROB_DISABLED') {
        return 'Disabled'
    }
    if (-not [string]::IsNullOrWhiteSpace($problem) -and $problem -notin @('0', 'CM_PROB_NONE')) {
        return $problem
    }
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        return $status
    }

    return 'Unknown'
}

function Get-BestIdText {
    param(
        [object]$Device
    )

    foreach ($searchId in @($Device.CandidateSearch.SearchIds)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$searchId.HardwareId)) {
            return [string]$searchId.HardwareId
        }
    }

    return [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'InstanceId' -DefaultValue '')
}

function Get-DriverText {
    param(
        [object]$Device
    )

    $infName = [string](Get-ObjectPropertyValue -InputObject $Device.InstalledDriver -PropertyName 'InfName' -DefaultValue '')
    $provider = [string](Get-ObjectPropertyValue -InputObject $Device.InstalledDriver -PropertyName 'Provider' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($infName) -and -not [string]::IsNullOrWhiteSpace($provider)) {
        return "$infName / $provider"
    }
    if (-not [string]::IsNullOrWhiteSpace($infName)) {
        return $infName
    }
    return $provider
}

function Get-TrustText {
    param(
        [object]$Device
    )

    $trust = Get-ObjectPropertyValue -InputObject $Device -PropertyName 'DriverResearchTrust' -DefaultValue $null
    if ($null -eq $trust) {
        return ''
    }

    $level = [string](Get-ObjectPropertyValue -InputObject $trust -PropertyName 'Level' -DefaultValue '')
    $score = [string](Get-ObjectPropertyValue -InputObject $trust -PropertyName 'Score' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($level)) {
        return ''
    }
    if ([string]::IsNullOrWhiteSpace($score)) {
        return $level
    }

    $shortLevel = switch ($level) {
        'StrongEvidenceManualReview' { 'StrongManual' }
        'ReadyForManualCandidateReview' { 'ReadyManual' }
        'WeakEvidence' { 'WeakEvidence' }
        'InventoryOnly' { 'InventoryOnly' }
        'NoDriverResearchNeeded' { 'NoResearch' }
        default { $level }
    }

    return ("{0} {1}" -f $shortLevel, $score)
}

function ConvertTo-DeviceViewRows {
    param(
        [object]$Bundle
    )

    $rowIndex = 0
    foreach ($device in @($Bundle.Devices)) {
        $rowIndex++
        [pscustomobject]@{
            Index = $rowIndex
            Device = if ([string]::IsNullOrWhiteSpace([string]$device.FriendlyName)) { [string]$device.InstanceId } else { [string]$device.FriendlyName }
            Status = Get-DeviceStatusText -Device $device
            Evidence = [string]$device.Assessment.EvidenceLevel
            Trust = Get-TrustText -Device $device
            Recommendation = [string]$device.Assessment.RecommendedAction
            Driver = Get-DriverText -Device $device
            BestId = Get-BestIdText -Device $device
            Priority = [string]$device.DriverResearchPriority
            NeedsDriverResearch = [bool]$device.NeedsDriverResearch
            InstanceId = [string]$device.InstanceId
        }
    }
}

function Write-DeviceViewTable {
    param(
        [object]$BundleInfo,
        [object[]]$Rows
    )

    $bundle = $BundleInfo.Bundle
    $consoleWidth = 130
    try {
        if (-not [Console]::IsOutputRedirected -and [Console]::WindowWidth -gt 0) {
            $consoleWidth = [Console]::WindowWidth
        }
    }
    catch {
        $consoleWidth = 130
    }

    $deviceWidth = 28
    $statusWidth = 14
    $evidenceWidth = 22
    $trustWidth = 20
    $driverWidth = 24
    $idWidth = 30
    $indexWidth = 3
    $separatorWidth = 21
    $recommendationWidth = [Math]::Max(24, $consoleWidth - ($indexWidth + $deviceWidth + $statusWidth + $evidenceWidth + $trustWidth + $driverWidth + $idWidth + $separatorWidth))

    Write-Host 'Readable Device View' -ForegroundColor Cyan
    Write-Host '--------------------' -ForegroundColor Cyan
    Write-Host ("Source       : {0}" -f $BundleInfo.Source) -ForegroundColor DarkGray
    if (-not [string]::IsNullOrWhiteSpace([string]$BundleInfo.Path)) {
        Write-Host ("Evidence JSON: {0}" -f $BundleInfo.Path) -ForegroundColor DarkGray
    }
    Write-Host ("Inventory    : {0}" -f $bundle.InventoryPath) -ForegroundColor DarkGray
    Write-Host ("Devices      : {0} total, {1} driver research, {2} exact INF" -f $bundle.Counts.Devices, $bundle.Counts.NeedsDriverResearch, $bundle.Counts.ExactInfDevices) -ForegroundColor Cyan
    Write-Host ("Safety       : {0}; no download/install/remove actions" -f $bundle.Safety.Mode) -ForegroundColor Green
    Write-Host ''

    $header = ('{0} | {1} | {2} | {3} | {4} | {5} | {6} | {7}' -f
        (Get-ShortText -Text '#' -Width $indexWidth),
        (Get-ShortText -Text 'Device' -Width $deviceWidth),
        (Get-ShortText -Text 'Status' -Width $statusWidth),
        (Get-ShortText -Text 'Evidence' -Width $evidenceWidth),
        (Get-ShortText -Text 'Trust' -Width $trustWidth),
        (Get-ShortText -Text 'Recommendation' -Width $recommendationWidth),
        (Get-ShortText -Text 'Driver' -Width $driverWidth),
        (Get-ShortText -Text 'Best ID' -Width $idWidth)
    )
    Write-Host $header -ForegroundColor DarkCyan
    Write-Host ('-' * [Math]::Min($header.Length, [Math]::Max(60, $consoleWidth - 1))) -ForegroundColor DarkGray

    foreach ($row in @($Rows)) {
        $color = 'Gray'
        if ($row.Priority -eq 'High') {
            $color = 'Red'
        }
        elseif ($row.Priority -eq 'Medium') {
            $color = 'Yellow'
        }
        elseif ($row.NeedsDriverResearch) {
            $color = 'Cyan'
        }

        $line = ('{0} | {1} | {2} | {3} | {4} | {5} | {6} | {7}' -f
            (Get-ShortText -Text ([string]$row.Index) -Width $indexWidth),
            (Get-ShortText -Text $row.Device -Width $deviceWidth),
            (Get-ShortText -Text $row.Status -Width $statusWidth),
            (Get-ShortText -Text $row.Evidence -Width $evidenceWidth),
            (Get-ShortText -Text $row.Trust -Width $trustWidth),
            (Get-ShortText -Text $row.Recommendation -Width $recommendationWidth),
            (Get-ShortText -Text $row.Driver -Width $driverWidth),
            (Get-ShortText -Text $row.BestId -Width $idWidth)
        )
        Write-Host $line -ForegroundColor $color
    }

    Write-Host ''
    Write-Host 'Legend' -ForegroundColor Cyan
    Write-Host '- LocalInfExactGeneric: local installed INF matched a generic/class ID; useful evidence, not OEM proof.' -ForegroundColor DarkGray
    Write-Host '- LocalInfExactSpecific: local installed INF matched a vendor/device-style ID.' -ForegroundColor DarkGray
    Write-Host '- InstalledInfMetadata: inventory knows the installed INF, but no exact INF line matched.' -ForegroundColor DarkGray
    Write-Host '- Trust is research readiness only; download/install/remove remain blocked until package metadata is verified.' -ForegroundColor DarkGray
}

function Write-DetailLine {
    param(
        [string]$Label,
        [AllowEmptyString()]
        [string]$Value,
        [string]$Color = 'Gray'
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    Write-Host ("{0,-18}: {1}" -f $Label, $Value) -ForegroundColor $Color
}

function Write-DetailSection {
    param(
        [string]$Title
    )

    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray
}

function Write-DeviceEvidenceDetail {
    param(
        [object]$Device,
        [int]$Index,
        [int]$Total
    )

    $displayName = if ([string]::IsNullOrWhiteSpace([string]$Device.FriendlyName)) { [string]$Device.InstanceId } else { [string]$Device.FriendlyName }
    $assessment = Get-ObjectPropertyValue -InputObject $Device -PropertyName 'Assessment' -DefaultValue $null
    $inventory = Get-ObjectPropertyValue -InputObject $Device -PropertyName 'Inventory' -DefaultValue $null
    $installedDriver = Get-ObjectPropertyValue -InputObject $Device -PropertyName 'InstalledDriver' -DefaultValue $null
    $candidateSearch = Get-ObjectPropertyValue -InputObject $Device -PropertyName 'CandidateSearch' -DefaultValue $null
    $localInfEvidence = Get-ObjectPropertyValue -InputObject $Device -PropertyName 'LocalInfEvidence' -DefaultValue $null
    $researchTrust = Get-ObjectPropertyValue -InputObject $Device -PropertyName 'DriverResearchTrust' -DefaultValue $null
    $bestResolution = Get-ObjectPropertyValue -InputObject $inventory -PropertyName 'BestResolution' -DefaultValue $null
    $bestLookup = Get-ObjectPropertyValue -InputObject $bestResolution -PropertyName 'Lookup' -DefaultValue $null
    $liveIdEvidence = Get-ObjectPropertyValue -InputObject $localInfEvidence -PropertyName 'LiveIdEvidence' -DefaultValue $null

    Write-Host ''
    Write-Host ("Device Detail [{0}/{1}]" -f $Index, $Total) -ForegroundColor Cyan
    Write-Host ('=' * 22) -ForegroundColor Cyan
    Write-Host $displayName -ForegroundColor White
    Write-DetailLine -Label 'InstanceId' -Value ([string]$Device.InstanceId) -Color 'DarkGray'
    Write-DetailLine -Label 'Status' -Value (Get-DeviceStatusText -Device $Device)
    Write-DetailLine -Label 'Evidence' -Value ([string](Get-ObjectPropertyValue -InputObject $assessment -PropertyName 'EvidenceLevel' -DefaultValue ''))
    Write-DetailLine -Label 'Recommendation' -Value ([string](Get-ObjectPropertyValue -InputObject $assessment -PropertyName 'RecommendedAction' -DefaultValue '')) -Color 'Yellow'
    Write-DetailLine -Label 'Safety' -Value 'AuditOnly; no download/install/remove actions' -Color 'Green'

    if ($null -ne $researchTrust) {
        Write-DetailSection -Title 'Research Trust'
        Write-DetailLine -Label 'Level' -Value ([string](Get-ObjectPropertyValue -InputObject $researchTrust -PropertyName 'Level' -DefaultValue '')) -Color 'Yellow'
        Write-DetailLine -Label 'Score' -Value ([string](Get-ObjectPropertyValue -InputObject $researchTrust -PropertyName 'Score' -DefaultValue ''))
        Write-DetailLine -Label 'Readiness' -Value ([string](Get-ObjectPropertyValue -InputObject $researchTrust -PropertyName 'CandidateReadiness' -DefaultValue ''))
        Write-DetailLine -Label 'Best search ID' -Value ([string](Get-ObjectPropertyValue -InputObject $researchTrust -PropertyName 'BestSearchId' -DefaultValue ''))
        Write-DetailLine -Label 'Next gate' -Value ([string](Get-ObjectPropertyValue -InputObject $researchTrust -PropertyName 'NextGate' -DefaultValue ''))
        Write-DetailLine -Label 'Download' -Value ([string](Get-ObjectPropertyValue -InputObject $researchTrust -PropertyName 'AllowsDownload' -DefaultValue 'False')) -Color 'Green'
        Write-DetailLine -Label 'Auto install' -Value ([string](Get-ObjectPropertyValue -InputObject $researchTrust -PropertyName 'AllowsAutomaticInstall' -DefaultValue 'False')) -Color 'Green'
        Write-DetailLine -Label 'Driver removal' -Value ([string](Get-ObjectPropertyValue -InputObject $researchTrust -PropertyName 'AllowsDriverRemoval' -DefaultValue 'False')) -Color 'Green'

        foreach ($blocker in @(Get-ObjectArrayPropertyValue -InputObject $researchTrust -PropertyName 'Blockers')) {
            if (-not [string]::IsNullOrWhiteSpace([string]$blocker)) {
                Write-Host ("- Blocker: {0}" -f [string]$blocker) -ForegroundColor DarkGray
            }
        }
        foreach ($factor in @(Get-ObjectArrayPropertyValue -InputObject $researchTrust -PropertyName 'Factors')) {
            if (-not [string]::IsNullOrWhiteSpace([string]$factor)) {
                Write-Host ("- Factor: {0}" -f [string]$factor) -ForegroundColor DarkGray
            }
        }
    }

    Write-DetailSection -Title 'Installed Driver'
    Write-DetailLine -Label 'INF' -Value ([string](Get-ObjectPropertyValue -InputObject $installedDriver -PropertyName 'InfName' -DefaultValue ''))
    Write-DetailLine -Label 'Provider' -Value ([string](Get-ObjectPropertyValue -InputObject $installedDriver -PropertyName 'Provider' -DefaultValue ''))
    Write-DetailLine -Label 'Version' -Value ([string](Get-ObjectPropertyValue -InputObject $installedDriver -PropertyName 'Version' -DefaultValue ''))
    Write-DetailLine -Label 'Date' -Value ([string](Get-ObjectPropertyValue -InputObject $installedDriver -PropertyName 'Date' -DefaultValue ''))
    Write-DetailLine -Label 'Service' -Value ([string](Get-ObjectPropertyValue -InputObject $installedDriver -PropertyName 'Service' -DefaultValue ''))

    Write-DetailSection -Title 'Hardware Identity'
    Write-DetailLine -Label 'Kind' -Value ([string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'DeviceKind' -DefaultValue ''))
    Write-DetailLine -Label 'Best ID' -Value (Get-BestIdText -Device $Device)
    Write-DetailLine -Label 'Local name' -Value ([string](Get-ObjectPropertyValue -InputObject $inventory -PropertyName 'BestResolutionName' -DefaultValue ''))
    Write-DetailLine -Label 'Confidence' -Value ([string](Get-ObjectPropertyValue -InputObject $bestResolution -PropertyName 'Confidence' -DefaultValue ''))
    Write-DetailLine -Label 'Vendor' -Value ([string](Get-ObjectPropertyValue -InputObject $bestLookup -PropertyName 'VendorName' -DefaultValue ''))
    Write-DetailLine -Label 'Product' -Value ([string](Get-ObjectPropertyValue -InputObject $bestLookup -PropertyName 'ProductName' -DefaultValue ''))

    $notes = @(Get-ObjectArrayPropertyValue -InputObject $assessment -PropertyName 'Notes')
    if ($notes.Count -gt 0) {
        Write-DetailSection -Title 'Notes'
        foreach ($note in $notes) {
            if (-not [string]::IsNullOrWhiteSpace([string]$note)) {
                Write-Host ("- {0}" -f [string]$note) -ForegroundColor DarkGray
            }
        }
    }

    $matchSummary = Get-ObjectPropertyValue -InputObject $localInfEvidence -PropertyName 'MatchSummary' -DefaultValue $null
    $installedInf = Get-ObjectPropertyValue -InputObject $localInfEvidence -PropertyName 'InstalledInf' -DefaultValue $null
    $matches = @(Get-ObjectArrayPropertyValue -InputObject $localInfEvidence -PropertyName 'Matches')
    if ($null -ne $matchSummary -or $null -ne $installedInf -or $matches.Count -gt 0) {
        Write-DetailSection -Title 'Local INF Evidence'
        Write-DetailLine -Label 'Installed INF' -Value ([string](Get-ObjectPropertyValue -InputObject $installedInf -PropertyName 'FullName' -DefaultValue ''))
        Write-DetailLine -Label 'Provider' -Value ([string](Get-ObjectPropertyValue -InputObject $installedInf -PropertyName 'Provider' -DefaultValue ''))
        Write-DetailLine -Label 'DriverVer' -Value ([string](Get-ObjectPropertyValue -InputObject $installedInf -PropertyName 'DriverVer' -DefaultValue ''))
        Write-DetailLine -Label 'Exact matches' -Value ([string](Get-ObjectPropertyValue -InputObject $matchSummary -PropertyName 'ExactHardwareIdMatches' -DefaultValue ''))
        foreach ($match in $matches) {
            $matchType = [string](Get-ObjectPropertyValue -InputObject $match -PropertyName 'MatchType' -DefaultValue '')
            $hardwareId = [string](Get-ObjectPropertyValue -InputObject $match -PropertyName 'HardwareId' -DefaultValue '')
            $line = [string](Get-ObjectPropertyValue -InputObject $match -PropertyName 'Line' -DefaultValue '')
            if (-not [string]::IsNullOrWhiteSpace($hardwareId)) {
                Write-Host ("- {0}: {1}" -f $matchType, $hardwareId) -ForegroundColor Gray
            }
            elseif (-not [string]::IsNullOrWhiteSpace($matchType)) {
                Write-Host ("- {0}: {1}" -f $matchType, [string](Get-ObjectPropertyValue -InputObject $match -PropertyName 'FileName' -DefaultValue '')) -ForegroundColor Gray
            }
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Host ("  {0}" -f $line) -ForegroundColor DarkGray
            }
            $resolvedLabel = [string](Get-ObjectPropertyValue -InputObject $match -PropertyName 'ResolvedLabel' -DefaultValue '')
            $modelSection = [string](Get-ObjectPropertyValue -InputObject $match -PropertyName 'ModelSection' -DefaultValue '')
            $installSection = [string](Get-ObjectPropertyValue -InputObject $match -PropertyName 'InstallSection' -DefaultValue '')
            $source = [string](Get-ObjectPropertyValue -InputObject $match -PropertyName 'Source' -DefaultValue '')
            if (-not [string]::IsNullOrWhiteSpace($resolvedLabel)) {
                Write-Host ("  Label: {0}" -f $resolvedLabel) -ForegroundColor DarkGray
            }
            if (-not [string]::IsNullOrWhiteSpace($modelSection)) {
                Write-Host ("  Source: {0}; model {1}; install {2}" -f $source, $modelSection, $installSection) -ForegroundColor DarkGray
            }
            elseif (-not [string]::IsNullOrWhiteSpace($source)) {
                Write-Host ("  Source: {0}" -f $source) -ForegroundColor DarkGray
            }
        }
    }

    if ($null -ne $liveIdEvidence) {
        Write-DetailSection -Title 'Live ID Evidence'
        Write-DetailLine -Label 'Queried' -Value ([string](Get-ObjectPropertyValue -InputObject $liveIdEvidence -PropertyName 'Queried' -DefaultValue ''))
        Write-DetailLine -Label 'Succeeded' -Value ([string](Get-ObjectPropertyValue -InputObject $liveIdEvidence -PropertyName 'QuerySucceeded' -DefaultValue ''))
        foreach ($candidateId in @(Get-ObjectArrayPropertyValue -InputObject $liveIdEvidence -PropertyName 'CandidateIds')) {
            if (-not [string]::IsNullOrWhiteSpace([string]$candidateId)) {
                Write-Host ("- {0}" -f [string]$candidateId) -ForegroundColor DarkGray
            }
        }
    }

    $searchIds = @(Get-ObjectArrayPropertyValue -InputObject $candidateSearch -PropertyName 'SearchIds')
    if ($searchIds.Count -gt 0) {
        Write-DetailSection -Title 'Driver Research Links'
        foreach ($searchId in $searchIds) {
            $hardwareId = [string](Get-ObjectPropertyValue -InputObject $searchId -PropertyName 'HardwareId' -DefaultValue '')
            if (-not [string]::IsNullOrWhiteSpace($hardwareId)) {
                Write-Host $hardwareId -ForegroundColor White
            }
            foreach ($link in @(Get-ObjectArrayPropertyValue -InputObject $searchId -PropertyName 'Links')) {
                $label = [string](Get-ObjectPropertyValue -InputObject $link -PropertyName 'Label' -DefaultValue '')
                $url = [string](Get-ObjectPropertyValue -InputObject $link -PropertyName 'Url' -DefaultValue '')
                if (-not [string]::IsNullOrWhiteSpace($url)) {
                    Write-Host ("- {0}: {1}" -f $label, $url) -ForegroundColor DarkGray
                }
            }
        }
    }
}

function Read-DeviceDetailSelection {
    param(
        [int]$MaxIndex
    )

    if ($MaxIndex -le 0 -or [Console]::IsInputRedirected) {
        return 0
    }

    Write-Host ''
    Write-Host ("Select device # for details (1-{0}, ENTER/ESC to exit): " -f $MaxIndex) -NoNewline -ForegroundColor Yellow
    $buffer = ''

    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Escape) {
            Write-Host ''
            return 0
        }
        if ($key.Key -eq [ConsoleKey]::Enter) {
            Write-Host ''
            if ([string]::IsNullOrWhiteSpace($buffer)) {
                return 0
            }
            $parsed = 0
            if ([int]::TryParse($buffer, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $MaxIndex) {
                return $parsed
            }
            Write-Host ("Invalid selection: {0}" -f $buffer) -ForegroundColor Red
            return -1
        }
        if ($key.Key -eq [ConsoleKey]::Backspace) {
            if ($buffer.Length -gt 0) {
                $buffer = $buffer.Substring(0, $buffer.Length - 1)
                Write-Host "`b `b" -NoNewline
            }
            continue
        }
        if ([char]::IsDigit($key.KeyChar)) {
            $buffer += [string]$key.KeyChar
            Write-Host $key.KeyChar -NoNewline
        }
    }
}

function Wait-DeviceDetailReturn {
    if ([Console]::IsInputRedirected) {
        return $false
    }

    Write-Host ''
    Write-Host 'Press ENTER/ESC to return to the table...' -NoNewline -ForegroundColor DarkGray
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Escape -or $key.Key -eq [ConsoleKey]::Enter) {
            Write-Host ''
            return $true
        }
    }
}

function Show-InteractiveDeviceDetails {
    param(
        [object]$BundleInfo,
        [object[]]$Rows
    )

    while ($true) {
        $selection = Read-DeviceDetailSelection -MaxIndex $Rows.Count
        if ($selection -eq 0) {
            return
        }
        if ($selection -lt 0) {
            continue
        }

        $device = @($BundleInfo.Bundle.Devices)[$selection - 1]
        Write-DeviceEvidenceDetail -Device $device -Index $selection -Total $Rows.Count
        if (-not (Wait-DeviceDetailReturn)) {
            return
        }

        Write-Host ''
        Write-DeviceViewTable -BundleInfo $BundleInfo -Rows $Rows
    }
}

$bundleInfo = Get-DriverEvidenceBundle -Path $EvidencePath -RootPath $EvidenceRoot -InventoryRootPath $InventoryRoot -FilterText $Filter -AllDevicesValue:$AllDevices -RefreshValue:$Refresh -SkipLiveIdEnrichmentValue:$SkipLiveIdEnrichment
$rows = @(ConvertTo-DeviceViewRows -Bundle $bundleInfo.Bundle)

if ($AsJson) {
    [ordered]@{
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Source = $bundleInfo.Source
        EvidencePath = $bundleInfo.Path
        InventoryPath = $bundleInfo.Bundle.InventoryPath
        Counts = $bundleInfo.Bundle.Counts
        Rows = @($rows)
    } | ConvertTo-Json -Depth 24
    return
}

Write-DeviceViewTable -BundleInfo $bundleInfo -Rows $rows

if ($DeviceIndex -lt 0) {
    throw '-DeviceIndex must be 0 or a positive table row number.'
}

if ($DeviceIndex -gt 0) {
    if ($DeviceIndex -gt $rows.Count) {
        throw ("-DeviceIndex {0} is outside the available row range 1-{1}." -f $DeviceIndex, $rows.Count)
    }

    $selectedDevice = @($bundleInfo.Bundle.Devices)[$DeviceIndex - 1]
    Write-DeviceEvidenceDetail -Device $selectedDevice -Index $DeviceIndex -Total $rows.Count
    return
}

if (-not $NoDetailPrompt) {
    Show-InteractiveDeviceDetails -BundleInfo $bundleInfo -Rows $rows
}
