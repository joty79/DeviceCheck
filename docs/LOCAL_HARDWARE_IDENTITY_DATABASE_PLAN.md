# Local Hardware Identity Database Plan

Date: 2026-06-04

## Σκοπός

Αυτό το plan μετατρέπει τα δύο research PDFs σε πρακτικό roadmap για το `DeviceCheck`.

Research inputs:

- `docs\DeviceCheck_ Local Hardware Identity Design.pdf`
- `docs\Designing a Reliable Local Digital Evidence Architecture.pdf`

Κεντρική απόφαση: το `DeviceCheck` δεν πρέπει να ψάχνει μόνο για ένα “ωραίο όνομα” συσκευής. Πρέπει να χτίζει ένα local evidence bundle που κρατά raw identifiers, local/installed evidence, enrichment sources, confidence, και provenance.

Το `USB\VID_0DB0&PID_CD0E&MI_00` της Realtek USB Audio στο MSI MAG X870 TOMAHAWK WIFI είναι regression case, όχι ειδικός hardcoded στόχος.

## Current Repo State

Ήδη υπάρχει μέρος του Phase 1:

- `source\hwdata\pci.ids`, `usb.ids`, `pnp.ids` tracked ως runtime-critical source input.
- `internal\Update-HardwareIdDatabases.ps1` παράγει `data\hwdb`.
- `internal\HardwareIdResolver.psm1` κάνει PCI/USB/HID/ACPI/PNP resolution.
- `DeviceCheck.ps1` δείχνει structured Hardware ID breakdown και compact `Local Hardware Identity`.
- `config\board-model-evidence.json` υπάρχει μόνο για explicit user-confirmed/local evidence, όχι για blind mappings.

Άρα το επόμενο σωστό βήμα δεν είναι “βάλε κι άλλα mappings”. Είναι schema + harness + source provenance.

## Design Principles

1. Preserve raw first.

Store the raw `InstanceId`, `HardwareId`, `CompatibleId`, driver properties, SMBIOS fields, EDID bytes, and source file metadata before any enrichment.

2. Enrich in layers.

Do not collapse `usb.ids`, INF, ALSA UCM, SMBIOS, OEM specs, and user confirmation into one field. Each source gets its own layer, source URL/path, version/commit/date, and confidence.

3. Never let enrichment overwrite evidence.

Example: `usb.ids` says vendor-only for `0DB0:CD0E`. ALSA UCM and MSI specs may support `Realtek ALC4080`, but the UI must not present that as a `usb.ids` exact match.

4. Every derived claim needs provenance.

Any derived model name must show where it came from: local file, installed INF, ALSA commit, OEM spec URL, or user attestation.

5. Harness before broad enrichment.

Before adding ALSA UCM, DriverStore index, EDID decoding, or OEM adapters into the TUI, add regression tests that prove false positives are blocked.

## Evidence Layers

| Layer | Name | Purpose | Example |
|---|---|---|---|
| L0 | Raw Device Evidence | Preserve exact local strings and properties | `USB\VID_0DB0&PID_CD0E&MI_00` |
| L1 | Local ID Database | `pci.ids`, `usb.ids`, `pnp.ids` lookup | `VID_0DB0 = Micro Star International` |
| L2 | Bus/Class/Service | USB/PCI class and Windows service context | `USB Class 01`, `RtkUsbAD_2422` |
| L3 | Installed Driver/INF | Active Windows driver package evidence | `rtdusbad_msi.inf`, `RtkUsbAD.NT`, `Realtek USB Audio` |
| L4 | Subsystem/OEM Vendor | PCI `SUBSYS`, USB interface, vendor implementation hints | NVIDIA `SUBSYS_51741462` |
| L5 | SMBIOS/System Context | BaseBoard/System SKU/chassis context | `MAG X870 TOMAHAWK WIFI (MS-7E51)` |
| L6 | Open-Source Profile | ALSA UCM, Linux hwdb, LVFS/fwupd-like metadata | `0db0:cd0e -> Realtek/ALC4080` |
| L7 | Official OEM Spec | Vendor support/spec/manual correlation | MSI spec says `Realtek ALC4080 Codec` |
| L8 | User-Attested Evidence | User-confirmed exact physical model with explicit source | RTX 4060 Ti exact board model |

## Source Strategy

### Keep As Core Local Sources

- `hwdata` bundle: `pci.ids`, `usb.ids`, `pnp.ids`.
- Windows PnP/CIM evidence already collected by `DeviceCheck.ps1`.
- Installed driver evidence from `Win32_PnPSignedDriver`, `DEVPKEY_Device_*`, and selected INF files.

### Add As Next Local/Offline Sources

- Windows DriverStore/INF index.
- ALSA UCM `ucm2\USB-Audio` profile importer.
- EDID decoder from Windows `DISPLAY` registry data.
- Source provenance manifest and test fixtures.

### Defer Until Harness Exists

- OEM support/spec adapters.
- Microsoft Update Catalog / `Wsusscn2.cab` metadata.
- TechPowerUp GPU database/API/licensed data.
- SDIO/DriverPack indexes.
- LVFS/fwupd metadata.

## Proposed Data Files

Keep generated runtime caches ignored unless explicitly decided otherwise.

Add source/schema/test files like:

```text
config\hardware-identity-sources.json
config\hardware-identity-confidence.json
schemas\hardware-id-database.schema.json
schemas\hardware-source-manifest.schema.json
schemas\device-evidence-bundle.schema.json
schemas\hardware-match-result.schema.json
schemas\hardware-regression-tests.schema.json
tests\fixtures\hardware-identity\TC_MSI_X870_REALTEK_AUDIO_001\
tests\fixtures\hardware-identity\TC_NVIDIA_4060TI_MSI_5174_001\
internal\Test-HardwareIdentityHarness.ps1
internal\New-HardwareEvidenceBundle.ps1
internal\Import-AlsaUcmProfiles.ps1
internal\New-DriverStoreInfIndex.ps1
internal\Get-MonitorEdidIdentity.ps1
```

## Confidence Labels

Use named labels first, numeric scores second.

Recommended labels:

- `RAW-ID`
- `VENDOR-ONLY`
- `EXACT-ID-DATABASE`
- `EXACT-INF-HARDWARE-ID`
- `COMPATIBLE-INF-CLASS`
- `SUBSYSTEM-VENDOR`
- `OPEN-SOURCE-PROFILE`
- `OEM-SPEC-CORRELATED`
- `USER-ATTESTED`

Example UI for the Realtek regression:

```text
Local Match      : USB / VENDOR-ONLY / usb.ids
Coverage         : No exact product model in local usb.ids
Driver Identity  : Realtek USB Audio / rtdusbad_msi.inf / RtkUsbAD.NT
Audio Profile    : Realtek/ALC4080 / ALSA UCM
Spec Inference   : Realtek ALC4080 Codec / MSI official spec
Confidence       : OEM-SPEC-CORRELATED + OPEN-SOURCE-PROFILE / 85-95
```

Forbidden output:

```text
Exact USB Product : Realtek ALC4080
Source            : usb.ids
```

## Regression Harness

The first harness should be small and deterministic.

Inputs:

- Mock raw device evidence JSON.
- Mock SMBIOS JSON.
- Mock installed INF JSON or mini `.inf` file.
- Mock `usb.ids` where vendor exists and product is missing.
- Mock ALSA UCM profile/regex data.
- Expected output JSON.

Required assertions:

- Raw IDs are preserved exactly.
- `usb.ids` product remains unresolved when product row is absent.
- INF match is labeled as driver identity, not silicon identity.
- ALSA/OEM evidence can resolve `Realtek ALC4080` only in its own layer.
- Confidence floor is met only when multiple independent layers agree.
- Hallucinated/generic names are rejected.

Initial test cases:

1. `TC_MSI_X870_REALTEK_AUDIO_001`
   - `USB\VID_0DB0&PID_CD0E&MI_00`
   - `usb.ids`: vendor-only
   - INF: `Realtek USB Audio`
   - SMBIOS: `MAG X870 TOMAHAWK WIFI`
   - ALSA/OEM: `Realtek ALC4080`

2. `TC_NVIDIA_4060TI_MSI_5174_001`
   - `PCI\VEN_10DE&DEV_2803&SUBSYS_51741462&REV_A1`
   - `pci.ids`: chip + MSI subvendor, no exact board model
   - user/external source: TechPowerUp exact board model

3. `TC_USB_VENDOR_ONLY_NO_GUESS_001`
   - USB vendor exists, product missing
   - expected: no product/model inference

4. `TC_INF_GENERIC_AUDIO_NO_CHIP_001`
   - INF only says generic audio
   - expected: no chip model claim

## Phased Roadmap

### Phase 0: Repo Packaging For Laptop Work

Goal: make the current research and plan available from any machine.

Tasks:

- Commit the two research PDFs.
- Commit this plan.
- Commit current local identity/UI changes.
- Push `master` to `origin`.

Validation:

```powershell
git status --short --untracked-files=all
git log -1 --oneline
```

### Phase 1: Harden Current Local ID Cache

Goal: make the existing `pci.ids`/`usb.ids`/`pnp.ids` layer more testable and provenance-aware.

Tasks:

- Add source metadata fields to generated `data\hwdb` envelopes if missing: source path, SHA-256, commit/date, generator version.
- Add stale-source warning but do not block offline use.
- Add resolver smoke tests for known PCI/USB/PNP IDs.

Suggested laptop-sized task:

- Add `internal\Test-HardwareIdResolver.ps1` with 5-10 fixed IDs and expected confidence labels.

Validation:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\internal\Update-HardwareIdDatabases.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\internal\Resolve-HardwareIds.ps1 'USB\VID_0DB0&PID_CD0E&REV_0005&MI_00' -AsJson
```

### Phase 2: Device Evidence Bundle Schema

Goal: define the stable shape before adding more parsers.

Tasks:

- Add JSON schemas under `schemas\`.
- Add one real cached-device evidence example sanitized if needed.
- Add `internal\Test-JsonSchemas.ps1` if a validator is available, otherwise a basic `ConvertFrom-Json` smoke first.

Suggested laptop-sized task:

- Create `schemas\device-evidence-bundle.schema.json` and `schemas\hardware-match-result.schema.json`.

### Phase 3: Windows DriverStore/INF Index

Goal: extract what Windows actually knows locally without treating driver strings as chip models.

Tasks:

- Parse only active selected-device INF first, not the full DriverStore.
- Extract provider, original INF name, driver version/date, matching hardware ID, install section, service, and string token resolution.
- Store exact hardware-ID match vs compatible/class fallback separately.

Guardrail:

- `Realtek USB Audio` is `Driver Identity`, not `Silicon Model`.

Suggested laptop-sized task:

- Extend or wrap `internal\InfDriverParser.psm1` with one command that resolves a single installed INF by `InfName`.

### Phase 4: ALSA UCM Importer

Goal: add an open-source profile evidence layer for USB audio.

Tasks:

- Clone or fetch selected `alsa-ucm-conf` files into `source\alsa-ucm-conf` only after license/source decision.
- Import `ucm2\USB-Audio\USB-Audio.conf`.
- Normalize regex match groups to source profile names where feasible.
- Store source commit, URL, file path, and profile name.

Regression:

- `0db0:cd0e` must map to `Realtek/ALC4080` as `OPEN-SOURCE-PROFILE`.
- It must not change `usb.ids` result.

### Phase 5: EDID / Monitor Identity

Goal: identify monitors from raw EDID and flag Windows EDID overrides.

Tasks:

- Read `HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\*\*\Device Parameters\EDID`.
- Decode manufacturer, product code, serial, week/year, display size.
- Detect override blocks and display `Raw EDID` vs `OS-effective EDID`.

Guardrail:

- Do not require admin unless a registry path is actually blocked.

### Phase 6: OEM Spec Adapters

Goal: correlate onboard components through official source evidence.

Tasks:

- Start with manual cached spec facts, not broad scraping.
- Add source manifest with URL, fetch date, and short evidence text.
- Only correlate when SMBIOS/baseboard matches.

Guardrail:

- Search snippets and AI text have low confidence until verified on official pages.

### Phase 7: Confidence Engine And TUI Integration

Goal: show richer identity in the UI without hiding uncertainty.

Tasks:

- Implement deterministic scoring from evidence layers.
- Add short right-pane rows, with full detail in a cache/report file.
- Preserve the existing compact `Local Hardware Identity` style.

Suggested UI sections:

```text
Local Hardware Identity
Installed Driver
Derived Identity
Evidence Sources
```

### Phase 8: Optional Online/Package Metadata

Goal: enrich update-driver workflows without turning identity into installer automation.

Tasks:

- Review Microsoft `Wsusscn2.cab` offline scan viability.
- Review TechPowerUp API/licensing for GPU board data.
- Review SDIO/DriverPack index licensing and size.
- Keep download/install flows audit-only until signature/rollback design exists.

## Work-From-Laptop Checklist

When working from the laptop:

```powershell
git pull --ff-only
pwsh -NoProfile -ExecutionPolicy Bypass -File .\internal\Update-HardwareIdDatabases.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\internal\Resolve-HardwareIds.ps1 'PCI\VEN_10DE&DEV_2803&SUBSYS_51741462&REV_A1' -AsJson
pwsh -NoProfile -ExecutionPolicy Bypass -File .\internal\Resolve-HardwareIds.ps1 'USB\VID_0DB0&PID_CD0E&REV_0005&MI_00' -AsJson
```

Before pushing:

```powershell
$files = @(
  'DeviceCheck.ps1',
  'internal\HardwareIdResolver.psm1',
  'internal\Update-HardwareIdDatabases.ps1',
  'internal\Resolve-HardwareIds.ps1'
)
foreach ($file in $files) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors) > $null
  if ($errors.Count -gt 0) { throw "$file parser errors: $($errors.Message -join '; ')" }
}
git diff --check
```

## Immediate Next Implementation Recommendation

Do this next, in order:

1. Add `tests\fixtures\hardware-identity\TC_MSI_X870_REALTEK_AUDIO_001`.
2. Add `internal\Test-HardwareIdentityHarness.ps1`.
3. Add minimal schema for expected match output.
4. Make the current resolver pass the vendor-only part of the fixture.
5. Only then add ALSA UCM importer.

This keeps the project honest: the harness proves incomplete `usb.ids` behavior before enrichment is added.

## Phase 0.1 Implementation Snapshot

Date: 2026-06-06

Added first committed harness foundation:

- `schemas\hardware-source-manifest.schema.json`
- `schemas\device-evidence-bundle.schema.json`
- `schemas\hardware-regression-tests.schema.json`
- `tests\fixtures\hardware-identity\TC_MSI_X870_REALTEK_AUDIO_001`
- `internal\Test-HardwareIdentityHarness.ps1`
- Markdown copies of the two research documents in `docs\`

The first fixture is intentionally not a live resolver. It is a regression contract:

- `usb.ids` must remain `VENDOR-ONLY` for `VID_0DB0&PID_CD0E` when the product row is missing.
- Windows INF evidence may identify the driver display name as `Realtek USB Audio`.
- ALSA UCM / OEM-style evidence may identify `Realtek ALC4080` only as a separate enrichment layer.
- The forbidden claim is `usb.ids exact product Realtek ALC4080`.

Laptop validation command:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\internal\Test-HardwareIdentityHarness.ps1 -AsJson
```

Next implementation step:

1. Replace the fixture-only `usb.ids` simulation with a call into `internal\HardwareIdResolver.psm1`.
2. Add a small `Test-HardwareIdResolver.ps1` smoke suite for PCI/USB/PNP IDs.
3. Only after those pass, add an `Import-AlsaUcmProfiles.ps1` prototype.
