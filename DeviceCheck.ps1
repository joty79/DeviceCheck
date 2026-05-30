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
$script:ActiveSearches = [ordered]@{}
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
                            ParentDevice = $d
                        })
                    }
                    elseif ($d.SearchStatus -eq 'Error') {
                        $rows.Add([PSCustomObject]@{
                            Type         = 'Status'
                            Name         = 'Search failed'
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
            
            $text = $row.Name
            $isSubResult = $text.StartsWith("  ")
            
            if ($isSubResult) {
                $text = $text.Substring(2)
                $branch = if ($row.IsLastResult) { "    └── " } else { "│   └── " }
            } else {
                $branch = if ($row.IsLastResult) { "└── " } else { "├── " }
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

# Start background lookup pipeline for a device (Asynchronous, non-blocking)
function Start-DeviceLookup {
    param($Dev)
    
    $instanceId = $Dev.InstanceId
    
    # If already searching, toggle to cancel/stop it
    if ($script:ActiveSearches.Contains($instanceId)) {
        Stop-DeviceLookup -InstanceId $instanceId
        return
    }
    
    $geminiModel = "gemini-2.5-flash"
    $openRouterModel = "nvidia/nemotron-3-super-120b-a12b:free"
    
    # Resolve API keys
    $apiKey = $env:GEMINI_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey)) { $apiKey = $env:GOOGLE_API_KEY }
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        try { $apiKey = (Get-ItemProperty -Path 'HKCU:\Environment' -ErrorAction SilentlyContinue).GOOGLE_API_KEY } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        try { $apiKey = (Get-ItemProperty -Path 'HKCU:\Environment' -ErrorAction SilentlyContinue).GEMINI_API_KEY } catch {}
    }
    
    $openRouterKey = $env:OPENROUTER_API_KEY
    if ([string]::IsNullOrWhiteSpace($openRouterKey)) {
        try { $openRouterKey = (Get-ItemProperty -Path 'HKCU:\Environment' -ErrorAction SilentlyContinue).OPENROUTER_API_KEY } catch {}
    }
    
    # Initialize search states
    $localState = 'Searching'
    $webState = 'Searching'
    $geminiState = if ($apiKey) { 'Waiting' } else { 'None' }
    $openRouterState = if ($openRouterKey) { 'Waiting' } else { 'None' }
    
    # Pre-populate search rows
    $Dev.SearchStatus = 'Done'
    $newResults = [System.Collections.Generic.List[string]]::new()
    if ($geminiState -eq 'Waiting') { $newResults.Add("[Gemini: $geminiModel] (Waiting for web search...)") }
    if ($openRouterState -eq 'Waiting') { $newResults.Add("[OpenRouter: $openRouterModel] (Waiting for web search...)") }
    if ($webState -eq 'Searching') { $newResults.Add("[Web Snippet] (Searching...)") }
    $Dev.SearchResults = $newResults
    
    # Start background runspace for Web and Local Search
    $psWeb = [PowerShell]::Create()
    $null = $psWeb.AddScript({
        param($InstanceId)
        $ProgressPreference = 'SilentlyContinue'
        try {
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
                
                $dbPath = Join-Path $env:TEMP $dbName
                try {
                    if (-not (Test-Path $dbPath) -or (Get-Item $dbPath).LastWriteTime -lt (Get-Date).AddDays(-30)) {
                        Invoke-WebRequest -Uri $dbUrl -OutFile $dbPath -UserAgent "Mozilla/5.0" -TimeoutSec 15 -UseBasicParsing
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
                
                $response = Invoke-WebRequest -Uri $uri -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -TimeoutSec 15 -UseBasicParsing
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
            
            $localInfo = Get-LocalDeviceLookup -InstId $InstanceId
            if ($null -ne $localInfo) {
                Write-Output ([PSCustomObject]@{ Source = 'Local'; Status = 'Done'; Result = "[Local DB] Vendor: $($localInfo.Vendor) | Device: $($localInfo.Device)" })
            } else {
                Write-Output ([PSCustomObject]@{ Source = 'Local'; Status = 'Done'; Result = $null })
            }
            
            $webSnippets = @()
            try {
                $webSnippets = Search-DeviceWeb -HwId $InstanceId
                if ($webSnippets.Count -gt 0) {
                    Write-Output ([PSCustomObject]@{ Source = 'Web'; Status = 'Done'; Snippets = $webSnippets; Result = $webSnippets[0] })
                } else {
                    Write-Output ([PSCustomObject]@{ Source = 'Web'; Status = 'Done'; Snippets = @(); Result = "No web snippets found." })
                }
            } catch {
                Write-Output ([PSCustomObject]@{ Source = 'Web'; Status = 'Error'; Snippets = @(); Result = "Search failed: $($_.Exception.Message)" })
            }
        } catch {
            Write-Output ([PSCustomObject]@{ Source = 'Web'; Status = 'Error'; Snippets = @(); Result = "Runspace crashed: $($_.Exception.Message)" })
        }
        return $null
    })
    $null = $psWeb.AddArgument($Dev.InstanceId)
    
    $outputWeb = [System.Management.Automation.PSDataCollection[PSObject]]::new()
    $asyncWeb = $psWeb.BeginInvoke($outputWeb)
    
    # Register active search
    $script:ActiveSearches[$instanceId] = [pscustomobject]@{
        Device             = $Dev
        StartTime          = (Get-Date)
        
        PsWeb              = $psWeb
        AsyncWeb           = $asyncWeb
        OutputWeb          = $outputWeb
        
        PsGemini           = $null
        AsyncGemini        = $null
        OutputGemini       = $null
        GeminiStarted      = $false
        GeminiApiKey       = $apiKey
        GeminiModel        = $geminiModel
        GeminiDuration     = $null
        
        PsOpenRouter       = $null
        AsyncOpenRouter    = $null
        OutputOpenRouter   = $null
        OpenRouterStarted  = $false
        OpenRouterApiKey   = $openRouterKey
        OpenRouterModel    = $openRouterModel
        OpenRouterDuration = $null
        
        LocalState         = $localState
        WebState           = $webState
        GeminiState        = $geminiState
        OpenRouterState    = $openRouterState
        
        LocalVal           = $null
        WebVal             = $null
        WebSnippets        = @()
        GeminiVal          = $null
        OpenRouterVal      = $null
        
        SpinnerIndex       = 0
    }
}

# Stop and cleanup an active device lookup (Cancellation)
function Stop-DeviceLookup {
    param([string]$InstanceId)
    
    if (-not $script:ActiveSearches.Contains($InstanceId)) { return }
    $search = $script:ActiveSearches[$InstanceId]
    
    # Safely stop and dispose runspaces
    if ($null -ne $search.PsWeb) { try { $search.PsWeb.Stop(); $search.PsWeb.Dispose() } catch {} }
    if ($null -ne $search.PsGemini) { try { $search.PsGemini.Stop(); $search.PsGemini.Dispose() } catch {} }
    if ($null -ne $search.PsOpenRouter) { try { $search.PsOpenRouter.Stop(); $search.PsOpenRouter.Dispose() } catch {} }
    
    # Finalize search results with cancelled messages in split format
    $newResults = [System.Collections.Generic.List[string]]::new()
    
    if ($search.GeminiState -in @('Searching', 'Waiting')) {
        $newResults.Add("[Gemini Error] (Cancelled)")
        $newResults.Add("  Cancelled by user.")
    } elseif ($search.GeminiState -eq 'Done') {
        $durationStr = if ($null -ne $search.GeminiDuration) { "in $($search.GeminiDuration)s" } else { "Done" }
        $newResults.Add("[Gemini: $($search.GeminiModel)] (Done $durationStr)")
        $newResults.Add("  $($search.GeminiVal)")
    } elseif ($search.GeminiState -eq 'Error') {
        $durationStr = if ($null -ne $search.GeminiDuration) { " after $($search.GeminiDuration)s" } else { "" }
        $newResults.Add("[Gemini Error] (Failed$durationStr)")
        $newResults.Add("  $($search.GeminiVal)")
    }
    
    if ($search.OpenRouterState -in @('Searching', 'Waiting')) {
        $newResults.Add("[OpenRouter Error] (Cancelled)")
        $newResults.Add("  Cancelled by user.")
    } elseif ($search.OpenRouterState -eq 'Done') {
        $durationStr = if ($null -ne $search.OpenRouterDuration) { "in $($search.OpenRouterDuration)s" } else { "Done" }
        $newResults.Add("[OpenRouter: $($search.OpenRouterModel)] (Done $durationStr)")
        $newResults.Add("  $($search.OpenRouterVal)")
    } elseif ($search.OpenRouterState -eq 'Error') {
        $durationStr = if ($null -ne $search.OpenRouterDuration) { " after $($search.OpenRouterDuration)s" } else { "" }
        $newResults.Add("[OpenRouter Error] (Failed$durationStr)")
        $newResults.Add("  $($search.OpenRouterVal)")
    }
    
    if ($search.LocalVal) {
        $newResults.Add($search.LocalVal)
    }
    
    if ($search.WebState -eq 'Searching') {
        $newResults.Add("[Web Snippet Error] (Cancelled)")
        $newResults.Add("  Cancelled by user.")
    } elseif ($search.WebVal) {
        $newResults.Add("[Web Snippet] $($search.WebVal)")
    }
    
    $search.Device.SearchResults = $newResults
    
    # Remove from active searches
    $script:ActiveSearches.Remove($InstanceId)
}

# Update all active background lookups (Invoked inside key polling)
function Update-ActiveSearches {
    $completedIds = [System.Collections.Generic.List[string]]::new()
    
    foreach ($instanceId in @($script:ActiveSearches.Keys)) {
        $search = $script:ActiveSearches[$instanceId]
        
        $spinner = @('|', '/', '-', '\')
        $search.SpinnerIndex = ($search.SpinnerIndex + 1) % $spinner.Count
        $spChar = $spinner[$search.SpinnerIndex]
        $elapsed = [int]((Get-Date) - $search.StartTime).TotalSeconds
        
        # 1. Process Web/Local Search
        if ($null -ne $search.PsWeb) {
            while ($search.OutputWeb.Count -gt 0) {
                $data = $search.OutputWeb[0]
                $search.OutputWeb.RemoveAt(0)
                if ($null -ne $data) {
                    if ($data.Source -eq 'Local') {
                        $search.LocalVal = $data.Result
                        $search.LocalState = $data.Status
                    }
                    elseif ($data.Source -eq 'Web') {
                        $search.WebVal = $data.Result
                        $search.WebState = $data.Status
                        if ($data.Snippets) {
                            $search.WebSnippets = $data.Snippets
                        }
                    }
                }
            }
            
            if ($search.AsyncWeb.IsCompleted) {
                try {
                    $resList = $search.PsWeb.EndInvoke($search.AsyncWeb)
                    foreach ($data in $resList) {
                        if ($null -ne $data) {
                            if ($data.Source -eq 'Local') {
                                $search.LocalVal = $data.Result
                                $search.LocalState = $data.Status
                            }
                            elseif ($data.Source -eq 'Web') {
                                $search.WebVal = $data.Result
                                $search.WebState = $data.Status
                                if ($data.Snippets) {
                                    $search.WebSnippets = $data.Snippets
                                }
                            }
                        }
                    }
                } catch {
                    $search.WebState = 'Error'
                    $search.WebVal = "Runspace failed: $($_.Exception.Message)"
                }
                if ($search.WebState -eq 'Searching') { $search.WebState = 'Done' }
                if ($search.LocalState -eq 'Searching') { $search.LocalState = 'Done' }
                try { $search.PsWeb.Dispose() } catch {}
                $search.PsWeb = $null
                $search.AsyncWeb = $null
            }
        }
        
        # 2. Trigger AI Runspaces if Web search finished and AI not started yet
        if (($search.WebState -eq 'Done' -or $search.WebState -eq 'Error') -and 
            -not $search.GeminiStarted -and -not $search.OpenRouterStarted) {
            
            $prompt = "You are a hardware expert. Below are search snippets for Hardware ID '$($search.Device.InstanceId)'. Synthesize them into a single concise line (max 90 chars) specifying the exact manufacturer, model, and likely driver/troubleshooting tip. Do not use markdown, bolding, or lists. Keep it brief.`nSnippets:`n" + ($search.WebSnippets -join "`n")
            
            # Start Gemini
            if ($search.GeminiState -eq 'Waiting') {
                $search.GeminiStarted = $true
                $search.GeminiState = 'Searching'
                
                $psGem = [PowerShell]::Create()
                $null = $psGem.AddScript({
                    param($PromptText, $resolvedApiKey, $resolvedModelName)
                    $ProgressPreference = 'SilentlyContinue'
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
                $null = $psGem.AddArgument($prompt)
                $null = $psGem.AddArgument($search.GeminiApiKey)
                $null = $psGem.AddArgument($search.GeminiModel)
                
                $search.OutputGemini = [System.Management.Automation.PSDataCollection[PSObject]]::new()
                $search.AsyncGemini = $psGem.BeginInvoke($search.OutputGemini)
                $search.PsGemini = $psGem
            }
            
            # Start OpenRouter
            if ($search.OpenRouterState -eq 'Waiting') {
                $search.OpenRouterStarted = $true
                $search.OpenRouterState = 'Searching'
                
                $psOR = [PowerShell]::Create()
                $null = $psOR.AddScript({
                    param($PromptText, $resolvedOpenRouterKey, $resolvedModelName)
                    $ProgressPreference = 'SilentlyContinue'
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
                $null = $psOR.AddArgument($prompt)
                $null = $psOR.AddArgument($search.OpenRouterApiKey)
                $null = $psOR.AddArgument($search.OpenRouterModel)
                
                $search.OutputOpenRouter = [System.Management.Automation.PSDataCollection[PSObject]]::new()
                $search.AsyncOpenRouter = $psOR.BeginInvoke($search.OutputOpenRouter)
                $search.PsOpenRouter = $psOR
            }
            
            if ($search.GeminiState -eq 'Waiting') { $search.GeminiState = 'None' }
            if ($search.OpenRouterState -eq 'Waiting') { $search.OpenRouterState = 'None' }
        }
        
        # 3. Process Gemini Runspace Output
        if ($null -ne $search.PsGemini) {
            while ($search.OutputGemini.Count -gt 0) {
                $data = $search.OutputGemini[0]
                $search.OutputGemini.RemoveAt(0)
                if ($null -ne $data) {
                    $search.GeminiState = $data.Status
                    $search.GeminiVal = $data.Result
                }
            }
            
            if ($search.AsyncGemini.IsCompleted) {
                try {
                    $resList = $search.PsGemini.EndInvoke($search.AsyncGemini)
                    if ($search.GeminiState -eq 'Searching') {
                        if ($resList.Count -gt 0 -and $null -ne $resList[0]) {
                            $search.GeminiState = $resList[0].Status
                            $search.GeminiVal = $resList[0].Result
                            $search.GeminiDuration = $elapsed
                        } else {
                            $search.GeminiState = 'Error'
                            $search.GeminiVal = 'Empty response from Gemini API.'
                            $search.GeminiDuration = $elapsed
                        }
                    }
                } catch {
                    $search.GeminiState = 'Error'
                    $search.GeminiVal = $_.Exception.Message
                    $search.GeminiDuration = $elapsed
                }
                try { $search.PsGemini.Dispose() } catch {}
                $search.PsGemini = $null
                $search.AsyncGemini = $null
            }
        }
        
        # 4. Process OpenRouter Runspace Output
        if ($null -ne $search.PsOpenRouter) {
            while ($search.OutputOpenRouter.Count -gt 0) {
                $data = $search.OutputOpenRouter[0]
                $search.OutputOpenRouter.RemoveAt(0)
                if ($null -ne $data) {
                    $search.OpenRouterState = $data.Status
                    $search.OpenRouterVal = $data.Result
                }
            }
            
            if ($search.AsyncOpenRouter.IsCompleted) {
                try {
                    $resList = $search.PsOpenRouter.EndInvoke($search.AsyncOpenRouter)
                    if ($search.OpenRouterState -eq 'Searching') {
                        if ($resList.Count -gt 0 -and $null -ne $resList[0]) {
                            $search.OpenRouterState = $resList[0].Status
                            $search.OpenRouterVal = $resList[0].Result
                            $search.OpenRouterDuration = $elapsed
                        } else {
                            $search.OpenRouterState = 'Error'
                            $search.OpenRouterVal = 'Empty response from OpenRouter API.'
                            $search.OpenRouterDuration = $elapsed
                        }
                    }
                } catch {
                    $search.OpenRouterState = 'Error'
                    $search.OpenRouterVal = $_.Exception.Message
                    $search.OpenRouterDuration = $elapsed
                }
                try { $search.PsOpenRouter.Dispose() } catch {}
                $search.PsOpenRouter = $null
                $search.AsyncOpenRouter = $null
            }
        }
        
        # Rebuild Results list
        $newResults = [System.Collections.Generic.List[string]]::new()
        
        # Gemini display
        if ($search.GeminiState -eq 'Waiting') {
            $newResults.Add("[Gemini: $($search.GeminiModel)] (Waiting for web search...)")
        } elseif ($search.GeminiState -eq 'Searching') {
            $newResults.Add("[Gemini: $($search.GeminiModel)] (Searching... $spChar ${elapsed}s)")
        } elseif ($search.GeminiState -eq 'Done') {
            $durationStr = if ($null -ne $search.GeminiDuration) { "in $($search.GeminiDuration)s" } else { "Done" }
            $newResults.Add("[Gemini: $($search.GeminiModel)] (Done $durationStr)")
            $newResults.Add("  $($search.GeminiVal)")
        } elseif ($search.GeminiState -eq 'Error') {
            $durationStr = if ($null -ne $search.GeminiDuration) { " after $($search.GeminiDuration)s" } else { "" }
            $newResults.Add("[Gemini Error] (Failed$durationStr)")
            $newResults.Add("  $($search.GeminiVal)")
        }
        
        # OpenRouter display
        if ($search.OpenRouterState -eq 'Waiting') {
            $newResults.Add("[OpenRouter: $($search.OpenRouterModel)] (Waiting for web search...)")
        } elseif ($search.OpenRouterState -eq 'Searching') {
            $newResults.Add("[OpenRouter: $($search.OpenRouterModel)] (Searching... $spChar ${elapsed}s)")
        } elseif ($search.OpenRouterState -eq 'Done') {
            $durationStr = if ($null -ne $search.OpenRouterDuration) { "in $($search.OpenRouterDuration)s" } else { "Done" }
            $newResults.Add("[OpenRouter: $($search.OpenRouterModel)] (Done $durationStr)")
            $newResults.Add("  $($search.OpenRouterVal)")
        } elseif ($search.OpenRouterState -eq 'Error') {
            $durationStr = if ($null -ne $search.OpenRouterDuration) { " after $($search.OpenRouterDuration)s" } else { "" }
            $newResults.Add("[OpenRouter Error] (Failed$durationStr)")
            $newResults.Add("  $($search.OpenRouterVal)")
        }
        
        # Local DB display
        if ($search.LocalState -eq 'Done' -and $search.LocalVal) {
            $newResults.Add($search.LocalVal)
        }
        
        # Web Snippet display
        if ($search.WebState -eq 'Searching') {
            $newResults.Add("[Web Snippet] (Searching... $spChar ${elapsed}s)")
        } elseif ($search.WebState -eq 'Done' -and $search.WebVal) {
            $newResults.Add("[Web Snippet] $($search.WebVal)")
        } elseif ($search.WebState -eq 'Error') {
            $newResults.Add("[Web Snippet Error] $($search.WebVal)")
        }
        
        $search.Device.SearchResults = $newResults
        
        # Check if completed
        $finished = $true
        if ($null -ne $search.PsWeb) { $finished = $false }
        if ($null -ne $search.PsGemini) { $finished = $false }
        if ($null -ne $search.PsOpenRouter) { $finished = $false }
        if ($search.GeminiState -eq 'Waiting') { $finished = $false }
        if ($search.OpenRouterState -eq 'Waiting') { $finished = $false }
        
        if ($finished) {
            $completedIds.Add($instanceId)
        }
    }
    
    foreach ($id in $completedIds) {
        $script:ActiveSearches.Remove($id)
    }
}

# Override Read-ConsoleKey to support background search ticks & smooth rendering
function Read-ConsoleKey {
    try { [Console]::CursorVisible = $false } catch {}

    try {
        while (-not [Console]::KeyAvailable) {
            if (Test-WindowResized) {
                return [pscustomobject]@{
                    Key            = 'ResizeEvent'
                    KeyChar        = [char]0
                    VirtualKeyCode = 0
                }
            }

            # Update active background searches and redraw
            if ($script:ActiveSearches.Count -gt 0) {
                Update-ActiveSearches
                $script:visibleRows = Update-VisibleRows
                if ($script:visibleRows.Count -gt 0) {
                    $script:selectedIndex = [Math]::Max(0, [Math]::Min($script:selectedIndex, $script:visibleRows.Count - 1))
                } else {
                    $script:selectedIndex = 0
                }
                Render-Frame
                Start-Sleep -Milliseconds 150
            } else {
                Start-Sleep -Milliseconds 40
            }
        }
    }
    catch {}

    try {
        $keyInfo = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    catch {
        $keyInfo = [Console]::ReadKey($true)
    }

    $keyName = $null
    $keyChar = [char]0
    $virtualKeyCode = $null

    if ($keyInfo.PSObject.Properties['Key']) {
        $keyName = [string]$keyInfo.Key
    }
    elseif ($keyInfo.PSObject.Properties['VirtualKeyCode']) {
        $virtualKeyCode = [int]$keyInfo.VirtualKeyCode
        try {
            $keyName = [string][System.Enum]::ToObject([System.ConsoleKey], $virtualKeyCode)
        }
        catch {
            $keyName = [string]$virtualKeyCode
        }
    }

    if ($keyInfo.PSObject.Properties['KeyChar']) {
        $keyChar = [char]$keyInfo.KeyChar
    }
    elseif ($keyInfo.PSObject.Properties['Character']) {
        $keyChar = [char]$keyInfo.Character
    }

    [pscustomobject]@{
        Key            = $keyName
        KeyChar        = $keyChar
        VirtualKeyCode = $virtualKeyCode
    }
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
                    Start-DeviceLookup -Dev $currentRow.Ref
                } elseif ($currentRow.Type -in @('Result', 'Status') -and $null -ne $currentRow.ParentDevice) {
                    Start-DeviceLookup -Dev $currentRow.ParentDevice
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
                        Start-DeviceLookup -Dev $currentRow.Ref
                    } elseif ($currentRow.Type -in @('Result', 'Status') -and $null -ne $currentRow.ParentDevice) {
                        Start-DeviceLookup -Dev $currentRow.ParentDevice
                    }
                }
            }
        }
    }
}
finally {
    # Stop and dispose all active searches
    if ($null -ne $script:ActiveSearches) {
        foreach ($id in @($script:ActiveSearches.Keys)) {
            Stop-DeviceLookup -InstanceId $id
        }
    }
    # Restore Host Settings
    Restore-TuiHost
    Write-Host 'DeviceCheck closed.'
}
