Set-StrictMode -Version Latest

function New-DriverSourceComparisonReport {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory evidence object and does not change system state.')]
    param(
        $LocalEvidence,
        $WindowsUpdateEvidence,
        $CatalogEvidence,
        $CatalogPackageEvidence,
        $SelectionEvidence,
        $OemTraceEvidence,
        $SdioEvidence
    )

    $observations = [System.Collections.Generic.List[string]]::new()
    $observations.Add("Active driver observed: $($LocalEvidence.ActiveDriver.PublishedInf), $($LocalEvidence.ActiveDriver.Version), $($LocalEvidence.ActiveDriver.Date).")

    if ($null -ne $WindowsUpdateEvidence) {
        $observations.Add($WindowsUpdateEvidence.Interpretation)
    }
    if ($null -ne $CatalogEvidence) {
        $observations.Add("Public Catalog query returned $($CatalogEvidence.TotalRowCount) rows; applicability and Windows rank remain unknown.")
    }
    if ($null -ne $CatalogPackageEvidence) {
        $exactPackageMatches = @($CatalogPackageEvidence.Packages | ForEach-Object { $_.Infs } | ForEach-Object { $_.TargetMatches })
        $observations.Add("Downloaded Catalog package inspection found $($exactPackageMatches.Count) target INF matches; the mutation guard remained $($CatalogPackageEvidence.MutationGuard.Unchanged).")
    }
    if ($null -ne $SelectionEvidence) {
        $best = @($SelectionEvidence.Candidates | Where-Object Status -eq 'Best Ranked')
        if ($SelectionEvidence.Mode -eq 'ControlledActivation') {
            $installedBest = @($SelectionEvidence.Candidates | Where-Object Status -eq 'Best Ranked / Installed')
            $observations.Add("Controlled Windows activation evidence found $($installedBest.Count) Best Ranked / Installed candidate(s); activation succeeded: $($SelectionEvidence.DeviceGuard.ActivationSucceeded).")
            $observations.Add("Physical media test status: $($SelectionEvidence.FunctionalEvidence.MediaTestStatus).")
        }
        else {
            $observations.Add("Stage-only Windows selection evidence found $($best.Count) Best Ranked candidate(s); active binding unchanged: $($SelectionEvidence.NetworkGuard.ActiveBindingUnchanged).")
            if ($null -ne $SelectionEvidence.PSObject.Properties['Cleanup']) {
                $observations.Add("Experiment cleanup restored baseline candidates: $($SelectionEvidence.Cleanup.RestoredBaselineCandidates); active after cleanup: $($SelectionEvidence.Cleanup.ActiveInfAfterCleanup).")
            }
        }
    }
    if ($null -ne $OemTraceEvidence) {
        $observations.Add("OEM trace outcome: $($OemTraceEvidence.Outcome).")
    }
    if ($null -ne $SdioEvidence) {
        $observations.Add('SDIO evidence is preserved as an independent recommendation surface, not converted into Windows rank.')
        if ($null -ne $SdioEvidence.PSObject.Properties['LocalComparison']) {
            $indexOnlyCount = if ($null -ne $SdioEvidence.LocalComparison.PSObject.Properties['IndexOnlyCount']) { [int]$SdioEvidence.LocalComparison.IndexOnlyCount } else { 0 }
            $observations.Add("Local SDIO audit found $($SdioEvidence.LocalComparison.ApplicableCount) available unique candidate(s), including $($SdioEvidence.LocalComparison.NewerThanActiveCount) newer than active; $indexOnlyCount index-only row(s) have no active local payload pack.")
            if ($SdioEvidence.LocalComparison.SelectionAssessment.Status -eq 'NotRequiredSameAsActive') {
                $observations.Add('The extracted OEM candidate has the same matched ID, DriverVer date, and version as the active driver; a selection test is not required for that identical candidate.')
            }
            if ($SdioEvidence.LocalComparison.Outcome -eq 'NoNewerOrBetterCandidate') {
                $observations.Add('Fast SDIO policy found no best candidate labeled NEW or BETTER; current/older/duplicate/invalid rows were not inspected.')
            }
        }
    }

    $overallVerdict = 'EvidenceComparisonOnly'
    $nextGate = 'Download and inspect a specific candidate package only when a Catalog/WU row needs INF-level applicability and DriverVer verification.'
    $sdioCurrent = @(
        if ($null -ne $SdioEvidence) {
            $SdioEvidence.Devices | ForEach-Object { $_.Candidates } | Where-Object {
                @($_.StatusLabels) -contains 'SAME' -and @($_.StatusLabels) -contains 'CURRENT'
            }
        }
    )
    if ($LocalEvidence.Device.Status -eq 'OK' -and
        $null -ne $WindowsUpdateEvidence -and $WindowsUpdateEvidence.MatchingOfferCount -eq 0 -and
        $null -ne $OemTraceEvidence -and $OemTraceEvidence.Outcome -eq 'ObservedOutrankedCandidate' -and
        $sdioCurrent.Count -gt 0) {
        $overallVerdict = 'KeepCurrent_NoVerifiedBetterCandidate'
        $nextGate = 'Optional: download one relevant public Catalog CAB and inspect its INF metadata before treating the Catalog title version as a comparable candidate.'
    }
    if ($LocalEvidence.Device.Status -eq 'OK' -and
        $null -ne $OemTraceEvidence -and $OemTraceEvidence.Outcome -eq 'ObservedOutrankedCandidate' -and
        $null -ne $SdioEvidence -and
        $null -ne $SdioEvidence.PSObject.Properties['LocalComparison'] -and
        $SdioEvidence.LocalComparison.Outcome -eq 'NoNewerOrBetterCandidate' -and
        ($null -eq $WindowsUpdateEvidence -or [int]$WindowsUpdateEvidence.MatchingOfferCount -eq 0)) {
        $overallVerdict = 'KeepCurrent_NoVerifiedBetterCandidate'
        $nextGate = 'The tested OEM candidate was outranked and the fast local SDIO policy found no best NEW/BETTER candidate. Keep the current driver unless another source is explicitly requested.'
    }
    if ($LocalEvidence.Device.Status -eq 'OK' -and
        $null -ne $SdioEvidence -and
        $null -ne $SdioEvidence.PSObject.Properties['LocalComparison'] -and
        $SdioEvidence.LocalComparison.SelectionAssessment.Status -eq 'NotRequiredSameAsActive' -and
        [int]$SdioEvidence.LocalComparison.NewerThanActiveCount -eq 0) {
        $overallVerdict = 'KeepCurrent_NoVerifiedBetterCandidate'
        $nextGate = 'No selection test is needed for the extracted OEM candidate because it is the active DriverVer on the same matched ID. Local SDIO candidates are not newer; keep the current driver.'
    }
    $newerCatalogCandidates = @(
        if ($null -ne $CatalogPackageEvidence) {
            $CatalogPackageEvidence.Packages | ForEach-Object { $_.Infs } | Where-Object {
                $_.ActiveComparison.DateRelation -eq 'Newer' -and @($_.TargetMatches).Count -gt 0
            }
        }
    )
    if ($newerCatalogCandidates.Count -gt 0 -and
        $null -ne $WindowsUpdateEvidence -and $WindowsUpdateEvidence.MatchingOfferCount -eq 0) {
        $overallVerdict = 'KeepCurrent_CatalogCandidateRequiresControlledSelectionProof'
        $nextGate = 'A signed exact-match Catalog candidate has a later DriverVer date but is not offered by current WUAPI. Proving actual Windows selection now requires an explicitly authorized, mutation-traced staging/update experiment.'
    }
    $observedBestCandidates = @(
        if ($null -ne $SelectionEvidence) {
            $SelectionEvidence.Candidates | Where-Object Status -eq 'Best Ranked'
        }
    )
    if ($null -ne $SelectionEvidence -and $SelectionEvidence.Mode -eq 'StageOnlyNoInstall' -and
        $observedBestCandidates.Count -gt 0 -and
        [bool]$SelectionEvidence.NetworkGuard.ActiveBindingUnchanged -and
        [bool]$SelectionEvidence.NetworkGuard.AdapterStayedUp) {
        $overallVerdict = 'CatalogCandidateObservedBestRanked_ActiveUnchanged'
        $nextGate = 'Windows has ranked the staged Catalog candidate as Best Ranked. Actual activation is optional and must use a separate connectivity-safe, resumable experiment with explicit authorization.'
    }
    $observedInstalledBest = @(
        if ($null -ne $SelectionEvidence) {
            $SelectionEvidence.Candidates | Where-Object Status -eq 'Best Ranked / Installed'
        }
    )
    if ($null -ne $SelectionEvidence -and $SelectionEvidence.Mode -eq 'ControlledActivation' -and
        $observedInstalledBest.Count -gt 0 -and
        [bool]$SelectionEvidence.DeviceGuard.ActivationSucceeded -and
        [string]$SelectionEvidence.DeviceGuard.StatusAfter -eq 'OK' -and
        [int]$SelectionEvidence.DeviceGuard.ProblemCodeAfter -eq 0) {
        $overallVerdict = 'CandidateObservedBestRankedAndActivated'
        $nextGate = if ($SelectionEvidence.FunctionalEvidence.MediaTestStatus -eq 'Verified') {
            'The candidate is selected, active, healthy, and functionally verified with physical media. Preserve post-reboot evidence if long-term validation is required.'
        }
        else {
            'The candidate is selected, active, and healthy. Insert suitable physical media for an optional read/write test before claiming full device functionality.'
        }
    }

    [pscustomobject]@{
        SchemaVersion = 1
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Safety = [pscustomobject]@{
            Mode                = 'AuditOnly'
            DownloadsDrivers    = $false
            InstallsDrivers     = $false
            RemovesDrivers      = $false
            ChangesDeviceState  = $false
            IntegratesMainTui   = $false
            CatalogUsesNetwork  = $null -ne $CatalogEvidence
            WuapiUsesNetwork    = $null -ne $WindowsUpdateEvidence
            ImportsPackageInspection = $null -ne $CatalogPackageEvidence
            ImportsStageOnlySelectionEvidence = $null -ne $SelectionEvidence -and $SelectionEvidence.Mode -eq 'StageOnlyNoInstall'
            ImportsControlledActivationEvidence = $null -ne $SelectionEvidence -and $SelectionEvidence.Mode -eq 'ControlledActivation'
            RunsLocalSdioAudit = $null -ne $SdioEvidence -and $null -ne $SdioEvidence.PSObject.Properties['Source'] -and [string]$SdioEvidence.Source -in @('SdioRun', 'ExistingLog')
        }
        Target = $LocalEvidence.Device
        Active = $LocalEvidence
        Sources = [pscustomobject]@{
            WindowsUpdate = $WindowsUpdateEvidence
            CatalogPublic = $CatalogEvidence
            CatalogPackage = $CatalogPackageEvidence
            SelectionExperiment = $SelectionEvidence
            OEMTrace      = $OemTraceEvidence
            SDIO          = $SdioEvidence
        }
        Observations = @($observations)
        OverallVerdict = $overallVerdict
        NextGate = $nextGate
    }
}

function ConvertTo-DriverSourceComparisonMarkdown {
    param($Report)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Driver Source Comparison')
    $lines.Add('')
    $lines.Add(('- Generated UTC: `{0}`' -f $Report.GeneratedAtUtc))
    $lines.Add(('- Device: **{0}**' -f $Report.Target.FriendlyName))
    $lines.Add(('- Instance: `{0}`' -f $Report.Target.InstanceId))
    $lines.Add('- Safety: this comparison run is audit-only; imported evidence may describe a separately authorized staging or controlled activation experiment')
    $lines.Add('')
    $lines.Add('## Active Windows Evidence')
    $lines.Add('')
    $lines.Add(('- Published INF: `{0}`' -f $Report.Active.ActiveDriver.PublishedInf))
    $lines.Add(('- Provider: `{0}`' -f $Report.Active.ActiveDriver.Provider))
    $lines.Add(('- DriverVer: `{0} / {1}`' -f $Report.Active.ActiveDriver.Date, $Report.Active.ActiveDriver.Version))
    $lines.Add(('- Matching ID: `{0}`' -f $Report.Active.ActiveDriver.MatchingDeviceId))
    $lines.Add(('- Signer: `{0}`' -f $Report.Active.ActiveDriver.Signer))
    $lines.Add(('- Known provenance: `{0}`' -f $Report.Active.KnownProvenance))
    $lines.Add('')

    $wu = $Report.Sources.WindowsUpdate
    $lines.Add('## Current Windows Update Evidence')
    $lines.Add('')
    if ($null -eq $wu) {
        $lines.Add('- Not queried.')
    }
    else {
        $lines.Add(('- Outcome: **{0}**' -f $wu.Outcome))
        $lines.Add(('- Current driver offers returned for all devices: `{0}`' -f $wu.TotalDriverOffers))
        $lines.Add(('- Target-matching offers: `{0}`' -f $wu.MatchingOfferCount))
        $lines.Add(('- Interpretation: {0}' -f $wu.Interpretation))
        foreach ($offer in @($wu.Offers)) {
            $lines.Add(('- `{0}` - {1} - `{2}`' -f $offer.DriverHardwareId, $offer.Title, $offer.UpdateId))
        }
    }
    $lines.Add('')

    $catalog = $Report.Sources.CatalogPublic
    $lines.Add('## Public Catalog Evidence')
    $lines.Add('')
    if ($null -eq $catalog) {
        $lines.Add('- Not queried.')
    }
    else {
        $lines.Add(('- Query: `{0}`' -f $catalog.QueryHardwareId))
        foreach ($attempt in @($catalog.QueryAttempts)) {
            $lines.Add(('- Attempt: `{0}` => `{1}` public rows' -f $attempt.HardwareId, $attempt.RowCount))
        }
        $lines.Add(('- Public rows: `{0}`' -f $catalog.TotalRowCount))
        $lines.Add(('- Outcome: **{0}**' -f $catalog.Outcome))
        $lines.Add(('- Interpretation: {0}' -f $catalog.Interpretation))
        $lines.Add('')
        $lines.Add('| Last updated | Title version | Title | Products | GUID |')
        $lines.Add('|---|---|---|---|---|')
        foreach ($row in @($catalog.Rows | Select-Object -First 12)) {
            $title = ([string]$row.Title).Replace('|', '\|')
            $products = ([string]$row.Products).Replace('|', '\|')
            $lines.Add(('| {0} | `{1}` | {2} | {3} | `{4}` |' -f $row.LastUpdated, $row.Version, $title, $products, $row.Guid))
        }
    }
    $lines.Add('')

    $catalogPackage = $Report.Sources.CatalogPackage
    $lines.Add('## Catalog Package Inspection')
    $lines.Add('')
    if ($null -eq $catalogPackage) {
        $lines.Add('- Not supplied.')
    }
    else {
        $lines.Add(('- Mutation guard unchanged: `{0}`' -f $catalogPackage.MutationGuard.Unchanged))
        $lines.Add('- Package download and extraction did not stage or install a driver.')
        foreach ($package in @($catalogPackage.Packages)) {
            $lines.Add(('- GUID `{0}` / CAB `{1}` bytes / SHA-1 verified `{2}` / signature `{3}`' -f $package.CatalogGuid, $package.CabLength, $package.SHA1Verified, $package.CabSignatureStatus))
            foreach ($inf in @($package.Infs)) {
                $lines.Add(('  - INF `{0}` / DriverVer `{1}` / date `{2}` vs active / version `{3}` vs active' -f $inf.Name, $inf.DriverVer, $inf.ActiveComparison.DateRelation, $inf.ActiveComparison.VersionRelation))
                foreach ($match in @($inf.TargetMatches)) {
                    $lines.Add(('    - `{0}` / {1} / feature `{2}` / identifier `{3}` / computed rank body `{4}`' -f $match.HardwareId, $match.MatchKind, $match.FeatureScore, $match.IdentifierScore, $match.ComputedRankBody))
                    $lines.Add(('    - Confidence: `{0}`; this is not observed Windows selection evidence.' -f $match.ComputedRankConfidence))
                }
            }
        }
    }
    $lines.Add('')

    $selection = $Report.Sources.SelectionExperiment
    $lines.Add('## Observed Windows Selection Evidence')
    $lines.Add('')
    if ($null -eq $selection) {
        $lines.Add('- Not supplied.')
    }
    else {
        $lines.Add(('- Mode: `{0}`; `/install` used: `{1}`; `/reboot` used: `{2}`' -f $selection.Mode, $selection.CommandGuards.InstallSwitchUsed, $selection.CommandGuards.RebootSwitchUsed))
        $lines.Add(('- Outcome: **{0}**' -f $selection.Outcome))
        if ($selection.Mode -eq 'ControlledActivation') {
            $lines.Add(('- Active binding: `{0}` before, `{1}` after; activation succeeded: `{2}`' -f $selection.DeviceGuard.ActiveInfBefore, $selection.DeviceGuard.ActiveInfAfter, $selection.DeviceGuard.ActivationSucceeded))
            $lines.Add(('- Device after activation: status `{0}`, problem code `{1}`, service `{2}`' -f $selection.DeviceGuard.StatusAfter, $selection.DeviceGuard.ProblemCodeAfter, $selection.DeviceGuard.ServiceAfter))
            $lines.Add(('- Extension INF before/after: `{0}` / `{1}`' -f (@($selection.DeviceGuard.ExtensionInfBefore) -join ', '), (@($selection.DeviceGuard.ExtensionInfAfter) -join ', ')))
            $lines.Add(('- Loaded binary: `{0}` / version `{1}` / signature `{2}` / payload hash match `{3}`' -f $selection.RuntimeEvidence.BinaryPath, $selection.RuntimeEvidence.FileVersion, $selection.RuntimeEvidence.SignatureStatus, $selection.RuntimeEvidence.MatchesPayloadHash))
            $lines.Add(('- Physical media test: `{0}` - {1}' -f $selection.FunctionalEvidence.MediaTestStatus, $selection.FunctionalEvidence.Interpretation))
        }
        else {
            $lines.Add(('- Active binding: `{0}` before, `{1}` after; unchanged: `{2}`' -f $selection.NetworkGuard.ActiveInfBefore, $selection.NetworkGuard.ActiveInfAfter, $selection.NetworkGuard.ActiveBindingUnchanged))
            $lines.Add(('- Adapter stayed up: `{0}`' -f $selection.NetworkGuard.AdapterStayedUp))
            if ($null -ne $selection.PSObject.Properties['Cleanup']) {
                $lines.Add(('- Cleanup deleted: `{0}`; `/uninstall` used: `{1}`; `/force` used: `{2}`' -f (@($selection.Cleanup.DeletedPublishedInfs) -join ', '), $selection.Cleanup.UninstallSwitchUsed, $selection.Cleanup.ForceSwitchUsed))
                $lines.Add(('- Cleanup restored baseline candidates: `{0}`; active after cleanup: `{1}`; adapter: `{2}`' -f $selection.Cleanup.RestoredBaselineCandidates, $selection.Cleanup.ActiveInfAfterCleanup, $selection.Cleanup.AdapterStatusAfterCleanup))
            }
        }
        $lines.Add('')
        $lines.Add('| Published INF | DriverVer | Rank | Windows status |')
        $lines.Add('|---|---|---|---|')
        foreach ($candidate in @($selection.Candidates)) {
            $lines.Add(('| `{0}` | `{1}` | `{2}` | **{3}** |' -f $candidate.PublishedInf, $candidate.DriverVer, $candidate.Rank, $candidate.Status))
        }
    }
    $lines.Add('')

    $sdio = $Report.Sources.SDIO
    $lines.Add('## SDIO Audit Evidence')
    $lines.Add('')
    if ($null -eq $sdio) {
        $lines.Add('- Not supplied.')
    }
    else {
        $lines.Add(('- Matched devices: `{0}` / `{1}`' -f $sdio.MatchedDeviceCount, $sdio.TotalDeviceCount))
        $lines.Add(('- Parser warnings: `{0}`' -f @($sdio.ParserWarnings).Count))
        if ($null -ne $sdio.PSObject.Properties['LocalComparison']) {
            $localSdio = $sdio.LocalComparison
            $lines.Add(('- Local outcome: **{0}**' -f $localSdio.Outcome))
            $indexOnlyCount = if ($null -ne $localSdio.PSObject.Properties['IndexOnlyCount']) { [int]$localSdio.IndexOnlyCount } else { 0 }
            $lines.Add(('- Available unique candidates: `{0}`; newer than active: `{1}`; index-only without local payload: `{2}`' -f $localSdio.ApplicableCount, $localSdio.NewerThanActiveCount, $indexOnlyCount))
            $lines.Add(('- Selection assessment: **{0}** - {1}' -f $localSdio.SelectionAssessment.Status, $localSdio.SelectionAssessment.Display))
            $lines.Add('')
            $lines.Add('| Relation | DriverVer | SDIO status | INF | Driver pack |')
            $lines.Add('|---|---|---|---|---|')
            foreach ($candidate in @($localSdio.Candidates | Select-Object -First 12)) {
                $lines.Add(('| **{0}** | `{1}` | `{2}` | `{3}` | `{4}` |' -f $candidate.ActiveRelation, $candidate.DriverVer, $candidate.SdioStatus, $candidate.InfFile, $candidate.PackName))
            }
        }
        foreach ($warning in @($sdio.ParserWarnings | Select-Object -First 8)) {
            $lines.Add(('- Warning: `{0}`' -f ([string]$warning).Replace('`', "'")))
        }
        foreach ($device in @($sdio.Devices)) {
            $lines.Add(('- Installed: `{0} / {1} / {2}`' -f $device.Installed.Date, $device.Installed.Version, $device.Installed.Inf))
            foreach ($candidate in @($device.Candidates | Select-Object -First 8)) {
                $labels = @($candidate.StatusLabels) -join '+'
                $lines.Add(('- Candidate: **{0}** `{1} / {2}` - `{3}`' -f $labels, $candidate.Date, $candidate.Version, $candidate.InfFile))
            }
        }
    }
    $lines.Add('')

    $oemTrace = $Report.Sources.OEMTrace
    $lines.Add('## OEM Package Trace Evidence')
    $lines.Add('')
    if ($null -eq $oemTrace) {
        $lines.Add('- Not supplied.')
    }
    else {
        $lines.Add(('- Installer: `{0}`' -f $oemTrace.InstallerName))
        $lines.Add(('- Outcome: **{0}**' -f $oemTrace.Outcome))
        $lines.Add(('- Target preview matches: `{0}`' -f @($oemTrace.TargetPreviewMatches).Count))
        foreach ($match in @($oemTrace.TargetPreviewMatches)) {
            $lines.Add(('- {0}: `{1}` => `{2}` (`{3}`)' -f $match.MatchKind, $match.MatchedId, $match.Inf, $match.DriverVer))
        }
        foreach ($node in @($oemTrace.TargetDriverNodes)) {
            $lines.Add(('- SetupAPI: **{0}** `{1}` / `{2}` / rank `{3}`' -f $node.Status, $node.PublishedName, $node.OriginalName, $node.DriverRank))
        }
        $lines.Add(('- Added published packages: `{0}`' -f @($oemTrace.AddedPublishedDrivers).Count))
    }
    $lines.Add('')

    $lines.Add('## Interpretation')
    $lines.Add('')
    foreach ($observation in @($Report.Observations)) {
        $lines.Add(('- {0}' -f $observation))
    }
    if ($null -ne $Report.PSObject.Properties['Benchmark']) {
        $lines.Add('')
        $lines.Add('## Benchmark')
        $lines.Add('')
        $lines.Add(('- Total: `{0}` seconds; slowest phase: `{1}` (`{2}` ms)' -f $Report.Benchmark.TotalSeconds, $Report.Benchmark.SlowestPhase, $Report.Benchmark.SlowestMs))
        foreach ($phase in @($Report.Benchmark.Phases)) {
            $lines.Add(('- `{0}`: `{1}` ms ({2})' -f $phase.Name, $phase.DurationMs, $phase.Status))
        }
    }
    if ($null -ne $Report.PSObject.Properties['AdvisorRecommendation']) {
        $advisor = $Report.AdvisorRecommendation
        $lines.Add('')
        $lines.Add('## Advisor Recommendation')
        $lines.Add('')
        $lines.Add(('- Code: **{0}**' -f $advisor.Code))
        $lines.Add(('- Recommendation: **{0}**' -f $advisor.Title))
        $lines.Add(('- Confidence: `{0}`; risk: `{1}`; next action: `{2}`' -f $advisor.Confidence, $advisor.Risk, $advisor.RecommendedAction))
        $lines.Add(('- Summary: {0}' -f $advisor.Summary))
        foreach ($reason in @($advisor.Reasons)) {
            $lines.Add(('- {0}: {1}' -f $reason.Kind, $reason.Text))
        }
        foreach ($caveat in @($advisor.Caveats)) {
            $lines.Add(('- Caveat: {0}' -f $caveat))
        }
    }
    $lines.Add('')
    $lines.Add(('**Verdict:** {0}' -f $Report.OverallVerdict))
    $lines.Add('')
    $lines.Add(('**Next gate:** {0}' -f $Report.NextGate))

    return ($lines -join [Environment]::NewLine)
}
