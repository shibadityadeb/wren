# Wren

[![CI](https://github.com/shibadityadeb/wren/actions/workflows/ci.yml/badge.svg)](https://github.com/shibadityadeb/wren/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/shibadityadeb/wren?include_prereleases&label=preview)](https://github.com/shibadityadeb/wren/releases)

**A personal executor for your Mac.** Tell Wren what you need, by typing or speaking. It sets the reminder, asks ChatGPT, or checks your inbox, then tells you when something needs you.

Wren is free and runs on your Mac:
- No subscription and no API keys.
- Speech is transcribed on-device.
- It connects to your own ChatGPT and Google accounts by signing in on their pages.

```
⌥ Space   "remind me to call Sam tomorrow at 10 AM"        → a reminder macOS delivers, even after you quit
⌥⇧ Space  🎙 "ask GPT to research quantum physics carefully" → GPT runs on your plan; you're told when it's done
          "do I have an important email from the recruiter?" → an answer from your inbox, with reasons
```

## What it does

- **Captures and reminds.** Natural-language tasks and reminders ("by Friday", "every weekday at 3 PM") are saved locally and scheduled with macOS. Repeating reminders follow daylight saving. Changing or completing one updates its notification, and a restart never duplicates it.
- **Voice when you ask for it.** Press ⌥⇧ Space or click **Voice**. Wren records one command, transcribes it on this Mac and lets you fix the words before it acts. It never listens in the background.
- **Delegates to ChatGPT.** "Ask GPT to …" runs on your ChatGPT plan through Sign in with ChatGPT, not an API key.
  - Wren tracks the request and notifies you when it finishes. Clicking the notification opens the saved answer.
  - "Think deeply" asks for high reasoning effort. "Research" lets ChatGPT search the web.
  - The result page shows what ChatGPT reports it actually did.
- **Watches your inbox while it runs.** Gmail is read-only by default.
  - Important new mail gets one alert, such as "Important email from Sam", with the reason. You can snooze it.
  - Optional: a morning email digest and quiet hours.
  - Your email is never sent to an AI service.
- **One router for everything.** Typing, the capture panel and voice all go through the same steps. Wren asks when something is unclear, and anything that changes existing data waits for your confirmation.

## Status

Wren is a **preview** (0.10). Every feature below is built and covered by automated tests. "Verified live" means it was also checked against the real service or real macOS; the record is in [docs/MANUAL_TESTS.md](docs/MANUAL_TESTS.md).

| Feature | Verified live |
|---|---|
| Tasks and reminders from your words | Yes, in the running app |
| ChatGPT requests, high reasoning effort, web search with sources | Yes, on a real ChatGPT plan |
| Gmail sync and triage (read-only) | Yes, on a real Google account |
| Voice with a real microphone, notification delivery and click-through, Gmail Mark as read | **Not yet. [Help test it](docs/TESTING_GUIDE.md)** |
| Notion, Calendar | Built; needs a sign-in to verify |

## Install

1. Download `Wren-macOS-universal-unsigned.dmg` from [Releases](https://github.com/shibadityadeb/wren/releases).
2. Optional: check the file with `shasum -a 256 -c Wren-macOS-universal-unsigned.dmg.sha256`.
3. Open the DMG, drag **Wren** into **Applications**, and open it.
4. The preview isn't notarized yet, so macOS blocks it the first time. Go to **System Settings › Privacy & Security** and click **Open Anyway**.

Requirements:
- macOS 14 Sonoma or later, on Apple Silicon or Intel.
- ChatGPT features need a Plus or Pro plan.
- Optional local AI uses [Ollama](https://ollama.com/download).

Upgrading keeps your data in `~/Library/Application Support/Wren` and backs it up before any database upgrade. Don't go back to an older version afterwards: it will refuse to open the newer data.

## First five minutes

1. Press **⌥ Space**, type `remind me to stretch in 2 minutes`, then press Return. Allow notifications when macOS asks.
2. **Connectors › ChatGPT › Continue with ChatGPT**: sign in and approve plan usage.
3. **Connectors › Gmail › Connect Google**: approve read-only Gmail.
4. Click **Voice** in the capture panel and say "ask GPT to explain black holes in two sentences". You'll get a notification when it's done.
5. **Settings › Voice, GPT and Gmail** shows how each tool is set up, along with alert frequency, quiet hours, digest time and sounds.

## Try it for real

**[docs/TESTING_GUIDE.md](docs/TESTING_GUIDE.md)** is a 30-minute checklist covering voice, reminders, GPT and Gmail, with the result to expect at each step.

From a source checkout, you can test without touching your installed Wren:

```bash
scripts/try-wren.sh
```

This builds and opens **Wren Dev**, a separate copy with its own data, sign-ins and permissions, and records a diagnostic log to `build/test-logs/`. The log never contains your words, email or answers, so it's safe to attach to an [issue](https://github.com/shibadityadeb/wren/issues).

## Privacy at a glance

| | |
|---|---|
| Your items | A local database on your Mac. Export, backups and Remove all data are in Settings |
| Voice | The microphone is on only while you record a command. Transcription is on-device, and audio is never stored or sent |
| ChatGPT | Only the request you send, on your own plan. No API key, no paid fallback, nothing in the background |
| Gmail | Read-only by default. Triage runs locally with rules, and email is never shared with an AI service. Wren checks mail only while it runs |
| Sign-ins | Private files that only your macOS account can read. They never appear in logs, exports or backups |

The full policy is at [website/privacy](website/privacy/index.html), and every data flow is mapped in [docs/PRIVACY_DATA_MAP.md](docs/PRIVACY_DATA_MAP.md).

## Documentation

| Read this | For |
|---|---|
| [User guide](docs/USER_GUIDE.md) | Everything in detail: capture, reminders, voice, ChatGPT, Gmail, Calendar, Notion, local AI, permissions, your data |
| [Testing guide](docs/TESTING_GUIDE.md) | Trying Wren with your own accounts |
| [Changelog](CHANGELOG.md) | What changed in each version |
| [Architecture](ARCHITECTURE.md) | How it's built |
| [Manual test record](docs/MANUAL_TESTS.md) and [audit report](docs/AUDIT_REPORT.md) | What has been verified, and how |
| [Maintainer setup](docs/MAINTAINER_SETUP.md) | Provider registration, releases, signing |

## For developers

Requirements: macOS 14 or later and Xcode 16 (Swift 6.1).

```bash
swift test                                 # full suite (providers mocked); CI runs it on arm64 and x86_64
scripts/build-app.sh                       # release build → build/Wren.app (ad-hoc signed)
scripts/build-app.sh debug --dev-identity  # "Wren Dev", separate from an installed Wren
scripts/package-dmg.sh                     # tests, universal build, DMG in dist/, verification
```

| Command | What it does |
|---|---|
| `swift run wren-tools live-check chatgpt "ask GPT to …"` | Runs one real request on the signed-in ChatGPT plan and prints status and evidence only |
| `swift run wren-tools live-check gmail` | A read-only real sync with the signed-in Google account. It needs `WREN_GOOGLE_CLIENT_ID` and `WREN_GOOGLE_CLIENT_SECRET` in the environment |
| `WREN_LIVE_OLLAMA=qwen2.5:3b swift test --filter LiveModelTests` | The local-model tests |

- **Releases:** push a `vX.Y.Z-preview.N` tag that matches `VERSION`. The Release workflow tests on both architectures, then builds, verifies and publishes the DMG. Signing, notarization and Google sign-in are configured through repository secrets ([maintainer setup](docs/MAINTAINER_SETUP.md)).
- **Website:** a static site in `website/`, built with `node website/build.mjs` and deployed on Vercel ([docs/WEBSITE.md](docs/WEBSITE.md)).
- **Brand assets:** `scripts/build-app.sh` regenerates `Brand/` from `assets/logo.png`. That includes vector traces of the bird, the menu-bar template, the icon set and the design tokens.
