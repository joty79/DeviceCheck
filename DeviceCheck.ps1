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
                            Name         = if ($script:CurrentLoadingText) { $script:CurrentLoadingText } else { 'Searching databases & web...' }
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
        # Reduce window height dynamically to accommodate details panel
        $maxVisible = [Math]::Max(4, $Host.UI.RawUI.WindowSize.Height - 16)
    } catch {
        $maxVisible = 12
    }
    
    $viewTop = [Math]::Max(0, [Math]::Min($selectedIndex - [int]($maxVisible / 2), [Math]::Max(0, $script:visibleRows.Count - $maxVisible)))
    $viewBot = [Math]::Min($viewTop + $maxVisible - 1, $script:visibleRows.Count - 1)
    
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
        $row = $script:visibleRows[$index]
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
            if ($text -match '^(\[(Local DB|Gemini AI|Gemini Error|Web Snippet)\])(.*)$') {
                $tag = $Matches[1]
                $rest = $Matches[3]
                $tagColor = if ($tag -like '*Local*') {
                    $_C.OK
                } elseif ($tag -like '*Error*') {
                    $_C.Fail
                } elseif ($tag -like '*Gemini*') {
                    $_C.Gold
                } else {
                    $_C.Info
                }
                
                if ($isSelected) {
                    Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $parentPrefix$branch$tag$rest $($_C.Reset)$($_C.EraseLn)"
                } else {
                    Write-Host "$($_C.Dim)$parentPrefix$branch$($_C.Reset)$tagColor$tag$($_C.Reset)$($_C.White)$rest$($_C.Reset)$($_C.EraseLn)"
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
    $belowMessage = if ($belowCount -gt 0) { "  $($_C.Dim)$([char]0x2193) $belowCount more below$($_C.Reset)" } else { '' }
    Write-Host "$belowMessage$($_C.EraseLn)"
    
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    #  DETAILS INSPECTOR PANEL
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    $selectedRow = $script:visibleRows[$selectedIndex]
    if ($selectedRow.Type -eq 'Device') {
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
        
        $statusText = if ($errCode -eq 0) {
            "$($_C.OK)OK ($errDesc)$($_C.Reset)"
        } else {
            "$($_C.Fail)Error (Code ${errCode}: $errDesc)$($_C.Reset)"
        }
        
        Write-Host "  $($_C.Dim)Status       :$($_C.Reset) $statusText$($_C.EraseLn)"
    }
    elseif ($selectedRow.Type -eq 'Result') {
        # Select title prefix based on tag
        $titleText = "Detailed Info"
        if ($selectedRow.Name -match '^\[(Local DB|Gemini AI|Gemini Error|Web Snippet)\]') {
            $titleText = $Matches[1]
        }
        Write-UiSection -Title $titleText -Icon ""
        
        $cleanText = $selectedRow.Name -replace '^\[(Local DB|Gemini AI|Gemini Error|Web Snippet)\]\s*', ''
        
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
                $currentLine = if ($currentLine -eq "  ") { "  $word" } else { "$currentLine $word" }
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
        Write-Host "$($_C.EraseLn)"
        Write-Host "$($_C.EraseLn)"
    }
    
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

# Run full lookup pipeline for a device (Asynchronously with loading spinner)
function Invoke-DeviceLookup {
    param($Dev)
    
    $Dev.SearchStatus = 'Searching'
    
    # Resolve the API Key on the main thread first to pass it to the background thread
    $apiKey = $env:GEMINI_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey)) { $apiKey = $env:GOOGLE_API_KEY }
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        try {
            $apiKey = (Get-ItemProperty -Path 'HKCU:\Environment' -ErrorAction SilentlyContinue).GOOGLE_API_KEY
        } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        try {
            $apiKey = (Get-ItemProperty -Path 'HKCU:\Environment' -ErrorAction SilentlyContinue).GEMINI_API_KEY
        } catch {}
    }
    
    $openRouterKey = $env:OPENROUTER_API_KEY
    if ([string]::IsNullOrWhiteSpace($openRouterKey)) {
        try {
            $openRouterKey = (Get-ItemProperty -Path 'HKCU:\Environment' -ErrorAction SilentlyContinue).OPENROUTER_API_KEY
        } catch {}
    }
    
    # Start background execution
    $ps = [PowerShell]::Create()
    $null = $ps.AddScript({
        param($InstanceId, $resolvedApiKey, $resolvedOpenRouterKey)
        
        # Define local helper functions inside the background thread
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
            
            # Use TEMP folder inside runspace context
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
                        Device = if ($deviceName) { $deviceName } else { "Unknown Device" }
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
            
            $response = Invoke-WebRequest -Uri $uri -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -TimeoutSec 15
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
        
        # Pipeline Execution:
        $results = [System.Collections.Generic.List[string]]::new()
        
        $localInfo = Get-LocalDeviceLookup -InstId $InstanceId
        if ($null -ne $localInfo) {
            $results.Add("[Local DB] Vendor: $($localInfo.Vendor) | Device: $($localInfo.Device)")
        }
        
        $webSnippets = @()
        try {
            $webSnippets = Search-DeviceWeb -HwId $InstanceId
        } catch {}
        
        $geminiSummary = $null
        $geminiError = $null
        $usedBackup = $false
        
        if ($webSnippets.Count -gt 0) {
            $prompt = "You are a hardware expert. Below are search snippets for Hardware ID '$InstanceId'. Synthesize them into a single concise line (max 90 chars) specifying the exact manufacturer, model, and likely driver/troubleshooting tip. Do not use markdown, bolding, or lists. Keep it brief.`nSnippets:`n" + ($webSnippets -join "`n")
            
            # 1. Try Google Gemini API first if key is available
            if ($resolvedApiKey) {
                $body = @{
                    contents = @(
                        @{ parts = @( @{ text = $prompt } ) }
                    )
                } | ConvertTo-Json -Depth 5
                
                $uri = "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent?key=$resolvedApiKey"
                
                try {
                    $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 30
                    if ($response -and $response.candidates -and $response.candidates[0].content.parts[0].text) {
                        $geminiSummary = $response.candidates[0].content.parts[0].text.Trim()
                    } else {
                        $geminiError = "Empty response from Gemini API."
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
                    $geminiError = $msg
                }
            } else {
                $geminiError = "No Gemini API Key found (set GOOGLE_API_KEY)."
            }
            
            # 2. Try OpenRouter backup if Gemini failed or key was missing, and OpenRouter key is available
            if ([string]::IsNullOrWhiteSpace($geminiSummary) -and $resolvedOpenRouterKey) {
                $orBody = @{
                    model = "google/gemini-2.5-flash:free"
                    messages = @(
                        @{ role = "user"; content = $prompt }
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
                        $geminiSummary = $response.choices[0].message.content.Trim()
                        $geminiError = $null
                        $usedBackup = $true
                    } else {
                        $geminiError = "Empty response from OpenRouter API."
                    }
                } catch {
                    $geminiError = "OpenRouter backup failed: " + $_.Exception.Message
                }
            }
        } else {
            $geminiError = "No search snippets gathered to synthesize."
        }
        
        if ($null -ne $geminiSummary) {
            $prefix = if ($usedBackup) { "[Gemini AI] (Backup)" } else { "[Gemini AI]" }
            $results.Insert(0, "$prefix $geminiSummary")
            if ($webSnippets.Count -gt 0) {
                $results.Add("[Web Snippet] $($webSnippets[0])")
            }
        } else {
            if ($null -ne $geminiError) {
                $results.Insert(0, "[Gemini Error] $geminiError")
            }
            foreach ($snip in $webSnippets) {
                $results.Add("[Web Snippet] $snip")
            }
        }
        
        return $results
    })
    $null = $ps.AddArgument($Dev.InstanceId)
    $null = $ps.AddArgument($apiKey)
    $null = $ps.AddArgument($openRouterKey)
    
    $asyncResult = $ps.BeginInvoke()
    
    # Spinner animation loop on the main thread
    $spinner = @('|', '/', '-', '\')
    $spIndex = 0
    
    while (-not $asyncResult.IsCompleted) {
        $spText = $spinner[$spIndex]
        $spIndex = ($spIndex + 1) % $spinner.Count
        
        $script:CurrentLoadingText = "Searching databases & web... $spText"
        $script:visibleRows = Update-VisibleRows
        Render-Frame
        
        Start-Sleep -Milliseconds 150
    }
    
    $script:CurrentLoadingText = $null
    
    # Retrieve results
    try {
        $results = $ps.EndInvoke($asyncResult)
        $Dev.SearchResults = $results
        $Dev.SearchStatus = 'Done'
    } catch {
        $Dev.SearchStatus = 'Error'
    }
    $ps.Dispose()
    
    $script:visibleRows = Update-VisibleRows
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
        $script:visibleRows = Update-VisibleRows
        
        # Clamp selected index to selectable types (Category / Device / Result)
        if ($visibleRows.Count -eq 0) {
            $selectedIndex = 0
        } else {
            $selectedIndex = [Math]::Max(0, [Math]::Min($selectedIndex, $visibleRows.Count - 1))
            while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Category', 'Device', 'Result')) {
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
                    while ($idx -gt 0 -and $visibleRows[$idx].Type -notin @('Category', 'Device', 'Result')) {
                        $idx--
                    }
                    if ($visibleRows[$idx].Type -in @('Category', 'Device', 'Result')) {
                        $selectedIndex = $idx
                    }
                }
            }
            'DownArrow' {
                if ($selectedIndex -lt ($visibleRows.Count - 1)) {
                    $idx = $selectedIndex + 1
                    while ($idx -lt ($visibleRows.Count - 1) -and $visibleRows[$idx].Type -notin @('Category', 'Device', 'Result')) {
                        $idx++
                    }
                    if ($visibleRows[$idx].Type -in @('Category', 'Device', 'Result')) {
                        $selectedIndex = $idx
                    }
                }
            }
            'PageUp' {
                $selectedIndex = [Math]::Max(0, $selectedIndex - 10)
                while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Category', 'Device', 'Result')) {
                    $selectedIndex--
                }
            }
            'PageDown' {
                $selectedIndex = [Math]::Min($visibleRows.Count - 1, $selectedIndex + 10)
                while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Category', 'Device', 'Result')) {
                    $selectedIndex--
                }
            }
            'Home' {
                $selectedIndex = 0
            }
            'End' {
                $selectedIndex = $visibleRows.Count - 1
                while ($selectedIndex -gt 0 -and $visibleRows[$selectedIndex].Type -notin @('Category', 'Device', 'Result')) {
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
