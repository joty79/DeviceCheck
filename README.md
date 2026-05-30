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

---

## 🛠️ DeviceCheck TUI

> An interactive Windows Terminal console app replicating the device category structure.

### The Problem
- Windows Device Manager is a slow, GUI-bound utility.
- Getting clean parent-child relationship info (like finding exactly which hub a broken USB device is plugged into) requires diving into deep properties tabs.
- Checking IDs and status for multiple devices is tedious.

### The Solution

A fast, keyboard-driven console interface that groups all present hardware by their device class and lists them in an expandable/collapsible tree using PowerShell and low-level WMI/CIM properties. On wide terminals, the app uses a dual-pane layout with the Device Manager-style tree on the left and selected device/system details on the right.

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
| `E` | Collect local evidence for the selected device; on a category, scan that group; on the computer root, scan all present devices |
| `S` | Refresh selected-device evidence, then run web/AI lookup |
| `+` | Expand the selected category; on the computer root, expand every category |
| `-` | Collapse the selected category; on the computer root, collapse every category |
| `Q` / `Esc` | Exit |

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

---

## 📁 Project Structure

```
DeviceCheck/
├── data/
│   └── google-ai-studio-rate-limits-only free.csv  # Local model quota reference
├── docs/
│   └── google-ai-studio-rate-limits-only-free.md   # Human-readable quota table
├── .gitattributes        # Repository line-ending policy
├── DeviceCheck.ps1         # Main interactive TUI script
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
<summary><b>Where does selected-device evidence get cached?</b></summary>

DeviceCheck creates a stable machine ID from SMBIOS/CIM system fields and saves selected-device evidence under `%LOCALAPPDATA%\DeviceCheck\machines\<machineId>\devices\`. Press `E` on a device to collect local evidence only, press `E` on a category to scan every device in that group, press `E` on the computer root to scan all present devices, or press `S` to refresh selected-device evidence before web/AI lookup. Root/category evidence scans are queued and throttled so the UI stays responsive, with a progress line showing completed, active, and queued scans. The cache stores PnP properties, signed driver data, and `pnputil` output so repeated investigation can reuse local evidence before spending AI/web calls.

</details>

---

<p align="center">
  <sub>Built with PowerShell · Flicker-Free TUI · System Agnostic</sub>
</p>
