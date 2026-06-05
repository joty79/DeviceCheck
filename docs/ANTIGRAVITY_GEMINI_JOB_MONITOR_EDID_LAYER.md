# Gemini / Antigravity Job: Monitor EDID Layer

Use this as the next implementation brief inside Antigravity.

```text
Repo:
D:\Users\joty79\scripts\DeviceCheck

Context:
DeviceCheck is a PowerShell 7 Windows TUI that collects local PnP evidence and explains device identities. The current monitor work has:
- DISPLAY ID parsing in internal\HardwareIdResolver.psm1
- EDID registry decoding in internal\MonitorEdidResolver.psm1
- TUI rows in DeviceCheck.ps1 under Local Hardware Identity
- smoke tests in internal\Test-MonitorEdidResolver.ps1

Primary goal:
Improve monitor identity without AI guessing. Use local evidence first: DISPLAY hardware ID, raw EDID, WMI monitor classes, monitor INF, and only then external/offline datasets with provenance.

Tasks:
1. Inspect the current EDID implementation:
   - internal\MonitorEdidResolver.psm1
   - internal\Test-MonitorEdidResolver.ps1
   - DeviceCheck.ps1 DISPLAY branch
   Confirm it decodes EDID correctly and does not claim exact retail model unless evidence supports it.

2. Test on the user's real machine:
   Run:
   pwsh -NoProfile -ExecutionPolicy Bypass -File .\internal\Test-MonitorEdidResolver.ps1 -AsJson

   Then run a local monitor smoke:
   Import-Module .\internal\MonitorEdidResolver.psm1 -Force
   Get-PnpDevice -Class Monitor -PresentOnly | ForEach-Object {
       Get-MonitorEdidFromRegistry -InstanceId $_.InstanceId
   } | Format-List *

   Capture what fields are present for the real monitor(s). If serial numbers appear, redact them in docs/screenshots unless the user explicitly allows storing them.

3. Add WMI monitor evidence as a separate layer:
   Investigate and, if reliable, implement a read-only helper for:
   - root\wmi:WmiMonitorID
   - root\wmi:WmiMonitorBasicDisplayParams
   - root\wmi:WmiMonitorConnectionParams
   - root\wmi:WmiMonitorListedSupportedSourceModes

   Keep WMI evidence separate from raw registry EDID. Do not merge fields silently if they disagree.

4. Add monitor INF evidence:
   Search installed monitor INF files for the DISPLAY hardware ID and EDID product code.
   If a monitor INF maps DISPLAY\GSM5BD3 to a model string, show it as "INF Model" with source `Installed monitor INF`.
   If the installed INF is generic Microsoft monitor INF, label it generic and do not promote it to exact model evidence.

5. Improve UI rows carefully:
   Good rows:
   - EDID Name
   - EDID ID
   - EDID Size
   - EDID Made
   - EDID Timing
   - EDID Checksum
   - INF Model, only when exact
   - Evidence Source
   Avoid repeating the same vendor/product facts already shown in the HardwareId breakdown.

6. Add or update tests:
   - Synthetic valid EDID fixture
   - Invalid checksum/header fixture
   - Registry-reader unit behavior if possible with mocked input
   - No-exact-model case must remain no-exact-model

Validation commands:
Run these before final:
$files = @(
  '.\DeviceCheck.ps1',
  '.\internal\HardwareIdResolver.psm1',
  '.\internal\MonitorEdidResolver.psm1',
  '.\internal\Test-HardwareIdResolver.ps1',
  '.\internal\Test-MonitorEdidResolver.ps1'
)
foreach ($file in $files) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors) > $null
  if ($errors.Count) { $errors | ForEach-Object { "${file}: $($_.Message)" }; exit 1 }
}
pwsh -NoProfile -ExecutionPolicy Bypass -File .\internal\Test-HardwareIdResolver.ps1 -AsJson
pwsh -NoProfile -ExecutionPolicy Bypass -File .\internal\Test-MonitorEdidResolver.ps1 -AsJson
pwsh -NoProfile -ExecutionPolicy Bypass -File .\internal\Test-AlsaUcmResolver.ps1 -AsJson
pwsh -NoProfile -ExecutionPolicy Bypass -File .\internal\Test-HardwareIdentityHarness.ps1 -AsJson
git diff --check

Important rules:
- Do not hardcode the user's monitor model.
- Do not invent EDID product-code mappings.
- Keep user-confirmed or web-confirmed mappings in config/evidence files with provenance, not inside generic parsers.
- Treat monitor serials as privacy-sensitive.
- Explain results in Greek for the user, but keep code/docs technical terms in English.

Final deliverable:
- Code changes if needed
- Test results
- Screenshot or text summary of real monitor EDID rows
- A short TODO list for the next evidence source
```
