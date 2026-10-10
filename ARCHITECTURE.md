# Wren — Architecture

## 1. Shape of the app

Wren is a **menu-bar utility** (`LSUIElement = YES`, no Dock icon) built with SwiftUI, using AppKit only for three things that SwiftUI cannot do: the global hotkey, the non-activating capture panel, and sleep/wake observation.

```
┌──────────────────────────────────────────────────────────────────┐
│ App (SwiftUI + AppKit)                                           │
│  MenuBarExtra popover · CapturePanel (NSPanel) · Settings window │
│  HotKeyService (Carbon) · NotificationService (UserNotifications)│
│  SchedulerRunner (timer + wake hooks) · LoginItemService         │
├──────────────────────────────────────────────────────────────────┤
│ WrenCore (Swift package, no UI, fully testable with `swift test`)│
│  Models (SwiftData) · Store (CRUD, queries)                      │
│  ReminderEngine (pure functions: state + clock → actions)        │
│  IntentProcessor · IntentValidator · RelativeDateParser          │
│  OllamaClient (URLSession → 127.0.0.1:11434 only)                │
│  ActionEngine (Phase 7) · Transcriber (Phase 6)                  │
├──────────────────────────────────────────────────────────────────┤
│ SwiftData store  ~/Library/Application Support/Wren/Wren.store   │
└──────────────────────────────────────────────────────────────────┘
```

The split matters: everything with logic lives in `WrenCore` and is tested without launching an app. The App target is thin glue.

## 2. Toolchain and deployment target

- **Deployment target: macOS 14.0.** SwiftData requires 14. `MenuBarExtra` (13), `SMAppService` (13), `UNUserNotificationCenter` and Carbon hotkeys are all available. Going to 15 buys nothing we need; going below 14 loses SwiftData.
- Verified on the dev machine: Xcode 16.4, Swift 6.1.2, macOS 15.5 SDK, running on macOS 26.1. Only macOS 26.1 will actually be tested. The 14.0 floor is a declaration, not a tested guarantee.
- Swift 6 language mode with strict concurrency. `@MainActor` for UI and SwiftData main context; `actor` for the Ollama client and the scheduler runner.

## 3. Repository layout

```
Wren/
  Package.swift                 # WrenCore library + WrenCoreTests
  Sources/WrenCore/
    Models/        Capture.swift, Commitment.swift, ActivityEvent.swift, DailyRun.swift, (Phase 5: Goal, WaitingItem, ResearchRequest)
    Store/         WrenStore.swift (ModelContainer setup, CRUD, queries)
    Scheduling/    ReminderEngine.swift, BriefingSelector.swift, ScheduleSettings.swift
    Intent/        IntentProcessor.swift, IntentSchema.swift, IntentValidator.swift, RelativeDateParser.swift
    LLM/           OllamaClient.swift, OllamaModels.swift
  Tests/WrenCoreTests/
  App/
    project.yml                 # xcodegen spec → Wren.xcodeproj (generated, committed)
    Wren/                       # WrenApp.swift, MenuBar/, Capture/, Settings/, Services/
    Wren/Info.plist, Wren.entitlements
    Resources/Assets.xcassets   # logo from assets/logo.png
  assets/logo.png
  PROJECT_SPEC.md ARCHITECTURE.md ROADMAP.md TEST_PLAN.md README.md
```

Why a local Swift package plus an Xcode project rather than one or the other: SwiftPM cannot produce a signed `.app` bundle with an Info.plist, which notifications and login items require. An Xcode project alone makes unit tests slow and ties logic to the app target. The package holds logic; the project holds the bundle.

## 4. Data model (SwiftData)

Source of truth is the database. The LLM only proposes.

### `Capture` (Phase 2)
The raw thing you said. Always written first, never deleted by automation.

| Field | Type | Notes |
|---|---|---|
| id | UUID | |
| rawText | String | verbatim |
| createdAt | Date | UTC instant; local TZ stored separately |
| timeZoneID | String | e.g. `Asia/Kolkata`, needed to reinterpret relative dates later |
| source | enum `text, voice, notificationReply, manual` | |
| processingState | enum `awaiting, processed, failed, needsClarification, manual` | |
| classification | enum `commitment, goal, idea, question, waiting, research, unknown`? | nil until processed |
| clarificationQuestion | String? | set when `needsClarification` |
| modelName / modelRawOutput | String? | for debugging, truncated |
| linkedCommitment | Commitment? | relationship |

### `Commitment` (Phase 1)

| Field | Type | Notes |
|---|---|---|
| id | UUID | |
| title | String | |
| details | String? | |
| createdAt | Date | |
| deadline | Date? | |
| deadlineHasTime | Bool | "Friday" vs "Friday 5pm"; affects overdue logic |
| deadlineIsUncertain | Bool | model was unsure; shown with a "?" and surfaced for confirmation |
| nextReminderAt | Date? | the only field the scheduler reads to decide "is something due" |
| lastReminderAt | Date? | |
| reminderCount | Int | bounded by settings |
| snoozedUntil | Date? | |
| snoozeCount | Int | drives Phase 5 "still want this?" logic |
| status | enum `pending, completed, dropped` | |
| priority | enum `low, normal, high` | |
| source | enum `manual, capture, notificationReply` | |
| completedAt | Date? | |
| droppedAt | Date? | |
| goal | Goal? | Phase 5 relationship, nil until then |
| events | [ActivityEvent] | cascade delete |

### `ActivityEvent` (Phase 1, filled from Phase 4 on)
`id, at, kind (created, surfacedInBriefing, checkedIn, snoozed, completed, dropped, rescheduled, postponementLimitReached, clarified), note: String?, commitment`.
This is the "why did Wren do that" history required by the trust rules.

### `DailyRun` (Phase 4)
`localDate: String (yyyy-MM-dd), briefingSentAt: Date?, checkInSentAt: Date?`. One row per calendar day. This is what prevents duplicate briefings after a restart.

### Phase 5 additions
`Goal` (title, targetCount, unit, dueDate?, commitments), `WaitingItem` (what, from whom, followUpAt?), `ResearchRequest` (Phase 7: request, dueAt, status, summary, sources [URL+retrievedAt], error). Ideas and questions remain `Capture` rows with a classification; they need no extra fields.

### Migration policy
SwiftData lightweight migration for additive fields. Every schema change gets a `VersionedSchema` entry from Phase 5 onward, when real data exists. Before any migration the store file is copied to `Wren.store.bak-<date>`.

## 5. State flow

```
hotkey ──▶ CapturePanel ──▶ store.insert(Capture awaiting)   [sync, < 50 ms]
                                   │
                                   ▼  (background Task)
                           IntentProcessor
                             ├─ Ollama reachable? no ──▶ Capture.failed, show "retry/edit" in popover
                             ├─ /api/chat with JSON schema, temperature 0
                             ├─ IntentValidator (schema, enums, evidence spans, date sanity)
                             │     invalid ──▶ Capture.failed (raw output kept)
                             │     needs clarification ──▶ Capture.needsClarification + question
                             └─ valid ──▶ create Commitment/Goal/... + ActivityEvent, link Capture
                                                    │
                                                    ▼
                                         ReminderEngine.plan(commitment) sets nextReminderAt
```

The scheduler never reads the model. Notification replies ("Done", "Not yet", "remind me at 9") are first handled by a deterministic parser; only free-form replies that the parser rejects go to the model, and the result is still validated against the same rules.

## 6. Scheduling design

### Principle
"What should happen now?" is a **pure function** of (database state, settings, current time). `ReminderEngine.evaluate(now:settings:commitments:dailyRun:) -> [Action]` where `Action` is `.sendBriefing(items)`, `.sendCheckIn(commitment)`, `.sendFollowUp(commitment)`, `.markBriefingSent`, etc. The app applies the actions. This is what makes it deterministic and testable with a fake clock.

### Runner
`SchedulerRunner` (actor) runs `evaluate` on:
- app launch,
- `NSWorkspace.didWakeNotification`,
- `NSSystemClockDidChange` (timezone/clock changes),
- a repeating timer every 60 s (cheap: one indexed query on `nextReminderAt <= now`).

### Why deliver from the running app instead of pre-scheduling `UNCalendarNotificationTrigger`s
Pre-scheduled triggers fire even if the app is not running, which sounds attractive, but they go stale the moment you complete or snooze a task, and keeping the pending-request list in sync with the database is exactly the duplicate/ghost-reminder bug class the spec forbids. Since Wren is a login item and lives in the menu bar anyway, delivering at evaluation time from a single source of truth is simpler and correct. Trade-off: if Wren is not running, nothing fires. Phase 8 surfaces that honestly ("Wren has not been running since …").

### Duplicate prevention
- Briefing/check-in: `DailyRun` row for today has the timestamp → skip.
- Per-commitment follow-up: due iff `nextReminderAt <= now` and (`lastReminderAt == nil` or `lastReminderAt < nextReminderAt`). Sending sets `lastReminderAt = now` and clears `nextReminderAt` in the same transaction as the notification request.

### Sleep, shutdown, missed times
- Mac asleep at 11:00, wakes 11:40 → briefing sends at 11:40 (within the briefing window 11:00–18:59).
- Wakes at 20:30 → briefing skipped (window closed), check-in sends because its window is 19:00–22:59.
- Wakes at 02:00 → nothing sends; both roll to the next day. Wren never notifies between 23:00 and 07:00 unless you explicitly asked for that time.
- Per-commitment follow-ups missed by more than `settings.lateGrace` (default 3 h) are delivered once with "(this was due at 21:00)" rather than dropped.
- Machine shut down overnight → on next launch, `evaluate` runs with the same rules. No separate "recovery" code path exists; recovery is just evaluation.

### Briefing selection (`BriefingSelector`)
Score each pending, non-snoozed commitment: overdue (+100), deadline today (+60), deadline within 2 days (+30), high priority (+20), days since last reminder (+5/day, cap 20), uncertain deadline (−10 so it is confirmed rather than pushed). Take top `settings.briefingLimit` (default 3). Never include ideas, goals without due dates, or waiting items. Fully unit tested with fixed dates.

## 7. Notifications

- `UNUserNotificationCenter` with categories:
  - `BRIEFING`: no actions, opens the popover.
  - `CHECK_IN`: `DONE`, `NOT_YET`, `REMIND_LATER` (a `UNTextInputNotificationAction`, placeholder "e.g. 9pm, 2h, tomorrow 10am").
  - `CLARIFY`: text input action to answer a clarification.
- Reply text goes to `RelativeDateParser` first. Unparseable → capture panel opens prefilled with the task so you can type a time.
- Permission is requested on first launch with a sentence explaining what Wren sends and when. Denied → menu-bar item shows a warning state and the popover shows due items instead. Capture keeps working.
- Interactive actions require a **signed app bundle** with a stable bundle identifier. Ad-hoc signing is sufficient locally.

## 8. Global hotkey and capture panel

- **Hotkey:** Carbon `RegisterEventHotKey`. It needs no Accessibility or Input Monitoring permission, works while any app is focused, consumes the keystroke, and observes nothing else. It is old but not removed, and is what every popular launcher uses under the hood. `NSEvent.addGlobalMonitorForEvents` was rejected: it requires Input Monitoring permission and cannot consume the key.
- Default Option + Space. No conflicting launcher (Raycast/Alfred) is installed on the dev machine; macOS itself binds nothing to it. Recording a new shortcut uses a small SwiftUI recorder view that captures one keystroke via a local `NSEvent` monitor only while the recorder is focused.
- **Panel:** `NSPanel` with `.nonactivatingPanel`, `.hudWindow`-like appearance, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, hosting a SwiftUI view. Because it is non-activating, dismissing it returns focus to the previous app without extra work.

## 9. LLM integration (Ollama)

- `OllamaClient` talks only to the configured base URL, default `http://127.0.0.1:11434`. The settings UI only accepts `localhost`/`127.0.0.1`/`::1` hosts; anything else is rejected with an explanation. There is no cloud code path to fall back to.
- Endpoints used: `GET /api/tags` (installed models, availability probe), `GET /api/version`, `POST /api/chat` with `stream: false`, `format: <JSON schema>`, `options: {temperature: 0, num_ctx: 2048}`, `keep_alive: "5m"` so the model unloads and frees RAM.
- **Model choice (8 GB RAM, 21 GB disk):** a 3B-class instruct model, `qwen2.5:3b` (about 1.9 GB) recommended; `llama3.2:3b` as alternative. 7B+ models will swap on this machine when Xcode is open. Wren never pulls a model; it shows the `ollama pull qwen2.5:3b` instruction.
- **Prompt contract:** the system prompt includes the local date, time, weekday and timezone, and the taxonomy. The schema requires, for any deadline, a `deadline_evidence` string that must be a verbatim substring of the input. `IntentValidator` rejects any deadline whose evidence is not found in the input (case-insensitive) — this is the structural defence against invented dates. The model also returns `confidence` in `{high, medium, low}` and an optional `clarification_question`.
- `RelativeDateParser` (pure Swift, `Calendar.current`) independently resolves the evidence span ("tomorrow evening", "Friday", "tonight at 8", "this weekend"). If it resolves and disagrees with the model's ISO date by more than the granularity (day vs. hour), the parser wins and the commitment is flagged `deadlineIsUncertain`. If neither resolves, the capture goes to `needsClarification`.
- Timeouts: 20 s for chat, 2 s for availability. Malformed JSON, missing fields, unknown enums, deadlines more than 2 years out, or an empty title → `Capture.failed` with the raw output retained.

## 10. Bounded actions (Phase 7 sketch, not built before then)

`ActionEngine` dispatches on a closed `enum ActionKind { answerLocally, searchLocalFiles(scope), webResearch(query) }`. Each is a separate type conforming to `Action` with `func run() async throws -> ActionResult`. The LLM can only pick a kind and fill its typed parameters, which are validated like intents. There is no string-to-shell path anywhere in the codebase, and a test asserts that `Process` is not referenced in `WrenCore`.

Web research uses `URLSession` against public pages and a no-key search endpoint (DuckDuckGo HTML results), honours `robots.txt` and HTTP status, and records `url + retrievedAt` for every claim. If retrieval fails, the request is `blocked` with the reason.

## 11. Voice (Phase 6 sketch)

Two viable fully offline options, decided in Phase 6 after a quick quality test:
1. Apple `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` — zero dependencies, on-device guaranteed by the flag, needs Speech + Microphone permission.
2. `whisper.cpp` via its SwiftPM package with `ggml-base.en` (about 150 MB) — better accuracy, one dependency, model file managed by the user.
Either way audio is captured with `AVAudioEngine` to a temp file that is deleted after transcription.

## 12. Permissions and system APIs

| Need | API | Permission prompt | Phase |
|---|---|---|---|
| Menu bar | `MenuBarExtra` | none | 1 |
| Notifications + actions | `UserNotifications` | yes, user-facing | 4 |
| Global shortcut | Carbon `RegisterEventHotKey` | none | 2 |
| Launch at login | `SMAppService.mainApp.register()` | shows in System Settings › Login Items; explicit toggle in Wren | 8 |
| Sleep/wake | `NSWorkspace.didWakeNotification` | none | 4 |
| Microphone | `AVAudioEngine` | yes | 6 |
| Speech (if option 1) | `SFSpeechRecognizer` | yes | 6 |
| Local file search | `FileManager` with user-picked folders via `NSOpenPanel` (security-scoped bookmarks) | folder picker | 7 |

App Sandbox: **off** (not App Store). Hardened runtime: on. Signing: ad-hoc for local builds; Developer ID if the user has a certificate.

## 13. Dependencies and their reasons

| Dependency | Kind | Reason | Phase |
|---|---|---|---|
| `xcodegen` (Homebrew) | dev-only | generates `Wren.xcodeproj` from a readable `project.yml` so the project file is reviewable and never hand-edited. Not shipped. Alternative is hand-writing a pbxproj. | 1 |
| `whisper.cpp` SwiftPM package | runtime | only if option 2 is chosen in Phase 6 | 6 |

No other third-party code. Specifically rejected: `KeyboardShortcuts` (we need about 100 lines of Carbon), GRDB/Realm (SwiftData is native and sufficient), any HTTP client (URLSession), any scheduling library (the engine is a pure function).

## 14. Failure handling summary

| Failure | Behaviour |
|---|---|
| Ollama not running / no model | Capture saved as `awaiting`; popover shows "Model unavailable — retry / edit manually"; menu-bar icon shows a dot |
| Malformed model output | `Capture.failed`, raw output kept, retry button |
| Store cannot open | Alert with the path and a "Reset (keeps a backup)" button; capture panel still accepts text and appends to `~/Library/Application Support/Wren/emergency-captures.txt` |
| Notification permission denied | Reminders shown as badges in the popover; status explains how to enable |
| Hotkey registration fails | Popover capture field is the fallback; settings explains |
| App crashed / not running | No notifications. Phase 8 status shows last-run time honestly |
