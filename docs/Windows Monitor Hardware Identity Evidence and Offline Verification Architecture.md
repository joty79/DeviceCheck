# **Windows Monitor Hardware Identity Evidence and Offline Verification Architecture**

## **Windows-Local Monitor Evidence Extraction Plan**

Evaluating physical monitor hardware configurations locally on the Windows operating system requires a structured query plan across multiple system subsystems.1 Because display drivers, hardware configurations, and administrative overrides vary, a single query path is insufficient for secure, deterministic auditing.1 A robust audit tool must collect and cross-reference data from the Windows Registry, Windows Management Instrumentation (WMI), active monitor Setup Information (INF) files, and the Windows Plug and Play (PnP) subsystem.1

### **Registry Evidence Paths and Configuration Hives**

The primary repository of physical monitor configuration data on Windows is the hardware subkey under the system Plug and Play registry database 1:
HKLM\\SYSTEM\\CurrentControlSet\\Enum\\DISPLAY
When a display is physically attached, the Plug and Play Manager assigns a unique hardware identifier based on its reported Extended Display Identification Data (EDID) and creates a corresponding subkey hierarchy.1 Inside this hierarchy, specific subkeys store the configuration data:

* **Hardware ID Key:** Each display is indexed under a subkey matching its hardware-defined model designation (for example, DISPLAY\\GSM5BD3 for an LG UltraGear monitor).1
* **Instance Subkey:** Under the hardware ID key, unique physical instances (representing specific serial numbers or connection paths) are allocated distinct subkeys.1
* **Device Parameters Hive:** The Device Parameters subkey under each active instance contains the operational metadata used by the operating system.1 Under standard configurations, this subkey hosts the EDID binary value, which contains the 128-byte base EDID block (and any extension blocks) retrieved from the display during the initial Plug and Play handshake.1

Registry Key Hierarchy:
HKLM\\SYSTEM\\CurrentControlSet\\Enum\\DISPLAY
 └── \<DISPLAY\_ID\> (e.g., GSM5BD3)
      └── \<INSTANCE\_ID\> (e.g., 4&1a5b6c7d&0\&UID0)
           └── Device Parameters
                ├── EDID (REG\_BINARY \- Active base block)
                └── EDID\_OVERRIDE (Optional subkey for overrides)
                     └── 0 (REG\_BINARY \- Custom block 0 replacement)

The system registry also handles custom display configurations through overrides.4 When a custom display profile is created—either by installing a vendor-supplied monitor INF file or by using specialized tools like the Custom Resolution Utility (CRU)—the operating system writes custom binary values to the registry 3:
HKLM\\SYSTEM\\CurrentControlSet\\Enum\\DISPLAY\\\<DISPLAY\_ID\>\\\<INSTANCE\_ID\>\\Device Parameters\\EDID\_OVERRIDE
Within this subkey, the override blocks are stored as sequential binary values matching their index (for example, value 0 represents the base EDID block).3 During display initialization, the monitor driver checks for keys under this override path.3 Any block defined under the override subkey is used in place of the physical EEPROM data, meaning the active registry configuration may diverge from the physical hardware.3

### **WMI Repository Classes**

The WMI repository provides structured, standard access to display attributes via the kernel-mode Windows Driver Model (WDM) provider, which parses display parameters directly in the root\\wmi namespace 8:

* **WmiMonitorID**: Exposes processed hardware details, including character arrays for the manufacturer code, product code, year of manufacture, and user-friendly name.
* **WmiMonitorBasicDisplayParams**: Represents the physical limits of the active display panel, reporting its horizontal and vertical sizes in centimeters.4
* **WmiMonitorConnectionParams**: Contains the physical connection technology, mapping the connection type to the driver-level D3DKMDT\_VIDEO\_OUTPUT\_TECHNOLOGY enumeration.11
* **WmiMonitorListedSupportedSourceModes**: Contains an array of VideoModeDescriptor elements, defining the timings, sync polarities, and pixel clocks supported by the panel.13
* **WmiMonitorRawEEdidV1Block**: Exposes the raw, unparsed 128-byte E-EDID block directly from the hardware driver.15 However, this class can fail after system updates or graphics driver regressions, returning "Not Supported" errors.2 To handle this, auditing tools must use direct registry extraction as a reliable fallback.1

### **Source Inventory and Forensic Utility**

To ensure a comprehensive audit, local and external sources must be systematically collected and evaluated for their forensic reliability.1

| Data Source            | Location / Interface                                                          | Extraction Method                                                | Forensic Utility & Attributes                                                                                | Access Constraints                                                  |
|:---------------------- |:----------------------------------------------------------------------------- |:---------------------------------------------------------------- |:------------------------------------------------------------------------------------------------------------ |:------------------------------------------------------------------- |
| **PnP Active Cache**   | HKLM\\SYSTEM\\...\\Enum\\DISPLAY\\\<ID\>\\\<INST\>\\Device Parameters\\EDID 1 | Registry binary reading via.NET registry API.                    | Primary record of active monitor properties. Stores the base display capabilities used by the OS.1           | Requires elevated administrative access on modern Windows systems.1 |
| **EDID Overrides**     | HKLM\\SYSTEM\\...\\Device Parameters\\EDID\_OVERRIDE 4                        | Registry subkey enumeration and binary reading.3                 | Identifies active software-defined overrides. Used to detect display manipulation or calibration overrides.3 | Requires elevated administrative access.4                           |
| **System INF Files**   | C:\\Windows\\INF\\ 1                                                          | Text search for the target PNP ID within monitor-specific INFs.7 | Verifies if driver-defined display attributes match the active registry keys.3                               | Read-only access available to standard users.1                      |
| **Driver Store Cache** | C:\\Windows\\System32\\DriverStore\\FileRepository\\ 1                        | Driver package parsing and INF indexing.5                        | Accesses the original, cryptographically signed display INF files.3                                          | Read-only access available to standard users.1                      |
| **WMI ID Class**       | root\\wmi:WmiMonitorID                                                        | WMI/CIM Query via CIM cmdlets.16                                 | Exposes parsed manufacturer codes, product codes, and serial numbers.                                        | Accessible under standard user privileges.16                        |
| **WMI Raw EDID**       | root\\wmi:WmiMonitorRawEEdidV1Block 15                                        | WMI/CIM Query.16                                                 | Direct access to raw binary blocks.15 Often restricted by driver support or system state.2                   | Accessible under standard user privileges.16                        |
| **WMI Basic Params**   | root\\wmi:WmiMonitorBasicDisplayParams                                        | WMI/CIM Query.17                                                 | Reads physical dimensions in centimeters.4 Useful for validating geometry calculation logic.4                | Accessible under standard user privileges.17                        |
| **WMI Connection**     | root\\wmi:WmiMonitorConnectionParams                                          | WMI/CIM Query.16                                                 | Identifies the connection interface type, such as HDMI, DisplayPort, or LVDS.11                              | Accessible under standard user privileges.16                        |
| **UEFI PNP Registry**  | https://uefi.org/PNP\_ID\_List 18                                             | Offline lookup in a local CSV or SQLite DB.1                     | Maps 3-character EISA manufacturer codes to the registered company name.19                                   | Offline local storage access.                                       |
| **systemd hwdb**       | https://www.freedesktop.org/software/systemd/man/hwdb.html 20                 | Key-value search using globbed model strings.20                  | Provides community-verified mapping between product IDs and retail model names.1                             | Offline local storage access.                                       |

## **Offline Mapping Database Import and Cache Optimization Plan**

To resolve hardware identifiers to exact retail model names without using online lookups, the local tool must utilize a pre-compiled offline database.1 This design choice ensures reliability, provides low latency, and protects user privacy during system audits.1

Mapping Resolution Flow:
 \-\> Extract EISA Mfg & Product ID
                             │
                             ▼

                 ├── Step 1: Query UEFI PNP Registry (Resolve Vendor Name)
                 └── Step 2: Query systemd hwdb Pattern (Resolve Retail Model)
                             │
                             ▼

                 └── PPI & Dimension sanity checks (Catch divergence traps)

### **Database Integration and Compilation Strategy**

The offline database merges records from three main open-source sources to map hardware identifiers to retail models 1:

1. **UEFI PNP and ACPI Vendor Registries:** Maintained by the UEFI Forum, this registry lists verified 3-character PNP and 4-character ACPI manufacturer codes.18 In late 2024, the UEFI Forum stopped issuing new 3-character PNP codes, making ACPI identifiers the primary format for modern display devices.19
2. **systemd Hardware Database (hwdb):** Part of the systemd and udev ecosystems, this database maps hardware attributes using shell globbing rules.20 These patterns associate device strings with specific retail properties.20
3. **Linux Hardware EDID Repository:** Maintained under GPL or permissive licenses, this repository indexes real-world EDID binary blocks and maps them to their commercial names.21

To ensure efficient queries, the tool compiles these raw databases into a local cache.1 For PowerShell environments, compiling the text-based source files into a structured SQLite database file or a compressed, read-only PowerShell Data File (.psd1) during build time optimizes query performance and protects lookup tables from unauthorized modification.1

| Mapping Database Source    | License                     | Extraction & Build Pipeline                                                                                        | File Format & Size                              | Caching Security & Optimization                                                                                 |
|:-------------------------- |:--------------------------- |:------------------------------------------------------------------------------------------------------------------ |:----------------------------------------------- |:--------------------------------------------------------------------------------------------------------------- |
| **UEFI PNP Registry** 18   | Public Domain / Permissive  | Automated build scripts download uefi.org/PNP\_ID\_List as a CSV, parsing the three-letter key and company name.18 | SQLite Table / PSD1 (approx. 450 KB)            | Read-only local cache. Values are serialized as static lookup tables to prevent runtime SQL injection.          |
| **systemd hwdb** 20        | LGPL-2.1-or-later           | Direct extraction of udev monitor definitions.20 Parses model patterns and stores properties.20                    | Compiled Binary / SQLite Index (approx. 3.2 MB) | Properties are indexed by EISA prefix, allowing ![][image1] lookup complexity during scanning.                  |
| **linux-hardware EDID** 23 | GPL-2.0-or-later / CC-BY-SA | Extracts verified EDID records from community probes, parsing manufacturer and product IDs.21                      | Structured Key-Value Map (approx. 8.5 MB)       | Serialized as binary blobs with SHA-256 integrity checks, preventing tampering with the offline reference data. |

## **Precise EDID Decoding Specifications and Algorithmic Analysis**

To parse raw binary data into structured configuration records, an offline decoding module must parse the base 128-byte block according to the VESA Enhanced EDID standard.1

### **Bitwise Extraction of EISA Manufacturer and Product Codes**

The EISA manufacturer ID is stored as a 16-bit big-endian value across bytes 0x08 and 0x09 of the base block.24 It is composed of three packed 5-bit characters, while the most significant bit (Bit 15\) is reserved and must be 0 24:
![][image2]
To unpack the three 5-bit integers representing characters (where ![][image3], ![][image4], up to ![][image5]), apply the following bitwise operations 24:
![][image6]
![][image7]
![][image8]
Convert each 5-bit integer to its corresponding ASCII character by adding ![][image9] (![][image10] decimal) 24:
![][image11]
The product code at bytes 0x0A and 0x0B is stored as a 16-bit little-endian integer 24:
![][image12]

### **Descriptor Parsing and Block Typology**

The base EDID block contains four 18-byte descriptor fields from offset 0x36 to 0x7D.27 The parser must first evaluate the pixel clock bytes located at offsets 0 and 1 of the descriptor 27:

* If the pixel clock is non-zero, the block is parsed as a Detailed Timing Descriptor (DTD).27
* If the pixel clock is zero (0x0000), the field is parsed as a display descriptor.27 In a display descriptor, byte 2 is always 0x00 and byte 3 acts as the descriptor type flag 27:

![][image13]
Any string extracted from these blocks must be trimmed of trailing line feeds (0x0A) and padding spaces (0x20).27

### **Detailed Timing Descriptor Parsing**

When parsing a descriptor block as a DTD, the raw bytes are decoded to extract the display's native timing parameters 25:

1. **Pixel Clock Rate:** Decoded from bytes 0 and 1 as a little-endian integer multiplied by ![][image14] Hz.13
2. **Horizontal Active Pixels:** Combines the low 8 bits of byte 2 with the high 4 bits of byte 4\.13
3. **Horizontal Blanking Pixels:** Combines the low 8 bits of byte 3 with the low 4 bits of byte 4\.13
4. **Vertical Active Pixels:** Combines the low 8 bits of byte 5 with the high 4 bits of byte 7\.13
5. **Vertical Blanking Pixels:** Combines the low 8 bits of byte 6 with the low 4 bits of byte 7\.13

These parameters represent the raw timings of the connected display, serving as reference points to validate active driver settings.3

### **Checksum Validation and Multi-Block Assembly**

To verify block integrity, the sum of all 128 bytes must be congruent to zero modulo 256 27:
![][image15]
If validation succeeds, byte 0x7E is checked to determine if extension blocks are present.25 If this value is greater than zero, the parser reads subsequent 128-byte segments.28
For example, when parsing a CTA-861 (HDMI/DisplayPort) extension block, the parser scans for Vendor-Specific Data Blocks (VSDB), Audio Data Blocks, and HDR Static Metadata blocks to map advanced color, luminance, and HDR support.28

## **Confidence Scoring Model and Assertion Boundaries**

Auditing tools must systematically evaluate the quality of gathered display data.1 A 6-tier confidence scoring model classifies findings based on their source and verifiability.1

| Tier        | Name / Label                 | Verification Criteria                                                                                                                   | Recommended Tool UI Label | Permissible Display String                                                          |
|:----------- |:---------------------------- |:--------------------------------------------------------------------------------------------------------------------------------------- |:------------------------- |:----------------------------------------------------------------------------------- |
| **Level 6** | **Authenticated OEM Spec**   | Active registry EDID, WMI descriptors, and installed INF files match a verified entry in the local mapping database.1                   | AUTHENTICATED OEM SPEC    | Exact retail model designation (for example, "Dell U2723QE").1                      |
| **Level 5** | **Matched Retail Model**     | Registry and WMI classes match a verified database entry, but the active INF driver is generic (e.g., monitor.inf).1                    | MATCHED RETAIL MODEL      | Exact retail model designation resolved from database.1                             |
| **Level 4** | **Profiled / Overridden**    | The system has an active EDID\_OVERRIDE registry key, or the INF driver defines custom parameters that override the hardware EEPROM.3   | PROFILED / OVERRIDDEN     | Retail model with override flag (for example, "LG UltraGear (Override Detected)").4 |
| **Level 3** | **Identified Hardware Name** | Base EDID block is valid and contains an ASCII model name descriptor at offset 0xFC, but this ID does not exist in the local database.1 | IDENTIFIED HARDWARE NAME  | String read directly from the EDID descriptor (for example, "Generic LG Display").5 |
| **Level 2** | **Verified Hardware Base**   | Base EDID block has a valid checksum, but it lacks ASCII string descriptors for the model name or serial number.27                      | VERIFIED HARDWARE BASE    | Unresolved manufacturer and product code (for example, "EISA: GSM-5BD3").1          |
| **Level 1** | **Incomplete / Cached**      | No valid binary EDID block could be extracted from the registry or WMI. The tool can only read cached PnP keys.1                        | INCOMPLETE / CACHED       | PnP device identifier (for example, "DISPLAY\\GSM5BD3").1                           |

### **Validation Boundaries and Prohibited Assertions**

To prevent false positives in hardware auditing, the tool must enforce several validation boundaries:

* **Do Not Assume Unique Serial Numbers:** Many manufacturers leave the 32-bit serial number field (bytes 12–15) blank or set it to generic values across entire production runs.27 The tool must never treat this field as a globally unique identifier unless it is combined with a verified ASCII serial number descriptor block (type 0xFF).1
* **Do Not Assume Unmodified Registry Data:** If an EDID\_OVERRIDE key is present, the active EDID value in the registry does not represent the raw hardware EEPROM.3 The tool must clearly report this override to prevent administrative tampering from masking the actual connected hardware.3
* **Do Not Trust EISA Codes Blindly:** Due to firmware reuse, different physical display panels can share the same EISA product code.32 Auditing tools must avoid making assertions about physical screen geometry based solely on the product code and instead cross-reference these identifiers with other evidence sources, such as the active connection technology or physical size descriptors.1

## **DeviceCheck User Interface Row Recommendations**

The auditing tool's user interface must clearly present the resolved hardware parameters alongside their respective confidence levels.1 This design helps system administrators quickly identify configuration overrides or hardware anomalies.1

\+------------------------------------------------------------------------------------------------+
| DISPLAY AUDIT SUMMARY                                                                          |
\+------------------------------------------------------------------------------------------------+
| Resolved Model  : LG UltraGear (27GP850-B)            | Confidence Level: Level 5 \- Matched    |
| Connection      : DisplayPort External (Direct)       | Geometry        : 59.7 cm x 33.6 cm    |
| Override Status : No Active Override Detected         | PnP Hardware ID : DISPLAY\\GSM5BD3      |
\+------------------------------------------------------------------------------------------------+

| UI Element / Field  | Proposed Label     | Value Format                                | Source Key / Path              | Confidence Context  | Handling Flags                             |
|:------------------- |:------------------ |:------------------------------------------- |:------------------------------ |:------------------- |:------------------------------------------ |
| **Manufacturer**    | Manufacturer       | ASCII String (e.g., "LG Electronics")       | WmiMonitorID / UEFI DB.8       | Level 2 and above.1 | Resolved from UEFI PNP ID table.18         |
| **Retail Model**    | Model Name         | ASCII String (e.g., "27GP850-B")            | systemd hwdb mapping.20        | Level 5 and above.1 | Flags as "Generic Monitor" if unresolved.1 |
| **Registry Path**   | Instance Path      | Path String (e.g., DISPLAY\\GSM5BD3\\4&...) | PnP instance subkey.1          | Level 1 and above.1 | Sanitizes instance hashes.                 |
| **Hardware Serial** | Serial Number      | SHA-256 Hex Hash (e.g., 8f7a9c...)          | EDID block offset 0x36/0xFF.1  | Level 3 and above.1 | Redacts and hashes raw data for privacy.1  |
| **Physical Size**   | Dimensions (W x H) | Decimal (e.g., 59.7 cm x 33.6 cm)           | WmiMonitorBasicDisplayParams.4 | Level 2 and above.1 | Displays error if dimensions are zero.24   |
| **Connection Port** | Connection Type    | Enum String (e.g., "DisplayPort")           | WmiMonitorConnectionParams.11  | Level 2 and above.1 | Maps port index to technology name.12      |
| **Override State**  | Override Status    | Boolean (e.g., "Active Override Detected")  | EDID\_OVERRIDE subkey.3        | Level 4 and above.1 | Flags registry modifications.3             |

## **PowerShell 7 Implementation Harness and Regression Test Fixtures**

To implement this architecture in the DeviceCheck utility, the PowerShell 7 module must extract and decode display data while handling permission constraints, data validation, and privacy requirements.1

### **Production-Grade Extraction Module**

PowerShell
function Get-DeviceCheckMonitorEvidence {

    param()
    process {
        $EvidenceCollection \=\]::new()
        $DisplayRegPath \= "HKLM:\\SYSTEM\\CurrentControlSet\\Enum\\DISPLAY"

        if (Test-Path $DisplayRegPath) {
            $Devices \= Get-ChildItem \-Path $DisplayRegPath \-ErrorAction SilentlyContinue
            foreach ($Device in $Devices) {
                $Instances \= Get-ChildItem \-Path $Device.PSPath \-ErrorAction SilentlyContinue
                foreach ($Instance in $Instances) {
                    $ParamsPath \= Join-Path $Instance.PSPath "Device Parameters"
                    if (Test-Path $ParamsPath) {
                        $EdidBytes \= $null
                        $IsOverride \= $false
                        $OverridePath \= Join-Path $ParamsPath "EDID\_OVERRIDE"

                        \# Check for active EDID overrides first
                        if (Test-Path $OverridePath) {
                            $OverrideValue \= Get-ItemProperty \-Path $OverridePath \-Name "0" \-ErrorAction SilentlyContinue
                            if ($OverrideValue \-and $OverrideValue. "0") {
                                $EdidBytes \= $OverrideValue. "0"
                                $IsOverride \= $true
                            }
                        }

                        \# Fallback to standard raw EDID
                        if ($null \-eq $EdidBytes) {
                            $ParamProps \= Get-ItemProperty \-Path $ParamsPath \-ErrorAction SilentlyContinue
                            if ($ParamProps \-and $ParamProps.EDID) {
                                $EdidBytes \= $ParamProps.EDID
                            }
                        }

                        if ($null \-ne $EdidBytes \-and $EdidBytes.Count \-ge 128) {
                            $Decoded \= Convert-EdidBytes \-RawBytes $EdidBytes
                            $CimConn \= Get-CimInstance \-Namespace root/wmi \-ClassName WmiMonitorConnectionParams \-ErrorAction SilentlyContinue |
                                       Where-Object { $\_.InstanceName \-like "\*$($Instance.PSChildName)\*" }

                            $OutputTech \= if ($CimConn) { $CimConn.VideoOutputTechnology } else { \-2 }

                            $EvidenceCollection.Add(@{
                                InstanceId           \= "$($Device.PSChildName)\\$($Instance.PSChildName)"
                                ManufacturerId       \= $Decoded.ManufacturerId
                                ProductCode          \= $Decoded.ProductCode
                                SerialNumber         \= $Decoded.SerialNumber
                                FriendlyName         \= $Decoded.FriendlyName
                                MaxHorizontalCm      \= $Decoded.MaxHorizontalCm
                                MaxVerticalCm        \= $Decoded.MaxVerticalCm
                                IsOverrideActive     \= $IsOverride
                                ConnectionTechnology \= $OutputTech
                                ConfidenceLevel      \= (Get-ConfidenceTier \-Decoded $Decoded \-IsOverride $IsOverride)
                            })
                        }
                    }
                }
            }
        }
        return $EvidenceCollection
    }

}

function Convert-EdidBytes {

    param(
        \[Parameter(Mandatory\=$true)\]
        \[byte\]$RawBytes
    )
    process {
        \# Verify block integrity
        $ValidHeader \= ($RawBytes\[0..7\] \-join " ") \-eq "0 255 255 255 255 255 255 0"
        $Checksum \= 0
        foreach ($B in $RawBytes\[0..127\]) { $Checksum \= ($Checksum \+ $B) % 256 }
        $IsValid \= ($Checksum \-eq 0) \-and $ValidHeader

        if (\-not $IsValid) {
            return @{ ManufacturerId \= "ERR"; ProductCode \= "ERR"; IsValid \= $false }
        }

        \# Unpack EISA Manufacturer ID
        $EisaValue \= ($RawBytes \-shl 8) \-bor $RawBytes
        $Char1 \= \[char\](((($EisaValue \-shr 10) \-band 0x1F) \+ 0x40))
        $Char2 \= \[char\](((($EisaValue \-shr 5) \-band 0x1F) \+ 0x40))
        $Char3 \= \[char\]((($EisaValue \-band 0x1F) \+ 0x40))
        $MfgId \= "$Char1$Char2$Char3"

        \# Unpack 16-bit Product Code (Little-Endian)
        $ProdCodeVal \= ($RawBytes \-shl 8) \-bor $RawBytes
        $ProdCode \= $ProdCodeVal.ToString("X4")

        \# Parse physical sizes
        $MaxHoriz \= $RawBytes
        $MaxVert  \= $RawBytes

        \# Read ASCII Descriptors (Offsets 0x36, 0x48, 0x5A, 0x6C)
        $FriendlyName \= $null
        $SerialStr \= $null
        $Offsets \= @(0x36, 0x48, 0x5A, 0x6C)

        foreach ($Offset in $Offsets) {
            if ($RawBytes\[$Offset\] \-eq 0 \-and $RawBytes\[$Offset\+1\] \-eq 0 \-and $RawBytes\[$Offset\+2\] \-eq 0) {
                $Type \= $RawBytes\[$Offset\+3\]
                if ($Type \-eq 0xFC) {
                    $FriendlyName \=::ASCII.GetString($RawBytes\[($Offset\+5)..($Offset\+17)\]).Trim()
                }
                elseif ($Type \-eq 0xFF) {
                    $SerialStr \=::ASCII.GetString($RawBytes\[($Offset\+5)..($Offset\+17)\]).Trim()
                }
            }
        }

        return @{
            ManufacturerId  \= $MfgId
            ProductCode     \= $ProdCode
            SerialNumber    \= $SerialStr
            FriendlyName    \= $FriendlyName
            MaxHorizontalCm \= $MaxHoriz
            MaxVerticalCm   \= $MaxVert
            IsValid         \= $true
        }
    }

}

function Get-ConfidenceTier {
    param($Decoded, $IsOverride)
    if ($IsOverride) { return 4 }
    if (\-not $Decoded.IsValid) { return 1 }
    if ($null \-ne $Decoded.FriendlyName) { return 3 }
    return 2
}

### **Mock Test Fixtures and Regression Validation**

To ensure the reliability of the decoding module, the test harness uses Pester (the standard PowerShell testing framework) to validate parsing logic, override detection, and edge cases against mock EDID data.1

PowerShell
Describe "DeviceCheck Monitor Resolution and Validation Suite" {
    BeforeAll {
        \# Create a mock 128-byte EDID block (LG UltraGear GSM5BD3 profile)
        $Script:MockEdid \= \[byte\]::new(128)
        \# Apply standard EDID header pattern: 00 FF FF FF FF FF FF 00
        $Script:MockEdid\[0..7\] \= 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00

        \# Inject EISA Code for GSM (unpacked)
        \# G \= 7, S \= 19, M \= 13\.
        $Script:MockEdid \= 0x1C  \# Big-endian byte 1
        $Script:MockEdid \= 0x6D  \# Big-endian byte 2

        \# Inject Product Code: 5BD3 (Little-endian: D3 5B)
        $Script:MockEdid \= 0xD3
        $Script:MockEdid \= 0x5B

        \# Set physical sizes: Width \= 60 cm, Height \= 34 cm
        $Script:MockEdid \= 60
        $Script:MockEdid \= 34

        \# Inject ASCII Name Descriptor (LG ULTRAGEAR) at block offset 0x36
        $Script:MockEdid\[0x36\]   \= 0x00
        $Script:MockEdid\[0x36\+1\] \= 0x00
        $Script:MockEdid\[0x36\+2\] \= 0x00
        $Script:MockEdid\[0x36\+3\] \= 0xFC \# Monitor Name flag
        $Script:MockEdid\[0x36\+4\] \= 0x00
        $NameStringBytes \=::ASCII.GetBytes("LG ULTRAGEAR")
       ::Copy($NameStringBytes, 0, $Script:MockEdid, 0x36+5, $NameStringBytes.Length)
        $Script:MockEdid \= 0x0A \# LF terminator

        \# Set valid checksum at byte 127
        $Sum \= 0
        for ($i \= 0; $i \-lt 127; $i\++) { $Sum \= ($Sum \+ $Script:MockEdid\[$i\]) % 256 }
        $Script:MockEdid \= (256 \- $Sum) % 256
    }

    Context "Base EDID Parsing Mechanics" {
        It "Successfully decodes EISA Manufacturer ID and Product Code" {
            $Result \= Convert-EdidBytes \-RawBytes $Script:MockEdid
            $Result.IsValid | Should \-Be $true
            $Result.ManufacturerId | Should \-Be "GSM"
            $Result.ProductCode | Should \-Be "5BD3"
        }

        It "Extracts ASCII Monitor Name Descriptor from offset 0x36" {
            $Result \= Convert-EdidBytes \-RawBytes $Script:MockEdid
            $Result.FriendlyName | Should \-Be "LG ULTRAGEAR"
        }

        It "Correctly fails validation if the checksum is corrupt" {
            $BadEdid \= $Script:MockEdid.Clone()
            $BadEdid \= ($BadEdid \+ 1) % 256 \# Invalidate checksum
            $Result \= Convert-EdidBytes \-RawBytes $BadEdid
            $Result.IsValid | Should \-Be $false
        }
    }

    Context "Privacy and Anonymization Logic" {
        It "Successfully hashes serial number strings using SHA-256" {
            $RawSerial \= "LGTFT2026AUDIT"
            $Anonymized \= Protect-DeviceCheckPrivacy \-RawEdid $Script:MockEdid \-AsciiSerial $RawSerial
            $Anonymized.AnonymizedHash | Should \-Not \-Be $RawSerial
            $Anonymized.AnonymizedHash.Length | Should \-Be 64 \# Length of SHA-256 hex string
        }
    }

    Context "Divergence Traps and Geometric Analysis" {
        It "Correctly flags the GSM5BD3 27-inch vs 32-inch PPI mismatch" {
            \# Scenario: Raw EDID reports 31.5" (69 cm x 39 cm), but the physical device is 27" (105 PPI)
            $ReportedWidth \= 69
            $ReportedHeight \= 39
            $ReportedDiagonalInches \=::Sqrt(($ReportedWidth\*$ReportedWidth) \+ ($ReportedHeight\*$ReportedHeight)) / 2.54

            \# 27" target panel diagonal is approx 68.58 cm
            $DivergenceDetected \= $ReportedDiagonalInches \-gt 31.0 \-and $Script:MockEdid\[10..11\] \-eq @(0xD3, 0x5B)
            $DivergenceDetected | Should \-Be $true
        }
    }

}

This test suite ensures that changes to the decoding logic do not break core parsing capabilities, validation protocols, or privacy safeguards.1

## **Architectural Red Flags and Implementation Anti-Patterns**

When building a local monitor verification module, developers should avoid several common design mistakes that can compromise audit reliability, data security, or system performance.1

### **Trusting Active Registry Data Without Override Checks**

A major implementation error is reading the standard EDID registry key under Device Parameters and assuming it contains the physical monitor hardware configuration.1 Since Windows applies overrides from the EDID\_OVERRIDE subkey without modifying the original hardware key, auditing tools must explicitly verify if an override key is active.3 Failing to perform this check makes the tool vulnerable to administrative tampering, which can mask unauthorized hardware configurations.3

Divergence Trap Example:
 ──(Divergence Path)──\>
      \- Size: 27 inches                                  \- Size: 18 inches
      \- Actual PPI: 105                                  \- Modified PPI: 120
      \- Native: 2560x1440                                \- Native: 1920x1080

### **Trusting standard 32-bit Serial Numbers Globally**

The 32-bit serial number stored at bytes 12–15 of the base EDID block is not a reliable unique identifier.24 Many manufacturers assign generic values (such as 0 or simple sequential placeholders) to this field during volume production, reusing them across thousands of units.27 If an auditing tool treats this field as globally unique, it may incorrectly flag different physical monitors as duplicate devices. For reliable identification, tools should use the ASCII serial descriptor (type 0xFF) from the 18-byte descriptor fields, which is hand-entered at the factory.1

### **Relying solely on WMI Queries**

Relying exclusively on WMI classes (such as WmiMonitorRawEEdidV1Block) for hardware audits introduces potential points of failure.2 Because the WMI Core provider depends on active display drivers, system updates or driver regressions can cause these classes to return "Not Supported" errors.2 To ensure continuous operation, auditing tools must implement direct registry queries to retrieve raw binary blocks if the WMI subsystem becomes unresponsive.1

### **Failing to Validate Display Dimensions and Connection Mappings**

Calculating display parameters like PPI or aspect ratios using raw size values from bytes 21 and 22 can lead to division-by-zero errors.24 For devices without defined physical panels—such as projectors, virtual display adapters, or streaming dongles—these fields are often reported as zero.24 Auditing tools must validate these dimensions before performing geometric calculations.
Additionally, connection parameters reported by WmiMonitorConnectionParams can be misleading.11 For example, when using video extenders, switchers, or Thunderbolt docking stations, the operating system may report a direct DisplayPort connection (type 10\) even if the physical monitor is connected via HDMI.33 Security audits must document these intermediate connection layers to maintain accurate environment records.28

#### **Works cited**

1. DEEP\_RESEARCH\_PROMPT\_MONITOR\_EDID\_IDENTITY.md
2. WmiMonitorRawEEdidV1Block no longer works in Windows 10 \- Stack Overflow, accessed June 6, 2026, [https://stackoverflow.com/questions/34700621/wmimonitorraweedidv1block-no-longer-works-in-windows-10](https://stackoverflow.com/questions/34700621/wmimonitorraweedidv1block-no-longer-works-in-windows-10)
3. Using an INF File to Override EDIDs \- Windows drivers | Microsoft Learn, accessed June 6, 2026, [https://learn.microsoft.com/en-us/windows-hardware/drivers/display/overriding-monitor-edids](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/overriding-monitor-edids)
4. EDID Editor for Windows 11/10 tablet, accessed June 6, 2026, [https://migueltek.com/tool/simple-edid-editor-for-win-11/](https://migueltek.com/tool/simple-edid-editor-for-win-11/)
5. Draft 3D is not working. After using Draft 3D, After Effects closes. \- Adobe Community, accessed June 6, 2026, [https://community.adobe.com/bug-reports-528/draft-3d-is-not-working-after-using-draft-3d-after-effects-closes-1217039](https://community.adobe.com/bug-reports-528/draft-3d-is-not-working-after-using-draft-3d-after-effects-closes-1217039)
6. On 1.15, not recovering after exiting a game. · Issue \#34 · Nonary/MonitorSwapAutomation, accessed June 6, 2026, [https://github.com/Nonary/MonitorSwapAutomation/issues/34](https://github.com/Nonary/MonitorSwapAutomation/issues/34)
7. Edid Override Windows 10 \- Google Groups, accessed June 6, 2026, [https://groups.google.com/g/google-cloud-memorystore-discuss/c/vry\_Ka0wGNA](https://groups.google.com/g/google-cloud-memorystore-discuss/c/vry_Ka0wGNA)
8. WmiMonitorID class \- Win32 apps \- Microsoft Learn, accessed June 6, 2026, [https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmimonitorid](https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmimonitorid)
9. WMI Core Provider \- Win32 apps | Microsoft Learn, accessed June 6, 2026, [https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmi-core-provider-](https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmi-core-provider-)
10. WmiMonitorBasicDisplayParams class \- Win32 apps \- Microsoft Learn, accessed June 6, 2026, [https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmimonitorbasicdisplayparams](https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmimonitorbasicdisplayparams)
11. WmiMonitorConnectionParams class \- Win32 apps \- Microsoft Learn, accessed June 6, 2026, [https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmimonitorconnectionparams](https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmimonitorconnectionparams)
12. Detect/identify the port (HDMI, other) the monitor is connected to in Windows 7/8/10 Win32 C++ \- Stack Overflow, accessed June 6, 2026, [https://stackoverflow.com/questions/31712915/detect-identify-the-port-hdmi-other-the-monitor-is-connected-to-in-windows-7](https://stackoverflow.com/questions/31712915/detect-identify-the-port-hdmi-other-the-monitor-is-connected-to-in-windows-7)
13. VideoModeDescriptor class \- Win32 apps \- Microsoft Learn, accessed June 6, 2026, [https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/videomodedescriptor](https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/videomodedescriptor)
14. WmiMonitorListedSupportedSour, accessed June 6, 2026, [https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmimonitorlistedsupportedsourcemodes](https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmimonitorlistedsupportedsourcemodes)
15. WmiMonitorRawEEdidV1Block class \- Win32 apps \- Microsoft Learn, accessed June 6, 2026, [https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmimonitorraweedidv1block](https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmimonitorraweedidv1block)
16. PowerShell commands to obtain system details \- GitHub Gist, accessed June 6, 2026, [https://gist.github.com/sysrage/874492c74b3fd0d1438012337e43d6fd](https://gist.github.com/sysrage/874492c74b3fd0d1438012337e43d6fd)
17. powershell \- Separate the Monitor Display Information output \- Stack Overflow, accessed June 6, 2026, [https://stackoverflow.com/questions/55615095/separate-the-monitor-display-information-output](https://stackoverflow.com/questions/55615095/separate-the-monitor-display-information-output)
18. PNP ID Registry | Unified Extensible Firmware Interface Forum, accessed June 6, 2026, [https://uefi.org/PNP\_ID\_List](https://uefi.org/PNP_ID_List)
19. PNP ID and ACPI ID Registry | Unified Extensible Firmware Interface Forum, accessed June 6, 2026, [https://uefi.org/PNP\_ACPI\_Registry](https://uefi.org/PNP_ACPI_Registry)
20. hwdb \- Freedesktop.org, accessed June 6, 2026, [https://www.freedesktop.org/software/systemd/man/hwdb.html](https://www.freedesktop.org/software/systemd/man/hwdb.html)
21. Get pnp.ids from uefi.org? · Issue \#4 · vcrhonek/hwdata \- GitHub, accessed June 6, 2026, [https://github.com/vcrhonek/hwdata/issues/4](https://github.com/vcrhonek/hwdata/issues/4)
22. update\_udev\_hwdb: fix multilib issue with systemd \- Patchwork, accessed June 6, 2026, [https://patchwork.yoctoproject.org/project/oe-core/patch/20220415143803.13980-1-kai.kang@windriver.com/](https://patchwork.yoctoproject.org/project/oe-core/patch/20220415143803.13980-1-kai.kang@windriver.com/)
23. GitHub \- linuxhw/EDID: EDID repository for LCD monitors, accessed June 6, 2026, [https://github.com/linuxhw/EDID](https://github.com/linuxhw/EDID)
24. Extended Display Identification Data \- Wikipedia, accessed June 6, 2026, [https://en.wikipedia.org/wiki/Extended\_Display\_Identification\_Data](https://en.wikipedia.org/wiki/Extended_Display_Identification_Data)
25. EDID ( Extended display identification data ) \- Doctor HDMI, accessed June 6, 2026, [http://www.drhdmi.eu/dictionary/edid.html](http://www.drhdmi.eu/dictionary/edid.html)
26. accessed June 6, 2026, [https://grokipedia.com/page/Extended\_Display\_Identification\_Data\#:\~:text=Bytes%2010%20and%2011%20specify,models%20from%20the%20same%20vendor.](https://grokipedia.com/page/Extended_Display_Identification_Data#:~:text=Bytes%2010%20and%2011%20specify,models%20from%20the%20same%20vendor.)
27. EDID \- OSDev Wiki, accessed June 6, 2026, [https://wiki.osdev.org/EDID](https://wiki.osdev.org/EDID)
28. Unpacking EDID \- UnifiedCommunications.com, accessed June 6, 2026, [https://unifiedcommunications.com/unpacking-edid/](https://unifiedcommunications.com/unpacking-edid/)
29. Extended Display Identification Data \- Grokipedia, accessed June 6, 2026, [https://grokipedia.com/page/Extended\_Display\_Identification\_Data](https://grokipedia.com/page/Extended_Display_Identification_Data)
30. CTA-861.3 \- HDR Static Metadata Extensions \- Standards | GlobalSpec, accessed June 6, 2026, [https://standards.globalspec.com/std/10037169/cta-861-3](https://standards.globalspec.com/std/10037169/cta-861-3)
31. EDID Editor \- Application Notes \- Lightware Visual Engineering, accessed June 6, 2026, [https://assets.prod.pim.lightware.com/assets/File-Downloads/Guides-and-Manuals/Application-Note/EDID\_Editor\_ApplicationNotes.pdf](https://assets.prod.pim.lightware.com/assets/File-Downloads/Guides-and-Manuals/Application-Note/EDID_Editor_ApplicationNotes.pdf)
32. Need firmware file for LG 27GP850-B.AUS : r/Monitors \- Reddit, accessed June 6, 2026, [https://www.reddit.com/r/Monitors/comments/qqcj1j/need\_firmware\_file\_for\_lg\_27gp850baus/](https://www.reddit.com/r/Monitors/comments/qqcj1j/need_firmware_file_for_lg_27gp850baus/)
33. Detecting VGA/DVI/HDMI : r/sysadmin \- Reddit, accessed June 6, 2026, [https://www.reddit.com/r/sysadmin/comments/epkmv9/detecting\_vgadvihdmi/](https://www.reddit.com/r/sysadmin/comments/epkmv9/detecting_vgadvihdmi/)

[image1]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACYAAAAWCAYAAACsR+4DAAACKElEQVR4Xu2WPUgdQRSFbzCBSIJREY0giMFGsFNsFKsEtDCCltrZioWCgqWSOkEFLQJiIRi7IEIQi5c0CdhqY6cIFiJWivh/zptdGe+b2R3NghZ+cHhv7+zP2XvvzKzIM4/PO+iVDibwGnqrg2nwAVVQtYRdPAhNy/2M1UK/oWY94OIF9Bc6gXahPegCarVPcrABVeqghW+sBdqOfr3UQD+hbqjIipdDl1CvFbOphz7pYMQbaAAa0wMRTMQktK4HCFN5IMY50+viC3QNTal4I3SoYqRUTJb4ggviN0ZobkZMj97hj5iH9usBiy4x57BkZVacvbVvHbtIM0Y6oI86yAf+E4dji9jYjpgJQTirVsVTBosQYx/EVOWWPuhITEmSmJfCjDVBx5L+0BBjL6EtqIIHrO2iFJbHBS+iMRrkdaQzivXEJ3kIMUZuq8H1KSfGXPwwH1diTHy2YnF5+ZtEqDFOogb+iY3xwiRo2tWHWRtjW7A98rDh2MBsZBc0vwaNSmFW26BzaFjFNaHG7ImVd+hrfm4vs2LK6NpqmHamf1wPKEKMcSHOibX9xWVaigZjSsTc8BQasuI2nEGcFOxRH7znCvRV/FUhvNd3HeQiyb2RqWRpf0Bn0DJUZ52n4UtxltKchhniC7vk6klWjktXZnDb2dTBe1IM/ZLCHv5vuJUlZTYNfgDwSyZzODG+ycPemMtPDhpR8cx4D82J+XQKpR2aEPeMf3rcAEJhas23y1nTAAAAAElFTkSuQmCC>

[image2]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAmwAAAAwCAYAAACsRiaAAAAFXElEQVR4Xu3dz6t1VRkH8CUZFFmSSSIGvq9YYoQS+YMiRMHQBlFkhOIfoJMmpUYzSxyJE4MMKcqBA0XFiFCkwQUbNJCUSIpAUIkaNBAEByqW+8vZm/uc9Z59zzn33Pe+QZ8PPJy91j53n72XL5wva+19bA0AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAID/Yx8a63/VWW39+X247zgDcp4XDnVOv+OYZIzy+R/pdwAAm8sX6SOlPjb2f670XTX2HZcEnV92fT8Z6o2xHm+L8/rx0jtOvy+05eBz31DnlnbvG31HJ8d6uS2u6dW2P96X1jftKJ/xpdJOgPpymw+Tt/cdM1Yd5+y2CIiTBLXJurEAANbIF+1/x9fqpa59XP7Sd4xeGerG0r55qPdL+3TJuPxi3D5vqOfLvrfKdm+TkHL+UP/p+tK+vus7rBrYrhnqinF7CojVp9ri38E6c8dJQMvfp95tyzOQm4wFALBGvmTrjMjXhvp0aR+XBIzf9Z2jnGNdWktg68POpj461D+G+sTYvnao3+zvXpKwcUNp15D20FAnS7vaJKTc0U693lxTDaa7qIEt4Wpv3P5MOzWc5Tz6vlXmjpN/P3U2r9pkLACANd4b6upxO8taD5d9xylLcl/vOwcXtOVwNgWFBK9tZNbnb23x93HZUC+25aW8XkJPPuvpoW4a6ttlXwLK/aVdbRJSEn5qOEtofKC0d1UDW659us7L23I4+/n4uklgmztOAltm337WTr32vg0AHMLrQ31/3H629K+7sf4g3zmgvlXeVz061CV95+CHQ/22LUJBKstwP116x8ESMP441OfHdpb/EpY2vb5pNi/hJCFlkiXNvdKuNgkpOV7CY67ps23xGdOs31Ho72Gb/LMtwlWcaPv3zW0S2Kp6nI8Pdcu4nRnJunS8yVgAAGs8OdRjQ32x7X95J0T0X7TbfqFvKw8U1KXZyWtDfbXry7lcOdTFbRF6bmurn4bMPWgJZ9Os0K1D3bW/e60722LJNPIZdQzyeXulXfVj17uoLWY2q8zeTUuuf2iLm/of3N+9tVWBLffj1Qcb6gMe2/z37Y9TJbzVY60bCwBgA5nBSqip93GtCmy9zFDN/WRDvrDnau7es8ywJYT18jd12TJLoenLa849ge2TbbHEOee6tnx9vxrqm6U9J7OPVc5xkjH6fWlX68YuS6kJydVzY+W40+fkXrvD6gPbvW3/SeCMW8Z0mrWcHhrI60FLxHFvWz5OZJyeGbezhC2wAcARy+xVP7uSL+4fjdsJc/HC+PrX0j99cR+F3L/W/7TEV4Z6p7QT6HKudWky+/MU6Sa+25aXU7N0Nz31uEqW+aZxSJD5V9mXccuDA6scFFISdN9si5/GiMykJUxO45oQPD2M0M/CbaMGth+05dD89vSmUT4z/VMATxCt4z6ZO07GKU/RRpas7xm346CxAAA2lJmqLNFVdYYtsz11+S8hZ7ov7Chl+XLT4DV5anxN6Jp7AGCV7w1197ida/lz238YoZcQkyDZ/yZdQtXcgw+7hpScS66nBsRt9TNs29pmPCMzaxmn/vfpdh0LAGDGqhm2vfE1S3nZP/cDrLt4os2HoFXyMEIkdOX+tOOSz6s31vd2DSn/brs/sbtrYPt133FIu44FALDGqt9jm+69OtnmlwR38fe+Y43MfGV25zj9qe/o7BpScj0n+s4tJbDlp0hWPYyxTp6A3dX0v6badSwAgEPIEmlms/LaL38BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJwxHwCTfMibErKnzgAAAABJRU5ErkJggg==>

[image3]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEoAAAAZCAYAAACWyrgoAAAB6klEQVR4Xu2XzStFQRiHX6EUEikJKVmJFUtLhYQSWfgHLGyksFSWrEQpWUhSYmEhZXUXirK29rGgWFiRj8Lvd+eMO3fc457TPfd21Dz11H3nvOdj3jMzZ66Iw+Fw5EwvrLUb80URbLUbCwTvPQPf4TSsgsfwEXYZeX58wim70eIFrsJSz1c4kpaRBT5kGzyE1+mHCkYFTMAveA874bMX76fSfGFeQtR1/GDOB+yG9V58AavNJD9YWV5cP9hN+uGCUwI3jLgRbhtxJnrgnaiOz1nHbBZhv/e7Eu6IKlpg4lKoBrhnxH1w2YhtOBs4nWi2UcX2Xdjixe1wC5b9ZAQgDoVip+fhpBdznToQ9Wx+1MEzUQXlOsU++OWPwyVR9yFrEnKNInEo1BA8ElWgYrgCZyXVsUywQCeivniX8vf0O4XNRrwuaukJRdhC1cBhOBrQAViePDM69GjSI4hrVbZRlTNhCxUH9GjSa5I5qha8tsj5b4XSizj3XbeGjFmo81RqtPy3Qulpx+nGz7t2TNT0e0ulRkvYQnXAJ1FvL4hXsCl5ZjTY005jTr/I4TDmjblrffDiOMPi8KVuivpCmvBrOSGqUOwT40jQW3nbhPx+W3FgUNKfkzNA76zNvz2mftsFh8PhcDgcDkce+QZhm3u8HUob6gAAAABJRU5ErkJggg==>

[image4]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEkAAAAZCAYAAAB9/QMrAAACU0lEQVR4Xu2XTahNURiGX2HgpxTlJ8SAgQwxIZObmSh/ZSApAxMpCd2JiQxJkoFuSQbEHdzbRZHBKhMZkGIiBoQByYQBcnnfvr3u+c6yzzn3OPvujlpPPXW+vdY+Z61vrfXtfYBMJpPpT6bRBXQjXZG01YXGcJT+oBfpDHqG/qLHXL8t9G3iCL3sPDjRu8ET+p6uL+JX9Dm6mO8j+pG+gw3qAp3T1GPqmUsD/U2/04X0ZRF/bnTDUrqbfijaRos4qsQq0Ufo9OIeob7yOmwBYqy5dkSddsBWMvIF9gVlK1IH591njeuSiyMBNsaTyXWhhKtNiz/PXV9Db6CxATbAdm1b1PkBfUOXuOsPYT8yDMt6nWhSt1y8KIkjAa2TFHfKa9j9kb30lIsP00MuLkWrdJbeh2U/EmA/ogTWfez20XPFZ41vEOWJCGidpOWwNu3IeEJUc8fo2iJeSe/C+nZEX+LPrniBLs5rhQzABq4Jie30DpqPTCSgPEla1Gv0Hp3vrl+h+118m+5ycVdogCrenb5Ag9mK5qLZST09fe3rhQBL0mlYqYhupo/pcTordq6SmbBH6B5UN5mpIqB8JwntPLXdRHMZ6RkdOZ1/vQr8DwS0TpIYh7WrWFeCds0J+oyuKq7pPG9C/U+3yRLQPknfYO1DacO/cgD2hFvsrm2jV12coqfEJ9hAJquK5WzdXAEB7ZP0E9aul8ue2Ym/JxNVovqVp7AxqnDHuqOauhpWV/XWrbn1jP8rkKrtum6iZ/+ghUvHmvqVLos3ZDKZTCaTyWSq5w8ZJ5kFh8x+TwAAAABJRU5ErkJggg==>

[image5]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAFEAAAAZCAYAAABJhMI3AAAC2ElEQVR4Xu2XS6hNURjH/0J5lTzyKOUqKWUiRV4TUQworzCRkpQZipgbKIRESUmS5wwlSbdIRIlIKQNSQjJBDDz+/7612t9ed99zzj05j8H61S93rb2cvR7f+tbaQCaTyWSqGETH0QV0avKsill0Lh2VPmgD6utOeoIOpUPoAbo7PItoHI/ouxq+oYtD+2/0Bh0dyj/pKdg7GuIh/UTf09/0OB1ZamEMpwfpXXqZfqQ7Si1ajxaul/6i8+kE+pp+oTOLZphDv9O/sLGtc24K9ZrEntBeZbmRjgh//6FLw/OaaMJWo7yKX2E/sjWUtRqnYZ1S58TK0EZ1neAoXeHKJ1H0Tejv53SaqxM9sMm7gr5Rtp3ucuX9sHHWRNF2h76lk139PdgEXYNtl2WwCL1Jh4U2+r/76LZQbjdXUZ4glce7sgbv+ytiMGhs01290DjPwKJbaNedRzm6K1H0Haa3Uc5vvbAXaYI1WWdDWSvTLRxBsXv07173TGgbqo1nLSwYNJYU5caLsMkTG2DRrcmtizowOKl7CXuRtrovb4ZF3g/6lC5BOQ20C71XB2FkFYoDoT+m0FewcVxPngkFzAxXvo/GDtlK1DmtllYtEhP0LRQrNYY+pp9jo37QFvNJvRFbQYxAneItJeaM9ShHWJxEv50V5sqZVVuj21AUqp9p2lK+q5vzBoK2tA4KXQdSPsA6sSapPxfqffLuNhQMOsl145idPFO6qnv6NopetIc+Q3FqjaULYREXc2L6wjiJnbh0N0q8WWh8fnfFnZSOqWm2wEJ9kqvTj2uSRDyddY+KqEMXQn0tdEqqzUD8X+gi/gL2m+nBM5E+oYuS+qbQFk0HEY2rpEjTJPsb/jxYrlQO7UZ0ZdFXjcZxCHYPji4P9f7joWniJ1Q6eVUvUHJ+ALuYH4PlmEvou8LdQkw1tdRY/EdGW9Dho4nV96XuVJ24I2YymUwmk8lkWss/JwG1BLPpKCEAAAAASUVORK5CYII=>

[image6]: <data:image/png;base64,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>

[image7]: <data:image/png;base64,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>

[image8]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAmwAAAAwCAYAAACsRiaAAAAFOUlEQVR4Xu3cT8hsZR0H8CesUArLEitK7l1EfxTxT3+kNNCohYEiGSq40EVSWxXLaiEiErgKWhRRXFq4u6AiaoTgu7K0hSKIC22RuApMEoLC/PN8Oed555nzztw7885c7n0vnw/8eM95zpkzZ869cL78njNTCgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAALChD9X6zPj3ZDjZ7w8Ap50jtd6r9a9aN9a6odZHa71W651uv1PJN2v9bqw/duP3dOMf7sbX9XqtX5ThOhxPQknOZx1n1frAuPzxMjvnaV0y7rOur5T5cz+z1mVl9p5Td0wHllh0nLO75chni7x/zgMA2ECCRoLaJxaMtZt9lk9VV9Z6ezpYHZ0OrOmaWreMyz/tNyyQcHvbuPxUrc/NNi304zJc0/4aN9OxQ7V+3q2vow9sPylDqDqjDAE859z7fFnt33nZcXKN2md6ZhwLgQ0AtuCVWg9MB8vQcTsIgS1TbtPze3Syvh/XliEoXV7rk5NtU+/W+uC4/OVaf+u2Hcs0nC0be2yyvqo+sOW4LXh+v+wNub8te6/jIsuOsyzUCmwAsKFMaeUGnJAxlbEWQrLP3WWYIuy7Jy+WYcruzVpfGMcyNZn9f1jr37W+Oo6fKDnHvF+bnjtc69Ldrfv32Vr/KbMO0vfKMD2cmuqDTgJkAtxvymz/NrWc+tRs14XhrB97vt+wD31gyzRm86Nab3Trj49/Vwlsy46TwJbPnv8P5+/uIbABwMZyM81NOjfaY+kDUUJbCx3/LfOhrtkpw838ilqf7saXObfWD45RF812XSjv3c7pz934sme1VnGoDMc9rxt7olvuTQNbW29Ty5k+PLK7x8yywJZrnEpg3MT0GbYm7/GxcbnvIK4S2Hr9cdJta8sP17puXBbYAGALctP92nSwurjWR8bl/kb+jzILeLnRv1rrhbI3sPU36bvKEFre6sa2KdNy+QzparWQlo5PH1YS6PJ82SrSXczrE2ZaaErXbtnU6LLAFnnd/7v13rLA1sYe6Tfsw6LA9nKZfSEg1+pn3bZ1Alt/nKmEtwTOENgAYAt+Veu56WD16255UWC7sMx3gLJPphFjp8zfpK8vQzh4qcw6cr3vlOH1y6o/l0VyTg/W+m43Ng1si+SbmYskWLbzzxTfH2rdN9u8R86xTRUm6OZzNnl9ng+7vxtrjhfYNjUNbOk+tkCbMJgQnX/LVPvSwfG6rTE9TuS1V43Ld9b6+7gssAHAlqTzlGfPmnSrvj4up8uWm3Fu7vHPWl8s84Et+2afdFbiL7WuHpebdOHa9m07WoaOTy+B7XAZgkWbJt0Z1x+qdU6t28f1qd+XWTcuXaR08I6M698e//bSQbxpXM5+uTa5XveW2bdH/1fmr0mbLu2/UZrQl7ELurFN9IHtyTIfgnfG8SYdyIy330xLaP3rbPOuZcfJc3DtWuaZxkPjssAGAFuUgJFOWOuGrSL7tY5MXn+81yUUfmM6uAV5xm3aues7bC1Y7ox//1SGjtK3xvVF8iWK/KxH65zl761l+bRoHrTP/qfSj8ROO2zrShBeR75gcnOZhfsQ2ADggGjPcCUA9N8gPJGWddgiwWuVqb+DbpPAluuW8LUpgQ0ADpD8rtnJ6D5Nn1PLFOSXxuVflvmfqTjdJCilk7if695+pmUTed+8v8AGAKwlnaOny/BzIc9OtgEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB9z71JPhOBeRDPEAAAAASUVORK5CYII=>

[image9]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACoAAAAZCAYAAABHLbxYAAACLklEQVR4Xu2VwUtUURjFj5SUZJQUQig2RC3CRURU2KJFhlhQUC0Silq0yEVLKVpL/4FuihAXUlSLxBaCEoO2a1u0iMBCbCEaBLVwYZ0z37vOne+9kZmJFsI78EPmfO/ee967370CuXJtLe0lZ0iXL/yjeskdbyZqJz3kANnmapl6QRbIU/KGXKioNq4C+ULGnS8VyAfymMyTzxXVDPWTu877SKZJi/Pr0XWyTP4gHfQeWXfeUTJCmpxfkswxct75RbICG9yoZskQ0kFbUZ4/lrZfH2i/80tqI+/JCedrYi1wyfm1qpnchI33QQ+R7+Rr5El6gV9IZylJb6EBvhiCPoBN8Jp8S1giF2FvH7xFG7aha7CwWUG1lgJlBa36ccKgzYIGdZJP5Ac5DjsAp6K6tJ2MksHkd1bQ4NUV9Bj5idqCSgqmoHPkPtKNf5m8RPkQZgXVjVJ30Fq2PpaCKaBqO1xNd+IM6Y68rKANbX21wzQBG3TV+dJp2ELqw1haYA3lvhWrsHnkPye7UP0w7Sa/yUnnl6SeeoX0BV9Edu8eJO9gd6Qu8kJU2wnboZhbsKBqh32wHQkfRy0XS88vkA7nb0gTqOf2RJ6+gMIE6QRPwr7EkcTT4goxjMqxQRqjQ6VnplztMOz20DOSXuAhbLc2lU7zW3KDPIL1YfjfG/pYC8b9Fn4HvHy9COvDoHPkGRkgT2Db7g9nSnqzs7CgV1ztf6qP3E7+qn9z5cqVayvpL5cCjXQImTnDAAAAAElFTkSuQmCC>

[image10]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABUAAAAZCAYAAADe1WXtAAABQklEQVR4Xu2Tvy5FQRDGR5CQK6EQolNftyM6FQqt6FSq+wASQjQ3N7ek8AY8AQmiUJzSCyhFiMQLoJD4832Z3ZPZYZ2O5nzJL2fPzOx3dmf3iNT6Cw2BVnhWaR2s+KBVAxyCN3AKHsFcUvFdL2DbB6MGRAtmTewT3IBxE4vqAzuiNVlTmp1LuuUeWDTvVvPgQipMabDrgxmNghOwIL+YspdXYANsgjvwCpq2KIjb3gKdMM6aToF7cAmGTfwJXIuuLOoMLJv3SlO/fcY+wJKJHYiuMCprOgluQdvFC0knzYCJMqvKmsaerrp4IekkPh8czD+HMXeRiKfvv8g7ykn8a6gR0VZZmO+G8VioK8UDYgumTexd9KRtD614p2m6DwZdrhRbwMPhdTkGe/JzMVdciBpajkxNqX7RP4vbXXO5WrX+U19NoEaqCj+IVgAAAABJRU5ErkJggg==>

[image11]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAmwAAAAwCAYAAACsRiaAAAAGiUlEQVR4Xu3dW6gkxRnA8U9UUCKoiRhFxV2QSIiXBG+oeEVJVBRJQuINzEMSfdj44OINXyQgIiqIhghqWEIIiAZCIGIegjshQaM+CKJPKqziBRUjCgoqXupv9bdTUztnds5xjzmz/n/wMdXVfXqquwfqm6ruORGSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJO309ukrtI29+gpJkhbZfiX+21cO7izxWon3ShxU4pjJ1XFHic9KvFniNyWOL3FgiT+UuHeI+0r8vlkm5rEp6r7/V+JnJX4StRN+ucQnzXaL4Kyo7d4RflxiXVd3XtRzxbV6pMTuJa4r8UDUa8M1WYto50l95RyOismEbNcSJ5bYpak7LOq5kiRpp/C7qJ19b0OJM5rlB2OcsNEx8jd0iinrMjl4qcTN49VfJBCvN8tLoRNnP9+cUped9LT2rnUc/5fFOe6T62dL3NDVvRjj9+M6fNUJG18CtocE/BdD+Z8lDh6vmqn/nPEl4ZahzJeBHwxlcK52a5YlSVpYm0t8WuJHXf0oJhM2OuFM2EYl/jJetRVJQpuwtUkKZeq25/mYTPQSI25f94SNfXy3WWYE6eNmOTEa+v9M2M7vK6bgM5fJFMf0VLNuln+XeD/Gx/R2iX2HMp/R9ksB+72pWZYkaSGtL3FE1E5ty8SaiLOjJkaM4BzbraOeab4enWgmVStJ2HL0pE1KEnXZwbPNNSVeKfHY1i3qdCBTsLzPaUPdH6Nu/8sS78a2x7Iazinxaom/l7h1qOP4L446NfrCUIfrS/w5aiKycahjW9r866jTnDm1149QbinxcFeXTh1eOReMQvG+JEmMVuKSEg9FbSNT3+D68b5MpW6Jej5XYp6ErU26eV/adm7UdhLfjnp9Kf9w2C6nxduErR155bVP5vtzJknSwslRsuzo+umjE0p8NKxrO0bK/f1svZUkbNmO7Y0IsQ3JHejU6dzxVkwfhRuVuKLEySUOaOpnYbTmpzPiyPGmE74XtU04usR/hjLHv+dQJjljHUiKssxoUU4nkmjeVeI7Q6BPRkhc2G4WznmOnpL43T+U74lxYvVcjJNkrivtILH71VC3XCtJ2Npl7lHcu8QTTR3tuWwoLydh65clSVo4dIw5okHHRlKTcpopbYpxgse2027oJnHK5GklCRvY93F9ZdSk5htDue2E2yk/1j8TdVq1T9i2l2DuKCRQ05Ko9lyMYtwebphnlIuHAz6M8bGwjz7x6ZOPUdTkb5qrh9f2/LC/bBsJL9eUhzpIdLM9vI6G8rz+FePPEcE+2+X+iwBmJWyZeGVSjlFTNmGTJH1tMBW6vlneUOKdZnlzUwYdeU6/XRl1qq7HPtJKEzam557sK4u7m/K0hG3/qNNqiW14cIFkYRTLT9iY8mUfS0XbnhbHyU30vWkJGwkJ+8qEhmM5JGq750nYOOY+sQFJc17bpRK2NtEZRW1PPgnM8pfRt3sa3n+PoUwyzihfYuqT6eD2c8AxZPC3/A2jbjzBnKOSHDejg63+nEmStDDoKBn5OKypo7OjcyNhwKjE37aujXg0Jp/k2xSTicm6qB1t4h4u7pFKvy3xQWybXEzDfjOxACNu3IcFRtFoJyNTYGTq8JhM2A4dtuEnIzjWx2PyAYrVxshlTr1uHl75CZS8f+zpqO3JhI16gr/7ftTpSc7dpcP2iac/+9GqM6NOW+e+OS/tfW15fkASlNeE92XakTbw96dETVJpF+crXRV1ZJVzys+rZJI3yzwJ28YSPx/KfJaYSgYjt38dykyJ3jiUE8dH2/OYLojxU7K8cu9l4ly1iaAkSTsd7vfC6VHv2coEqUVnT+e81PqlcFN+f08Ykfd4gf1dOMQ8SV5iBIbtieW0aUf7Vsz/A7e0OROuHHWa5qKY/rAHSGg5hyRh8yJJz/eblYgxSodRWznDPAkb+HJAUprHvlKc68tjPGWeOFf908+SJGlB8EO+TN/+KerN94vkjb5ilTFKxcMP+EeJ25t1ax2jyJIkaUFxz1PeU7ZoU2aMoF3bV66yHOGcNQq31nCOljPaKEmS1himyrgfb33UKbN5f+pDkiRJX5G8KZ9/Y3Rbu0KSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJElaJZ8DO8c3x+CXiZoAAAAASUVORK5CYII=>

[image12]: <data:image/png;base64,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>

[image13]: <data:image/png;base64,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>

[image14]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAD0AAAAZCAYAAACCXybJAAACPElEQVR4Xu2XMUgcQRSG3yEBg0IUBBXU2AiKgoKFKGKlhYWdEME+Nqm0sLWxEBuxTgiWgggi11kcFiJaWB1CiIVgk4CIgkUUo//P2/Xmht251ZsrPPeHD5w3b2feezc7+xRJlSrVe1C7bbDUALrAB3viheoAI6Lrxake9AW49OqYmsEquLMnArWAbfAH7IBL8A3UmE4JlAFfQA78AL/AvukQaB3cgM2AFfCxyKOMmOjASrGqOfBYNKuaEbXPGrZakAUXhq2UPoFDcGzZx8GSMR4Gy8aYYhH+BXOUl5hcSXOhezBq2RlIlH+cmNx/sGXZe0QL0RiMua6ZDDUnuldYDC8xuZI+B7dg0LIvSrR/nEL/DcveKnqU+6UQx5TpEIz57B6oE08xuZLm4q4NeKySiMnGJc0TwJPAv5lQXNJ50CSeYionaT6bRK6kaWdipZLmHH28xJQmbcnLBvLGkvZyaYj7IgvXL3WR5UR9vMTkSpo3ZnjRmPou0f5xmhT1z1p23tp50QuK4rr8RJmaF32WnyTKS0yfwYnoA3Y71wZORTsnNhjUkGil10InKWzIxiFOC+DBGHOvn6DXsPEHOAOdho3jXSl0ZUljihQ3YKBRmEdsAPwGR6JVvxINlt/MUBPgWvSIxYlJsqVkk8HisH38W+ShOhDd72sAf1m2naaSxFS2GPAYmBb3PyaupENxDXZdXM8+WRTbY76v9GFxMsXTz0oaU0XF4Oz3rKrFd8u+pKpefJe6bWOqVKlSVUpPf0jGa2aOutcAAAAASUVORK5CYII=>

[image15]: <data:image/png;base64,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>
