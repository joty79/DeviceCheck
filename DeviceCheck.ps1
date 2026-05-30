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
            
            # Highlight prefixes like [Local DB] or [Gemini: ...] or [OpenRouter: ...]
            if ($text -match '^(\[([^\]]+)\])(.*)$') {
                $tag = $Matches[1]
                $tagName = $Matches[2]
                $rest = $Matches[3]
                $tagColor = if ($tagName -like '*Error*') {
                    $_C.Fail
                } elseif ($tagName -like '*Gemini*') {
                    $_C.Info    # Blue for Gemini
                } elseif ($tagName -like '*nvidia*' -or $tagName -like '*nemotron*') {
                    $_C.OK      # Green for Nvidia/Nemotron
                } elseif ($tagName -like '*Local*') {
                    $_C.Gold
                } elseif ($tagName -like '*Web*') {
                    $_C.Warn
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
        if ($selectedRow.Name -match '^\[([^\]]+)\]') {
            $titleText = $Matches[1]
        }
        Write-UiSection -Title $titleText -Icon ""
        
        $cleanText = $selectedRow.Name -replace '^\[[^\]]+\]\s*', ''
        
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
    
    $Dev.SearchStatus = 'Done' # Set to Done immediately so we can render individual progress!
    $Dev.SearchResults = [System.Collections.Generic.List[string]]::new()
    
    $geminiModel = "gemini-2.5-flash"
    $openRouterModel = "nvidia/llama-3.1-nemotron-70b-instruct:free"
    
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
    
    # Initialize states: 'Searching', 'Waiting', 'Done', 'Error', 'None'
    $localState = 'Searching'
    $webState = 'Searching'
    $geminiState = if ($apiKey) { 'Waiting' } else { 'None' }
    $openRouterState = if ($openRouterKey) { 'Waiting' } else { 'None' }
    
    $localVal = $null
    $webVal = $null
    $webSnippets = @()
    $geminiVal = $null
    $openRouterVal = $null
    
    # Pre-populate search rows showing status
    $newResults = [System.Collections.Generic.List[string]]::new()
    if ($geminiState -eq 'Waiting') { $newResults.Add("[Gemini: $geminiModel] (Waiting for web search...)") }
    if ($openRouterState -eq 'Waiting') { $newResults.Add("[OpenRouter: $openRouterModel] (Waiting for web search...)") }
    if ($localState -eq 'Searching') { $newResults.Add("[Local DB] (Searching...)") }
    if ($webState -eq 'Searching') { $newResults.Add("[Web Snippet] (Searching...)") }
    $Dev.SearchResults = $newResults
    
    # 1. Start background execution for Web and Local Search
    $psWeb = [PowerShell]::Create()
    $null = $psWeb.AddScript({
        param($InstanceId)
        
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
        
        # Local lookup execution
        $localInfo = Get-LocalDeviceLookup -InstId $InstanceId
        if ($null -ne $localInfo) {
            Write-Output ([PSCustomObject]@{ Source = 'Local'; Result = "[Local DB] Vendor: $($localInfo.Vendor) | Device: $($localInfo.Device)" })
        }
        
        # Web lookup execution
        $webSnippets = @()
        try {
            $webSnippets = Search-DeviceWeb -HwId $InstanceId
            if ($webSnippets.Count -gt 0) {
                Write-Output ([PSCustomObject]@{ Source = 'Web'; Snippets = $webSnippets; Result = $webSnippets[0] })
            } else {
                Write-Output ([PSCustomObject]@{ Source = 'Web'; Snippets = @(); Result = $null })
            }
        } catch {
            Write-Output ([PSCustomObject]@{ Source = 'Web'; Snippets = @(); Result = $null })
        }
        return $null
    })
    $null = $psWeb.AddArgument($Dev.InstanceId)
    
    $outputWeb = [System.Management.Automation.PSDataCollection[PSObject]]::new()
    $asyncWeb = $psWeb.BeginInvoke($outputWeb)
    
    $psGemini = $null
    $asyncGemini = $null
    $outputGemini = $null
    $geminiStarted = $false
    
    $psOpenRouter = $null
    $asyncOpenRouter = $null
    $outputOpenRouter = $null
    $openRouterStarted = $false
    
    # Spinner animation loop on the main thread
    $spinner = @('|', '/', '-', '\')
    $spIndex = 0
    
    try {
        while (
            $null -ne $psWeb -or
            $null -ne $psGemini -or
            $null -ne $psOpenRouter -or
            $geminiState -eq 'Waiting' -or
            $openRouterState -eq 'Waiting'
        ) {
            $spChar = $spinner[$spIndex]
            $spIndex = ($spIndex + 1) % $spinner.Count
            
            # 1. Process Web / Local Runspace Output
            if ($null -ne $psWeb) {
                while ($outputWeb.Count -gt 0) {
                    $data = $outputWeb[0]
                    $outputWeb.RemoveAt(0)
                    if ($null -ne $data) {
                        if ($data.Source -eq 'Local') {
                            $localVal = $data.Result
                            $localState = 'Done'
                        }
                        elseif ($data.Source -eq 'Web') {
                            $webVal = $data.Result
                            if ($data.Snippets) {
                                $webSnippets = $data.Snippets
                            }
                            $webState = 'Done'
                        }
                    }
                }
                
                if ($asyncWeb.IsCompleted) {
                    $webState = 'Done'
                    if ($localState -eq 'Searching') { $localState = 'Done' }
                    try {
                        $null = $psWeb.EndInvoke($asyncWeb)
                    } catch {}
                    $psWeb.Dispose()
                    $psWeb = $null
                    $asyncWeb = $null
                }
            }
            
            # 2. Trigger AI Runspaces if Web search is Done and keys are available
            if ($webState -eq 'Done') {
                $prompt = "You are a hardware expert. Below are search snippets for Hardware ID '$($Dev.InstanceId)'. Synthesize them into a single concise line (max 90 chars) specifying the exact manufacturer, model, and likely driver/troubleshooting tip. Do not use markdown, bolding, or lists. Keep it brief.`nSnippets:`n" + ($webSnippets -join "`n")
                
                # Start Gemini
                if ($geminiState -eq 'Waiting' -and -not $geminiStarted) {
                    $geminiStarted = $true
                    $geminiState = 'Searching'
                    
                    $psGemini = [PowerShell]::Create()
                    $null = $psGemini.AddScript({
                        param($PromptText, $resolvedApiKey, $resolvedModelName)
                        $body = @{
                            contents = @(
                                @{ parts = @( @{ text = $PromptText } ) }
                            )
                        } | ConvertTo-Json -Depth 5
                        
                        $uri = "https://generativelanguage.googleapis.com/v1beta/models/$($resolvedModelName):generateContent?key=$resolvedApiKey"
                        
                        try {
                            $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 30
                            if ($response -and $response.candidates -and $response.candidates[0].content.parts[0].text) {
                                $geminiSummary = $response.candidates[0].content.parts[0].text.Trim()
                                return [PSCustomObject]@{ Status = 'Done'; Result = $geminiSummary }
                            } else {
                                return [PSCustomObject]@{ Status = 'Error'; Result = "Empty response from Gemini API." }
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
                            return [PSCustomObject]@{ Status = 'Error'; Result = $msg }
                        }
                    })
                    $null = $psGemini.AddArgument($prompt)
                    $null = $psGemini.AddArgument($apiKey)
                    $null = $psGemini.AddArgument($geminiModel)
                    
                    $outputGemini = [System.Management.Automation.PSDataCollection[PSObject]]::new()
                    $asyncGemini = $psGemini.BeginInvoke($outputGemini)
                }
                
                # Start OpenRouter
                if ($openRouterState -eq 'Waiting' -and -not $openRouterStarted) {
                    $openRouterStarted = $true
                    $openRouterState = 'Searching'
                    
                    $psOpenRouter = [PowerShell]::Create()
                    $null = $psOpenRouter.AddScript({
                        param($PromptText, $resolvedOpenRouterKey, $resolvedModelName)
                        $orBody = @{
                            model = $resolvedModelName
                            messages = @(
                                @{ role = "user"; content = $PromptText }
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
                                $openRouterSummary = $response.choices[0].message.content.Trim()
                                return [PSCustomObject]@{ Status = 'Done'; Result = $openRouterSummary }
                            } else {
                                return [PSCustomObject]@{ Status = 'Error'; Result = "Empty response from OpenRouter API." }
                            }
                        } catch {
                            return [PSCustomObject]@{ Status = 'Error'; Result = $_.Exception.Message }
                        }
                    })
                    $null = $psOpenRouter.AddArgument($prompt)
                    $null = $psOpenRouter.AddArgument($openRouterKey)
                    $null = $psOpenRouter.AddArgument($openRouterModel)
                    
                    $outputOpenRouter = [System.Management.Automation.PSDataCollection[PSObject]]::new()
                    $asyncOpenRouter = $psOpenRouter.BeginInvoke($outputOpenRouter)
                }
                
                # If both were not configured, ensure state doesn't stay Waiting
                if ($geminiState -eq 'Waiting') { $geminiState = 'None' }
                if ($openRouterState -eq 'Waiting') { $openRouterState = 'None' }
            }
            
            # 3. Process Gemini Output
            if ($null -ne $psGemini) {
                while ($outputGemini.Count -gt 0) {
                    $data = $outputGemini[0]
                    $outputGemini.RemoveAt(0)
                    if ($null -ne $data) {
                        $geminiState = $data.Status
                        $geminiVal = $data.Result
                    }
                }
                
                if ($asyncGemini.IsCompleted) {
                    try {
                        $resList = $psGemini.EndInvoke($asyncGemini)
                        if ($geminiState -eq 'Searching') {
                            if ($resList.Count -gt 0 -and $null -ne $resList[0]) {
                                $geminiState = $resList[0].Status
                                $geminiVal = $resList[0].Result
                            } else {
                                $geminiState = 'Error'
                                $geminiVal = 'Empty response from Gemini API.'
                            }
                        }
                    } catch {
                        $geminiState = 'Error'
                        $geminiVal = $_.Exception.Message
                    }
                    $psGemini.Dispose()
                    $psGemini = $null
                    $asyncGemini = $null
                }
            }
            
            # 4. Process OpenRouter Output
            if ($null -ne $psOpenRouter) {
                while ($outputOpenRouter.Count -gt 0) {
                    $data = $outputOpenRouter[0]
                    $outputOpenRouter.RemoveAt(0)
                    if ($null -ne $data) {
                        $openRouterState = $data.Status
                        $openRouterVal = $data.Result
                    }
                }
                
                if ($asyncOpenRouter.IsCompleted) {
                    try {
                        $resList = $psOpenRouter.EndInvoke($asyncOpenRouter)
                        if ($openRouterState -eq 'Searching') {
                            if ($resList.Count -gt 0 -and $null -ne $resList[0]) {
                                $openRouterState = $resList[0].Status
                                $openRouterVal = $resList[0].Result
                            } else {
                                $openRouterState = 'Error'
                                $openRouterVal = 'Empty response from OpenRouter API.'
                            }
                        }
                    } catch {
                        $openRouterState = 'Error'
                        $openRouterVal = $_.Exception.Message
                    }
                    $psOpenRouter.Dispose()
                    $psOpenRouter = $null
                    $asyncOpenRouter = $null
                }
            }
            
            # Rebuild the visible search result rows
            $newResults = [System.Collections.Generic.List[string]]::new()
            
            # Gemini display
            if ($geminiState -eq 'Waiting') {
                $newResults.Add("[Gemini: $geminiModel] (Waiting for web search...)")
            } elseif ($geminiState -eq 'Searching') {
                $newResults.Add("[Gemini: $geminiModel] (Searching... $spChar)")
            } elseif ($geminiState -eq 'Done') {
                $newResults.Add("[Gemini: $geminiModel] $geminiVal")
            } elseif ($geminiState -eq 'Error') {
                $newResults.Add("[Gemini Error] $geminiVal")
            }
            
            # OpenRouter display
            if ($openRouterState -eq 'Waiting') {
                $newResults.Add("[OpenRouter: $openRouterModel] (Waiting for web search...)")
            } elseif ($openRouterState -eq 'Searching') {
                $newResults.Add("[OpenRouter: $openRouterModel] (Searching... $spChar)")
            } elseif ($openRouterState -eq 'Done') {
                $newResults.Add("[OpenRouter: $openRouterModel] $openRouterVal")
            } elseif ($openRouterState -eq 'Error') {
                $newResults.Add("[OpenRouter Error] $openRouterVal")
            }
            
            # Local DB display
            if ($localState -eq 'Searching') {
                $newResults.Add("[Local DB] (Searching... $spChar)")
            } elseif ($localState -eq 'Done' -and $localVal) {
                $newResults.Add($localVal)
            }
            
            # Web Snippet display
            if ($webState -eq 'Searching') {
                $newResults.Add("[Web Snippet] (Searching... $spChar)")
            } elseif ($webState -eq 'Done' -and $webVal) {
                $newResults.Add("[Web Snippet] $webVal")
            }
            
            $Dev.SearchResults = $newResults
            $script:visibleRows = Update-VisibleRows
            Render-Frame
            
            Start-Sleep -Milliseconds 150
        }
    } catch {
        $Dev.SearchStatus = 'Error'
    } finally {
        # Safe cleanup in case of exceptions or early exit
        if ($null -ne $psWeb) { try { $psWeb.Dispose() } catch {} }
        if ($null -ne $psGemini) { try { $psGemini.Dispose() } catch {} }
        if ($null -ne $psOpenRouter) { try { $psOpenRouter.Dispose() } catch {} }
    }
    
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
