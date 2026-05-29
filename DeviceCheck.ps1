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

# Perform local database lookup (usb.ids / pci.ids)
function Get-LocalDeviceLookup {
    param(
        [string]$InstanceId
    )
    
    $vendorId = $null
    $deviceId = $null
    $dbUrl = $null
    $dbName = $null
    
    if ($InstanceId -match 'USB\\VID_([0-9a-fA-F]{4})&PID_([0-9a-fA-F]{4})') {
        $vendorId = $Matches[1].ToLower()
        $deviceId = $Matches[2].ToLower()
        $dbUrl = "http://www.linux-usb.org/usb.ids"
        $dbName = "usb.ids"
    }
    elseif ($InstanceId -match 'PCI\\VEN_([0-9a-fA-F]{4})&DEV_([0-9a-fA-F]{4})') {
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
            Invoke-WebRequest -Uri $dbUrl -OutFile $dbPath -UserAgent "Mozilla/5.0" -TimeoutSec 15
        }
        
        $vendorName = $null
        $deviceName = $null
        $foundVendor = $false
        
        foreach ($line in Get-Content $dbPath) {
            if ($line.StartsWith("#") -or [string]::IsNullOrWhiteSpace($line)) { continue }
            
            # Vendor Match (starts with 4 hex, then space/tab, then name)
            if ($line -match "^([0-9a-fA-F]{4})\s+(.+)$") {
                if ($Matches[1].ToLower() -eq $vendorId) {
                    $vendorName = $Matches[2].Trim()
                    $foundVendor = $true
                    continue
                } else {
                    $foundVendor = $false
                }
            }
            
            # Device Match (starts with tab, then 4 hex, then space/tab, then name)
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
                Device = if ($deviceName) { $deviceName } else { "Unknown Device" }
            }
        }
    } catch {
        # Silent fail on network/parse error
    }
    return $null
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
        if ($results.Count -eq 3) { break } # Capture top 3 snippets for AI synthesis
    }
    
    if ($results.Count -eq 0) {
        $results.Add("No Web search descriptions found.")
    }
    return $results
}

# Call Google Gemini API to synthesize snippets (Free Tier)
function Get-GeminiSummary {
    param(
        [string]$HardwareId,
        [string[]]$Snippets
    )
    
    $apiKey = $env:GEMINI_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        return $null
    }
    
    $snippetsText = $Snippets -join "`n"
    $prompt = "You are a hardware expert. Below are search snippets for Hardware ID '$HardwareId'. Synthesize them into a single concise line (max 90 chars) specifying the exact manufacturer, model, and likely driver/troubleshooting tip. Do not use markdown, bolding, or lists. Keep it brief.`nSnippets:`n$snippetsText"
    
    $body = @{
        contents = @(
            @{
                parts = @(
                    @{ text = $prompt }
                )
            }
        )
    } | ConvertTo-Json -Depth 5
    
    $uri = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$apiKey"
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 10
        if ($response -and $response.candidates -and $response.candidates[0].content.parts[0].text) {
            $resultText = $response.candidates[0].content.parts[0].text
            return $resultText.Trim()
        }
    } catch {
        # Silent fallback
    }
    return $null
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
                            Name         = 'Searching databases & web...'
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
            
            # Highlight prefixes like [Local DB] or [Gemini AI] in gold, rest in white
            if ($text -match '^(\[(Local DB|Gemini AI|Web Snippet)\])(.*)$') {
                $tag = $Matches[1]
                $rest = $Matches[3]
                $tagColor = if ($tag -like '*Local*') { $_C.OK } elseif ($tag -like '*Gemini*') { $_C.Gold } else { $_C.Info }
                Write-Host "$($_C.Dim)$parentPrefix$branch$($_C.Reset)$tagColor$tag$($_C.Reset)$($_C.White)$rest$($_C.Reset)$($_C.EraseLn)"
            } else {
                Write-Host "$($_C.Dim)$parentPrefix$branch$($_C.Reset)$($_C.White)$text$($_C.Reset)$($_C.EraseLn)"
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
        New-UiShortcutSegment -Text 'Enter' -Color $_C.OK
        New-UiShortcutSegment -Text ' = expand/collapse   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'S' -Color $_C.Gold
        New-UiShortcutSegment -Text ' = search   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'Q / Esc' -Color $_C.Fail
        New-UiShortcutSegment -Text ' = exit' -Color $_C.Dim
    )
    Write-UiShortcutSegments -Segments $segments
    Write-Host "$($_E)[J" -NoNewline
    
    End-SyncRender
}

# Run full lookup pipeline for a device
function Invoke-DeviceLookup {
    param($Dev)
    
    $Dev.SearchStatus = 'Searching'
    $global:visibleRows = Update-VisibleRows
    Render-Frame
    
    $results = [System.Collections.Generic.List[string]]::new()
    
    # 1. Local Database Lookup (Instant & Offline)
    $localInfo = Get-LocalDeviceLookup -InstanceId $Dev.InstanceId
    if ($null -ne $localInfo) {
        $results.Add("[Local DB] Vendor: $($localInfo.Vendor) | Device: $($localInfo.Device)")
    }
    
    # 2. Web search snippets (DuckDuckGo HTML)
    $webSnippets = @()
    try {
        $webSnippets = Search-DeviceWeb -HardwareId $Dev.InstanceId
    } catch {}
    
    # 3. Gemini AI synthesis (Optional, if API key set)
    $geminiSummary = $null
    if ($null -ne $env:GEMINI_API_KEY -and $webSnippets.Count -gt 0) {
        $geminiSummary = Get-GeminiSummary -HardwareId $Dev.InstanceId -Snippets $webSnippets
    }
    
    if ($null -ne $geminiSummary) {
        $results.Insert(0, "[Gemini AI] $geminiSummary")
        if ($webSnippets.Count -gt 0) {
            $results.Add("[Web Snippet] $($webSnippets[0])")
        }
    } else {
        foreach ($snip in $webSnippets) {
            $results.Add("[Web Snippet] $snip")
        }
    }
    
    $Dev.SearchResults = $results
    $Dev.SearchStatus = 'Done'
    $global:visibleRows = Update-VisibleRows
    Render-Frame
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
                    Invoke-DeviceLookup -Dev $currentRow.Ref
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
                # Handle lowercase 's' keypress
                if ($key.KeyChar -eq 's') {
                    $currentRow = $visibleRows[$selectedIndex]
                    if ($currentRow.Type -eq 'Device') {
                        Invoke-DeviceLookup -Dev $currentRow.Ref
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
