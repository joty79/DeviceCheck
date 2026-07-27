#requires -version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'tools\DriverAdvisor\TerminalRenderer.ps1')
. (Join-Path $repoRoot 'tools\DriverPackageView\Topology.ps1')
. (Join-Path $repoRoot 'tools\DriverPackageView\TerminalRenderer.ps1')

function Assert-DriverPackageViewEqual {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("DeviceCheck-PackageView-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
    $baseInf = Join-Path $fixtureRoot 'base.inf'
    $extensionInf = Join-Path $fixtureRoot 'extension.inf'
    $componentInf = Join-Path $fixtureRoot 'component.inf'
    $unrelatedInf = Join-Path $fixtureRoot 'unrelated.inf'
    Set-Content -LiteralPath $baseInf -Encoding utf8 -Value @'
[Version]
Class=MEDIA
DriverVer=01/01/2026,1.0.0.0
[Models]
%Device%=Install,HDAUDIO\FUNC_01&VEN_1234&DEV_5678
'@
    Set-Content -LiteralPath $extensionInf -Encoding utf8 -Value @'
[Version]
Class=Extension
ExtensionId={11111111-2222-3333-4444-555555555555}
DriverVer=01/02/2026,1.0.0.1
[Models]
%Device%=Install,HDAUDIO\FUNC_01&VEN_1234&DEV_5678
[Install.Components]
AddComponent=ExampleComponent,,ExampleComponent.Install
[ExampleComponent.Install]
ComponentIDs=VEN_TEST&AID_0001
'@
    Set-Content -LiteralPath $componentInf -Encoding utf8 -Value @'
[Version]
Class=AudioProcessingObject
DriverVer=01/03/2026,1.0.0.2
[Models]
%Device%=Install,SWC\VEN_TEST&AID_0001
'@
    Set-Content -LiteralPath $unrelatedInf -Encoding utf8 -Value @'
[Version]
Class=System
DriverVer=01/04/2026,1.0.0.3
[Models]
%Device%=Install,PCI\VEN_DEAD&DEV_BEEF
'@

    $infFiles = @(
        [pscustomobject]@{FileName='base.inf';RelativePath='base.inf';DriverVer='01/01/2026,1.0.0.0';Provider='Fixture';Class='MEDIA';CatalogFile='';SupportedDeviceIds=@('HDAUDIO\FUNC_01&VEN_1234&DEV_5678');Hash='1'},
        [pscustomobject]@{FileName='extension.inf';RelativePath='extension.inf';DriverVer='01/02/2026,1.0.0.1';Provider='Fixture';Class='Extension';CatalogFile='';SupportedDeviceIds=@('HDAUDIO\FUNC_01&VEN_1234&DEV_5678');Hash='2'},
        [pscustomobject]@{FileName='component.inf';RelativePath='component.inf';DriverVer='01/03/2026,1.0.0.2';Provider='Fixture';Class='AudioProcessingObject';CatalogFile='';SupportedDeviceIds=@('SWC\VEN_TEST&AID_0001');Hash='3'},
        [pscustomobject]@{FileName='unrelated.inf';RelativePath='unrelated.inf';DriverVer='01/04/2026,1.0.0.3';Provider='Fixture';Class='System';CatalogFile='';SupportedDeviceIds=@('PCI\VEN_DEAD&DEV_BEEF');Hash='4'}
    )
    $preview = [pscustomobject]@{
        InstallerPath='C:\Fixture\Audio.exe'
        InstallerName='Audio.exe'
        InstallerHash='FIXTURE'
        ExistingExtractedRoot=$fixtureRoot
        InfFiles=$infFiles
        Matches=@(
            [pscustomobject]@{DeviceName='Fixture Audio';DeviceClass='MEDIA';InstanceId='HDAUDIO\FIXTURE';MatchKind='ExactHardwareId';MatchedId='HDAUDIO\FUNC_01&VEN_1234&DEV_5678';Inf='base.inf'},
            [pscustomobject]@{DeviceName='Fixture Audio';DeviceClass='MEDIA';InstanceId='HDAUDIO\FIXTURE';MatchKind='ExactHardwareId';MatchedId='HDAUDIO\FUNC_01&VEN_1234&DEV_5678';Inf='extension.inf'},
            [pscustomobject]@{DeviceName='Fixture APO';DeviceClass='AudioProcessingObject';InstanceId='SWD\FIXTURE_APO';MatchKind='ExactHardwareId';MatchedId='SWC\VEN_TEST&AID_0001';Inf='extension.inf'},
            [pscustomobject]@{DeviceName='Fixture APO';DeviceClass='AudioProcessingObject';InstanceId='SWD\FIXTURE_APO';MatchKind='ExactHardwareId';MatchedId='SWC\VEN_TEST&AID_0001';Inf='component.inf'}
        )
    }

    $topology = New-DriverPackageTopology -Preview $preview
    Assert-DriverPackageViewEqual $topology.Summary.InfCount 4 'INF inventory count mismatch.'
    Assert-DriverPackageViewEqual $topology.Summary.RelatedInfCount 3 'Related INF count mismatch.'
    Assert-DriverPackageViewEqual $topology.Summary.PresentDeviceCount 2 'Present device count mismatch.'
    Assert-DriverPackageViewEqual $topology.Summary.StackRootCount 1 'Stack root count mismatch.'
    Assert-DriverPackageViewEqual $topology.Summary.DirectBindingCount 2 'Direct binding count mismatch.'
    Assert-DriverPackageViewEqual $topology.Summary.ExtensionApplicationCount 1 'Extension application count mismatch.'
    Assert-DriverPackageViewEqual $topology.Summary.PotentialApplicationCount 3 'Potential application count mismatch.'
    Assert-DriverPackageViewEqual $topology.Summary.DeclarationMatchRowCount 1 'Declaration row count mismatch.'
    Assert-DriverPackageViewEqual $topology.Summary.LinkedComponentEdgeCount 1 'Linked component count mismatch.'
    Assert-DriverPackageViewEqual $topology.Devices[0].StackRootName 'Fixture Audio' 'Child stack-root linkage mismatch.'

    foreach ($width in @(80, 104, 105, 140, 200)) {
        $snapshot = ConvertTo-DriverPackageViewSnapshot -Topology $topology -Width $width -Height 32 -PlainText
        $snapshotLines = @($snapshot -split "`r?`n")
        if (@($snapshotLines | Where-Object Length -gt $width).Count -gt 0) { throw "Package view exceeded width $width." }
        if (-not $snapshot.Contains('Fixture Audio')) { throw "Package view width $width omitted the matched root device." }
    }

    'PASS: driver package topology and filtered DeviceCheck-style view.'
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
