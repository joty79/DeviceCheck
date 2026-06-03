[CmdletBinding()]
param(
    [string]$InventoryPath = '',

    [string]$InventoryRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'devices'),

    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'driver-candidates'),

    [string]$Filter = '',

    [switch]$AllDevices,

    [switch]$NoReport,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LatestInventoryPath {
    param(
        [string]$RootPath
    )

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return ''
    }

    $latest = Get-ChildItem -LiteralPath $RootPath -Filter 'device-inventory-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $latest) {
        return ''
    }

    return $latest.FullName
}

function Get-Inventory {
    param(
        [AllowEmptyString()]
        [string]$Path,
        [string]$RootPath
    )

    $resolvedPath = $Path
    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        $resolvedPath = Get-LatestInventoryPath -RootPath $RootPath
    }

    if ([string]::IsNullOrWhiteSpace($resolvedPath) -or -not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "No inventory JSON found. Run internal\Show-DeviceInventory.ps1 first."
    }

    $inventory = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json
    [pscustomobject]@{
        Path = (Resolve-Path -LiteralPath $resolvedPath).ProviderPath
        Inventory = $inventory
    }
}

function Get-UrlEncoded {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    $safeValue = if ($null -eq $Value) { '' } else { $Value }
    return [System.Uri]::EscapeDataString($safeValue)
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

function Get-SafeDeviceSlug {
    param(
        [object]$Device,
        [int]$Index
    )

    $source = if (-not [string]::IsNullOrWhiteSpace([string]$Device.FriendlyName)) {
        [string]$Device.FriendlyName
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$Device.InstanceId)) {
        [string]$Device.InstanceId
    }
    else {
        "device-$Index"
    }

    $slug = ($source -replace '[^\p{L}\p{Nd}]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = "device-$Index"
    }

    if ($slug.Length -gt 70) {
        $slug = $slug.Substring(0, 70).Trim('-')
    }

    return $slug.ToLowerInvariant()
}

function Get-LinkSetForHardwareId {
    param(
        [string]$HardwareId,
        [object]$Resolution
    )

    $links = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($HardwareId)) {
        return @()
    }

    $encodedHardwareId = Get-UrlEncoded -Value $HardwareId
    $links.Add([pscustomobject]@{
        Label = 'Microsoft Update Catalog'
        Url = "https://www.catalog.update.microsoft.com/Search.aspx?q=$encodedHardwareId"
        Purpose = 'Official Windows driver search by exact Hardware ID'
    })

    $links.Add([pscustomobject]@{
        Label = 'Web Search'
        Url = "https://www.google.com/search?q=$encodedHardwareId"
        Purpose = 'General search by exact Hardware ID'
    })

    $bus = [string]$Resolution.Bus
    $fields = $Resolution.Fields
    if ($bus -eq 'PCI') {
        $vendorId = [string]$fields.VendorId
        $deviceId = [string]$fields.DeviceId
        if (-not [string]::IsNullOrWhiteSpace($vendorId) -and -not [string]::IsNullOrWhiteSpace($deviceId)) {
            $links.Add([pscustomobject]@{
                Label = 'PCI ID Repository'
                Url = "https://pci-ids.ucw.cz/read/PC/$vendorId/$deviceId"
                Purpose = 'PCI vendor/device database lookup'
            })
            $links.Add([pscustomobject]@{
                Label = 'DeviceHunt PCI'
                Url = "https://devicehunt.com/view/type/pci/vendor/$vendorId/device/$deviceId"
                Purpose = 'Human-friendly PCI lookup fallback'
            })
        }
    }
    elseif ($bus -in @('USB', 'HID')) {
        $vendorId = [string]$fields.VendorId
        $productId = [string]$fields.ProductId
        if (-not [string]::IsNullOrWhiteSpace($vendorId) -and -not [string]::IsNullOrWhiteSpace($productId)) {
            $links.Add([pscustomobject]@{
                Label = 'DeviceHunt USB'
                Url = "https://devicehunt.com/view/type/usb/vendor/$vendorId/device/$productId"
                Purpose = 'Human-friendly USB lookup fallback'
            })
        }
    }

    return @($links)
}

function ConvertTo-SearchableHardwareId {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $trimmed = $Value.Trim()
    if ($trimmed -match '^(?i)(PCI|USB|HID|ACPI|ROOT|SWD)\\([^\\]+)\\.+') {
        return ('{0}\{1}' -f $Matches[1].ToUpperInvariant(), $Matches[2])
    }

    return $trimmed
}

function Get-DeviceCandidateIds {
    param(
        [object]$Device
    )

    $idSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($Device.CandidateHardwareIds, $Device.HardwareIds, $Device.CompatibleIds, $Device.MatchingDeviceId, $Device.InstanceId)) {
        foreach ($item in @($value)) {
            $candidateId = ConvertTo-SearchableHardwareId -Value ([string]$item)
            if (-not [string]::IsNullOrWhiteSpace($candidateId) -and $idSet.Add($candidateId)) {
                $ids.Add($candidateId)
            }
        }
    }

    return @($ids)
}

function Get-CandidateReason {
    param(
        [object]$Device
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($Device.NeedsAttention) {
        $reasons.Add('NeedsAttention')
    }
    $deviceKind = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'DeviceKind' -DefaultValue '')
    $researchPriority = [string](Get-ObjectPropertyValue -InputObject $Device -PropertyName 'DriverResearchPriority' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($deviceKind)) {
        $reasons.Add("Kind=$deviceKind")
    }
    if (-not [string]::IsNullOrWhiteSpace($researchPriority)) {
        $reasons.Add("Research=$researchPriority")
    }
    foreach ($researchReason in @((Get-ObjectPropertyValue -InputObject $Device -PropertyName 'DriverResearchReasons' -DefaultValue @()))) {
        if (-not [string]::IsNullOrWhiteSpace([string]$researchReason)) {
            $reasons.Add([string]$researchReason)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Device.Problem) -and [string]$Device.Problem -notin @('0', 'CM_PROB_NONE')) {
        $reasons.Add([string]$Device.Problem)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Device.Status) -and [string]$Device.Status -notmatch '^(?i:OK|Unknown)$') {
        $reasons.Add("Status=$($Device.Status)")
    }
    if ([string]$Device.BestResolution.Confidence -in @('PARSED-ONLY', 'VENDOR-ONLY', 'UNSUPPORTED', 'NO-ID')) {
        $reasons.Add("Lookup=$($Device.BestResolution.Confidence)")
    }

    if ($reasons.Count -eq 0) {
        $reasons.Add('InventorySelected')
    }

    return @($reasons)
}

function Test-DeviceMatchesFilter {
    param(
        [object]$Device,
        [AllowEmptyString()]
        [string]$FilterText
    )

    if ([string]::IsNullOrWhiteSpace($FilterText)) {
        return $true
    }

    $needle = [regex]::Escape($FilterText.Trim())
    foreach ($value in @(
            $Device.FriendlyName,
            $Device.InstanceId,
            $Device.Class,
            $Device.Status,
            $Device.Problem,
            $Device.BestResolutionName,
            $Device.InfName,
            $Device.DriverProviderName
        )) {
        if ([string]$value -match "(?i)$needle") {
            return $true
        }
    }

    foreach ($candidateId in @(Get-DeviceCandidateIds -Device $Device)) {
        if ($candidateId -match "(?i)$needle") {
            return $true
        }
    }

    return $false
}

function New-DriverCandidateReport {
    param(
        [object]$Inventory,
        [string]$InventoryPath,
        [switch]$AllDevices,
        [AllowEmptyString()]
        [string]$FilterText
    )

    $devices = @($Inventory.Devices)
    if (-not $AllDevices) {
        $devices = @($devices | Where-Object {
            $needsDriverResearch = Get-ObjectPropertyValue -InputObject $_ -PropertyName 'NeedsDriverResearch' -DefaultValue $null
            if ($null -ne $needsDriverResearch) {
                [bool]$needsDriverResearch
            }
            else {
                [bool]$_.NeedsAttention
            }
        })
    }
    if (-not [string]::IsNullOrWhiteSpace($FilterText)) {
        $devices = @($devices | Where-Object { Test-DeviceMatchesFilter -Device $_ -FilterText $FilterText })
    }

    $candidateDevices = [System.Collections.Generic.List[object]]::new()
    $deviceIndex = 0
    foreach ($device in @($devices | Sort-Object @{ Expression = 'NeedsAttention'; Descending = $true }, FriendlyName, InstanceId)) {
        $deviceIndex++
        $candidateIds = @(Get-DeviceCandidateIds -Device $device)
        $searchIds = [System.Collections.Generic.List[object]]::new()

        foreach ($candidateId in @($candidateIds | Select-Object -First 12)) {
            $resolution = @($device.Resolutions | Where-Object { $_.Normalized -eq $candidateId.ToUpperInvariant() -or $_.Input -eq $candidateId } | Select-Object -First 1)
            if ($resolution.Count -eq 0) {
                $resolution = @($device.BestResolution)
            }

            $searchIds.Add([pscustomobject]@{
                HardwareId = $candidateId
                Resolution = $resolution[0]
                Links = @(Get-LinkSetForHardwareId -HardwareId $candidateId -Resolution $resolution[0])
            })
        }

        $candidateDevices.Add([pscustomobject]@{
            Slug = Get-SafeDeviceSlug -Device $device -Index $deviceIndex
            FriendlyName = $device.FriendlyName
            InstanceId = $device.InstanceId
            Class = $device.Class
            DeviceKind = Get-ObjectPropertyValue -InputObject $device -PropertyName 'DeviceKind' -DefaultValue ''
            AttentionCategory = Get-ObjectPropertyValue -InputObject $device -PropertyName 'AttentionCategory' -DefaultValue ''
            DriverResearchPriority = Get-ObjectPropertyValue -InputObject $device -PropertyName 'DriverResearchPriority' -DefaultValue ''
            NeedsDriverResearch = [bool](Get-ObjectPropertyValue -InputObject $device -PropertyName 'NeedsDriverResearch' -DefaultValue $false)
            Status = $device.Status
            Problem = $device.Problem
            NeedsAttention = $device.NeedsAttention
            BestResolutionName = $device.BestResolutionName
            BestResolution = $device.BestResolution
            Driver = [pscustomobject]@{
                InfName = $device.InfName
                DriverName = $device.DriverName
                Provider = $device.DriverProviderName
                Version = $device.DriverVersion
                Date = $device.DriverDate
                Service = $device.ServiceName
            }
            Reasons = @(Get-CandidateReason -Device $device)
            SearchIds = @($searchIds)
        })
    }

    [ordered]@{
        SchemaVersion = 1
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        InventoryPath = $InventoryPath
        InventoryGeneratedAtUtc = $Inventory.GeneratedAtUtc
        AllDevices = [bool]$AllDevices
        Filter = $FilterText
        Counts = [ordered]@{
            Devices = $candidateDevices.Count
            SearchIds = @($candidateDevices | ForEach-Object { $_.SearchIds }).Count
            HighPriority = @($candidateDevices | Where-Object { $_.DriverResearchPriority -eq 'High' }).Count
            MediumPriority = @($candidateDevices | Where-Object { $_.DriverResearchPriority -eq 'Medium' }).Count
        }
        Devices = @($candidateDevices)
        Safety = [ordered]@{
            Mode = 'AuditOnly'
            InstallsDrivers = $false
            DownloadsDrivers = $false
            DeletesDrivers = $false
        }
    }
}

function ConvertTo-MarkdownDriverCandidateReport {
    param(
        [object]$Report
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Driver Candidates')
    $lines.Add('')
    $lines.Add(('- Generated UTC: {0}' -f $Report.GeneratedAtUtc))
    $lines.Add(('- Inventory: `{0}`' -f $Report.InventoryPath))
    $lines.Add(('- Devices: {0}' -f $Report.Counts.Devices))
    $lines.Add(('- High priority: {0}' -f $Report.Counts.HighPriority))
    $lines.Add(('- Medium priority: {0}' -f $Report.Counts.MediumPriority))
    $lines.Add('- Safety: audit-only, no download/install/remove actions')
    if (-not [string]::IsNullOrWhiteSpace([string]$Report.Filter)) {
        $lines.Add(('- Filter: `{0}`' -f $Report.Filter))
    }
    $lines.Add('')

    foreach ($device in @($Report.Devices)) {
        $title = if ([string]::IsNullOrWhiteSpace([string]$device.FriendlyName)) { $device.InstanceId } else { $device.FriendlyName }
        $lines.Add(("## {0}" -f $title))
        $lines.Add('')
        $lines.Add(('- Status: `{0}`  Problem: `{1}`  Class: `{2}`' -f $device.Status, $device.Problem, $device.Class))
        $lines.Add(('- Device kind: `{0}`  Attention: `{1}`  Driver research: `{2}`' -f $device.DeviceKind, $device.AttentionCategory, $device.DriverResearchPriority))
        $lines.Add(('- InstanceId: `{0}`' -f $device.InstanceId))
        $lines.Add(('- Reasons: {0}' -f (@($device.Reasons) -join ', ')))
        $lines.Add(('- Best match: `{0}` / `{1}` / `{2}`' -f $device.BestResolution.Bus, $device.BestResolution.Confidence, $device.BestResolutionName))

        if (-not [string]::IsNullOrWhiteSpace([string]$device.Driver.InfName) -or -not [string]::IsNullOrWhiteSpace([string]$device.Driver.Provider)) {
            $lines.Add(('- Installed driver: INF `{0}`, provider `{1}`, version `{2}`, date `{3}`' -f $device.Driver.InfName, $device.Driver.Provider, $device.Driver.Version, $device.Driver.Date))
        }

        $lines.Add('')
        $lines.Add('### Search IDs')
        $lines.Add('')
        foreach ($searchId in @($device.SearchIds)) {
            $resolutionName = ''
            foreach ($propertyName in @('SubsystemName', 'DeviceName', 'ProductName', 'VendorName')) {
                $property = $searchId.Resolution.Lookup.PSObject.Properties[$propertyName]
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    $resolutionName = [string]$property.Value
                    break
                }
            }

            $lines.Add(('- `{0}`' -f $searchId.HardwareId))
            if (-not [string]::IsNullOrWhiteSpace($resolutionName)) {
                $lines.Add(('  - Match: `{0}` / `{1}`' -f $searchId.Resolution.Confidence, $resolutionName))
            }
            foreach ($link in @($searchId.Links)) {
                $lines.Add(('  - [{0}]({1}) - {2}' -f $link.Label, $link.Url, $link.Purpose))
            }
        }
        $lines.Add('')
    }

    return ($lines -join [Environment]::NewLine)
}

function Write-DriverCandidateSummary {
    param(
        [object]$Report
    )

    Write-Host 'Driver Candidates' -ForegroundColor Cyan
    Write-Host '-----------------' -ForegroundColor Cyan
    Write-Host ("Inventory : {0}" -f $Report.InventoryPath) -ForegroundColor DarkGray
    Write-Host ("Devices   : {0}" -f $Report.Counts.Devices) -ForegroundColor Cyan
    Write-Host ("Search IDs: {0}" -f $Report.Counts.SearchIds) -ForegroundColor Cyan
    Write-Host ("Priority  : High {0}, Medium {1}" -f $Report.Counts.HighPriority, $Report.Counts.MediumPriority) -ForegroundColor Cyan
    Write-Host 'Safety    : audit-only; no downloads, installs, or removals' -ForegroundColor Green
    Write-Host ''

    foreach ($device in @($Report.Devices | Select-Object -First 12)) {
        $bestName = if ([string]::IsNullOrWhiteSpace([string]$device.BestResolutionName)) { 'unresolved' } else { $device.BestResolutionName }
        Write-Host ("- {0}" -f $device.FriendlyName) -ForegroundColor Yellow
        Write-Host ("  {0} / {1} / {2} / research {3}" -f $device.Class, $device.Status, $device.DeviceKind, $device.DriverResearchPriority) -ForegroundColor DarkGray
        Write-Host ("  {0}" -f $bestName) -ForegroundColor DarkCyan
        $firstSearchId = @($device.SearchIds | Select-Object -First 1)
        if ($firstSearchId.Count -gt 0) {
            Write-Host ("  ID: {0}" -f $firstSearchId[0].HardwareId) -ForegroundColor DarkGray
        }
    }
}

function Save-DriverCandidateReport {
    param(
        [object]$Report,
        [string]$RootPath
    )

    New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $RootPath "driver-candidates-$timestamp.json"
    $markdownPath = Join-Path $RootPath "driver-candidates-$timestamp.md"

    $Report | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    ConvertTo-MarkdownDriverCandidateReport -Report $Report | Set-Content -LiteralPath $markdownPath -Encoding UTF8

    [pscustomobject]@{
        JsonPath = $jsonPath
        MarkdownPath = $markdownPath
    }
}

$inventoryBundle = Get-Inventory -Path $InventoryPath -RootPath $InventoryRoot
$report = New-DriverCandidateReport -Inventory $inventoryBundle.Inventory -InventoryPath $inventoryBundle.Path -AllDevices:$AllDevices -FilterText $Filter

if ($AsJson) {
    $report | ConvertTo-Json -Depth 32
    return
}

Write-DriverCandidateSummary -Report $report

if (-not $NoReport) {
    $savedReport = Save-DriverCandidateReport -Report $report -RootPath $OutputRoot
    Write-Host ''
    Write-Host 'Reports' -ForegroundColor Green
    Write-Host ("JSON     : {0}" -f $savedReport.JsonPath) -ForegroundColor DarkGray
    Write-Host ("Markdown : {0}" -f $savedReport.MarkdownPath) -ForegroundColor DarkGray
}
