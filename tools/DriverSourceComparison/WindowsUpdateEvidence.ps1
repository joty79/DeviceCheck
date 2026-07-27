Set-StrictMode -Version Latest

function Get-DriverComparisonComProperty {
    param(
        $InputObject,
        [string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    try {
        return $InputObject.$Name
    }
    catch {
        return $DefaultValue
    }
}

function Get-WindowsUpdateDriverEvidence {
    param(
        [string[]]$HardwareIds,
        [string[]]$CompatibleIds
    )

    $targetIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($HardwareIds) + @($CompatibleIds)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$id)) {
            [void]$targetIds.Add(([string]$id).Trim())
        }
    }

    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'DeviceCheck Driver Source Comparison Audit'
    $searcher = $session.CreateUpdateSearcher()
    $searcher.Online = $true

    $criteria = "IsInstalled=0 and Type='Driver'"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $searcher.Search($criteria)
    $stopwatch.Stop()

    $offers = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $result.Updates.Count; $index++) {
        $update = $result.Updates.Item($index)
        $driverHardwareId = [string](Get-DriverComparisonComProperty -InputObject $update -Name 'DriverHardwareID' -DefaultValue '')
        if (-not $targetIds.Contains($driverHardwareId)) {
            continue
        }

        $identity = Get-DriverComparisonComProperty -InputObject $update -Name 'Identity'
        $driverDate = Get-DriverComparisonComProperty -InputObject $update -Name 'DriverVerDate'
        $offers.Add([pscustomobject]@{
                Source               = 'WindowsUpdate'
                Confidence           = 'Observed'
                EvidenceSource       = 'WUAPI IUpdateSearcher.Search'
                Title                = [string](Get-DriverComparisonComProperty -InputObject $update -Name 'Title' -DefaultValue '')
                UpdateId             = [string](Get-DriverComparisonComProperty -InputObject $identity -Name 'UpdateID' -DefaultValue '')
                RevisionNumber       = Get-DriverComparisonComProperty -InputObject $identity -Name 'RevisionNumber'
                DriverHardwareId     = $driverHardwareId
                DriverModel          = [string](Get-DriverComparisonComProperty -InputObject $update -Name 'DriverModel' -DefaultValue '')
                DriverManufacturer   = [string](Get-DriverComparisonComProperty -InputObject $update -Name 'DriverManufacturer' -DefaultValue '')
                DriverProvider       = [string](Get-DriverComparisonComProperty -InputObject $update -Name 'DriverProvider' -DefaultValue '')
                DriverVerDate        = if ($driverDate -is [datetime]) { $driverDate.ToString('yyyy-MM-dd') } else { [string]$driverDate }
                IsDownloaded         = [bool](Get-DriverComparisonComProperty -InputObject $update -Name 'IsDownloaded' -DefaultValue $false)
                IsAssigned           = [bool](Get-DriverComparisonComProperty -InputObject $update -Name 'IsAssigned' -DefaultValue $false)
                BrowseOnly           = [bool](Get-DriverComparisonComProperty -InputObject $update -Name 'BrowseOnly' -DefaultValue $false)
                AutoSelectOnWebSites = [bool](Get-DriverComparisonComProperty -InputObject $update -Name 'AutoSelectOnWebSites' -DefaultValue $false)
                Applicability        = 'CurrentClientSearchMatch'
                ActiveState          = 'Unknown'
                WindowsRank          = $null
            })
    }

    [pscustomobject]@{
        Source               = 'WindowsUpdate'
        Confidence           = 'Observed'
        EvidenceSource       = 'WUAPI IUpdateSearcher.Search'
        Criteria             = $criteria
        ResultCode           = [int]$result.ResultCode
        ElapsedMs            = [int]$stopwatch.ElapsedMilliseconds
        TotalDriverOffers    = [int]$result.Updates.Count
        MatchingOfferCount   = $offers.Count
        Outcome              = if ($offers.Count -gt 0) { 'CurrentWuOfferObserved' } else { 'NoCurrentWuOfferObserved' }
        Interpretation       = if ($offers.Count -gt 0) {
            'WUAPI returned one or more currently applicable target-matching driver offers.'
        }
        else {
            'WUAPI returned no current target-matching offer. This does not prove that Windows Update never offered one previously.'
        }
        Offers               = @($offers)
    }
}
