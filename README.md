<p align="center">
  <img src="https://img.shields.io/badge/Platform-Windows-0078d7?style=for-the-badge&logo=windows&logoColor=white" alt="Platform">
  <img src="https://img.shields.io/badge/Language-PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white" alt="Language">
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License">
</p>

<h1 align="center">🔍 DeviceCheck</h1>

<p align="center">
  <b>A premium, interactive PowerShell TUI for viewing and verifying Plug and Play device hierarchies.</b><br>
  <sub>Browse device classes → inspect connection paths → identify unknown hardware.</sub>
</p>

---

## ✨ What's Inside

| # | Tool | Description |
|:-:|------|-------------|
| 🛠️ | **[DeviceCheck](#devicecheck-tui)** | Interactive text-based Device Manager interface |
| 🔁 | **[Remote Evidence Export](#remote-evidence-export)** | Same-LAN WinRM collector for repeatable local/remote PC snapshots |
| 🧬 | **[Hardware ID Foundation](#hardware-id-foundation)** | Migrated offline hardware ID database, resolver, INF evidence, and driver package metadata audit tools |

---

## 🛠️ DeviceCheck TUI

> An interactive Windows Terminal console app replicating the device category structure.

### The Problem
- Windows Device Manager is a slow, GUI-bound utility.
- Getting clean parent-child relationship info (like finding exactly which hub a broken USB device is plugged into) requires diving into deep properties tabs.
- Checking IDs and status for multiple devices is tedious.

### The Solution

A fast, keyboard-driven console interface that groups all present hardware by their device class and lists them in an expandable/collapsible tree using PowerShell and low-level WMI/CIM properties. On wide terminals, the app uses a dual-pane layout with the Device Manager-style tree on the left and selected device/system details on the right. When selected-device evidence is cached, the details pane also shows local Hardware ID resolution from the offline `hwdata` cache, including PCI board vendor/subdevice fallback when exact subsystem model data is not present, plus readable installed-driver facts such as provider, version, date, INF, service, and driver key.

```
+------------------------------------------+
|  [>] Audio inputs and outputs            |
|  [v] Cameras                             |
|      └── USB Camera [Camera]             |
|  [>] Display adapters                    |
+------------------------------------------+
```

### Usage

**From terminal:**
```powershell
# Run the interactive TUI
.\DeviceCheck.ps1

# Optional: show lightweight TUI render metrics while testing scroll smoothness
$env:DEVICECHECK_TUI_PERF = '1'
.\DeviceCheck.ps1
```

| Key | Action |
|-----|--------|
| `R` | Rescan machine evidence and the full present PnP device tree; shows running/complete counts |
| `Ctrl+L` | Connect to a same-LAN/workgroup PC, collect/open snapshots, and browse the local offline snapshot library grouped by saved network |
| `E` | Collect local evidence for the selected device; on a category, scan that group; on the computer root, press `E` twice within 4 seconds to scan all present devices. Selected-device details refresh as soon as evidence is saved |
| `S` | Refresh selected-device evidence, then run web/AI lookup |
| `A` | Run the agentic driver finder for the selected device; the tree shows one agent row while full answer, trace, and links stay in the details pane |
| `M` | Select which free-tier AI models are active for lookup |
| `+` | Expand the selected category; on the computer root, expand every category |
| `-` | Collapse the selected category; on the computer root, collapse every category |
| `Q` / `Esc` | Exit |

---

## 🔁 Remote Evidence Export

> A repeatable same-LAN collector for workgroup PCs before remote TUI target switching is wired in.

### The Problem
- Shop/workbench PCs need quick inspection without retyping long WinRM commands.
- Remote testing needs a stable JSON snapshot that can be reviewed even after the PC is disconnected.
- The interactive TUI should not grow more remote plumbing until the collector path is proven.

### The Solution

`internal\Export-DeviceCheckEvidence.ps1` collects system identity, present PnP devices, optional per-device properties, `pnputil` output, and monitor registry/WMI evidence from either the local host or a same-LAN WinRM target. `Connect-PaliosDeviceCheck.ps1` is a convenience wrapper for the known `PALIOS` desktop and writes snapshots under `%LOCALAPPDATA%\DeviceCheck\snapshots\`.
Inside the TUI, `Ctrl+L` prompts for a computer name/IP (or lists saved history/discovered PCs) and opens the existing `latest.json` snapshot immediately when one is available. The selector shows active online saved connections for the current network, plus an `Offline Snapshots` submenu where offline PCs are grouped by saved network. This keeps one-time shop/customer PCs available as an offline evidence corpus without crowding the daily target list or requiring manual archiving. The offline library is the local `%LOCALAPPDATA%\DeviceCheck` cache for the PC running DeviceCheck, so snapshots collected from another PC must be scanned again or copied/imported before they appear here. If the target PC is offline, DeviceCheck lets you load its cached snapshot in offline mode and dynamically disables live refresh (`R`) and archive capture (`F`). For online cached targets, `R` performs a quick snapshot refresh and `F` captures a slower full archive sample marked as `SnapshotMode = FullArchive` / `CapturePurpose = RepairShopSample`. Type `local`, `.`, `localhost`, or the current computer name to switch back to the host. New remote logins use DeviceCheck's inline username/password prompts instead of PowerShell's separate credential dialog, and connection failures stay on the connect/refresh screen until you acknowledge them.

```text
NEOS TUI -> Ctrl+L -> WinRM target -> collector snapshot -> remote device tree
```

### Usage

```powershell
# Known shop/lab target shortcut
.\Connect-PaliosDeviceCheck.ps1

# Faster connectivity/evidence smoke without per-device property expansion
.\Connect-PaliosDeviceCheck.ps1 -Quick

# Generic local snapshot
.\internal\Export-DeviceCheckEvidence.ps1

# Generic remote target
$cred = Get-Credential 'PALIOS\joty79'
.\internal\Export-DeviceCheckEvidence.ps1 -ComputerName PALIOS -Credential $cred

# Run once on the target PC to enable WinRM and prepare a usable local admin
.\Enable-RemotePs.ps1

# Run again after the snapshot and answer Y when it offers to remove dcadmin and profile folders
.\Enable-RemotePs.ps1

# Force-create the temporary local admin used for snapshots
.\Enable-RemotePs.ps1 -CreateDeviceCheckUser -DeviceCheckUserName dcadmin

# Remove the temporary local admin and matching profile folders after finishing snapshots
.\Enable-RemotePs.ps1 -RemoveDeviceCheckUser -DeviceCheckUserName dcadmin
```

| Parameter | Details |
|-----------|---------|
| `-ComputerName` | Target host name or IP; local host is the default for the generic exporter. |
| `-Credential` / `-UserName` | Explicit WinRM credentials. The PALIOS wrapper prompts for `PALIOS\joty79` by default. |
| `-Quick` | Skips full per-device property expansion for faster connection testing. |
| `-SkipTrustedHosts` | Skips automatic exact-target `TrustedHosts` update when it is already configured. |
| `-NoSave` | Runs the collector and prints a summary without writing a snapshot file. |

`TrustedHosts` updates are target-specific only; the scripts refuse wildcard trust entries and never store passwords.
`Enable-RemotePs.ps1` checks whether the target has an enabled local administrator account. If the only administrator is a Microsoft Account, it offers to create a temporary local admin such as `dcadmin`; pressing Enter at the password prompt creates it passwordless, matching the shop/workbench default. Running the helper again later detects the temporary user and matching profile folders such as `C:\Users\dcadmin*`, then asks whether to remove them. The helper also keeps `LimitBlankPasswordUse = 0` so passwordless local accounts can work over the LAN when that workflow is intentionally used.
In the first TUI remote slice, `R` refreshes the active remote snapshot using the in-session credential when available; selected-device `E`, `S`, and `A` actions remain local-target only until remote per-device actions are wired safely.
The first full PALIOS LAN snapshot completed through a Windows PowerShell 5.1 WinRM endpoint in about 10 seconds, collecting 127 present devices, 9 monitor registry entries, and connected-device `pnputil` output.

---

## 🧬 Hardware ID Foundation

> Migrated audit-only engine layer for richer device identity and future driver finding.

### The Problem
- The TUI already collects local PnP evidence, but driver research needs offline PCI/USB/PNP lookup data.
- Local installed INF evidence must be separated from web/AI guesses.
- Candidate driver package metadata needs a strict safety gate before any future download or install workflow.

### The Solution

The migrated `internal\` tools build a local `hwdata` cache, resolve Hardware IDs, inspect installed INF evidence, create unified evidence bundles, and validate candidate package metadata. PCI resolution separates chip identity from board identity: for example `VEN/DEV` can identify the GPU chip, while `SUBSYS` can still expose the board vendor and board code even when the exact marketing model is missing locally. USB resolution separates exact `VID/PID` identity from generic compatible class evidence, so `USB\Class_01&SubClass_00&Prot_20` can explain "USB Audio class match" without pretending to know the exact product or codec. HDAUDIO resolution parses onboard HD Audio codec IDs such as `HDAUDIO\FUNC_01&VEN_10EC&DEV_0892&SUBSYS_10438698`, resolving codec/subsystem vendors locally and using separate board/OEM evidence for exact codec names such as `ASUS Z170-A onboard Realtek ALC892 HD Audio`. DISPLAY resolution parses monitor IDs such as `DISPLAY\GSM5BD3` as EDID manufacturer/product codes, resolving the vendor through `pnp.ids` where available and falling back to the local Windows manufacturer string when the offline table is missing a code such as `AOC`. The selected-device pane combines raw registry EDID, `root\wmi` monitor classes, and installed monitor INF names into a compact monitor summary with local descriptors, size, manufacture date, native timing, connector evidence, and checksum state without claiming an exact retail model unless a stronger offline/OEM source proves it. Storage resolution explains Windows disk IDs such as `SCSI\DISK&VEN_NVME&PROD_*`, `USBSTOR\Disk&Ven_*&Prod_*`, and `IDE\Disk...` as storage-stack identity, which is why NVMe/SATA/USB drives can appear under different Windows storage enumerators; compact SCSI strings can contain fixed-width underscore padding, so the UI strips padding and prefers structured IDs/local FriendlyName for readable disk models. The TUI auto-builds the generated `data\hwdb` cache from the tracked runtime-critical `source\hwdata` and `source\alsa-ucm-conf` source files when generated caches are missing, so the local database can travel between machines without manual bootstrap. A separate read-only board-model evidence file can add user-confirmed or official-spec exact marketing models without pretending that `pci.ids` or `usb.ids` knew them. SDIO comparison is kept as an audit adapter: `internal\Invoke-SdioDriverAudit.ps1` parses SDIO matcher logs or launches SDIO with install disabled, then writes candidate matches into DeviceCheck's per-device cache so the details pane can show whether SDIO matched exact hardware IDs or fallback compatible IDs. The first TUI integrations are local Hardware ID resolution, board-model evidence display, USB class breakdown, HDAUDIO codec/subsystem breakdown, DISPLAY monitor breakdown, monitor EDID/WMI/INF evidence, storage breakdown, ALSA UCM audio profile evidence, safe local labels, readable installed-driver evidence, and cached SDIO match evidence in the selected-device details pane; the deeper trust/package/download layers remain CLI/report-first for now.

```text
hwdata source -> data\hwdb -> resolver -> inventory/evidence -> package metadata gate
```

### Usage

```powershell
# Optional: rebuild local hardware ID cache from cloned DeviceCheck\source\hwdata
# DeviceCheck.ps1 also auto-builds this cache at startup when it is missing.
pwsh -ExecutionPolicy Bypass -File .\internal\Update-HardwareIdDatabases.ps1

# Resolve a Hardware ID from the local cache
pwsh -ExecutionPolicy Bypass -File .\internal\Resolve-HardwareIds.ps1 'USB\VID_5986&PID_215D'

# Run Hardware ID resolver smoke tests
pwsh -ExecutionPolicy Bypass -File .\internal\Test-HardwareIdResolver.ps1

# Keep DeviceCheck.ps1 from growing back into a monolith
pwsh -ExecutionPolicy Bypass -File .\internal\Test-DeviceCheckStructure.ps1

# Optional: enforce the same structure guard before every local commit
git config core.hooksPath .githooks

# Build and test ALSA UCM USB audio profile evidence
pwsh -ExecutionPolicy Bypass -File .\internal\Update-AlsaUcmProfiles.ps1
pwsh -ExecutionPolicy Bypass -File .\internal\Test-AlsaUcmResolver.ps1

# Create an audit-only package metadata template from latest evidence
pwsh -ExecutionPolicy Bypass -File .\internal\Test-DriverCandidatePackageMetadata.ps1 -CreateTemplate -Filter Camera

# Parse a captured SDIO matcher log and update the selected-device SDIO cache
pwsh -ExecutionPolicy Bypass -File .\internal\Invoke-SdioDriverAudit.ps1 `
  -ExistingLog 'D:\Temp\Windows\UserTemp\DeviceCheck-SDIO-20260608-010409\logs\log.txt' `
  -InstanceId 'PCI\VEN_10EC&DEV_8126&SUBSYS_7E511462&REV_01\01000000684CE00000' `
  -UpdateDeviceCheckCache

# Parse the same SDIO log and populate cached SDIO matches for every local device SDIO matched
pwsh -ExecutionPolicy Bypass -File .\internal\Invoke-SdioDriverAudit.ps1 `
  -ExistingLog 'D:\Temp\Windows\UserTemp\DeviceCheck-SDIO-20260608-010409\logs\log.txt' `
  -UpdateAllDeviceCheckCaches
```

| Tool | Purpose |
|------|---------|
| `internal\Update-HardwareIdDatabases.ps1` | Imports local `source\hwdata` into generated `data\hwdb`. |
| `internal\HardwareIdResolver.psm1` | Parses and resolves PCI/USB/HID/HDAUDIO/DISPLAY/storage/ACPI/PNP IDs from the local cache. |
| `internal\Test-HardwareIdResolver.ps1` | Smoke-tests resolver behavior for USB `VID/PID/REV/MI`, generic USB class compatible IDs, SCSI/USBSTOR/IDE storage IDs, DISPLAY monitor IDs, and HDAUDIO codec/subsystem IDs. |
| `internal\Test-DeviceCheckStructure.ps1` | Fails when `DeviceCheck.ps1` grows beyond the entrypoint budget, regains local function definitions, or any dot-sourced part exceeds the per-file budget. |
| `internal\MonitorEdidResolver.psm1` | Decodes raw monitor EDID bytes and reads registry, WMI, and installed-INF evidence for present DISPLAY devices. |
| `internal\Test-MonitorEdidResolver.ps1` | Smoke-tests EDID manufacturer/product/name/date/checksum decoding with a synthetic fixture; `-IncludeLiveMonitor` adds real local monitor WMI/INF checks. |
| `internal\Update-AlsaUcmProfiles.ps1` | Imports local ALSA UCM `USB-Audio.conf` profile rules into generated `data\hwdb`. |
| `internal\AlsaUcmResolver.psm1` | Resolves USB audio VID/PID values against ALSA UCM profile rules as open-source profile evidence. |
| `internal\Test-AlsaUcmResolver.ps1` | Proves `0db0:cd0e` maps to `Realtek/ALC4080` through ALSA UCM without changing the `usb.ids` result. |
| `internal\InfDriverParser.psm1` | Independent section-aware INF parser; does not copy GPL `wininfparser` code. |
| `internal\Find-InstalledInfMatches.ps1` | Local audit-only installed INF evidence matcher. |
| `internal\Invoke-SdioDriverAudit.ps1` | Parses SDIO matcher logs or runs SDIO with `-disableinstall`, then writes cached selected-device or all-device candidate evidence for DeviceCheck. |
| `internal\New-DriverEvidenceBundle.ps1` | Composes inventory, candidate links, INF evidence, and research trust. |
| `internal\Test-DriverCandidatePackageMetadata.ps1` | Creates/validates candidate package metadata templates. |
| `internal\New-DriverPackageMetadataCollectionPlan.ps1` | Creates skeleton-only source adapter tasks for metadata collection. |

GitHub Actions runs the same structure guard on push and pull request through `.github\workflows\devicecheck-structure.yml`. The optional tracked Git hook can run it before local commits after `git config core.hooksPath .githooks`.

Generated folders such as `data\hwdb`, `devices`, `driver-candidates`, `inf-matches`, `driver-evidence`, and `driver-package-metadata` are ignored by Git.
The adopted `source\hwdata\pci.ids`, `usb.ids`, `pnp.ids`, `source\alsa-ucm-conf\USB-Audio.conf`, and source license/readme/provenance files are tracked because they are the source input for rebuilding the generated cache; cloned study repos under `source\` remain ignored.
The local evidence database roadmap lives in `docs\LOCAL_HARDWARE_IDENTITY_DATABASE_PLAN.md`, backed by the two research PDFs in `docs\`.

---

## 📦 Installation

### Quick Setup
```powershell
# Clone the repository
git clone https://github.com/joty79/DeviceCheck.git
cd DeviceCheck

# Run
.\DeviceCheck.ps1
```

### Requirements
| Requirement | Details |
|-------------|---------|
| **OS** | Windows 10 / 11 |
| **Runtime** | PowerShell 7 (PS7) |
| **Terminal** | Windows Terminal (recommended for synchronized rendering) |
| **Agent browser retrieval** | Node.js and local Chrome are used by the agent when JavaScript-rendered OEM support pages block plain HTTP fetches |
| **Agent state** | Agent checkpoints, traces, and tool-result cache are stored under `%LOCALAPPDATA%\DeviceCheck\machines\<machineId>\` |

---

## 📁 Project Structure

```
DeviceCheck/
├── data/
│   └── google-ai-studio-rate-limits-only free.csv  # Local model quota reference
├── docs/
│   ├── google-ai-studio-rate-limits-only-free.md   # Human-readable quota table
│   ├── HARDWARE_SOURCE_INTAKE.md                   # Hardware/driver source intake notes
│   └── LOCAL_SOURCE_PROJECT_AUDIT.md               # Local source repo audit and transfer decisions
├── internal/
│   ├── DeviceCheck/                                  # Dot-sourced function groups used by DeviceCheck.ps1
│   ├── Export-DeviceCheckEvidence.ps1              # Local/remote snapshot collector
│   ├── HardwareIdResolver.psm1                      # Offline Hardware ID parser/resolver
│   └── InfDriverParser.psm1                         # Section-aware local INF parser
├── config/
│   ├── hardware-sources.json                        # Source intake manifest
│   ├── driver-candidate-package.schema.json         # Candidate package metadata schema
│   └── driver-package-source-adapters.json          # Metadata adapter skeletons
├── tools/
│   └── Fetch-RenderedPage.js                       # Chrome DevTools rendered-page fetch helper
├── .gitignore            # Generated evidence/cache folder ignores
├── .gitattributes        # Repository line-ending policy
├── Connect-PaliosDeviceCheck.ps1 # Convenience wrapper for PALIOS remote snapshot export
├── Enable-RemotePs.ps1     # WinRM/PSRemoting administrator configuration helper
├── DeviceCheck.ps1         # Main TUI entrypoint, startup state, and event loop
├── Get-DriverUpdateAgent.ps1 # Gemini tool-calling driver finder
├── PROJECT_RULES.md        # Project-specific implementation memory
├── PS_UI_Blueprint.psm1    # TUI synchronized rendering engine
├── README.md               # You are here
└── CHANGELOG.md            # Project version history
```

---

## 🧠 Technical Notes

<details>
<summary><b>How does it determine parent-child relationships?</b></summary>

It queries the low-level **DEVPKEY_Device_Parent** property using `Get-PnpDeviceProperty` for each device, mapping relationships to reconstruct the system's hardware connection tree.

</details>

<details>
<summary><b>Why do category names match Device Manager?</b></summary>

DeviceCheck keeps the internal Plug and Play setup class key for logic, but renders common classes with **Device Manager display names** such as `Human Interface Devices`, `Network adapters`, and `Universal Serial Bus controllers`. The top row uses the Windows system name, matching Device Manager's computer root.

</details>

<details>
<summary><b>How does it avoid console flickering?</b></summary>

It uses **Windows Terminal Synchronized Output (ANSI ESC `[?2026h` / `[?2026l`)** to write the entire viewport frame atomically, preventing rendering tears and visual jitter during scrolling.

</details>

<details>
<summary><b>How does the dual-pane layout work?</b></summary>

DeviceCheck renders both panes inside one terminal window rather than requiring a Windows Terminal split. Wide terminals show the device tree on the left and selected details on the right; narrow terminals fall back to the stacked layout.

</details>

<details>
<summary><b>How does the agent handle rate limits and retries?</b></summary>

The agent saves a checkpoint after each Gemini/tool step, including conversation state, tool results, candidate URLs, confirmed/failing URLs, and the current plan. If Gemini returns a rate-limit response or the 10-step budget guard is reached, the run pauses with a visible state; running the agent again for the same device resumes from the checkpoint and reuses cached rendered pages/tool results where possible.

Before Gemini spends planning calls, DeviceCheck builds vendor-first official candidates from the local device and machine evidence. If no official vendor candidate can be built, or if Gemini later needs identity discovery after vendor pages are insufficient, it can use rendered Google Search with raw Device Manager-style evidence (`FriendlyName`, `InstanceId`, `HardwareId`, `CompatibleId`, `Service`, and installed `INF`). Google AI Overview is treated as an identity hint, not final truth, and driver links still have to be confirmed by rendered official/vendor pages. Google can return anti-bot/reCAPTCHA pages for automated SERP sessions, so those blocks are logged and should be investigated with the Gemini Google Search briefing in `docs/gemini-google-search-investigation.md`. For regional OEM sites, Greece/Europe pages are tried before US/global pages so a US miss does not become a false "no driver" result.

</details>

<details>
<summary><b>Where does selected-device evidence get cached?</b></summary>

DeviceCheck creates a stable machine ID from SMBIOS/CIM system fields and saves selected-device evidence under `%LOCALAPPDATA%\DeviceCheck\machines\<machineId>\devices\`. Press `E` on a device to collect local evidence only, press `E` on a category to scan every device in that group, press `E` on the computer root to scan all present devices, or press `S` to refresh selected-device evidence before web/AI lookup. Root/category evidence scans are queued and throttled so the UI stays responsive, with a progress line showing completed, active, and queued scans. The cache stores PnP properties, signed driver data, and `pnputil` output so repeated investigation can reuse local evidence before spending AI/web calls.

</details>

---

<p align="center">
  <sub>Built with PowerShell · Flicker-Free TUI · System Agnostic</sub>
</p>
