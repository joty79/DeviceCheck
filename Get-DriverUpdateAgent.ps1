#requires -version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DeviceName,
    [Parameter(Mandatory=$true)][string]$InstanceId,
    [Parameter(Mandatory=$true)][string]$HardwareId,
    [string]$Manufacturer,
    [string]$InstalledDriver,
    [string]$Motherboard,
    [string]$Cpu,
    [string]$Os,
    [AllowEmptyString()][string]$EvidenceJson,
    [string]$ApiKey,
    [string]$TracePath,
    [string]$CheckpointPath,
    [string]$ToolCacheRoot,
    [int]$MaxIterations = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Define API variables
$resolvedModelName = "gemini-3.1-flash-lite"
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-Output ([PSCustomObject]@{ Type = 'Error'; Message = "Google API key is required." })
    return
}
$uri = "https://generativelanguage.googleapis.com/v1beta/models/$($resolvedModelName):generateContent?key=$ApiKey"

function Get-WebExceptionBody {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    try {
        if ($ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
            return $ErrorRecord.ErrorDetails.Message
        }
    } catch {}

    try {
        if ($ErrorRecord.Exception.Response) {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = [System.IO.StreamReader]::new($stream)
                return $reader.ReadToEnd()
            }
        }
    } catch {}

    return ''
}

function Get-WebExceptionStatusCode {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    try {
        if ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) {
            return [int]$ErrorRecord.Exception.Response.StatusCode
        }
    } catch {}
    return $null
}

function Get-WebExceptionRetryAfterSeconds {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    try {
        $headers = $ErrorRecord.Exception.Response.Headers
        if ($headers) {
            $raw = $headers['Retry-After']
            $retryAfter = 0
            if ($raw -and [int]::TryParse([string]$raw, [ref]$retryAfter)) {
                return $retryAfter
            }
        }
    } catch {}
    return $null
}

function Format-AgentLogValue {
    param(
        [AllowNull()]$Value,
        [int]$MaxLength = 180
    )

    if ($null -eq $Value) { return '' }
    $text = ([string]$Value) -replace '\s+', ' '
    $text = $text.Trim()
    if ($text.Length -le $MaxLength) { return $text }
    return $text.Substring(0, $MaxLength - 3) + '...'
}

function Convert-AgentValueToText {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return '' }
    return ((@($Value) | ForEach-Object {
        if ($null -eq $_) { '' } else { [string]$_ }
    }) -join "`n").Trim()
}

function Format-AgentArgs {
    param([AllowNull()]$ArgsObject)

    if ($null -eq $ArgsObject) { return '' }
    try {
        $pairs = @(
            $ArgsObject.PSObject.Properties | ForEach-Object {
                "$($_.Name)=$(Format-AgentLogValue -Value $_.Value -MaxLength 120)"
            }
        )
        return ($pairs -join '; ')
    } catch {
        return (Format-AgentLogValue -Value $ArgsObject)
    }
}

function Get-NotePropertyValue {
    param(
        [AllowNull()]$Object,
        [string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Write-AgentEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowNull()]$Data
    )

    if (-not [string]::IsNullOrWhiteSpace($TracePath)) {
        try {
            $traceRoot = Split-Path -Path $TracePath -Parent
            if (-not [string]::IsNullOrWhiteSpace($traceRoot)) {
                $null = New-Item -ItemType Directory -Path $traceRoot -Force
            }
            $record = [pscustomobject]@{
                at      = (Get-Date).ToString('o')
                type    = $Type
                message = $Message
                data    = $Data
            }
            $record | ConvertTo-Json -Depth 10 -Compress | Add-Content -LiteralPath $TracePath -Encoding UTF8
        } catch {}
    }

    Write-Output ([PSCustomObject]@{ Type = $Type; Message = $Message })
}

function New-AgentHash {
    param([AllowEmptyString()][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hashBytes = $sha.ComputeHash($bytes)
        return (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 24)
    } finally {
        $sha.Dispose()
    }
}

function Get-JsonDepthSafe {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    return ($Value | ConvertTo-Json -Depth 30 -Compress)
}

function Get-ToolCachePath {
    param([string]$ToolName, [AllowNull()]$ArgsObject)

    if ([string]::IsNullOrWhiteSpace($ToolCacheRoot)) { return $null }
    $keyJson = Get-JsonDepthSafe ([pscustomobject]@{ tool = $ToolName; args = $ArgsObject })
    $hash = New-AgentHash -Text $keyJson
    return (Join-Path -Path $ToolCacheRoot -ChildPath "$hash.json")
}

function Get-CachedToolResult {
    param(
        [string]$ToolName,
        [AllowNull()]$ArgsObject,
        [int]$MaxAgeHours = 12
    )

    $cachePath = Get-ToolCachePath -ToolName $ToolName -ArgsObject $ArgsObject
    if ([string]::IsNullOrWhiteSpace($cachePath) -or -not (Test-Path -LiteralPath $cachePath)) { return $null }

    try {
        $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
        $capturedAt = [datetime]$cache.capturedAt
        if ($capturedAt -lt (Get-Date).AddHours(-1 * [Math]::Max(1, $MaxAgeHours))) { return $null }
        return [pscustomobject]@{
            Result     = [string]$cache.result
            CapturedAt = $capturedAt
            Path       = $cachePath
        }
    } catch {
        return $null
    }
}

function Set-CachedToolResult {
    param(
        [string]$ToolName,
        [AllowNull()]$ArgsObject,
        [AllowNull()]$Result
    )

    $cachePath = Get-ToolCachePath -ToolName $ToolName -ArgsObject $ArgsObject
    if ([string]::IsNullOrWhiteSpace($cachePath)) { return }

    try {
        $cacheRoot = Split-Path -Path $cachePath -Parent
        $null = New-Item -ItemType Directory -Path $cacheRoot -Force
        $resultText = Convert-AgentValueToText -Value $Result
        [pscustomobject]@{
            schemaVersion = 1
            capturedAt    = (Get-Date).ToString('o')
            tool          = $ToolName
            args          = $ArgsObject
            result        = $resultText
        } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $cachePath -Encoding UTF8
    } catch {}
}

function Invoke-CachedTool {
    param(
        [string]$ToolName,
        [AllowNull()]$ArgsObject,
        [scriptblock]$Action,
        [int]$MaxAgeHours = 12
    )

    $cached = Get-CachedToolResult -ToolName $ToolName -ArgsObject $ArgsObject -MaxAgeHours $MaxAgeHours
    if ($null -ne $cached) {
        return "[Cached $ToolName result from $($cached.CapturedAt.ToString('u'))]`n$($cached.Result)"
    }

    $result = Convert-AgentValueToText -Value (& $Action)
    Set-CachedToolResult -ToolName $ToolName -ArgsObject $ArgsObject -Result $result
    return $result
}

function Get-UrlsFromAgentText {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $urls = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Text, 'https?://[^\s\]\)\}>"]+')) {
        $url = $match.Value.TrimEnd('.', ',', ';', ':')
        if (-not [string]::IsNullOrWhiteSpace($url) -and -not $urls.Contains($url)) {
            $urls.Add($url)
        }
    }
    return @($urls)
}

function Get-DeviceModelTokens {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$MaxCount = 5
    )

    $tokens = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    foreach ($match in [regex]::Matches($Text, '(?i)\b[A-Z0-9]{2,}[-_]?[A-Z0-9]{2,}(?:[-_][A-Z0-9]{2,})*\b')) {
        $token = $match.Value.ToUpperInvariant()
        if ($token -in @('DISPLAYPORT', 'MONITOR', 'WINDOWS', 'DRIVER', 'DRIVERS', 'AUDIO', 'DEVICE', 'HARDWARE', 'MICROSOFT')) { continue }
        if ($token -match '^(VEN|DEV|SUBSYS|REV|VID|PID|MI|COL|UID)[A-Z0-9_]*$') { continue }
        if (-not $tokens.Contains($token)) { $tokens.Add($token) }
        if ($tokens.Count -ge $MaxCount) { break }
    }

    return @($tokens)
}

function New-VendorCandidate {
    param(
        [string]$Vendor,
        [string]$Url,
        [string]$TargetText,
        [string]$InputText,
        [string]$Reason
    )

    return [pscustomobject]@{
        vendor     = $Vendor
        url        = $Url
        targetText = $TargetText
        inputText  = $InputText
        reason     = $Reason
    }
}

function Get-VendorFirstCandidates {
    param(
        [string]$Name,
        [string]$HwId,
        [string]$Maker,
        [string]$Board
    )

    $sourceText = "$Name $HwId $Maker $Board"
    $candidateInput = @(
        Get-DeviceModelTokens -Text "$Name $HwId $Maker" -MaxCount 4
    ) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($candidateInput)) { $candidateInput = $Name }

    $candidates = [System.Collections.Generic.List[object]]::new()

    if ($sourceText -match '(?i)\bAOC\b' -or $HwId -match '(?i)^MONITOR\\AOC') {
        $model = $candidateInput
        foreach ($region in @('gr', 'eu', 'uk', 'us')) {
            if (-not [string]::IsNullOrWhiteSpace($model)) {
                $candidates.Add((New-VendorCandidate -Vendor 'AOC' -Url "https://www.aoc.com/$region/gaming/monitors/$($model.ToLowerInvariant())" -TargetText 'DRIVERS AND MANUALS|Drivers & Manuals|Drivers' -InputText '' -Reason "AOC regional product page for model $model"))
            }
        }
        $candidates.Add((New-VendorCandidate -Vendor 'AOC' -Url 'https://www.aoc.com/gr/gaming/drivers-downloads' -TargetText 'Search' -InputText $candidateInput -Reason 'AOC regional driver search page'))
    }

    if ($sourceText -match '(?i)\bLG\b|ULTRAGEAR|\bGSM[0-9A-F]{4}\b' -or $HwId -match '(?i)^MONITOR\\GSM') {
        $searchInput = if ($HwId -match '(?i)MONITOR\\([^\\]+)') { $Matches[1].ToUpperInvariant() } else { $candidateInput }
        $candidates.Add((New-VendorCandidate -Vendor 'LG' -Url 'https://www.lg.com/gr/support/software-firmware-drivers' -TargetText 'Search' -InputText $searchInput -Reason 'LG Greece/regional official software/firmware/driver search by monitor hardware code'))
        $candidates.Add((New-VendorCandidate -Vendor 'LG' -Url 'https://www.lg.com/uk/support/software-firmware-drivers' -TargetText 'Search' -InputText $searchInput -Reason 'LG Europe/UK official software/firmware/driver search by monitor hardware code'))
        $candidates.Add((New-VendorCandidate -Vendor 'LG' -Url 'https://www.lg.com/us/support/software-firmware-drivers' -TargetText 'Search' -InputText $searchInput -Reason 'LG US official software/firmware/driver search by monitor hardware code after regional checks'))
        $candidates.Add((New-VendorCandidate -Vendor 'LG' -Url "https://www.lg.com/gr/search?q=$([Uri]::EscapeDataString($searchInput))" -TargetText 'Support|Drivers|Software' -InputText '' -Reason 'LG Greece official site search by hardware code'))
    }

    $isExternalMonitor = $HwId -match '(?i)^MONITOR\\' -or $Name -match '(?i)\bmonitor\b|ULTRAGEAR|DisplayPort|HDMI'
    if (-not $isExternalMonitor -and $sourceText -match '(?i)Micro-Star|MSI|MAG X870 TOMAHAWK WIFI') {
        $candidates.Add((New-VendorCandidate -Vendor 'MSI' -Url 'https://www.msi.com/Motherboard/MAG-X870-TOMAHAWK-WIFI/support' -TargetText 'Driver' -InputText '' -Reason 'MSI motherboard support page from local BaseBoard evidence'))
    }

    return @($candidates)
}

function Format-VendorCandidateGuidance {
    param([AllowNull()]$Candidates)

    $items = @($Candidates)
    if ($items.Count -eq 0) {
        return 'No deterministic official vendor URLs were constructed. Use SearchGoogleCustom if configured with the local device evidence query, then immediately fetch the best official/vendor result with FetchRenderedUrlText. Use SearchGoogleRendered only as a fragile fallback/diagnostic.'
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Vendor-first required actions before search discovery:')
    $index = 0
    foreach ($candidate in $items | Select-Object -First 6) {
        $index++
        $lines.Add("$index. FetchRenderedUrlText url=$($candidate.url); targetText=$($candidate.targetText); inputText=$($candidate.inputText) [$($candidate.reason)]")
    }
    return ($lines -join "`n")
}

function New-LocalDeviceSearchText {
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($DeviceName, $InstanceId, $HardwareId, $Manufacturer, $InstalledDriver)) {
        if (-not [string]::IsNullOrWhiteSpace($value)) { $parts.Add([string]$value) }
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($EvidenceJson)) {
            $evidence = $EvidenceJson | ConvertFrom-Json
            $important = Get-NotePropertyValue -Object $evidence -Name 'ImportantProperties'
            foreach ($key in @(
                'DEVPKEY_Device_DeviceDesc',
                'DEVPKEY_Device_HardwareIds',
                'DEVPKEY_Device_CompatibleIds',
                'DEVPKEY_Device_Manufacturer',
                'DEVPKEY_Device_Service',
                'DEVPKEY_Device_DriverInfPath',
                'DEVPKEY_Device_DriverVersion'
            )) {
                $value = Get-NotePropertyValue -Object $important -Name $key
                if ($value) { $parts.Add(($value -join ' ')) }
            }
        }
    } catch {}

    return (($parts | Select-Object -Unique) -join ' | ')
}

function Get-GoogleSearchQueries {
    $queries = [System.Collections.Generic.List[string]]::new()
    $localText = New-LocalDeviceSearchText
    $modelTokens = @(Get-DeviceModelTokens -Text $localText -MaxCount 5)
    $hardwareCode = ''
    if ($HardwareId -match '(?i)^[^\\]+\\([^\\]+)$') { $hardwareCode = $Matches[1].ToUpperInvariant() }

    $rawEvidenceLines = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($DeviceName)) { $rawEvidenceLines.Add("FriendlyName  : $DeviceName") }
    if (-not [string]::IsNullOrWhiteSpace($InstanceId)) { $rawEvidenceLines.Add("InstanceId    : $InstanceId") }
    if (-not [string]::IsNullOrWhiteSpace($HardwareId)) { $rawEvidenceLines.Add("HardwareId    : $HardwareId") }
    if (-not [string]::IsNullOrWhiteSpace($Manufacturer)) { $rawEvidenceLines.Add("Manufacturer  : $Manufacturer") }
    if (-not [string]::IsNullOrWhiteSpace($InstalledDriver)) { $rawEvidenceLines.Add("Driver        : $InstalledDriver") }
    try {
        if (-not [string]::IsNullOrWhiteSpace($EvidenceJson)) {
            $evidence = $EvidenceJson | ConvertFrom-Json
            $important = Get-NotePropertyValue -Object $evidence -Name 'ImportantProperties'
            $compatibleId = Get-NotePropertyValue -Object $important -Name 'DEVPKEY_Device_CompatibleIds'
            $service = Get-NotePropertyValue -Object $important -Name 'DEVPKEY_Device_Service'
            $driverInf = Get-NotePropertyValue -Object $important -Name 'DEVPKEY_Device_DriverInfPath'
            $driverVersion = Get-NotePropertyValue -Object $important -Name 'DEVPKEY_Device_DriverVersion'
            if ($compatibleId) { $rawEvidenceLines.Add("CompatibleId  : $(($compatibleId -join ' '))") }
            if ($service) { $rawEvidenceLines.Add("Service       : $(($service -join ' '))") }
            if ($driverVersion -or $driverInf) { $rawEvidenceLines.Add("Installed INF : $(($driverVersion, $driverInf | Where-Object { $_ }) -join ' ')") }
        }
    } catch {}
    if ($rawEvidenceLines.Count -gt 0) {
        $queries.Add(($rawEvidenceLines -join "`n"))
    }

    $coreTerms = @()
    if (-not [string]::IsNullOrWhiteSpace($DeviceName)) { $coreTerms += '"' + $DeviceName + '"' }
    if (-not [string]::IsNullOrWhiteSpace($hardwareCode)) { $coreTerms += '"' + $hardwareCode + '"' }
    if (-not [string]::IsNullOrWhiteSpace($Manufacturer)) { $coreTerms += '"' + $Manufacturer + '"' }
    if ($InstalledDriver -match '\(([^)]+\.inf)\)') { $coreTerms += '"' + $Matches[1] + '"' }
    if ($coreTerms.Count -gt 0) {
        $queries.Add((($coreTerms + @('driver', 'official')) -join ' '))
    }

    if ($modelTokens.Count -gt 0) {
        $queries.Add((($modelTokens | ForEach-Object { '"' + $_ + '"' }) -join ' ') + ' driver official')
    }

    if (-not [string]::IsNullOrWhiteSpace($localText)) {
        $brief = $localText
        if ($brief.Length -gt 240) { $brief = $brief.Substring(0, 240) }
        $queries.Add("$brief driver")
    }

    return @($queries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique -First 3)
}

function Add-AgentMemoryFromTool {
    param(
        [Parameter(Mandatory = $true)]$Memory,
        [int]$Step,
        [string]$Tool,
        [AllowNull()]$ArgsObject,
        [AllowNull()]$Result
    )

    $resultText = Convert-AgentValueToText -Value $Result
    $hasPositiveEvidence = $resultText -match '(?i)AOC deterministic match|downloadLinks|DOWNLOAD\s+(ZIP|EXE|CAB|INF|MSI|PDF|HTML)|DownloadLink|official support|official OEM|driver|drivers|manuals'
    $hasNegativeEvidence = $resultText -match '(?i)failed|not found|404|no results|anti-bot|blocked|Could not find requested resource'
    $urls = @(Get-UrlsFromAgentText -Text ((Get-JsonDepthSafe $ArgsObject) + "`n" + $resultText))
    foreach ($url in $urls) {
        if (-not $Memory.CandidateUrls.Contains($url)) { $Memory.CandidateUrls.Add($url) }
        if ($hasPositiveEvidence) {
            if (-not $Memory.ConfirmedUrls.Contains($url)) { $Memory.ConfirmedUrls.Add($url) }
        } elseif ($hasNegativeEvidence) {
            if (-not $Memory.FailedUrls.Contains($url)) { $Memory.FailedUrls.Add($url) }
        }
    }

    $Memory.ToolResults.Add([pscustomobject]@{
        step          = $Step
        tool          = $Tool
        args          = $ArgsObject
        resultPreview = Format-AgentLogValue -Value $resultText -MaxLength 800
    })
    $Memory.CurrentPlan = "After step $Step, processed $Tool and will decide whether more evidence is needed."
}

function Save-AgentCheckpoint {
    param(
        [string]$State,
        [int]$Step,
        [Parameter(Mandatory = $true)]$Messages,
        [Parameter(Mandatory = $true)]$Memory,
        [AllowEmptyString()][string]$Reason,
        [AllowNull()]$RetryAfterSeconds
    )

    if ([string]::IsNullOrWhiteSpace($CheckpointPath)) { return }

    try {
        $checkpointRoot = Split-Path -Path $CheckpointPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($checkpointRoot)) {
            $null = New-Item -ItemType Directory -Path $checkpointRoot -Force
        }
        [pscustomobject]@{
            schemaVersion      = 1
            updatedAt          = (Get-Date).ToString('o')
            state              = $State
            step               = $Step
            model              = $resolvedModelName
            maxIterations      = $MaxIterations
            reason             = $Reason
            retryAfterSeconds  = $RetryAfterSeconds
            device             = [pscustomobject]@{
                name            = $DeviceName
                instanceId      = $InstanceId
                hardwareId      = $HardwareId
                manufacturer    = $Manufacturer
                installedDriver = $InstalledDriver
                motherboard     = $Motherboard
                cpu             = $Cpu
                os              = $Os
            }
            memory             = $Memory
            messages           = @($Messages)
        } | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $CheckpointPath -Encoding UTF8
    } catch {
        Write-AgentEvent -Type 'Log' -Message "[Checkpoint] Failed to save: $($_.Exception.Message)" -Data @{ Path = $CheckpointPath }
    }
}

function New-AgentMemory {
    return [pscustomobject]@{
        CandidateUrls = [System.Collections.Generic.List[string]]::new()
        ConfirmedUrls = [System.Collections.Generic.List[string]]::new()
        FailedUrls    = [System.Collections.Generic.List[string]]::new()
        ToolResults   = [System.Collections.Generic.List[object]]::new()
        CurrentPlan   = 'Start with local evidence, deterministic vendor hints, then ask Gemini for the next action.'
    }
}

function Convert-CheckpointMemory {
    param([AllowNull()]$CheckpointMemory)

    $memory = New-AgentMemory
    if ($null -eq $CheckpointMemory) { return $memory }

    foreach ($item in @(Get-NotePropertyValue -Object $CheckpointMemory -Name 'CandidateUrls')) { if ($item) { $memory.CandidateUrls.Add([string]$item) } }
    foreach ($item in @(Get-NotePropertyValue -Object $CheckpointMemory -Name 'ConfirmedUrls')) { if ($item) { $memory.ConfirmedUrls.Add([string]$item) } }
    foreach ($item in @(Get-NotePropertyValue -Object $CheckpointMemory -Name 'FailedUrls')) { if ($item) { $memory.FailedUrls.Add([string]$item) } }
    foreach ($item in @(Get-NotePropertyValue -Object $CheckpointMemory -Name 'ToolResults')) { if ($null -ne $item) { $memory.ToolResults.Add($item) } }
    $plan = Get-NotePropertyValue -Object $CheckpointMemory -Name 'CurrentPlan'
    if (-not [string]::IsNullOrWhiteSpace($plan)) { $memory.CurrentPlan = [string]$plan }
    return $memory
}

# Tool: SearchWeb
function SearchWeb {
    param([string]$query)

    if ($query -match 'https?://[^\s"<>]+') {
        $directUrl = $Matches[0].TrimEnd('.', ',', ';', ')', ']')
        return "Query contained a direct URL; rendered browser fetch result:`n$(FetchRenderedUrlText -url $directUrl -targetText '')"
    }

    if ($script:AgentVendorFirstCandidates -and @($script:AgentVendorFirstCandidates).Count -gt 0 -and $script:AgentOfficialFetchAttempts -lt 1) {
        return "POLICY BLOCKED: SearchWeb is a last-resort URL discovery tool, not the first step. Do not use DuckDuckGo snippets yet.`n$(Format-VendorCandidateGuidance -Candidates $script:AgentVendorFirstCandidates)"
    }

    $script:AgentSearchWebCalls++
    if ($script:AgentSearchWebCalls -gt 1) {
        return "POLICY BLOCKED: SearchWeb budget is exhausted for this run. Do not loop on search snippets. Use FetchRenderedUrlText on the best official vendor URL already found, SearchUpdateCatalog as fallback, or produce a cautious final answer from available evidence."
    }

    $toolArgs = [pscustomobject]@{ query = $query; policy = 'SearchWebDiscoveryV2' }
    return Invoke-CachedTool -ToolName 'SearchWebDiscoveryV2' -ArgsObject $toolArgs -MaxAgeHours 6 -Action {
    try {
        $escapedQuery = [Uri]::EscapeDataString($query)
        $ddgUrl = "https://html.duckduckgo.com/html/?q=$escapedQuery"
        $response = Invoke-WebRequest -Uri $ddgUrl -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -TimeoutSec 15 -UseBasicParsing
        $content = $response.Content
        if ($content -match 'anomaly-modal|Unfortunately,\s+bots\s+use\s+DuckDuckGo') {
            if ($query -match '(?i)\bAOC\b' -and $query -match '\b([A-Z0-9]{2,}\d[A-Z0-9]*)\b') {
                $aocModel = $Matches[1].ToUpperInvariant()
                return "Search failed: DuckDuckGo returned an anti-bot challenge. For AOC model $aocModel, call FetchRenderedUrlText with url=https://aoc.com/us/gaming/drivers-downloads, targetText=Search, inputText=$aocModel. If that returns nothing found, try another AOC regional drivers-downloads URL from the rendered links."
            }
            return "Search failed: DuckDuckGo returned an anti-bot challenge. Use FetchRenderedUrlText if you have an official support URL, or try a more specific official-domain query."
        }
        $matches = [regex]::Matches($content, '<a class="result__snippet"[^>]*>(.*?)</a>')
        $results = @()
        foreach ($m in $matches) {
            $text = $m.Groups[1].Value -replace '<[^>]+>', ''
            $text = $text -replace '&amp;', '&' -replace '&#92;', '\' -replace '&quot;', '"' -replace '&#x27;', "'" -replace '&lt;', '<' -replace '&gt;', '>'
            $text = $text.Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            $results += $text
            if ($results.Count -eq 5) { break }
        }
        if ($results.Count -eq 0) { return "No web search snippets found." }
        return ($results -join "`n")
    } catch {
        return "Search failed: $($_.Exception.Message)"
    }
    }
}

# Tool: SearchGoogleRendered
function SearchGoogleRendered {
    param([string]$query)

    $script:AgentGoogleSearchCalls++
    if ($script:AgentGoogleSearchCalls -gt 2) {
        return "POLICY BLOCKED: Google search budget is exhausted for this run. Use FetchRenderedUrlText on the best official result already found, SearchUpdateCatalog as fallback, or produce a cautious final answer from available evidence."
    }

    $toolArgs = [pscustomobject]@{ query = $query; policy = 'GoogleRenderedDiscoveryV1' }
    return Invoke-CachedTool -ToolName 'SearchGoogleRendered' -ArgsObject $toolArgs -MaxAgeHours 6 -Action {
    try {
        $node = Get-Command node -ErrorAction Stop
        $helper = Join-Path -Path $PSScriptRoot -ChildPath 'tools\Search-GoogleRendered.js'
        if (-not (Test-Path -LiteralPath $helper)) {
            return "Google rendered search failed: helper not found at $helper"
        }

        $output = & $node.Source @($helper, $query, '70000') 2>&1
        $exitCode = $LASTEXITCODE
        $text = ($output | Out-String).Trim()
        if ($exitCode -ne 0) {
            return "Google rendered search failed with exit code ${exitCode}: $text"
        }
        if ($text -match '"blockedByGoogle"\s*:\s*true' -or $text -match "(?i)I'm not a robot|unusual traffic|reCAPTCHA|detected unusual traffic") {
            $script:AgentGoogleSearchCalls = 2
            return "Google rendered search blocked by Google anti-bot/reCAPTCHA for this automated browser session. Do not retry Google in this run. Use the vendor-first official regional URLs already provided, fetch official/vendor pages with FetchRenderedUrlText, and only use Microsoft Update Catalog as fallback.`n$text"
        }
        return $text
    } catch {
        return "Google rendered search failed: $($_.Exception.Message)"
    }
    }
}

# Tool: SearchGoogleCustom
function SearchGoogleCustom {
    param([string]$query)

    $apiKey = $env:GOOGLE_CUSTOM_SEARCH_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey)) { $apiKey = $env:GOOGLE_CSE_API_KEY }
    $cx = $env:GOOGLE_CUSTOM_SEARCH_CX
    if ([string]::IsNullOrWhiteSpace($cx)) { $cx = $env:GOOGLE_CSE_CX }

    if ([string]::IsNullOrWhiteSpace($apiKey) -or [string]::IsNullOrWhiteSpace($cx)) {
        return "Google Custom Search API is not configured. Set GOOGLE_CUSTOM_SEARCH_API_KEY and GOOGLE_CUSTOM_SEARCH_CX, then retry. Use official vendor candidates and FetchRenderedUrlText without Google API for this run."
    }

    $toolArgs = [pscustomobject]@{ query = $query; cx = $cx; gl = 'gr'; policy = 'GoogleCustomSearchOfficialApiV1' }
    return Invoke-CachedTool -ToolName 'GoogleCustomSearchOfficialApiV1' -ArgsObject $toolArgs -MaxAgeHours 12 -Action {
    try {
        $escapedQuery = [Uri]::EscapeDataString($query)
        $escapedCx = [Uri]::EscapeDataString($cx)
        $escapedKey = [Uri]::EscapeDataString($apiKey)
        $url = "https://www.googleapis.com/customsearch/v1?key=$escapedKey&cx=$escapedCx&q=$escapedQuery&gl=gr&hl=en&num=10"
        $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 25
        $items = @($response.items)
        if ($items.Count -eq 0) {
            return "Google Custom Search API returned no results."
        }
        $results = foreach ($item in $items | Select-Object -First 10) {
            [pscustomobject]@{
                title       = [string]$item.title
                link        = [string]$item.link
                displayLink = [string]$item.displayLink
                snippet     = [string]$item.snippet
            }
        }
        return ($results | ConvertTo-Json -Depth 5)
    } catch {
        $body = Get-WebExceptionBody -ErrorRecord $_
        if ([string]::IsNullOrWhiteSpace($body)) { $body = $_.Exception.Message }
        return "Google Custom Search API failed: $body"
    }
    }
}

# Tool: FetchUrlText
function FetchUrlText {
    param([string]$url)
    $toolArgs = [pscustomobject]@{ url = $url }
    $script:AgentOfficialFetchAttempts++
    return Invoke-CachedTool -ToolName 'FetchUrlText' -ArgsObject $toolArgs -MaxAgeHours 12 -Action {
    try {
        $response = Invoke-WebRequest -Uri $url -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -TimeoutSec 15 -UseBasicParsing
        $content = $response.Content
        
        # Extract links ending with driver extensions
        $uriObj = [System.Uri]$url
        $linkMatches = [regex]::Matches($content, 'href="([^"]+\.(?:zip|exe|cab|inf|msi))"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $links = @()
        foreach ($lm in $linkMatches) {
            $rawLink = $lm.Groups[1].Value
            try {
                $absLink = New-Object System.Uri($uriObj, $rawLink)
                $links += $absLink.AbsoluteUri
            } catch {
                $links += $rawLink
            }
        }
        $links = $links | Select-Object -Unique
        
        # Clean HTML tags to extract raw text
        $text = $content -replace '<script[^>]*>[\s\S]*?</script>', ''
        $text = $text -replace '<style[^>]*>[\s\S]*?</style>', ''
        $text = $text -replace '<[^>]+>', ' '
        $text = $text -replace '\s+', ' '
        $text = $text.Trim()
        
        $snippet = if ($text.Length -gt 2500) { $text.Substring(0, 2500) + "..." } else { $text }
        
        return @{
            TextSnippet = $snippet
            DriverLinks = ($links -join "; ")
        } | ConvertTo-Json
    } catch {
        return "Failed to fetch webpage: $($_.Exception.Message)"
    }
    }
}

# Tool: FetchRenderedUrlText
function FetchRenderedUrlText {
    param(
        [string]$url,
        [string]$targetText,
        [string]$inputText
    )

    $toolArgs = [pscustomobject]@{ url = $url; targetText = $targetText; inputText = $inputText }
    $script:AgentOfficialFetchAttempts++
    return Invoke-CachedTool -ToolName 'FetchRenderedUrlText' -ArgsObject $toolArgs -MaxAgeHours 12 -Action {
    try {
        $node = Get-Command node -ErrorAction Stop
        $helper = Join-Path -Path $PSScriptRoot -ChildPath 'tools\Fetch-RenderedPage.js'
        if (-not (Test-Path -LiteralPath $helper)) {
            return "Rendered browser fetch failed: helper not found at $helper"
        }

        $arguments = @($helper, $url)
        if (-not [string]::IsNullOrWhiteSpace($targetText)) {
            $arguments += $targetText
        }
        if (-not [string]::IsNullOrWhiteSpace($inputText)) {
            $arguments += $inputText
        }
        $arguments += '70000'

        $output = & $node.Source @arguments 2>&1
        $exitCode = $LASTEXITCODE
        $text = ($output | Out-String).Trim()
        if ($exitCode -ne 0) {
            return "Rendered browser fetch failed with exit code ${exitCode}: $text"
        }
        return $text
    } catch {
        return "Rendered browser fetch failed: $($_.Exception.Message)"
    }
    }
}

# Tool: SearchUpdateCatalog
function SearchUpdateCatalog {
    param([string]$hardwareId)
    $toolArgs = [pscustomobject]@{ hardwareId = $hardwareId }
    return Invoke-CachedTool -ToolName 'SearchUpdateCatalog' -ArgsObject $toolArgs -MaxAgeHours 24 -Action {
    try {
        $escaped = [Uri]::EscapeDataString($hardwareId)
        $catalogUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=$escaped"
        $response = Invoke-WebRequest -Uri $catalogUrl -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -UseBasicParsing -TimeoutSec 15
        $content = $response.Content
        
        $rowMatches = [regex]::Matches($content, '<tr[^>]*id="[^"]+_R\d+"[^>]*>([\s\S]*?)</tr>')
        $results = @()
        
        # Take top 3 matching drivers
        $maxCount = [Math]::Min(3, $rowMatches.Count)
        for ($k = 0; $k -lt $maxCount; $k++) {
            $row = $rowMatches[$k]
            $cells = [regex]::Matches($row.Groups[1].Value, '<td[^>]*>([\s\S]*?)</td>')
            if ($cells.Count -ge 7) {
                $title = ($cells[1].Groups[1].Value -replace '<[^>]+>', '').Trim()
                $products = ($cells[2].Groups[1].Value -replace '<[^>]+>', '').Trim()
                $updated = ($cells[4].Groups[1].Value -replace '<[^>]+>', '').Trim()
                $size = ($cells[6].Groups[1].Value -replace '<[^>]+>', '').Trim()
                
                # Extract GUID from row ID
                $updateId = ""
                if ($row.Value -match 'id="([^"]+)_R\d+"') {
                    $updateId = $Matches[1]
                }
                
                # Fetch cabinet download link from DownloadDialog.aspx
                $downloadUrl = "N/A"
                if ($updateId) {
                    try {
                        $jsonPayload = "[{`"updateID`": `"$updateId`", `"size`": 0, `"languages`": `"`", `"uidInfo`": `"$updateId`", `"title`": `"`"}]"
                        $postBody = "updateIDs=" + [Uri]::EscapeDataString($jsonPayload)
                        $dialogUrl = "https://www.catalog.update.microsoft.com/DownloadDialog.aspx"
                        $dr = Invoke-WebRequest -Uri $dialogUrl -Method Post -Body $postBody -ContentType "application/x-www-form-urlencoded" -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -UseBasicParsing -TimeoutSec 10
                        if ($dr.Content -match "downloadInformation\[0\]\.files\[0\]\.url\s*=\s*'([^']+)'") {
                            $downloadUrl = $Matches[1]
                        }
                    } catch {}
                }
                
                $results += "Title: $title | Products: $products | Updated: $updated | Size: $size | DownloadLink: $downloadUrl"
            }
        }
        if ($results.Count -eq 0) { return "No drivers found in Microsoft Update Catalog for: $hardwareId" }
        return ($results -join "`n")
    } catch {
        return "Catalog search failed: $($_.Exception.Message)"
    }
    }
}

function FindDeterministicVendorDownloads {
    param(
        [string]$Name,
        [string]$HwId,
        [string]$Maker
    )

    $hints = [System.Collections.Generic.List[string]]::new()
    $sourceText = "$Name $HwId $Maker"

    if ($sourceText -match '(?i)\bAOC\b' -or $HwId -match '(?i)^MONITOR\\AOC') {
        $model = $null
        if ($sourceText -match '(?i)\b([0-9]{2}[A-Z0-9]{2,8})\b') {
            $model = $Matches[1].ToUpperInvariant()
        }
        if ($model) {
            $regions = @('gr', 'eu', 'uk', 'us')
            foreach ($region in $regions) {
                $url = "https://www.aoc.com/$region/gaming/monitors/$($model.ToLowerInvariant())"
                $null = Write-AgentEvent -Type 'Log' -Message "[Deterministic] AOC rendered check region=$region url=$url" -Data @{ Vendor = 'AOC'; Region = $region; Url = $url; Model = $model }
                $result = FetchRenderedUrlText -url $url -targetText 'DRIVERS AND MANUALS|Drivers & Manuals|Drivers' -inputText ''
                if ($result -match '(?i)DRIVERS\s*&\s*MANUALS|DOWNLOAD ZIP|DOWNLOAD EXE|downloadLinks') {
                    $hints.Add("AOC deterministic match ($region): $result")
                    break
                }
                if ($result -match '(?i)404|Page not found|Could not find requested resource') {
                    $hints.Add("AOC deterministic miss ($region): $url")
                }
            }
        } else {
            $hints.Add("AOC deterministic hint: AOC-like monitor detected, but no model token was extracted from '$sourceText'.")
        }
    }

    if ($hints.Count -eq 0) {
        return "No deterministic vendor adapter matched before Gemini. Continue with Gemini planning and available tools."
    }
    return ($hints -join "`n")
}

# Define Tools schema
$functionDeclarations = @(
    @{
        name = "SearchGoogleRendered"
        description = "Fragile fallback only. Opens Google Search in a real local Chrome/Edge browser via DevTools and returns AI Overview text as a hint plus top organic result URLs/snippets. Google may return anti-bot/reCAPTCHA; do not loop if blocked. Prefer SearchGoogleCustom when configured, and always confirm final answers by fetching official/vendor pages with FetchRenderedUrlText."
        parameters = @{
            type = "OBJECT"
            properties = @{
                query = @{ type = "STRING"; description = 'A focused query built from local Device Manager evidence, preferably a multiline block with FriendlyName, InstanceId, HardwareId, Manufacturer, CompatibleId, Service, and Driver/INF.' }
            }
            required = @("query")
        }
    },
    @{
        name = "SearchGoogleCustom"
        description = "Preferred Google discovery tool when configured. Uses the official Google Custom Search JSON API, avoiding browser SERP automation and reCAPTCHA. Returns result title, link, displayLink, and snippet. Requires GOOGLE_CUSTOM_SEARCH_API_KEY and GOOGLE_CUSTOM_SEARCH_CX environment variables."
        parameters = @{
            type = "OBJECT"
            properties = @{
                query = @{ type = "STRING"; description = 'A focused query built from local Device Manager evidence or model/manufacturer terms. Use this for discovery before fetching official/vendor URLs.' }
            }
            required = @("query")
        }
    },
    @{
        name = "FetchUrlText"
        description = "Fetches the text content of a webpage and any direct download links (.zip, .exe, .cab) found on it."
        parameters = @{
            type = "OBJECT"
            properties = @{
                url = @{ type = "STRING"; description = "The URL of the webpage to fetch" }
            }
            required = @("url")
        }
    },
    @{
        name = "FetchRenderedUrlText"
        description = "Opens a real local Chrome browser via DevTools Protocol, waits for JavaScript-rendered content, optionally clicks a visible tab/category by text, then returns rendered page text and download links. Use this for OEM support pages that block plain HTTP fetches or require JavaScript, especially MSI support pages."
        parameters = @{
            type = "OBJECT"
            properties = @{
                url = @{ type = "STRING"; description = "The support page URL to open in Chrome" }
                targetText = @{ type = "STRING"; description = "Optional visible tab/category text to click, e.g. 'On-Board Audio Drivers', 'LAN Drivers', 'BIOS', 'Driver', 'Search', or 'Downloads'" }
                inputText = @{ type = "STRING"; description = "Optional text to type into the most relevant visible search/product/model input after targetText is clicked, e.g. '27G4HRE'" }
            }
            required = @("url")
        }
    },
    @{
        name = "SearchUpdateCatalog"
        description = "Searches the Microsoft Update Catalog for drivers by Hardware ID."
        parameters = @{
            type = "OBJECT"
            properties = @{
                hardwareId = @{ type = "STRING"; description = "The hardware ID of the device (e.g., USB\VID_0DB0&PID_CD0E)" }
            }
            required = @("hardwareId")
        }
    }
)

# Prepare prompt context
$systemDetails = @"
Device Info:
- Name: $DeviceName
- InstanceId: $InstanceId
- HardwareId: $HardwareId
- Manufacturer: $Manufacturer
- InstalledDriver: $InstalledDriver

System Info:
- Motherboard: $Motherboard
- CPU: $Cpu
- OS: $Os
"@

$localEvidenceSection = ''
if (-not [string]::IsNullOrWhiteSpace($EvidenceJson)) {
    $evidencePreview = $EvidenceJson
    if ($evidencePreview.Length -gt 16000) {
        $evidencePreview = $evidencePreview.Substring(0, 16000) + '...[truncated]'
    }
    $localEvidenceSection = @"

Local Device Evidence JSON:
$evidencePreview
"@
}

$agentGuide = @"
Driver search policy:
1. Prefer the official OEM/support source for this exact machine or motherboard first.
2. If motherboard/system model is known, construct or retrieve the OEM support page and use rendered retrieval on that page before using generic web search or Microsoft Update Catalog.
3. When vendor pages are regional, try Greece/Europe regional official pages first (for example /gr, /eu, /uk or local-language pages), then US/global. A US "not found" is not proof that no driver exists.
4. If you have a direct official support/download URL, call FetchRenderedUrlText on that URL. Do not pass direct URLs into search tools.
5. For MSI, AOC, Dell, HP, Lenovo, ASUS, Gigabyte, or JavaScript-heavy OEM support pages, use FetchRenderedUrlText and click the matching category text when useful (for example On-Board Audio Drivers, LAN Drivers, BIOS, Driver, Drivers, Downloads, Support). Plain FetchUrlText may fail with 403 or miss tab content.
6. For AOC monitor driver/software searches, use FetchRenderedUrlText with a regional AOC product/support page before trying Microsoft Update Catalog.
7. For search discovery, SearchGoogleRendered is available again for testing because Google Search + AI Overview may provide strong model identity hints. Use it carefully: one focused raw Device Manager-style evidence query first, then fetch official/vendor pages. If it returns anti-bot/reCAPTCHA, do not retry it in the same run. Build queries from raw local evidence: FriendlyName, InstanceId, HardwareId, Manufacturer, CompatibleId, Service, and installed INF/driver version. Treat AI Overview as a strong model-identity hint only; confirm driver/version/download links by fetching official/vendor URLs.
8. Microsoft Update Catalog is fallback evidence, not the primary answer, unless the device is generic or no OEM/vendor package can be found.
9. If an official support page fetch fails with 403/blocked HTML or search returns an anti-bot challenge, do not treat that as "no OEM driver". Use FetchRenderedUrlText before falling back to Microsoft Update Catalog.
10. Do not claim "latest" unless you have a version/date from an official page, official download URL, or Microsoft Catalog row.
11. Final answer must separate source quality: Official OEM, Official vendor, Microsoft Catalog, or Web snippet only.
"@

$messages = [System.Collections.Generic.List[object]]::new()
$memory = New-AgentMemory
$resumeState = $null
$resumeReason = $null
$resumeStep = 0

if (-not [string]::IsNullOrWhiteSpace($CheckpointPath) -and (Test-Path -LiteralPath $CheckpointPath)) {
    try {
        $checkpoint = Get-Content -LiteralPath $CheckpointPath -Raw | ConvertFrom-Json
        if ($checkpoint.state -in @('PausedRateLimit', 'PausedBudget')) {
            foreach ($message in @($checkpoint.messages)) {
                if ($null -ne $message) { $messages.Add($message) }
            }
            $memory = Convert-CheckpointMemory -CheckpointMemory $checkpoint.memory
            $resumeState = [string]$checkpoint.state
            $resumeReason = [string]$checkpoint.reason
            $resumeStep = [int]$checkpoint.step
        }
    } catch {
        Write-AgentEvent -Type 'Log' -Message "[Checkpoint] Existing checkpoint could not be loaded: $($_.Exception.Message)" -Data @{ Path = $CheckpointPath }
    }
}

Write-AgentEvent -Type 'Log' -Message "[Agent] Started for: $(Format-AgentLogValue -Value $DeviceName -MaxLength 120)" -Data @{
    DeviceName      = $DeviceName
    InstanceId      = $InstanceId
    HardwareId      = $HardwareId
    Manufacturer    = $Manufacturer
    InstalledDriver = $InstalledDriver
    Motherboard     = $Motherboard
    Cpu             = $Cpu
    Os              = $Os
    Model           = $resolvedModelName
    CheckpointPath  = $CheckpointPath
    ToolCacheRoot   = $ToolCacheRoot
    MaxIterations   = $MaxIterations
}

$script:AgentSearchWebCalls = 0
$script:AgentGoogleSearchCalls = 0
$script:AgentOfficialFetchAttempts = 0
$script:AgentVendorFirstCandidates = @(Get-VendorFirstCandidates -Name $DeviceName -HwId $HardwareId -Maker $Manufacturer -Board $Motherboard)
$vendorFirstGuidance = Format-VendorCandidateGuidance -Candidates $script:AgentVendorFirstCandidates
Write-AgentEvent -Type 'Log' -Message "[Deterministic] Vendor-first candidates: $(@($script:AgentVendorFirstCandidates).Count)" -Data @{ Candidates = $script:AgentVendorFirstCandidates }

$deterministicEvidence = FindDeterministicVendorDownloads -Name $DeviceName -HwId $HardwareId -Maker $Manufacturer
$googleQueries = @(Get-GoogleSearchQueries)
$googleDiscoveryEvidence = ''
if (@($script:AgentVendorFirstCandidates).Count -eq 0 -and $googleQueries.Count -gt 0) {
    if ((-not [string]::IsNullOrWhiteSpace($env:GOOGLE_CUSTOM_SEARCH_API_KEY) -or -not [string]::IsNullOrWhiteSpace($env:GOOGLE_CSE_API_KEY)) -and
        (-not [string]::IsNullOrWhiteSpace($env:GOOGLE_CUSTOM_SEARCH_CX) -or -not [string]::IsNullOrWhiteSpace($env:GOOGLE_CSE_CX))) {
        Write-AgentEvent -Type 'Log' -Message "[Google] Custom Search API query: $(Format-AgentLogValue -Value $googleQueries[0] -MaxLength 180)" -Data @{ Query = $googleQueries[0] }
        $googleDiscoveryEvidence = SearchGoogleCustom -query $googleQueries[0]
    } else {
        Write-AgentEvent -Type 'Log' -Message "[Google] Skipped automatic search because Google Custom Search API is not configured. Browser Google search is reserved for explicit Gemini fallback/diagnostic to avoid reCAPTCHA loops." -Data @{ Query = $googleQueries[0] }
    }
} elseif ($googleQueries.Count -gt 0) {
    Write-AgentEvent -Type 'Log' -Message "[Google] Skipped automatic search because official vendor-first candidates exist. Gemini may call SearchGoogleCustom after official candidates are insufficient." -Data @{ Query = $googleQueries[0]; VendorCandidateCount = @($script:AgentVendorFirstCandidates).Count }
}
$deterministicEvidence = "$deterministicEvidence`n`n$vendorFirstGuidance"
if (-not [string]::IsNullOrWhiteSpace($googleDiscoveryEvidence)) {
    $deterministicEvidence = "$deterministicEvidence`n`nGoogle Custom Search discovery evidence (confirm final answer on official/vendor URLs):`n$googleDiscoveryEvidence"
}
$memory.CurrentPlan = 'Deterministic evidence collected before Gemini. Gemini should synthesize directly if sufficient, otherwise call the smallest useful tool next.'
if ($deterministicEvidence -notmatch '^No deterministic vendor adapter matched') {
    Add-AgentMemoryFromTool -Memory $memory -Step 0 -Tool 'FindDeterministicVendorDownloads' -ArgsObject ([pscustomobject]@{ name = $DeviceName; hardwareId = $HardwareId; manufacturer = $Manufacturer }) -Result $deterministicEvidence
}

if ($messages.Count -eq 0) {
    $messages.Add(@{
        role = "user"
        parts = @( @{ text = "You are an autonomous hardware support assistant. Your only goal is to identify the correct hardware model and the correct driver download link(s). Ignore PDFs, manuals, utilities, unrelated software, and generic explanations unless no driver package exists. Use deterministic evidence and vendor-first candidates before search. If discovery is needed, use one focused SearchGoogleRendered query built from raw local Device Manager-style evidence, then fetch the best official/vendor result with FetchRenderedUrlText. Prefer Greece/Europe regional official pages before US/global pages. If deterministic or Google evidence already contains official driver links, synthesize the final answer instead of searching again. Use Local Device Evidence JSON to identify exact hardware IDs, original INF names, provider, installed version/date, parent/child devices, and model hints. Ensure you specify version/date when available, source quality, and direct download URLs.`n`n$agentGuide`n`n$systemDetails$localEvidenceSection`n`nDeterministic prefetch evidence:`n$deterministicEvidence" } )
    })
} else {
    $messages.Add(@{
        role = 'user'
        parts = @( @{ text = "Resume the previous driver-finder run from checkpoint state '$resumeState'. Reason: $resumeReason. Do not repeat cached tool calls unless the previous evidence is insufficient. Use this fresh deterministic prefetch evidence if useful:`n$deterministicEvidence" } )
    })
    Write-AgentEvent -Type 'Log' -Message "[Checkpoint] Resuming from $resumeState at previous step $resumeStep" -Data @{ Path = $CheckpointPath; State = $resumeState; Step = $resumeStep }
}

Write-AgentEvent -Type 'Log' -Message "[Deterministic] $(Format-AgentLogValue -Value $deterministicEvidence -MaxLength 220)" -Data @{ Result = $deterministicEvidence }
Save-AgentCheckpoint -State 'Running' -Step 0 -Messages $messages -Memory $memory -Reason 'Agent initialized.' -RetryAfterSeconds $null

    $loop = $true
    $iterations = 0
    $maxIterations = [Math]::Max(1, $MaxIterations)
    
    while ($loop -and $iterations -lt $maxIterations) {
        $iterations++
        Write-AgentEvent -Type 'Log' -Message "[Gemini] Step ${iterations}: asking model for next action" -Data @{ Step = $iterations }
        
        $toolsList = [System.Collections.Generic.List[object]]::new()
        $toolsList.Add(@{ google_search = @{} })
        if ($functionDeclarations.Count -gt 0) {
            $toolsList.Add(@{ functionDeclarations = $functionDeclarations })
        }

        $body = @{
            contents = $messages.ToArray()
            tools = $toolsList.ToArray()
        } | ConvertTo-Json -Depth 10
        
        try {
            $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 30
        } catch {
            $apiErrorBody = Get-WebExceptionBody -ErrorRecord $_
            $statusCode = Get-WebExceptionStatusCode -ErrorRecord $_
            $retryAfterSeconds = Get-WebExceptionRetryAfterSeconds -ErrorRecord $_
            $apiError = "API Error: $($_.Exception.Message)"
            if (-not [string]::IsNullOrWhiteSpace($apiErrorBody)) {
                $apiError = "$apiError $apiErrorBody"
            }
            if ($statusCode -eq 429 -or $apiError -match '(?i)429|rate limit|quota') {
                $reason = "Rate limit hit while asking Gemini at step $iterations. Checkpoint saved; resume later without repeating completed tool results."
                Save-AgentCheckpoint -State 'PausedRateLimit' -Step $iterations -Messages $messages -Memory $memory -Reason $reason -RetryAfterSeconds $retryAfterSeconds
                Write-AgentEvent -Type 'PausedRateLimit' -Message $reason -Data @{ Step = $iterations; ApiError = $apiErrorBody; RetryAfterSeconds = $retryAfterSeconds; CheckpointPath = $CheckpointPath }
                return
            }
            Save-AgentCheckpoint -State 'Error' -Step $iterations -Messages $messages -Memory $memory -Reason $apiError -RetryAfterSeconds $null
            Write-AgentEvent -Type 'Error' -Message $apiError -Data @{ Step = $iterations; ApiError = $apiErrorBody }
            return
        }
        
        if (-not $response -or -not $response.candidates -or $response.candidates.Count -eq 0) {
            Save-AgentCheckpoint -State 'Error' -Step $iterations -Messages $messages -Memory $memory -Reason 'Empty API response.' -RetryAfterSeconds $null
            Write-AgentEvent -Type 'Error' -Message "Empty API response." -Data @{ Step = $iterations }
            return
        }
        
        $candidate = $response.candidates[0]
        
        # Process grounding metadata if present (Google Search Grounding sources)
        if ($candidate.PSObject.Properties['groundingMetadata'] -and $null -ne $candidate.groundingMetadata) {
            $gm = $candidate.groundingMetadata
            $queriesText = ""
            if ($gm.PSObject.Properties['webSearchQueries'] -and $null -ne $gm.webSearchQueries) {
                $queriesText = ($gm.webSearchQueries -join ", ")
            }
            
            $chunksText = [System.Collections.Generic.List[string]]::new()
            if ($gm.PSObject.Properties['groundingChunks'] -and $null -ne $gm.groundingChunks) {
                foreach ($chunk in @($gm.groundingChunks)) {
                    if ($chunk.PSObject.Properties['web'] -and $null -ne $chunk.web) {
                        $web = $chunk.web
                        $title = $web.title
                        $uri = $web.uri
                        $chunksText.Add("$title ($uri)")
                        # Add to candidate and confirmed URLs
                        if (-not $memory.CandidateUrls.Contains($uri)) {
                            $memory.CandidateUrls.Add($uri)
                        }
                        if (-not $memory.ConfirmedUrls.Contains($uri)) {
                            $memory.ConfirmedUrls.Add($uri)
                        }
                    }
                }
            }
            
            if ($queriesText -or $chunksText.Count -gt 0) {
                $logMessage = "[Google Grounding] Queries: $queriesText"
                if ($chunksText.Count -gt 0) {
                    $logMessage += " | Sources: " + ($chunksText -join "; ")
                }
                Write-AgentEvent -Type 'Log' -Message $logMessage -Data @{
                    Step = $iterations
                    Queries = $gm.webSearchQueries
                    Chunks = $gm.groundingChunks
                }
            }
        }

        $part = $candidate.content.parts[0]
        $functionCallProperty = $part.PSObject.Properties['functionCall']
        $textProperty = $part.PSObject.Properties['text']
        
        if ($functionCallProperty -and $null -ne $functionCallProperty.Value) {
            $functionCall = $functionCallProperty.Value
            $funcName = $functionCall.name
            $args = $functionCall.args
            Write-AgentEvent -Type 'Log' -Message "[Gemini] Requested tool: $funcName $(Format-AgentArgs -ArgsObject $args)" -Data @{
                Step = $iterations
                Tool = $funcName
                Args = $args
            }
    
            # Execute tool locally
            $toolResult = $null
            switch ($funcName) {
                "SearchWeb" { $toolResult = SearchWeb -query $args.query }
                "SearchGoogleCustom" { $toolResult = SearchGoogleCustom -query $args.query }
                "SearchGoogleRendered" { $toolResult = SearchGoogleRendered -query $args.query }
                "FetchUrlText" { $toolResult = FetchUrlText -url $args.url }
                "FetchRenderedUrlText" { $toolResult = FetchRenderedUrlText -url $args.url -targetText $args.targetText -inputText $args.inputText }
                "SearchUpdateCatalog" { $toolResult = SearchUpdateCatalog -hardwareId $args.hardwareId }
                default { $toolResult = "Error: Unknown function '$funcName'" }
            }
            Write-AgentEvent -Type 'Log' -Message "[Tool Result] $funcName -> $(Format-AgentLogValue -Value $toolResult)" -Data @{
                Step = $iterations
                Tool = $funcName
                Result = $toolResult
            }
            Add-AgentMemoryFromTool -Memory $memory -Step $iterations -Tool $funcName -ArgsObject $args -Result $toolResult
    
            # Preserve the full model content, including thoughtSignature metadata required by Gemini 3 tool calls.
            $messages.Add($candidate.content)
            
            $messages.Add(@{
                role = "tool"
                parts = @( @{
                    functionResponse = @{
                        name = $funcName
                        response = @{ result = $toolResult }
                    }
                } )
            })
            Save-AgentCheckpoint -State 'Running' -Step $iterations -Messages $messages -Memory $memory -Reason "Completed tool call $funcName." -RetryAfterSeconds $null
        } elseif ($textProperty -and -not [string]::IsNullOrWhiteSpace([string]$textProperty.Value)) {
            # Final answer received
            $finalAnswer = ([string]$textProperty.Value).Trim()
            Write-AgentEvent -Type 'Log' -Message "[Gemini] Final answer received" -Data @{ Step = $iterations }
            Save-AgentCheckpoint -State 'Done' -Step $iterations -Messages $messages -Memory $memory -Reason 'Final answer received.' -RetryAfterSeconds $null
            Write-AgentEvent -Type 'Result' -Message $finalAnswer -Data @{ Step = $iterations; FinalAnswer = $finalAnswer }
            $loop = $false
        } else {
            $reason = "Gemini returned a response without text or functionCall."
            Save-AgentCheckpoint -State 'Error' -Step $iterations -Messages $messages -Memory $memory -Reason $reason -RetryAfterSeconds $null
            Write-AgentEvent -Type 'Error' -Message $reason -Data @{ Step = $iterations; Content = $candidate.content }
            return
        }
    }

if ($loop -and $iterations -ge $maxIterations) {
    $reason = "Agent paused at budget guard after $maxIterations Gemini steps. Checkpoint saved; run the agent again to continue."
    Save-AgentCheckpoint -State 'PausedBudget' -Step $iterations -Messages $messages -Memory $memory -Reason $reason -RetryAfterSeconds $null
    Write-AgentEvent -Type 'PausedBudget' -Message $reason -Data @{ MaxIterations = $maxIterations; CheckpointPath = $CheckpointPath }
}
