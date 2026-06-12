# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Added dynamic Benchmark Mode toggling (hotkey `B` in the `Ctrl+L` connection selector screen). When enabled, it renders detailed network scan phase durations inline below the Actions section, using the TUI's native scrolling view and persisting the setting in `config.json`.
- Added a progress notebook ([progress_notebook.md](file:///d:/Users/joty79/scripts/DeviceCheck/docs/progress_notebook.md)) under the `docs` folder to record detailed walkthroughs of major changes and progress.
- Added network scan phase benchmarking inside `Get-DeviceCheckDiscoveredHosts` that writes detailed phase durations into date-time stamped log files inside a dedicated `logs` folder (ignored in git) ONLY when Benchmark Mode is enabled, dynamically reading the most recent log file to render results.
- Added offline target snapshot loading support. When attempting to connect to an offline or unreachable LAN target, the connection selector now checks if a local cached snapshot exists for that computer name. If a cache is found, it prompts the user to load and view the offline snapshot instead of failing with a resolution error, disabling live refresh dynamically.
- Added an active `R` rescan hotkey in the `Invoke-ConnectionHistorySelector` LAN connection selector screen to reload discovered hosts without exiting the menu.
- Added parallel local network scanning (`Get-DeviceCheckDiscoveredHosts`) to discover active PC hosts in the local ARP cache with WinRM port 5985 open, resolving hostnames dynamically via reverse DNS lookup.
- Added a segmented and unified connection selector screen in `Invoke-ConnectionHistorySelector` dividing connections into "Saved Connections (History)", "Discovered PCs on Network", and "Actions", featuring dynamic `(Online)` indicators and smooth keyboard navigation that skips non-selectable headers.
- Added `internal\Invoke-SdioDriverAudit.ps1`, an audit adapter that parses SDIO matcher logs or launches SDIO with install disabled, extracts indexed driver candidates, labels exact hardware ID vs compatible-ID fallback matches, and can write per-device SDIO reports into the DeviceCheck cache for the selected-details pane.
- Added cached `SDIO Matches` rendering to selected-device details, showing candidate status labels, match kind, version/date, INF, driver pack, the installed device ID, and the candidate INF hardware ID without running SDIO from the TUI render loop.
- Added `-UpdateAllDeviceCheckCaches` to the SDIO audit adapter so one SDIO log can populate cached match details for every present local device that SDIO matched.
- Added higher-resolution Agent instrumentation: Gemini response durations, tool cache hit/miss events, live tool start/complete events with duration and result size, rendered-browser helper timing breakdowns, and latest Agent activity in the TUI status line. Long Agent gaps now identify whether the wait is model latency, cache miss, Chrome startup, page settling, search/result loading, scrolling, or extraction.
- Integrated DPAPI credentials storage (`%LOCALAPPDATA%\DeviceCheck\credentials\<computername>.xml`) directly into the remote snapshot exporter `internal\Export-DeviceCheckEvidence.ps1`. When credentials are null, it automatically looks for a stored XML file matching the lowercase target name and loads it safely. When credentials are provided by the user, it automatically saves them for future reuse.
- Added `Enable-RemotePs.ps1`, a unified administrator helper script to automatically change network profile categories to Private, enable WinRM/PSRemoting listeners, and configure UAC LocalAccountTokenFilterPolicy for remote administrator access.
- Added network adapter profile category analysis and auto-bypass to `Enable-RemotePs.ps1`. The script now inspects all active network interfaces, warns explicitly if any active adapter (such as a virtual Hyper-V switch / unidentified network) has no profile and thus defaults to Public, and automatically uses `-SkipNetworkProfileCheck` to prevent WinRM setup failures.
- Added dual-port TCP scan (ports 5985 and 445) in `Get-DeviceCheckDiscoveredHosts` to identify active Windows computers on the LAN that do not have WinRM enabled yet. These hosts are now displayed in the target selection menu with a yellow `(WinRM Disabled)` status indicator rather than being skipped completely, ensuring 100% network visibility.
- Added checks for `LanmanWorkstation` (Workstation), `lmhosts` (TCP/IP NetBIOS Helper) services, `SMBv2/v3` protocol configuration, and `LimitBlankPasswordUse` security policies auditing/fixing in `Diagnose-SmbSharing.ps1` to automatically detect and repair network sharing setups degraded by trimmed Windows installations (like AtlasOS).
- Added `Diagnose-SmbSharing.ps1`, an interactive diagnostic and fix utility script to automatically audit and repair Windows LAN/SMB file sharing settings, including Private network profile category configuration, Windows Defender Firewall file sharing and network discovery rules, and LAN-related services configuration.

### Fixed
- Fixed a parameter binding error in `Invoke-ConnectionHistorySelector` where the `Join-Path` command failed with "Cannot bind argument to parameter 'Path' because it is an empty string" when `$global:PSScriptRoot` was not defined. Added robust fallback check for the active script root folder.
- Fixed a bug in `Diagnose-SmbSharing.ps1` where the Network Discovery firewall rules group check and enabling command used the incorrect group resource ID `@FirewallAPI.dll,-27752` instead of the correct `@FirewallAPI.dll,-32752`, causing a false positive warning and preventing the rules from actually being enabled.
- Fixed LAN target connection selector issues where devices changing their IP address (e.g. from USB Wi-Fi adapter changes) stayed listed as offline. Enhanced `Get-DeviceCheckDiscoveredHosts` to map resolved history IPs to their respective computer names and query MAC addresses post-connection check. Updated `Invoke-ConnectionHistorySelector` to match history entries by Hostname, IP, or MAC Address and display the current resolved IP instead of the stale cached IP. Fixed `Resolve-HistoryTargetAddress` to normalize MAC Address formatting before checking the local ARP cache.
- Fixed connection history and cached snapshot lookup issues for LAN targets connected via IP addresses. The connection workflow now resolves the target PC's actual hostname from the snapshot, and uses this actual hostname to save the entry in the connection history and set the active target. Enhanced `Add-DeviceCheckConnectionHistoryEntry` to automatically upgrade existing IP-based history entries to the resolved hostname on a successful connection. Updated `Find-LatestSnapshotForComputerName` to scan all snapshots and match them by `RequestedComputerName` when given an IP address, enabling cached snapshot access and offline viewing for IP-based targets.
- Fixed socket handle leaks and negative ARP cache blocks in network discovery and port checks. Replaced asynchronous APM `BeginConnect` calls (which lacked `EndConnect` and leaked handles when hosts were unreachable) with version-aware `ConnectAsync` and `CancellationTokenSource` under PowerShell 6+, falling back to task-waiting under PowerShell 5.1. Added automatic flushing of the Windows OS ARP neighbor cache (`Remove-NetNeighbor` / `arp.exe -d`) for history IPs on rescan to prevent Windows from immediately discarding connections locally without sending packets on the wire when a target transitions from offline to online. Passed `-Confirm:$false` to `Remove-NetNeighbor` to prevent interactive confirmation prompts from interrupting the TUI interface.
- Fixed network discovery for saved connections (like `PALIOS`) that block ICMP pings. The script now appends all unique connection history IP addresses directly to the TCP scan list, scanning them on WinRM port 5985 regardless of whether they respond to pings or are present in the local OS neighbor cache.
- Fixed a connection failure when adding an IP (like the laptop's IP) to `TrustedHosts` via `gsudo.exe`. Resolved correct PowerShell executable path (`pwsh.exe` or `powershell.exe`) from `$PSHOME` instead of trying to elevate the active IDE executable which does not support PowerShell arguments.
- Resolved a pipeline unrolling bug in `Add-DeviceCheckConnectionHistoryEntry` that caused a `PSCustomObject does not contain a method named Add` exception when trying to save a new connection while the history file contained exactly one item.
- Improved LAN connection selector screen to display offline saved connections with a red `(Offline)` indicator, using custom styling for both selected and non-selected items.
- Modified connection failure/cancellation behavior in `Invoke-ConnectLanTarget` to return the user back to the connection selector screen (the "Ctrl+L" menu) instead of exiting to the local host's main menu.
- Fixed active host detection when a target PC was booted after launching the script. `Get-DeviceCheckDiscoveredHosts` now performs active ARP discovery by pinging the subnet broadcast and connection history targets asynchronously before reading the local OS neighbor cache.
- Fixed a null argument binding exception in `DeviceCheck.ps1` when scanning the local network with no other hosts active. Wrapped `Get-DeviceCheckDiscoveredHosts` results in an array subexpression `@(...)` and added a null fallback initialization in `Invoke-ConnectionHistorySelector` to ensure the parameter is never null.
- Resolved a pipeline unrolling issue where `Get-DeviceCheckConnectionHistory` returning an empty collection unrolled to `$null`, causing subsequent method calls (like `.Add()`) to throw a null-valued expression error.
- Fixed a constructor overload resolution error in `Add-DeviceCheckConnectionHistoryEntry` when constructing `List[object]` from a single-item sorted history pipeline by wrapping it in `@(...)`.
- Resolved WinRM connection timeouts and hangs when collecting remote device properties on systems with large numbers of present PnP devices (e.g. over 100 devices). Replaced the slow, loop-based `Get-PnpDeviceProperty` remote calls with a single, batch pipeline execution grouped by `InstanceId`, accelerating remote collection speed by over 15x.
- Cleaned up all other syntax errors on PowerShell 5.1 related to inline `if` statement assignments throughout the entire script by wrapping all statement-mode variable assignments in subexpressions (`$()`) globally.
- Resolved a critical PowerShell 5.1 syntax error (`The term 'if' is not recognized`) by wrapping inline `if` assignments in subexpressions (`$()`) in the connection choice block.
- Fixed a credential cache lookup mismatch by searching cached and stored credentials using both the hostname target (e.g. `se`) and the resolved IP address (e.g. `192.168.1.5`).
- Prevented a `PropertyNotFoundException` crash under `Set-StrictMode -Version Latest` when connecting via current/token-based credentials by safely handling null `Credential` values in the connection collection result object.
- Resolved syntax errors in `Add-DeviceCheckConnectionHistoryEntry` by replacing parenthesized `(if ...)` assignments with subexpressions `$(if ...)` and wrapping inline `if` expressions to satisfy the PowerShell 5.1 parser.
- Improved `Get-CurrentNetworkIdentity` to bind connection metadata to the active interface associated with the Internet connection profile, ensuring correct subnet resolution (e.g., `192.168.1`) rather than picking inactive interfaces like Bluetooth.
- Fixed a StrictMode property error when loading a cached snapshot from history without active credentials. Replaced direct property access on a potentially null `$cachedCredential` object with a safe conditional check falling back to the selected history target's `UserName` property, and updated all returned objects in `Invoke-ConnectionHistorySelector` to guarantee the `UserName` property exists.
- Fixed a Set-StrictMode crash in the remote connection progress loop when a user pressed a key. Replaced raw $Host.UI.RawUI.ReadKey property access with the Read-ConsoleKey helper to safely handle console key properties.
- Fixed indefinite WinRM connection hangs in remote snapshot collection. Added a 15-second connection and operation timeout (New-PSSessionOption) to Invoke-Command within internal\Export-DeviceCheckEvidence.ps1, so unreachable target PCs fail fast with a descriptive error instead of hanging the TUI.
- Rendered Agent Markdown answers with a controlled TUI-safe formatter instead of stripping Markdown into all-white plain text. Agent results now style headings, numbered source sections, bullets, inline code, and URLs while still respecting the selected-details pane width/height budget.
- Fixed a StrictMode crash in the new Agent deferred logging path. The deferred event queue is now initialized before tool calls and guarded with `Get-Variable`, so cache-hit logging no longer terminates the Agent with "unexpectedly without returning result".
- Prevented Agent tool-internal log events from being captured as part of tool return values. Cache hit/miss, browser start/complete, and browser timing logs are now deferred and flushed after the tool call, so `[Tool Result]` contains only the actual tool result instead of nested `{ Type = Log }` objects.
- Added a `.gitattributes` rule for JavaScript files so rendered-browser helper edits stay LF-normalized and Git stops warning that `tools\*.js` will be rewritten to CRLF.
- Enabled `A` / `S` lookups while viewing a remote snapshot. DeviceCheck now runs the web/AI or Agent workflow locally while feeding it the selected remote device's snapshot evidence, instead of blocking with the misleading "local-target only; press R" message after the snapshot was already refreshed.
- Made the top status/message line report selected-device Agent/Web lookup actions immediately. Pressing `A` now shows queued/running/complete/failed states, missing `GOOGLE_API_KEY` / `GEMINI_API_KEY` is shown as a visible blocked Agent status, and invalid selections show a clear "select a device" message instead of appearing to do nothing.
- Added an automatic ASCII glyph fallback for non-UTF-8 console sessions, with `DEVICECHECK_ASCII_UI=1` / `POWERSHELL_TUI_ASCII=1` as manual overrides. DeviceCheck no longer depends on global Windows UTF-8 locale or Nerd Font availability for arrows, tree branches, pane dividers, boxed headers, and footer shortcuts.
- Split the main TUI footer into three stable shortcut rows and removed `Q` from the visible exit hint, while leaving `Q` as a hidden/backward-compatible exit key.
- Compacted the header machine summary without removing any underlying evidence: omitted generic system manufacturer/model text, removed the live clock, shortened Windows captions (`Win10 Pro`), shortened common CPU names (`Ryzen 7 9700X`, `i7-6700K`), stripped trailing MSI board code parentheses, and changed counts to `dev` / `cat`.
- Wrapped long selected-details key/value values as real frame rows instead of truncating with `...`, so fields such as `InstanceId`, `HardwareId`, driver keys, and local identity rows stay readable during live terminal stretching/shrinking.
- Widened the selected-details key column by one character on roomy panes so labels such as `Storage Vendor` display fully without wrapping or breaking row alignment.
- Clamped the main DeviceCheck narrow/short-window renderer to the actual viewport height budget. On very small Windows Terminal sizes, the TUI now hides stacked details temporarily and can reduce visible tree rows to zero instead of writing past the viewport, which caused scrollback movement, duplicated/layered headers, and broken blue banner borders.
- Fixed the shared UI blueprint viewport helpers so `Get-UiWidth` never reports a width larger than the real console viewport and `Lock-ViewportToWindow` locks both buffer width and height. This prevents rendered header corruption where copied text looked correct but Windows Terminal painted wrapped/stale border fragments.
- Stale credentials cleanup on failure: Added a new `Remove-DeviceCheckStoredCredential` helper and integrated it into the remote collection and refresh loops. If a WinRM connection to a remote target fails (e.g. with `Access is denied`), the script automatically deletes the cached credential from the disk (`%LOCALAPPDATA%\DeviceCheck\credentials\<computername>.xml`) and memory, prompting the user for fresh credentials on the next connect/refresh attempt instead of repeatedly failing with stale data.
- Resolved connection screen remnants: Forced a console screen clear (`$script:RequestForceClear = $true`) immediately upon entering the LAN target connection screen and transitioning between prompt stages (username, password, cached snapshot choices). This completely wipes any background main tree elements (like detail pane borders and status lines) without needing a manual window resize.
- Disabled connection mode auto-wrap: Removed `Restore-TuiHost` from `Invoke-ConnectLanTarget` and `Invoke-SystemScan` so auto-wrap remains disabled (`?7l`) during execution. This prevents horizontal border wrapping on extremely narrow terminal widths (under 60 columns) and allows clean truncation/clipping.
- Made the connection failure dialog responsive to resizing by replacing the blocking `Read-Host` call with a key polling loop (`Read-ConsoleKey`) that dynamically redraws the screen on `ResizeEvent`.
- Rewrote LAN connection target prompt, username/password prompts, and cached action choice inputs using a custom key-polling `Read-TuiLine` loop. This enables real-time viewport redrawing on window `ResizeEvent` while blocked on input, preventing all double-border stretching and reflow remnants.
- Fixed TUI double-border stretching and screen remnants in connection screens by appending `$($_C.EraseLn)` to all border lines in `Add-UiFrameBanner` (in `PS_UI_Blueprint.psm1`), `Add-FrameBanner` (in `DeviceCheck.ps1`), `Add-UiFrameSection`, and `Add-FrameSection`. This ensures any old characters from a previous wider frame are erased.
- Improved `Clear-TuiScreen` to use native .NET `[Console]::Clear()` for complete viewport and scrollback buffer wipe on modal transitions, eliminating background text leaking under connection panels.
- Automated remote snapshot refresh: pressing `R` or reconnecting in the TUI now uses the stored credential on disk if it exists, bypassing all prompts.
- Added first TUI remote target switching slice: `Ctrl+L` prompts for a same-LAN/workgroup target, collects a WinRM snapshot, and redraws the main DeviceCheck tree from that remote snapshot.
- Added `internal\Export-DeviceCheckEvidence.ps1`, a local/WinRM evidence snapshot exporter that collects system identity, present PnP devices, optional per-device properties, `pnputil` connected-device output, and monitor registry/WMI evidence into `%LOCALAPPDATA%\DeviceCheck\snapshots\`.
- Added `Connect-PaliosDeviceCheck.ps1`, a convenience wrapper for the known `PALIOS` LAN desktop that prompts for credentials and calls the generic exporter.

### Verified
- Confirmed the first interactive TUI `Ctrl+L` remote target switch against `PALIOS`: DeviceCheck returned to the main screen and displayed the remote snapshot-backed device tree.
- Confirmed two full `Connect-PaliosDeviceCheck.ps1` runs against `PALIOS` over same-LAN WinRM, each collecting 127 present devices and 9 monitor registry entries through the Windows PowerShell 5.1 endpoint in about 10 seconds.
- Added persistent machine summary (system information, dynamic device/category counts, and time) inside the header banner subtitle in `DeviceCheck.ps1`'s TUI.
- Added TUI rendering performance and console limits research guide in `docs\TUI_Render_Performance_Limits.md`.
- Added high-fidelity in-memory performance benchmarking in `DeviceCheck.ps1` which logs key reads, event processing, prep work, and rendering frame durations, and automatically saves a detailed summary to `tui_benchmark.log` upon exiting.

### Changed
- Updated `WinRM.ps1` to configure `LimitBlankPasswordUse` to 0 (allowing blank passwords remotely for local accounts) and automatically restart the WinRM service at the end of the script to apply all UAC and password registry changes immediately.
- Documented the proven stretching/blinking/performance/arrow-navigation guardrails directly in `PS_UI_Blueprint.psm1` so future TUI work inherits the same rules instead of re-learning them from chat history.
- Animated remote snapshot collection progress: Converted `Invoke-DeviceCheckSnapshotExport` to run the remote evidence collector asynchronously in a background PowerShell runspace instead of blocking the main thread. Added a dynamic marquee progress bar with a spinning activity indicator (`[---###---] /`) that updates every 100ms. Added live window `ResizeEvent` processing during collection and enabled connection cancellation at any time by pressing `ESC`.
- Updated the `Ctrl+L` LAN connection screen, credential prompt, and remote connection status/error screens (`Invoke-ConnectLanTarget`, `New-DeviceCheckCredentialFromPrompt`, `Show-RemoteSnapshotCollectionScreen`, and `Invoke-RemoteSnapshotCollectionScreen`) to fully comply with the TUI blueprint: transitioned from raw `Write-Host`/`Read-Host`/`Clear-Host` calls to unified frame-building using `StringBuilder`, atomic single-write rendering via `[Console]::Write()`, proper `EraseLn` to prevent window stretching artifacts, and consistent use of the `$_C.*` color palette. Added explicit `Clear-Host` calls before each modal connection wizard step to prevent prompts from leaking underneath the active main TUI tree view.
- Added a script-scope credentials cache (`$script:CredentialCache`) mapping computer names to their entered `PSCredential` objects, allowing automatic credential reuse during target scans/refreshes (via `R` key or connect prompts) without repeatedly asking the user.
- Replaced the `Ctrl+L`/remote refresh PowerShell credential popup with inline DeviceCheck username/password prompts, and kept connection failures on the connect/refresh screen instead of leaking error text under the main TUI.
- Changed `Ctrl+L` target switching to open an existing cached `latest.json` snapshot instantly by default, with refresh as an explicit choice.
- Changed the TUI status/footer to show the active target and advertise `Ctrl+L` connect; `R` now refreshes the active remote snapshot when viewing a remote target.
- Removed redundant keybinding help strings (`R rescans devices. E scans evidence...`) from the header banner subtitle in `DeviceCheck.ps1` since those shortcuts are already displayed in the navigation footer.
- Ignored the generated `tui_benchmark.log` file so local TUI performance runs do not leave noisy untracked artifacts.
- Updated `Write-UiBanner` in `PS_UI_Blueprint.psm1` to safely truncate long titles or subtitles using the BMP-safe ellipsis character `[char]0x2026` and pad them correctly, preventing negative padding string multiplication crashes on narrow windows.
- Cleaned up TUI status message logic in `DeviceCheck.ps1` to prevent duplicate system summary printing: initialized the status line with a clean welcome message, and simplified system scan status messages during scan operations.

### Performance
- **Concurrent TCP port scanning:** Refactored the TCP scan phase in `Get-DeviceCheckDiscoveredHosts` to scan ports 5985 and 445 concurrently using native .NET `TcpClient.ConnectAsync` tasks. This completely eliminates the runspace-creation overhead of `ForEach-Object -Parallel` (saving ~5.2 seconds) and reduces the port scan duration to exactly **~500ms**.
- **Fixed and optimized parallel history DNS lookups:** Resolved a parameter binding error in `Resolve-DnsName` (removed invalid `-Timeout` parameter and used `-QuickTimeout`). Prevented the slow fallback to `[System.Net.Dns]::GetHostAddresses` when `Resolve-DnsName` throws exceptions on offline hosts, dropping the DNS resolution phase duration from 2.5 seconds to **~30-50ms**.
- **Removed slow reverse DNS lookups:** Completely removed blocking `[System.Net.Dns]::GetHostEntry` from the reverse resolution phase in `Get-DeviceCheckDiscoveredHosts`. Reverse resolution now uses only `Resolve-DnsName -DnsOnly` which avoids the slow 4.5-second NetBIOS/LLMNR query timeouts on discovered hosts without PTR records, dropping reverse resolution time to **~70-90ms**.
- **Reduced TUI polling loop sleep:** Decreased the idle polling sleep in `Read-ConsoleKey` from 40ms to 10ms, eliminating key repeat scroll stuttering and reducing input latency to match the ultra-fast (3.5-6ms) render loop.
- **Single-write main frame renderer:** `Render-Frame` now builds the main TUI navigation frame with `StringBuilder` and emits it through one `[Console]::Write()` call, reducing PowerShell host write overhead during scrolling.
- **Optional TUI perf status:** Set `$env:DEVICECHECK_TUI_PERF = '1'` before launching `DeviceCheck.ps1` to show last-frame render time, frame size, console writes, visible rows, and detail lines in the status line.
- **In-memory evidence cache:** `Read-CachedDeviceEvidence` now caches parsed JSON objects in `$script:EvidenceCacheMemory`, eliminating disk I/O and `ConvertFrom-Json` on every render frame. Cache is invalidated on evidence completion and system rescan.
- **Compiled ANSI regex:** `Remove-AnsiSequence` now uses pre-compiled `[regex]` objects (`$script:AnsiOscRegex`, `$script:AnsiCsiRegex`) instead of recompiling patterns on every call (~120+ calls per render frame in dual-pane mode).
- **Dirty flag for VisibleRows:** Tree rows are only rebuilt when `$script:VisibleRowsDirty` is true (set by expand/collapse, search completion, system scan, resize). Skips unnecessary rebuilds during idle polling and static navigation.
- **Cursor-home repositioning rendering:** Replaced standard `Clear-Host` calls with cursor-home (`[Console]::Write("$($_E)[H")`) positioning and selective ANSI Erase line/screen directives. This drastically reduces the overhead of `Write-Host` and completely eliminates blinking/flicker in both standard rendering and `Invoke-ModelSelector` dialog loops.

### Fixed
- Fixed the local TUI blueprint width helper so wide terminals report their real width again instead of being capped at 100 columns, restoring the dual-pane layout.
- Fixed key-loss and skipping bugs during rapid arrow navigation by completely removing the experimental arrow-key batching mechanism, relying instead on the new highly-optimized cursor-positioning redraw routine to achieve butter-smooth scroll behavior.
- Added a state-driven `$script:RequestForceClear` flag to perform a full `Clear-Host` only on startup, window resizing (`ResizeEvent`), or when returning from modal menus (e.g. `Invoke-ModelSelector`), preventing screen artifacts while keeping regular renders instantaneous.
- Fixed a layout line-overflow bug in non-maximized console windows (pwsh 5/7) where total printed lines exceeded `WindowSize.Height`, causing the console buffer to scroll and display duplicate/layered headers and footers. The number of visible rows (`$maxVisible`) is now strictly clamped based on dynamic header height, dividers, details pane size, and footer safety margins.

### Added
- Added WMI monitor evidence layer in `internal\MonitorEdidResolver.psm1` (`Get-MonitorWmiEvidence`) and integrated it into `DeviceCheck.ps1` (`Get-MonitorWmiIdentityForResolution` and `Add-MonitorWmiAndInfRows`), decoding user-friendly monitor name, manufacturer/product IDs, physical panel sizes, preferred active timing descriptors, and connection technology ports (HDMI/DisplayPort etc. mapped from WDM D3DKMDT_VIDEO_OUTPUT_TECHNOLOGY enum) directly from `root\wmi` classes.
- Added monitor INF driver evidence support in `internal\MonitorEdidResolver.psm1` (`Get-MonitorInfEvidence`) and integrated it into `DeviceCheck.ps1` (`Get-MonitorInfIdentityForResolution` and `Add-MonitorWmiAndInfRows`), searching the active driver INF and matching `oem*.inf` files under `C:\Windows\INF` for local monitor names without treating INF strings alone as authenticated retail-model proof.
- Added optional live-monitor assertions in `internal\Test-MonitorEdidResolver.ps1 -IncludeLiveMonitor` to test WMI and INF monitor evidence retrieval against actual present hardware devices while keeping the default test deterministic.
- Added monitor EDID registry evidence support through `internal\MonitorEdidResolver.psm1`, decoding manufacturer/product code, monitor name descriptor, serial evidence, manufacture week/year, physical size, preferred timing, EDID version, extension count, and checksum state from raw EDID bytes.
- Added `internal\Test-MonitorEdidResolver.ps1` with a synthetic valid EDID fixture proving `GSM / 5BD3` manufacturer/product decoding, monitor name parsing, manufacture year parsing, and checksum validation.
- Added `docs\DEEP_RESEARCH_PROMPT_MONITOR_EDID_IDENTITY.md` and `docs\ANTIGRAVITY_GEMINI_JOB_MONITOR_EDID_LAYER.md` to hand off the next monitor evidence research and Antigravity implementation pass.
- Added DISPLAY monitor ID parsing for IDs such as `DISPLAY\GSM5BD3`, resolving the EISA/PNP manufacturer code through `pnp.ids` and preserving the EDID product code as monitor identity evidence.
- Added broader Windows storage ID parsing for `USBSTOR\Disk&Ven_*&Prod_*` and compact `IDE\Disk...` disk IDs alongside the existing SCSI storage parser.
- Added HDAUDIO codec/subsystem parsing for Windows HD Audio IDs such as `HDAUDIO\FUNC_01&VEN_10EC&DEV_0892&SUBSYS_10438698&REV_1003`, including controller tuple parsing for compatible IDs with `CTLR_VEN_*` / `CTLR_DEV_*`.
- Added official-board-spec evidence for the ASUS Z170-A onboard Realtek ALC892 HD Audio tuple, sourced from the ASUS Z170-A official user manual.
- Added ALSA UCM USB audio profile evidence support: tracked `source\alsa-ucm-conf` snapshot, importer, resolver, and regression smoke test for `0db0:cd0e -> Realtek/ALC4080`.
- Added selected-device `Audio Profile` rows for ALSA UCM matches, clearly labeled as open-source profile evidence rather than `usb.ids` product identity.
- Added Markdown copies of the ChatGPT/Gemini local hardware identity research documents under `docs\` so the source research is laptop-ready without PDF conversion.
- Added initial hardware identity JSON schemas for source manifests, device evidence bundles, and regression test contracts under `schemas\`.
- Added `TC_MSI_X870_REALTEK_AUDIO_001`, the first hardware identity regression fixture for the MSI X870 Tomahawk / Realtek USB Audio case.
- Added `internal\Test-HardwareIdentityHarness.ps1`, a deterministic contract harness that proves vendor-only `usb.ids` data must not be promoted into an exact `Realtek ALC4080` USB product claim.
- Added dual-pane keyboard navigation: Left/Right arrow keys now switch focus between the Device Connection Tree (left) and Selected Details (right) panes. When the Detail pane is focused, Up/Down/PageUp/PageDown/Home/End scroll the detail content instead of navigating the tree. The active pane is visually indicated with a highlighted section header and diamond icon. Left/Right arrows no longer perform expand/collapse (use `+`/`-` keys instead).
- Migrated the audit-only hardware ID and driver-research engine prototype into `DeviceCheck\internal` from the accidental sibling `drivercheck` work.
- Added offline hardware ID cache tooling: `internal\Update-HardwareIdDatabases.ps1`, `internal\HardwareIdResolver.psm1`, and `internal\Resolve-HardwareIds.ps1`.
- Added local audit-only driver research tooling: device inventory report, candidate search-link report, installed INF matching, evidence bundle, readable evidence view, package metadata gate, and adapter collection plan.
- Added source/metadata manifests under `config\`, including `hardware-sources.json`, `driver-candidate-package.schema.json`, and `driver-package-source-adapters.json`.
- Added generated artifact ignores for `data\hwdb`, `devices`, `driver-candidates`, `inf-matches`, `driver-evidence`, and `driver-package-metadata`.
- Integrated the migrated `HardwareIdResolver` into the `DeviceCheck.ps1` selected-device details pane, showing read-only local Hardware ID identity summaries from the offline `hwdata` cache when cached device evidence exists.
- Added optional candidate `Recommendation` metadata fields for version comparison, trust level/score/factors, and candidate flags inspired by the local OpenDriverUpdater source audit.
- Added read-only board-model evidence support through `config\board-model-evidence.json`, seeded with the user-confirmed MSI RTX 4060 Ti Ventus 2X Black OC 16 GB exact PCI tuple.
- Added `docs\GEMINI_NEXT_STEP_GPU_BOARD_MODEL_EVIDENCE.md` with the next verification and enrichment steps for Gemini.
- Added `docs\GEMINI_NEXT_STEP_USB_AUDIO_IDENTITY.md` documenting the non-hardcoded Realtek USB Audio identity path for `USB\VID_0DB0&PID_CD0E&MI_00`.
- Added the ChatGPT/Gemini research PDFs and `docs\LOCAL_HARDWARE_IDENTITY_DATABASE_PLAN.md` as the laptop-ready roadmap for the local evidence database, source provenance, confidence model, and regression harness.

### Changed
- Hardened evidence-scan hotkeys in the TUI: pressing `E` on the root now requires a second `E` within 4 seconds before scanning all devices, root all-device scans cannot start from the right details pane, and pasted/right-click input bursts are ignored instead of being treated as shortcut keys.
- Reverted the right-pane clipboard shortcut workaround because it did not solve the real Windows Terminal mouse-selection problem and added unusable UI surface.
- Improved disk identity display for Windows SCSI/NVMe compact IDs by stripping fixed-width underscore padding from displayed tokens, preferring the structured storage `InstanceId` when available, and using the local FriendlyName for the visible storage model.
- Reduced selected-monitor `Local Hardware Identity` noise by hiding duplicate EDID/WMI/INF source rows and keeping a compact monitor summary with name, ID, size, manufacture date, native timing, connection, checksum, and evidence source family.
- Improved DISPLAY/MONITOR Hardware ID breakdowns so missing `pnp.ids` EISA vendor entries can fall back to the local Windows manufacturer string instead of showing `Unknown display vendor`.
- Improved selected-monitor details so DISPLAY devices can show local Windows registry EDID rows when raw EDID is readable, while still labeling exact retail model discovery as requiring stronger INF/OEM/source evidence.
- Improved monitor and disk selected-device details so DISPLAY monitor IDs and USBSTOR/IDE disk IDs no longer fall through to generic PNP/unsupported identity when Windows exposes enough structured identity text.
- Improved selected-device Hardware ID breakdown and Local Hardware Identity rows for Realtek HD Audio devices so HDAUDIO IDs no longer fall through to misleading PNP compact parsing such as `VEN_HDA` / `DEV_UDIO`.
- Improved disk identity display by adding SCSI/storage ID parsing for Windows disk IDs such as `SCSI\DISK&VEN_NVME&PROD_*`, avoiding misleading PNP fallback rows for NVMe/SATA drives.
- Improved USB Hardware ID parsing and display: `REV_*` and `MI_*` are now extracted regardless of order, and USB compatible class IDs such as `USB\Class_01&SubClass_00&Prot_20` resolve as generic USB Audio class evidence.
- Added a safe local USB identity label in the details pane that combines vendor/product-class certainty with installed driver evidence without claiming an exact silicon model.
- Updated PCI/USB/ACPI/PNP Hardware ID rendering in the details pane (both dual-pane and stacked modes) to display a detailed, structured breakdown of the hardware ID components (VEN, DEV, SUBSYS subvendor/subdevice, REV, VID, PID, MI) mapped against resolved database names.
- Refined `Local Hardware Identity` into a compact evidence summary: it now keeps local match confidence/source and exact board-model evidence, while avoiding repeated chip/vendor/board-ID rows already explained by the Hardware ID breakdown.
- Added `Get-FormattedHardwareVendorName` helper to clean up manufacturer/vendor names (e.g. converting `Micro-Star International Co., Ltd. [MSI]` to `Micro-Star International / MSI` and stripping `Corporation`/`Co., Ltd.`).
- Expanded selected-device cached evidence in the TUI with a readable `Installed Driver` section for provider, version, date, INF, INF section, service, driver key, driver name, and manufacturer when those fields are available.
- Updated the local evidence pipeline so pressing `E` marks selected-device evidence as cached as soon as the evidence output arrives, allowing the details pane to refresh immediately without moving the selection.
- Improved PCI Hardware ID resolution when exact `SUBSYS` model data is missing: DeviceCheck now resolves the subsystem vendor from the PCI vendor table and shows chip, board vendor, board IDs, exact-model availability, and a search hint in local identity summaries.
- Made local Hardware ID cache startup self-healing: if generated `data\hwdb` files are missing but `source\hwdata` is present, DeviceCheck builds the cache automatically before the TUI starts.
- Changed `.gitignore` so runtime-critical `source\hwdata` ID and license/readme files can be tracked while generated caches and cloned study repos remain ignored.
- Display board-model evidence rows in the selected-device details pane when a local evidence entry exactly matches the PCI tuple.
- Improved USB vendor-only fallbacks so missing-product `usb.ids` matches produce a fuller search hint with the complete `USB\VID_*&PID_*&MI_*` tuple, without claiming an exact codec/product model.

### Fixed
- Deduplicated `Local ID` and `Search Hint` rows in the details pane by stopping the candidate resolution loop after the first successful match (most specific Hardware ID).
- Prevented first-selection TUI lag/black frames by preloading the local Hardware ID resolver/cache at startup and keeping cache/database load work out of the selected-device details render path.

### Documented
- Documented the migrated Hardware ID Foundation in `README.md`.
- Documented the first read-only TUI integration for local Hardware ID resolution.
- Added `docs\HARDWARE_SOURCE_INTAKE.md` and `docs\GEMINI_NEXT_STEP_DRIVER_PACKAGE_ADAPTERS.md` for source strategy and continuation handoff.
- Added `docs\LOCAL_SOURCE_PROJECT_AUDIT.md` to record what should and should not transfer from local OpenDriverUpdater and wininfparser sources.
- Documented the local hardware identity database roadmap in `README.md`.

## [0.2.0] - 2026-05-31

### Added
- Parameterized the Agent model name using the `-ModelName` parameter in `Get-DriverUpdateAgent.ps1` and passed the user-selected model dynamically from the `DeviceCheck.ps1` TUI instead of hardcoding `gemini-3.1-flash-lite`.
- Disabled the built-in `google_search` grounding tool due to a Gemini API restriction that forbids combining built-in tools with custom Function Calling in the same request.
- Prevented monitor EDID hardware/PnP codes (such as `GSM5BD3`) from being prefetched as direct search inputs on LG support pages, allowing Google Search to perform model discovery first.
- Refactored `Get-GoogleSearchQueries` to build clean, deduplicated, single-line human-like queries combining device properties instead of robotic multiline blocks.
- Added `--disable-blink-features=AutomationControlled` to Chrome arguments in `Search-GoogleRendered.js` to disable webdriver detection and mitigate instant CAPTCHA challenges.
- Updated TUI status display to render the active Agent model name dynamically (e.g., `[Agent: gemini-2.5-flash]`).
- Implemented **Stealth Browser Automation & Persistent Profile** support in `tools/Search-GoogleRendered.js`, using a stable Chrome profile directory (`browser-profile`) and simulating human-like key typing (typed-search emulation) instead of direct URL queries to prevent reCAPTCHA blocks.
- Completed and documented the Gemini response for Google Search / AI Overview retrieval strategies (`docs/gemini-google-search-investigation-response.md`), outlining recommended workflows, tool/prompt changes, and human-in-the-loop fallback strategies.
- Added documentation analyzing Google Search AI Overview behavior in profiled vs non-profiled sessions, including test evidence logs (`docs/google-search-profile-analysis.md`).
- Added system design and research documentation for local/online Device ID databases (PCI, USB, EDID/PNP) to achieve offline deterministic device resolution (`docs/device-id-database-research.md`).
- Added autonomous Agentic Driver Finder (`Get-DriverUpdateAgent.ps1`) that uses Gemini 3.1 Flash Lite Function Calling (Tool Use) to automatically search for, identify, and locate the latest official drivers for any device.
- Agent has built-in tools for `SearchGoogleCustom` (official Google Custom Search JSON API when configured), `SearchWeb` (guarded DuckDuckGo fallback), `FetchUrlText` (plain HTML text/link extractor), `FetchRenderedUrlText` (real Chrome DevTools rendered-page extraction with optional category/tab click), and `SearchUpdateCatalog` (Microsoft Update Catalog search with direct `.cab` download link extraction via POST to DownloadDialog.aspx).
- Agent runs in a recursive loop: Gemini decides which tool to call, the script executes it locally and feeds the result back, until Gemini produces a final synthesized answer with version, date, and download URLs.
- Added `tools/Fetch-RenderedPage.js`, a dependency-light Node helper that drives local Chrome through DevTools Protocol for JavaScript-rendered OEM support pages that block plain HTTP fetches.
- Rendered-page helper can now type into visible search/product inputs, letting the Agent use OEM search pages such as AOC Drivers & Software.
- Integrated Agent into the DeviceCheck TUI via the `A` hotkey. Selecting a device and pressing `A` launches the Agent in a background runspace.
- Live Agent activity is displayed in real-time in the right-side Details Panel, including model steps, requested tools, query/url arguments, and short tool-result previews.
- Agent runs now write JSONL traces under the machine cache so failed or misleading lookup paths can be audited after the TUI run.
- Agent runs now save resumable checkpoints after every Gemini/tool step, including conversation state, tool results, candidate URLs, confirmed/failing URLs, and current plan.
- Added a tool-result cache for rendered pages, plain fetches, web searches, and Microsoft Update Catalog lookups so retries do not refetch recent evidence unnecessarily.
- Added a deterministic prefetch phase before Gemini planning, currently including an AOC regional product-page adapter as the first vendor-specific pattern.
- Added vendor-first candidate guidance for agent runs so Gemini receives official rendered-page actions before it can fall back to search snippets.
- Added `tools/Search-GoogleRendered.js`, a Chrome/Edge DevTools Google Search helper that feeds raw Device Manager-style evidence to Google, captures AI Overview text as an identity hint, and returns top organic result URLs for official-page confirmation.
- Added `SearchGoogleCustom`, an official Google Custom Search JSON API tool controlled by `GOOGLE_CUSTOM_SEARCH_API_KEY` and `GOOGLE_CUSTOM_SEARCH_CX`, so agent discovery can avoid automated Google SERP sessions.
- Added regional-first discovery guidance so Greece/Europe OEM pages are checked before US/global pages when vendor sites differ by region.
- Added Google anti-bot/reCAPTCHA detection so rendered search blocks are logged clearly and the agent stops retrying Google during that run.
- Limited automatic Google discovery to official Custom Search API when configured, reducing CAPTCHA risk while keeping browser Google only as an explicit fragile fallback/diagnostic.
- Added `docs/gemini-google-search-investigation.md`, a focused Gemini briefing for investigating reliable Google Search / AI Overview retrieval.
- Re-enabled the browser Google Search tool in Gemini's default tool list for active testing, while keeping block detection and retry limits.
- Added a 10-step Agent budget guard that pauses with checkpoint state instead of spending unbounded Gemini requests.
- Fixed Agent activity streaming so logs appear while the background runspace is still running instead of only after completion.
- Agent result rows now stay as one selectable tree item, while the full driver report, trace path, and clickable terminal download links are displayed in the right-side details pane.
- Added `A = agent` shortcut to both footer renderers (legacy and dual-pane).

### Fixed
- Fixed SyntaxError in the browser JS code of `tools/Search-GoogleRendered.js` caused by unescaped newlines inside the RegExp literal (`/\r?\n/g`) in Node's template string.
- Increased CDP command timeout in `tools/Search-GoogleRendered.js` to 45 seconds and optimized query input to simulate human paste (`document.execCommand('insertText')`) for long queries, preventing command timeouts on multiline property blocks.
- Hid `SearchGoogleCustom` from Gemini tool declarations unless `GOOGLE_CUSTOM_SEARCH_API_KEY`/`GOOGLE_CUSTOM_SEARCH_CX` (or the `GOOGLE_CSE_*` aliases) are configured, preventing a wasted agent step on the "Custom Search API is not configured" result.
- Fixed `SearchGoogleRendered` cache handling so empty Google-home results are ignored/deleted and cached results do not consume the per-run rendered Google budget before a real browser attempt.
- Improved Google Search form submission in `tools/Search-GoogleRendered.js` by emulating keyboard `Enter` events and clicking the Google Search button as fallbacks to raw `form.submit()`, ensuring typed queries submit correctly on dynamic search variants.
- Added programmatic wrapping and hyperlink formatting for `Log`, `Checkpoint`, and `Cache` path values in `DeviceCheck.ps1`'s details panel using `Add-WrappedPathLine` to prevent truncation and make them Ctrl-clickable terminal links.
- Enforced using the full multiline Device Properties Block as the search query in `SearchGoogleRendered` inside `Get-DriverUpdateAgent.ps1`. If the Gemini model tries to call the tool with a short/summarized search query, the function automatically overrides it with the full script-scoped `$script:devicePropertiesBlock` to guarantee accurate model resolution and AI Overview parsing in Google.
- Fixed Gemini 3 tool-calling `400 Bad Request` failures by preserving the full model content, including `thoughtSignature`, when sending function-call history back to the API.
- Fixed Agent API failures being displayed as successful `(Done)` results; they now return `Type = Error` and render as failed in the TUI.
- Fixed a strict-mode crash when Gemini returns a final text response without a `functionCall` property.
- Fixed final answers emitted on the last allowed Agent step being overwritten by a false maximum-iteration error.
- Fixed rate-limit handling so Gemini `429`/quota responses pause as `Paused: Rate limit` with a checkpoint instead of becoming an unrecoverable failed run.
- Improved DuckDuckGo anti-bot handling so AOC model searches point Gemini toward rendered AOC driver-page search instead of repeated failed web queries.
- Changed Agent `SearchWeb` into a guarded last-resort discovery tool: it now blocks premature DuckDuckGo use when official vendor candidates exist and limits repeated search loops.
- Passed compact local device evidence JSON into agent prompts so Gemini can see full PnP properties, signed-driver data, and `pnputil` output instead of only a few summary strings.
- Changed the pre-Gemini discovery query to use raw local evidence fields (`FriendlyName`, `InstanceId`, `HardwareId`, `CompatibleId`, `Service`, and installed `INF`) instead of short generic search phrases.
- Reduced Agent tree noise by hiding local/web snippet rows during agentic runs; observable tool activity remains available in the details pane and JSONL trace.

## [0.1.9] - 2026-05-31

### Added
- Added dynamic model configuration by loading free-tier Gemini and Gemma models from `data/google-ai-studio-rate-limits-only free.csv`.
- Added Gemma 4 models (`gemma-4-26b-a4b-it` and `gemma-4-31b-it`) to the available model list.
- Added interactive TUI Model Selector (`Invoke-ModelSelector` triggered by pressing `M`/`m`) to select which models are active for lookup.
- Added parallel background execution for multiple active models concurrently, scaling dynamically to any number of selected models.
- Added `M = models` footer shortcuts and polling key handlers.
- Updated tree highlighting and legacy stacked rendering to color OpenRouter models green (`$_C.OK`) and Gemini models blue (`$_C.Info`).

### Fixed
- Fixed TUI freeze caused by inactive models (State = 'None') keeping the pending model count permanently above zero.
- Fixed strict mode exception (`The property 'Key' cannot be found on this object`) in `Read-ConsoleKey` by wrapping properties extraction and ensuring a valid object is always returned.
- Fixed model selection persistence across sessions by automatically saving selections to `config.json` in `LocalApplicationData` and restoring them upon startup.
- Fixed potential strict-mode exceptions by adding null-checks for runspace EndInvoke outputs.
- Prevented silent infinite loop hangs by rethrowing unexpected exceptions in Read-ConsoleKey instead of swallowing them.
- Fixed strict-mode exception on pending models count query by wrapping it in an array subexpression `@(...)` to safely evaluate `.Count`.
- Added robust null and property existence guards to all loop `switch ($key.Key)` invocations to prevent strict-mode crashes when key objects are null.

## [0.1.8] - 2026-05-30

### Added
- Added responsive dual-pane rendering for wide terminals, with the Device Manager-style tree on the left and selected details/evidence on the right.
- Added ANSI-aware truncation/padding helpers so status lines and panes stay inside the header width instead of overflowing horizontally.
- Added a live evidence-scan progress line showing completed, active, queued, and elapsed work for root/category batch scans.
- Added Device Manager-style `+` and `-` expand/collapse shortcuts; on the computer root they expand/collapse every category.
- Added root-level `E` evidence scans so pressing `E` on the computer root scans all present devices locally.
- Added category-level `E` evidence scans so pressing `E` on a group scans all devices in that group locally.
- Added `R` system scan and `E` selected-device evidence scan hotkeys, keeping `S` for selected-device evidence refresh plus web/AI lookup.
- Added visible running/complete status for `R` system scans, including present-device/category counts and elapsed milliseconds.
- Added a Device Manager-style computer root row using the Windows system name.
- Added Device Manager-style category display names while preserving internal PnP class keys for logic.
- Added a human-readable system summary from System Information fields instead of showing the cache/database machine hash in the header.
- Added an always-visible selected-device evidence summary in the details panel when cached evidence exists.
- Added a stable machine evidence ID and selected-device JSON evidence cache under `%LOCALAPPDATA%\DeviceCheck\machines\<machineId>\devices\`.
- Added local evidence collection for selected devices, including PnP properties, signed driver data, and `pnputil /enum-devices /ids /relations /drivers` output.
- Included local machine/device evidence in the Gemini/OpenRouter prompt before web snippets so AI summaries are grounded in local facts first.
- Display all collected DuckDuckGo web snippets in the TUI as numbered evidence rows instead of showing only the first snippet.
- Added canonical CSV and Markdown extracts for the Google AI Studio free-tier RPM/TPM/RPD limit data.
- Documented the snapshot in `PROJECT_RULES.md`, including the distinction between text-out model quotas and tool-specific grounding quotas.
- Added a repository `.gitattributes` file to keep PowerShell, Markdown, JSON, and YAML files on LF line endings while preserving CRLF for Windows launcher/integration files.

### Changed
- Throttled root/category evidence scans to a small queued batch instead of starting every device runspace at once.
- Optimized root/category evidence counters to use in-memory cache flags instead of filesystem checks on every render.

### Fixed
- Fixed selected-device detail rendering when cached evidence is missing optional properties such as `DEVPKEY_Device_Service`.
- Balanced wide dual-pane rendering so the device tree and details pane split the terminal width near the middle.
- Removed evidence-cache status/path rows from the left device tree; selected-device evidence state now stays in the details pane.
- Fixed category-level evidence scans crashing under `Set-StrictMode` when a category has no optional `DisplayName` property.
- Fixed completed evidence batch progress staying visible and continuing to increase elapsed time after all devices finished.

## [0.1.7] - 2026-05-30

### Changed
- Switched default Google Gemini model from `gemini-3.5-flash` to `gemini-3.1-flash-lite` during quota testing, with quota interpretation documented in `PROJECT_RULES.md` because tool-specific grounding quotas are separate from normal text-out `generateContent` quotas.

## [0.1.6] - 2026-05-30

### Changed
- Updated the default Google Gemini model from `gemini-2.5-flash` to the newly released `gemini-3.5-flash` for better reasoning and performance in device information extraction.

## [0.1.5] - 2026-05-30

### Fixed
- Fixed runspace processing loop syntax error in `Update-ActiveSearches` which caused parser failures.
- Redesigned search result layout to print the model header and elapsed time on one line (colored in the model's theme color: Blue for Gemini, Green for OpenRouter/Nvidia), and the synthesized result text on a new indented line (in white).

## [0.1.4] - 2026-05-30

### Added
- Rewrote the device lookup pipeline to be completely asynchronous and non-blocking. The user can now navigate the connection tree, inspect other devices, and select results while a search is running.
- Added an elapsed time counter (e.g. `(Searching... / 4s)`) next to all active spinner rows.
- Implemented search toggling: pressing `S` on a searching device or any of its sub-rows cancels the active search immediately and stops the runspaces.

## [0.1.3] - 2026-05-30

### Added
- Modified Gemini and OpenRouter searches to run concurrently using separate PowerShell Runspaces instead of sequentially.
- Implemented individual real-time spinners in the TUI tree for each model request.
- Added dynamic model tags showing model names (`gemini-2.5-flash` and `nvidia/nemotron-3-super-120b-a12b:free`).
- Applied custom color highlights for model tags (Blue for Google Gemini, Green for Nvidia models).

### Fixed
- Fixed background thread deadlock and TUI frame corruption by setting `$ProgressPreference = 'SilentlyContinue'` in all background runspaces.
- Prevented Internet Explorer initialization hangs in PowerShell 5.1 by adding `-UseBasicParsing` to background web requests.
- Prevented potential loop freeze by wrapping runspace `Dispose()` and `Stop()` calls in `try/catch` and ensuring variable references are safely nullified.

## [0.1.2] - 2026-05-30

### Added
- Added OpenRouter API integration to run side-by-side with the primary Google Gemini API. If both `GOOGLE_API_KEY` (or `GEMINI_API_KEY`) and `OPENROUTER_API_KEY` are present, the script queries both APIs sequentially, displays both summaries in the TUI tree under `[Gemini AI]` and `[OpenRouter AI]`, and provides distinct error reporting for each path.

## [0.1.1] - 2026-05-29

### Fixed
- Fixed spinner animation not displaying during async database/web lookup due to variable scoping issues.
- Fixed HttpClient.Timeout error when querying Gemini API by increasing the timeout from 10 seconds to 30 seconds.
- Increased DuckDuckGo search query timeout to 15 seconds to ensure web snippets are collected reliably.

## [0.1.0] - 2026-05-29

### Added
- Initialize project directory and git repository.
- Copy `PS_UI_Blueprint.psm1` for responsive, flicker-free rendering.
- Setup `README.md` and `CHANGELOG.md`.
- Plan implementation of the interactive device category tree navigation.
