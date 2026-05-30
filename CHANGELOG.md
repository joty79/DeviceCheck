# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
