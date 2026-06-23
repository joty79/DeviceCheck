# Part of DeviceCheck.ps1. Dot-sourced by the root entrypoint; keep script-scope state shared.
# Purpose: Offline snapshot submenu helpers for the LAN connection selector.

function Get-DeviceCheckLatestSnapshotEntries {
    $snapshotsRoot = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'snapshots'
    if (-not (Test-Path -LiteralPath $snapshotsRoot -PathType Container)) {
        return @()
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -Path $snapshotsRoot -Recurse -Filter 'latest.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $snapshot = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
            $collector = Get-NotePropertyValue -Object $snapshot -Name 'Collector'
            $machine = Get-NotePropertyValue -Object $snapshot -Name 'Machine'
            $computerSystem = Get-NotePropertyValue -Object $machine -Name 'ComputerSystem'
            $computerName = [string](Get-NotePropertyValue -Object $collector -Name 'TargetComputerName')
            if ([string]::IsNullOrWhiteSpace($computerName)) {
                $computerName = [string](Get-NotePropertyValue -Object $computerSystem -Name 'Name')
            }
            if ([string]::IsNullOrWhiteSpace($computerName)) {
                $computerName = $file.Directory.Name
            }

            $devicesRoot = Get-NotePropertyValue -Object $snapshot -Name 'Devices'
            $deviceCount = [string](Get-NotePropertyValue -Object $devicesRoot -Name 'Count')
            if ([string]::IsNullOrWhiteSpace($deviceCount)) {
                $deviceCount = [string](@((Get-NotePropertyValue -Object $devicesRoot -Name 'Present')).Count)
            }

            $entries.Add([PSCustomObject]@{
                ComputerName    = $computerName
                RequestedTarget = [string](Get-NotePropertyValue -Object $collector -Name 'RequestedComputerName')
                FinishedAt      = [string](Get-NotePropertyValue -Object $collector -Name 'FinishedAt')
                DeviceCount     = $deviceCount
                SnapshotPath    = $file.FullName
                Snapshot        = $snapshot
            })
        } catch {}
    }

    return @($entries | Sort-Object FinishedAt -Descending)
}

function Get-DeviceCheckOfflineMenuEntries {
    param(
        [Parameter(Mandatory)]$AllHistory,
        $CurrentDiscovered = @(),
        [string]$CurrentNetworkId
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    $snapshotPathKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in @($AllHistory)) {
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace($entry.ComputerName)) {
            continue
        }

        $online = Test-DeviceCheckHistoryEntryOnline -Entry $entry -DiscoveredHosts $CurrentDiscovered -CurrentNetworkId $CurrentNetworkId
        if ($online.IsOnline -and $entry.NetworkId -eq $CurrentNetworkId) {
            continue
        }

        $networkLabel = Get-DeviceCheckNetworkLabel -NetworkId $entry.NetworkId
        $cached = Find-LatestSnapshotForComputerName -ComputerName $entry.ComputerName
        if ($null -eq $cached -and (Test-DeviceCheckIPv4Address -Address $entry.LastIPAddress)) {
            $cached = Find-LatestSnapshotForComputerName -ComputerName $entry.LastIPAddress
        }

        $deviceCount = 'no snapshot'
        $finishedAt = 'not captured'
        $snapshotPath = $null
        $hasSnapshot = $false
        $displayIPAddress = $(if (Test-DeviceCheckIPv4Address -Address $entry.LastIPAddress) { $entry.LastIPAddress } else { 'Unknown' })
        if ($null -ne $cached) {
            $collector = Get-NotePropertyValue -Object $cached.Snapshot -Name 'Collector'
            $finishedAt = [string](Get-NotePropertyValue -Object $collector -Name 'FinishedAt')
            $requestedTarget = [string](Get-NotePropertyValue -Object $collector -Name 'RequestedComputerName')
            if (Test-DeviceCheckIPv4Address -Address $requestedTarget) {
                $displayIPAddress = $requestedTarget
            }
            $devicesRoot = Get-NotePropertyValue -Object $cached.Snapshot -Name 'Devices'
            $deviceCount = [string](Get-NotePropertyValue -Object $devicesRoot -Name 'Count')
            if ([string]::IsNullOrWhiteSpace($deviceCount)) {
                $deviceCount = [string](@((Get-NotePropertyValue -Object $devicesRoot -Name 'Present')).Count)
            }
            $snapshotPath = $cached.LatestPath
            $hasSnapshot = $true
            $null = $snapshotPathKeys.Add($snapshotPath)
        }

        if (
            $entry.NetworkId -eq $CurrentNetworkId -and
            (Test-DeviceCheckIPv4Address -Address $displayIPAddress) -and
            (Test-PortOpen -ComputerName $displayIPAddress -Port 5985 -TimeoutMs 300)
        ) {
            continue
        }

        $entries.Add([PSCustomObject]@{
            Type          = $(if ($hasSnapshot) { 'OfflineSnapshot' } else { 'OfflineHistory' })
            ComputerName  = $entry.ComputerName
            LastIPAddress = $displayIPAddress
            MACAddress    = $entry.MACAddress
            UserName      = $entry.UserName
            NetworkId     = $entry.NetworkId
            NetworkLabel  = $networkLabel
            DeviceCount   = $deviceCount
            FinishedAt    = $finishedAt
            SnapshotPath  = $snapshotPath
            HasSnapshot   = $hasSnapshot
            Source        = 'History'
            Data          = $entry
        })
    }

    foreach ($snapshotEntry in @(Get-DeviceCheckLatestSnapshotEntries)) {
        if ($null -eq $snapshotEntry -or [string]::IsNullOrWhiteSpace($snapshotEntry.ComputerName)) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($snapshotEntry.SnapshotPath) -and $snapshotPathKeys.Contains($snapshotEntry.SnapshotPath)) {
            continue
        }

        $onlineByName = $false
        foreach ($d in @($CurrentDiscovered)) {
            if (-not [string]::IsNullOrWhiteSpace($d.HostName) -and $snapshotEntry.ComputerName.Equals($d.HostName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $onlineByName = $true
                break
            }
        }
        if ($onlineByName) {
            continue
        }

        $requested = $snapshotEntry.RequestedTarget
        if (-not (Test-DeviceCheckIPv4Address -Address $requested)) { $requested = 'snapshot' }
        $entries.Add([PSCustomObject]@{
            Type          = 'OfflineSnapshot'
            ComputerName  = $snapshotEntry.ComputerName
            LastIPAddress = $requested
            MACAddress    = 'Unknown'
            UserName      = 'Unknown'
            NetworkId     = ''
            NetworkLabel  = 'snapshot only'
            DeviceCount   = $snapshotEntry.DeviceCount
            FinishedAt    = $snapshotEntry.FinishedAt
            SnapshotPath  = $snapshotEntry.SnapshotPath
            HasSnapshot   = $true
            Source        = 'Snapshot'
            Data          = [PSCustomObject]@{
                ComputerName  = $snapshotEntry.ComputerName
                LastIPAddress = $requested
                MACAddress    = 'Unknown'
                UserName      = 'Unknown'
                NetworkId     = ''
            }
        })
    }

    return @($entries | Sort-Object NetworkLabel, ComputerName)
}

function Invoke-OfflineSnapshotSelector {
    param(
        [Parameter(Mandatory)]$NetworkInfo,
        [Parameter(Mandatory)]$AllHistory,
        $DiscoveredHosts = @()
    )

    $mode = 'Networks'
    $selectedNetwork = $null
    $selectedIndex = -1
    $needsReload = $true
    $offlineEntries = $null

    while ($true) {
        Lock-ViewportToWindow

        # Measure Prep
        $swPrep = [System.Diagnostics.Stopwatch]::StartNew()
        if ($needsReload) {
            $offlineEntries = @(Get-DeviceCheckOfflineMenuEntries -AllHistory $AllHistory -CurrentDiscovered $DiscoveredHosts -CurrentNetworkId $NetworkInfo.NetworkId)
            $needsReload = $false
        }
        $prepMs = $swPrep.Elapsed.TotalMilliseconds
        $swPrep.Stop()

        # Measure Render
        $swRender = [System.Diagnostics.Stopwatch]::StartNew()
        $items = [System.Collections.Generic.List[object]]::new()

        if ($mode -eq 'Networks') {
            $items.Add([PSCustomObject]@{ Type = 'Header'; Text = "$($_C.Bold)$($_C.Info)Offline Snapshots by Network$($_C.Reset)"; Selectable = $false })
            if ($offlineEntries.Count -eq 0) {
                $items.Add([PSCustomObject]@{ Type = 'Placeholder'; Text = "  $($_C.Dim)(No offline snapshots or offline history targets found)$($_C.Reset)"; Selectable = $false })
            } else {
                $currentLabel = Get-DeviceCheckNetworkLabel -NetworkId $NetworkInfo.NetworkId
                $networkRows = @($offlineEntries | Group-Object NetworkLabel | Sort-Object @{ Expression = { if ($_.Name -eq $currentLabel) { 0 } else { 1 } } }, Name)
                foreach ($group in $networkRows) {
                    $snapshotCount = @($group.Group | Where-Object { $_.HasSnapshot }).Count
                    $historyOnlyCount = @($group.Group | Where-Object { -not $_.HasSnapshot }).Count
                    $extra = $(if ($historyOnlyCount -gt 0) { ", $historyOnlyCount no snapshot" } else { "" })
                    $items.Add([PSCustomObject]@{
                        Type       = 'NetworkFolder'
                        Text       = "[$($group.Name)] - $($group.Count) pcs, $snapshotCount snapshots$extra"
                        Selectable = $true
                        Network    = $group.Name
                    })
                }
            }
        } else {
            $items.Add([PSCustomObject]@{ Type = 'Header'; Text = "$($_C.Bold)$($_C.Info)Offline Snapshots: $selectedNetwork$($_C.Reset)"; Selectable = $false })
            $items.Add([PSCustomObject]@{ Type = 'Back'; Text = "[Back to networks]"; Selectable = $true })
            foreach ($entry in @($offlineEntries | Where-Object { $_.NetworkLabel -eq $selectedNetwork } | Sort-Object ComputerName)) {
                $status = $(if ($entry.HasSnapshot) { 'Offline' } else { 'No Snapshot' })
                $items.Add([PSCustomObject]@{
                    Type       = $entry.Type
                    Text       = "$($entry.ComputerName) ($($entry.LastIPAddress)) - $($entry.DeviceCount) dev - $($entry.FinishedAt) ($status)"
                    Selectable = $true
                    Entry      = $entry
                })
            }
        }

        if ($selectedIndex -lt 0 -or $selectedIndex -ge $items.Count -or -not $items[$selectedIndex].Selectable) {
            $selectedIndex = 0
            for ($i = 0; $i -lt $items.Count; $i++) {
                if ($items[$i].Selectable) {
                    $selectedIndex = $i
                    break
                }
            }
        }

        try { $maxVisible = [Math]::Max(3, $Host.UI.RawUI.WindowSize.Height - 10) } catch { $maxVisible = 10 }
        $viewTop = [Math]::Max(0, [Math]::Min($selectedIndex - [int]($maxVisible / 2), [Math]::Max(0, $items.Count - $maxVisible)))
        $viewBot = [Math]::Min($viewTop + $maxVisible - 1, $items.Count - 1)

        $frame = New-UiFrame
        Add-UiFrameBanner -Frame $frame -Title 'Offline Snapshot Library' -Subtitle "Active Network: $($NetworkInfo.ProfileName)" -Width (Get-UiWidth)
        Add-UiFrameLine -Frame $frame
        $aboveMessage = $(if ($viewTop -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Up) $viewTop more above$($_C.Reset)" } else { '' })
        Add-UiFrameLine -Frame $frame -Text "$aboveMessage$($_C.EraseLn)"

        for ($index = $viewTop; $index -le $viewBot; $index++) {
            $item = $items[$index]
            if ($item.Type -eq 'Header') {
                Add-UiFrameLine -Frame $frame -Text "  $($item.Text)$($_C.EraseLn)"
            } elseif ($item.Type -eq 'Placeholder') {
                Add-UiFrameLine -Frame $frame -Text "$($item.Text)$($_C.EraseLn)"
            } else {
                $lineText = $item.Text
                if ($item.Type -eq 'OfflineHistory') {
                    $lineText = "$($_C.Dim)$lineText$($_C.Reset)"
                } elseif ($item.Type -eq 'OfflineSnapshot') {
                    $lineText = "$($_C.White)$lineText$($_C.Reset)"
                } elseif ($item.Type -eq 'NetworkFolder' -or $item.Type -eq 'Back') {
                    $lineText = "$($_C.OK)$lineText$($_C.Reset)"
                }

                if ($index -eq $selectedIndex) {
                    Add-UiFrameLine -Frame $frame -Text "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $(Get-UiGlyph -Name SelectionArrow) $($item.Text) $($_C.Reset)$($_C.EraseLn)"
                } else {
                    Add-UiFrameLine -Frame $frame -Text "    $lineText$($_C.EraseLn)"
                }
            }
        }

        $below = $items.Count - 1 - $viewBot
        $belowMessage = $(if ($below -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Down) $below more below$($_C.Reset)" } else { '' })
        Add-UiFrameLine -Frame $frame -Text "$belowMessage$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame -Text "$($_C.EraseLn)"
        Add-UiFrameShortcutSegments -Frame $frame -Segments @(
            (New-UiShortcutSegment -Text "$(Get-UiGlyph -Name Up)$(Get-UiGlyph -Name Down)" -Color $_C.White)
            (New-UiShortcutSegment -Text ' navigate   ' -Color $_C.Dim)
            (New-UiShortcutSegment -Text 'Enter' -Color $_C.OK)
            (New-UiShortcutSegment -Text ' = select   ' -Color $_C.Dim)
            (New-UiShortcutSegment -Text 'Del' -Color $_C.Fail)
            (New-UiShortcutSegment -Text ' = delete history   ' -Color $_C.Dim)
            (New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail)
            (New-UiShortcutSegment -Text ' = back' -Color $_C.Dim)
        )
        Write-UiFrame -Frame $frame
        $renderMs = $swRender.Elapsed.TotalMilliseconds
        $swRender.Stop()

        $swKey = [System.Diagnostics.Stopwatch]::StartNew()
        $key = Read-ConsoleKey
        $keyReadMs = $swKey.Elapsed.TotalMilliseconds
        $swKey.Stop()

        if ($null -eq $key -or -not $key.PSObject.Properties['Key']) {
            continue
        }

        $swProcess = [System.Diagnostics.Stopwatch]::StartNew()
        switch ($key.Key) {
            'UpArrow' {
                for ($i = $selectedIndex - 1; $i -ge 0; $i--) {
                    if ($items[$i].Selectable) { $selectedIndex = $i; break }
                }
            }
            'DownArrow' {
                for ($i = $selectedIndex + 1; $i -lt $items.Count; $i++) {
                    if ($items[$i].Selectable) { $selectedIndex = $i; break }
                }
            }
            'Escape' {
                if ($mode -eq 'Entries') {
                    $mode = 'Networks'
                    $selectedNetwork = $null
                    $selectedIndex = -1
                    continue
                }
                return [PSCustomObject]@{ Action = 'Back' }
            }
            'ResizeEvent' { continue }
            'Delete' {
                $item = $items[$selectedIndex]
                if ($mode -eq 'Entries' -and $item.PSObject.Properties['Entry'] -and $item.Entry.Source -eq 'History') {
                    $targetEntry = $item.Entry.Data
                    $updatedHistory = [System.Collections.Generic.List[object]]::new()
                    foreach ($entry in @($AllHistory)) {
                        if (-not ($entry.ComputerName.ToLower() -eq $targetEntry.ComputerName.ToLower() -and $entry.NetworkId -eq $targetEntry.NetworkId)) {
                            $updatedHistory.Add($entry)
                        }
                    }
                    Save-DeviceCheckConnectionHistory -History $updatedHistory
                    $AllHistory = $updatedHistory
                    $selectedIndex = -1
                    $needsReload = $true
                }
            }
            'Enter' {
                $item = $items[$selectedIndex]
                if ($item.Type -eq 'NetworkFolder') {
                    $selectedNetwork = $item.Network
                    $mode = 'Entries'
                    $selectedIndex = -1
                    continue
                }
                if ($item.Type -eq 'Back') {
                    $mode = 'Networks'
                    $selectedNetwork = $null
                    $selectedIndex = -1
                    continue
                }
                if ($item.Type -eq 'OfflineSnapshot') {
                    return [PSCustomObject]@{
                        Action       = 'OpenOfflineSnapshot'
                        ComputerName = $item.Entry.ComputerName
                        LastIP       = $item.Entry.LastIPAddress
                        MAC          = $item.Entry.MACAddress
                        UserName     = $item.Entry.UserName
                        SnapshotPath = $item.Entry.SnapshotPath
                    }
                }
                if ($item.Type -eq 'OfflineHistory') {
                    return [PSCustomObject]@{
                        Action       = 'Connect'
                        ComputerName = $item.Entry.ComputerName
                        LastIP       = $item.Entry.LastIPAddress
                        MAC          = $item.Entry.MACAddress
                        UserName     = $item.Entry.UserName
                    }
                }
            }
        }
        $processMs = $swProcess.Elapsed.TotalMilliseconds
        $swProcess.Stop()

        # Log benchmark entry
        $now = [datetime]::Now
        $repeatDelayMs = $(if ($script:LastKeyTimestamp -ne [datetime]::MinValue) {
            ($now - $script:LastKeyTimestamp).TotalMilliseconds
        } else {
            0
        })
        $script:LastKeyTimestamp = $now

        $logEntry = "[$(Get-Date -Format 'HH:mm:ss.fff')] [Offline-Menu] Key: $($key.Key) (char: '$($key.KeyChar)') | KeyRead: $([Math]::Round($keyReadMs, 1))ms | EventProcess: $([Math]::Round($processMs, 1))ms | Render: $([Math]::Round($renderMs, 1))ms | Prep: $([Math]::Round($prepMs, 1))ms | KeyDelay: $([Math]::Round($repeatDelayMs, 1))ms"
        $script:BenchmarkLog.Add($logEntry)
    }
}
