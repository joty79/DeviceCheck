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
```

| Key | Action |
|-----|--------|
| `R` | Rescan machine evidence and the full present PnP device tree; shows running/complete counts |
| `E` | Collect local evidence for the selected device; on a category, scan that group; on the computer root, scan all present devices. Selected-device details refresh as soon as evidence is saved |
| `S` | Refresh selected-device evidence, then run web/AI lookup |
| `A` | Run the agentic driver finder for the selected device; the tree shows one agent row while full answer, trace, and links stay in the details pane |
| `M` | Select which free-tier AI models are active for lookup |
| `+` | Expand the selected category; on the computer root, expand every category |
| `-` | Collapse the selected category; on the computer root, collapse every category |
| `Q` / `Esc` | Exit |

---

## 🧬 Hardware ID Foundation

> Migrated audit-only engine layer for richer device identity and future driver finding.

### The Problem
- The TUI already collects local PnP evidence, but driver research needs offline PCI/USB/PNP lookup data.
- Local installed INF evidence must be separated from web/AI guesses.
- Candidate driver package metadata needs a strict safety gate before any future download or install workflow.

### The Solution

The migrated `internal\` tools build a local `hwdata` cache, resolve Hardware IDs, inspect installed INF evidence, create unified evidence bundles, and validate candidate package metadata. PCI resolution separates chip identity from board identity: for example `VEN/DEV` can identify the GPU chip, while `SUBSYS` can still expose the board vendor and board code even when the exact marketing model is missing locally. USB resolution separates exact `VID/PID` identity from generic compatible class evidence, so `USB\Class_01&SubClass_00&Prot_20` can explain "USB Audio class match" without pretending to know the exact product or codec. HDAUDIO resolution parses onboard HD Audio codec IDs such as `HDAUDIO\FUNC_01&VEN_10EC&DEV_0892&SUBSYS_10438698`, resolving codec/subsystem vendors locally and using separate board/OEM evidence for exact codec names such as `ASUS Z170-A onboard Realtek ALC892 HD Audio`. DISPLAY resolution parses monitor IDs such as `DISPLAY\GSM5BD3` as EDID manufacturer/product codes, resolving the vendor through `pnp.ids` where available and falling back to the local Windows manufacturer string when the offline table is missing a code such as `AOC`. The selected-device pane combines raw registry EDID, `root\wmi` monitor classes, and installed monitor INF names into a compact monitor summary with local descriptors, size, manufacture date, native timing, connector evidence, and checksum state without claiming an exact retail model unless a stronger offline/OEM source proves it. Storage resolution explains Windows disk IDs such as `SCSI\DISK&VEN_NVME&PROD_*`, `USBSTOR\Disk&Ven_*&Prod_*`, and `IDE\Disk...` as storage-stack identity, which is why NVMe/SATA/USB drives can appear under different Windows storage enumerators. The TUI auto-builds the generated `data\hwdb` cache from the tracked runtime-critical `source\hwdata` and `source\alsa-ucm-conf` source files when generated caches are missing, so the local database can travel between machines without manual bootstrap. A separate read-only board-model evidence file can add user-confirmed or official-spec exact marketing models without pretending that `pci.ids` or `usb.ids` knew them. The first TUI integrations are local Hardware ID resolution, board-model evidence display, USB class breakdown, HDAUDIO codec/subsystem breakdown, DISPLAY monitor breakdown, monitor EDID/WMI/INF evidence, storage breakdown, ALSA UCM audio profile evidence, safe local labels, and readable installed-driver evidence in the selected-device details pane; the deeper trust/package/download layers remain CLI/report-first for now.

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

# Build and test ALSA UCM USB audio profile evidence
pwsh -ExecutionPolicy Bypass -File .\internal\Update-AlsaUcmProfiles.ps1
pwsh -ExecutionPolicy Bypass -File .\internal\Test-AlsaUcmResolver.ps1

# Create an audit-only package metadata template from latest evidence
pwsh -ExecutionPolicy Bypass -File .\internal\Test-DriverCandidatePackageMetadata.ps1 -CreateTemplate -Filter Camera
```

| Tool | Purpose |
|------|---------|
| `internal\Update-HardwareIdDatabases.ps1` | Imports local `source\hwdata` into generated `data\hwdb`. |
| `internal\HardwareIdResolver.psm1` | Parses and resolves PCI/USB/HID/HDAUDIO/DISPLAY/storage/ACPI/PNP IDs from the local cache. |
| `internal\Test-HardwareIdResolver.ps1` | Smoke-tests resolver behavior for USB `VID/PID/REV/MI`, generic USB class compatible IDs, SCSI/USBSTOR/IDE storage IDs, DISPLAY monitor IDs, and HDAUDIO codec/subsystem IDs. |
| `internal\MonitorEdidResolver.psm1` | Decodes raw monitor EDID bytes and reads registry, WMI, and installed-INF evidence for present DISPLAY devices. |
| `internal\Test-MonitorEdidResolver.ps1` | Smoke-tests EDID manufacturer/product/name/date/checksum decoding with a synthetic fixture; `-IncludeLiveMonitor` adds real local monitor WMI/INF checks. |
| `internal\Update-AlsaUcmProfiles.ps1` | Imports local ALSA UCM `USB-Audio.conf` profile rules into generated `data\hwdb`. |
| `internal\AlsaUcmResolver.psm1` | Resolves USB audio VID/PID values against ALSA UCM profile rules as open-source profile evidence. |
| `internal\Test-AlsaUcmResolver.ps1` | Proves `0db0:cd0e` maps to `Realtek/ALC4080` through ALSA UCM without changing the `usb.ids` result. |
| `internal\InfDriverParser.psm1` | Independent section-aware INF parser; does not copy GPL `wininfparser` code. |
| `internal\Find-InstalledInfMatches.ps1` | Local audit-only installed INF evidence matcher. |
| `internal\New-DriverEvidenceBundle.ps1` | Composes inventory, candidate links, INF evidence, and research trust. |
| `internal\Test-DriverCandidatePackageMetadata.ps1` | Creates/validates candidate package metadata templates. |
| `internal\New-DriverPackageMetadataCollectionPlan.ps1` | Creates skeleton-only source adapter tasks for metadata collection. |

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
├── DeviceCheck.ps1         # Main interactive TUI script
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
