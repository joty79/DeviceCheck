# Part of DeviceCheck.ps1. Dot-sourced by the root entrypoint; keep script-scope state shared.
# Purpose: Hotkey actions, evidence scans, web/agent lookup runspaces, and active lookup polling.
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
        $lookupLabel = $(if ($UseAgent) { 'Agent' } else { 'Web/AI lookup' })
        Set-SystemStatusMessage -Message "$lookupLabel needs a selected device row."
        return
    }

    if ($currentRow.Type -eq 'Device') {
        Start-DeviceLookup -Dev $currentRow.Ref -UseAgent:$UseAgent -ForceEvidenceRefresh
    } elseif ($currentRow.Type -in @('Result', 'Status') -and $null -ne $currentRow.ParentDevice) {
        Start-DeviceLookup -Dev $currentRow.ParentDevice -UseAgent:$UseAgent -ForceEvidenceRefresh
    } else {
        $lookupLabel = $(if ($UseAgent) { 'Agent' } else { 'Web/AI lookup' })
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
            $Dev.SearchKind = $(if ($UseAgent) { 'Agent' } else { $null })
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

    $selectedModels = $(if ($UseAgent) { @() } else { $script:AvailableModels | Where-Object { $_.Selected } })
    foreach ($model in $selectedModels) {
        $runKey = $(if ($model.Provider -eq 'Gemini') { $apiKey } else { $openRouterKey })
        $state = $(if ((-not $EvidenceOnly) -and $runKey) { 'Waiting' } else { 'None' })

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
    $localState = $(if ($EvidenceOnly) { 'None' } else { 'Searching' })
    $webState = $(if ($EvidenceOnly) { 'None' } else { 'Searching' })
    $agentTracePath = $(if ($UseAgent) { New-AgentTracePath -InstanceId $instanceId } else { $null })
    $agentCheckpointPath = $(if ($UseAgent) { New-AgentCheckpointPath -InstanceId $instanceId } else { $null })
    $agentToolCacheRoot = $(if ($UseAgent) { New-AgentToolCacheRoot } else { $null })

    # Pre-populate search rows
    $Dev.SearchStatus = 'Done'
    $Dev.SearchKind = $(if ($UseAgent) { 'Agent' } else { $null })
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
        $sourceText = $(if ($null -ne $preloadedEvidence) { 'remote snapshot' } else { 'local evidence' })
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
                                    Type    = $(if ($null -eq $_.Type) { $null } else { $_.Type.ToString() })
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
                            Device = $(if ($deviceName) { $deviceName } else { "Unknown Device" })
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
                $resultText = $(if ([string]::IsNullOrWhiteSpace([string]$snapshotPath)) {
                    "[Evidence Snapshot] Loaded remote snapshot evidence."
                } else {
                    "[Evidence Snapshot] Loaded remote snapshot evidence: $snapshotPath"
                })
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
        EvidenceSource     = $(if ($null -ne $preloadedEvidence) { 'remote snapshot' } else { 'local evidence' })
        UseAgent           = [bool]$UseAgent
        AgentModelName     = $agentModel
        ApiKey             = $apiKey
        AgentLogs          = [System.Collections.Generic.List[string]]::new()
        AgentState         = $(if ($UseAgent) { 'Waiting' } else { 'None' })
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
    $categoryName = $(if (-not [string]::IsNullOrWhiteSpace($categoryDisplayName)) { $categoryDisplayName } else { $Category.Name })
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
                $durationStr = $(if ($null -ne $run.Duration) { "in $($run.Duration)s" } else { "Done" })
                $newResults.Add("[$($run.Provider): $($run.ModelName)] (Done $durationStr)")
                $newResults.Add("  $($run.Val)")
            } elseif ($run.State -eq 'Error') {
                $durationStr = $(if ($null -ne $run.Duration) { " after $($run.Duration)s" } else { "" })
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
                            $hardwareId = $(if ($hwIds -is [array]) { $hwIds[0] } else { $hwIds })
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

                $agentScriptPath = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'Get-DriverUpdateAgent.ps1'
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
                $activitySuffix = $(if ([string]::IsNullOrWhiteSpace($activityText)) { '' } else { " | $activityText" })
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
                    $durationStr = $(if ($null -ne $run.Duration) { "in $($run.Duration)s" } else { "Done" })
                    $newResults.Add("[$($run.Provider): $($run.ModelName)] (Done $durationStr)")
                    $newResults.Add("  $($run.Val)")
                } elseif ($run.State -eq 'Error') {
                    $durationStr = $(if ($null -ne $run.Duration) { " after $($run.Duration)s" } else { "" })
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
