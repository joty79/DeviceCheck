Set-StrictMode -Version Latest

function Import-DriverSelectionExperimentEvidence {
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath,

        [Parameter(Mandatory)]
        [string]$ExpectedInstanceId
    )

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Driver selection experiment manifest not found: $ManifestPath"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $ManifestPath).ProviderPath
    $evidence = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json
    if ($evidence.SchemaVersion -ne 1) {
        throw "Unsupported driver selection experiment schema '$($evidence.SchemaVersion)' in '$resolvedPath'."
    }
    if ([string]$evidence.Target.InstanceId -ne $ExpectedInstanceId) {
        throw "Selection evidence targets '$($evidence.Target.InstanceId)', not '$ExpectedInstanceId'."
    }
    $supportedModes = @('StageOnlyNoInstall', 'ControlledActivation')
    if ([string]$evidence.Mode -notin $supportedModes) {
        throw "Selection evidence mode '$($evidence.Mode)' is unsupported. Expected: $($supportedModes -join ', ')."
    }
    if ([bool]$evidence.CommandGuards.RebootSwitchUsed) {
        throw "Selection evidence '$resolvedPath' reports a /reboot switch; automatic reboot evidence is not supported."
    }
    if ([string]$evidence.Mode -eq 'StageOnlyNoInstall' -and [bool]$evidence.CommandGuards.InstallSwitchUsed) {
        throw "Stage-only selection evidence '$resolvedPath' reports a forbidden /install switch."
    }
    if ([string]$evidence.Mode -eq 'ControlledActivation' -and -not [bool]$evidence.CommandGuards.InstallSwitchUsed) {
        throw "Controlled activation evidence '$resolvedPath' does not report the required /install switch."
    }

    $evidence | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $resolvedPath -Force
    return $evidence
}
