[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '', Justification = 'Repository policy uses UTF-8 without BOM for PowerShell source.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Windows Terminal rendering intentionally uses a single Console.Write frame.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-* functions construct in-memory rows and frames only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The plural helper names accurately describe the row and detail collections returned.')]
param()

Set-StrictMode -Version Latest

function New-DriverPackageViewRows {
    param(
        [Parameter(Mandatory)]$Topology,
        [Parameter(Mandatory)][hashtable]$ExpandedCategories
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add([pscustomobject]@{ Type='Root'; Name=[string]$Topology.InstallerName; Ref=$Topology })
    foreach ($category in @($Topology.Categories)) {
        $categoryName = [string]$category.Name
        if (-not $ExpandedCategories.ContainsKey($categoryName)) { $ExpandedCategories[$categoryName] = $true }
        $expanded = [bool]$ExpandedCategories[$categoryName]
        $rows.Add([pscustomobject]@{ Type='Category'; Name=$categoryName; IsExpanded=$expanded; Ref=$category })
        if (-not $expanded) { continue }
        $categoryDevices = @($category.Devices)
        for ($deviceIndex = 0; $deviceIndex -lt $categoryDevices.Count; $deviceIndex++) {
            $device = $categoryDevices[$deviceIndex]
            $rows.Add([pscustomobject]@{
                Type='Device'
                Name=[string]$device.DeviceName
                Class=[string]$device.DeviceClass
                IsLast=$deviceIndex -eq ($categoryDevices.Count - 1)
                Ref=$device
            })
        }
    }
    return $rows
}

function Get-DriverPackageViewInitialSelectionIndex {
    param([Parameter(Mandatory)][object[]]$Rows)

    $bestIndex = 0
    $bestScore = -1
    for ($index = 0; $index -lt $Rows.Count; $index++) {
        if ($Rows[$index].Type -ne 'Device' -or -not $Rows[$index].Ref.IsStackRoot) { continue }
        $score = @($Rows[$index].Ref.DirectMatches).Count
        if ($score -gt $bestScore) { $bestIndex = $index; $bestScore = $score }
    }
    if ($bestScore -ge 0) { return $bestIndex }
    for ($index = 0; $index -lt $Rows.Count; $index++) {
        if ($Rows[$index].Type -eq 'Device') { return $index }
    }
    return 0
}

function Get-DriverPackageViewRelationLabel {
    param([AllowEmptyString()][string]$Relation)

    switch ($Relation) {
        'FunctionBinding'      { 'Base/function driver' }
        'ComponentBinding'     { 'Component driver' }
        'ExtensionApplication' { 'Extension layer' }
        'ComponentDeclaration' { 'Component declaration' }
        default                { $Relation }
    }
}

function Add-DriverPackageViewDetailValue {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$Value,
        [int]$Width
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $labelWidth = [Math]::Min(17, [Math]::Max(11, [Math]::Floor($Width * 0.26)))
    $prefix = '  ' + $Label.PadRight($labelWidth) + ': '
    $wrapped = @(Split-DriverAdvisorText -Text $Value -Width ([Math]::Max(1, $Width - $prefix.Length)))
    for ($lineIndex = 0; $lineIndex -lt $wrapped.Count; $lineIndex++) {
        $linePrefix = if ($lineIndex -eq 0) { $prefix } else { ' ' * $prefix.Length }
        $Lines.Add($linePrefix + $wrapped[$lineIndex])
    }
}

function Get-DriverPackageViewDetailLines {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)]$Topology,
        [int]$Width
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Row.Type -eq 'Root') {
        $summary = $Topology.Summary
        $lines.Add('Package topology')
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'Installer' -Value ([string]$Topology.InstallerName) -Width $Width
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'Present nodes' -Value ([string]$summary.PresentDeviceCount) -Width $Width
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'INF packages' -Value ([string]$summary.InfCount) -Width $Width
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'Applications' -Value ([string]$summary.PotentialApplicationCount) -Width $Width
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'Direct bindings' -Value ([string]$summary.DirectBindingCount) -Width $Width
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'Extensions' -Value ([string]$summary.ExtensionApplicationCount) -Width $Width
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'Stack roots' -Value ([string]$summary.StackRootCount) -Width $Width
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'Linked children' -Value ([string]$summary.LinkedComponentEdgeCount) -Width $Width
        $lines.Add('')
        $lines.Add('A package application is not proof that Windows will select or activate that INF.')
        return $lines
    }

    if ($Row.Type -eq 'Category') {
        $lines.Add('Matched device category')
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'Class' -Value ([string]$Row.Name) -Width $Width
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'Devices' -Value ([string]@($Row.Ref.Devices).Count) -Width $Width
        $lines.Add('')
        $lines.Add('Only present devices related to this extracted package are shown.')
        return $lines
    }

    $device = $Row.Ref
    $lines.Add('Selected package device')
    Add-DriverPackageViewDetailValue -Lines $lines -Label 'Name' -Value ([string]$device.DeviceName) -Width $Width
    Add-DriverPackageViewDetailValue -Lines $lines -Label 'Class' -Value ([string]$device.DeviceClass) -Width $Width
    Add-DriverPackageViewDetailValue -Lines $lines -Label 'Instance' -Value ([string]$device.InstanceId) -Width $Width
    Add-DriverPackageViewDetailValue -Lines $lines -Label 'Stack root' -Value ([string]$device.StackRootName) -Width $Width
    Add-DriverPackageViewDetailValue -Lines $lines -Label 'Node role' -Value $(if ($device.IsStackRoot) { 'Stack root / package target' } else { 'Related child component' }) -Width $Width

    foreach ($application in @($device.DirectMatches)) {
        $lines.Add('')
        $lines.Add((Get-DriverPackageViewRelationLabel -Relation ([string]$application.Relation)))
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'INF' -Value ([string]$application.InfFileName) -Width $Width
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'DriverVer' -Value ([string]$application.DriverVer) -Width $Width
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'Match' -Value ("{0}: {1}" -f $application.MatchKind, $application.MatchedId) -Width $Width
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'ExtensionId' -Value ([string]$application.ExtensionId) -Width $Width
    }
    foreach ($declaration in @($device.DeclarationMatches)) {
        $lines.Add('')
        $lines.Add('Declared by parent Extension')
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'Extension INF' -Value ([string]$declaration.InfFileName) -Width $Width
        Add-DriverPackageViewDetailValue -Lines $lines -Label 'Component ID' -Value ([string]$declaration.MatchedId) -Width $Width
    }
    return $lines
}

function Get-DriverPackageViewTreeText {
    param(
        [Parameter(Mandatory)]$Row,
        [switch]$Ascii
    )

    $expanded = if ($Ascii) { 'v' } else { [string][char]0x25BC }
    $collapsed = if ($Ascii) { '>' } else { [string][char]0x25B6 }
    $branch = if ($Ascii) { '+-' } else { [string][char]0x251C + [string][char]0x2500 }
    $branchLast = if ($Ascii) { '\-' } else { [string][char]0x2514 + [string][char]0x2500 }
    if ($Row.Type -eq 'Root') { return " $expanded $($Row.Name)" }
    if ($Row.Type -eq 'Category') {
        $marker = if ($Row.IsExpanded) { $expanded } else { $collapsed }
        return "   $marker $($Row.Name)"
    }
    $deviceBranch = if ($Row.IsLast) { $branchLast } else { $branch }
    $roleMarker = if ($Row.Ref.IsStackRoot) { '[T]' } else { '[C]' }
    return "       $deviceBranch $roleMarker $($Row.Name)"
}

function New-DriverPackageViewFrame {
    param(
        [Parameter(Mandatory)]$Topology,
        [Parameter(Mandatory)][object[]]$Rows,
        [int]$SelectedIndex,
        [int]$ScrollOffset,
        [ValidateSet('Tree','Detail')][string]$ActivePane = 'Tree',
        [int]$DetailScrollOffset = 0,
        [int]$Width,
        [int]$Height,
        [switch]$PlainText
    )

    $theme = Get-DriverAdvisorTheme -PlainText:$PlainText
    $glyphs = Get-DriverAdvisorGlyphMap
    $ascii = $glyphs.H -eq '-'
    $usableWidth = [Math]::Max(52, $Width)
    $usableHeight = [Math]::Max(14, $Height)
    $contentHeight = [Math]::Max(5, $usableHeight - 8)
    $split = $usableWidth -ge 105
    $leftWidth = if ($split) { [Math]::Max(42, [Math]::Floor($usableWidth * 0.43)) } else { $usableWidth }
    $rightWidth = if ($split) { $usableWidth - $leftWidth - 3 } else { $usableWidth }
    $treeViewportHeight = if ($split) { $contentHeight } else { [Math]::Min($Rows.Count, [Math]::Max(5, [Math]::Floor($contentHeight * 0.55))) }
    $maxScroll = [Math]::Max(0, $Rows.Count - $treeViewportHeight)
    if ($SelectedIndex -lt $ScrollOffset) { $ScrollOffset = $SelectedIndex }
    if ($SelectedIndex -ge ($ScrollOffset + $treeViewportHeight)) { $ScrollOffset = $SelectedIndex - $treeViewportHeight + 1 }
    $ScrollOffset = [Math]::Max(0, [Math]::Min($ScrollOffset, $maxScroll))
    $selectedRow = $Rows[[Math]::Max(0, [Math]::Min($SelectedIndex, $Rows.Count - 1))]
    $detailLines = @(Get-DriverPackageViewDetailLines -Row $selectedRow -Topology $Topology -Width $rightWidth)
    $detailViewHeight = if ($split) { $contentHeight } else { [Math]::Max(1, $contentHeight - $treeViewportHeight - 1) }
    $maxDetailScroll = [Math]::Max(0, $detailLines.Count - $detailViewHeight)
    $DetailScrollOffset = [Math]::Max(0, [Math]::Min($DetailScrollOffset, $maxDetailScroll))
    $frameLines = [System.Collections.Generic.List[string]]::new()
    $heavyRule = $glyphs.Heavy * $usableWidth
    $summary = $Topology.Summary
    $frameLines.Add("$($theme.H1)$heavyRule$($theme.Reset)")
    $frameLines.Add("$($theme.Bold)$($theme.White) DeviceCheck Package Device View — $(Limit-DriverAdvisorText ([string]$Topology.InstallerName) ([Math]::Max(1, $usableWidth - 38)))$($theme.Reset)")
    $summaryText = " $($summary.InfCount) INF | $($summary.PresentDeviceCount) present nodes | $($summary.PotentialApplicationCount) potential applications | $($summary.StackRootCount) stacks"
    $frameLines.Add("$($theme.Dim)$(Limit-DriverAdvisorText $summaryText $usableWidth)$($theme.Reset)")
    $frameLines.Add("$($theme.H1)$heavyRule$($theme.Reset)")
    if ($split) {
        $leftIndicator = if ($ActivePane -eq 'Tree') { '> ' } else { '  ' }
        $rightIndicator = if ($ActivePane -eq 'Detail') { '> ' } else { '  ' }
        $leftTitle = Limit-DriverAdvisorText "${leftIndicator}Package-filtered device tree" $leftWidth
        $rightTitle = Limit-DriverAdvisorText "${rightIndicator}Selected details" $rightWidth
        $frameLines.Add("$($theme.H1)$($leftTitle.PadRight($leftWidth))$($theme.Dim) | $($theme.H1)$rightTitle$($theme.Reset)")
    } else {
        $frameLines.Add("$($theme.H1) Package-filtered device tree$($theme.Reset)")
    }

    for ($contentIndex = 0; $contentIndex -lt $contentHeight; $contentIndex++) {
        $rowIndex = $ScrollOffset + $contentIndex
        if (-not $split -and $contentIndex -ge $treeViewportHeight) {
            $detailIndex = $DetailScrollOffset + $contentIndex - $treeViewportHeight - 1
            if ($contentIndex -eq $treeViewportHeight) {
                $detailIndicator = if ($ActivePane -eq 'Detail') { '> ' } else { '  ' }
                $frameLines.Add("$($theme.H1)${detailIndicator}Selected details$($theme.Reset)")
            } else {
                $detailPlain = if ($detailIndex -ge 0 -and $detailIndex -lt $detailLines.Count) { [string]$detailLines[$detailIndex] } else { '' }
                $frameLines.Add("$($theme.White)$(Limit-DriverAdvisorText -Text $detailPlain -Width $usableWidth)$($theme.Reset)")
            }
            continue
        }
        $treePlain = if ($rowIndex -lt $Rows.Count) { Get-DriverPackageViewTreeText -Row $Rows[$rowIndex] -Ascii:$ascii } else { '' }
        $treeLimited = Limit-DriverAdvisorText -Text $treePlain -Width $leftWidth
        if ($rowIndex -eq $SelectedIndex) {
            $treeText = "$($theme.Selected)$($treeLimited.PadRight($leftWidth))$($theme.Reset)"
        } else {
            $treeText = "$($theme.White)$($treeLimited.PadRight($leftWidth))$($theme.Reset)"
        }
        if ($split) {
            $detailIndex = $DetailScrollOffset + $contentIndex
            $detailPlain = if ($detailIndex -lt $detailLines.Count) { [string]$detailLines[$detailIndex] } else { '' }
            $detailLimited = Limit-DriverAdvisorText -Text $detailPlain -Width $rightWidth
            $frameLines.Add("$treeText$($theme.Dim) | $($theme.Reset)$($theme.White)$detailLimited$($theme.Reset)")
        } else {
            $frameLines.Add($treeText)
        }
    }
    $frameLines.Add("$($theme.H1)$heavyRule$($theme.Reset)")
    $footer = ' Up/Down navigate/scroll   Left/Right pane   +/- expand   Enter analyze   A all   Esc cancel'
    $frameLines.Add("$($theme.Dim)$(Limit-DriverAdvisorText $footer $usableWidth)$($theme.Reset)")
    return [pscustomobject]@{
        Text = $frameLines -join [Environment]::NewLine
        ScrollOffset = $ScrollOffset
        MaxScroll = $maxScroll
        DetailScrollOffset = $DetailScrollOffset
        MaxDetailScroll = $maxDetailScroll
    }
}

function ConvertTo-DriverPackageViewSnapshot {
    param(
        [Parameter(Mandatory)]$Topology,
        [int]$Width = 120,
        [int]$Height = 32,
        [switch]$PlainText
    )

    $expanded = @{}
    $rows = @(New-DriverPackageViewRows -Topology $Topology -ExpandedCategories $expanded)
    $selectedIndex = Get-DriverPackageViewInitialSelectionIndex -Rows $rows
    return (New-DriverPackageViewFrame -Topology $Topology -Rows $rows -SelectedIndex $selectedIndex -ScrollOffset 0 -ActivePane Tree -DetailScrollOffset 0 -Width $Width -Height $Height -PlainText:$PlainText).Text
}

function Show-DriverPackageView {
    param([Parameter(Mandatory)]$Topology)

    $escape = [char]27
    $expandedCategories = @{}
    $rows = @(New-DriverPackageViewRows -Topology $Topology -ExpandedCategories $expandedCategories)
    $selectedIndex = Get-DriverPackageViewInitialSelectionIndex -Rows $rows
    $scrollOffset = 0
    $detailScrollOffset = 0
    $activePane = 'Tree'
    $lastWidth = 0
    $lastHeight = 0
    $alternate = [Environment]::GetEnvironmentVariable('POWERSHELL_TUI_PRIMARY_BUFFER') -notin @('1','true','True','on','On')

    try {
        $prefix = if ($alternate) { "$escape[?1049h" } else { '' }
        [Console]::Write("$prefix$escape[?7l$escape[?25l$escape[3J$escape[2J$escape[H")
        while ($true) {
            try {
                $window = $Host.UI.RawUI.WindowSize
                $width = [Math]::Max(52, $window.Width - 1)
                $height = [Math]::Max(14, $window.Height)
                if ($Host.UI.RawUI.BufferSize -ne $window) { $Host.UI.RawUI.BufferSize = $window }
            } catch { $width = 120; $height = 32 }

            $forceClear = $width -ne $lastWidth -or $height -ne $lastHeight
            $lastWidth = $width
            $lastHeight = $height
            $rows = @(New-DriverPackageViewRows -Topology $Topology -ExpandedCategories $expandedCategories)
            $selectedIndex = [Math]::Max(0, [Math]::Min($selectedIndex, $rows.Count - 1))
            $frame = New-DriverPackageViewFrame -Topology $Topology -Rows $rows -SelectedIndex $selectedIndex -ScrollOffset $scrollOffset -ActivePane $activePane -DetailScrollOffset $detailScrollOffset -Width $width -Height $height
            $scrollOffset = $frame.ScrollOffset
            $detailScrollOffset = $frame.DetailScrollOffset
            $clear = if ($forceClear) { "$escape[3J$escape[2J$escape[H" } else { "$escape[H" }
            $interactiveFrame = ConvertTo-DriverAdvisorInteractiveFrameText -Text $frame.Text -Escape $escape
            [Console]::Write("$escape[?2026h$clear$interactiveFrame$escape[J$escape[?2026l")

            while (-not [Console]::KeyAvailable) {
                Start-Sleep -Milliseconds 10
                try {
                    $currentWindow = $Host.UI.RawUI.WindowSize
                    if ($currentWindow.Width -ne ($lastWidth + 1) -or $currentWindow.Height -ne $lastHeight) { break }
                } catch { Write-Debug "Resize polling unavailable: $($_.Exception.Message)" }
            }
            if (-not [Console]::KeyAvailable) { continue }
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   {
                    if ($activePane -eq 'Detail') { $detailScrollOffset = [Math]::Max(0, $detailScrollOffset - 1) }
                    else { $selectedIndex = if ($selectedIndex -le 0) { $rows.Count - 1 } else { $selectedIndex - 1 }; $detailScrollOffset = 0 }
                }
                'DownArrow' {
                    if ($activePane -eq 'Detail') { $detailScrollOffset = [Math]::Min($frame.MaxDetailScroll, $detailScrollOffset + 1) }
                    else { $selectedIndex = ($selectedIndex + 1) % $rows.Count; $detailScrollOffset = 0 }
                }
                'PageUp' {
                    if ($activePane -eq 'Detail') { $detailScrollOffset = [Math]::Max(0, $detailScrollOffset - 8) }
                }
                'PageDown' {
                    if ($activePane -eq 'Detail') { $detailScrollOffset = [Math]::Min($frame.MaxDetailScroll, $detailScrollOffset + 8) }
                }
                'Home'      {
                    if ($activePane -eq 'Detail') { $detailScrollOffset = 0 } else { $selectedIndex = 0; $detailScrollOffset = 0 }
                }
                'End'       {
                    if ($activePane -eq 'Detail') { $detailScrollOffset = $frame.MaxDetailScroll } else { $selectedIndex = $rows.Count - 1; $detailScrollOffset = 0 }
                }
                'LeftArrow' {
                    if ($activePane -eq 'Detail') { $activePane = 'Tree' }
                    else {
                        $row = $rows[$selectedIndex]
                        if ($row.Type -eq 'Category' -and $row.IsExpanded) { $expandedCategories[$row.Name] = $false }
                    }
                }
                'RightArrow' {
                    if ($activePane -eq 'Tree') { $activePane = 'Detail' }
                }
                { $_ -in @('Subtract','OemMinus') } {
                    $row = $rows[$selectedIndex]
                    if ($row.Type -eq 'Category') { $expandedCategories[$row.Name] = $false }
                }
                { $_ -in @('Add','OemPlus') } {
                    $row = $rows[$selectedIndex]
                    if ($row.Type -eq 'Category') { $expandedCategories[$row.Name] = $true }
                }
                'Enter' {
                    $row = $rows[$selectedIndex]
                    if ($row.Type -eq 'Category') { $expandedCategories[$row.Name] = -not [bool]$expandedCategories[$row.Name] }
                    elseif ($row.Type -eq 'Device') { return [string]$row.Ref.InstanceId }
                }
                'A'      { return '__ALL__' }
                'Escape' { return $null }
            }
        }
    }
    finally {
        $suffix = if ($alternate) { "$escape[?1049l" } else { '' }
        try { [Console]::Write("$escape[?7h$escape[?25h$suffix") } catch { Write-Debug "Terminal restore sequence failed: $($_.Exception.Message)" }
        try { [Console]::CursorVisible = $true } catch { Write-Debug "Cursor restore failed: $($_.Exception.Message)" }
    }
}
