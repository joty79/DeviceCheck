# Hardware Source Intake Strategy

This document defines how `DeviceCheck` should use the hardware database and driver-discovery sources collected in the research notes.

## Goal

Build a readable Windows Device Manager replacement first, then add driver discovery in controlled layers:

1. Identify devices from live Windows `PnP` state.
2. Resolve raw IDs through local offline databases.
3. Generate safe candidate research reports.
4. Add local INF/package matching only after the source and safety contracts are clear.

Driver install/update automation is intentionally out of scope for this phase.

## Current Baseline

`hwdata` is the first adopted source because it already bundles the three database files we need most:

| File | Used For | Current Consumer |
| ---- | -------- | ---------------- |
| `pci.ids` | `PCI\VEN_*&DEV_*` lookup | `internal\Update-HardwareIdDatabases.ps1` |
| `usb.ids` | `USB\VID_*&PID_*` and HID-as-USB lookup | `internal\Update-HardwareIdDatabases.ps1` |
| `pnp.ids` | compact `PNPxxxx` / vendor-code lookup | `internal\Update-HardwareIdDatabases.ps1` |

The runtime code must consume the generated normalized cache under `data\hwdb\`, not the upstream repo directly.

The repo tracks only the runtime-critical `source\hwdata\pci.ids`, `usb.ids`, `pnp.ids`, and license/readme files. The full cloned `hwdata` repo, plus study repos under `source\`, remain local inputs and are not broadly vendored.

## Intake Tiers

| Tier | Sources | Decision |
| ---- | ------- | -------- |
| 0 | `vcrhonek/hwdata` | Adopted now. Keep it as the canonical first database bundle. |
| 1 | UEFI PNP/ACPI registry, Microsoft `devids.txt`, Microsoft driver docs | Track next. These fill Windows-specific ACPI/PNP and matching-rule gaps. |
| 2 | `wininfparser`, `OpenDriverUpdater`, SDIO | `wininfparser` and `OpenDriverUpdater` are now cloned for study; SDIO remains later/offline-driverpack work. |
| 3 | direct `pciids`, `usbids`, `pciutils`, `libwdi` | Do not clone by default. They either overlap with `hwdata` or are narrower concept references. |
| 4 | `fwupd`, `OCSysInfo`, Go/Rust PCI/USB libraries | Defer. Useful ideas, but not direct Windows driver database inputs right now. |

## Why Not Clone Everything

Many repositories overlap. Direct `pciids` and `usbids` are useful upstream mirrors, but `hwdata` already gives us the actual files in one local source. Library wrappers such as `go-pcidb` are useful implementation references only if the current normalized JSON resolver becomes too slow or too awkward.

Keeping a small source set reduces license review, update friction, disk usage, and accidental coupling to external layouts.

## Source Status Helper

The tracked manifest is:

```text
config\hardware-sources.json
```

Check the current local source state:

```powershell
pwsh -ExecutionPolicy Bypass -File .\internal\Get-HardwareSourceStatus.ps1
```

Include deferred/reference-only sources:

```powershell
pwsh -ExecutionPolicy Bypass -File .\internal\Get-HardwareSourceStatus.ps1 -IncludeDeferred
```

Return structured JSON for automation:

```powershell
pwsh -ExecutionPolicy Bypass -File .\internal\Get-HardwareSourceStatus.ps1 -AsJson
```

Remote checking is opt-in because normal source review should work offline:

```powershell
pwsh -ExecutionPolicy Bypass -File .\internal\Get-HardwareSourceStatus.ps1 -CheckRemote
```

## Currently Cloned Study Sources

These are present under the sibling source root:

```text
D:\Users\joty79\scripts\DeviceCheck\source\wininfparser
D:\Users\joty79\scripts\DeviceCheck\source\OpenDriverUpdater
```

| Source | License Note | Useful Finding | Decision |
| ------ | ------------ | -------------- | -------- |
| `arutar/wininfparser` | GPL-3.0 | Good reference for section-preserving INF parsing, comments, key/value/comment separation, and section lookup. | Do not embed/copy code. `DeviceCheck` now has an independent section-aware INF extractor focused on `[Manufacturer]`, model sections, HW IDs, and `[Strings]`. |
| `OpenDriverUpdater/OpenDriverUpdater` | MIT | Good layered model for `DeviceInfo`, `CandidateDriver`, `UpdateRecommendation`, version comparison, source priority, and trust scoring. Microsoft Catalog parsing is still stubbed there. | Reuse concepts/contracts only. Keep our current tool audit-only and avoid download/install automation for now. |

## Next Downloads To Ask For

No additional clone is needed immediately.

Ask the user for SDIO / Snappy Driver Installer Origin only when offline driverpack/index scoring starts:

| Source | When Needed | Why |
| ------ | ----------- | --- |
| SDIO / Snappy Driver Installer Origin source | Before offline driverpack/index scoring | Study scoring concepts and index format cautiously. |

## Guardrails

- Do not scrape web pages during normal inventory or candidate-report runs.
- Do not vendor upstream database files into Git unless there is an explicit packaging/license decision.
- `source\hwdata` is the explicit packaging exception for the current runtime-critical ID files only; do not expand it to whole cloned source repos without another decision.
- Do not treat vendor/device lookup as driver correctness.
- Prefer `SUBSYS` / OEM specificity when moving into real driver matching.
- Keep Microsoft Catalog and web results as links until package authenticity, OS targeting, signature verification, and rollback strategy are implemented.
- Treat `OpenDriverUpdater` as proof that a candidate/trust model is useful, not as proof that catalog scraping is solved; its catalog parser is currently a stub.
- Treat `wininfparser` as a parser-shape reference only because of GPL-3.0; `DeviceCheck` must use an independent INF extraction implementation.
- Keep `internal\InfDriverParser.psm1` independent and purpose-built; prefer model-section evidence over broad regex line scanning.
