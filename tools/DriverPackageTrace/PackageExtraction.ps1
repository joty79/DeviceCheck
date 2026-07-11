Set-StrictMode -Version Latest

function ConvertTo-DriverPackageExtractionSafeName {
    param([Parameter(Mandatory)][string]$Text)

    $invalidCharacters = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = [System.Text.StringBuilder]::new()
    foreach ($character in $Text.ToCharArray()) {
        if ($invalidCharacters -contains $character) {
            [void]$builder.Append('_')
        } else {
            [void]$builder.Append($character)
        }
    }

    $value = $builder.ToString().Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($value)) { return 'package' }
    return $value
}

function Resolve-DriverPackageExtractionTool {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('7Zip', 'DIE', 'InnoExtract', 'LessMsi', 'Strings')]
        [string]$Name
    )

    $candidates = switch ($Name) {
        '7Zip' {
            @(
                (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
                (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
            )
        }
        'DIE' { @('diec.exe', 'diec') }
        'InnoExtract' { @('innoextract.exe', 'innoextract') }
        'LessMsi' { @('lessmsi.exe', 'lessmsi') }
        'Strings' { @('strings.exe', 'strings') }
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ([System.IO.Path]::IsPathRooted($candidate)) {
            if (Test-Path -LiteralPath $candidate) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
            continue
        }

        $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
            return [string]$command.Source
        }
    }

    return ''
}

function Get-DriverPackageExtractionToolInfo {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Path
    )

    $version = ''
    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) {
        $item = Get-Item -LiteralPath $Path
        $version = [string]$item.VersionInfo.ProductVersion
        if ([string]::IsNullOrWhiteSpace($version)) {
            $version = [string]$item.VersionInfo.FileVersion
        }
    }

    return [pscustomobject]@{
        Name = $Name
        Path = $Path
        Version = $version
        Available = -not [string]::IsNullOrWhiteSpace($Path)
    }
}

function Invoke-DriverPackageExtractionCommand {
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$LogPath
    )

    $parent = Split-Path -Parent $LogPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $startedAt = Get-Date
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $outputLines = @()
    $exitCode = $null
    $errorText = ''
    try {
        $outputLines = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    } catch {
        $errorText = $_.Exception.Message
        $outputLines = @($errorText)
    } finally {
        $stopwatch.Stop()
    }

    [System.IO.File]::WriteAllText($LogPath, ($outputLines -join [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        Tool = $ToolName
        FilePath = $FilePath
        Arguments = @($ArgumentList)
        StartedAt = $startedAt.ToString('o')
        DurationMilliseconds = $stopwatch.ElapsedMilliseconds
        ExitCode = $exitCode
        Error = $errorText
        LogPath = $LogPath
        OutputLines = @($outputLines)
    }
}

function Get-DriverPackageInstallerIdentification {
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][string]$LogBaseName
    )

    $extension = [System.IO.Path]::GetExtension($PackagePath).ToLowerInvariant()
    $engine = switch ($extension) {
        '.msi' { 'MSI' }
        '.msm' { 'MSI merge module' }
        '.cab' { 'Cabinet' }
        '.zip' { 'Archive' }
        '.7z' { 'Archive' }
        default { 'Unknown' }
    }
    $engineVersion = ''
    $detectorExitCode = $null
    $detectorError = ''
    $values = @()
    $diePath = Resolve-DriverPackageExtractionTool -Name DIE
    $dieLog = Join-Path $LogDirectory "$LogBaseName-diec.log"

    if (-not [string]::IsNullOrWhiteSpace($diePath)) {
        $result = Invoke-DriverPackageExtractionCommand -ToolName 'Detect It Easy' -FilePath $diePath -ArgumentList @('-j', $PackagePath) -LogPath $dieLog
        $detectorExitCode = $result.ExitCode
        $detectorError = $result.Error
        if ($result.ExitCode -eq 0 -and $result.OutputLines.Count -gt 0) {
            try {
                $json = ($result.OutputLines -join [Environment]::NewLine) | ConvertFrom-Json
                $values = @($json.detects | ForEach-Object { @($_.values) })
                $installerValue = @($values | Where-Object { [string]$_.type -eq 'installer' } | Select-Object -First 1)
                if ($installerValue.Count -gt 0) {
                    $name = [string]$installerValue[0].name
                    $engineVersion = [string]$installerValue[0].version
                    $engine = switch -Regex ($name) {
                        'Inno Setup' { 'Inno Setup'; break }
                        'Nullsoft|NSIS' { 'NSIS'; break }
                        'InstallShield' { 'InstallShield'; break }
                        '7-Zip' { '7-Zip SFX'; break }
                        'WiX|Windows Installer|Microsoft Installer|MSI' { 'MSI'; break }
                        default { $name }
                    }
                }
            } catch {
                $detectorError = "DIE JSON parse failed: $($_.Exception.Message)"
            }
        }
    } else {
        $detectorError = 'Detect It Easy was not found.'
    }

    return [pscustomobject]@{
        PackagePath = $PackagePath
        Extension = $extension
        Engine = $engine
        EngineVersion = $engineVersion
        Detector = 'Detect It Easy'
        DetectorPath = $diePath
        DetectorExitCode = $detectorExitCode
        DetectorLogPath = $dieLog
        DetectorError = $detectorError
        Values = @($values | ForEach-Object {
            [pscustomobject]@{
                Type = [string]$_.type
                Name = [string]$_.name
                Version = [string]$_.version
                Info = [string]$_.info
                Text = [string]$_.string
            }
        })
    }
}

function Get-DriverPackageExtractionInventory {
    param([AllowEmptyString()][string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        return [pscustomobject]@{
            FileCount = 0
            TotalBytes = 0
            InfCount = 0
            MsiCount = 0
            SysCount = 0
            CatCount = 0
            ExeCount = 0
        }
    }

    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)
    $totalBytes = 0L
    if ($files.Count -gt 0) {
        $measurement = $files | Measure-Object -Property Length -Sum
        if ($null -ne $measurement.PSObject.Properties['Sum'] -and $null -ne $measurement.Sum) {
            $totalBytes = [long]$measurement.Sum
        }
    }
    return [pscustomobject]@{
        FileCount = $files.Count
        TotalBytes = $totalBytes
        InfCount = @($files | Where-Object { $_.Extension -eq '.inf' }).Count
        MsiCount = @($files | Where-Object { $_.Extension -eq '.msi' }).Count
        SysCount = @($files | Where-Object { $_.Extension -eq '.sys' }).Count
        CatCount = @($files | Where-Object { $_.Extension -eq '.cat' }).Count
        ExeCount = @($files | Where-Object { $_.Extension -eq '.exe' }).Count
    }
}

function Get-DriverPackageNestedCandidateFiles {
    param([Parameter(Mandatory)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) { return @() }

    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -in @('.exe', '.msi', '.msm', '.cab') -and
        $_.Name -notmatch '^(?i:unins\d*|uninstall|vc_redist|vcredist|dxsetup|dotnetfx|setupapi)'
    })

    return @($files | Sort-Object -Property @(
        @{ Expression = { if ($_.Name -match '(?i)(driver|chipset|setup|install)') { 0 } else { 1 } } },
        @{ Expression = { if ($_.Extension -in @('.msi', '.msm')) { 0 } else { 1 } } },
        @{ Expression = 'Length'; Descending = $true }
    ) | Select-Object -First 40)
}

function Invoke-DriverPackageStaticExtractionAttempt {
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][object]$Identification,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][string]$AttemptName,
        [Parameter(Mandatory)][hashtable]$ToolPaths,
        [Parameter(Mandatory)][int]$Depth
    )

    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $engine = [string]$Identification.Engine
    $toolName = ''
    $toolPath = ''
    $argumentList = @()

    if ($engine -eq 'Inno Setup') {
        $toolName = 'innoextract'
        $toolPath = [string]$ToolPaths.InnoExtract
        $argumentList = @('-d', $OutputDirectory, $PackagePath)
    } elseif ($engine -in @('MSI', 'MSI merge module')) {
        $toolName = 'lessmsi'
        $toolPath = [string]$ToolPaths.LessMsi
        # lessmsi distinguishes the optional destination from file filters by
        # the documented trailing directory separator.
        $lessMsiOutputDirectory = $OutputDirectory.TrimEnd('\') + '\'
        $argumentList = @('x', $PackagePath, $lessMsiOutputDirectory)
    } else {
        $toolName = '7-Zip'
        $toolPath = [string]$ToolPaths.SevenZip
        $argumentList = @('x', '-y', '-bd', "-o$OutputDirectory", $PackagePath)
    }

    if ([string]::IsNullOrWhiteSpace($toolPath)) {
        return [pscustomobject]@{
            Kind = 'Static'
            PackagePath = $PackagePath
            Engine = $engine
            Depth = $Depth
            Tool = $toolName
            ToolPath = ''
            Arguments = @($argumentList)
            ExitCode = $null
            Status = 'Tool unavailable'
            OutputDirectory = $OutputDirectory
            LogPath = ''
            FileCount = 0
            InfCount = 0
            Error = "$toolName was not found."
        }
    }

    $logPath = Join-Path $LogDirectory "$AttemptName-$toolName.log"
    $commandResult = Invoke-DriverPackageExtractionCommand -ToolName $toolName -FilePath $toolPath -ArgumentList $argumentList -LogPath $logPath
    $inventory = Get-DriverPackageExtractionInventory -Root $OutputDirectory
    $status = if ($commandResult.ExitCode -eq 0 -and $inventory.FileCount -gt 0) {
        'Success'
    } elseif ($commandResult.ExitCode -eq 1 -and $inventory.FileCount -gt 0 -and $toolName -eq '7-Zip') {
        'Partial with warnings'
    } elseif ($inventory.FileCount -gt 0) {
        'Partial'
    } else {
        'Failed'
    }

    return [pscustomobject]@{
        Kind = 'Static'
        PackagePath = $PackagePath
        Engine = $engine
        Depth = $Depth
        Tool = $toolName
        ToolPath = $toolPath
        Arguments = @($argumentList)
        ExitCode = $commandResult.ExitCode
        Status = $status
        OutputDirectory = $OutputDirectory
        LogPath = $logPath
        FileCount = $inventory.FileCount
        InfCount = $inventory.InfCount
        Error = $commandResult.Error
    }
}

function Test-DriverPackageInstallShieldAdministrativeSupport {
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][hashtable]$ToolPaths,
        [Parameter(Mandatory)][string]$AttemptName
    )

    $stringsPath = [string]$ToolPaths.Strings
    if ([string]::IsNullOrWhiteSpace($stringsPath)) {
        return [pscustomobject]@{
            Supported = $false
            Reason = 'Sysinternals Strings was not found, so administrative-extraction support was not proven.'
            LogPath = ''
        }
    }

    $logPath = Join-Path $LogDirectory "$AttemptName-strings.log"
    $result = Invoke-DriverPackageExtractionCommand -ToolName 'Sysinternals Strings' -FilePath $stringsPath -ArgumentList @('-nobanner', '-n', '4', $PackagePath) -LogPath $logPath
    $text = $result.OutputLines -join "`n"
    $hasAdministrativeText = $text -match '(?i)(perform an administrative installation|administrative install)'
    $hasMsiPayloadText = $text -match '(?i)\.msi\b'
    $supported = $result.ExitCode -eq 0 -and $hasAdministrativeText -and $hasMsiPayloadText
    $reason = if ($supported) {
        'Static Strings evidence contains both administrative-installation text and an embedded MSI name.'
    } elseif ($result.ExitCode -ne 0) {
        "Strings failed with exit code $($result.ExitCode)."
    } else {
        'Required administrative-installation and embedded-MSI evidence was not found.'
    }

    return [pscustomobject]@{
        Supported = $supported
        Reason = $reason
        LogPath = $logPath
    }
}

function Invoke-DriverPackageInstallShieldAdministrativeExtraction {
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][string]$AttemptName,
        [Parameter(Mandatory)][hashtable]$ToolPaths,
        [int]$TimeoutSeconds = 600
    )

    $support = Test-DriverPackageInstallShieldAdministrativeSupport -PackagePath $PackagePath -LogDirectory $LogDirectory -ToolPaths $ToolPaths -AttemptName $AttemptName
    if (-not $support.Supported) {
        return [pscustomobject]@{
            Kind = 'Extended administrative'
            PackagePath = $PackagePath
            Engine = 'InstallShield'
            Tool = 'InstallShield /a'
            Arguments = @()
            ExitCode = $null
            Status = 'Skipped; support not proven'
            OutputDirectory = $OutputDirectory
            LogPath = $support.LogPath
            FileCount = 0
            InfCount = 0
            Error = $support.Reason
        }
    }

    $packageHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash
    $stagingRoot = Join-Path $env:TEMP 'DeviceCheckDriverExtract'
    $stagingDirectory = Join-Path $stagingRoot ("{0}-{1}" -f $packageHash.Substring(0, 12), $PID)
    if (Test-Path -LiteralPath $stagingDirectory) {
        $resolvedStagingRoot = [System.IO.Path]::GetFullPath($stagingRoot).TrimEnd('\') + '\'
        $resolvedStagingTarget = [System.IO.Path]::GetFullPath($stagingDirectory).TrimEnd('\') + '\'
        if (-not $resolvedStagingTarget.StartsWith($resolvedStagingRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clear administrative staging outside the expected temp root: $stagingDirectory"
        }
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $stagingDirectory | Out-Null
    $msiLogPath = Join-Path $LogDirectory "$AttemptName-administrative-msi.log"
    $msiOptions = "/qn TARGETDIR=`"$stagingDirectory`" /L*v `"$msiLogPath`""
    $argumentList = @('/a', '/s', "/v`"$msiOptions`"")
    $startedAt = Get-Date
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = $null
    $errorText = ''
    $timedOut = $false
    $process = $null
    try {
        # Start-Process preserves the InstallShield /v"<MSI arguments>" command-line
        # form that was verified against the AMD Basic MSI wrapper. ProcessStartInfo
        # ArgumentList re-quoted the embedded /v payload and left a hidden UI waiting.
        $process = Start-Process -FilePath $PackagePath -ArgumentList $argumentList -PassThru -WindowStyle Hidden
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try {
                $process.Kill($true)
            } catch {
                $errorText = "Administrative extraction timed out and process-tree termination failed: $($_.Exception.Message)"
            }
        } else {
            $exitCode = $process.ExitCode
        }
    } catch {
        $errorText = $_.Exception.Message
    } finally {
        $stopwatch.Stop()
        if ($null -ne $process) { $process.Dispose() }
    }

    $stagingInventory = Get-DriverPackageExtractionInventory -Root $stagingDirectory
    if ($stagingInventory.FileCount -gt 0) {
        New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
        foreach ($stagedItem in @(Get-ChildItem -LiteralPath $stagingDirectory -Force -ErrorAction SilentlyContinue)) {
            Move-Item -LiteralPath $stagedItem.FullName -Destination $OutputDirectory -Force
        }
    }
    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
    $inventory = Get-DriverPackageExtractionInventory -Root $OutputDirectory
    $status = if ($timedOut) {
        'Timed out'
    } elseif ($exitCode -eq 0 -and $inventory.FileCount -gt 0) {
        'Success'
    } elseif ($inventory.FileCount -gt 0) {
        'Partial'
    } else {
        'Failed'
    }

    return [pscustomobject]@{
        Kind = 'Extended administrative'
        PackagePath = $PackagePath
        Engine = 'InstallShield'
        Tool = 'InstallShield /a'
        Arguments = @($argumentList)
        StartedAt = $startedAt.ToString('o')
        DurationMilliseconds = $stopwatch.ElapsedMilliseconds
        ExitCode = $exitCode
        Status = $status
        TimedOut = $timedOut
        AdministrativeStagingRoot = $stagingRoot
        OutputDirectory = $OutputDirectory
        LogPath = $msiLogPath
        SupportEvidenceLogPath = $support.LogPath
        FileCount = $inventory.FileCount
        InfCount = $inventory.InfCount
        Error = $errorText
    }
}

function Remove-DriverPackageExtractionCacheDirectory {
    param(
        [Parameter(Mandatory)][string]$CacheDirectory,
        [Parameter(Mandatory)][string]$CacheRoot
    )

    if (-not (Test-Path -LiteralPath $CacheDirectory)) { return }
    $resolvedRoot = [System.IO.Path]::GetFullPath($CacheRoot).TrimEnd('\') + '\'
    $resolvedTarget = [System.IO.Path]::GetFullPath($CacheDirectory).TrimEnd('\') + '\'
    if (-not $resolvedTarget.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove extraction cache outside the configured root: $CacheDirectory"
    }
    Remove-Item -LiteralPath $CacheDirectory -Recurse -Force
}

function Invoke-DriverPackagePayloadExtraction {
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][ValidateSet('None', 'Safe', 'Extended')][string]$Mode,
        [Parameter(Mandatory)][string]$CacheRoot,
        [AllowEmptyString()][string]$ExistingPayloadRoot,
        [switch]$ForceReextract,
        [ValidateRange(0, 4)][int]$MaxDepth = 2
    )

    $resolvedPackage = (Resolve-Path -LiteralPath $PackagePath).Path
    $packageItem = Get-Item -LiteralPath $resolvedPackage
    $sourceHash = (Get-FileHash -LiteralPath $resolvedPackage -Algorithm SHA256).Hash.ToUpperInvariant()
    $cacheDirectory = Join-Path $CacheRoot $sourceHash.Substring(0, 16)
    $payloadRoot = Join-Path $cacheDirectory 'payload'
    $logDirectory = Join-Path $cacheDirectory 'logs'
    $manifestPath = Join-Path $cacheDirectory 'extraction-manifest.json'
    $modeRank = @{ None = 0; Safe = 1; Extended = 2 }

    $toolPaths = @{
        SevenZip = Resolve-DriverPackageExtractionTool -Name 7Zip
        DIE = Resolve-DriverPackageExtractionTool -Name DIE
        InnoExtract = Resolve-DriverPackageExtractionTool -Name InnoExtract
        LessMsi = Resolve-DriverPackageExtractionTool -Name LessMsi
        Strings = Resolve-DriverPackageExtractionTool -Name Strings
    }
    $tools = @(
        Get-DriverPackageExtractionToolInfo -Name '7-Zip' -Path $toolPaths.SevenZip
        Get-DriverPackageExtractionToolInfo -Name 'Detect It Easy' -Path $toolPaths.DIE
        Get-DriverPackageExtractionToolInfo -Name 'innoextract' -Path $toolPaths.InnoExtract
        Get-DriverPackageExtractionToolInfo -Name 'lessmsi' -Path $toolPaths.LessMsi
        Get-DriverPackageExtractionToolInfo -Name 'Sysinternals Strings' -Path $toolPaths.Strings
    )

    if (-not $ForceReextract -and -not [string]::IsNullOrWhiteSpace($ExistingPayloadRoot) -and (Test-Path -LiteralPath $ExistingPayloadRoot)) {
        $resolvedExistingRoot = (Resolve-Path -LiteralPath $ExistingPayloadRoot).Path
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
        $identification = Get-DriverPackageInstallerIdentification -PackagePath $resolvedPackage -LogDirectory $logDirectory -LogBaseName 'source'
        $inventory = Get-DriverPackageExtractionInventory -Root $resolvedExistingRoot
        $signature = Get-AuthenticodeSignature -LiteralPath $resolvedPackage
        $manifest = [pscustomobject]@{
            SchemaVersion = 1
            CreatedAt = (Get-Date).ToString('o')
            RequestedMode = $Mode
            CompletedMode = 'ExistingPayload'
            Source = [pscustomobject]@{
                Path = $resolvedPackage
                Length = $packageItem.Length
                LastWriteTimeUtc = $packageItem.LastWriteTimeUtc.ToString('o')
                Sha256 = $sourceHash
                SignatureStatus = [string]$signature.Status
                SignerSubject = if ($null -ne $signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
                SignerThumbprint = if ($null -ne $signature.SignerCertificate) { [string]$signature.SignerCertificate.Thumbprint } else { '' }
            }
            Identification = $identification
            Tools = $tools
            CacheRoot = $cacheDirectory
            PayloadRoot = $resolvedExistingRoot
            UsedExistingPayload = $true
            CacheReused = $false
            MaxDepth = $MaxDepth
            Attempts = @()
            ExtendedCandidates = @()
            Inventory = $inventory
            Warnings = @('An existing extracted payload was reused; extractor commands were not rerun.')
        }
        return [pscustomobject]@{ PayloadRoot = $resolvedExistingRoot; Manifest = $manifest; ManifestPath = ''; CacheReused = $false }
    }

    if (-not $ForceReextract -and (Test-Path -LiteralPath $manifestPath)) {
        try {
            $storedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $storedHash = [string]$storedManifest.Source.Sha256
            $storedMode = [string]$storedManifest.CompletedMode
            if ($storedHash -eq $sourceHash -and $modeRank.ContainsKey($storedMode) -and $modeRank[$storedMode] -ge $modeRank[$Mode] -and (Test-Path -LiteralPath ([string]$storedManifest.PayloadRoot))) {
                $storedManifest.CacheReused = $true
                return [pscustomobject]@{ PayloadRoot = [string]$storedManifest.PayloadRoot; Manifest = $storedManifest; ManifestPath = $manifestPath; CacheReused = $true }
            }
        } catch {
            Write-Verbose "Extraction cache manifest could not be reused and will be rebuilt: $($_.Exception.Message)"
        }
    }

    if (Test-Path -LiteralPath $cacheDirectory) {
        Remove-DriverPackageExtractionCacheDirectory -CacheDirectory $cacheDirectory -CacheRoot $CacheRoot
    }
    New-Item -ItemType Directory -Force -Path $payloadRoot, $logDirectory | Out-Null

    $signature = Get-AuthenticodeSignature -LiteralPath $resolvedPackage
    $sourceIdentification = Get-DriverPackageInstallerIdentification -PackagePath $resolvedPackage -LogDirectory $logDirectory -LogBaseName 'source'
    $attempts = [System.Collections.Generic.List[object]]::new()
    $extendedCandidates = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if ($Mode -ne 'None') {
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue([pscustomobject]@{
            Path = $resolvedPackage
            Depth = 0
            Identification = $sourceIdentification
            OutputDirectory = $payloadRoot
            AttemptName = 'depth0-source'
        })
        $seenHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        while ($queue.Count -gt 0) {
            $entry = $queue.Dequeue()
            $entryPath = [string]$entry.Path
            if (-not (Test-Path -LiteralPath $entryPath)) { continue }
            $entryHash = (Get-FileHash -LiteralPath $entryPath -Algorithm SHA256).Hash
            if (-not $seenHashes.Add($entryHash)) { continue }

            $attempt = Invoke-DriverPackageStaticExtractionAttempt -PackagePath $entryPath -Identification $entry.Identification -OutputDirectory $entry.OutputDirectory -LogDirectory $logDirectory -AttemptName $entry.AttemptName -ToolPaths $toolPaths -Depth ([int]$entry.Depth)
            $attempts.Add($attempt)

            if ($attempt.Status -in @('Tool unavailable', 'Failed') -and [string]$entry.Identification.Engine -in @('Inno Setup', 'MSI', 'MSI merge module')) {
                $fallbackIdentification = [pscustomobject]@{
                    Engine = 'Generic archive fallback'
                    EngineVersion = ''
                }
                $fallbackAttempt = Invoke-DriverPackageStaticExtractionAttempt -PackagePath $entryPath -Identification $fallbackIdentification -OutputDirectory $entry.OutputDirectory -LogDirectory $logDirectory -AttemptName "$($entry.AttemptName)-fallback" -ToolPaths $toolPaths -Depth ([int]$entry.Depth)
                $attempts.Add($fallbackAttempt)
            }

            if ([string]$entry.Identification.Engine -eq 'InstallShield') {
                $extendedCandidates.Add([pscustomobject]@{
                    PackagePath = $entryPath
                    Depth = [int]$entry.Depth
                    Engine = 'InstallShield'
                    EngineVersion = [string]$entry.Identification.EngineVersion
                })
            }

            if ([int]$entry.Depth -ge $MaxDepth -or -not (Test-Path -LiteralPath $entry.OutputDirectory)) { continue }
            $nestedFiles = @(Get-DriverPackageNestedCandidateFiles -Root $entry.OutputDirectory)
            $nestedIndex = 0
            foreach ($nestedFile in $nestedFiles) {
                $nestedIndex++
                $nestedSafeName = ConvertTo-DriverPackageExtractionSafeName -Text ([System.IO.Path]::GetFileNameWithoutExtension($nestedFile.Name))
                $nestedLogBase = "depth$([int]$entry.Depth + 1)-$nestedIndex-$nestedSafeName"
                $identification = Get-DriverPackageInstallerIdentification -PackagePath $nestedFile.FullName -LogDirectory $logDirectory -LogBaseName $nestedLogBase
                $recognized = $identification.Engine -in @('Inno Setup', 'NSIS', 'InstallShield', 'MSI', 'MSI merge module', '7-Zip SFX', 'Cabinet', 'Archive')
                if (-not $recognized) { continue }
                $nestedHash = (Get-FileHash -LiteralPath $nestedFile.FullName -Algorithm SHA256).Hash
                if ($seenHashes.Contains($nestedHash)) { continue }
                $nestedOutput = Join-Path $payloadRoot ("_nested\{0}" -f $nestedHash.Substring(0, 10))
                $queue.Enqueue([pscustomobject]@{
                    Path = $nestedFile.FullName
                    Depth = [int]$entry.Depth + 1
                    Identification = $identification
                    OutputDirectory = $nestedOutput
                    AttemptName = $nestedLogBase
                })
            }
        }
    }

    if ($Mode -eq 'Extended') {
        if ($extendedCandidates.Count -eq 0) {
            $warnings.Add('Extended mode was requested, but no InstallShield candidate was identified.')
        }
        $extendedIndex = 0
        foreach ($candidate in $extendedCandidates) {
            $extendedIndex++
            $candidatePath = [string]$candidate.PackagePath
            $candidateHash = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash
            $candidateName = ConvertTo-DriverPackageExtractionSafeName -Text ([System.IO.Path]::GetFileNameWithoutExtension($candidatePath))
            $extendedOutput = Join-Path $payloadRoot ("_extended\{0}" -f $candidateHash.Substring(0, 10))
            $extendedAttempt = Invoke-DriverPackageInstallShieldAdministrativeExtraction -PackagePath $candidatePath -OutputDirectory $extendedOutput -LogDirectory $logDirectory -AttemptName "extended-$extendedIndex-$candidateName" -ToolPaths $toolPaths
            $attempts.Add($extendedAttempt)
            if ($extendedAttempt.Status -notin @('Success', 'Partial')) {
                $warnings.Add("Extended extraction did not complete for $candidatePath`: $($extendedAttempt.Status). $($extendedAttempt.Error)")
            }
        }
    }

    $inventory = Get-DriverPackageExtractionInventory -Root $payloadRoot
    if ($inventory.FileCount -eq 0 -and $Mode -ne 'None') {
        $warnings.Add('No payload files were extracted.')
    } elseif ($inventory.InfCount -eq 0 -and $extendedCandidates.Count -gt 0 -and $Mode -eq 'Safe') {
        $warnings.Add('Safe extraction found an InstallShield candidate but no INF files; Extended mode may reveal an administrative image.')
    }
    if ([string]::IsNullOrWhiteSpace([string]$toolPaths.DIE)) {
        $warnings.Add('Detect It Easy is unavailable; installer routing used only extension-based fallback evidence.')
    }

    $effectivePayloadRoot = if ($Mode -eq 'None' -and $inventory.FileCount -eq 0) { '' } else { $payloadRoot }

    $manifest = [pscustomobject]@{
        SchemaVersion = 1
        CreatedAt = (Get-Date).ToString('o')
        RequestedMode = $Mode
        CompletedMode = $Mode
        Source = [pscustomobject]@{
            Path = $resolvedPackage
            Length = $packageItem.Length
            LastWriteTimeUtc = $packageItem.LastWriteTimeUtc.ToString('o')
            Sha256 = $sourceHash
            SignatureStatus = [string]$signature.Status
            SignerSubject = if ($null -ne $signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
            SignerThumbprint = if ($null -ne $signature.SignerCertificate) { [string]$signature.SignerCertificate.Thumbprint } else { '' }
        }
        Identification = $sourceIdentification
        Tools = $tools
        CacheRoot = $cacheDirectory
        PayloadRoot = $effectivePayloadRoot
        UsedExistingPayload = $false
        CacheReused = $false
        MaxDepth = $MaxDepth
        Attempts = $attempts.ToArray()
        ExtendedCandidates = $extendedCandidates.ToArray()
        Inventory = $inventory
        Warnings = $warnings.ToArray()
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    return [pscustomobject]@{ PayloadRoot = $effectivePayloadRoot; Manifest = $manifest; ManifestPath = $manifestPath; CacheReused = $false }
}
