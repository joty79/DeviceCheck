# DeviceCheck Driver Evidence Decision Model

## Purpose

DeviceCheck should not be a blind driver updater.

The useful product is:

> Device Manager + evidence + source comparison + risk labels.

The goal is to make driver confusion visible enough that a human can make a better decision. Installation can come much later, after the evidence model is reliable.

## Core Idea

For each device, DeviceCheck should explain:

- what the device really is
- what driver is actively bound to it
- what extra driver stack packages are attached
- where each package probably came from
- which external candidates match the same hardware
- whether a candidate is useful, redundant, older, unrelated, or risky

Example:

```text
Device: AMD Audio CoProcessor
Main driver: AMD 6.0.2.118 from AMD Adrenalin
Extensions:
  oem70.inf AMD 6.0.0.130 from AMD Adrenalin
  oem77.inf AMD 6.0.2.60 from Windows Update, older/parallel extension

Sources:
  AMD official: newer platform stack installed
  Lenovo package: older or not same branch
  Windows Update: offered extension only
  SDIO: candidate exists but needs match proof

Verdict:
  Current state is OK. Do not replace main driver.
```

## Evidence Layers To Show

### 1. Device Identity

- Friendly name
- Device category
- Instance ID
- Hardware IDs
- Compatible IDs
- Parent/child path

### 2. Current Active Driver

- Provider
- INF name
- Driver version and date
- DriverStore path
- Matching HWID and INF section
- Signer

### 3. Attached Driver Stack

- Extension INFs
- Software Components
- Services
- Audio APOs
- Firmware companion devices
- Related child devices

### 4. Source Provenance

Possible source labels:

- Windows inbox
- Windows Update
- AMD/NVIDIA/Intel official installer
- Lenovo/OEM package
- SDIO/manual
- Unknown

Provenance should be evidence-based, not guessed from names only. Useful signals include `setupapi.dev.log`, DriverStore import time, matching source folders, original INF name, catalog signer, installer logs, and known package hashes.

### 5. Candidate Comparison

Compare installed evidence against candidate sources:

- Lenovo/OEM extracted package
- AMD/NVIDIA/Intel official package
- Windows Update / Microsoft Catalog
- SDIO candidate
- local extracted driver package

The comparison must label match strength:

- exact hardware ID
- hardware ID without revision
- compatible ID fallback
- class/generic fallback
- no real match

### 6. Verdict / Risk

Useful verdict labels:

- already installed
- exact same driver
- newer same branch
- newer but different branch
- older than current
- same version, different package
- extension only, not main driver
- compatible-ID fallback only
- wrong vendor/OEM
- OS not applicable
- risky / do not install blindly
- unknown, needs review

## Source Personalities

| Source | Good For | Risk |
|---|---|---|
| AMD / NVIDIA / Intel | Platform, GPU, chipset, audio co-processor stacks when official generic support exists | Can install broad stacks that are not laptop-OEM tuned |
| Lenovo / OEM | Enablement drivers, hotkeys, firmware, special laptop components, validated baseline | Often old; compatible does not mean latest or best |
| Windows Update | Safe WHCP signed baseline and automatic extension delivery | Can offer confusing extension packages and does not explain relationships |
| SDIO | Discovery and audit, especially missing drivers | Ranking is not truth; can match fallback IDs |
| Microsoft Catalog | Powerful source for exact WHCP packages | Easy to pick unrelated OEM packages with similar names |

The correct question is not "which source is globally best?"

The correct question is:

```text
For this device and this package type, which source has the strongest evidence?
```

## TUI First Step

The first useful DeviceCheck feature should be a compact Driver Evidence section for the selected device:

```text
Driver Evidence
  Active: AMD 6.0.2.118 | oem69.inf | 2025-12-23
  Stack : 2 extensions, 1 software component
  Source: AMD Adrenalin evidence found
  Risk  : Windows Update has older parallel extension installed
```

Then a deeper Candidate Sources section:

```text
Candidate Sources
  Lenovo: older / no action
  AMD: current source, preferred for this class
  Windows Update: extension only
  SDIO: not checked / fallback candidate
```

## Review Buckets

Keep the UI decision simple:

```text
Green  = current state looks good
Yellow = confusing / needs review
Red    = missing / wrong / failed / unknown
```

Examples:

```text
Green:
Current AMD stack is newer than Lenovo baseline.

Yellow:
Windows Update installed older extension with same ExtensionId.
Visible driver unchanged.

Red:
Unknown device: ROOT\WINDOWSHELLOFACESOFTWAREDRIVER failed install.
```

DeviceCheck's job is to turn driver chaos into review buckets.

## Rules Learned From The Laptop Audit

- Do not compare only versions. A driver with version `6.0.2.60` can be older or less applicable than `6.0.0.130` depending on branch/date/package role.
- Extension INF is not the visible Device Manager driver.
- Same hardware can appear as multiple related devices, such as AMD Audio Device, AMD Audio CoProcessor, ACP HDA Node, extensions, and software components.
- Lenovo official does not mean latest. It often means validated baseline.
- SDIO `newer` or `better` is a candidate label, not a verdict.
- Windows Update can install extra packages without changing Device Manager's Driver tab.
- Exact HWID match beats compatible-ID fallback.
- OS applicability matters. A driver can be valid for Windows 10 but intentionally not applicable to Windows 11.

## Tracking What An Installer Actually Changes

For a package like:

```text
D:\Users\joty79\Downloads\laptop driver\Cardreader Driver (Genesys, Bayhub, Realtek).exe
```

there are two different questions:

1. What can this package install?
2. What did it actually change on this machine?

The first can be predicted by extracting and reading the payload:

- INF files
- `DriverVer`
- supported HWIDs
- installer scripts
- catalog signer
- package folders

The second requires before/after tracking around a real install attempt.

### Before Snapshot

Capture these before running the installer:

- `pnputil /enum-drivers /files`
- `Get-PnpDevice`
- selected `Get-PnpDeviceProperty` keys
- `Win32_PnPSignedDriver`
- `C:\Windows\INF\oem*.inf` list and hashes
- `C:\Windows\System32\DriverStore\FileRepository` directory list
- relevant `HKLM\SYSTEM\CurrentControlSet\Services` driver services
- timestamp and file length of `C:\Windows\INF\setupapi.dev.log`
- optional `setupapi.app.log`

### Run Installer

Run the installer on the test subject only, ideally elevated.

For DeviceCheck automation, the install runner should mark the timestamp before launch, then collect only log entries after that marker.

### After Snapshot

Capture the same inventory again, then diff:

- new `oem*.inf` published names
- removed or replaced `oem*.inf`
- new DriverStore folders
- active device driver changes
- new extension INFs
- new services
- SetupAPI install sections
- devices that changed status or problem code

### Important Installer Outcomes

An installer can:

- stage a driver package without binding it to any device
- bind a new active driver to a device
- add an Extension INF without changing the visible Driver tab
- install helper services/software components
- do nothing because the installed driver ranks higher
- install only the matching vendor subfolder from a combo package

For the Cardreader package specifically, the package contains Genesys, BayHub, and Realtek paths, but this laptop currently matches the Realtek `PCI\VEN_10EC&DEV_522A` path. The useful tracker should prove whether the installer stages all vendor INFs or only the matching Realtek package, and whether it changes the active `Realtek PCIE CardReader` binding.

## Future DeviceCheck Feature

A useful audit command would be:

```powershell
.\internal\Trace-DriverInstallerChanges.ps1 `
  -InstallerPath "D:\Users\joty79\Downloads\laptop driver\Cardreader Driver (Genesys, Bayhub, Realtek).exe" `
  -Label "Lenovo Cardreader"
```

Expected output:

```text
Driver installer trace: Lenovo Cardreader

New packages staged:
  none

Active driver changes:
  Realtek PCIE CardReader: unchanged
  oem19.inf 10.0.22621.21365 still active

SetupAPI:
  installer inspected PCI\VEN_10EC&DEV_522A
  no better-ranked package installed

Verdict:
  No action needed. Package is same/similar baseline.
```

This should remain an audit tool first. It should not become an automatic installer until the evidence and rollback model are trustworthy.
