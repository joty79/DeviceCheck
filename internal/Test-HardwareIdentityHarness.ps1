[CmdletBinding()]
param(
    [string] $FixtureRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\fixtures\hardware-identity'),
    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonFile {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required fixture file was not found: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Add-HarnessAssertion {
    param(
        [System.Collections.Generic.List[object]] $Assertions,
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [bool] $Passed,
        [string] $Expected,
        [string] $Actual
    )

    $Assertions.Add([pscustomobject]@{
            Name     = $Name
            Passed   = $Passed
            Expected = $Expected
            Actual   = $Actual
        }) | Out-Null
}

function Get-UsbIdsVendorOnlyMatch {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $RegistryDevice
    )

    $rawId = @($RegistryDevice.hardwareIds | Where-Object { $_ -match '^USB\\VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4}' } | Select-Object -First 1)[0]
    if (-not $rawId) {
        throw "Fixture does not include a USB VID/PID hardware ID."
    }

    if ($rawId -notmatch 'VID_(?<VendorId>[0-9A-Fa-f]{4})&PID_(?<ProductId>[0-9A-Fa-f]{4})') {
        throw "Could not parse USB VID/PID from fixture hardware ID: $rawId"
    }

    $vendorId = $Matches.VendorId.ToUpperInvariant()
    $productId = $Matches.ProductId.ToUpperInvariant()
    $vendorName = if ($vendorId -eq '0DB0') { 'Micro-Star International' } else { $null }

    [pscustomobject]@{
        SourceId    = 'usb.ids'
        Label       = if ($vendorName) { 'VENDOR-ONLY' } else { 'NO-MATCH' }
        VendorId    = $vendorId
        ProductId   = $productId
        VendorName  = $vendorName
        ProductName = $null
        ClaimScope  = if ($vendorName) { 'vendor' } else { 'none' }
        Confidence  = if ($vendorName) { 10 } else { 0 }
    }
}

function Invoke-HardwareIdentityFixture {
    param(
        [Parameter(Mandatory)]
        [string] $CasePath
    )

    $expectedPath = Join-Path $CasePath 'expected.json'
    $contract = Read-JsonFile -Path $expectedPath
    $inputs = $contract.inputs

    $registryDevice = Read-JsonFile -Path (Join-Path $CasePath $inputs.registryDevice)
    $smbios = Read-JsonFile -Path (Join-Path $CasePath $inputs.smbios)
    $inf = Read-JsonFile -Path (Join-Path $CasePath $inputs.inf)
    $profile = Read-JsonFile -Path (Join-Path $CasePath $inputs.openSourceProfile)

    $assertions = [System.Collections.Generic.List[object]]::new()
    $localMatch = Get-UsbIdsVendorOnlyMatch -RegistryDevice $registryDevice

    Add-HarnessAssertion -Assertions $assertions -Name 'Raw instance ID is preserved' `
        -Passed ($registryDevice.instanceId -eq 'USB\VID_0DB0&PID_CD0E&MI_00\9&9C4D365&0&0000') `
        -Expected 'USB\VID_0DB0&PID_CD0E&MI_00\9&9C4D365&0&0000' `
        -Actual $registryDevice.instanceId

    Add-HarnessAssertion -Assertions $assertions -Name 'usb.ids remains vendor-only' `
        -Passed ($localMatch.Label -eq $contract.expected.localDatabase.label) `
        -Expected $contract.expected.localDatabase.label `
        -Actual $localMatch.Label

    Add-HarnessAssertion -Assertions $assertions -Name 'usb.ids product remains unresolved' `
        -Passed ($null -eq $localMatch.ProductName) `
        -Expected '<null>' `
        -Actual ([string] $localMatch.ProductName)

    Add-HarnessAssertion -Assertions $assertions -Name 'INF resolves only driver display name' `
        -Passed (($inf.resolvedDisplayName -eq $contract.expected.driverIdentity.resolvedName) -and (-not $inf.containsSiliconModel)) `
        -Expected "$($contract.expected.driverIdentity.resolvedName), containsSiliconModel=false" `
        -Actual "$($inf.resolvedDisplayName), containsSiliconModel=$($inf.containsSiliconModel)"

    Add-HarnessAssertion -Assertions $assertions -Name 'Open-source profile resolves codec in separate layer' `
        -Passed (($profile.resolvedCodec -eq $contract.expected.openSourceProfile.resolvedCodec) -and ($profile.sourceId -eq $contract.expected.openSourceProfile.sourceId)) `
        -Expected "$($contract.expected.openSourceProfile.sourceId): $($contract.expected.openSourceProfile.resolvedCodec)" `
        -Actual "$($profile.sourceId): $($profile.resolvedCodec)"

    Add-HarnessAssertion -Assertions $assertions -Name 'SMBIOS context is motherboard context only' `
        -Passed (($smbios.baseBoard.product -like '*X870*TOMAHAWK*') -and ($smbios.baseBoard.manufacturer -like '*Micro-Star*')) `
        -Expected 'Micro-Star X870 Tomahawk motherboard context' `
        -Actual "$($smbios.baseBoard.manufacturer) / $($smbios.baseBoard.product)"

    $confidence = $localMatch.Confidence
    if ($inf.exactHardwareIdMatch) { $confidence += 30 }
    if ($profile.resolvedCodec) { $confidence += 20 }
    if ($smbios.baseBoard.product -like '*X870*TOMAHAWK*') { $confidence += 10 }

    Add-HarnessAssertion -Assertions $assertions -Name 'Confidence floor requires multiple evidence layers' `
        -Passed ($confidence -ge $contract.expected.minimumConfidence) `
        -Expected ">= $($contract.expected.minimumConfidence)" `
        -Actual ([string] $confidence)

    $forbiddenHits = [System.Collections.Generic.List[string]]::new()
    if ($localMatch.ProductName -eq 'Realtek ALC4080') {
        $forbiddenHits.Add('usb.ids exact product Realtek ALC4080') | Out-Null
    }
    if ($inf.containsSiliconModel -or $inf.claimScope -eq 'silicon-model') {
        $forbiddenHits.Add('INF display name is silicon model') | Out-Null
    }
    if (($localMatch.Label -eq 'VENDOR-ONLY') -and $localMatch.ProductName) {
        $forbiddenHits.Add('vendor-only USB match resolves product model') | Out-Null
    }

    Add-HarnessAssertion -Assertions $assertions -Name 'Forbidden claims are absent' `
        -Passed ($forbiddenHits.Count -eq 0) `
        -Expected 'No forbidden claims' `
        -Actual ($(if ($forbiddenHits.Count -eq 0) { 'None' } else { $forbiddenHits -join '; ' }))

    $failed = @($assertions | Where-Object { -not $_.Passed })

    [pscustomobject]@{
        TestCaseId = $contract.testCaseId
        Passed     = ($failed.Count -eq 0)
        Confidence = $confidence
        Assertions = $assertions
    }
}

$caseDirs = @(Get-ChildItem -LiteralPath $FixtureRoot -Directory -ErrorAction Stop | Sort-Object Name)
if ($caseDirs.Count -eq 0) {
    throw "No hardware identity fixture directories found under $FixtureRoot"
}

$results = @(foreach ($caseDir in $caseDirs) {
    Invoke-HardwareIdentityFixture -CasePath $caseDir.FullName
})

$summary = [pscustomobject]@{
    Passed = (@($results | Where-Object { -not $_.Passed }).Count -eq 0)
    Count  = $results.Count
    Cases  = $results
}

if ($AsJson) {
    $summary | ConvertTo-Json -Depth 8
}
else {
    foreach ($result in $results) {
        $status = if ($result.Passed) { 'PASS' } else { 'FAIL' }
        Write-Host ("[{0}] {1} confidence={2}" -f $status, $result.TestCaseId, $result.Confidence)
        foreach ($assertion in $result.Assertions) {
            $assertionStatus = if ($assertion.Passed) { 'PASS' } else { 'FAIL' }
            Write-Host ("  [{0}] {1}" -f $assertionStatus, $assertion.Name)
            if (-not $assertion.Passed) {
                Write-Host ("       expected: {0}" -f $assertion.Expected)
                Write-Host ("       actual  : {0}" -f $assertion.Actual)
            }
        }
    }
}

if (-not $summary.Passed) {
    exit 1
}
