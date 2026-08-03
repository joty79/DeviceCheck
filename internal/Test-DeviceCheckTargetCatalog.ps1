#requires -version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path $repoRoot '.assets\WinRMDiscovery\WinRMDiscovery.psd1'
$entryPoint = Join-Path $repoRoot 'DeviceCheck.ps1'
$connectionSourcePath = Join-Path $PSScriptRoot 'DeviceCheck\06-RemoteConnection.ps1'
$catalogAdapterPath = Join-Path $PSScriptRoot 'DeviceCheck\06-RemoteTargetCatalog.ps1'

function Assert-TargetCatalogTest {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

Test-ModuleManifest -Path $manifest -ErrorAction Stop | Out-Null
Import-Module $manifest -Force -ErrorAction Stop
foreach ($commandName in @('Get-WinRMTargetCatalog', 'Get-WinRMDiscoverySnapshot', 'Save-WinRMDiscoverySnapshot', 'Resolve-WinRMHistoryTargetAddress')) {
    Assert-TargetCatalogTest -Condition ($null -ne (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) -Message "Missing canonical catalog command: $commandName"
}

$tokens = $null
$parseErrors = $null
$connectionAst = [System.Management.Automation.Language.Parser]::ParseFile($connectionSourcePath, [ref]$tokens, [ref]$parseErrors)
Assert-TargetCatalogTest -Condition (@($parseErrors).Count -eq 0) -Message 'Remote connection source did not parse.'
$functions = @($connectionAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
$connectFunction = @($functions | Where-Object Name -eq 'Invoke-ConnectLanTarget' | Select-Object -First 1)
$selectorFunction = @($functions | Where-Object Name -eq 'Invoke-ConnectionHistorySelector' | Select-Object -First 1)
$historyStatusFunction = @($functions | Where-Object Name -eq 'Test-DeviceCheckHistoryEntryOnline' | Select-Object -First 1)
$presentationFunction = @($functions | Where-Object Name -eq 'Get-DeviceCheckTargetStatusPresentation' | Select-Object -First 1)
Assert-TargetCatalogTest -Condition ($connectFunction.Count -eq 1) -Message 'Invoke-ConnectLanTarget was not found.'
Assert-TargetCatalogTest -Condition ($selectorFunction.Count -eq 1) -Message 'Invoke-ConnectionHistorySelector was not found.'
Assert-TargetCatalogTest -Condition ($historyStatusFunction.Count -eq 1) -Message 'Test-DeviceCheckHistoryEntryOnline was not found.'
Assert-TargetCatalogTest -Condition ($presentationFunction.Count -eq 1) -Message 'Get-DeviceCheckTargetStatusPresentation was not found.'

$connectText = $connectFunction[0].Extent.Text
$selectorText = $selectorFunction[0].Extent.Text
Assert-TargetCatalogTest -Condition ($connectText -match 'Get-WinRMTargetCatalog') -Message 'Initial Ctrl+L flow does not load the local target catalog.'
Assert-TargetCatalogTest -Condition ($connectText -notmatch 'Get-DeviceCheckDiscoveredHosts') -Message 'Initial Ctrl+L flow still blocks on LAN discovery before the selector.'
Assert-TargetCatalogTest -Condition ($selectorText -match '\[Scan network now\.\.\.\]') -Message 'The selector is missing an explicit Scan network action.'
Assert-TargetCatalogTest -Condition ($selectorText -match '(?s)\$validationStatus\s*=\s*\$\(if\s*\(\$hasFreshDiscoverySnapshot\).*?''CachedDiscovery''.*?else.*?''NotChecked''') -Message 'Saved targets do not fall back to NotChecked when no fresh discovery snapshot exists.'
Assert-TargetCatalogTest -Condition ($selectorText -match 'Test-DeviceCheckHistoryEntryOnline\s+-Entry\s+\$entry\s+-DiscoveredHosts\s+\$currentDiscovered') -Message 'Saved targets are not correlated with the fresh discovery snapshot.'
Assert-TargetCatalogTest -Condition ($selectorText -match 'Fresh scan found') -Message 'The selector does not explain when fresh scan targets are already present in saved history.'
Assert-TargetCatalogTest -Condition ([regex]::Matches($selectorText, 'Get-DeviceCheckTargetStatusPresentation\s+-Item\s+\$item').Count -eq 2) -Message 'Selected and unselected rows do not share one status-presentation path.'
Assert-TargetCatalogTest -Condition ($selectorText -match '''Escape''\s*\{\s*return\s+\$null\s*\}') -Message 'Selector ESC behavior changed.'
Assert-TargetCatalogTest -Condition ($connectText -match 'Resolve-WinRMHistoryTargetAddress') -Message 'Saved target selection does not use canonical on-demand validation.'
Assert-TargetCatalogTest -Condition ($connectionAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-HistoryTargetAddress' }, $true).Count -eq 0) -Message 'Legacy saved-target resolver still exists beside the canonical resolver.'

Invoke-Expression $historyStatusFunction[0].Extent.Text
Invoke-Expression $presentationFunction[0].Extent.Text
$historyEntry = [PSCustomObject]@{
    ComputerName  = 'NEOS'
    LastIPAddress = '192.168.1.6'
    MACAddress    = '34-5A-60-A4-65-2C'
    NetworkId     = 'Home|AA-BB-CC-DD-EE-FF|192.168.1'
}
$freshHost = [PSCustomObject]@{
    HostName  = 'NEOS'
    IP        = '192.168.1.6'
    MAC       = '34-5A-60-A4-65-2C'
    WinRmOpen = $true
}
$freshState = Test-DeviceCheckHistoryEntryOnline -Entry $historyEntry -DiscoveredHosts @($freshHost) -CurrentNetworkId $historyEntry.NetworkId
Assert-TargetCatalogTest -Condition ($freshState.IsOnline -and $freshState.WinRmOpen -and $freshState.ResolvedIP -eq '192.168.1.6') -Message 'A freshly discovered saved target was not correlated as online.'

$notChecked = Get-DeviceCheckTargetStatusPresentation -Item ([PSCustomObject]@{ ValidationStatus = 'NotChecked'; IsOnline = $false; WinRmOpen = $false })
$online = Get-DeviceCheckTargetStatusPresentation -Item ([PSCustomObject]@{ ValidationStatus = 'CachedDiscovery'; IsOnline = $true; WinRmOpen = $true })
$offline = Get-DeviceCheckTargetStatusPresentation -Item ([PSCustomObject]@{ ValidationStatus = 'CachedDiscovery'; IsOnline = $false; WinRmOpen = $false })
Assert-TargetCatalogTest -Condition ($notChecked.Kind -eq 'NotChecked' -and $notChecked.Label -eq 'Not checked') -Message 'An unscanned saved target does not render as Not checked.'
Assert-TargetCatalogTest -Condition ($online.Kind -eq 'Online' -and $online.Label -eq 'Online') -Message 'A freshly discovered saved target does not render as Online.'
Assert-TargetCatalogTest -Condition ($offline.Kind -eq 'Offline' -and $offline.Label -eq 'Offline') -Message 'A saved target absent from a fresh scan does not render as Offline.'

$catalogAdapterText = Get-Content -LiteralPath $catalogAdapterPath -Raw
Assert-TargetCatalogTest -Condition ($catalogAdapterText -match 'Get-WinRMConnectionHistory') -Message 'Target catalog adapter does not use canonical connection history.'
Assert-TargetCatalogTest -Condition ($catalogAdapterText -match 'Add-WinRMConnectionHistoryEntry') -Message 'Target catalog adapter does not use canonical history updates.'
Assert-TargetCatalogTest -Condition ($catalogAdapterText -notmatch 'Get-Command\s+-Name\s+''(Get|Add)-WinRM') -Message 'Target catalog adapter still treats required canonical APIs as optional fallbacks.'

$entryPointText = Get-Content -LiteralPath $entryPoint -Raw
$catalogPartIndex = $entryPointText.IndexOf("'06-RemoteTargetCatalog.ps1'", [System.StringComparison]::Ordinal)
$connectionPartIndex = $entryPointText.IndexOf("'06-RemoteConnection.ps1'", [System.StringComparison]::Ordinal)
Assert-TargetCatalogTest -Condition ($catalogPartIndex -ge 0 -and $catalogPartIndex -lt $connectionPartIndex) -Message 'Target catalog adapters are not loaded before the connection UI.'

$previousStateRoot = Get-WinRMDiscoveryStateRoot
$testStateRoot = Join-Path ([System.IO.Path]::GetTempPath()) "DeviceCheckTargetCatalog-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $testStateRoot -Force
try {
    Set-WinRMDiscoveryStateRoot -Path $testStateRoot
    $networkId = 'DeviceCheckScale|AA-BB-CC-DD-EE-FF|192.0.2'
    $history = for ($index = 1; $index -le 100; $index++) {
        [PSCustomObject]@{
            ComputerName  = ('DEVICE-{0:D3}' -f $index)
            LastIPAddress = "192.0.2.$index"
            MACAddress    = ('02-10-00-00-00-{0:X2}' -f $index)
            UserName      = 'user'
            NetworkId     = $networkId
            LastConnected = [datetime]::UtcNow.AddMinutes(-$index).ToString('o')
        }
    }
    $history | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $testStateRoot 'connection-history.json') -Encoding UTF8
    $forbiddenSecret = 'devicecheck-catalog-secret'
    $null = Save-WinRMDiscoverySnapshot -NetworkId $networkId -Targets @(
        [PSCustomObject]@{
            ComputerName  = 'DISCOVERED-ONLY'
            IPAddress     = '198.51.100.20'
            MACAddress    = '02-10-00-00-01-01'
            WinRMHttpOpen = $true
            Password      = $forbiddenSecret
        }
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $catalog = Get-WinRMTargetCatalog -NetworkId $networkId -IncludeDiagnostics
    $watch.Stop()
    Assert-TargetCatalogTest -Condition ($catalog.SavedTargetCount -eq 100 -and $catalog.TargetCount -eq 101) -Message 'DeviceCheck scale catalog returned incorrect counts.'
    Assert-TargetCatalogTest -Condition ($watch.Elapsed.TotalMilliseconds -lt 1000) -Message "DeviceCheck 100-target local catalog exceeded 1000 ms: $([math]::Round($watch.Elapsed.TotalMilliseconds, 1)) ms."
    Assert-TargetCatalogTest -Condition (@($catalog.Targets | Where-Object { $_.HasSavedHistory -and $_.ValidationStatus -ne 'NotChecked' }).Count -eq 0) -Message 'A saved DeviceCheck target was treated as already validated.'
    $serializedCatalog = $catalog | ConvertTo-Json -Depth 8 -Compress
    Assert-TargetCatalogTest -Condition ($serializedCatalog -notmatch [regex]::Escape($forbiddenSecret)) -Message 'Catalog diagnostics exposed a forbidden secret.'
} finally {
    Set-WinRMDiscoveryStateRoot -Path $previousStateRoot
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testStateRoot)
    $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'DeviceCheck target catalog tests passed.' -ForegroundColor Green
