Set-StrictMode -Version Latest

function Import-DriverAdvisorCase {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Driver Advisor case not found: $Path"
    }

    $case = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$case.SchemaVersion -ne 1) {
        throw "Unsupported Driver Advisor case schema '$($case.SchemaVersion)' in '$Path'."
    }
    if ($null -eq $case.PSObject.Properties['Report'] -or $null -eq $case.PSObject.Properties['Expected']) {
        throw "Driver Advisor case '$Path' must contain Report and Expected objects."
    }

    return $case
}

function Test-DriverAdvisorCase {
    param(
        [Parameter(Mandatory)]$Case,
        [switch]$PassThru
    )

    $recommendation = Get-DriverAdvisorRecommendation -Report $Case.Report
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($field in @('Code', 'RecommendedAction', 'Confidence', 'Risk')) {
        $expectedProperty = $Case.Expected.PSObject.Properties[$field]
        if ($null -eq $expectedProperty) { continue }
        if ([string]$recommendation.$field -ne [string]$expectedProperty.Value) {
            $failures.Add("$field expected '$($expectedProperty.Value)', actual '$($recommendation.$field)'.")
        }
    }

    $result = [pscustomobject]@{
        Name           = [string]$Case.Name
        Passed         = $failures.Count -eq 0
        Failures       = @($failures)
        Recommendation = $recommendation
    }

    if (-not $result.Passed -and -not $PassThru) {
        throw "Driver Advisor case '$($Case.Name)' failed: $($failures -join ' ')"
    }
    return $result
}

function Invoke-DriverAdvisorCaseSuite {
    param(
        [Parameter(Mandatory)][string]$CaseRoot,
        [switch]$PassThru
    )

    $results = @(
        Get-ChildItem -LiteralPath $CaseRoot -Filter '*.case.json' -File | Sort-Object Name | ForEach-Object {
            $case = Import-DriverAdvisorCase -Path $_.FullName
            Test-DriverAdvisorCase -Case $case -PassThru
        }
    )

    $failed = @($results | Where-Object { -not $_.Passed })
    if ($failed.Count -gt 0 -and -not $PassThru) {
        throw "$($failed.Count) Driver Advisor regression case(s) failed."
    }
    return $results
}
