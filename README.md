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

A fast, keyboard-driven console interface that groups all present hardware by their device class and lists them in an expandable/collapsible tree using PowerShell and low-level WMI/CIM properties.

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
├── DeviceCheck.ps1         # Main interactive TUI script
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
<summary><b>How does it avoid console flickering?</b></summary>

It uses **Windows Terminal Synchronized Output (ANSI ESC `[?2026h` / `[?2026l`)** to write the entire viewport frame atomically, preventing rendering tears and visual jitter during scrolling.

</details>

---

<p align="center">
  <sub>Built with PowerShell · Flicker-Free TUI · System Agnostic</sub>
</p>
