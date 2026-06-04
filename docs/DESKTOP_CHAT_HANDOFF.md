# Desktop Chat Handoff - DeviceCheck

Date: 2026-06-03

This file is the starting point for a new Codex chat on the desktop machine.

## Repo Lock

Work only in:

```text
D:\Users\joty79\scripts\DeviceCheck
```

Do not continue this work in `drivercheck`. The earlier `drivercheck` work was accidental and has been migrated/adapted into `DeviceCheck`.

## Read First

In the new desktop chat, load these files before editing:

```text
D:\Users\joty79\scripts\DeviceCheck\PROJECT_RULES.md
D:\Users\joty79\scripts\DeviceCheck\CHANGELOG.md
D:\Users\joty79\scripts\DeviceCheck\README.md
D:\Users\joty79\scripts\DeviceCheck\docs\HARDWARE_SOURCE_INTAKE.md
D:\Users\joty79\scripts\DeviceCheck\docs\LOCAL_SOURCE_PROJECT_AUDIT.md
D:\Users\joty79\scripts\DeviceCheck\docs\DESKTOP_CHAT_HANDOFF.md
```

If editing PowerShell scripts, also load:

```text
C:\Users\joty79\.codex\POWERSHELL_SCRIPT_WORKFLOW.md
C:\Users\joty79\.codex\POWERSHELL_UI_WORKFLOW.md
```

If editing docs/README/changelog, also load:

```text
C:\Users\joty79\.codex\DOCS_WORKFLOW.md
C:\Users\joty79\.codex\README_TEMPLATE.md
```

## Current Goal

DeviceCheck should become a much more readable, user-friendly Device Manager replacement and later a safer driver-finding assistant.

The immediate focus is local device identity quality. For GPUs and similar PCI devices, the app should identify the hardware in layers:

- chip vendor/device from `VEN/DEV`
- board vendor/subdevice from `SUBSYS`
- exact subsystem/marketing model only when a trusted local/online source actually provides it
- search hints that help the user or future agent find official drivers

## Important GPU Test Case

Desktop GPU known by the user:

```text
MSI RTX 4060 Ti Ventus 2X Black OC
```

Reference URL from the user:

```text
https://www.techpowerup.com/gpu-specs/msi-rtx-4060-ti-ventus-2x-black-oc.b11157
```

Device Hardware ID from the desktop screenshot:

```text
PCI\VEN_10DE&DEV_2803&SUBSYS_51741462&REV_A1
```

Current local `hwdata/pci.ids` can identify:

```text
VendorId     10DE -> NVIDIA Corporation
DeviceId     2803 -> AD106 [GeForce RTX 4060 Ti]
SubvendorId  1462 -> Micro-Star International Co., Ltd. [MSI]
SubdeviceId  5174
```

Current local `pci.ids` does not contain the exact subsystem model row for `10DE:2803:1462:5174`, so DeviceCheck must not claim the exact marketing model from `pci.ids` alone.

Expected local identity rows after the latest fix:

```text
Local ID      PCI / EXACT-DEVICE+SUBVENDOR / AD106 [GeForce RTX 4060 Ti] / board Micro-Star International Co., Ltd. [MSI] 5174
Chip          NVIDIA Corporation / AD106 [GeForce RTX 4060 Ti]
Board Vendor  Micro-Star International Co., Ltd. [MSI]
Board IDs     subdevice 5174 / subvendor 1462
Exact Model   Not in local pci.ids subsystem table
Search Hint   MSI NVIDIA AD106 [GeForce RTX 4060 Ti] 5174 1462 2803 10DE
```

## Latest Fix To Verify On Desktop

The desktop screenshot showed:

```text
Local ID : Unavailable; run internal\Update-HardwareIdDatabases.ps1
```

Root cause:

`data\hwdb` is generated and ignored by Git. It can be missing on another machine even when `source\hwdata` is present.

Latest code change:

`DeviceCheck.ps1` now auto-builds `data\hwdb` from `source\hwdata` during startup when the generated cache is missing.

Files involved:

```text
DeviceCheck.ps1
internal\Update-HardwareIdDatabases.ps1
internal\HardwareIdResolver.psm1
```

## Desktop Verification Steps

Run from the desktop repo:

```powershell
cd D:\Users\joty79\scripts\DeviceCheck
.\DeviceCheck.ps1
```

If the cache is missing, startup may pause briefly while building local Hardware ID cache.

In the TUI:

1. Go to `Display adapters`.
2. Select `NVIDIA GeForce RTX 4060 Ti`.
3. Press `E` to refresh local evidence if needed.
4. Confirm the details pane no longer shows `Local ID: Unavailable`.
5. Confirm it shows the layered identity rows listed above.

If it still shows unavailable, check:

```powershell
Test-Path .\source\hwdata\pci.ids
Test-Path .\source\hwdata\usb.ids
Test-Path .\source\hwdata\pnp.ids
Test-Path .\data\hwdb\normalized\pci.json
pwsh -NoProfile -ExecutionPolicy Bypass -File .\internal\Resolve-HardwareIds.ps1 'PCI\VEN_10DE&DEV_2803&SUBSYS_51741462&REV_A1' -AsJson
```

## Validation Already Run On Laptop

These passed on the laptop repo:

```text
PowerShell parser validation for DeviceCheck.ps1
PowerShell parser validation for internal\HardwareIdResolver.psm1
Temporary missing-cache autobuild smoke
Resolver smoke for PCI\VEN_10DE&DEV_2803&SUBSYS_51741462&REV_A1
Extracted UI detail-row smoke
git diff --check
```

The laptop cannot visually verify the desktop GPU because it does not have that GPU.

## Next Engineering Step After Desktop Smoke

If the layered identity rows work, the next step is exact board-model enrichment.

Current local `pci.ids` is not enough to map:

```text
10DE:2803:1462:5174
```

to:

```text
MSI RTX 4060 Ti Ventus 2X Black OC
```

Potential next sources:

- TechPowerUp GPU database / VGA BIOS pages
- SDIO / Snappy Driver Installer Origin indexes and driverpacks
- NVIDIA driver INF packages
- Microsoft Update Catalog metadata
- vendor support pages when a safe official adapter exists

Do not implement downloads or installs yet. Keep this layer audit-only and identity-only.

## Suggested Next Task For Codex Desktop Chat

First verify the desktop TUI with the GPU.

Then implement a read-only `Board Model Evidence` layer that can store:

```text
Source
Input IDs
Matched IDs
Model name
Vendor
Confidence
URL or local file path
Timestamp
Notes
```

Start with a local/manual evidence adapter or a TechPowerUp research adapter, but do not claim exact model unless the source maps the exact PCI tuple or provides strong evidence tied to the same board/subsystem.

