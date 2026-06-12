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

### Implemented Changes
1. **Fast DNS Lookup:** Corrected `Resolve-DnsName` parameters (removed `-Timeout 1`, added `-QuickTimeout -DnsOnly`). Prevented the slow fallback to `GetHostAddresses` if `Resolve-DnsName` throws an exception for an offline host.
2. **Concurrent TCP Scans:** Refactored port checking (ports 5985 and 445) to run concurrently via native `.NET` `TcpClient.ConnectAsync` tasks in the main runspace. This completely eliminated the 5.2-second runspace overhead, capping the TCP scan duration at **~500ms** (the connection timeout).
3. **Fast Reverse DNS:** Completely removed `[System.Net.Dns]::GetHostEntry` from the reverse lookup phase. It now queries `Resolve-DnsName -DnsOnly -QuickTimeout`, reverting to the IP address if resolution fails, which drops reverse DNS resolution duration from 4.5 seconds to **~70-90ms**.
4. **TUI Benchmark Mode:** Added a `$script:BenchmarkMode` setting (saved/loaded in `config.json` and toggled with the `B` key in the TUI). When enabled, it displays detailed phase timings in a beautiful popup frame after scans.

### Verification Results
Scanning 15 unique IPs (with 2 online hosts) now completes in **~2.3 seconds** total:
- **Phase 2 (DNS):** ~417ms (for 5 offline history hosts resolved concurrently via `-QuickTimeout`).
- **Phase 6 (TCPScan):** ~578ms (for 15 concurrent IP port checks).
- **Phase 7 (Reverse):** ~79ms.
