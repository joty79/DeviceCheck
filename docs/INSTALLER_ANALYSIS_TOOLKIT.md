# Installer Analysis Toolkit

## Σκοπός

Αυτό το toolkit υποστηρίζει το standalone driver-package trace όταν ένα OEM/vendor installer κρύβει τα πραγματικά INF μέσα σε nested EXE, MSI ή CAB payloads. Η ασφαλής διαδρομή εκτελείται πλέον αυτόματα από το tracer και παραμένει ξεχωριστή από το κύριο `DeviceCheck.ps1` TUI.

Η σειρά εργασίας είναι:

1. Επιβεβαίωση signature/SHA-256 και lookup στο extraction cache.
2. Static format identification με Detect It Easy.
3. Automatic `Safe` routing σε innoextract, 7-Zip ή lessmsi, μαζί με nested recursion.
4. Explicit `Extended` administrative extraction μόνο όταν Strings αποδεικνύει InstallShield `/a` και embedded MSI evidence.
5. DriverStore, SetupAPI και uninstall guard πριν/μετά από κάθε execution-based extraction.
6. Dynamic Procmon capture μόνο όταν οι αυτοματοποιημένες διαδρομές δεν αρκούν.

## Εγκατεστημένα εργαλεία

Snapshot: `2026-07-11`.

| Tool | Version | Ρόλος | Εγκατάσταση / source |
|---|---:|---|---|
| 7-Zip | 26.02 | Πρώτη δοκιμή για NSIS, archives και απλά self-extractors | `winget install --id 7zip.7zip -e` |
| innoextract | 1.9 | Inno Setup extraction μόνο | `winget install --id dscharrer.innoextract -e` |
| Detect It Easy (`diec`) | 3.21 | PE/installer/packer identification | `winget install --id horsicq.DIE-engine -e` |
| lessmsi | 2.12.9 | MSI Property/File/custom-table inspection και extraction όταν υπάρχει προσβάσιμο CAB | `winget install --id activescott.lessmsi -e` |
| WiX Toolset (`dark.exe`) | 3.14.1 | MSI decompilation και extraction embedded Binary streams | `winget install --id WiXToolset.WiXToolset -e` |
| WiX CLI (`wix.exe`) | 7.0.0 portable test copy | Νεότερο MSI decompiler για side-by-side comparison με WiX 3 | [Official WiX v7.0.0 release](https://github.com/wixtoolset/wix/releases/tag/v7.0.0) |
| Universal Extractor 2 | 2.0.0 RC3 portable | Orchestrator για πολλούς legacy/current extractors, μαζί με `i6comp`, `IsXunpack`, `unshield`, `MsiX` και `innounp` | [Bioruebe/UniExtract2](https://github.com/Bioruebe/UniExtract2) |
| Sysinternals Strings | Store/Sysinternals build | Static strings για embedded filenames και command-line switches | [Microsoft Sysinternals](https://learn.microsoft.com/sysinternals/) |
| Sysinternals Process Monitor | Store/Sysinternals build | Dynamic process/file/Registry evidence και temporary extraction paths | [Process Monitor](https://learn.microsoft.com/sysinternals/downloads/procmon) |
| Windows Installer (`msiexec`) | Windows | Native MSI administrative image (`/a`) | Built into Windows |
| PSScriptAnalyzer | 1.25.0 | Static analysis των PowerShell trace/extraction helpers πέρα από parser validation | `Install-PSResource -Name PSScriptAnalyzer -Scope CurrentUser -Repository PSGallery -TrustRepository` |

Το WiX CLI 7.0 απαιτεί explicit OSMF EULA acceptance για MSI commands. Το root `wix --help` και το `wix --version` λειτουργούν χωρίς acceptance, αλλά τα `wix msi --help` και `wix msi decompile --help` σταματούν με `WIX7015`. Στις `2026-07-11` ο χρήστης αποδέχθηκε ρητά την EULA για αυτό το testing. Χρησιμοποιείται μόνο per-command `-acceptEula wix7`, χωρίς persistent acceptance file. Το WiX 3.14.1 παραμένει εγκατεστημένο και η εγκατάστασή του ενεργοποίησε το Windows feature `NetFx3`.

⚠️⚠️⚠️ Πριν χρησιμοποιηθεί binary/tool που απαιτεί EULA ή Terms acceptance, ο operator πρέπει να ενημερώνεται εμφανώς για το boundary και να δίνει explicit acceptance. Η αποδοχή δεν πρέπει να συνάγεται από γενική άδεια εγκατάστασης εργαλείων.

Το UniExtract2 βρίσκεται στο `%LOCALAPPDATA%\Programs\UniExtract2\UniExtract`. Το release archive που χρησιμοποιήθηκε ήταν `UniExtractRC3.zip` με SHA-256 `03170680B80F2AFDF824F4D700C11B8E2DAC805A4D9BD3D24F53E43BD7131C3A`.

## Routing ανά installer type

| Detected type | Πρώτη επιλογή | Fallback | Σημείωση |
|---|---|---|---|
| NSIS | 7-Zip | UniExtract2 | Το 7-Zip συνήθως αποδίδει όλο το outer payload. |
| Inno Setup | innoextract | UniExtract2 / `innounp` | Μην χρησιμοποιείται το innoextract για InstallShield. |
| InstallShield Basic MSI wrapper | Vendor EXE `/a` | Procmon `/b` capture | Η native administrative image είναι συνήθως πληρέστερη από generic unpackers. |
| Standalone MSI | `msiexec /a`, lessmsi | WiX `dark.exe` | Το lessmsi είναι ιδιαίτερα χρήσιμο για table inspection. |
| InstallShield CAB | `unshield` | `i6comp` | Αφορά CAB που έχει ήδη εξαχθεί από το wrapper. |
| Άγνωστο PE/packed EXE | Detect It Easy + Strings | Procmon, και μόνο μετά debugger/decompiler | Ghidra/x64dbg δεν είναι πρώτο βήμα για standard installer containers. |

## Automatic tracer modes

| Mode | Συμπεριφορά |
|---|---|
| `None` | Χρησιμοποιεί μόνο υπάρχον `extracted\<package>` payload και δεν εκτελεί extractor. |
| `Safe` | Default. Υπολογίζει SHA-256, αναγνωρίζει engine, εκτελεί static extractor adapters, ακολουθεί nested installers έως `-MaxExtractionDepth`, γράφει manifest και επαναχρησιμοποιεί hash-matched cache. |
| `Extended` | Απαιτεί elevation. Εκτελεί InstallShield `/a` μόνο μετά από DIE + Strings eligibility proof, μέσα σε DriverStore/SetupAPI/uninstall guard. |

Το Explorer context menu περνά `-ExtractionMode Safe -PromptForExtendedExtraction`. Αν το Safe αποτέλεσμα έχει μηδέν INF και statically identified InstallShield candidate, εμφανίζει τριπλή warning γραμμή πριν προσφέρει Extended extraction. Το administrative MSI target δημιουργείται προσωρινά κάτω από `%TEMP%\DeviceCheckDriverExtract` επειδή το πραγματικό AMD MSI απέτυχε με `Error 1304` όταν το βαθύ cache path ξεπέρασε legacy path limits. Μετά την επιτυχία το payload μεταφέρεται στο SHA cache.

Το `extraction-manifest.json` διατηρεί source signature/hash, tool versions/paths, engine evidence, commands, exit codes, nested attempts, payload inventory, cache reuse, warnings και Extended mutation-guard αποτέλεσμα.

## Βασικές εντολές

```powershell
$installer = Join-Path $env:USERPROFILE 'Desktop\driver-package.exe'
$output = Join-Path $env:USERPROFILE 'Desktop\extracted\driver-package'

# Signature/hash
Get-AuthenticodeSignature -LiteralPath $installer
Get-FileHash -LiteralPath $installer -Algorithm SHA256

# Identification
diec -j $installer

# Static extractors
& "$env:ProgramFiles\7-Zip\7z.exe" x $installer "-o$output" -y
innoextract --info $installer

# MSI table inspection
lessmsi v '.\package.msi'
lessmsi l -t File '.\package.msi'

# MSI decompilation (best effort; proprietary InstallShield tables may fail)
$dark = Join-Path ${env:ProgramFiles(x86)} 'WiX Toolset v3.14\bin\dark.exe'
& $dark `
    -nologo -x '.\wix-payload' -o '.\product.wxs' '.\package.msi'

# WiX 7: per-command EULA acceptance, χωρίς persistent acceptance file
& '.\wix.exe' msi decompile `
    -acceptEula wix7 -sct -x '.\wix7-payload' -o '.\product-v7.wxs' '.\package.msi'
```

Για InstallShield wrapper που δηλώνει `/a`:

```powershell
$target = Join-Path $env:USERPROFILE 'Desktop\extracted\package-admin-image'
$log = Join-Path $target 'administrative-image.log'
$msiArgs = "/qn TARGETDIR=`"$target`" /L*v `"$log`""

Start-Process -FilePath '.\Setup.exe' `
    -ArgumentList @('/a', '/s', "/v`"$msiArgs`"") `
    -Wait -PassThru
```

Administrative extraction εκτελεί το MSI engine. Πριν θεωρηθεί ασφαλές/no-install αποτέλεσμα, ελέγχονται τουλάχιστον:

- published-driver count πριν/μετά,
- growth του `setupapi.dev.log`,
- νέα uninstall entries,
- process exit code και verbose MSI log.

## AMD Chipset Software 8.05.04.516 — πραγματικό comparison

### Δομή

- Outer EXE: NSIS `3.08`, περίπου 80 MB.
- Nested EXE: InstallShield `29.x` / Setup Player `31`, περίπου 20 MB.
- Embedded names από static Strings: `AMD_Chipset_Drivers.msi`, `Data.Cab`.
- Embedded supported switch: `/a Perform an administrative installation`.
- AMD Authenticode signature: valid.

### Αποτελέσματα εργαλείων

| Method | Αποτέλεσμα |
|---|---|
| 7-Zip outer | Επιτυχία· αποκάλυψε το nested `AMD_Chipset_Drivers.exe`. |
| 7-Zip inner | Μόνο 54 PE/resource files, `0` MSI, `0` INF. Δεν αναγνώρισε το InstallShield overlay. |
| innoextract | Exit `2`: όχι Inno Setup installer. Αναμενόμενο. |
| Detect It Easy | Αναγνώρισε σωστά outer NSIS και inner InstallShield. Καλύτερο identification tool της δοκιμής. |
| UniExtract2 default silent | Έμεινε σε method-selection GUI· χρειάστηκε termination. |
| UniExtract2 + forced `IsXunpack` | Exit `0` αλλά `0` extracted files. Το legacy helper δεν υποστηρίζει αυτό το InstallShield generation. |
| InstallShield `/a` | Καλύτερο αποτέλεσμα: `414` files, `68` INF, `37` MSI, `54` SYS, `68` CAT. |
| Automatic tracer `Safe` | Αναγνώρισε `NSIS → InstallShield`, εκτέλεσε δύο 7-Zip attempts και παρήγαγε combined `604` files αλλά `0` INF, οπότε πρότεινε σωστά Extended mode. |
| Automatic tracer `Extended` | Χρησιμοποίησε short `%TEMP%` administrative staging και ολοκλήρωσε με exit `0`. Το combined cache περιείχε `468` files (`54` static streams + `414` administrative files), `68` INF, `37` MSI, `54` SYS και `68` CAT. Guard: published drivers `166 → 166`, SetupAPI unchanged, uninstall inventory unchanged. |
| lessmsi | Διάβασε version και `414` File-table rows. Extraction απέτυχε επειδή το administrative MSI αναφέρεται σε `Data1.cab` ενώ το image είναι uncompressed. |
| WiX 3 `dark.exe` | Εξήγαγε μερικά embedded Binary streams, αλλά decompile σταμάτησε στο proprietary `ISDRMFile` table. Χρήσιμο για MSI structure, όχι για πλήρες payload εδώ. |
| WiX 7 `wix msi decompile` | Ίδιο πρακτικό αποτέλεσμα με WiX 3 στα main και AMD PCI MSI: exit `182`, `ISDRMFile` error και ίδιοι `24`/`22` extracted streams. Σε control WiX MSI ολοκλήρωσε επιτυχώς με `62` extracted files, άρα το failure είναι InstallShield-specific και όχι χαλασμένο WiX 7 runtime. |
| Procmon | Επιβεβαίωσε το child process tree, MSIEXEC και temporary/cache paths. Πολύ ακριβό: `843,559` raw events για ένα extraction· χρησιμοποιείται μόνο ως fallback. |

Η native `/a` δοκιμή είχε exit code `0`, published drivers `166 → 166`, SetupAPI growth `0` και uninstall-entry count `2 → 2`. Άρα δεν έγινε driver binding/install κατά την administrative extraction.

Το τελικό payload αντιγράφηκε στο:

```text
%USERPROFILE%\Desktop\extracted\amd_chipset_software_8.05.04.516
```

Μετά την ασφαλέστερη preview matching διόρθωση, το tracer βρήκε `68` INF και `30` local candidate matches. Τα generic `USB\ROOT_HUB30` matches απορρίπτονται· διατηρούνται μόνο τα AMD-specific `USB\ROOT_HUB30&VID1022&PID...` IDs.

Το package version `8.05.04.516` ήταν ήδη registered στο test OS από `2026-06-24`. Στα matched same-family function drivers, `11` candidate families είχαν ίδια active version και δύο UMDF Sensor candidates ήταν νεότερα από το active `1.0.0.341`. Filter/Extension families απαιτούν SetupAPI evidence και δεν κρίνονται από το visible function-driver binding μόνο.

## Πρακτική αξιολόγηση

- **Καλύτερο identification:** Detect It Easy.
- **Καλύτερο generic πρώτο extraction:** 7-Zip.
- **Καλύτερο Inno extraction:** innoextract.
- **Καλύτερο αποτέλεσμα για αυτό το AMD InstallShield package:** native `/a` administrative image.
- **Καλύτερο MSI metadata/table inspection:** lessmsi.
- **WiX 3 έναντι WiX 7 για αυτό το AMD package:** ισοπαλία· το WiX 7 είναι νεότερο, αλλά δεν ξεπερνά το proprietary InstallShield `ISDRMFile` table.
- **Καλύτερο fallback για temporary paths/child processes:** Procmon.
- **Πραγματικό reverse engineering:** μόνο όταν identification, vendor switches, MSI/CAB extraction και dynamic capture αποτύχουν όλα.
