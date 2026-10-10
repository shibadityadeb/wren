# Wren — Project Specification

Wren is a local-first personal execution assistant that lives natively on the Mac. It captures casual commitments from anywhere via a global shortcut, remembers them, briefs you in the morning, checks in with you in the evening, and never forgets an unfinished item unless you explicitly complete or drop it.

It is not a notes app, a chatbot, a web dashboard, or a conventional reminder manager.

## 1. Target environment (verified 2026-10-10)

| Item | Value |
|---|---|
| Machine | MacBook Pro, Apple M3, 8 GB RAM, 512 GB SSD (about 21 GB free) |
| OS on dev machine | macOS 26.1 |
| Xcode | 16.4 (build 16F6), macOS 15.5 SDK |
| Swift | 6.1.2 |
| Ollama | 0.40.2, running at http://127.0.0.1:11434 |
| Installed Ollama models | `nomic-embed-text` only (embedding model; **no chat model yet**) |
| Minimum deployment target | **macOS 14.0 (Sonoma)** — see ARCHITECTURE.md §2 |

The 8 GB RAM and 21 GB free disk are real constraints: the local LLM must be a small (3B-class) model, and nothing may be downloaded automatically.

## 2. Product vision

A quiet, dependable assistant. You press a shortcut, say what you intend to do, and get on with your day. Wren does the remembering and follows up at predictable times. Interaction is primarily through the global shortcut and native notifications; the menu-bar popover is supporting UI only.

### Canonical interaction

1. You press **Option + Space** anywhere and type: "I need to submit that form by Friday."
2. Wren saves the raw text immediately, then (if a local model is available) extracts a commitment with a deadline of Friday, time unspecified.
3. At **11:00 AM** Wren sends a short briefing naming the few items most worth doing today.
4. At **7:00 PM** Wren asks: "Did you finish the certificate form?" with actions **Done**, **Not yet**, **Remind me later**.
5. You reply "Not yet, remind me at 9." Wren reschedules the follow-up and keeps the task.
6. When you confirm **Done**, Wren records completion and stops reminding.

## 3. Capture taxonomy

Every capture is classified as exactly one of:

| Kind | Example | Gets reminders? |
|---|---|---|
| **commitment** | "Submit my certificate form by Friday." | Yes (briefing, check-in, follow-ups) |
| **goal** | "Publish three articles this month." | Progress reviews only; never nagged like a task |
| **idea** | "I have an idea for a new AI startup." | No. Stored, surfaced only on request or in periodic review |
| **question** | "What's the capital gains rate here?" | No. Answered if a local model is available (Phase 7) |
| **waiting** | "I'm waiting for the recruiter to reply." | Optional follow-up date only |
| **research** | "Find three open-source security scanners and tell me tomorrow." | Result notification when done (Phase 7) |
| **unknown** | Anything the model could not classify confidently | No. Stays in the inbox awaiting your decision |

The rule that matters most: **speculative language never becomes a commitment**. "I might", "someday", "maybe I should" produce an idea or an unknown, not a task with a deadline.

## 4. Functional requirements

### 4.1 Capture (Phase 2)
- Global shortcut, default Option + Space, configurable and disableable.
- Small non-activating overlay with a single text field. Enter submits, Escape dismisses.
- Raw text is persisted **before** any model call. Failed processing never loses input.
- Overlay closes after submit and focus returns to the previous application.
- Fallback capture via the menu-bar popover if the shortcut is unavailable.

### 4.2 Understanding (Phase 3)
- Local Ollama only. No cloud endpoint, no silent fallback.
- User selects an already-installed model. If none is installed, show setup instructions.
- Model output is constrained to a JSON schema and validated before touching persistent state.
- Deadlines are only accepted when a span of the input text supports them. Relative dates resolve against the Mac's local timezone and the capture timestamp.
- Uncertain details produce a clarification request, never an invented value.

### 4.3 Reminders (Phase 4)
- Morning briefing (default 11:00) and evening check-in (default 19:00), both configurable.
- Deterministic selection of a small number of items for the briefing.
- Interactive notification actions: Done, Not yet, Remind me later (with a time).
- Schedules persist, survive restarts, do not duplicate, and reconcile after sleep.
- Completed and dropped items never reappear in the normal queue.

### 4.4 Assistant behaviours (Phase 5)
- Goals with measurable targets and linked commitments.
- Repeated postponement triggers a "still want to do this?" question instead of identical reminders.
- Stale items surface at review time, not as interruptions.
- Natural references ("move that to Sunday", "drop that idea") resolve against recent and active items; ambiguity triggers a question.
- Activity history explains every surfaced, postponed, completed, or dropped event.

### 4.5 Voice (Phase 6)
- Push-to-talk added to the existing overlay. Fully offline transcription. No wake word, no always-listening.
- Transcript feeds the same intent pipeline. Audio deleted after transcription by default.

### 4.6 Research and bounded actions (Phase 7)
- Research requests with original text, expected completion, status, summary, sources, errors.
- Bounded action engine with separately implemented action types. No arbitrary shell execution, ever.
- Web claims carry URLs and retrieval dates. Blocked requests are reported as blocked, never faked.

### 4.7 Daily-use readiness (Phase 8)
- Distributable `.app`, opt-in launch at login, model availability indicator, export/backup, logs, safe reset, pause/quit.

## 5. Hard constraints (restated as test-visible rules)

1. Native macOS only: Swift, SwiftUI, AppKit where needed. No web, Electron, or React.
2. Core features work offline with no paid service and no cloud API key.
3. Persistence is native and local (SwiftData). The database, not the model, is the source of truth.
4. Only `http://127.0.0.1:11434` (or a user-configured local URL) is ever contacted for LLM work.
5. Native notifications only.
6. Launch at login is explicit opt-in.
7. No always-listening microphone.
8. A task is completed only by explicit user confirmation.
9. Capture must work with the model unavailable.
10. The model cannot execute commands, delete files, or send messages. It only proposes structured data that Swift code validates.
11. No unnecessary dependencies. Every dependency is listed with a reason in ARCHITECTURE.md §9.

## 6. Non-goals (for the whole project)

- Cloud sync, accounts, authentication, team features.
- Calendar or email integration (may be considered after Phase 8; not planned).
- iOS companion app.
- Mac App Store distribution (sandboxing would complicate the global shortcut and local file research). Wren ships as a locally built, ad-hoc or Developer ID signed `.app`.

## 7. Trust and tone rules

- Never mark anything done because you stopped responding.
- Never silently discard an unfinished item.
- Reminder counts are bounded and configurable.
- No guilt-inducing copy. Briefings are short, specific, and end with a question you can act on.
- Notification delivery is best effort. Focus modes, Do Not Disturb, and a quit app all prevent delivery, and Wren says so in its status UI rather than pretending otherwise.

## 8. Data location and privacy

- Database: `~/Library/Application Support/Wren/Wren.store` (SwiftData/SQLite).
- Settings: `UserDefaults` for the `com.shibadityadeb.wren` bundle.
- Logs: `~/Library/Logs/Wren/` plus unified logging with `privacy: .private` on any user text.
- No telemetry. No network traffic except the local Ollama endpoint and, in Phase 7, explicitly requested web research.
