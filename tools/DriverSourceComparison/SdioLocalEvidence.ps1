[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '', Justification = 'Repository policy uses UTF-8 without BOM for PowerShell source.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are consumed inside benchmarked scriptblock closures that PSScriptAnalyzer does not trace.')]
param()

Set-StrictMode -Version Latest

function Resolve-DriverComparisonSdioRoot {
    param([AllowEmptyString()][string]$RequestedRoot = '')

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $candidates.Add($RequestedRoot)
    }
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$drive.Root)) {
            $candidates.Add((Join-Path $drive.Root 'SDIO'))
        }
    }
    foreach ($fallback in @(
            (Join-Path $env:USERPROFILE 'SDIO'),
            (Join-Path $env:USERPROFILE 'Programs\SDIO'),
            'D:\Programs\SDIO'
        )) {
        $candidates.Add($fallback)
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        $exe = Get-ChildItem -LiteralPath $candidate -Filter 'SDIO_x64_*.exe' -File -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        $drivers = Join-Path $candidate 'drivers'
        $indexes = Join-Path $candidate 'indexes\SDIO'
        if ($null -ne $exe -and
            (Test-Path -LiteralPath $drivers -PathType Container) -and
            (Test-Path -LiteralPath $indexes -PathType Container)) {
            return [pscustomobject]@{
                Root       = (Resolve-Path -LiteralPath $candidate).ProviderPath
                Exe        = $exe.FullName
                Drivers    = (Resolve-Path -LiteralPath $drivers).ProviderPath
                Indexes    = (Resolve-Path -LiteralPath $indexes).ProviderPath
                ConfigPath = Join-Path $candidate 'sdio.cfg'
            }
        }
    }

    return $null
}

function ConvertTo-DriverComparisonDate {
    param([AllowEmptyString()][string]$Text)

    [datetime]$value = [datetime]::MinValue
    foreach ($culture in @([Globalization.CultureInfo]::InvariantCulture, [Globalization.CultureInfo]::CurrentCulture)) {
        if ([datetime]::TryParse($Text, $culture, [Globalization.DateTimeStyles]::None, [ref]$value)) {
            return $value.Date
        }
    }
    return $null
}

function Get-DriverComparisonVersionRelation {
    param(
        [AllowEmptyString()][string]$CandidateDate,
        [AllowEmptyString()][string]$CandidateVersion,
        [AllowEmptyString()][string]$ActiveDate,
        [AllowEmptyString()][string]$ActiveVersion
    )

    $candidateDateValue = ConvertTo-DriverComparisonDate $CandidateDate
    $activeDateValue = ConvertTo-DriverComparisonDate $ActiveDate
    if ($null -ne $candidateDateValue -and $null -ne $activeDateValue) {
        if ($candidateDateValue -gt $activeDateValue) { return 'NewerThanActive' }
        if ($candidateDateValue -lt $activeDateValue) { return 'OlderThanActive' }
    }

    try {
        $candidateVersionValue = [version]$CandidateVersion
        $activeVersionValue = [version]$ActiveVersion
        if ($candidateVersionValue -gt $activeVersionValue) { return 'NewerThanActive' }
        if ($candidateVersionValue -lt $activeVersionValue) { return 'OlderThanActive' }
        return 'SameAsActive'
    }
    catch {
        if ($CandidateVersion -eq $ActiveVersion) { return 'SameAsActive' }
    }
    return 'Unknown'
}

function Resolve-SdioAuditPackPath {
    param(
        [AllowEmptyString()][string]$RawPackName,
        [string]$DriverPackRoot
    )

    $fragment = [IO.Path]::GetFileName($RawPackName)
    if ([string]::IsNullOrWhiteSpace($fragment)) { return $null }
    $packMatches = @(Get-ChildItem -LiteralPath $DriverPackRoot -Filter '*.7z' -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name.EndsWith($fragment, [StringComparison]::OrdinalIgnoreCase)
        })
    if ($packMatches.Count -eq 1) { return $packMatches[0].FullName }
    return $null
}

function Resolve-DriverComparison7ZipPath {
    $candidates = @(
        $(try { (Get-Command 7z.exe -ErrorAction Stop).Source } catch { $null }),
        (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe' })
    )
    return @($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique | Select-Object -First 1)
}

function Get-SdioPackFamilyToken {
    param([AllowEmptyString()][string]$RawPackName)

    $leaf = [IO.Path]::GetFileNameWithoutExtension($RawPackName)
    $leaf = $leaf -replace '^DP_', '' -replace '_\d{5}$', ''
    return @($leaf -split '[^A-Za-z]+' | Where-Object { $_.Length -ge 4 } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
}

function Get-SdioArchiveInfPath {
    param(
        [string]$SevenZipPath,
        [string]$PackPath,
        [hashtable]$PathCache
    )

    if ($PathCache.ContainsKey($PackPath)) { return @($PathCache[$PackPath]) }
    $paths = @(
        & $SevenZipPath l -slt -- $PackPath |
            Select-String '^Path = .*\.inf$' |
            ForEach-Object { $_.Line.Substring(7) }
    )
    if ($LASTEXITCODE -ne 0) { return @() }
    $PathCache[$PackPath] = @($paths)
    return @($paths)
}

function Read-SdioArchiveInfText {
    param(
        [string]$SevenZipPath,
        [string]$PackPath,
        [string]$InfPath,
        [hashtable]$TextCache
    )

    $key = "$PackPath|$InfPath"
    if ($TextCache.ContainsKey($key)) { return [string]$TextCache[$key] }
    $text = (& $SevenZipPath e -so -- $PackPath $InfPath | Out-String) -replace "`0", '' -replace '^��', ''
    if ($LASTEXITCODE -ne 0) { return '' }
    $TextCache[$key] = $text
    return $text
}

function Resolve-SdioCandidateFromCurrentArchive {
    param(
        $Candidate,
        [string]$DriverPackRoot,
        [hashtable]$PathCache,
        [hashtable]$TextCache
    )

    $sevenZip = @(Resolve-DriverComparison7ZipPath) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace([string]$sevenZip)) { return $null }
    $tokens = @(Get-SdioPackFamilyToken -RawPackName ([string]$Candidate.PackName))
    if ($tokens.Count -eq 0) { return $null }

    $packs = @(Get-ChildItem -LiteralPath $DriverPackRoot -Filter '*.7z' -File -ErrorAction SilentlyContinue | Where-Object {
            $name = $_.BaseName.ToLowerInvariant()
            @($tokens | Where-Object { $name.Contains($_) }).Count -gt 0
        })
    $candidateInfName = [IO.Path]::GetFileName([string]$Candidate.InfFile)
    foreach ($pack in $packs) {
        $infPaths = @(Get-SdioArchiveInfPath -SevenZipPath $sevenZip -PackPath $pack.FullName -PathCache $PathCache | Where-Object {
                [IO.Path]::GetFileName($_) -ieq $candidateInfName
            })
        foreach ($infPath in $infPaths) {
            $text = Read-SdioArchiveInfText -SevenZipPath $sevenZip -PackPath $pack.FullName -InfPath $infPath -TextCache $TextCache
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            if ($text.IndexOf([string]$Candidate.HardwareId, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $driverVerMatch = [regex]::Match($text, '(?im)^\s*DriverVer\s*=\s*(?<Date>[^,]+),\s*(?<Version>.+?)\s*$')
            if (-not $driverVerMatch.Success) { continue }
            $relation = Get-DriverComparisonVersionRelation `
                -CandidateDate $driverVerMatch.Groups['Date'].Value.Trim() `
                -CandidateVersion $driverVerMatch.Groups['Version'].Value.Trim() `
                -ActiveDate ([string]$Candidate.Date) `
                -ActiveVersion ([string]$Candidate.Version)
            if ($relation -ne 'SameAsActive') { continue }
            return [pscustomobject]@{
                PackPath = $pack.FullName
                InfPath  = $infPath
                Method   = 'ArchiveVerifiedFallback'
            }
        }
    }
    return $null
}

function Find-ReusableSdioMatcherLog {
    param(
        [Parameter(Mandatory)]$SdioPaths,
        [string]$RepoRoot,
        [string]$OutputRoot
    )

    $newestPack = Get-ChildItem -LiteralPath $SdioPaths.Drivers -Filter '*.7z' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $minimumTime = if ($null -ne $newestPack) { $newestPack.LastWriteTimeUtc } else { [datetime]::MinValue }
    $roots = @(
        (Join-Path $OutputRoot 'sdio-audits'),
        (Join-Path $RepoRoot '.devicecheck-data\sdio-advisor-audit'),
        (Join-Path $SdioPaths.Root 'logs')
    )
    $logs = @(
        foreach ($root in $roots) {
            if (Test-Path -LiteralPath $root -PathType Container) {
                Get-ChildItem -LiteralPath $root -Filter 'log.txt' -File -Recurse -ErrorAction SilentlyContinue
            }
        }
    ) | Where-Object { $_.Length -gt 0 -and $_.LastWriteTimeUtc -ge $minimumTime } | Sort-Object LastWriteTimeUtc -Descending

    foreach ($log in $logs) {
        $hasStart = Select-String -LiteralPath $log.FullName -SimpleMatch '{matcher_print' -Quiet
        $hasEnd = Select-String -LiteralPath $log.FullName -SimpleMatch '}matcher_print' -Quiet
        if ($hasStart -and $hasEnd) { return $log.FullName }
    }
    return ''
}

function Get-SdioFullAuditCachePath {
    param(
        [string]$LogPath,
        [string]$OutputRoot
    )

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($LogPath.ToLowerInvariant())
        $key = (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 20)
    }
    finally { $sha.Dispose() }
    return Join-Path $OutputRoot "sdio-full-cache\full-audit-$key.json"
}

function Import-ReusableSdioFullAudit {
    param(
        [string]$CachePath,
        [string]$LogPath
    )

    if (-not (Test-Path -LiteralPath $CachePath -PathType Leaf)) { return $null }
    try {
        $wrapper = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
        $log = Get-Item -LiteralPath $LogPath -ErrorAction Stop
        if ([string]$wrapper.LogPath -ne $log.FullName -or
            [long]$wrapper.LogLength -ne $log.Length -or
            $null -eq $wrapper.PSObject.Properties['LogLastWriteUtcTicks'] -or
            [long]$wrapper.LogLastWriteUtcTicks -ne $log.LastWriteTimeUtc.Ticks) {
            return $null
        }
        return $wrapper.Audit
    }
    catch {
        Write-Debug "Ignoring unreadable SDIO full-audit cache '$CachePath': $($_.Exception.Message)"
        return $null
    }
}

function Export-SdioFullAuditCache {
    param(
        $Audit,
        [string]$LogPath,
        [string]$CachePath
    )

    $log = Get-Item -LiteralPath $LogPath -ErrorAction Stop
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $CachePath) -Force
    [pscustomobject]@{
        SchemaVersion = 1
        LogPath = $log.FullName
        LogLength = $log.Length
        LogLastWriteUtc = $log.LastWriteTimeUtc.ToString('o')
        LogLastWriteUtcTicks = $log.LastWriteTimeUtc.Ticks
        Audit = $Audit
    } | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $CachePath -Encoding UTF8
}

function ConvertTo-DriverComparisonHardwareId {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value.Trim() -replace '^"|"$', '') -replace '\s+', '').ToUpperInvariant()
}

function Select-SdioAuditTargetDevice {
    param(
        $FullAudit,
        $LocalEvidence
    )

    $targetIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($LocalEvidence.Device.HardwareIds) + @($LocalEvidence.Device.CompatibleIds) + @($LocalEvidence.ActiveDriver.MatchingDeviceId)) {
        $normalized = ConvertTo-DriverComparisonHardwareId ([string]$id)
        if ($normalized) { [void]$targetIds.Add($normalized) }
    }
    $matched = @(
        foreach ($device in @($FullAudit.Devices)) {
            $deviceIds = @($device.HardwareIds) + @($device.CompatibleIds) + @($device.Installed.HardwareId) + @($device.Candidates | ForEach-Object HardwareId)
            $isMatch = $false
            foreach ($id in $deviceIds) {
                if ($targetIds.Contains((ConvertTo-DriverComparisonHardwareId ([string]$id)))) { $isMatch = $true; break }
            }
            if ($isMatch) { $device }
        }
    )
    return [pscustomobject]@{
        SchemaVersion      = $FullAudit.SchemaVersion
        GeneratedAt        = $FullAudit.GeneratedAt
        Source             = $FullAudit.Source
        Target             = [pscustomobject]@{
            InstanceId       = [string]$LocalEvidence.Device.InstanceId
            HardwareIds      = @($LocalEvidence.Device.HardwareIds)
            CompatibleIds    = @($LocalEvidence.Device.CompatibleIds)
            MatchingDeviceId = [string]$LocalEvidence.ActiveDriver.MatchingDeviceId
        }
        Paths              = $FullAudit.Paths
        Run                = $FullAudit.Run
        Warning            = @($FullAudit.Warning)
        ParserWarnings     = @($FullAudit.ParserWarnings)
        TotalDeviceCount   = $FullAudit.TotalDeviceCount
        MatchedDeviceCount = $matched.Count
        Devices            = $matched
    }
}

function Add-SdioLocalComparisonEvidence {
    param(
        [Parameter(Mandatory)]$Audit,
        [Parameter(Mandatory)]$LocalEvidence,
        $OemTraceEvidence,
        [Parameter(Mandatory)]$SdioPaths,
        $BenchmarkRecorder
    )

    $active = $LocalEvidence.ActiveDriver
    $normalized = [System.Collections.Generic.List[object]]::new()
    $indexOnly = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $archivePathCache = @{}
    $archiveTextCache = @{}

    $eligibleIndexCount = 0
    foreach ($device in @($Audit.Devices)) {
        $bestCandidates = @(
            $device.Candidates | Where-Object {
                $statusLabels = @($_.StatusLabels)
                ($statusLabels -contains 'NEW' -or $statusLabels -contains 'BETTER') -and
                $statusLabels -notcontains 'INVALID' -and
                $statusLabels -notcontains 'MISSING' -and
                $statusLabels -notcontains 'WORSE' -and
                $statusLabels -notcontains 'DUP'
            } | Select-Object -First 1
        )
        $eligibleIndexCount += $bestCandidates.Count
        foreach ($candidate in $bestCandidates) {
            $labels = @($candidate.StatusLabels)
            if ($labels -contains 'INVALID') { continue }
            $key = '{0}|{1}|{2}|{3}|{4}' -f $candidate.InfCrc, $candidate.Version, $candidate.Date, $candidate.HardwareId, $candidate.DriverSection
            $packPath = Resolve-SdioAuditPackPath -RawPackName ([string]$candidate.PackName) -DriverPackRoot $SdioPaths.Drivers
            $resolvedInfPath = [string]$candidate.InfFile
            $payloadResolution = 'ExactPackSuffix'
            if ($null -eq $packPath) {
                $archiveResolution = if ($null -ne $BenchmarkRecorder) {
                    Measure-DriverBenchmarkPhase -Recorder $BenchmarkRecorder -Name 'ArchiveVerification' -Operation {
                        Resolve-SdioCandidateFromCurrentArchive -Candidate $candidate -DriverPackRoot $SdioPaths.Drivers -PathCache $archivePathCache -TextCache $archiveTextCache
                    }
                }
                else {
                    Resolve-SdioCandidateFromCurrentArchive -Candidate $candidate -DriverPackRoot $SdioPaths.Drivers -PathCache $archivePathCache -TextCache $archiveTextCache
                }
                if ($null -ne $archiveResolution) {
                    $packPath = [string]$archiveResolution.PackPath
                    $resolvedInfPath = [string]$archiveResolution.InfPath
                    $payloadResolution = [string]$archiveResolution.Method
                }
            }
            if ($null -eq $packPath) {
                $indexOnly.Add([pscustomobject]@{
                        CandidateKey = $key
                        PackNameRaw = [string]$candidate.PackName
                        InfFile = [string]$candidate.InfFile
                        DriverVer = "$($candidate.Date) / $($candidate.Version)"
                        MatchedId = [string]$candidate.HardwareId
                        Reason = 'Referenced by the SDIO index, but no matching .7z payload exists in the active driver-pack root.'
                    })
                continue
            }
            if (-not $seen.Add($key)) { continue }
            $normalized.Add([pscustomobject]@{
                    Source          = 'SDIOLocal'
                    MatchKind       = [string]$candidate.MatchKind
                    MatchedId       = [string]$candidate.HardwareId
                    DriverVer       = "$($candidate.Date) / $($candidate.Version)"
                    Date            = [string]$candidate.Date
                    Version         = [string]$candidate.Version
                    Provider        = [string]$candidate.Manufacturer
                    InfFile         = $resolvedInfPath
                    DriverSection   = [string]$candidate.DriverSection
                    PackName        = if ($null -ne $packPath) { Split-Path -Leaf $packPath } else { [string]$candidate.PackName }
                    PackNameRaw     = [string]$candidate.PackName
                    PackPath        = [string]$packPath
                    PayloadResolution = $payloadResolution
                    SdioScore       = [string]$candidate.Score
                    SdioStatus      = @($labels) -join '+'
                    ActiveRelation  = Get-DriverComparisonVersionRelation -CandidateDate ([string]$candidate.Date) -CandidateVersion ([string]$candidate.Version) -ActiveDate ([string]$active.Date) -ActiveVersion ([string]$active.Version)
                    WindowsRank     = $null
                    WindowsRankNote = 'Not observed; SDIO score is not Windows rank evidence.'
                })
        }
    }

    $oemLinks = [System.Collections.Generic.List[object]]::new()
    foreach ($match in @($(if ($null -ne $OemTraceEvidence) { $OemTraceEvidence.TargetPreviewMatches }))) {
        $driverVer = [string]$match.DriverVer
        $date = ''
        $version = $driverVer
        if ($driverVer -match '^\s*(?<Date>[^,]+),\s*(?<Version>.+?)\s*$') {
            $date = $Matches.Date
            $version = $Matches.Version
        }
        $relation = Get-DriverComparisonVersionRelation -CandidateDate $date -CandidateVersion $version -ActiveDate ([string]$active.Date) -ActiveVersion ([string]$active.Version)
        $sameId = [string]$match.MatchedId -ieq [string]$active.MatchingDeviceId
        $oemLinks.Add([pscustomobject]@{
                Inf            = [string]$match.Inf
                InfPath        = [string]$match.InfPath
                MatchKind      = [string]$match.MatchKind
                MatchedId      = [string]$match.MatchedId
                DriverVer      = $driverVer
                ActiveRelation = if ($relation -eq 'SameAsActive' -and $sameId) { 'SameAsActive' } else { $relation }
                SameMatchedId  = $sameId
            })
    }

    $sameOem = @($oemLinks | Where-Object ActiveRelation -eq 'SameAsActive').Count -gt 0
    $newerSdio = @($normalized | Where-Object ActiveRelation -eq 'NewerThanActive').Count
    $uniqueIndexOnly = @(
        $indexOnly |
            Where-Object { -not $seen.Contains([string]$_.CandidateKey) } |
            Group-Object CandidateKey |
            ForEach-Object { $_.Group | Select-Object -First 1 }
    )
    $selectionAssessment = if ($sameOem) {
        [pscustomobject]@{
            Status         = 'NotRequiredSameAsActive'
            Display        = 'Not required — extracted OEM candidate is the active driver'
            RequiresTest   = $false
            Reason         = 'Same matched ID, DriverVer date, and version as the active driver.'
        }
    }
    else {
        [pscustomobject]@{
            Status         = 'NotRun'
            Display        = 'Not run — candidate differs from active driver'
            RequiresTest   = $true
            Reason         = 'A package match alone does not prove Windows selection.'
        }
    }

    $comparison = [pscustomobject]@{
        Outcome             = if ($normalized.Count -gt 0) {
            'NewerOrBetterCandidateFound'
        }
        elseif ($eligibleIndexCount -gt 0) {
            'NewerOrBetterCandidatePayloadUnavailable'
        }
        else {
            'NoNewerOrBetterCandidate'
        }
        SdioRoot            = $SdioPaths.Root
        DriverPackRoot      = $SdioPaths.Drivers
        IndexRoot           = $SdioPaths.Indexes
        ApplicableCount     = $normalized.Count
        EligibleIndexCount  = $eligibleIndexCount
        IndexOnlyCount      = $uniqueIndexOnly.Count
        NewerThanActiveCount = $newerSdio
        FilterPolicy        = [pscustomobject]@{
            Newer           = $true
            BetterMatch     = $true
            ShowOnlyBest    = $true
            Current         = $false
            Older           = $false
            WorseMatch      = $false
            Duplicates      = $false
            Invalid         = $false
        }
        Candidates          = @($normalized)
        IndexOnlyCandidates = @($uniqueIndexOnly)
        OemCandidates       = @($oemLinks)
        SelectionAssessment = $selectionAssessment
    }
    $Audit | Add-Member -NotePropertyName LocalComparison -NotePropertyValue $comparison -Force
    $Audit | Add-Member -NotePropertyName Outcome -NotePropertyValue $comparison.Outcome -Force
    return $Audit
}

function Get-AutomaticSdioEvidence {
    param(
        [Parameter(Mandatory)]$LocalEvidence,
        $OemTraceEvidence,
        [string]$RepoRoot,
        [string]$OutputRoot,
        [AllowEmptyString()][string]$SdioRoot = ''
    )

    $sdioBenchmark = New-DriverBenchmarkRecorder -Name 'SdioLocalEvidence'
    $paths = Measure-DriverBenchmarkPhase -Recorder $sdioBenchmark -Name 'ResolveSdioRoot' -Operation {
        Resolve-DriverComparisonSdioRoot -RequestedRoot $SdioRoot
    }
    if ($null -eq $paths) {
        $missingResult = [pscustomobject]@{
            SchemaVersion = 1
            Source = 'SDIOLocal'
            Outcome = 'SdioInstallationNotFound'
            MatchedDeviceCount = 0
            TotalDeviceCount = 0
            ParserWarnings = @()
            Devices = @()
            LocalComparison = [pscustomobject]@{
                Outcome = 'SdioInstallationNotFound'
                SdioRoot = ''
                ApplicableCount = 0
                NewerThanActiveCount = 0
                Candidates = @()
                OemCandidates = @()
                SelectionAssessment = [pscustomobject]@{ Status='Unavailable'; Display='Not available — local SDIO installation was not found'; RequiresTest=$false; Reason='No SDIO root with executable, drivers, and indexes was detected.' }
            }
        }
        $missingResult | Add-Member -NotePropertyName Benchmark -NotePropertyValue (Complete-DriverBenchmark $sdioBenchmark) -Force
        return $missingResult
    }

    $auditScript = Join-Path $RepoRoot 'internal\Invoke-SdioDriverAudit.ps1'
    $auditRoot = Join-Path $OutputRoot 'sdio-audits'
    $reusableLog = Measure-DriverBenchmarkPhase -Recorder $sdioBenchmark -Name 'FindReusableMatcherLog' -Operation {
        Find-ReusableSdioMatcherLog -SdioPaths $paths -RepoRoot $RepoRoot -OutputRoot $OutputRoot
    }
    $arguments = @{
        SdioExe = $paths.Exe
        DriverPackRoot = $paths.Drivers
        IndexRoot = $paths.Indexes
        OutputRoot = $auditRoot
        TopCandidateCount = 20
        AsJson = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($reusableLog)) {
        $arguments.ExistingLog = $reusableLog
    }
    elseif (@(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($paths.Exe)) -ErrorAction SilentlyContinue).Count -gt 0) {
        $deferredResult = [pscustomobject]@{
            SchemaVersion = 1
            Source = 'SDIOLocal'
            Outcome = 'SdioAuditDeferredProcessRunning'
            MatchedDeviceCount = 0
            TotalDeviceCount = 0
            ParserWarnings = @('SDIO is already running and no current reusable matcher log was found.')
            Devices = @()
            LocalComparison = [pscustomobject]@{
                Outcome = 'SdioAuditDeferredProcessRunning'
                SdioRoot = $paths.Root
                ApplicableCount = 0
                NewerThanActiveCount = 0
                Candidates = @()
                OemCandidates = @()
                SelectionAssessment = [pscustomobject]@{ Status='Deferred'; Display='Deferred — close SDIO and retry the audit'; RequiresTest=$false; Reason='A second SDIO process can block on the active SDIO instance.' }
            }
        }
        $deferredResult | Add-Member -NotePropertyName Benchmark -NotePropertyValue (Complete-DriverBenchmark $sdioBenchmark) -Force
        return $deferredResult
    }
    else {
        $arguments.RunSdio = $true
        $arguments.RunTimeoutSeconds = 45
    }
    $fullAudit = $null
    $cachePath = ''
    if (-not [string]::IsNullOrWhiteSpace($reusableLog)) {
        $cachePath = Get-SdioFullAuditCachePath -LogPath $reusableLog -OutputRoot $OutputRoot
        $fullAudit = Measure-DriverBenchmarkPhase -Recorder $sdioBenchmark -Name 'FullAuditCacheLookup' -Operation {
            Import-ReusableSdioFullAudit -CachePath $cachePath -LogPath $reusableLog
        }
    }
    if ($null -eq $fullAudit) {
        $json = Measure-DriverBenchmarkPhase -Recorder $sdioBenchmark -Name 'FullAuditCacheBuild' -Operation {
            & $auditScript @arguments | Out-String
        }
        $fullAudit = Measure-DriverBenchmarkPhase -Recorder $sdioBenchmark -Name 'FullAuditJsonParse' -Operation {
            $json | ConvertFrom-Json
        }
        $resolvedLog = [string]$fullAudit.Paths.Log
        $cachePath = Get-SdioFullAuditCachePath -LogPath $resolvedLog -OutputRoot $OutputRoot
        Measure-DriverBenchmarkPhase -Recorder $sdioBenchmark -Name 'FullAuditCacheWrite' -Operation {
            Export-SdioFullAuditCache -Audit $fullAudit -LogPath $resolvedLog -CachePath $cachePath
        }
    }
    $audit = Measure-DriverBenchmarkPhase -Recorder $sdioBenchmark -Name 'TargetLookup' -Operation {
        Select-SdioAuditTargetDevice -FullAudit $fullAudit -LocalEvidence $LocalEvidence
    }
    $result = Measure-DriverBenchmarkPhase -Recorder $sdioBenchmark -Name 'FilterAndNormalizeCandidates' -Operation {
        Add-SdioLocalComparisonEvidence -Audit $audit -LocalEvidence $LocalEvidence -OemTraceEvidence $OemTraceEvidence -SdioPaths $paths -BenchmarkRecorder $sdioBenchmark
    }
    $result | Add-Member -NotePropertyName Benchmark -NotePropertyValue (Complete-DriverBenchmark $sdioBenchmark) -Force
    return $result
}
