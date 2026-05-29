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

# Initial detection
$categories = Get-DeviceCategories

# Main Interactive Loop
$selectedIndex = 0
$running = $true

try {
    [Console]::CursorVisible = $false
    
    while ($running) {
        Lock-ViewportToWindow
        
        # Calculate current visible rows dynamically based on collapse/expand states
        $visibleRows = [System.Collections.Generic.List[object]]::new()
        foreach ($cat in $categories) {
            $visibleRows.Add([PSCustomObject]@{
                Type       = 'Category'
                Name       = $cat.Name
                IsExpanded = $cat.IsExpanded
                Ref        = $cat
            })
            if ($cat.IsExpanded) {
                $devicesCount = $cat.Devices.Count
                for ($i = 0; $i -lt $devicesCount; $i++) {
                    $isLast = ($i -eq ($devicesCount - 1))
                    $visibleRows.Add([PSCustomObject]@{
                        Type     = 'Device'
                        Name     = $cat.Devices[$i].FriendlyName
                        Class    = $cat.Devices[$i].Class
                        IsLast   = $isLast
                        IsProblem = $cat.Devices[$i].IsProblem
                        Ref      = $cat.Devices[$i]
                    })
                }
            }
        }
        
        # Clamp selected index
        if ($visibleRows.Count -eq 0) {
            $selectedIndex = 0
        } else {
            $selectedIndex = [Math]::Max(0, [Math]::Min($selectedIndex, $visibleRows.Count - 1))
        }
        
        # Calculate scrolling metrics
        try {
            $maxVisible = [Math]::Max(5, $Host.UI.RawUI.WindowSize.Height - 10)
        } catch {
            $maxVisible = 15
        }
        
        $viewTop = [Math]::Max(0, [Math]::Min($selectedIndex - [int]($maxVisible / 2), [Math]::Max(0, $visibleRows.Count - $maxVisible)))
        $viewBot = [Math]::Min($viewTop + $maxVisible - 1, $visibleRows.Count - 1)
        
        # Synchronized Render Frame
        Begin-SyncRender
        try { Clear-Host } catch {}
        
        # Header
        Write-UiBanner -Title "DeviceCheck Manager" -Subtitle "Present PnP hardware tree. Select categories to expand/collapse."
        Write-UiSection -Title "Device Connection Tree"
        Write-Host ''
        
        # Scrolling indicators
        $aboveCount = $viewTop
        $aboveMessage = if ($aboveCount -gt 0) { "  $($_C.Dim)$([char]0x2191) $aboveCount more above$($_C.Reset)" } else { '' }
        Write-Host "$aboveMessage$($_C.EraseLn)"
        
        # Render visible rows
        for ($index = $viewTop; $index -le $viewBot; $index++) {
            $row = $visibleRows[$index]
            $isSelected = ($index -eq $selectedIndex)
            
            # Format row representation
            if ($row.Type -eq 'Category') {
                $icon = if ($row.IsExpanded) { [char]0x25BC } else { [char]0x25B6 } # Down or Right arrow
                $displayText = " $icon  $($row.Name)"
                
                if ($isSelected) {
                    Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $displayText $($_C.Reset)$($_C.EraseLn)"
                } else {
                    Write-Host "    $($_C.White)$displayText$($_C.Reset)$($_C.EraseLn)"
                }
            } else {
                # Device node prefix (tree branches)
                $branch = if ($row.IsLast) { "└── " } else { "├── " }
                $warningIcon = if ($row.IsProblem) { "$($_C.Warn)[!]$($_C.Reset) " } else { "" }
                $displayText = "     $branch$warningIcon$($row.Name) [$($row.Class)]"
                
                if ($isSelected) {
                    # Strip ANSI reset from warningIcon inside selected background
                    $cleanWarning = if ($row.IsProblem) { "[!] " } else { "" }
                    $cleanText = "     $branch$cleanWarning$($row.Name) [$($row.Class)]"
                    Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $cleanText $($_C.Reset)$($_C.EraseLn)"
                } else {
                    Write-Host "$($_C.Dim)     $branch$($_C.Reset)$warningIcon$($_C.White)$($row.Name) $($_C.Dim)[$($row.Class)]$($_C.Reset)$($_C.EraseLn)"
                }
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
            New-UiShortcutSegment -Text 'Enter / ' -Color $_C.OK
            New-UiShortcutSegment -Text "$([char]0x2190)$([char]0x2192)" -Color $_C.White
            New-UiShortcutSegment -Text ' expand/collapse   ' -Color $_C.Dim
            New-UiShortcutSegment -Text 'Q / Esc' -Color $_C.Fail
            New-UiShortcutSegment -Text ' = exit' -Color $_C.Dim
        )
        Write-UiShortcutSegments -Segments $segments
        Write-Host "$($_E)[J" -NoNewline
        
        End-SyncRender
        
        # Key Handling
        $key = Read-ConsoleKey
        switch ($key.Key) {
            'UpArrow' {
                if ($selectedIndex -gt 0) { $selectedIndex-- }
            }
            'DownArrow' {
                if ($selectedIndex -lt ($visibleRows.Count - 1)) { $selectedIndex++ }
            }
            'PageUp' {
                $selectedIndex = [Math]::Max(0, $selectedIndex - $maxVisible)
            }
            'PageDown' {
                $selectedIndex = [Math]::Min($visibleRows.Count - 1, $selectedIndex + $maxVisible)
            }
            'Home' {
                $selectedIndex = 0
            }
            'End' {
                $selectedIndex = $visibleRows.Count - 1
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
                    # Optional extra polish: move selection to the parent category and collapse it
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
            'Escape' {
                $running = $false
            }
            'q' {
                $running = $false
            }
            'ResizeEvent' {
                continue
            }
        }
    }
}
finally {
    # Restore Host Settings
    Restore-TuiHost
    Write-Host 'DeviceCheck closed.'
}
