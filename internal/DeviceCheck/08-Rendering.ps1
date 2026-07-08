# Part of DeviceCheck.ps1. Dot-sourced by the root entrypoint; keep script-scope state shared.
# Purpose: Main frame rendering, footer/header helpers, and TUI performance status helpers.
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
    $aboveMessage = $(if ($aboveCount -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Up) $aboveCount more above$($_C.Reset)" } else { '' })
    Write-Host "$aboveMessage$($_C.EraseLn)"

    # Render visible rows
    for ($index = $viewTop; $index -le $viewBot; $index++) {
        $row = $script:visibleRows[$index]
        $isSelected = ($index -eq $selectedIndex)

        if ($row.Type -eq 'Root') {
            $icon = $(if ($row.IsExpanded) { Get-UiGlyph -Name Expanded } else { Get-UiGlyph -Name Collapsed })
            $displayText = " $icon  $($row.Name)"

            if ($isSelected) {
                Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $displayText $($_C.Reset)$($_C.EraseLn)"
            } else {
                Write-Host "  $($_C.White)$displayText$($_C.Reset)$($_C.EraseLn)"
            }
        }
        elseif ($row.Type -eq 'Category') {
            $icon = $(if ($row.IsExpanded) { Get-UiGlyph -Name Expanded } else { Get-UiGlyph -Name Collapsed })
            $displayText = "   $icon  $($row.Name)"

            if ($isSelected) {
                Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $displayText $($_C.Reset)$($_C.EraseLn)"
            } else {
                Write-Host "  $($_C.White)$displayText$($_C.Reset)$($_C.EraseLn)"
            }
        }
        elseif ($row.Type -eq 'Device') {
            $branch = $(if ($row.IsLast) { Get-UiGlyph -Name BranchLast } else { Get-UiGlyph -Name Branch })
            $warningIcon = $(if ($row.IsProblem) { "$($_C.Warn)[!]$($_C.Reset) " } else { "" })
            $displayText = "       $branch$warningIcon$($row.Name) [$($row.Class)]"

            if ($isSelected) {
                $cleanWarning = $(if ($row.IsProblem) { "[!] " } else { "" })
                $cleanText = "       $branch$cleanWarning$($row.Name) [$($row.Class)]"
                Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $cleanText $($_C.Reset)$($_C.EraseLn)"
            } else {
                Write-Host "$($_C.Dim)       $branch$($_C.Reset)$warningIcon$($_C.White)$($row.Name) $($_C.Dim)[$($row.Class)]$($_C.Reset)$($_C.EraseLn)"
            }
        }
        elseif ($row.Type -eq 'Status') {
            $parentPrefix = $(if ($row.ParentIsLast) { "            " } else { "       $(Get-UiGlyph -Name VLine)    " })
            Write-Host "$($_C.Dim)$parentPrefix$(Get-UiGlyph -Name BranchLast)$($_C.Reset)$($_C.Warn)[$($row.Name)]$($_C.Reset)$($_C.EraseLn)"
        }
        elseif ($row.Type -eq 'Result') {
            $parentPrefix = $(if ($row.ParentIsLast) { "            " } else { "       $(Get-UiGlyph -Name VLine)    " })

            $text = $row.Name
            $isSubResult = $text.StartsWith("  ")

            if ($isSubResult) {
                $text = $text.Substring(2)
                $branch = $(if ($row.IsLastResult) { "    $(Get-UiGlyph -Name BranchLast)" } else { "$(Get-UiGlyph -Name VLine)   $(Get-UiGlyph -Name BranchLast)" })
            } else {
                $branch = $(if ($row.IsLastResult) { Get-UiGlyph -Name BranchLast } else { Get-UiGlyph -Name Branch })
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
                $tagColor = $(if ($tagName -like '*Error*') {
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
                })

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
    $belowMessage = $(if ($belowCount -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Down) $belowCount more below$($_C.Reset)" } else { '' })
    Write-Host "$belowMessage$($_C.EraseLn)"

    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    #  DETAILS INSPECTOR PANEL
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    $selectedRow = $script:visibleRows[$selectedIndex]
    if ($selectedRow.Type -eq 'Root') {
        $machine = $selectedRow.Ref
        Write-UiSection -Title "Computer Info" -Icon ""
        Write-Host "  $($_C.Dim)System Name  :$($_C.Reset) $($_C.White)$(Get-MachineDisplayName -MachineEvidence $machine)$($_C.Reset)$($_C.EraseLn)"
        $allDevices = @()
        $snapshotLabel = ''
        if (Test-RemoteSnapshotTargetActive -and $null -ne $script:TargetSnapshot) {
            $snapshotLabel = [string](Get-NotePropertyValue -Object (Get-NotePropertyValue -Object $script:TargetSnapshot -Name 'Collector') -Name 'SnapshotLabel')
            if ([string]::IsNullOrWhiteSpace($snapshotLabel)) {
                $snapshotLabel = Get-DeviceCheckSnapshotHardwareLabel -Snapshot $script:TargetSnapshot
            }
        } else {
            $allDevices = @($script:categories | ForEach-Object { @($_.Devices) })
            $snapshotLabel = Get-DeviceCheckSnapshotHardwareLabel -Snapshot ([PSCustomObject]@{
                    Machine = $machine
                    Devices = [PSCustomObject]@{ Present = $allDevices }
                })
        }
        $deviceKind = Get-DeviceCheckDisplayDeviceKind -Snapshot $(if (Test-RemoteSnapshotTargetActive) { $script:TargetSnapshot } else { $null }) -Machine $machine -Devices $allDevices -SnapshotLabel $snapshotLabel -ComputerName (Get-MachineDisplayName -MachineEvidence $machine)
        $deviceKindColor = Get-DeviceCheckDeviceKindDisplayColor -DeviceKind $deviceKind
        Write-Host "  $($_C.Dim)Type         :$($_C.Reset) $deviceKindColor$(Format-UiValue -Text (Format-DeviceCheckDeviceKindDisplayText -DeviceKind $deviceKind) -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
        if (-not [string]::IsNullOrWhiteSpace($snapshotLabel)) {
            Write-Host "  $($_C.Dim)Label        :$($_C.Reset) $($_C.White)$(Format-UiValue -Text $snapshotLabel -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
        }
        Write-Host "  $($_C.Dim)OS           :$($_C.Reset) $($_C.White)$(Format-UiValue -Text "$($machine.OperatingSystem.Caption) $($machine.OperatingSystem.Version) Build $($machine.OperatingSystem.BuildNumber)" -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
        Write-Host "  $($_C.Dim)System       :$($_C.Reset) $($_C.White)$(Format-UiValue -Text "$($machine.ComputerSystem.Manufacturer) $($machine.ComputerSystem.Model) [$($machine.ComputerSystem.SystemType)]" -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
        Write-Host "  $($_C.Dim)BaseBoard    :$($_C.Reset) $($_C.White)$(Format-UiValue -Text "$($machine.BaseBoard.Manufacturer) $($machine.BaseBoard.Product)" -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
        Write-Host "  $($_C.Dim)Processor    :$($_C.Reset) $($_C.White)$(Format-UiValue -Text $machine.Processor.Name -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
        Write-Host "  $($_C.Dim)BIOS         :$($_C.Reset) $($_C.White)$(Format-UiValue -Text "$($machine.BIOS.Manufacturer) $($machine.BIOS.SMBIOSBIOSVersion)" -MaxLength ((Get-UiWidth) - 20))$($_C.Reset)$($_C.EraseLn)"
        if (Test-RemoteSnapshotTargetActive -and -not [string]::IsNullOrWhiteSpace($script:TargetSnapshotPath)) {
            Write-Host "$($_C.EraseLn)"
            $snapshotInfoLines = [System.Collections.Generic.List[string]]::new()
            $snapshotInfoLines.Add((New-SectionLine -Title 'Snapshot Info' -Width (Get-UiWidth)))
            Add-WrappedPathLine -Lines $snapshotInfoLines -Key 'File' -Path $script:TargetSnapshotPath -Width (Get-UiWidth)
            foreach ($snapshotInfoLine in $snapshotInfoLines) {
                Write-Host "$snapshotInfoLine$($_C.EraseLn)"
            }
        }
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

        $statusText = $(if ($errCode -eq 0) {
            "$($_C.OK)OK ($errDesc)$($_C.Reset)"
        } else {
            "$($_C.Fail)Error (Code ${errCode}: $errDesc)$($_C.Reset)"
        })

        Write-Host "  $($_C.Dim)Status       :$($_C.Reset) $statusText$($_C.EraseLn)"

        $cachedEvidence = Read-CachedDeviceEvidence -InstanceId $selectedRow.Ref.InstanceId
        if ($null -ne $cachedEvidence) {
            $capturedAt = Get-NotePropertyValue -Object $cachedEvidence -Name 'CapturedAt'
            $capturedText = $(if ($capturedAt) { $capturedAt } else { 'unknown time' })
            Write-Host "  $($_C.Dim)Evidence     :$($_C.Reset) $($_C.OK)Cached ($capturedText)$($_C.Reset)$($_C.EraseLn)"

            $importantProperties = Get-NotePropertyValue -Object $cachedEvidence -Name 'ImportantProperties'
            $hardwareIds = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_HardwareIds'
            if ($hardwareIds) {
                $firstHardwareId = $(if ($hardwareIds -is [array]) { $hardwareIds[0] } else { $hardwareIds })
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
                $firstCompatibleId = $(if ($compatibleIds -is [array]) { $compatibleIds[0] } else { $compatibleIds })
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
                    $rowColor = $(if ($rowColorName -and $_C.ContainsKey($rowColorName)) { $_C[$rowColorName] } else { $_C.White })
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
                $currentLine = $(if ($currentLine -eq "  ") { "  $word" } else { "$currentLine $word" })
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

    $displayTitle = $(if ($null -eq $Title) { '' } else { $Title })
    if ($displayTitle.Length -gt $maxTextWidth) {
        $ellipsis = Get-UiGlyph -Name Ellipsis
        $displayTitle = $displayTitle.Substring(0, [Math]::Max(1, $maxTextWidth - $ellipsis.Length)) + $ellipsis
    }
    $titlePad = [Math]::Max(0, $maxTextWidth - $displayTitle.Length)

    $displaySubtitle = $(if ($null -eq $Subtitle) { '' } else { $Subtitle })
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

    $prefix = $(if ($Icon) { " $Icon $Title " } else { " $Title " })
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
            $text = $(if ($remaining -eq 1) { $text.Substring(0, 1) } else { $text.Substring(0, $remaining - 1) + '~' })
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
    $batchRows = $(if ([string]::IsNullOrWhiteSpace($batchStatus)) { 0 } else { 1 })
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
    $selectedRow = $(if ($script:visibleRows.Count -gt 0) { $script:visibleRows[$selectedIndex] } else { $null })

    $deviceCount = 0
    if ($null -ne $script:categories) {
        foreach ($category in $script:categories) {
            $deviceCount += @($category.Devices).Count
        }
    }
    $categoryCount = $(if ($null -ne $script:categories) { @($script:categories).Count } else { 0 })
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
        $leftTitleColor = $(if ($script:ActivePane -eq 'Tree') { $_C.H1 } else { $_C.Dim })
        $rightTitleColor = $(if ($script:ActivePane -eq 'Detail') { $_C.H1 } else { $_C.Dim })
        $leftIndicator = $(if ($script:ActivePane -eq 'Tree') { "$(Get-UiGlyph -Name Diamond) " } else { '  ' })
        $rightIndicator = $(if ($script:ActivePane -eq 'Detail') { "$(Get-UiGlyph -Name Diamond) " } else { '  ' })
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
        $aboveMessage = $(if ($aboveCount -gt 0) { "$(Get-UiGlyph -Name Up) $aboveCount more above" } else { '' })
        $treeLines.Add("$($_C.Dim)$(Format-PlainToWidth -Text $aboveMessage -Width $leftWidth)$($_C.Reset)")

        for ($index = $viewTop; $index -le $viewBot; $index++) {
            $row = $script:visibleRows[$index]
            $treeLines.Add((Get-TreeDisplayLine -Row $row -IsSelected:($index -eq $selectedIndex) -Width $leftWidth))
        }

        $belowCount = $script:visibleRows.Count - 1 - $viewBot
        $belowMessage = $(if ($belowCount -gt 0) { "$(Get-UiGlyph -Name Down) $belowCount more below" } else { '' })
        $treeLines.Add("$($_C.Dim)$(Format-PlainToWidth -Text $belowMessage -Width $leftWidth)$($_C.Reset)")

        # Generate all detail lines (generous MaxLines for scrolling)
        $detailMaxLines = [Math]::Max($treeLines.Count, 200)
        $allDetailLines = $(if ($null -ne $selectedRow) {
            @(Get-DetailDisplayLines -SelectedRow $selectedRow -Width $rightWidth -MaxLines $detailMaxLines)
        } else {
            @((New-SectionLine -Title 'Selected Details' -Width $rightWidth))
        })
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
            $leftLine = $(if ($i -lt $treeLines.Count) { $treeLines[$i] } else { '' })
            $rightLine = $(if ($i -lt $detailSlice.Count) { $detailSlice[$i] } else { '' })
            Add-FrameLine -Frame $frame -Text "$(Format-AnsiToWidth -Text $leftLine -Width $leftWidth)$($_C.Dim) $(Get-UiGlyph -Name VLine) $($_C.Reset)$(Format-AnsiToWidth -Text $rightLine -Width $rightWidth)$($_C.EraseLn)"
        }
    } else {
        Add-FrameSection -Frame $frame -Title 'Device Connection Tree' -Width $uiWidth
        Add-FrameLine -Frame $frame

        $aboveCount = $viewTop
        $aboveMessage = $(if ($aboveCount -gt 0) { "  $(Get-UiGlyph -Name Up) $aboveCount more above" } else { '' })
        Add-FrameLine -Frame $frame -Text "$($_C.Dim)$(Format-PlainToWidth -Text $aboveMessage -Width $leftWidth)$($_C.Reset)$($_C.EraseLn)"

        for ($index = $viewTop; $index -le $viewBot; $index++) {
            $row = $script:visibleRows[$index]
            Add-FrameLine -Frame $frame -Text "$(Get-TreeDisplayLine -Row $row -IsSelected:($index -eq $selectedIndex) -Width $leftWidth)$($_C.EraseLn)"
        }

        $belowCount = $script:visibleRows.Count - 1 - $viewBot
        $belowMessage = $(if ($belowCount -gt 0) { "  $(Get-UiGlyph -Name Down) $belowCount more below" } else { '' })
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
