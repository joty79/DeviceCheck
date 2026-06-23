# Part of DeviceCheck.ps1. Dot-sourced by the root entrypoint; keep script-scope state shared.
# Purpose: Tree expansion, selected-detail rendering, trace rows, and model selector workflows.
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
                            Name         = $(if ($script:CurrentLoadingText) { $script:CurrentLoadingText } else { 'Searching databases & web...' })
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
        $icon = $(if ($Row.IsExpanded) { Get-UiGlyph -Name Expanded } else { Get-UiGlyph -Name Collapsed })
        $plainText = " $icon  $($Row.Name)"
        $ansiText = "$($_C.White)$plainText$($_C.Reset)"
    }
    elseif ($Row.Type -eq 'Category') {
        $icon = $(if ($Row.IsExpanded) { Get-UiGlyph -Name Expanded } else { Get-UiGlyph -Name Collapsed })
        $plainText = "   $icon  $($Row.Name)"
        $ansiText = "$($_C.White)$plainText$($_C.Reset)"
    }
    elseif ($Row.Type -eq 'Device') {
        $branch = $(if ($Row.IsLast) { Get-UiGlyph -Name BranchLast } else { Get-UiGlyph -Name Branch })
        $warning = $(if ($Row.IsProblem) { "[!] " } else { "" })
        $plainText = "       $branch$warning$($Row.Name) [$($Row.Class)]"
        if ($Row.IsProblem) {
            $ansiText = "$($_C.Dim)       $branch$($_C.Reset)$($_C.Warn)[!] $($_C.Reset)$($_C.White)$($Row.Name) $($_C.Dim)[$($Row.Class)]$($_C.Reset)"
        } else {
            $ansiText = "$($_C.Dim)       $branch$($_C.Reset)$($_C.White)$($Row.Name) $($_C.Dim)[$($Row.Class)]$($_C.Reset)"
        }
    }
    elseif ($Row.Type -eq 'Status') {
        $parentPrefix = $(if ($Row.ParentIsLast) { "            " } else { "       $(Get-UiGlyph -Name VLine)    " })
        $branchLast = Get-UiGlyph -Name BranchLast
        $plainText = "$parentPrefix$branchLast[$($Row.Name)]"
        $ansiText = "$($_C.Dim)$parentPrefix$branchLast$($_C.Reset)$($_C.Warn)[$($Row.Name)]$($_C.Reset)"
    }
    elseif ($Row.Type -eq 'Result') {
        $parentPrefix = $(if ($Row.ParentIsLast) { "            " } else { "       $(Get-UiGlyph -Name VLine)    " })
        $text = [string]$Row.Name
        $isSubResult = $text.StartsWith('  ')
        if ($isSubResult) {
            $text = $text.Substring(2)
            $branch = $(if ($Row.IsLastResult) { "    $(Get-UiGlyph -Name BranchLast)" } else { "$(Get-UiGlyph -Name VLine)   $(Get-UiGlyph -Name BranchLast)" })
        } else {
            $branch = $(if ($Row.IsLastResult) { Get-UiGlyph -Name BranchLast } else { Get-UiGlyph -Name Branch })
        }

        $plainText = "$parentPrefix$branch$text"
        if ($text -match '^(\[([^\]]+)\])(.*)$') {
            $tag = $Matches[1]
            $tagName = $Matches[2]
            $rest = $Matches[3]
            $tagColor = $(if ($tagName -like '*Error*') {
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
            })
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
    $stateText = $(if ($ActiveSearch.AgentState) { $ActiveSearch.AgentState } else { 'Unknown' })
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
        $targetColor = $(if (Test-RemoteSnapshotTargetActive) { $_C.Info } else { $_C.OK })
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
        $memory = Get-NotePropertyValue -Object $machine -Name 'Memory'
        $ramText = Format-MemorySummaryText -Memory $memory -ComputerSystem $machine.ComputerSystem
        if (-not [string]::IsNullOrWhiteSpace($ramText)) {
            Add-KeyValueLines -Lines $lines -Key 'RAM' -Value $ramText -Width $Width
        }
        $ramSpeed = Format-MemorySpeedText -Memory $memory
        if (-not [string]::IsNullOrWhiteSpace($ramSpeed)) {
            Add-KeyValueLines -Lines $lines -Key 'RAM Speed' -Value $ramSpeed -Width $Width
        }
        $ramPart = Format-MemoryPartNumberText -Memory $memory
        if (-not [string]::IsNullOrWhiteSpace($ramPart)) {
            Add-KeyValueLines -Lines $lines -Key 'RAM Part' -Value $ramPart -Width $Width
        }

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
            $evidenceText = $(if ($activeEvidenceCount -gt 0 -or $queuedEvidenceCount -gt 0) {
                "$activeEvidenceCount scanning / $queuedEvidenceCount queued / $cachedEvidenceCount cached"
            } else {
                "$cachedEvidenceCount cached"
            })
            $evidenceColor = $(if ($activeEvidenceCount -gt 0 -or $queuedEvidenceCount -gt 0) { $_C.Warn } elseif ($cachedEvidenceCount -gt 0) { $_C.OK } else { $_C.Dim })
            Add-KeyValueLines -Lines $lines -Key 'Evidence' -Value $evidenceText -Width $Width -ValueColor $evidenceColor
        }
    }
    elseif ($SelectedRow.Type -eq 'Device') {
        $lines.Add((New-SectionLine -Title 'Device Properties' -Width $Width))
        Add-KeyValueLines -Lines $lines -Key 'FriendlyName' -Value $SelectedRow.Ref.FriendlyName -Width $Width
        Add-KeyValueLines -Lines $lines -Key 'InstanceId' -Value $SelectedRow.Ref.InstanceId -Width $Width

        $errCode = [int]$SelectedRow.Ref.ConfigManagerErrorCode
        $errDesc = Get-DeviceProblemDescription -ErrorCode $errCode
        $statusColor = $(if ($errCode -eq 0) { $_C.OK } else { $_C.Fail })
        $statusValue = $(if ($errCode -eq 0) { "OK ($errDesc)" } else { "Error (Code ${errCode}: $errDesc)" })
        Add-KeyValueLines -Lines $lines -Key 'Status' -Value $statusValue -Width $Width -ValueColor $statusColor

        $activeSearch = $(if ($script:ActiveSearches.Contains($SelectedRow.Ref.InstanceId)) { $script:ActiveSearches[$SelectedRow.Ref.InstanceId] } else { $null })
        if ($null -ne $activeSearch -and $activeSearch.EvidenceState -eq 'Searching') {
            Add-KeyValueLines -Lines $lines -Key 'Evidence' -Value 'Collecting local evidence...' -Width $Width -ValueColor $_C.Warn
        } elseif ($null -ne $activeSearch -and $activeSearch.EvidenceState -eq 'Error') {
            Add-KeyValueLines -Lines $lines -Key 'Evidence' -Value "Error: $($activeSearch.EvidenceVal)" -Width $Width -ValueColor $_C.Fail
        }

        $cachedEvidence = Read-CachedDeviceEvidence -InstanceId $SelectedRow.Ref.InstanceId
        if ($null -ne $cachedEvidence) {
            $capturedAt = Get-NotePropertyValue -Object $cachedEvidence -Name 'CapturedAt'
            $capturedText = $(if ($capturedAt) { $capturedAt } else { 'unknown time' })
            if ($null -eq $activeSearch -or $activeSearch.EvidenceState -ne 'Searching') {
                Add-KeyValueLines -Lines $lines -Key 'Evidence' -Value "Cached ($capturedText)" -Width $Width -ValueColor $_C.OK
            }

            $importantProperties = Get-NotePropertyValue -Object $cachedEvidence -Name 'ImportantProperties'
            $hardwareIds = Get-NotePropertyValue -Object $importantProperties -Name 'DEVPKEY_Device_HardwareIds'
            if ($hardwareIds) {
                $firstHardwareId = $(if ($hardwareIds -is [array]) { $hardwareIds[0] } else { $hardwareIds })
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
                $firstCompatibleId = $(if ($compatibleIds -is [array]) { $compatibleIds[0] } else { $compatibleIds })
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
                    $rowColor = $(if ($rowColorName -and $_C.ContainsKey($rowColorName)) { $_C[$rowColorName] } else { $_C.White })
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
        $resultSearch = $(if ($null -ne $parentDevice -and $script:ActiveSearches.Contains($parentDevice.InstanceId)) { $script:ActiveSearches[$parentDevice.InstanceId] } else { $null })
        $isAgentResult = ([string]$SelectedRow.Name -match '^\[Agent:')

        if ($isAgentResult) {
            $lines.Add((New-SectionLine -Title 'Agent Result' -Width $Width))
            $stateText = ([string]$SelectedRow.Name -replace '^\[Agent:\s*[^\]]+\]\s*', '').Trim()
            if (-not [string]::IsNullOrWhiteSpace($stateText)) {
                $stateColor = $(if ($stateText -match 'Failed|Error|Cancelled') { $_C.Fail } elseif ($stateText -match 'Done') { $_C.OK } else { $_C.Warn })
                Add-KeyValueLines -Lines $lines -Key 'State' -Value $stateText -Width $Width -ValueColor $stateColor
            }

            $tracePath = $(if ($null -ne $resultSearch -and -not [string]::IsNullOrWhiteSpace($resultSearch.AgentTracePath)) {
                $resultSearch.AgentTracePath
            } else {
                Get-NotePropertyValue -Object $parentDevice -Name 'SearchTracePath'
            })
            if (-not [string]::IsNullOrWhiteSpace($tracePath)) {
                Add-WrappedPathLine -Lines $lines -Key 'Log' -Path $tracePath -Width $Width
            }
            $checkpointPath = $(if ($null -ne $resultSearch) {
                Get-NotePropertyValue -Object $resultSearch -Name 'AgentCheckpointPath'
            } else {
                Get-NotePropertyValue -Object $parentDevice -Name 'SearchCheckpointPath'
            })
            if (-not [string]::IsNullOrWhiteSpace($checkpointPath)) {
                Add-WrappedPathLine -Lines $lines -Key 'Checkpoint' -Path $checkpointPath -Width $Width
            }

            $detailText = $(if ($null -ne $resultSearch -and -not [string]::IsNullOrWhiteSpace($resultSearch.AgentVal)) {
                $resultSearch.AgentVal
            } else {
                Get-NotePropertyValue -Object $parentDevice -Name 'SearchDetail'
            })

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
            $evidenceText = $(if ($activeEvidenceCount -gt 0 -or $queuedEvidenceCount -gt 0) {
                "$activeEvidenceCount scanning / $queuedEvidenceCount queued / $cachedEvidenceCount cached"
            } else {
                "$cachedEvidenceCount cached"
            })
            $evidenceColor = $(if ($activeEvidenceCount -gt 0 -or $queuedEvidenceCount -gt 0) { $_C.Warn } elseif ($cachedEvidenceCount -gt 0) { $_C.OK } else { $_C.Dim })
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

            $aboveMessage = $(if ($viewTop -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Up) $viewTop more above$($_C.Reset)" } else { '' })
            Write-Host "$aboveMessage$($_C.EraseLn)"

            for ($index = $viewTop; $index -le $viewBot; $index++) {
                $model = $script:AvailableModels[$index]
                $check = $(if ($model.Selected) { "[x]" } else { "[ ]" })
                $checkColor = $(if ($model.Selected) { $_C.OK } else { $_C.Dim })
                $providerColor = $(if ($model.Provider -eq 'Gemini') { $_C.Info } else { $_C.Gold })

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
            $belowMessage = $(if ($below -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Down) $below more below$($_C.Reset)" } else { '' })
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
