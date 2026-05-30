# Google AI Studio Free Tier Rate Limits

Source CSV: `data/google-ai-studio-rate-limits-only free.csv`

Live dashboard URL: https://aistudio.google.com/rate-limit?timeRange=last-1-day&project=gen-lang-client-0786799232

!!! NOT LIVE VERIFIED

This Codex session cannot read the live AI Studio rate-limit page because it redirects to Google login. Treat the local CSV as the canonical project copy unless an authenticated export replaces it.

Important guardrail: `Tools` rows are not normal `generateContent` text-generation quotas. `DeviceCheck.ps1` currently uses the text generation API path, so quota decisions for `$geminiModel` must be made from `Text-out models` rows or another verified row for that exact API surface.

## Text-Out Models

| Model | RPM | TPM | RPD |
| --- | ---: | ---: | ---: |
| Gemini 2.5 Flash | 5 | 250000 | 20 |
| Gemini 3.5 Flash | 5 | 250000 | 20 |
| Gemini 3.1 Flash Lite | 15 | 250000 | 500 |
| Gemini 2.5 Flash Lite | 10 | 250000 | 20 |
| Gemini 3 Flash | 5 | 250000 | 20 |

## Multi-Modal Generative Models

| Model | RPM | TPM | RPD |
| --- | ---: | ---: | ---: |
| Gemini 2.5 Flash TTS | 3 | 10000 | 10 |
| Gemini 2.5 Pro TTS | 0 | 0 | 0 |
| Imagen 4 Generate | - | - | 25 |
| Imagen 4 Ultra Generate | - | - | 25 |
| Imagen 4 Fast Generate | - | - | 25 |
| Gemini 3.1 Flash TTS | 3 | 10000 | 10 |

## Other Models

| Model | RPM | TPM | RPD |
| --- | ---: | ---: | ---: |
| Gemma 4 26B | 15 | Unlimited | 1500 |
| Gemma 4 31B | 15 | Unlimited | 1500 |
| Gemini Embedding 1 | 100 | 30000 | 1000 |
| Gemini Robotics ER 1.5 Preview | 10 | 250000 | 20 |
| Gemini Robotics ER 1.6 Preview | 5 | 250000 | 20 |
| Gemini Embedding 2 | 100 | 30000 | 1000 |

## Live API

| Model | RPM | TPM | RPD |
| --- | ---: | ---: | ---: |
| Gemini 2.5 Flash Native Audio Dialog | Unlimited | 1000000 | Unlimited |
| Gemini 3 Flash Live | Unlimited | 65000 | Unlimited |

## Tools

| Model | Tool | RPD |
| --- | --- | ---: |
| Gemini 2.5 Flash | Map grounding | 500 |
| Gemini 2.5 Pro | Map grounding | 0 |
| Gemini 3.5 Flash | Map grounding | 0 |
| Gemini 3.1 Flash Lite | Map grounding | 500 |
| Gemini 3.1 Pro | Map grounding | 0 |
| Gemini 2.5 Flash Lite | Map grounding | 500 |
| Gemini 3 Flash | Map grounding | 0 |
| Gemini 3.1 Flash TTS | Map grounding | 500 |
| Gemini Robotics ER 1.6 Preview | Map grounding | 500 |
| Computer Use Preview | Map grounding | 500 |
| Deep Research Pro Preview | Map grounding | 500 |
| Gemini 2 | Search grounding | 1500 |
| Gemini 2.5 | Search grounding | 1500 |
| Gemini 3 | Search grounding | 0 |
| Default | Search grounding | 1500 |
