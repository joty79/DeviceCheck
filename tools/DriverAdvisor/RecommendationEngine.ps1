[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '', Justification = 'Repository policy uses UTF-8 without BOM for PowerShell source.')]
param()

Set-StrictMode -Version Latest

function Get-DriverAdvisorPathValue {
    param(
        $InputObject,
        [Parameter(Mandatory)][string]$Path,
        $Default = $null
    )

    $current = $InputObject
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $Default }

        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $Default }
            $current = $current[$segment]
            continue
        }

        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $Default }
        $current = $property.Value
    }

    if ($null -eq $current) { return $Default }
    return $current
}

function New-DriverAdvisorReason {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory reason object and does not change system state.')]
    param(
        [ValidateSet('Positive', 'Caution', 'Neutral', 'Blocking')]
        [string]$Kind,
        [string]$Code,
        [string]$Text,
        [string]$Evidence = ''
    )

    [pscustomobject]@{
        Kind     = $Kind
        Code     = $Code
        Text     = $Text
        Evidence = $Evidence
    }
}

function Get-DriverAdvisorActivationRisk {
    param(
        [string]$DeviceClass,
        [bool]$AlreadyActivated
    )

    if ($AlreadyActivated) { return 'Low' }

    switch ($DeviceClass) {
        'Net' { return 'High' }
        { $_ -in @('Display', 'SCSIAdapter', 'HDC', 'System', 'Firmware') } { return 'High' }
        { $_ -in @('Media', 'AudioEndpoint', 'USB', 'Bluetooth') } { return 'Moderate' }
        default { return 'Moderate' }
    }
}

function Get-DriverAdvisorRecommendation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory recommendation and does not change system state.')]
    param(
        [Parameter(Mandatory)]$Report
    )

    $reasons = [System.Collections.Generic.List[object]]::new()
    $caveats = [System.Collections.Generic.List[string]]::new()
    $actions = [System.Collections.Generic.List[object]]::new()

    $deviceClass = [string](Get-DriverAdvisorPathValue -InputObject $Report -Path 'Target.Class' -Default '')
    $deviceStatus = [string](Get-DriverAdvisorPathValue -InputObject $Report -Path 'Target.Status' -Default 'Unknown')
    $problemCode = Get-DriverAdvisorPathValue -InputObject $Report -Path 'Target.ProblemCode' -Default $null
    $selection = Get-DriverAdvisorPathValue -InputObject $Report -Path 'Sources.SelectionExperiment'
    $wuOutcome = [string](Get-DriverAdvisorPathValue -InputObject $Report -Path 'Sources.WindowsUpdate.Outcome' -Default '')
    $wuMatches = [int](Get-DriverAdvisorPathValue -InputObject $Report -Path 'Sources.WindowsUpdate.MatchingOfferCount' -Default 0)
    $catalogRows = [int](Get-DriverAdvisorPathValue -InputObject $Report -Path 'Sources.CatalogPublic.TotalRowCount' -Default 0)
    $oemOutcome = [string](Get-DriverAdvisorPathValue -InputObject $Report -Path 'Sources.OEMTrace.Outcome' -Default '')
    $legacyVerdict = [string](Get-DriverAdvisorPathValue -InputObject $Report -Path 'OverallVerdict' -Default 'EvidenceComparisonOnly')

    $code = 'NeedMoreEvidence'
    $title = 'Χρειάζεται περισσότερη verified πληροφορία'
    $summary = 'Τα διαθέσιμα sources δεν αποδεικνύουν ακόμη ποια ενέργεια είναι καλύτερη.'
    $recommendedAction = 'InspectEvidence'
    $confidence = 'Insufficient'
    $evidenceLevel = 'DiscoveryOnly'
    $risk = 'Unknown'
    $candidate = $null

    if ($deviceStatus -ne 'OK' -or ($null -ne $problemCode -and [int]$problemCode -ne 0)) {
        $reasons.Add((New-DriverAdvisorReason -Kind Blocking -Code 'DeviceNotHealthy' -Text 'Η συσκευή δεν είναι σε καθαρό OK state· προηγείται diagnosis.' -Evidence "Status=$deviceStatus; ProblemCode=$problemCode"))
        $code = 'DiagnoseDeviceFirst'
        $title = 'Κάνε diagnosis πριν από αλλαγή driver'
        $summary = 'Δεν είναι ασφαλές να αξιολογηθεί upgrade όσο το current device state έχει πρόβλημα.'
        $recommendedAction = 'Diagnose'
        $risk = 'High'
    }
    elseif ($null -ne $selection -and [string]$selection.Mode -eq 'ControlledActivation') {
        $installedBest = @($selection.Candidates | Where-Object Status -eq 'Best Ranked / Installed')
        $activationSucceeded = [bool](Get-DriverAdvisorPathValue -InputObject $selection -Path 'DeviceGuard.ActivationSucceeded' -Default $false)
        $statusAfter = [string](Get-DriverAdvisorPathValue -InputObject $selection -Path 'DeviceGuard.StatusAfter' -Default 'Unknown')
        $problemAfter = [int](Get-DriverAdvisorPathValue -InputObject $selection -Path 'DeviceGuard.ProblemCodeAfter' -Default -1)
        $signature = [string](Get-DriverAdvisorPathValue -InputObject $selection -Path 'RuntimeEvidence.SignatureStatus' -Default 'Unknown')
        $hashMatch = [bool](Get-DriverAdvisorPathValue -InputObject $selection -Path 'RuntimeEvidence.MatchesPayloadHash' -Default $false)

        if ($activationSucceeded -and $installedBest.Count -gt 0 -and $statusAfter -eq 'OK' -and $problemAfter -eq 0) {
            $candidate = $installedBest[0]
            $code = 'KeepVerifiedActiveCandidate'
            $title = 'Διατήρησε τον ενεργό verified candidate'
            $summary = 'Ο candidate είναι ήδη Best Ranked / Installed και το controlled activation ολοκληρώθηκε καθαρά.'
            $recommendedAction = 'KeepActiveCandidate'
            $confidence = 'High'
            $evidenceLevel = 'ObservedActivation'
            $risk = Get-DriverAdvisorActivationRisk -DeviceClass $deviceClass -AlreadyActivated $true
            $reasons.Add((New-DriverAdvisorReason -Kind Positive -Code 'ObservedBestInstalled' -Text 'Τα Windows τον αναφέρουν ως Best Ranked / Installed.' -Evidence "$($candidate.PublishedInf); rank $($candidate.Rank)"))
            $reasons.Add((New-DriverAdvisorReason -Kind Positive -Code 'HealthyAfterActivation' -Text 'Η συσκευή επέστρεψε OK με problem code 0 μετά το activation.' -Evidence "Status=$statusAfter"))
            if ($signature -eq 'Valid') {
                $reasons.Add((New-DriverAdvisorReason -Kind Positive -Code 'LoadedBinarySigned' -Text 'Το loaded driver binary έχει valid signature.' -Evidence $signature))
            }
            if ($hashMatch) {
                $reasons.Add((New-DriverAdvisorReason -Kind Positive -Code 'LoadedBinaryMatchesPayload' -Text 'Το loaded binary hash ταιριάζει με το inspected payload.' -Evidence 'SHA-256 match'))
            }

            $mediaStatus = [string](Get-DriverAdvisorPathValue -InputObject $selection -Path 'FunctionalEvidence.MediaTestStatus' -Default 'NotRecorded')
            if ($mediaStatus -ne 'Verified') {
                $caveats.Add('Για full functionality claim χρειάζεται inserted media και ελεγχόμενο read/write test.')
                $reasons.Add((New-DriverAdvisorReason -Kind Caution -Code 'FunctionalMediaPending' -Text 'Το driver/device health είναι verified, αλλά το physical-media I/O δεν δοκιμάστηκε.' -Evidence $mediaStatus))
            }
        }
    }
    elseif ($null -ne $selection -and [string]$selection.Mode -eq 'StageOnlyNoInstall') {
        $best = @($selection.Candidates | Where-Object Status -eq 'Best Ranked')
        $bindingUnchanged = [bool](Get-DriverAdvisorPathValue -InputObject $selection -Path 'NetworkGuard.ActiveBindingUnchanged' -Default $false)
        if ($best.Count -gt 0 -and $bindingUnchanged) {
            $candidate = $best[0]
            $code = 'ControlledActivationRecommended'
            $title = 'Κράτησε προσωρινά τον current driver'
            $summary = 'Ο staged candidate κέρδισε το Windows ranking, αλλά δεν έχει ακόμη αποδειχθεί activation και λειτουργία.'
            $recommendedAction = 'ControlledActivation'
            $confidence = 'High'
            $evidenceLevel = 'ObservedSelection'
            $risk = Get-DriverAdvisorActivationRisk -DeviceClass $deviceClass -AlreadyActivated $false
            $reasons.Add((New-DriverAdvisorReason -Kind Positive -Code 'ObservedBestRanked' -Text 'Το authoritative pnputil evidence δείχνει τον candidate ως Best Ranked.' -Evidence "$($candidate.PublishedInf); rank $($candidate.Rank)"))
            $reasons.Add((New-DriverAdvisorReason -Kind Caution -Code 'ActivationNotObserved' -Text 'Δεν έχει παρατηρηθεί ακόμη successful activation του candidate.' -Evidence 'Stage-only experiment'))
            if ($risk -eq 'High') {
                $caveats.Add('Η συσκευή είναι high-impact class· απαιτείται fallback και resumable capture πριν από activation.')
            }
            if ([bool](Get-DriverAdvisorPathValue -InputObject $selection -Path 'Cleanup.RestoredBaselineCandidates' -Default $false)) {
                $reasons.Add((New-DriverAdvisorReason -Kind Neutral -Code 'BaselineRestored' -Text 'Το stage-only cleanup αποκατέστησε το αρχικό candidate set.' -Evidence 'Cleanup verified'))
            }
        }
    }

    if ($code -eq 'NeedMoreEvidence' -and $legacyVerdict -eq 'KeepCurrent_NoVerifiedBetterCandidate') {
        $code = 'KeepCurrentNoVerifiedBetterCandidate'
        $title = 'Διατήρησε τον current driver'
        $summary = 'Δεν υπάρχει verified καλύτερος candidate στα διαθέσιμα evidence sources.'
        $recommendedAction = 'KeepCurrent'
        $confidence = 'High'
        $evidenceLevel = 'ObservedComparison'
        $risk = 'Low'
        $reasons.Add((New-DriverAdvisorReason -Kind Positive -Code 'CurrentHealthy' -Text 'Ο active driver και η συσκευή είναι healthy.' -Evidence $deviceStatus))
        $localSdio = Get-DriverAdvisorPathValue -InputObject $Report -Path 'Sources.SDIO.LocalComparison'
        if ($null -ne $localSdio -and [string](Get-DriverAdvisorPathValue $localSdio 'SelectionAssessment.Status' '') -eq 'NotRequiredSameAsActive') {
            $reasons.Add((New-DriverAdvisorReason -Kind Positive -Code 'OemCandidateAlreadyActive' -Text 'Το extracted OEM INF έχει ίδιο matched ID και ίδιο DriverVer με τον active driver.' -Evidence 'SameAsActive'))
            $reasons.Add((New-DriverAdvisorReason -Kind Neutral -Code 'NoNewerLocalSdioCandidate' -Text 'Το local SDIO audit δεν βρήκε νεότερο applicable candidate.' -Evidence "$(Get-DriverAdvisorPathValue $localSdio 'ApplicableCount' 0) candidate(s); 0 newer"))
        }
        elseif ($null -ne $localSdio -and [string](Get-DriverAdvisorPathValue $localSdio 'Outcome' '') -eq 'NoNewerOrBetterCandidate') {
            $reasons.Add((New-DriverAdvisorReason -Kind Neutral -Code 'NoNewerOrBetterSdioCandidate' -Text 'Το fast SDIO check δεν βρήκε best candidate με status NEW ή BETTER.' -Evidence 'Newer + Better match + Show only best'))
        }
    }

    if ($code -eq 'NeedMoreEvidence' -and $legacyVerdict -eq 'KeepCurrent_CatalogCandidateRequiresControlledSelectionProof') {
        $catalogCandidate = $null
        foreach ($package in @(Get-DriverAdvisorPathValue -InputObject $Report -Path 'Sources.CatalogPackage.Packages' -Default @())) {
            foreach ($inf in @(Get-DriverAdvisorPathValue -InputObject $package -Path 'Infs' -Default @())) {
                $targetMatches = @(Get-DriverAdvisorPathValue -InputObject $inf -Path 'TargetMatches' -Default @())
                $dateRelation = [string](Get-DriverAdvisorPathValue -InputObject $inf -Path 'ActiveComparison.DateRelation' -Default '')
                if ($targetMatches.Count -eq 0 -or $dateRelation -ne 'Newer') { continue }
                $match = $targetMatches[0]
                $catalogCandidate = [pscustomobject]@{
                    PublishedInf = ''
                    OriginalInf  = [string](Get-DriverAdvisorPathValue $inf 'Name' 'Unknown INF')
                    DriverVer    = [string](Get-DriverAdvisorPathValue $inf 'DriverVer' 'Unknown')
                    Rank         = [string](Get-DriverAdvisorPathValue $match 'ComputedRankBody' 'Not computed')
                    Status       = 'Computed; Windows selection not observed'
                    MatchKind    = [string](Get-DriverAdvisorPathValue $match 'MatchKind' 'Unknown')
                    MatchedId    = [string](Get-DriverAdvisorPathValue $match 'HardwareId' '')
                    CatalogGuid  = [string](Get-DriverAdvisorPathValue $package 'CatalogGuid' '')
                }
                break
            }
            if ($null -ne $catalogCandidate) { break }
        }
        $candidate = $catalogCandidate
        $code = 'InspectOrStageCandidate'
        $title = 'Διατήρησε τον current driver και έλεγξε τον candidate'
        $summary = 'Υπάρχει promising inspected package, αλλά λείπει observed Windows selection evidence.'
        $recommendedAction = 'StageOnly'
        $confidence = 'Medium'
        $evidenceLevel = 'InspectedPackage'
        $risk = Get-DriverAdvisorActivationRisk -DeviceClass $deviceClass -AlreadyActivated $false
        $reasons.Add((New-DriverAdvisorReason -Kind Caution -Code 'SelectionProofMissing' -Text 'Το computed rank δεν αντικαθιστά observed Windows selection.' -Evidence 'Package inspection only'))
        if ($null -ne $catalogCandidate) {
            $reasons.Add((New-DriverAdvisorReason -Kind Positive -Code 'SignedExactCatalogPackage' -Text 'Το inspected Catalog package έχει νεότερο exact-match INF candidate.' -Evidence "$($catalogCandidate.OriginalInf); $($catalogCandidate.DriverVer)"))
        }
    }

    if ($code -eq 'NeedMoreEvidence' -and $oemOutcome -eq 'ObservedOutrankedCandidate') {
        $code = 'SkipTestedOemCandidate'
        $title = 'Παράλειψε τον tested OEM candidate'
        $summary = 'Το local Windows selection απέδειξε ότι ο candidate του συγκεκριμένου installer έχασε από τον current driver.'
        $recommendedAction = 'KeepCurrent'
        $confidence = 'High'
        $evidenceLevel = 'ObservedSelection'
        $risk = 'Low'
        $candidate = @(Get-DriverAdvisorPathValue -InputObject $Report -Path 'Sources.OEMTrace.TargetPreviewMatches' -Default @()) | Select-Object -First 1
        $reasons.Add((New-DriverAdvisorReason -Kind Positive -Code 'CurrentOutrankedOemCandidate' -Text 'Το SetupAPI/pnputil evidence έδειξε τον tested OEM candidate ως Outranked.' -Evidence $oemOutcome))
    }
    elseif ($code -eq 'NeedMoreEvidence' -and $oemOutcome -eq 'ObservedAppliedExtension') {
        $extensionNode = @(Get-DriverAdvisorPathValue -InputObject $Report -Path 'Sources.OEMTrace.TargetPackageNodes' -Default @() | Where-Object NodeKind -eq 'Extension' | Select-Object -First 1)
        $node = if ($extensionNode.Count -gt 0) { $extensionNode[0] } else { $null }
        $candidate = if ($null -ne $node) {
            [pscustomobject]@{
                PublishedInf = [string]$node.PublishedName
                OriginalInf  = [string]$node.OriginalName
                DriverVer    = "$($node.DriverDate) / $($node.DriverVersion)"
                Rank         = [string]$node.DriverRank
                Status       = [string]$node.Status
                MatchKind    = 'Extension INF'
                MatchedId    = [string]$node.ExtensionId
            }
        } else { $null }
        $code = 'KeepAppliedExtensionStack'
        $title = 'Διατήρησε το applied Extension stack'
        $summary = 'Το package Extension INF επιλέχθηκε και εγκαταστάθηκε δίπλα στον base function driver· δεν είναι απλή αντικατάσταση base driver.'
        $recommendedAction = 'KeepCurrent'
        $confidence = 'High'
        $evidenceLevel = 'ObservedExtensionActivation'
        $risk = 'Low'
        $reasons.Add((New-DriverAdvisorReason -Kind Positive -Code 'ExtensionSelectedInstalled' -Text 'Το SetupAPI έδειξε το package Extension INF ως Selected / Installed.' -Evidence $oemOutcome))
        $reasons.Add((New-DriverAdvisorReason -Kind Neutral -Code 'BaseDriverSeparate' -Text 'Ο base/function driver και το Extension INF αποτελούν ξεχωριστά μέρη του active stack.' -Evidence 'Extension model'))
    }
    elseif ($code -eq 'NeedMoreEvidence' -and $oemOutcome -eq 'ObservedSelectedPackageCandidate') {
        $selectedNode = @(Get-DriverAdvisorPathValue -InputObject $Report -Path 'Sources.OEMTrace.TargetPackageNodes' -Default @() | Where-Object NodeKind -eq 'Driver' | Select-Object -First 1)
        $activeInf = [string](Get-DriverAdvisorPathValue $Report 'Active.ActiveDriver.PublishedInf' '')
        if ($selectedNode.Count -gt 0 -and [string]$selectedNode[0].PublishedName -eq $activeInf) {
            $node = $selectedNode[0]
            $candidate = [pscustomobject]@{ PublishedInf=[string]$node.PublishedName; OriginalInf=[string]$node.OriginalName; DriverVer="$($node.DriverDate) / $($node.DriverVersion)"; Rank=[string]$node.DriverRank; Status=[string]$node.Status }
            $code = 'KeepObservedSelectedPackageCandidate'
            $title = 'Διατήρησε τον selected package driver'
            $summary = 'Το package driver επιλέχθηκε από τα Windows και παραμένει ο current active driver.'
            $recommendedAction = 'KeepCurrent'
            $confidence = 'High'
            $evidenceLevel = 'ObservedActivation'
            $risk = 'Low'
            $reasons.Add((New-DriverAdvisorReason -Kind Positive -Code 'PackageDriverSelectedActive' -Text 'Το package node είναι Selected / Installed και ταιριάζει με το current active INF.' -Evidence $activeInf))
        }
    }
    elseif ($code -eq 'NeedMoreEvidence' -and $oemOutcome -in @('ObservedPackageMatchPreviewOnly', 'ObservedPackageMatch')) {
        $code = 'InspectMatchedPackageCandidate'
        $title = 'Έλεγξε τον matched package candidate πριν από install'
        $summary = 'Το extracted package ταιριάζει σε present device, αλλά δεν υπάρχει ακόμη authoritative selection/activation proof.'
        $recommendedAction = 'InspectPackage'
        $confidence = 'Medium'
        $evidenceLevel = 'ObservedPackageContent'
        $risk = Get-DriverAdvisorActivationRisk -DeviceClass $deviceClass -AlreadyActivated $false
        $candidate = @(Get-DriverAdvisorPathValue -InputObject $Report -Path 'Sources.OEMTrace.TargetPreviewMatches' -Default @()) | Select-Object -First 1
        $reasons.Add((New-DriverAdvisorReason -Kind Positive -Code 'PackageMatchesPresentDevice' -Text 'Το extracted INF έχει match με present device.' -Evidence $oemOutcome))
        $reasons.Add((New-DriverAdvisorReason -Kind Caution -Code 'PackageSelectionUnknown' -Text 'Package match δεν αποδεικνύει ότι τα Windows θα το επιλέξουν.' -Evidence 'Preview/package evidence'))
    }
    elseif ($code -eq 'NeedMoreEvidence' -and $oemOutcome -eq 'NoTargetMatchObserved') {
        $code = 'IgnorePackageNoPresentTarget'
        $title = 'Το package δεν αφορά present device'
        $summary = 'Δεν παρατηρήθηκε match με τη συγκεκριμένη present συσκευή.'
        $recommendedAction = 'SkipPackage'
        $confidence = 'High'
        $evidenceLevel = 'ObservedPackageContent'
        $risk = 'Low'
    }

    if ($wuMatches -gt 0) {
        $reasons.Add((New-DriverAdvisorReason -Kind Neutral -Code 'CurrentWuOffer' -Text 'Το current WUAPI search επέστρεψε matching driver offer.' -Evidence "$wuMatches offer(s)"))
        if ($code -eq 'NeedMoreEvidence') {
            $code = 'ReviewWindowsUpdateOffer'
            $title = 'Έλεγξε το current Windows Update offer'
            $summary = 'Υπάρχει current applicable offer, αλλά χρειάζεται package-level comparison πριν από recommendation.'
            $recommendedAction = 'InspectWindowsUpdateOffer'
            $confidence = 'Medium'
            $evidenceLevel = 'CurrentWuOffer'
            $risk = 'Moderate'
        }
    }
    elseif ($wuOutcome -eq 'NoCurrentWuOfferObserved') {
        $reasons.Add((New-DriverAdvisorReason -Kind Neutral -Code 'NoCurrentWuOffer' -Text 'Δεν παρατηρήθηκε current WU offer· αυτό δεν ακυρώνει candidates από άλλες πηγές.' -Evidence $wuOutcome))
    }

    if ($catalogRows -gt 0) {
        $reasons.Add((New-DriverAdvisorReason -Kind Neutral -Code 'CatalogDiscoveryRows' -Text 'Υπάρχουν public Catalog rows, αλλά δεν θεωρούνται αυτόματα applicable candidates.' -Evidence "$catalogRows row(s)"))
    }
    if ($oemOutcome -eq 'ObservedOutrankedCandidate' -and $code -ne 'SkipTestedOemCandidate') {
        $reasons.Add((New-DriverAdvisorReason -Kind Caution -Code 'OemCandidateOutranked' -Text 'Το tested OEM package περιείχε candidate που έχασε στο local Windows selection.' -Evidence $oemOutcome))
    }

    $actions.Add([pscustomobject]@{ Code = 'ViewEvidence'; Label = 'Προβολή πλήρους evidence'; MutatesSystem = $false; RequiresElevation = $false })
    switch ($recommendedAction) {
        'ControlledActivation' {
            $actions.Add([pscustomobject]@{ Code = 'ControlledActivation'; Label = 'Controlled activation με checkpoint'; MutatesSystem = $true; RequiresElevation = $true })
        }
        'StageOnly' {
            $actions.Add([pscustomobject]@{ Code = 'StageOnly'; Label = 'Stage-only και παρατήρηση Windows rank'; MutatesSystem = $true; RequiresElevation = $true })
        }
        'InspectWindowsUpdateOffer' {
            $actions.Add([pscustomobject]@{ Code = 'InspectWindowsUpdateOffer'; Label = 'Inspection του WU offer'; MutatesSystem = $false; RequiresElevation = $false })
        }
        'InspectPackage' {
            $actions.Add([pscustomobject]@{ Code = 'InspectPackage'; Label = 'Inspection package/signatures/INF'; MutatesSystem = $false; RequiresElevation = $false })
            $actions.Add([pscustomobject]@{ Code = 'StageOnly'; Label = 'Προαιρετικό stage-only ranking test'; MutatesSystem = $true; RequiresElevation = $true })
        }
    }

    [pscustomobject]@{
        SchemaVersion      = 1
        Code               = $code
        Title              = $title
        Summary            = $summary
        RecommendedAction  = $recommendedAction
        Confidence         = $confidence
        EvidenceLevel      = $evidenceLevel
        Risk               = $risk
        Candidate          = $candidate
        Reasons            = @($reasons)
        Caveats            = @($caveats)
        Actions            = @($actions)
        LegacyVerdict      = $legacyVerdict
        GeneratedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
    }
}
