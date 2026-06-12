# Progress Notebook & Detailed Changelog

This notebook documents detailed walkthroughs of major changes, architecture updates, and performance optimizations.

---

## [2026-06-12] - Network Scan Performance Optimization

### Goal
Drastically reduce network scan load times (hotkey `Ctrl+L`) from 10-20 seconds down to <3 seconds, and implement a toggleable benchmark mode.

### Problem Analysis
1. **Phase 2 (DNS) Delay:** The cmdlet `Resolve-DnsName` was called with the invalid `-Timeout 1` parameter, throwing parameter binding exceptions. This triggered a fallback to `[System.Net.Dns]::GetHostAddresses`, which blocked for **2.5 seconds** per offline hostname, resulting in a 2.5-second delay.
2. **Phase 6 (TCPScan) Delay:** Using `ForEach-Object -Parallel` in PowerShell 7 spun up new runspaces for each IP, introducing **~5.2 seconds** of overhead for 15-16 IPs.
3. **Reverse DNS Hangs:** Active hosts without PTR records in local DNS triggered `[System.Net.Dns]::GetHostEntry($ip)`, which blocked on NetBIOS/LLMNR queries for **4.5 seconds** per host.
4. **Join-Path Error:** Using `$global:PSScriptRoot` (which was empty) inside the connection history selector caused a `Cannot bind argument to parameter 'Path' because it is an empty string` crash when launching a scan.
5. **Overlapping UI:** Rendering benchmark timings as a blocking fullscreen popup overlay in `Invoke-ConnectionHistorySelector` clashed with the active connection menu elements, resulting in a cluttered/buggy visual layout.

### Implemented Changes
1. **Fast DNS Lookup:** Corrected `Resolve-DnsName` parameters (removed `-Timeout 1`, added `-QuickTimeout -DnsOnly`). Prevented the slow fallback to `GetHostAddresses` if `Resolve-DnsName` throws an exception for an offline host.
2. **Concurrent TCP Scans:** Refactored port checking (ports 5985 and 445) to run concurrently via native `.NET` `TcpClient.ConnectAsync` tasks in the main runspace. This completely eliminated the 5.2-second runspace overhead, capping the TCP scan duration at **~500ms** (the connection timeout).
3. **Fast Reverse DNS:** Completely removed `[System.Net.Dns]::GetHostEntry` from the reverse lookup phase. It now queries `Resolve-DnsName -DnsOnly -QuickTimeout`, reverting to the IP address if resolution fails, which drops reverse DNS resolution duration from 4.5 seconds to **~70-90ms**.
4. **TUI Benchmark Mode:** Added a `$script:BenchmarkMode` setting (saved/loaded in `config.json` and toggled with the `B` key in the TUI). When enabled, it displays detailed phase timings directly inside the UI.
5. **Robust Root Path Fallback:** Patched the `Join-Path` call in `Invoke-ConnectionHistorySelector` to use a multi-tiered fallback (`$PSScriptRoot` -> `$global:PSScriptRoot` -> `"."`) ensuring it never receives an empty string when resolved.
6. **Inline Benchmark Rendering:** Refactored the benchmark results layout. Timing phases are now rendered cleanly as inline non-selectable items directly inside the main `Ctrl+L` connection selection list under a new `"Scan Benchmark Results"` section right below `"Actions"`, color-coded with green (`$_C.OK`) and gold (`$_C.Gold`) accents. This leverages the TUI's native scrolling view and completely removes the blocking input modal.
7. **Dedicated Timestamped Logs Folder:** Moved benchmark scans into a dedicated `logs` directory inside the repository (ignored in `.gitignore`). Log filenames are now dynamically formatted with a date-time stamp (`network_scan_yyyy-MM-dd_HHmmss.log`) to keep individual scans separate and clean. These logs are ONLY generated when Benchmark Mode is enabled, saving disk I/O and space when the mode is OFF. The connection selector dynamically retrieves the most recent `network_scan_*.log` file from the `logs` folder to render timing results inline.
8. **Stale Log Prevention & Benchmark Scoping:** Prevented rendering stale log files from previous sessions and disabled in-memory timing caching when Benchmark Mode is OFF. The script now records `$script:ScriptStartTime` upon launch and restricts `$script:LastNetworkScanResult` updates to only occur when Benchmark Mode is active. If a scan runs with benchmark OFF, toggling it ON afterwards displays `(No scans run yet)` (as no timings were cached), forcing a clean rescan with `R` to capture active benchmark timings.

### Verification Results
Scanning 15 unique IPs (with 2 online hosts) now completes in **~2.3 seconds** total:
- **Phase 2 (DNS):** ~417ms (for 5 offline history hosts resolved concurrently via `-QuickTimeout`).
- **Phase 6 (TCPScan):** ~578ms (for 15 concurrent IP port checks).
- **Phase 7 (Reverse):** ~79ms.
