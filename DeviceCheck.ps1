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
$classMap = @{}
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
    Write-Host "Detecting connected PnP hardware..." -ForegroundColor Cyan
    $pnpDevices = Get-PnpDevice -PresentOnly
    
    $grouped = @{}
    foreach ($dev in $pnpDevices) {
        $guid = if ($dev.ClassGuid) { $dev.ClassGuid.ToLower() } else { "" }
        $className = if ($classMap.ContainsKey($guid)) { $classMap[$guid] } else { $dev.Class }
        if ([string]::IsNullOrWhiteSpace($className)) {
            $className = "Other Devices"
        }
        
        $devInfo = [PSCustomObject]@{
            InstanceId             = $dev.InstanceId
            FriendlyName           = $dev.FriendlyName
            Class                  = $className
            Status                 = $dev.Status
            ConfigManagerErrorCode = $dev.ConfigManagerErrorCode
            IsProblem              = ($dev.ConfigManagerErrorCode -ne 0)
            SearchStatus           = $null      # $null, 'Searching', 'Done', 'Error'
            SearchResults          = @()        # Array of strings
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

# Perform DuckDuckGo search for device details
function Search-DeviceWeb {
    param([string]$HardwareId)
    
    # Extract base VID/PID or VEN/DEV
    $query = $HardwareId
    if ($HardwareId -match '^([^\\]+\\[^\\]+)') {
        $query = $Matches[1]
    }
    
    $escapedQuery = [Uri]::EscapeDataString($query)
    $uri = "https://html.duckduckgo.com/html/?q=$escapedQuery"
    
    $response = Invoke-WebRequest -Uri $uri -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -TimeoutSec 10
    $content = $response.Content
    
    $matches = [regex]::Matches($content, '<a class="result__snippet"[^>]*>(.*?)</a>')
    
    $results = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    
    foreach ($m in $matches) {
        $text = $m.Groups[1].Value -replace '<[^>]+>', '' # Strip HTML tags
        $text = $text -replace '&amp;', '&' -replace '&#92;', '\' -replace '&quot;', '"' -replace '&#x27;', "'" -replace '&lt;', '<' -replace '&gt;', '>'
        $text = $text.Trim()
        
        if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -lt 10) { continue }
        
        # Limit duplicates or very similar snippets
        $hash = $text.Substring(0, [Math]::Min(30, $text.Length))
        if ($seen.ContainsKey($hash)) { continue }
        $seen[$hash] = $true
        
        $results.Add($text)
        if ($results.Count -eq 2) { break } # Keep only top 2 snippets
    }
    
    if ($results.Count -eq 0) {
        $results.Add("No Web search descriptions found.")
    }
    return $results
}

# Helper to generate visible rows list
function Update-VisibleRows {
    $rows = [System.Collections.Generic.List[object]]::new()
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
                            Name         = 'Searching web...'
                            ParentIsLast = $isLast
                        })
                    }
                    elseif ($d.SearchStatus -eq 'Error') {
                        $rows.Add([PSCustomObject]@{
                            Type         = 'Status'
                            Name         = 'Search failed'
                            ParentIsLast = $isLast
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
                            })
                        }
                    }
                }
            }
        }
    }
    return $rows
}

# Render a single UI frame
function Render-Frame {
    # Calculate scrolling metrics
    try {
        $maxVisible = [Math]::Max(5, $Host.UI.RawUI.WindowSize.Height - 10)
    } catch {
        $maxVisible = 15
    }
    
    $viewTop = [Math]::Max(0, [Math]::Min($selectedIndex - [int]($maxVisible / 2), [Math]::Max(0, $visibleRows.Count - $maxVisible)))
    $viewBot = [Math]::Min($viewTop + $maxVisible - 1, $visibleRows.Count - 1)
    
    Begin-SyncRender
    try { Clear-Host } catch {}
    
    # Header
    Write-UiBanner -Title "DeviceCheck Manager" -Subtitle "Highlight a device and press 'S' to search for drivers/details on the web."
    Write-UiSection -Title "Device Connection Tree"
    Write-Host ''
    
    # Scrolling indicators above
    $aboveCount = $viewTop
    $aboveMessage = if ($aboveCount -gt 0) { "  $($_C.Dim)$([char]0x2191) $aboveCount more above$($_C.Reset)" } else { '' }
    Write-Host "$aboveMessage$($_C.EraseLn)"
    
    # Render visible rows
    for ($index = $viewTop; $index -le $viewBot; $index++) {
        $row = $visibleRows[$index]
        $isSelected = ($index -eq $selectedIndex)
        
        if ($row.Type -eq 'Category') {
            $icon = if ($row.IsExpanded) { [char]0x25BC } else { [char]0x25B6 } # Down or Right arrow
            $displayText = " $icon  $($row.Name)"
            
            if ($isSelected) {
                Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $displayText $($_C.Reset)$($_C.EraseLn)"
            } else {
                Write-Host "    $($_C.White)$displayText$($_C.Reset)$($_C.EraseLn)"
            }
        }
        elseif ($row.Type -eq 'Device') {
            $branch = if ($row.IsLast) { "└── " } else { "├── " }
            $warningIcon = if ($row.IsProblem) { "$($_C.Warn)[!]$($_C.Reset) " } else { "" }
            $displayText = "     $branch$warningIcon$($row.Name) [$($row.Class)]"
            
            if ($isSelected) {
                $cleanWarning = if ($row.IsProblem) { "[!] " } else { "" }
                $cleanText = "     $branch$cleanWarning$($row.Name) [$($row.Class)]"
                Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $cleanText $($_C.Reset)$($_C.EraseLn)"
            } else {
                Write-Host "$($_C.Dim)     $branch$($_C.Reset)$warningIcon$($_C.White)$($row.Name) $($_C.Dim)[$($row.Class)]$($_C.Reset)$($_C.EraseLn)"
            }
        }
        elseif ($row.Type -eq 'Status') {
            $parentPrefix = if ($row.ParentIsLast) { "          " } else { "     │    " }
            Write-Host "$($_C.Dim)$parentPrefix└── $($_C.Reset)$($_C.Warn)[$($row.Name)]$($_C.Reset)$($_C.EraseLn)"
        }
        elseif ($row.Type -eq 'Result') {
            $parentPrefix = if ($row.ParentIsLast) { "          " } else { "     │    " }
            $branch = if ($row.IsLastResult) { "└── " } else { "├── " }
            
            # Truncate result text to console width dynamically
            $maxTextLen = (Get-UiWidth) - $parentPrefix.Length - $branch.Length - 10
            $text = $row.Name
            if ($text.Length -gt $maxTextLen) {
                $text = $text.Substring(0, [Math]::Max(5, $maxTextLen - 3)) + "..."
            }
            
            Write-Host "$($_C.Dim)$parentPrefix$branch$($_C.Reset)$($_C.White)$text$($_C.Reset)$($_C.EraseLn)"
        }
    }
    
    # Scrolling indicators below
    $belowCount = $visibleRows.Count - 1 - $viewBot
    $belowMessage = if ($belowCount -gt 0) { "  $($_C.Dim)$([char]0x2193) $belowCount more below$($_C.Reset)" } else { '' }
    Write-Host "$belowMessage$($_C.EraseLn)"
    Write-Host "$($_C.EraseLn)"
    
    # Footer
    $segments = @(
        New-UiShortcutSegment -Text "$([char]0x2191)$([char]0x2193)" -Color $_C.White
        New-UiShortcutSegment -Text ' navigate   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'Enter' -Color $_C.OK
        New-UiShortcutSegment -Text ' = expand/collapse   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'S' -Color $_C.Gold
        New-UiShortcutSegment -Text ' = search web   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'Q / Esc' -Color $_C.Fail
        New-UiShortcutSegment -Text ' = exit' -Color $_C.Dim
    )
    Write-UiShortcutSegments -Segments $segments
    Write-Host "$($_E)[J" -NoNewline
    
    End-SyncRender
}

# Initial categories detection
$categories = Get-DeviceCategories
$selectedIndex = 0
$running = $true

try {
    [Console]::CursorVisible = $false
    
    while ($running) {
        Lock-ViewportToWindow
        
        # Calculate current visible rows
        $visibleRows = Update-VisibleRows
        
        # Clamp selected index to selectable types (Category / Device)
        if ($visibleRows.Count -eq 0) {
            $selectedIndex = 0
        } else {
            $selectedIndex = [Math]::Max(0, [Math]::Min($selectedIndex, $visibleRows.Count - 1))
            while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Category', 'Device')) {
                $selectedIndex--
            }
        }
        
        # Render viewport
        Render-Frame
        
        # Key Handling
        $key = Read-ConsoleKey
        switch ($key.Key) {
            'UpArrow' {
                if ($selectedIndex -gt 0) {
                    $idx = $selectedIndex - 1
                    # Skip non-selectable rows
                    while ($idx -gt 0 -and $visibleRows[$idx].Type -notin @('Category', 'Device')) {
                        $idx--
                    }
                    if ($visibleRows[$idx].Type -in @('Category', 'Device')) {
                        $selectedIndex = $idx
                    }
                }
            }
            'DownArrow' {
                if ($selectedIndex -lt ($visibleRows.Count - 1)) {
                    $idx = $selectedIndex + 1
                    # Skip non-selectable rows
                    while ($idx -lt ($visibleRows.Count - 1) -and $visibleRows[$idx].Type -notin @('Category', 'Device')) {
                        $idx++
                    }
                    if ($visibleRows[$idx].Type -in @('Category', 'Device')) {
                        $selectedIndex = $idx
                    }
                }
            }
            'PageUp' {
                $selectedIndex = [Math]::Max(0, $selectedIndex - 10)
                while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Category', 'Device')) {
                    $selectedIndex--
                }
            }
            'PageDown' {
                $selectedIndex = [Math]::Min($visibleRows.Count - 1, $selectedIndex + 10)
                while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Category', 'Device')) {
                    $selectedIndex--
                }
            }
            'Home' {
                $selectedIndex = 0
            }
            'End' {
                $selectedIndex = $visibleRows.Count - 1
                while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Category', 'Device')) {
                    $selectedIndex--
                }
            }
            'RightArrow' {
                $currentRow = $visibleRows[$selectedIndex]
                if ($currentRow.Type -eq 'Category') {
                    $currentRow.Ref.IsExpanded = $true
                }
            }
            'LeftArrow' {
                $currentRow = $visibleRows[$selectedIndex]
                if ($currentRow.Type -eq 'Category') {
                    $currentRow.Ref.IsExpanded = $false
                } elseif ($currentRow.Type -eq 'Device') {
                    $parentCatName = $currentRow.Class
                    $parentIndex = -1
                    for ($j = 0; $j -lt $visibleRows.Count; $j++) {
                        if ($visibleRows[$j].Type -eq 'Category' -and $visibleRows[$j].Name -eq $parentCatName) {
                            $parentIndex = $j
                            break
                        }
                    }
                    if ($parentIndex -ne -1) {
                        $selectedIndex = $parentIndex
                        $visibleRows[$parentIndex].Ref.IsExpanded = $false
                    }
                }
            }
            'Enter' {
                $currentRow = $visibleRows[$selectedIndex]
                if ($currentRow.Type -eq 'Category') {
                    $currentRow.Ref.IsExpanded = -not $currentRow.Ref.IsExpanded
                }
            }
            'S' {
                $currentRow = $visibleRows[$selectedIndex]
                if ($currentRow.Type -eq 'Device') {
                    $dev = $currentRow.Ref
                    $dev.SearchStatus = 'Searching'
                    
                    # Force redraw for searching state
                    $visibleRows = Update-VisibleRows
                    Render-Frame
                    
                    try {
                        $results = Search-DeviceWeb -HardwareId $dev.InstanceId
                        $dev.SearchResults = $results
                        $dev.SearchStatus = 'Done'
                    } catch {
                        $dev.SearchStatus = 'Error'
                    }
                    
                    # Refresh rows
                    $visibleRows = Update-VisibleRows
                }
            }
            'Escape' {
                $running = $false
            }
            'q' {
                $running = $false
            }
            'ResizeEvent' {
                continue
            }
            default {
                # Handle lowercase 's' keypress as well
                if ($key.KeyChar -eq 's') {
                    $currentRow = $visibleRows[$selectedIndex]
                    if ($currentRow.Type -eq 'Device') {
                        $dev = $currentRow.Ref
                        $dev.SearchStatus = 'Searching'
                        
                        $visibleRows = Update-VisibleRows
                        Render-Frame
                        
                        try {
                            $results = Search-DeviceWeb -HardwareId $dev.InstanceId
                            $dev.SearchResults = $results
                            $dev.SearchStatus = 'Done'
                        } catch {
                            $dev.SearchStatus = 'Error'
                        }
                        
                        $visibleRows = Update-VisibleRows
                    }
                }
            }
        }
    }
}
finally {
    # Restore Host Settings
    Restore-TuiHost
    Write-Host 'DeviceCheck closed.'
}
