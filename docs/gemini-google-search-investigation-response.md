# Gemini Response: Google Search / AI Overview Retrieval

Date: 2026-05-31

Source prompt: `docs/gemini-google-search-investigation.md`

## Recommended Workflow

1. **Normalization Phase:** Before search, clean local IDs such as `MONITOR\GSM5BD3` into useful tokens like `GSM5BD3`.
2. **Discovery Phase:** Use `SearchGoogleCustom` when configured for stable URL/snippet discovery.
3. **Verification Phase:** Once a candidate model is found, use `FetchRenderedUrlText` directly on official vendor/OEM pages.
4. **Validation Phase:** Compare discovered model/driver evidence against local `HardwareId`, `CompatibleId`, installed INF, and vendor page evidence.

## Tool Changes Suggested

- Make `SearchGoogleCustom` the primary API-based discovery tool when configured.
- Use `SearchGoogleRendered` only when needed for AI Overview/model-identity hints.
- Add regional handling to rendered fetches, such as Greece/Europe first.
- Keep Microsoft Update Catalog as last resort after official vendor domains fail.

## Prompt Changes Suggested

- Extract `HardwareId`, `Manufacturer`, and model-like tokens before searching.
- Avoid searching the entire Device Manager block when a smaller normalized query is better.
- Enforce source hierarchy:
  1. Official vendor/OEM regional support page.
  2. Official vendor/OEM global support page.
  3. Microsoft Update Catalog.
  4. Third-party pages only as weak hints, never final driver truth.
- Treat AI Overview as identity hint only, not as final driver/version authority.

## Browser/Search Behavior Suggested

- Prefer a persistent browser profile over a fresh temporary profile.
- Avoid direct navigation to `/search?q=...` when testing rendered Google Search.
- Try opening `google.gr`/Google home first, then type into the search box and submit.
- Use regional browser settings such as `Accept-Language: el-GR,el;q=0.9,en-US;q=0.8`.
- Record final URL after redirects.

## Fallback And Human-Assisted Flow

- If rendered Google Search returns CAPTCHA, stop retrying that run and store:
  - pending query
  - target device evidence
  - timestamp
  - blocked URL/final URL
  - current checkpoint
- Let the user manually view Google/AI Overview in normal Chrome and paste/import the text as evidence.
- Keep final driver links subject to official vendor verification.

## Risks

- Regional redirects can lead to wrong country pages.
- Hardware IDs can map to a family of models, not a single exact model.
- AI Overview can identify a family/revision but must be verified.
- CAPTCHA/unusual-traffic results must not be looped.

## DeviceCheck Interpretation

The next useful implementation experiment is not "disable Google", but "make Google rendered search less dirty":

1. Add a persistent DeviceCheck browser profile for search diagnostics.
2. Add a Google-home typed-search mode.
3. Add visible logs for:
   - direct URL vs typed search
   - profile used
   - final URL
   - CAPTCHA detected
   - AI Overview extracted or absent
4. Keep official vendor pages as final truth.

Note: Gemini mentioned proxy/IP reputation as a risk. DeviceCheck should not implement proxy-based CAPTCHA bypass. If IP reputation is the problem, the acceptable workflow is human-assisted search or official API/tooling.
