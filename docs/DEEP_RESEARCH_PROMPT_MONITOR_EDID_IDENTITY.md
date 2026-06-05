# Deep Research Prompt: Monitor EDID / Local Identity Evidence

Χρησιμοποίησε αυτό το prompt σε ChatGPT Deep Research ή Gemini Deep Research.

```text
We are building DeviceCheck, a Windows PowerShell 7 local hardware identity tool.

Goal:
Create the best possible local/offline monitor identity evidence stack. We already parse IDs like DISPLAY\GSM5BD3 as EDID manufacturer/product codes using pnp.ids, but this is not enough to identify the exact monitor marketing model. We need evidence sources and a confidence model that work without AI guessing.

Current implementation:
- Windows PnP evidence cache includes InstanceId, HardwareIds, CompatibleIds, installed driver/INF, and PnP properties.
- DISPLAY\GSM5BD3 currently resolves:
  - DISPLAY = monitor/EDID enumerator
  - GSM = EISA/PNP manufacturer code, LG Electronics from pnp.ids
  - 5BD3 = EDID product code
- New planned layer reads raw EDID bytes from:
  HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\<DISPLAY_ID>\<INSTANCE>\Device Parameters\EDID
- EDID decoder can extract manufacturer ID, product code, serial, manufacture week/year, monitor name descriptor, physical size, preferred timing, version, checksum, extension count.

Research tasks:
1. Identify all reliable Windows-local monitor evidence sources:
   - Registry EDID path(s)
   - WMI classes such as WmiMonitorID, WmiMonitorBasicDisplayParams, WmiMonitorListedSupportedSourceModes, WmiMonitorConnectionParams
   - monitor INF files in C:\Windows\INF and DriverStore
   - Device Manager/PnP properties that expose monitor model, bus, connector, serial, overrides, HDR/VRR/color data
   - EDID override registry locations and how to distinguish raw monitor EDID from override EDID

2. Identify open-source/offline databases that can map EDID manufacturer/product codes to exact monitor models:
   - Linux hwdb monitor entries
   - linux-hardware.org / hw-probe EDID data, if there are downloadable or API-accessible datasets
   - any EDID/monitor database projects with permissive licensing
   - manufacturer/product code tables beyond pnp.ids
   For each source, provide exact URL, license, update mechanism, data format, and whether it is safe to vendor/cache in a local tool.

3. Explain EDID decoding precisely:
   - manufacturer EISA code encoding
   - product code endian-ness
   - descriptor types 0xFC, 0xFF, 0xFE
   - detailed timing descriptor parsing
   - checksum and extension blocks
   - common traps where Windows DISPLAY\xxxYYYY does not equal a retail model

4. Produce a confidence model:
   - Level 1: DISPLAY ID parsed only
   - Level 2: raw EDID read and checksum valid
   - Level 3: EDID monitor name descriptor present
   - Level 4: monitor INF exact hardware ID or EDID override
   - Level 5: external/offline database exact model match with provenance
   - Level 6: official OEM support/spec page confirms EDID product code or monitor model
   Include recommended labels for DeviceCheck UI and what should never be claimed.

5. Provide implementation recommendations for a PowerShell 7 harness:
   - functions/modules to create
   - test fixtures
   - schema fields for captured EDID evidence
   - privacy/redaction handling for monitor serial numbers
   - what can be tested without admin and what may require elevation

Strict evidence requirements:
- Do not invent mappings.
- For every claim, provide URL, file path, version/date/commit where possible.
- Quote only small relevant snippets.
- Mark inference clearly as inference.
- If a source does not map GSM5BD3 or a sample product code to an exact model, say so.
- Prefer official docs, source code, datasets, and specs over forum snippets.

Deliverable:
Return a structured report with:
- Source inventory table
- Windows-local evidence collection plan
- Offline database import plan
- Confidence scoring model
- DeviceCheck UI row recommendations
- Regression test cases we should add
- Red flags / anti-patterns to avoid
```

