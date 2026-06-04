# Gemini Next Step - GPU Board Model Evidence

Ημερομηνια: 2026-06-03

## Σκοπος

Συνεχισε το `DeviceCheck` exact board-model enrichment χωρις να μπεις ακομα σε download/install drivers.

Η τρεχουσα υλοποιηση κρατα:

- deterministic local ID lookup απο `source\hwdata` -> `data\hwdb`
- PCI layered identity με `VEN/DEV/SUBSYS`
- manual/read-only board-model evidence στο `config\board-model-evidence.json`
- TUI rows για `Board Model`, `Board Evidence`, `Evidence Source`, `Evidence URL`

## Desktop GPU Test Case

Ο desktop GPU ειναι:

```text
MSI RTX 4060 Ti Ventus 2X Black OC 16 GB
```

Hardware ID:

```text
PCI\VEN_10DE&DEV_2803&SUBSYS_51741462&REV_A1
```

Parsed identity:

```text
VendorId     10DE = NVIDIA
DeviceId     2803 = AD106 / GeForce RTX 4060 Ti
SubdeviceId  5174
SubvendorId  1462 = MSI
Revision     A1
```

User-provided reference:

```text
https://www.techpowerup.com/gpu-specs/msi-rtx-4060-ti-ventus-2x-black-oc-16-gb.b11323
```

Do not claim this model from `pci.ids`. `pci.ids` currently identifies the chip and MSI board vendor, but not the exact marketing model.

## What To Verify First

Run:

```powershell
cd D:\Users\joty79\scripts\DeviceCheck
.\DeviceCheck.ps1
```

Then:

1. Select `Display adapters`.
2. Select `NVIDIA GeForce RTX 4060 Ti`.
3. Press `E` if cached evidence is stale/missing.
4. Confirm the details pane shows:
   - `Exact Model : Not in local pci.ids subsystem table`
   - `Board Model : MSI RTX 4060 Ti Ventus 2X Black OC 16 GB`
   - `Board Evidence : UserConfirmedExactPciTuple / 95/100`
   - `Evidence URL : https://www.techpowerup.com/gpu-specs/msi-rtx-4060-ti-ventus-2x-black-oc-16-gb.b11323`

## Next Engineering Steps

1. Add a small CLI helper that reads `config\board-model-evidence.json` and validates duplicate/conflicting PCI tuples.
2. Add `BoardModelEvidence` to cached device evidence output, but keep the source file as the truth for manual entries.
3. Investigate TechPowerUp licensing/API separately before writing any automated adapter. The public licensing page presents GPU database access as licensed/commercial access; do not scrape or redistribute data as if it were open.
4. If an API/license is obtained, implement an opt-in metadata adapter that maps exact PCI tuple or exact TechPowerUp board ID to model name, URL, clocks, memory, and board vendor.
5. Keep confidence labels explicit:
   - `LocalPciIdsExactSubsystem`
   - `UserConfirmedExactPciTuple`
   - `LicensedGpuDatabaseExactTuple`
   - `SearchHintOnly`

## Guardrails

- Do not turn search hints into exact model claims.
- Do not generalize `10DE:2803` to every RTX 4060 Ti board.
- Do not add download/install/update behavior in this layer.
- Keep TechPowerUp evidence read-only unless licensing/API terms are clear.
- Preserve `source\hwdata\pci.ids`, `usb.ids`, and `pnp.ids` in Git because they are runtime-critical source inputs for rebuilding `data\hwdb`.
