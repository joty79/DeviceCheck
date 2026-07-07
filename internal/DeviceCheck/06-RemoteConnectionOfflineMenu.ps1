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
            $snapshotLabel = [string](Get-NotePropertyValue -Object $collector -Name 'SnapshotLabel')
            if ([string]::IsNullOrWhiteSpace($snapshotLabel)) {
                $snapshotLabel = Get-DeviceCheckSnapshotHardwareLabel -Snapshot $snapshot
            }

            $entries.Add([PSCustomObject]@{
                ComputerName    = $computerName
                SnapshotLabel   = $snapshotLabel
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
        $snapshotLabel = ''
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
            $snapshotLabel = [string](Get-NotePropertyValue -Object $collector -Name 'SnapshotLabel')
            if ([string]::IsNullOrWhiteSpace($snapshotLabel)) {
                $snapshotLabel = Get-DeviceCheckSnapshotHardwareLabel -Snapshot $cached.Snapshot
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
            SnapshotLabel = $(if ($hasSnapshot) { $snapshotLabel } else { '' })
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
            SnapshotLabel = $snapshotEntry.SnapshotLabel
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

function Get-DeviceCheckOfflineSnapshotRowLayout {
    param([int]$Width)

    $Width = [Math]::Max(80, $Width)
    $nameWidth = 18
    $ipWidth = 15
    $devicesWidth = 8
    $dateWidth = 12
    $statusWidth = 10
    $columnSeparatorWidth = 18
    $rightWidth = $nameWidth + $ipWidth + $devicesWidth + $dateWidth + $statusWidth
    $hardwareWidth = $Width - $rightWidth - $columnSeparatorWidth
    $useHardwareColumns = ($hardwareWidth -ge 69)

    if ($useHardwareColumns) {
        $modelWidth = 24
        $cpuWidth = 13
        $gpuWidth = 17
        $ramWidth = 7
        $diskWidth = 8
        $extraWidth = $hardwareWidth - ($modelWidth + $cpuWidth + $gpuWidth + $ramWidth + $diskWidth)

        $modelGrow = [Math]::Min($extraWidth, 12)
        if ($modelGrow -gt 0) { $modelWidth += $modelGrow; $extraWidth -= $modelGrow }
        $cpuGrow = [Math]::Min($extraWidth, 5)
        if ($cpuGrow -gt 0) { $cpuWidth += $cpuGrow; $extraWidth -= $cpuGrow }
        $gpuGrow = [Math]::Min($extraWidth, 7)
        if ($gpuGrow -gt 0) { $gpuWidth += $gpuGrow; $extraWidth -= $gpuGrow }
        $ramGrow = [Math]::Min($extraWidth, 2)
        if ($ramGrow -gt 0) { $ramWidth += $ramGrow; $extraWidth -= $ramGrow }
        $diskGrow = [Math]::Min($extraWidth, 20)
        if ($diskGrow -gt 0) { $diskWidth += $diskGrow; $extraWidth -= $diskGrow }
        $modelWideGrow = [Math]::Min($extraWidth, 8)
        if ($modelWideGrow -gt 0) { $modelWidth += $modelWideGrow; $extraWidth -= $modelWideGrow }
        $gpuWideGrow = [Math]::Min($extraWidth, 6)
        if ($gpuWideGrow -gt 0) { $gpuWidth += $gpuWideGrow; $extraWidth -= $gpuWideGrow }
        $diskWideGrow = [Math]::Min($extraWidth, 4)
        if ($diskWideGrow -gt 0) { $diskWidth += $diskWideGrow; $extraWidth -= $diskWideGrow }

        return [PSCustomObject]@{
            Mode    = 'HardwareColumns'
            Model   = $modelWidth
            CPU     = $cpuWidth
            GPU     = $gpuWidth
            RAM     = $ramWidth
            Disk    = $diskWidth
            Name    = $nameWidth
            IP      = $ipWidth
            Devices = $devicesWidth
            Date    = $dateWidth
            Status  = $statusWidth
        }
    }

    $compactSeparatorWidth = 10
    $fixedWidth = $nameWidth + $ipWidth + $devicesWidth + $dateWidth + $statusWidth + $compactSeparatorWidth
    $labelWidth = [Math]::Max(28, [Math]::Min(88, $Width - $fixedWidth))

    [PSCustomObject]@{
        Mode    = 'Compact'
        Label   = $labelWidth
        Name    = $nameWidth
        IP      = $ipWidth
        Devices = $devicesWidth
        Date    = $dateWidth
        Status  = $statusWidth
    }
}

function Convert-DeviceCheckOfflineColumnToLines {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width,
        [int]$MaxLines = 2
    )

    $cleanText = $(if ([string]::IsNullOrWhiteSpace($Text)) { '' } else { (($Text -replace '\s+', ' ').Trim()) })
    $lines = [System.Collections.Generic.List[string]]::new()
    $current = ''

    foreach ($word in @($cleanText -split '\s+')) {
        if ([string]::IsNullOrWhiteSpace($word) -or $lines.Count -ge $MaxLines) { continue }

        while ($word.Length -gt $Width -and $lines.Count -lt $MaxLines) {
            if (-not [string]::IsNullOrWhiteSpace($current)) {
                $lines.Add($current)
                $current = ''
                if ($lines.Count -ge $MaxLines) { break }
            }
            $lines.Add($word.Substring(0, $Width))
            $word = $word.Substring($Width)
        }
        if ($lines.Count -ge $MaxLines -or [string]::IsNullOrWhiteSpace($word)) { continue }

        $candidate = $(if ($current) { "$current $word" } else { $word })
        if ($candidate.Length -gt $Width) {
            if ($current) { $lines.Add($current) }
            $current = $word
        } else {
            $current = $candidate
        }
    }

    if ($lines.Count -lt $MaxLines -and -not [string]::IsNullOrWhiteSpace($current)) {
        $lines.Add($current)
    }
    if ($lines.Count -eq 0) { $lines = @('') }
    foreach ($line in $lines) {
        Format-PlainToWidth -Text $line -Width $Width
    }
}

function Join-DeviceCheckOfflineColumns {
    param(
        [Parameter(Mandatory)]$Columns,
        [Parameter(Mandatory)][string[]]$Colors,
        [int]$MaxLines = 2
    )

    $columnLines = [System.Collections.Generic.List[string[]]]::new()
    $lineCount = 1
    foreach ($column in @($Columns)) {
        [string[]]$lines = @(Convert-DeviceCheckOfflineColumnToLines -Text ([string]$column.Text) -Width ([int]$column.Width) -MaxLines $MaxLines)
        $columnLines.Add($lines)
        $lineCount = [Math]::Max($lineCount, $lines.Count)
    }

    $plainLines = [System.Collections.Generic.List[string]]::new()
    $renderLines = [System.Collections.Generic.List[string]]::new()
    for ($lineIndex = 0; $lineIndex -lt $lineCount; $lineIndex++) {
        $plainParts = [System.Collections.Generic.List[string]]::new()
        $renderParts = [System.Collections.Generic.List[string]]::new()
        for ($columnIndex = 0; $columnIndex -lt $columnLines.Count; $columnIndex++) {
            $width = [int]$Columns[$columnIndex].Width
            [string[]]$currentColumnLines = $columnLines[$columnIndex]
            $plainPart = $(if ($lineIndex -lt $currentColumnLines.Count) { $currentColumnLines[$lineIndex] } else { ' ' * $width })
            $plainParts.Add($plainPart)
            $renderParts.Add("$($Colors[$columnIndex])$plainPart$($_C.Reset)")
        }
        $plainLines.Add(($plainParts -join '  ').TrimEnd())
        $renderLines.Add(($renderParts -join '  ').TrimEnd())
    }

    [PSCustomObject]@{
        TextLines   = @($plainLines)
        RenderLines = @($renderLines)
    }
}

function Split-DeviceCheckSnapshotLabel {
    param([AllowEmptyString()][string]$Text)

    $normalized = $(if ([string]::IsNullOrWhiteSpace($Text)) { '' } else { (($Text -replace '\s+', ' ').Trim()) })
    $parts = @($normalized -split '\s+\|\s+', 5)

    [PSCustomObject]@{
        Model = $(if ($parts.Count -ge 1) { $parts[0] } else { $normalized })
        CPU   = $(if ($parts.Count -ge 2) { $parts[1] } else { '' })
        GPU   = $(if ($parts.Count -ge 3) { $parts[2] } else { '' })
        RAM   = $(if ($parts.Count -ge 4) { $parts[3] } else { '' })
        Disk  = $(if ($parts.Count -ge 5) { $parts[4] } else { '' })
        Full  = $normalized
    }
}

function Format-DeviceCheckOfflineMenuDate {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text) -or $Text -eq 'not captured') {
        return 'not captured'
    }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($Text, [ref]$parsed)) {
        return $parsed.ToString('MM/dd HH:mm')
    }

    return $Text
}

function New-DeviceCheckOfflineSnapshotHeaderRow {
    param([int]$Width)

    $layout = Get-DeviceCheckOfflineSnapshotRowLayout -Width $Width

    if ($layout.Mode -eq 'HardwareColumns') {
        $model = Format-PlainToWidth -Text 'Model' -Width $layout.Model
        $cpu = Format-PlainToWidth -Text 'CPU' -Width $layout.CPU
        $gpu = Format-PlainToWidth -Text 'GPU' -Width $layout.GPU
        $ram = Format-PlainToWidth -Text 'RAM' -Width $layout.RAM
        $disk = Format-PlainToWidth -Text 'Disk' -Width $layout.Disk
        $name = Format-PlainToWidth -Text 'PC name' -Width $layout.Name
        $ip = Format-PlainToWidth -Text 'Last IP' -Width $layout.IP
        $devices = Format-PlainToWidth -Text 'Devices' -Width $layout.Devices
        $date = Format-PlainToWidth -Text 'Captured' -Width $layout.Date
        $status = Format-PlainToWidth -Text 'Status' -Width $layout.Status
        $plain = "$model  $cpu  $gpu  $ram  $disk  $name  $ip  $devices  $date  $status"

        return [PSCustomObject]@{
            Type       = 'ColumnHeader'
            Text       = $plain
            RenderText = "$($_C.Dim)$plain$($_C.Reset)"
            Selectable = $false
        }
    }

    $label = Format-PlainToWidth -Text 'Hardware label' -Width $layout.Label
    $name = Format-PlainToWidth -Text 'PC name' -Width $layout.Name
    $ip = Format-PlainToWidth -Text 'Last IP' -Width $layout.IP
    $devices = Format-PlainToWidth -Text 'Devices' -Width $layout.Devices
    $date = Format-PlainToWidth -Text 'Captured' -Width $layout.Date
    $status = Format-PlainToWidth -Text 'Status' -Width $layout.Status
    $plain = "$label  $name  $ip  $devices  $date  $status"

    [PSCustomObject]@{
        Type       = 'ColumnHeader'
        Text       = $plain
        RenderText = "$($_C.Dim)$plain$($_C.Reset)"
        Selectable = $false
    }
}

function New-DeviceCheckOfflineSnapshotMenuRow {
    param(
        [Parameter(Mandatory)]$Entry,
        [int]$Width
    )

    $layout = Get-DeviceCheckOfflineSnapshotRowLayout -Width $Width
    $displayName = [string](Get-NotePropertyValue -Object $Entry -Name 'SnapshotLabel')
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = [string]$Entry.ComputerName }

    $deviceText = $(if ($Entry.HasSnapshot) { "$($Entry.DeviceCount) dev" } else { 'no snap' })
    $dateText = Format-DeviceCheckOfflineMenuDate -Text ([string]$Entry.FinishedAt)
    $statusText = $(if ($Entry.HasSnapshot) { 'Offline' } else { 'No Snapshot' })

    $name = Format-PlainToWidth -Text ([string]$Entry.ComputerName) -Width $layout.Name
    $ip = Format-PlainToWidth -Text ([string]$Entry.LastIPAddress) -Width $layout.IP
    $devices = Format-PlainToWidth -Text $deviceText -Width $layout.Devices
    $date = Format-PlainToWidth -Text $dateText -Width $layout.Date
    $status = Format-PlainToWidth -Text $statusText -Width $layout.Status
    $statusColor = $(if ($Entry.HasSnapshot) { $_C.Warn } else { $_C.Dim })

    if ($layout.Mode -eq 'HardwareColumns') {
        $hardware = Split-DeviceCheckSnapshotLabel -Text $displayName
        $joined = Join-DeviceCheckOfflineColumns -MaxLines 2 -Columns @(
            [PSCustomObject]@{ Text = $hardware.Model; Width = $layout.Model }
            [PSCustomObject]@{ Text = $hardware.CPU; Width = $layout.CPU }
            [PSCustomObject]@{ Text = $hardware.GPU; Width = $layout.GPU }
            [PSCustomObject]@{ Text = $hardware.RAM; Width = $layout.RAM }
            [PSCustomObject]@{ Text = $hardware.Disk; Width = $layout.Disk }
            [PSCustomObject]@{ Text = $Entry.ComputerName; Width = $layout.Name }
            [PSCustomObject]@{ Text = $Entry.LastIPAddress; Width = $layout.IP }
            [PSCustomObject]@{ Text = $deviceText; Width = $layout.Devices }
            [PSCustomObject]@{ Text = $dateText; Width = $layout.Date }
            [PSCustomObject]@{ Text = $statusText; Width = $layout.Status }
        ) -Colors @($_C.White, $_C.Gold, $_C.Info, $_C.OK, $_C.Dim, $_C.Info, $_C.Dim, $_C.Gold, $_C.Dim, $statusColor)
        $plain = $joined.TextLines[0]
        $render = $joined.RenderLines[0]
    } else {
        $hardware = Split-DeviceCheckSnapshotLabel -Text $displayName
        $joined = Join-DeviceCheckOfflineColumns -MaxLines 2 -Columns @(
            [PSCustomObject]@{ Text = $hardware.Full; Width = $layout.Label }
            [PSCustomObject]@{ Text = $Entry.ComputerName; Width = $layout.Name }
            [PSCustomObject]@{ Text = $Entry.LastIPAddress; Width = $layout.IP }
            [PSCustomObject]@{ Text = $deviceText; Width = $layout.Devices }
            [PSCustomObject]@{ Text = $dateText; Width = $layout.Date }
            [PSCustomObject]@{ Text = $statusText; Width = $layout.Status }
        ) -Colors @($_C.White, $_C.Info, $_C.Dim, $_C.Gold, $_C.Dim, $statusColor)
        $plain = $joined.TextLines[0]
        $render = $joined.RenderLines[0]
    }

    [PSCustomObject]@{
        Type        = $Entry.Type
        Text        = $plain
        RenderText  = $render
        TextLines   = @($joined.TextLines)
        RenderLines = @($joined.RenderLines)
        Selectable  = $true
        Entry       = $Entry
    }
}

function Get-DeviceCheckOfflineMenuItemLineCount {
    param($Item)

    if ($null -ne $Item -and $Item.PSObject.Properties['TextLines']) {
        return [Math]::Max(1, @($Item.TextLines).Count)
    }
    return 1
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
            $items.Add([PSCustomObject]@{ Type = 'Back'; Text = "< Back to networks"; Selectable = $true })
            $rowWidth = [Math]::Max(64, (Get-UiWidth) - 8)
            $items.Add((New-DeviceCheckOfflineSnapshotHeaderRow -Width $rowWidth))
            foreach ($entry in @($offlineEntries | Where-Object { $_.NetworkLabel -eq $selectedNetwork } | Sort-Object ComputerName)) {
                $items.Add((New-DeviceCheckOfflineSnapshotMenuRow -Entry $entry -Width $rowWidth))
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

        try { $maxVisibleLines = [Math]::Max(3, $Host.UI.RawUI.WindowSize.Height - 10) } catch { $maxVisibleLines = 10 }
        $viewTop = [Math]::Max(0, $selectedIndex)
        while ($viewTop -gt 0) {
            $lineSpan = 0
            for ($i = $viewTop; $i -le $selectedIndex; $i++) {
                $lineSpan += Get-DeviceCheckOfflineMenuItemLineCount -Item $items[$i]
            }
            if ($lineSpan -ge [Math]::Max(2, [int]($maxVisibleLines / 2))) { break }
            $viewTop--
        }
        while ($viewTop -lt $selectedIndex) {
            $lineSpan = 0
            for ($i = $viewTop; $i -le $selectedIndex; $i++) {
                $lineSpan += Get-DeviceCheckOfflineMenuItemLineCount -Item $items[$i]
            }
            if ($lineSpan -le $maxVisibleLines) { break }
            $viewTop++
        }
        $viewBot = $viewTop
        $usedVisibleLines = 0
        while ($viewBot -lt $items.Count) {
            $itemLines = Get-DeviceCheckOfflineMenuItemLineCount -Item $items[$viewBot]
            if ($usedVisibleLines -gt 0 -and ($usedVisibleLines + $itemLines) -gt $maxVisibleLines) { break }
            $usedVisibleLines += $itemLines
            $viewBot++
        }
        $viewBot = [Math]::Max($viewTop, $viewBot - 1)

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
            } elseif ($item.Type -eq 'ColumnHeader') {
                Add-UiFrameLine -Frame $frame -Text "    $($item.RenderText)$($_C.EraseLn)"
            } else {
                if ($index -eq $selectedIndex) {
                    if ($item.PSObject.Properties['TextLines']) {
                        $selectedLines = @($item.TextLines)
                    } else {
                        $selectedLines = @($item.Text)
                    }
                    for ($lineIndex = 0; $lineIndex -lt $selectedLines.Count; $lineIndex++) {
                        $prefix = $(if ($lineIndex -eq 0) { "  $(Get-UiGlyph -Name SelectionArrow) " } else { '    ' })
                        Add-UiFrameLine -Frame $frame -Text "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)$prefix$($selectedLines[$lineIndex]) $($_C.Reset)$($_C.EraseLn)"
                    }
                } else {
                    if ($item.PSObject.Properties['RenderLines']) {
                        $lineTexts = @($item.RenderLines)
                    } elseif ($item.PSObject.Properties['RenderText']) {
                        $lineTexts = @($item.RenderText)
                    } else {
                        $lineTexts = @($item.Text)
                    }
                    foreach ($lineText in $lineTexts) {
                        if ($item.Type -eq 'OfflineHistory' -and -not $item.PSObject.Properties['RenderLines']) {
                            $lineText = "$($_C.Dim)$lineText$($_C.Reset)"
                        } elseif ($item.Type -eq 'OfflineSnapshot' -and -not $item.PSObject.Properties['RenderLines']) {
                            $lineText = "$($_C.White)$lineText$($_C.Reset)"
                        } elseif ($item.Type -eq 'NetworkFolder' -or $item.Type -eq 'Back') {
                            $lineText = "$($_C.OK)$lineText$($_C.Reset)"
                        }
                        Add-UiFrameLine -Frame $frame -Text "    $lineText$($_C.EraseLn)"
                    }
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
