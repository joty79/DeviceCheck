[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '', Justification = 'Repository policy uses UTF-8 without BOM for PowerShell source.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Windows Terminal hot paths intentionally use single Console.Write frames for flicker-free rendering.')]
param()

Set-StrictMode -Version Latest

function Get-DriverAdvisorTheme {
    param([switch]$PlainText)

    $escape = [char]27
    if ($PlainText) {
        return @{ Reset=''; Bold=''; Dim=''; H1=''; H2=''; OK=''; Warn=''; Fail=''; Info=''; White=''; Selected='' }
    }

    return @{
        Reset    = "$escape[0m"
        Bold     = "$escape[1m"
        Dim      = "$escape[38;2;105;115;125m"
        H1       = "$escape[38;2;90;180;240m"
        H2       = "$escape[38;2;140;160;180m"
        OK       = "$escape[38;2;46;204;113m"
        Warn     = "$escape[38;2;241;196;15m"
        Fail     = "$escape[38;2;231;76;60m"
        Info     = "$escape[38;2;52;152;219m"
        White    = "$escape[38;2;225;230;235m"
        Selected = "$escape[48;2;35;70;105m$escape[38;2;255;255;255m"
    }
}

function Get-DriverAdvisorGlyphMap {
    $asciiValue = [Environment]::GetEnvironmentVariable('POWERSHELL_TUI_ASCII')
    $useAscii = -not [string]::IsNullOrWhiteSpace($asciiValue) -and $asciiValue -notin @('0','false','False','off','Off','no','No')
    if (-not $useAscii) {
        try { $useAscii = [Console]::OutputEncoding.CodePage -ne 65001 } catch { $useAscii = $false }
    }

    if ($useAscii) {
        return @{ H='-'; Heavy='='; Good='[+]'; Warn='[!]'; Bad='[x]'; Info='[i]'; Bullet='*'; Arrow='>'; Up='^'; Down='v' }
    }

    return @{ H=[string][char]0x2500; Heavy=[string][char]0x2550; Good='✅'; Warn='⚠️'; Bad='❌'; Info='ℹ️'; Bullet='•'; Arrow='❯'; Up='↑'; Down='↓' }
}

function ConvertFrom-DriverAdvisorAnsi {
    param([AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    return [regex]::Replace($Text, "`e\[[0-9;?]*[ -/]*[@-~]", '')
}

function Limit-DriverAdvisorText {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width
    )

    if ($Width -le 0) { return '' }
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Width) { return $Text }
    if ($Width -eq 1) { return $Text.Substring(0, 1) }
    return $Text.Substring(0, $Width - 1) + [char]0x2026
}

function Split-DriverAdvisorText {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width
    )

    if ($Width -lt 1) { return @('') }
    if ([string]::IsNullOrEmpty($Text)) { return @('') }

    $lines = [System.Collections.Generic.List[string]]::new()
    $remaining = $Text.TrimEnd()
    while ($remaining.Length -gt $Width) {
        $slice = $remaining.Substring(0, $Width)
        $breakAt = $slice.LastIndexOf(' ')
        if ($breakAt -lt [Math]::Floor($Width * 0.45)) { $breakAt = $Width }
        $lines.Add($remaining.Substring(0, $breakAt).TrimEnd())
        $remaining = $remaining.Substring($breakAt).TrimStart()
    }
    $lines.Add($remaining)
    return @($lines)
}

function Add-DriverAdvisorSectionLine {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Title,
        [int]$Width,
        [hashtable]$Theme,
        [hashtable]$Glyphs
    )

    $prefix = " $Title "
    $rule = $Glyphs.H * [Math]::Max(0, $Width - $prefix.Length)
    $Lines.Add("$($Theme.H1)$prefix$($Theme.Dim)$rule$($Theme.Reset)")
}

function Add-DriverAdvisorWrappedLine {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Text,
        [int]$Width,
        [string]$Prefix = '',
        [string]$ContinuationPrefix = '',
        [string]$Color = '',
        [string]$Reset = ''
    )

    $firstWidth = [Math]::Max(1, $Width - $Prefix.Length)
    $continuation = if ($ContinuationPrefix) { $ContinuationPrefix } else { ' ' * $Prefix.Length }
    $wrapped = @(Split-DriverAdvisorText -Text $Text -Width $firstWidth)
    for ($index = 0; $index -lt $wrapped.Count; $index++) {
        $linePrefix = if ($index -eq 0) { $Prefix } else { $continuation }
        $Lines.Add("$Color$linePrefix$($wrapped[$index])$Reset")
    }
}

function Add-DriverAdvisorKeyValue {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Label,
        [AllowEmptyString()][string]$Value,
        [int]$Width,
        [hashtable]$Theme
    )

    $labelWidth = [Math]::Min(16, [Math]::Max(10, [Math]::Floor($Width * 0.22)))
    $prefix = '  ' + $Label.PadRight($labelWidth) + ': '
    Add-DriverAdvisorWrappedLine -Lines $Lines -Text $Value -Width $Width -Prefix $prefix -ContinuationPrefix (' ' * $prefix.Length) -Color $Theme.White -Reset $Theme.Reset
}

function Get-DriverAdvisorConfidenceLabel {
    param([string]$Value)
    switch ($Value) { 'High' { 'Υψηλή' } 'Medium' { 'Μέτρια' } 'Low' { 'Χαμηλή' } default { 'Ανεπαρκής' } }
}

function Get-DriverAdvisorRiskLabel {
    param([string]$Value)
    switch ($Value) { 'Low' { 'Χαμηλό' } 'Moderate' { 'Μέτριο' } 'High' { 'Υψηλό' } default { 'Άγνωστο' } }
}

function Get-DriverAdvisorReasonStyle {
    param([string]$Kind, [hashtable]$Theme, [hashtable]$Glyphs)
    switch ($Kind) {
        'Positive' { return @{ Icon=$Glyphs.Good; Color=$Theme.OK } }
        'Caution'  { return @{ Icon=$Glyphs.Warn; Color=$Theme.Warn } }
        'Blocking' { return @{ Icon=$Glyphs.Bad; Color=$Theme.Fail } }
        default    { return @{ Icon=$Glyphs.Info; Color=$Theme.Info } }
    }
}

function ConvertTo-DriverAdvisorViewLine {
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)]$Recommendation,
        [ValidateSet('Overview','Sources','Candidates','Evidence','Actions')]
        [string]$View = 'Overview',
        [int]$Width = 100,
        [switch]$PlainText
    )

    $Width = [Math]::Max(52, $Width)
    $theme = Get-DriverAdvisorTheme -PlainText:$PlainText
    $glyphs = Get-DriverAdvisorGlyphMap
    $lines = [System.Collections.Generic.List[string]]::new()
    $selection = Get-DriverAdvisorPathValue -InputObject $Report -Path 'Sources.SelectionExperiment'

    switch ($View) {
        'Overview' {
            Add-DriverAdvisorSectionLine -Lines $lines -Title 'Συσκευή' -Width $Width -Theme $theme -Glyphs $glyphs
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'Name' -Value ([string](Get-DriverAdvisorPathValue $Report 'Target.FriendlyName' 'Unknown')) -Width $Width -Theme $theme
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'Status' -Value ("{0} / problem {1}" -f (Get-DriverAdvisorPathValue $Report 'Target.Status' 'Unknown'), (Get-DriverAdvisorPathValue $Report 'Target.ProblemCode' 'Unknown')) -Width $Width -Theme $theme
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'Instance' -Value ([string](Get-DriverAdvisorPathValue $Report 'Target.InstanceId' '')) -Width $Width -Theme $theme

            $oemTrace = Get-DriverAdvisorPathValue $Report 'Sources.OEMTrace'
            if ($null -ne $oemTrace) {
                $lines.Add('')
                Add-DriverAdvisorSectionLine -Lines $lines -Title 'Package' -Width $Width -Theme $theme -Glyphs $glyphs
                Add-DriverAdvisorKeyValue -Lines $lines -Label 'Installer' -Value ([string](Get-DriverAdvisorPathValue $oemTrace 'InstallerName' 'Unknown')) -Width $Width -Theme $theme
                Add-DriverAdvisorKeyValue -Lines $lines -Label 'Payload' -Value ("{0}; {1} INF" -f (Get-DriverAdvisorPathValue $oemTrace 'PayloadKind' 'Unknown'), (Get-DriverAdvisorPathValue $oemTrace 'InfCount' 0)) -Width $Width -Theme $theme
                Add-DriverAdvisorKeyValue -Lines $lines -Label 'Trace result' -Value ([string](Get-DriverAdvisorPathValue $oemTrace 'Outcome' 'Unknown')) -Width $Width -Theme $theme
            }

            $lines.Add('')
            Add-DriverAdvisorSectionLine -Lines $lines -Title 'Active driver' -Width $Width -Theme $theme -Glyphs $glyphs
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'INF' -Value ([string](Get-DriverAdvisorPathValue $Report 'Active.ActiveDriver.PublishedInf' 'Unknown')) -Width $Width -Theme $theme
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'DriverVer' -Value ("{0} / {1}" -f (Get-DriverAdvisorPathValue $Report 'Active.ActiveDriver.Date' 'Unknown'), (Get-DriverAdvisorPathValue $Report 'Active.ActiveDriver.Version' 'Unknown')) -Width $Width -Theme $theme
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'Provider' -Value ([string](Get-DriverAdvisorPathValue $Report 'Active.ActiveDriver.Provider' 'Unknown')) -Width $Width -Theme $theme

            if ($null -ne $Recommendation.Candidate) {
                $lines.Add('')
                Add-DriverAdvisorSectionLine -Lines $lines -Title 'Candidate' -Width $Width -Theme $theme -Glyphs $glyphs
                $candidateInf = [string](Get-DriverAdvisorPathValue $Recommendation.Candidate 'PublishedInf' '')
                $candidateOriginal = [string](Get-DriverAdvisorPathValue $Recommendation.Candidate 'OriginalInf' '')
                if (-not $candidateInf -and $candidateOriginal) { $candidateInf = $candidateOriginal; $candidateOriginal = '' }
                if (-not $candidateInf) { $candidateInf = [string](Get-DriverAdvisorPathValue $Recommendation.Candidate 'Inf' 'Unknown') }
                if ($candidateOriginal) { $candidateInf = "$candidateInf / $candidateOriginal" }
                Add-DriverAdvisorKeyValue -Lines $lines -Label 'INF' -Value $candidateInf -Width $Width -Theme $theme
                Add-DriverAdvisorKeyValue -Lines $lines -Label 'DriverVer' -Value ([string](Get-DriverAdvisorPathValue $Recommendation.Candidate 'DriverVer' 'Unknown')) -Width $Width -Theme $theme
                $candidateMatch = [string](Get-DriverAdvisorPathValue $Recommendation.Candidate 'MatchKind' '')
                $candidateMatchedId = [string](Get-DriverAdvisorPathValue $Recommendation.Candidate 'MatchedId' '')
                if ($candidateMatch -or $candidateMatchedId) {
                    Add-DriverAdvisorKeyValue -Lines $lines -Label 'Match' -Value ("$candidateMatch $candidateMatchedId".Trim()) -Width $Width -Theme $theme
                }
                $candidateRank = [string](Get-DriverAdvisorPathValue $Recommendation.Candidate 'Rank' '')
                $candidateStatus = [string](Get-DriverAdvisorPathValue $Recommendation.Candidate 'Status' '')
                if ($candidateRank -or $candidateStatus) {
                    Add-DriverAdvisorKeyValue -Lines $lines -Label 'Windows' -Value ("rank $candidateRank; $candidateStatus".Trim('; ')) -Width $Width -Theme $theme
                }
            }

            $lines.Add('')
            Add-DriverAdvisorSectionLine -Lines $lines -Title 'Recommendation' -Width $Width -Theme $theme -Glyphs $glyphs
            $recommendationColor = if ($Recommendation.Risk -eq 'High') { $theme.Warn } elseif ($Recommendation.Code -eq 'DiagnoseDeviceFirst') { $theme.Fail } else { $theme.OK }
            Add-DriverAdvisorWrappedLine -Lines $lines -Text $Recommendation.Title -Width $Width -Prefix "  $($glyphs.Arrow) " -Color "$recommendationColor$($theme.Bold)" -Reset $theme.Reset
            Add-DriverAdvisorWrappedLine -Lines $lines -Text $Recommendation.Summary -Width $Width -Prefix '    ' -Color $theme.White -Reset $theme.Reset
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'Confidence' -Value (Get-DriverAdvisorConfidenceLabel $Recommendation.Confidence) -Width $Width -Theme $theme
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'Activation risk' -Value (Get-DriverAdvisorRiskLabel $Recommendation.Risk) -Width $Width -Theme $theme
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'Next action' -Value ([string]$Recommendation.RecommendedAction) -Width $Width -Theme $theme

            $lines.Add('')
            Add-DriverAdvisorSectionLine -Lines $lines -Title 'Γιατί' -Width $Width -Theme $theme -Glyphs $glyphs
            foreach ($reason in @($Recommendation.Reasons)) {
                $style = Get-DriverAdvisorReasonStyle -Kind $reason.Kind -Theme $theme -Glyphs $glyphs
                Add-DriverAdvisorWrappedLine -Lines $lines -Text ([string]$reason.Text) -Width $Width -Prefix "  $($style.Icon) " -Color $style.Color -Reset $theme.Reset
            }
            if (@($Recommendation.Caveats).Count -gt 0) {
                $lines.Add('')
                Add-DriverAdvisorSectionLine -Lines $lines -Title 'Εκκρεμεί' -Width $Width -Theme $theme -Glyphs $glyphs
                foreach ($caveat in @($Recommendation.Caveats)) {
                    Add-DriverAdvisorWrappedLine -Lines $lines -Text ([string]$caveat) -Width $Width -Prefix "  $($glyphs.Warn) " -Color $theme.Warn -Reset $theme.Reset
                }
            }
        }
        'Sources' {
            Add-DriverAdvisorSectionLine -Lines $lines -Title 'Evidence sources' -Width $Width -Theme $theme -Glyphs $glyphs
            $wu = Get-DriverAdvisorPathValue $Report 'Sources.WindowsUpdate'
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'Windows Update' -Value $(if ($null -eq $wu) { 'Δεν έγινε query' } else { "$(Get-DriverAdvisorPathValue $wu 'Outcome' 'Unknown'); matches $(Get-DriverAdvisorPathValue $wu 'MatchingOfferCount' 0)" }) -Width $Width -Theme $theme
            $catalog = Get-DriverAdvisorPathValue $Report 'Sources.CatalogPublic'
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'Catalog' -Value $(if ($null -eq $catalog) { 'Δεν έγινε query' } else { "$(Get-DriverAdvisorPathValue $catalog 'TotalRowCount' 0) public rows; discovery only" }) -Width $Width -Theme $theme
            $package = Get-DriverAdvisorPathValue $Report 'Sources.CatalogPackage'
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'CAB inspection' -Value $(if ($null -eq $package) { 'Δεν δόθηκε' } else { "$(@(Get-DriverAdvisorPathValue $package 'Packages' @()).Count) package(s); guard unchanged $(Get-DriverAdvisorPathValue $package 'MutationGuard.Unchanged' 'Unknown')" }) -Width $Width -Theme $theme
            $oem = Get-DriverAdvisorPathValue $Report 'Sources.OEMTrace'
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'OEM trace' -Value $(if ($null -eq $oem) { 'Δεν δόθηκε' } else { "$(Get-DriverAdvisorPathValue $oem 'Outcome' 'Unknown'); $(Get-DriverAdvisorPathValue $oem 'InstallerName' '')" }) -Width $Width -Theme $theme
            $sdio = Get-DriverAdvisorPathValue $Report 'Sources.SDIO'
            $sdioComparison = if ($null -ne $sdio) { Get-DriverAdvisorPathValue $sdio 'LocalComparison' } else { $null }
            $sdioText = if ($null -eq $sdio) {
                'Δεν έγινε local audit'
            }
            elseif ($null -ne $sdioComparison) {
                "$(Get-DriverAdvisorPathValue $sdioComparison 'Outcome' 'Unknown'); $(Get-DriverAdvisorPathValue $sdioComparison 'ApplicableCount' 0) available; $(Get-DriverAdvisorPathValue $sdioComparison 'NewerThanActiveCount' 0) newer; $(Get-DriverAdvisorPathValue $sdioComparison 'IndexOnlyCount' 0) index-only"
            }
            else {
                "$(Get-DriverAdvisorPathValue $sdio 'MatchedDeviceCount' 0) matched device(s); $(@(Get-DriverAdvisorPathValue $sdio 'ParserWarnings' @()).Count) warning(s)"
            }
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'SDIO' -Value $sdioText -Width $Width -Theme $theme
            $selectionText = if ($null -ne $selection) {
                "$(Get-DriverAdvisorPathValue $selection 'Mode' 'Unknown'); $(Get-DriverAdvisorPathValue $selection 'Outcome' 'Not recorded')"
            }
            elseif ($null -ne $sdioComparison) {
                [string](Get-DriverAdvisorPathValue $sdioComparison 'SelectionAssessment.Display' 'Not run')
            }
            else { 'Δεν έγινε selection test' }
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'Selection' -Value $selectionText -Width $Width -Theme $theme

            $benchmark = Get-DriverAdvisorPathValue $Report 'Benchmark'
            if ($null -ne $benchmark) {
                Add-DriverAdvisorKeyValue -Lines $lines -Label 'Benchmark' -Value ("$(Get-DriverAdvisorPathValue $benchmark 'TotalSeconds' 0) s total; slowest $(Get-DriverAdvisorPathValue $benchmark 'SlowestPhase' 'Unknown') ($(Get-DriverAdvisorPathValue $benchmark 'SlowestMs' 0) ms)") -Width $Width -Theme $theme
            }

            $lines.Add('')
            Add-DriverAdvisorSectionLine -Lines $lines -Title 'Evidence boundary' -Width $Width -Theme $theme -Glyphs $glyphs
            Add-DriverAdvisorWrappedLine -Lines $lines -Text 'Catalog rows είναι discovery evidence. SDIO status δεν μετατρέπεται σε Windows rank. Μόνο pnputil/SetupAPI selection evidence αποδεικνύει local Windows ranking.' -Width $Width -Prefix "  $($glyphs.Info) " -Color $theme.Info -Reset $theme.Reset
        }
        'Candidates' {
            Add-DriverAdvisorSectionLine -Lines $lines -Title 'Observed candidates' -Width $Width -Theme $theme -Glyphs $glyphs
            $localSdio = Get-DriverAdvisorPathValue $Report 'Sources.SDIO.LocalComparison'
            if ($null -ne $localSdio) {
                Add-DriverAdvisorWrappedLine -Lines $lines -Text 'Active Windows driver' -Width $Width -Prefix "  $($glyphs.Good) " -Color "$($theme.OK)$($theme.Bold)" -Reset $theme.Reset
                Add-DriverAdvisorKeyValue -Lines $lines -Label 'INF' -Value ([string](Get-DriverAdvisorPathValue $Report 'Active.ActiveDriver.PublishedInf' 'Unknown')) -Width $Width -Theme $theme
                Add-DriverAdvisorKeyValue -Lines $lines -Label 'DriverVer' -Value ("$(Get-DriverAdvisorPathValue $Report 'Active.ActiveDriver.Date' '') / $(Get-DriverAdvisorPathValue $Report 'Active.ActiveDriver.Version' '')") -Width $Width -Theme $theme
                $lines.Add('')
                foreach ($oemCandidate in @(Get-DriverAdvisorPathValue $localSdio 'OemCandidates' @())) {
                    Add-DriverAdvisorWrappedLine -Lines $lines -Text 'Extracted OEM candidate' -Width $Width -Prefix "  $($glyphs.Arrow) " -Color "$($theme.Info)$($theme.Bold)" -Reset $theme.Reset
                    Add-DriverAdvisorKeyValue -Lines $lines -Label 'INF' -Value ([string](Get-DriverAdvisorPathValue $oemCandidate 'Inf' 'Unknown')) -Width $Width -Theme $theme
                    Add-DriverAdvisorKeyValue -Lines $lines -Label 'DriverVer' -Value ([string](Get-DriverAdvisorPathValue $oemCandidate 'DriverVer' 'Unknown')) -Width $Width -Theme $theme
                    Add-DriverAdvisorKeyValue -Lines $lines -Label 'vs active' -Value ([string](Get-DriverAdvisorPathValue $oemCandidate 'ActiveRelation' 'Unknown')) -Width $Width -Theme $theme
                    $lines.Add('')
                }
                foreach ($sdioCandidate in @(Get-DriverAdvisorPathValue $localSdio 'Candidates' @() | Select-Object -First 12)) {
                    Add-DriverAdvisorWrappedLine -Lines $lines -Text ([string](Get-DriverAdvisorPathValue $sdioCandidate 'PackName' 'Local SDIO candidate')) -Width $Width -Prefix "  $($glyphs.Bullet) " -Color $theme.White -Reset $theme.Reset
                    Add-DriverAdvisorKeyValue -Lines $lines -Label 'INF' -Value ([string](Get-DriverAdvisorPathValue $sdioCandidate 'InfFile' 'Unknown')) -Width $Width -Theme $theme
                    Add-DriverAdvisorKeyValue -Lines $lines -Label 'DriverVer' -Value ([string](Get-DriverAdvisorPathValue $sdioCandidate 'DriverVer' 'Unknown')) -Width $Width -Theme $theme
                    Add-DriverAdvisorKeyValue -Lines $lines -Label 'SDIO status' -Value ([string](Get-DriverAdvisorPathValue $sdioCandidate 'SdioStatus' 'Unknown')) -Width $Width -Theme $theme
                    Add-DriverAdvisorKeyValue -Lines $lines -Label 'vs active' -Value ([string](Get-DriverAdvisorPathValue $sdioCandidate 'ActiveRelation' 'Unknown')) -Width $Width -Theme $theme
                    $lines.Add('')
                }
            }
            $candidates = @($(if ($null -ne $selection) { $selection.Candidates } elseif ($null -eq $localSdio -and $null -ne $Recommendation.Candidate) { $Recommendation.Candidate }))
            if ($candidates.Count -eq 0) {
                if ($null -eq $localSdio) { Add-DriverAdvisorWrappedLine -Lines $lines -Text 'Δεν υπάρχει normalized observed candidate list σε αυτό το report.' -Width $Width -Prefix '  ' -Color $theme.Dim -Reset $theme.Reset }
            }
            else {
                foreach ($candidate in $candidates) {
                    $candidateStatus = [string](Get-DriverAdvisorPathValue $candidate 'Status' 'Not observed')
                    $statusColor = if ($candidateStatus -like 'Best Ranked*') { $theme.OK } elseif ($candidateStatus -like '*Outranked*') { $theme.Dim } else { $theme.White }
                    $candidateInf = [string](Get-DriverAdvisorPathValue $candidate 'PublishedInf' '')
                    $candidateOriginal = [string](Get-DriverAdvisorPathValue $candidate 'OriginalInf' '')
                    if (-not $candidateInf -and $candidateOriginal) { $candidateInf = $candidateOriginal; $candidateOriginal = '' }
                    if (-not $candidateInf) { $candidateInf = [string](Get-DriverAdvisorPathValue $candidate 'Inf' 'Unknown INF') }
                    $candidateLabel = if ($candidateOriginal) { "$candidateInf / $candidateOriginal" } else { $candidateInf }
                    Add-DriverAdvisorWrappedLine -Lines $lines -Text $candidateLabel -Width $Width -Prefix "  $($glyphs.Arrow) " -Color "$statusColor$($theme.Bold)" -Reset $theme.Reset
                    Add-DriverAdvisorKeyValue -Lines $lines -Label 'DriverVer' -Value ([string](Get-DriverAdvisorPathValue $candidate 'DriverVer' 'Unknown')) -Width $Width -Theme $theme
                    Add-DriverAdvisorKeyValue -Lines $lines -Label 'Rank' -Value ([string](Get-DriverAdvisorPathValue $candidate 'Rank' 'Not observed')) -Width $Width -Theme $theme
                    Add-DriverAdvisorKeyValue -Lines $lines -Label 'Windows status' -Value $candidateStatus -Width $Width -Theme $theme
                    $lines.Add('')
                }
            }
        }
        'Evidence' {
            Add-DriverAdvisorSectionLine -Lines $lines -Title 'Interpretation' -Width $Width -Theme $theme -Glyphs $glyphs
            foreach ($observation in @((Get-DriverAdvisorPathValue $Report 'Observations' @()))) {
                Add-DriverAdvisorWrappedLine -Lines $lines -Text ([string]$observation) -Width $Width -Prefix "  $($glyphs.Bullet) " -Color $theme.White -Reset $theme.Reset
            }
            $lines.Add('')
            Add-DriverAdvisorSectionLine -Lines $lines -Title 'Windows verdict' -Width $Width -Theme $theme -Glyphs $glyphs
            Add-DriverAdvisorKeyValue -Lines $lines -Label 'Verdict' -Value ([string](Get-DriverAdvisorPathValue $Report 'OverallVerdict' 'Unknown')) -Width $Width -Theme $theme
            Add-DriverAdvisorWrappedLine -Lines $lines -Text ([string](Get-DriverAdvisorPathValue $Report 'NextGate' '')) -Width $Width -Prefix '  ' -Color $theme.Warn -Reset $theme.Reset
            $reportPath = [string](Get-DriverAdvisorPathValue $Report 'AdvisorReportPath' '')
            if ($reportPath) { Add-DriverAdvisorKeyValue -Lines $lines -Label 'Report' -Value $reportPath -Width $Width -Theme $theme }
        }
        'Actions' {
            Add-DriverAdvisorSectionLine -Lines $lines -Title 'Available actions' -Width $Width -Theme $theme -Glyphs $glyphs
            foreach ($action in @($Recommendation.Actions)) {
                $icon = if ($action.MutatesSystem) { $glyphs.Warn } else { $glyphs.Good }
                $color = if ($action.MutatesSystem) { $theme.Warn } else { $theme.OK }
                Add-DriverAdvisorWrappedLine -Lines $lines -Text ([string]$action.Label) -Width $Width -Prefix "  $icon " -Color $color -Reset $theme.Reset
                Add-DriverAdvisorKeyValue -Lines $lines -Label 'Mutation' -Value ([string]$action.MutatesSystem) -Width $Width -Theme $theme
                Add-DriverAdvisorKeyValue -Lines $lines -Label 'Elevation' -Value ([string]$action.RequiresElevation) -Width $Width -Theme $theme
                $lines.Add('')
            }
            Add-DriverAdvisorWrappedLine -Lines $lines -Text 'Η πρώτη UI έκδοση εμφανίζει actions αλλά δεν εκτελεί mutation. Stage/install wiring παραμένει ξεχωριστό safety gate.' -Width $Width -Prefix "  $($glyphs.Info) " -Color $theme.Info -Reset $theme.Reset
        }
    }

    return @($lines)
}

function ConvertTo-DriverAdvisorInteractiveFrameText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$Escape = [string][char]27
    )

    $eraseToEndOfLine = "$Escape[K"
    $rows = @($Text -split '\r?\n')
    return (@($rows | ForEach-Object { "$_$eraseToEndOfLine" }) -join [Environment]::NewLine)
}

function New-DriverAdvisorFrame {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory terminal frame and does not change system state.')]
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)]$Recommendation,
        [string]$View,
        [int]$Width,
        [int]$Height,
        [int]$ScrollOffset = 0,
        [switch]$PlainText
    )

    $Width = [Math]::Max(52, $Width)
    $Height = [Math]::Max(14, $Height)
    $theme = Get-DriverAdvisorTheme -PlainText:$PlainText
    $glyphs = Get-DriverAdvisorGlyphMap
    $views = @('Overview','Sources','Candidates','Evidence','Actions')
    $content = @(ConvertTo-DriverAdvisorViewLine -Report $Report -Recommendation $Recommendation -View $View -Width $Width -PlainText:$PlainText)

    $header = [System.Collections.Generic.List[string]]::new()
    $header.Add("$($theme.H1)$($glyphs.Heavy * $Width)$($theme.Reset)")
    $title = Limit-DriverAdvisorText -Text 'DeviceCheck Driver Package Advisor' -Width ($Width - 2)
    $header.Add("$($theme.Bold)$($theme.White) $title$($theme.Reset)")
    $device = Limit-DriverAdvisorText -Text ([string](Get-DriverAdvisorPathValue $Report 'Target.FriendlyName' 'Unknown device')) -Width ($Width - 2)
    $header.Add("$($theme.Dim) $device$($theme.Reset)")
    $tabs = @($views | ForEach-Object { if ($_ -eq $View) { "[$_]" } else { " $_ " } }) -join ' '
    $header.Add("$($theme.Info)$(Limit-DriverAdvisorText -Text $tabs -Width $Width)$($theme.Reset)")
    $header.Add("$($theme.Dim)$($glyphs.H * $Width)$($theme.Reset)")

    $footerHeight = 3
    $bodyHeight = [Math]::Max(1, $Height - $header.Count - $footerHeight)
    $maxScroll = [Math]::Max(0, $content.Count - $bodyHeight)
    $ScrollOffset = [Math]::Max(0, [Math]::Min($ScrollOffset, $maxScroll))

    $frame = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $header) { $frame.Add($line) }
    for ($row = 0; $row -lt $bodyHeight; $row++) {
        $index = $ScrollOffset + $row
        if ($index -lt $content.Count) { $frame.Add($content[$index]) } else { $frame.Add('') }
    }
    $frame.Add("$($theme.Dim)$($glyphs.H * $Width)$($theme.Reset)")
    $position = if ($maxScroll -gt 0) { "Lines $($ScrollOffset + 1)-$([Math]::Min($ScrollOffset + $bodyHeight, $content.Count))/$($content.Count)" } else { "$($content.Count) lines" }
    $frame.Add("$($theme.Dim) $($glyphs.Up)$($glyphs.Down) scroll   $($theme.White)←→$($theme.Dim) view   $($theme.Fail)Esc$($theme.Dim) exit   $position$($theme.Reset)")
    $frame.Add("$($theme.H1)$($glyphs.Heavy * $Width)$($theme.Reset)")

    [pscustomobject]@{
        Text         = ($frame -join [Environment]::NewLine)
        MaxScroll    = $maxScroll
        ScrollOffset = $ScrollOffset
        LineCount    = $frame.Count
        Width        = $Width
        Height       = $Height
    }
}

function ConvertTo-DriverAdvisorSnapshot {
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)]$Recommendation,
        [ValidateSet('Overview','Sources','Candidates','Evidence','Actions')][string]$View = 'Overview',
        [int]$Width = 100,
        [switch]$PlainText
    )

    $Width = [Math]::Max(52, $Width)
    $theme = Get-DriverAdvisorTheme -PlainText:$PlainText
    $glyphs = Get-DriverAdvisorGlyphMap
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("$($theme.H1)$($glyphs.Heavy * $Width)$($theme.Reset)")
    $lines.Add("$($theme.Bold)$($theme.White) DeviceCheck Driver Package Advisor$($theme.Reset)")
    $device = Limit-DriverAdvisorText -Text ([string](Get-DriverAdvisorPathValue $Report 'Target.FriendlyName' 'Unknown device')) -Width ($Width - 2)
    $lines.Add("$($theme.Dim) $device / $View$($theme.Reset)")
    $lines.Add("$($theme.H1)$($glyphs.Heavy * $Width)$($theme.Reset)")
    foreach ($line in @(ConvertTo-DriverAdvisorViewLine -Report $Report -Recommendation $Recommendation -View $View -Width $Width -PlainText:$PlainText)) {
        $lines.Add($line)
    }
    $lines.Add("$($theme.H1)$($glyphs.Heavy * $Width)$($theme.Reset)")
    return ($lines -join [Environment]::NewLine)
}

function Show-DriverAdvisorTui {
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)]$Recommendation,
        [string]$InitialView = 'Overview'
    )

    $escape = [char]27
    $views = @('Overview','Sources','Candidates','Evidence','Actions')
    $viewIndex = [Math]::Max(0, [Array]::IndexOf($views, $InitialView))
    $scroll = 0
    $lastWidth = 0
    $lastHeight = 0
    $alternate = [Environment]::GetEnvironmentVariable('POWERSHELL_TUI_PRIMARY_BUFFER') -notin @('1','true','True','on','On')

    try {
        $prefix = if ($alternate) { "$escape[?1049h" } else { '' }
        [Console]::Write("$prefix$escape[?7l$escape[?25l$escape[3J$escape[2J$escape[H")
        while ($true) {
            try {
                $window = $Host.UI.RawUI.WindowSize
                $width = [Math]::Max(52, $window.Width - 1)
                $height = [Math]::Max(14, $window.Height)
                if ($Host.UI.RawUI.BufferSize -ne $window) { $Host.UI.RawUI.BufferSize = $window }
            }
            catch {
                $width = 100
                $height = 32
            }

            $forceClear = $width -ne $lastWidth -or $height -ne $lastHeight
            if ($forceClear) { $scroll = 0; $lastWidth = $width; $lastHeight = $height }
            $frame = New-DriverAdvisorFrame -Report $Report -Recommendation $Recommendation -View $views[$viewIndex] -Width $width -Height $height -ScrollOffset $scroll
            $scroll = $frame.ScrollOffset

            $clear = if ($forceClear) { "$escape[3J$escape[2J$escape[H" } else { "$escape[H" }
            $interactiveFrame = ConvertTo-DriverAdvisorInteractiveFrameText -Text $frame.Text -Escape $escape
            [Console]::Write("$escape[?2026h$clear$interactiveFrame$escape[J$escape[?2026l")

            while (-not [Console]::KeyAvailable) {
                Start-Sleep -Milliseconds 10
                try {
                    $current = $Host.UI.RawUI.WindowSize
                    if ($current.Width -ne ($lastWidth + 1) -or $current.Height -ne $lastHeight) { break }
                }
                catch { Write-Debug "Resize polling unavailable: $($_.Exception.Message)" }
            }
            if (-not [Console]::KeyAvailable) { continue }
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'LeftArrow'  { $viewIndex = if ($viewIndex -eq 0) { $views.Count - 1 } else { $viewIndex - 1 }; $scroll = 0 }
                'RightArrow' { $viewIndex = ($viewIndex + 1) % $views.Count; $scroll = 0 }
                'UpArrow'    { $scroll = [Math]::Max(0, $scroll - 1) }
                'DownArrow'  { $scroll = [Math]::Min($frame.MaxScroll, $scroll + 1) }
                'PageUp'     { $scroll = [Math]::Max(0, $scroll - [Math]::Max(1, $height - 10)) }
                'PageDown'   { $scroll = [Math]::Min($frame.MaxScroll, $scroll + [Math]::Max(1, $height - 10)) }
                'Home'       { $scroll = 0 }
                'End'        { $scroll = $frame.MaxScroll }
                'Escape'     { return }
            }
        }
    }
    finally {
        $suffix = if ($alternate) { "$escape[?1049l" } else { '' }
        try { [Console]::Write("$escape[?7h$escape[?25h$suffix") } catch { Write-Debug "Terminal restore sequence failed: $($_.Exception.Message)" }
        try { [Console]::CursorVisible = $true } catch { Write-Debug "Cursor restore failed: $($_.Exception.Message)" }
    }
}

function Select-DriverAdvisorItem {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,
        [string]$Subtitle = '↑↓ navigate   Enter select   Esc cancel'
    )

    if ($Items.Count -eq 0) { return $null }
    $escape = [char]27
    $theme = Get-DriverAdvisorTheme
    $glyphs = Get-DriverAdvisorGlyphMap
    $selected = 0
    $lastWidth = 0
    $lastHeight = 0
    $alternate = [Environment]::GetEnvironmentVariable('POWERSHELL_TUI_PRIMARY_BUFFER') -notin @('1','true','True','on','On')

    try {
        $prefix = if ($alternate) { "$escape[?1049h" } else { '' }
        [Console]::Write("$prefix$escape[?7l$escape[?25l$escape[3J$escape[2J$escape[H")
        while ($true) {
            try {
                $window = $Host.UI.RawUI.WindowSize
                $width = [Math]::Max(52, $window.Width - 1)
                $height = [Math]::Max(14, $window.Height)
                if ($Host.UI.RawUI.BufferSize -ne $window) { $Host.UI.RawUI.BufferSize = $window }
            }
            catch {
                $width = 100
                $height = 28
            }

            $forceClear = $width -ne $lastWidth -or $height -ne $lastHeight
            $lastWidth = $width
            $lastHeight = $height
            $maxVisible = [Math]::Max(3, $height - 8)
            $viewTop = [Math]::Max(0, [Math]::Min($selected - [Math]::Floor($maxVisible / 2), [Math]::Max(0, $Items.Count - $maxVisible)))
            $viewBottom = [Math]::Min($Items.Count - 1, $viewTop + $maxVisible - 1)

            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add("$($theme.H1)$($glyphs.Heavy * $width)$($theme.Reset)")
            $lines.Add("$($theme.Bold)$($theme.White) $(Limit-DriverAdvisorText $Title ($width - 2))$($theme.Reset)")
            $lines.Add("$($theme.Dim) $(Limit-DriverAdvisorText $Subtitle ($width - 2))$($theme.Reset)")
            $lines.Add("$($theme.H1)$($glyphs.Heavy * $width)$($theme.Reset)")
            if ($viewTop -gt 0) { $lines.Add("$($theme.Dim)  $($glyphs.Up) $viewTop more above$($theme.Reset)") }
            else { $lines.Add('') }

            for ($index = $viewTop; $index -le $viewBottom; $index++) {
                $number = if ($index -lt 9) { "[$($index + 1)]" } else { '   ' }
                $label = Limit-DriverAdvisorText -Text ([string]$Items[$index].Label) -Width ($width - 9)
                if ($index -eq $selected) {
                    $lines.Add("$($theme.Selected)  $($glyphs.Arrow) $number $label $($theme.Reset)")
                }
                else {
                    $lines.Add("$($theme.White)    $number $label$($theme.Reset)")
                }
            }

            while ($lines.Count -lt ($height - 3)) { $lines.Add('') }
            $below = $Items.Count - 1 - $viewBottom
            $lines.Add($(if ($below -gt 0) { "$($theme.Dim)  $($glyphs.Down) $below more below$($theme.Reset)" } else { '' }))
            $lines.Add("$($theme.Dim)  $Subtitle$($theme.Reset)")
            $lines.Add("$($theme.H1)$($glyphs.Heavy * $width)$($theme.Reset)")
            if ($lines.Count -gt $height) { $lines = [System.Collections.Generic.List[string]]::new(@($lines | Select-Object -First $height)) }

            $clear = if ($forceClear) { "$escape[3J$escape[2J$escape[H" } else { "$escape[H" }
            $interactiveFrame = ConvertTo-DriverAdvisorInteractiveFrameText -Text ($lines -join [Environment]::NewLine) -Escape $escape
            [Console]::Write("$escape[?2026h$clear$interactiveFrame$escape[J$escape[?2026l")

            while (-not [Console]::KeyAvailable) {
                Start-Sleep -Milliseconds 10
                try {
                    $current = $Host.UI.RawUI.WindowSize
                    if ($current.Width -ne ($lastWidth + 1) -or $current.Height -ne $lastHeight) { break }
                }
                catch { Write-Debug "Selector resize polling unavailable: $($_.Exception.Message)" }
            }
            if (-not [Console]::KeyAvailable) { continue }
            $key = [Console]::ReadKey($true)
            if ($key.KeyChar -ge '1' -and $key.KeyChar -le '9') {
                $numberIndex = [int][string]$key.KeyChar - 1
                if ($numberIndex -lt $Items.Count) { return $Items[$numberIndex].Value }
            }
            switch ($key.Key) {
                'UpArrow'   { if ($selected -gt 0) { $selected-- } }
                'DownArrow' { if ($selected -lt ($Items.Count - 1)) { $selected++ } }
                'PageUp'    { $selected = [Math]::Max(0, $selected - $maxVisible) }
                'PageDown'  { $selected = [Math]::Min($Items.Count - 1, $selected + $maxVisible) }
                'Home'      { $selected = 0 }
                'End'       { $selected = $Items.Count - 1 }
                'Enter'     { return $Items[$selected].Value }
                'Escape'    { return $null }
            }
        }
    }
    finally {
        $suffix = if ($alternate) { "$escape[?1049l" } else { '' }
        try { [Console]::Write("$escape[?7h$escape[?25h$suffix") } catch { Write-Debug "Selector terminal restore failed: $($_.Exception.Message)" }
        try { [Console]::CursorVisible = $true } catch { Write-Debug "Selector cursor restore failed: $($_.Exception.Message)" }
    }
}
