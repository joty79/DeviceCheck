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
$cpuCount = 4
if (-not [string]::IsNullOrWhiteSpace($env:NUMBER_OF_PROCESSORS)) {
    try { $cpuCount = [int]$env:NUMBER_OF_PROCESSORS } catch {}
}
$script:EvidenceBatchMaxConcurrent = [Math]::Max(4, [Math]::Min(12, $cpuCount))
$script:RootExpanded = $true
$script:DeviceCheckCacheRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'DeviceCheck'
if ([string]::IsNullOrWhiteSpace($script:DeviceCheckCacheRoot)) {
    $script:DeviceCheckCacheRoot = Join-Path -Path $env:TEMP -ChildPath 'DeviceCheck'
}
$env:DEVICECHECK_CHROME_PROFILE = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'browser-profile'
$script:BenchmarkMode = $false
$script:LastNetworkScanResult = $null
$script:ScriptStartTime = Get-Date

# Load DeviceCheck function groups. These are dot-sourced so existing script-scope state stays shared.
$deviceCheckModuleRoot = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'internal\DeviceCheck'
$deviceCheckModuleFiles = @(
    '01-ModelsAndCredentials.ps1'
    '02-MachineAndTarget.ps1'
    '03-EvidenceResolvers.ps1'
    '04-UiTextFormatting.ps1'
    '05-InventoryAndSnapshots.ps1'
    '06-RemoteDiscoveryFilters.ps1'
    '06-RemoteConnection.ps1'
    '06-RemoteConnectionOfflineMenu.ps1'
    '07-TreeDetailsAndModels.ps1'
    '08-Rendering.ps1'
    '09-ActionsAndLookups.ps1'
    '10-Input.ps1'
)
foreach ($deviceCheckModuleFile in $deviceCheckModuleFiles) {
    $deviceCheckModulePath = Join-Path -Path $deviceCheckModuleRoot -ChildPath $deviceCheckModuleFile
    if (-not (Test-Path -LiteralPath $deviceCheckModulePath)) {
        throw "Required DeviceCheck module not found: $deviceCheckModulePath"
    }
    . $deviceCheckModulePath
}

Initialize-AvailableModels




$script:MachineEvidence = Get-MachineEvidence
$script:MachineCacheRoot = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath "machines\$($script:MachineEvidence.MachineId)"
try { $null = New-Item -ItemType Directory -Path $script:MachineCacheRoot -Force } catch {}
$script:SystemScanMessage = "Welcome to DeviceCheck Manager. Navigate the tree to inspect device properties."
$script:TargetMode = 'Local'
$global:TargetMode = 'Local'
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


# Helper to generate visible rows list

# Legacy stacked renderer retained temporarily while the responsive renderer settles.



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
                if ($script:TargetMode -eq 'RemoteSnapshot') {
                    Invoke-ConnectLanTarget
                    $selectedIndex = $script:selectedIndex
                } else {
                    $running = $false
                }
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
        $repeatDelayMs = $(if ($script:LastKeyTimestamp -ne [datetime]::MinValue) {
            ($now - $script:LastKeyTimestamp).TotalMilliseconds
        } else {
            0
        })
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
