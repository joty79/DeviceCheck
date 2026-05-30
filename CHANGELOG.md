# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.8] - 2026-05-30

### Added
- Added responsive dual-pane rendering for wide terminals, with the Device Manager-style tree on the left and selected details/evidence on the right.
- Added ANSI-aware truncation/padding helpers so status lines and panes stay inside the header width instead of overflowing horizontally.
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

### Fixed
- Fixed selected-device detail rendering when cached evidence is missing optional properties such as `DEVPKEY_Device_Service`.
- Balanced wide dual-pane rendering so the device tree and details pane split the terminal width near the middle.
- Removed evidence-cache status/path rows from the left device tree; selected-device evidence state now stays in the details pane.
- Fixed category-level evidence scans crashing under `Set-StrictMode` when a category has no optional `DisplayName` property.

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
