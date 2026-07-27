[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '', Justification = 'Repository policy uses UTF-8 without BOM for PowerShell source.')]
param()

Set-StrictMode -Version Latest

function New-DriverBenchmarkRecorder {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory timing recorder only.')]
    param([string]$Name)

    [pscustomobject]@{
        Name           = $Name
        StartedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        TotalStopwatch = [Diagnostics.Stopwatch]::StartNew()
        Phases         = [System.Collections.Generic.List[object]]::new()
    }
}

function Add-DriverBenchmarkPhase {
    param(
        [Parameter(Mandatory)]$Recorder,
        [string]$Name,
        [long]$ElapsedMilliseconds,
        [string]$Status = 'Completed',
        [AllowEmptyString()][string]$Detail = ''
    )

    $Recorder.Phases.Add([pscustomobject]@{
            Name       = $Name
            DurationMs = $ElapsedMilliseconds
            Duration   = [math]::Round($ElapsedMilliseconds / 1000, 3)
            Status     = $Status
            Detail     = $Detail
        })
}

function Measure-DriverBenchmarkPhase {
    param(
        [Parameter(Mandatory)]$Recorder,
        [string]$Name,
        [scriptblock]$Operation,
        [AllowEmptyString()][string]$Detail = ''
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $status = 'Completed'
    try {
        & $Operation
    }
    catch {
        $status = 'Failed'
        throw
    }
    finally {
        $stopwatch.Stop()
        Add-DriverBenchmarkPhase -Recorder $Recorder -Name $Name -ElapsedMilliseconds $stopwatch.ElapsedMilliseconds -Status $status -Detail $Detail
    }
}

function Get-DriverBenchmarkSnapshot {
    param([Parameter(Mandatory)]$Recorder)

    $phases = @($Recorder.Phases)
    $slowest = @($phases | Sort-Object DurationMs -Descending | Select-Object -First 1)
    [pscustomobject]@{
        SchemaVersion = 1
        Name          = [string]$Recorder.Name
        StartedAtUtc  = [string]$Recorder.StartedAtUtc
        CompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        TotalMs       = [long]$Recorder.TotalStopwatch.ElapsedMilliseconds
        TotalSeconds  = [math]::Round($Recorder.TotalStopwatch.Elapsed.TotalSeconds, 3)
        SlowestPhase  = if ($slowest.Count) { [string]$slowest[0].Name } else { '' }
        SlowestMs     = if ($slowest.Count) { [long]$slowest[0].DurationMs } else { 0 }
        Phases        = $phases
    }
}

function Complete-DriverBenchmark {
    param([Parameter(Mandatory)]$Recorder)

    if ($Recorder.TotalStopwatch.IsRunning) { $Recorder.TotalStopwatch.Stop() }
    return Get-DriverBenchmarkSnapshot -Recorder $Recorder
}

function Export-DriverBenchmark {
    param(
        [Parameter(Mandatory)]$Recorder,
        [string]$Path
    )

    $result = Complete-DriverBenchmark -Recorder $Recorder
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
    return $result
}
