#requires -version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
. (Join-Path $scriptDir 'DeviceCheck\06-RemoteDiscoveryFilters.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message Expected '$Expected', got '$Actual'." }
}

$subnets = @('192.168.1')

Assert-True  (Test-DeviceCheckLanDiscoveryIPv4 -Address '192.168.1.64' -SubnetPrefixes $subnets) 'Expected same-subnet unicast host to be accepted.'
Assert-False (Test-DeviceCheckLanDiscoveryIPv4 -Address '192.168.2.64' -SubnetPrefixes $subnets) 'Expected other subnet host to be rejected.'
Assert-False (Test-DeviceCheckLanDiscoveryIPv4 -Address '192.168.1.0' -SubnetPrefixes $subnets) 'Expected network address to be rejected.'
Assert-False (Test-DeviceCheckLanDiscoveryIPv4 -Address '192.168.1.255' -SubnetPrefixes $subnets) 'Expected broadcast address to be rejected.'
Assert-False (Test-DeviceCheckLanDiscoveryIPv4 -Address '224.0.0.22' -SubnetPrefixes $subnets) 'Expected multicast address to be rejected.'
Assert-False (Test-DeviceCheckLanDiscoveryIPv4 -Address '239.255.255.250' -SubnetPrefixes $subnets) 'Expected WS-D multicast address to be rejected.'
Assert-False (Test-DeviceCheckLanDiscoveryIPv4 -Address '169.254.10.20' -SubnetPrefixes $subnets) 'Expected APIPA address to be rejected.'
Assert-False (Test-DeviceCheckLanDiscoveryIPv4 -Address '127.0.0.1' -SubnetPrefixes $subnets) 'Expected loopback address to be rejected.'
Assert-False (Test-DeviceCheckLanDiscoveryIPv4 -Address '0.0.0.0' -SubnetPrefixes $subnets) 'Expected unspecified address to be rejected.'
Assert-False (Test-DeviceCheckLanDiscoveryIPv4 -Address '255.255.255.255' -SubnetPrefixes $subnets) 'Expected limited broadcast address to be rejected.'
Assert-False (Test-DeviceCheckLanDiscoveryIPv4 -Address 'not-an-ip' -SubnetPrefixes $subnets) 'Expected invalid address to be rejected.'

Assert-Equal 'DESKTOP-RUHR98M' (ConvertTo-DeviceCheckHostDisplayName -HostName 'DESKTOP-RUHR98M.local' -FallbackIP '192.168.1.64') 'Expected DNS suffix to be trimmed.'
Assert-Equal '192.168.1.64' (ConvertTo-DeviceCheckHostDisplayName -HostName '192.168.1.64' -FallbackIP '192.168.1.64') 'Expected IP hostnames to fall back to the IP.'
Assert-Equal '192.168.1.64' (ConvertTo-DeviceCheckHostDisplayName -HostName '64.1.168.192.in-addr.arpa' -FallbackIP '192.168.1.64') 'Expected reverse-DNS placeholders to fall back to the IP.'
Assert-Equal '192.168.1.64' (ConvertTo-DeviceCheckHostDisplayName -HostName '' -FallbackIP '192.168.1.64') 'Expected empty hostnames to fall back to the IP.'

$probeText = @'
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:pub="http://schemas.microsoft.com/windows/pub/2005/07">
  <s:Body>
    <d:ProbeMatches>
      <d:ProbeMatch>
        <a:EndpointReference><a:Address>urn:uuid:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee</a:Address></a:EndpointReference>
        <d:Types>pub:Computer</d:Types>
        <d:XAddrs>http://192.168.1.64:5357/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/</d:XAddrs>
      </d:ProbeMatch>
    </d:ProbeMatches>
  </s:Body>
</s:Envelope>
'@
$probeFields = Get-DeviceCheckWsDiscoveryProbeFields -Text $probeText
Assert-Equal 'urn:uuid:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' $probeFields.Uuid 'Expected WS-D probe parser to extract the endpoint UUID with arbitrary XML prefixes.'
Assert-Equal 'http://192.168.1.64:5357/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/' $probeFields.XAddr 'Expected WS-D probe parser to extract the metadata XAddr with arbitrary XML prefixes.'
Assert-Equal $null (Get-DeviceCheckWsDiscoveryProbeFields -Text '<d:Types>dn:NetworkInfrastructure</d:Types>') 'Expected non-computer WS-D responses to be ignored.'

$metadataText = '<pub:Computer xmlns:pub="http://schemas.microsoft.com/windows/pub/2005/07">DESKTOP-RUHR98M/Workgroup:WORKGROUP</pub:Computer>'
Assert-Equal 'DESKTOP-RUHR98M' (Get-DeviceCheckWsDiscoveryMetadataComputerName -Content $metadataText) 'Expected WS-D metadata parser to return the computer name before the workgroup suffix.'
Assert-Equal 'DESKTOP-79L36PK' (Get-DeviceCheckWsDiscoveryMetadataComputerName -Content '<Computer>DESKTOP-79L36PK</Computer>') 'Expected WS-D metadata parser to handle unprefixed Computer elements.'

Assert-Equal 'DESKTOP-79L36PK' (Get-DeviceCheckExplorerNetworkComputerNameFromPath -Path '\\DESKTOP-79L36PK') 'Expected Explorer UNC path to yield a computer name.'
Assert-Equal 'DESKTOP-79L36PK' (Get-DeviceCheckExplorerNetworkComputerNameFromPath -Path '\\DESKTOP-79L36PK\Users') 'Expected Explorer UNC child path to yield the computer name.'
Assert-Equal $null (Get-DeviceCheckExplorerNetworkComputerNameFromPath -Path '::{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}') 'Expected non-UNC Explorer paths to be ignored.'

$emptySweep = @(Invoke-DeviceCheckComputerPortSweep -SubnetPrefixes @() -ExcludedIPs @('192.168.1.1'))
Assert-Equal 0 $emptySweep.Count 'Expected empty subnet sweep to return no hosts.'

$sweepCommand = Get-Command Invoke-DeviceCheckComputerPortSweep
$functionText = [string]$sweepCommand.ScriptBlock
Assert-True ($functionText -match '\[int\[\]\]\$Ports\s*=\s*@\(3389,\s*5985,\s*445\)') 'Expected default computer-port sweep ports to include RDP 3389, WinRM 5985, and SMB 445.'

'Remote discovery filter tests passed.'
