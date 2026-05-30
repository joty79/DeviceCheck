# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.2] - 2026-05-30

### Added
- Added OpenRouter API integration as a backup fallback path. If the primary Google Gemini API call fails (or if the key is missing), and `OPENROUTER_API_KEY` is present in the environment/registry, the script queries `google/gemini-2.5-flash:free` via OpenRouter and prefixes the result with `[Gemini AI] (Backup)`.

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
