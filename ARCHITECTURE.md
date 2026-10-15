# Wren — Architecture

> **Implementation note (Milestone 1, 2026-10-10).** As built, this differs from the original plan in three places. Each is deliberate:
> 1. **Build:** a Swift package plus `scripts/build-app.sh`, instead of xcodegen and an Xcode project. This adds no dependency and lets `swift test` run everything. Xcode can still open `Package.swift`.
> 2. **Targets:** `WrenCore` (no UI), `WrenKit` (SwiftUI views and AppKit services), `Wren` (a three-line executable), and `wren-tools` (dev-only brand and snapshot tool).
> 3. **Data:** a single `Commitment` model holds the verbatim `originalText`, a `kind` (commitment, idea, question, waiting, research, unsorted) and a `processing` state. This replaces a separate `Capture` entity. Only `kind == .commitment` gets automatic reminders. A separate `Capture` can be split out later if Phase 5 needs it.
> 4. **UI:** the menu bar uses `NSStatusItem` + `NSPopover` rather than `MenuBarExtra`, so a notification tap can open the popover programmatically.

> **0.12.0 (2026-10-14).** One command router, `CommandRouter.intent(for:)`, reads the outer request first and returns a structured intent (operation, destination, rule, confidence). `ItemExecution` runs CreateTask and CreateReminder and reads back what macOS accepted. Deadlines get a day-before heads-up. A reminder time is no longer stored as a deadline. Email alerts open the Gmail conversation (§47). No schema change. docs/EXECUTION_AUDIT.md has the defects and fixes.
>
> **0.11.0 (2026-10-14).** "Ask GPT" goes to the ChatGPT website by default (a handoff), the plan API becomes the explicit "Run with connected ChatGPT in Wren" mode, questions naming no assistant go to the local AI, and follow-ups keep their tool (§46). Schema v8.
>
> **0.10.0 (2026-10-13).** Voice is explicitly activated only (§40, the wake-word listener is gone), GPT thinking and research record requested versus reported effort and web-search evidence (§39), and every command goes through `ExecutionRouter` (§45). Schema v7.
>
> **0.9.0 (2026-10-11).** §35–§44 are rewritten as built: file-based credentials (no Keychain), Sign in with ChatGPT, tracked GPT delegations, Gmail inbox intelligence, Notion MCP, the continuous "Hey Wren" listener (removed in 0.10, see §40) and schema v6. §16 and §17 are the original plans and are superseded by §37–§39. docs/AUDIT_REPORT.md lists what is verified live.
>
> **Milestone 6 (2026-10-11).** Connectors, voice, ChatGPT handoff and delegation (rewritten in 0.9.0, §35–§44).
>
> **Milestone 5 (2026-10-11).** Main window, export, backups and restore, notification pause and reset are documented in §30–§34.
>
> **Milestone 4 (2026-10-11).** Local AI readiness, model download, model-assisted commands and distribution are documented in §26–§29. The build no longer uses only `scripts/build-app.sh` for local runs: releases go through `scripts/package-dmg.sh`.
>
> **Milestone 3 (2026-10-10).** Goals, waiting follow-ups, insights and contextual references are documented in §22–§25.
>
> **Milestone 2 (2026-10-10).** The permission system and daily engine are built in `WrenCore` and documented in §18–§20 below. Where §15 (planned broker) and §18 (as built) differ, §18 is authoritative.

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
  Package.swift                 # WrenCore, WrenKit, Wren, wren-tools, WrenCoreTests
  scripts/build-app.sh          # builds, assembles, icons, signs build/Wren.app
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

## 10. Bounded actions (Phase 7), superseded by the Action Broker (Phase 9)

Phase 7 ships `answerLocally`, `searchLocalFiles`, and `webResearch` as separate typed actions with no string-to-shell path. To avoid a rewrite in Phase 9, every state change from Phase 4 onward goes through one seam: `WrenStore.apply(_ request: ActionRequest)`. In Phases 4 to 8 that seam is a plain function. Phase 9 turns it into the broker below, and commitment actions become the built-in `wren.tasks` tool.

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
| OAuth tokens, API keys | Keychain Services (`SecItem*`) | none; items scoped to Wren | 9 |
| Gmail | Gmail REST API over `URLSession`, OAuth in the browser | Google consent screen | 10 |
| Calendar (later) | EventKit | yes | TBD |
| Named Shortcuts (later) | `/usr/bin/shortcuts run <name>` from one App-target adapter, allowlisted names only | Automation prompts per Shortcut | TBD |

App Sandbox: **off** (not App Store). Hardened runtime: on. Signing: ad-hoc for local builds; Developer ID if the user has a certificate.

## 13. Dependencies and their reasons

| Dependency | Kind | Reason | Phase |
|---|---|---|---|
| `xcodegen` (Homebrew) | dev-only | generates `Wren.xcodeproj` from a readable `project.yml` so the project file is reviewable and never hand-edited. Not shipped. Alternative is hand-writing a pbxproj. | 1 |
| `whisper.cpp` SwiftPM package | runtime | only if option 2 is chosen in Phase 6 | 6 |

| none for Gmail or OAuth | — | the Gmail REST API and OAuth with PKCE are small enough for `URLSession` and CryptoKit; GoogleSignIn and the Google API client were rejected as heavy for 8 GB and unnecessary | 10 |

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
| Tool missing grant or disconnected | Request rejected with guidance; audited |
| Tool result uncertain or timed out | Status `unverified`, notification says so, no retry of non-idempotent actions |
| OAuth token expired or revoked | Integration marked disconnected; reads pause; nothing else affected |
| Keychain unavailable | Integrations disabled; core features unaffected |

## 15. Tool Registry and Action Broker (Phase 9)

### 15.1 Types

```swift
enum EffectClass { case read, reversible, sensitive, destructive }

struct CapabilityDescriptor {
  let id: String                 // "gmail.archive"
  let tool: String               // "gmail"
  let effect: EffectClass
  let undo: String?              // capability that reverses it, e.g. "gmail.unarchive"
  let requiredGrants: [Grant]    // OAuth scopes, macOS permissions, user-granted folders
  let parameters: ParameterSchema
  let verification: String       // human description, e.g. "re-fetch labels; INBOX absent"
  let maxTargetsWithoutReview: Int  // 1 by default
}

protocol Tool: Sendable {
  var descriptor: ToolDescriptor { get }      // id, name, capabilities, auth method
  func status() async -> ToolStatus            // connected, grants held, last error
  func execute(_ call: ValidatedCall) async throws -> ToolOutput
  func verify(_ call: ValidatedCall, _ output: ToolOutput) async -> Verification
}

enum Authorization {
  case directInstruction(captureID: UUID)
  case standingRule(ruleID: UUID)
  case approval(approvalID: UUID)
}

struct ActionRequest {                 // persisted as ActionRecord
  let id: UUID
  let tool: String, capability: String
  let parameters: JSONValue            // raw, validated by the broker
  let targets: [TargetRef]             // resolved, each with a match reason
  let authorization: Authorization?    // nil = proposal only
  let origin: Origin                   // .user, .rule, .model(contextProvenance: [Provenance])
  let dryRun: Bool
}
```

Each record carries an execution status (`planned, awaitingReview, awaitingConfirmation, rejected, running, succeeded, failed, unverified`) and a verification status (`verified, mismatch, notVerifiable, pending`).

### 15.2 Broker pipeline

Every request, from any source, goes through the same ordered checks. The first failing check stops the request and is audited.

1. **Lookup.** Tool and capability exist in the registry.
2. **Validate.** Parameters match the schema. Targets are resolved and non-empty. An ambiguous target stops here with a clarification.
3. **Grants.** The tool is connected and holds every required grant. Missing grant means rejected with "connect X" guidance, never a silent scope upgrade.
4. **Authorization.** Checked against the rules in 15.3.
5. **Policy.** Effect class, target count, standing rules, and settings produce one of `allow`, `review`, `confirm`, `deny`.
6. **Dry run.** If requested, or global dry-run mode is on, return the plan and stop.
7. **Execute.** Through the tool, with a timeout.
8. **Verify.** The tool's verification runs. Status becomes `succeeded` only with evidence. A timeout or ambiguous answer becomes `unverified`, never success.
9. **Audit.** One `AuditEntry` per request, updated at each step.

Priority, confidence, or a "recommended" flag from a model are not inputs to steps 4 or 5. The policy function's signature does not accept them.

### 15.3 How authorization is established

- **Direct instruction.** Only Wren's own input channels create a `Capture` with source `text`, `voice`, or `notificationReply`. The broker accepts `directInstruction` only if that capture exists with one of those sources, is less than 10 minutes old, and was not already consumed by another request. The intent validator must also find the action verb in the raw text as an evidence span, the same rule used for deadlines. If the model resolved several targets, or resolved one with low confidence, the request is downgraded to a proposal needing approval.
- **Standing rule.** User-created in settings. Each rule names one capability, a predicate over metadata such as sender domain or label, an optional daily cap, and an expiry. Rules can cover read, reversible, and sensitive actions. They can never cover destructive actions.
- **Approval.** The review screen shows exact targets and effect. Approving stores a hash of capability, canonical parameters, and target IDs with a 10-minute expiry. The broker re-hashes at execution, so any difference invalidates it.
- **Model-originated requests** have no authorization field the model can fill. The JSON schema for model tool calls omits it, and the decoder drops it if present. They become proposals.
- **Content provenance.** When a proposal was influenced by untrusted content such as an email body, the proposal records that provenance and the review screen says so. Untrusted content never creates a `Capture` with a user source, so it cannot mint a direct instruction.

### 15.4 Policy table (defaults, editable in settings except where noted)

| Effect | Direct instruction, single target | Bulk or sensitive | Standing rule | Proposal |
|---|---|---|---|---|
| read | allow | allow | allow | allow if granted |
| reversible | allow | review | allow within scope | review |
| sensitive | review | review | allow within scope | review |
| destructive | confirm, not editable | confirm, not editable | not permitted | confirm, not editable |

### 15.5 Permissions view

The popover gets a Connections screen listing each tool, its grants, its standing rules, and its last ten actions. Revoking a tool removes its Keychain items, invalidates its rules, and for OAuth calls the provider's revoke endpoint.

### 15.6 Testing approach

`MockTool` implementations with configurable effect classes, failures, and verification results. Required tests include an email body containing "delete all messages" producing no executable request, a model tool call with a forged `authorization` field being rejected, and replayed or altered approvals failing. See TEST_PLAN.md Phase 9.

## 16. Email (Phase 10) — original plan, superseded by §37

- `EmailProvider` protocol: `listChanges(since:)`, `fetchMetadata(ids:)`, `fetchBody(id:)`, `search(query:)`, plus write capabilities registered as broker tools. Gmail is the only implementation until another is built and tested.
- **Gmail auth.** OAuth 2.0 for installed apps with PKCE and a loopback redirect on `127.0.0.1:<random port>`, opened in the default browser through `ASWebAuthenticationSession` or `NSWorkspace`. Tokens go to Keychain under service `com.shibadityadeb.wren.oauth.gmail`.
- **Developer console setup, done once by you.** Create a Google Cloud project, enable the Gmail API, configure the consent screen, and create an OAuth client of type "Desktop app". If the account is on Google Workspace, user type "Internal" avoids review and token expiry, subject to your admin. With user type "External" in Testing status, Google expires refresh tokens after 7 days, so you would reconnect weekly. The README will document both. This is OAuth configuration, not an AI API key.
- **Scopes.** `gmail.readonly` at connect. `gmail.modify` when you enable archive, trash, or read state. `gmail.settings.basic` when you enable block or filters. Permanent delete needs full `https://mail.google.com/` access, so it stays off unless you enable it explicitly.
- **Sync.** `users.history.list` from the stored `historyId` every 10 minutes while awake, and on wake. Initial sync covers the last 14 days only.
- **Index.** `EmailMessage` SwiftData model with metadata only, see PROJECT_SPEC §9.7. Bodies cached only under the retention setting.
- **Classifier.** Deterministic signals first: your important-senders list, Gmail category labels, `List-Unsubscribe` header, known billing and security sender patterns, calendar invites. The local model then labels the remainder with a category and a one-line reason, validated like intents. Corrections you make are stored as sender or domain overrides that win over both. Email text is wrapped as quoted data in the prompt, and the model output schema has no tool-call field.
- **Briefing.** Details pending the rest of the Phase 10 prompt.

## 17. External AI delegation — original plan, superseded by §39 (there is no API-key path)

Default is the handoff flow in PROJECT_SPEC §9.4. The optional API path is a broker tool `openai.delegate` with effect `sensitive`, because content leaves the Mac. It always shows a review screen containing the exact outbound text. The key lives in Keychain. The returned `model` and reasoning fields are compared with what was requested. Scripted control of the ChatGPT site or app is not planned.


## 18. Permission system (as built, Milestone 2)

Files: `Sources/WrenCore/Authorization/`.

### 18.1 The five steps, kept separate

| Step | Who | Code |
|---|---|---|
| Proposal | user UI, scheduler, model, or content-derived suggestion | `ActionRequest` (origin set by Wren code; `ProposalParser` for model JSON) |
| Authorization | pure function, no I/O | `Authorizer.decide` |
| Execution | registered trusted handler | `ActionHandler.execute` via `ActionBroker.submit` |
| Verification | the same handler re-reads real state | `ActionHandler.verify` |
| Audit | broker, one record per attempt | `AuditRecord` (SwiftData) |

`ActionRequest` has **no authorization field**. Authorization is computed from origin, grants, standing rules, denials and an optional one-time `Confirmation`. `ProposalParser` reads only `action`, `target`, `parameters`. It ignores `origin`, `authorization`, `confirmed`, `priority`, `confidence`, and forces the origin to `.model` or `.untrustedContent`.

### 18.2 Categories and confirmation floors

| Category | Examples | Floor | Can a rule relax it? |
|---|---|---|---|
| localReversible | complete, reopen, drop, snooze, set reminder, edit, apply interpretation, deliver reminder | none | n/a |
| localDestructive | delete item | always confirm | no |
| externalRead | read email (reserved) | none | n/a |
| externalWrite | archive email, delegate to external AI (reserved) | always confirm | no |
| irreversible | send email, permanent delete (reserved) | always confirm | no |

A descriptor can be stricter than its category (`effectiveConfirmation = max(floor, declared)`), never looser.

### 18.3 Decision order (`Authorizer.decide`)

1. Unknown action → deny.
2. Permission not granted → deny. External permissions are never granted by default.
3. `noPrivateDataToExternalAI` and the request is marked private → deny.
4. Origin is untrusted content and the category is not localReversible/externalRead → deny (even with a confirmation).
5. A stored denial for this action+target and the origin is not the user directly → deny (parameters ignored, so rephrasing doesn't help).
6. A confirmation is supplied → it must match the request fingerprint (action, target, parameters), be unused, and be under 5 minutes old → allow; otherwise deny.
7. By origin: **user** → allow unless the floor is "always" (then ask). **system** → allow only for localReversible actions covered by a standing rule. **model** → allow only for localReversible actions covered by a standing rule, else ask. **untrusted content** → ask.

Model confidence, priority and urgency are not parameters of this function.

### 18.4 Standing rules (typed, closed set)

| Rule | Default | Effect | Revocable |
|---|---|---|---|
| autoRemindDeadlines | on | scheduler may set/deliver reminders derived from your deadlines | yes |
| autoApplyInterpretations | on | date rules and the local model may apply their reading of your own captures | yes |
| confirmBeforeDelete | on | restates the destructive floor | no (locked) |
| showDraftBeforeSending | on | email send always asks | no (locked) |
| noPrivateDataToExternalAI | on | private content never goes to external AI | no (locked) |

There is no free-text policy language. Allow-type rules can only cover named localReversible actions.

### 18.5 Grants and denials

Defaults: `local.items.modify`, `local.items.delete`, `local.reminders`, `local.notifications`. Seeded once; revocations persist across restarts. Declining a confirmation records a denial for that action+target; Settings › Permissions › "Things you declined" lifts it.

### 18.6 Audit

`AuditRecord`: request id, time, action, category, target kind/id, target label (≤ 80 chars), origin label, authorization label, status, verification, confirmation obtained, dry run, detail (≤ 200 chars). No parameters, no item notes, no content bodies. Trimmed to the newest 2000. Viewable in Settings › Activity log.

## 19. Daily engine (as built)

Files: `Sources/WrenCore/Daily/`.

- `WrenEngine.tick()` delivers due reminders (through the broker, origin `.system`, authorized by `autoRemindDeadlines`), then evaluates the briefing and check-in. It is called on launch, wake, clock/timezone/day change, and a timer set to `nextWake()` (earliest reminder, next daily window, at most 60 s).
- `Briefing.build` and `CheckIn.build` derive everything from persisted items. No model.
- `DailyRun` (one row per local day, keyed `yyyy-MM-dd`) records each event's state: `pending, sent, skippedEmpty, missed, undelivered, completed, dismissed, disabled`. The state is written **before** delivery (at-most-once), so a crash or restart can't send twice.

| Event | Default | Window | Started inside window | Started after window |
|---|---|---|---|---|
| Briefing | 11:00 | until check-in time (or 23:00 if check-in off) | sent once, late | `missed`, never sent |
| Check-in | 19:00 | until 23:00 | sent once, late | `missed`, never sent |

Empty summaries are `skippedEmpty` unless "send even when there's nothing to report" is on. Without notification permission the state is `undelivered`, and the content stays viewable in the menu. Times use `Calendar.time(minutesAfterMidnight:on:)` with `.nextTime`, so a time inside a DST gap moves to the next valid minute; day keys use the local calendar, so fall-back days still get one event.

Check-in actions (Done, Snooze, Leave for tomorrow, Reschedule…) are user actions through the broker. The engine never changes items itself.

## 20. Launch at login and single instance

- `SMAppService.mainApp` behind `LoginItemService`; policy in `LoginItemController`. Default **off**. On launch, if you opted in and macOS lost the registration (app moved or replaced), Wren registers again; it never registers unasked.
- `.notFound` from macOS (never registered) is shown as Off. Registration errors are shown in Settings and the toggle returns to off.
- A second Wren process (for example login launch plus a manual open) exits immediately, so only one scheduler runs.

## 21. Dependency injection

| Concern | Protocol / type | Production | Tests |
|---|---|---|---|
| Clock and timezone | `WrenClock` | `SystemClock` (autoupdating calendar) | `FixedClock` |
| Persistence | `WrenStore`, `PolicyStoring` | SwiftData file store | in-memory or temp-file store |
| Notification delivery | `WrenNotifier` | `NotificationService` | `FakeNotifier` |
| Scheduling | `WrenEngine` + `DailySchedule` | timer in `AppModel` | direct `tick()` calls |
| Model access | `IntentProcessor(client:model:)` | `OllamaClient` | stub `URLProtocol`, nil client |
| Authorization | `Authorizer` (pure), `ActionBroker` | SwiftData policy | same, temp store |
| Login item | `LoginItemService` | `SMAppService` | `FakeLoginService` |


## 22. Goals (Milestone 3)

- `Goal` (SwiftData): title, original wording, notes, optional target date, status `active | paused | completed | archived`, progress method, manual progress, created/updated/last-progress timestamps, linked `tasks` (Commitments; nullify on delete), and `GoalEvent` history.
- Status transitions: active ↔ paused, either → completed or archived, completed or archived → active. Anything else is rejected.
- **Progress is explicit.** Default method is *manual* (the user sets a percentage). *Linked tasks*: completed ÷ (pending + completed); dropped and archived are excluded and the explanation says so. *Milestones*: same, over tasks flagged `isMilestone`. Every method returns a sentence explaining the number, including "each counts equally, whatever its size". With nothing to count, progress is "—", not 0%.
- Target date and status change only through `goal.edit` / `goal.setStatus`; target date changes are logged as their own history event. Completing a linked task updates `lastProgressAt` and logs a goal event.
- "Turn into a goal" archives the item (never deletes), links it to the new goal and keeps its history.

## 23. Waiting items

Commitment fields: `waitingOn`, `expectedResponse`, `waitingSince` (set on first update), `followUpAt`, `followUpAcknowledgedAt`, optional goal link. History: `waitingUpdated`, `followUpScheduled`, `followedUp`.

A follow-up is **due** when `followUpAt <= now` and it hasn't been acknowledged since that date. Acknowledging (with an optional next date the user picks) records an attempt and silences it; it only returns on the new date. A due follow-up not acknowledged within the grace period (default 3 days) moves to the stale review. Wren never sends follow-up messages.

## 24. Insights and review

`InsightEngine.compute(items:goals:now:calendar:settings:)` is pure and deterministic.

| Kind | Criteria (defaults, adjustable) | Fingerprint |
|---|---|---|
| followUpDue | waiting, follow-up date arrived, not acknowledged, within grace (3 d) | follow-up timestamp |
| postponed | commitment snoozed or deadline moved later ≥ threshold (3) times | count ÷ threshold (bucket) |
| goalApproaching | active goal, target within 7 days or past | bucket (soon/imminent/past) + target day |
| stale | task: no activity 14 d **and** no future deadline or reminder **and** not overdue; idea: 30 d; waiting: 14 d without a follow-up date, or follow-up past grace; goal: no progress or linked-task activity 14 d | last-activity day |

`InsightRecord` keys each observation by kind + subject + fingerprint. Dismissed or resolved observations stay closed for that fingerprint; a new fingerprint (situation changed) can surface again. `surfacedAt` records inclusion in a briefing or check-in, so the daily notifications raise each observation once; the Review tab and on-demand panes still show every open one. Review actions are ordinary broker actions; nothing is archived, deleted or rescheduled automatically.

Briefing: due follow-ups fill "follow-ups due"; up to 3 other fresh insights become "needs a decision". Check-in: up to 3 fresh postponement or follow-up insights. The briefing is no longer empty when only insights exist.

## 25. Contextual references

`ContextResolver` (deterministic) recognises:

| Pattern | Action |
|---|---|
| move / push / reschedule / postpone X to D | `item.reschedule` if X has a deadline, else `reminder.schedule` |
| remind me about X D | `reminder.schedule` |
| mark X as done, I finished X, X is done | `item.complete` |
| drop X / archive X | `item.drop` / `item.archive` |
| what am I waiting for | answer from waiting items |
| which goals have I made no progress on | answer: active goals with no activity for 7+ days |

Targets: pronouns use the open item, then the most recent captured/opened/notified item; with neither, Wren asks. Titles: exact (3), every word (2), some word (1). One exact or one full match resolves; several full matches ask (the open item breaks a tie); a single partial match resolves with a "closest match" warning; several partial matches ask. Closed items are never targets. A move that lands on the current date is reported, not proposed.

Optional model fallback (`ModelTargetPicker`) runs only when nothing matches and a local model is ready: the model picks an index from a list Wren supplies; out-of-range or failed answers are ignored; the proposal has origin `.model` and is labelled.

**Authorization.** Proposals carry origin `.conversational(text)` (or `.model`). The Authorizer always returns *needs confirmation* for `.conversational`, even when a standing rule would allow the action. The capture panel shows the preview; Confirm mints a confirmation bound to that exact action, target and parameters (5-minute lifetime, single use). Cancel is audited as "Cancelled by you" without a lasting denial, so the user can rephrase.


## 26. Local AI readiness (Milestone 4)

Files: `Sources/WrenCore/AI/`.

Root cause found in the audit: Ollama was installed and running, but its only model was `nomic-embed-text` (embedding-only). Wren correctly filtered it out, found no chat model, selected nothing and showed "No AI", with no way inside the app to fix it. The old status also treated "not installed" and "not running" alike, and reported ready as soon as a model was listed, without testing it.

`AIReadiness`: `disabled · checking · notInstalled · notRunning · noChatModel · selectModel · configured(model) · ready(model, verifiedAt, latency) · unavailable(model, reason)`.

| Check | How |
|---|---|
| Installed? | File existence of `/Applications/Ollama.app`, `~/Applications/Ollama.app`, `/usr/local/bin/ollama`, `/opt/homebrew/bin/ollama`. Nothing is executed. |
| Running? | `GET /api/version` on 127.0.0.1:11434 |
| Chat models | `GET /api/tags`, keeping models whose `capabilities` include `completion` |
| Selected | stored choice is installed; a single chat model is selected automatically |
| Ready | `POST /api/chat` with a harmless JSON schema request; answer must parse with `ok: true` |

`ready` is set only by a parsed answer: the Test button, or the first successful real capture/command (promotes `configured`). Any failed request demotes to `unavailable` with the reason. Timeouts and refused connections map to readable errors. "Start Ollama" asks macOS to open the installed Ollama app (`NSWorkspace.openApplication`); Wren runs no commands.

## 27. Model download

`OllamaClient.pull(model:)` streams `POST /api/pull` (`stream: true`) as NDJSON. `PullAggregator` sums per-layer `completed/total` by digest, raises Ollama `error` lines, and treats a stream that ends without `success` as failed. `pullToCompletion` turns consumer cancellation (which silently ends an async stream) into `CancellationError`. Model names must match Ollama's name grammar, so no arbitrary text reaches the request. Only the loopback client can be constructed. The UI shows the recommended model and its approximate size, checks free disk space (needs size + 2 GB), shows progress with cancel, offers Retry/Resume, and after success refreshes models and runs the readiness test. There is no download on launch or in the background.

## 28. Model-assisted understanding

Deterministic first, model second:

1. `ContextResolver.resolve` (no model): commands with polite prefixes ("could you…"), multi-sentence input (last command sentence wins), "the previous task", "the day before it's due", and eight grounded queries (`waiting, recentPromises, quietItems, postponed, goalsNoProgress, overdue, dueSoon, doneRecently`).
2. If that finds nothing and the text looks like a command or question (`mightBeCommandOrQuestion`), and a model is configured or ready, `ModelCommandInterpreter` asks the model to route it: `intent · operation · target_reference · target_id · date_phrase · days_before_deadline · question`. Plain captures skip the model and save immediately.

Validation: `target_reference` and `date_phrase` must appear verbatim in the user's text; dates are parsed by `DateParser`, never taken from the model; `target_id` must be one of at most 30 listed short IDs. The **target is found by the deterministic resolver** from the quoted words. If the model's pick disagrees, or is the only support for a target, Wren asks ("Did you mean this one?"). Questions are answered by `ContextResolver.answer` from stored records; each `AnswerLine` carries the record ID, and `basis` says what was counted. Anything invalid falls back to saving the text as a capture.

Proposals from either path use origin `.conversational(text)`, which the Authorizer never runs without a confirmation bound to action, target and parameters (5 min, single use). This also closes a Milestone 3 gap: the old model fallback produced `.model` proposals, which a standing rule could have auto-allowed for reminders.

Capture interpretation (`IntentProcessor`) additionally accepts an optional `clarification_question`, shown as a note; it never changes the item. Prompts are bounded (≤ 500 characters of input, ≤ 30 candidates of ≤ 80 characters, `num_ctx` 4096) and never leave the Mac.

## 29. Distribution

| Piece | Detail |
|---|---|
| Architectures | Universal (arm64 + x86_64). SwiftPM's multi-arch mode rejects the package's per-target Swift 5 language setting, so each triple is built separately (`--triple arm64-apple-macosx14.0`, `x86_64-apple-macosx14.0`) and merged with `lipo`. No third-party code; one executable. |
| Minimum OS | macOS 14.0 (unchanged; SwiftData) |
| `--smoke-test` | Starts the core in memory (store, policy, broker, date rules, resolver, insights, menu-bar image), prints `arch=…`, exits. No UI, no user data. Run per slice in CI. |
| `scripts/build-app.sh` | `[debug|release] [--universal]`; version from `VERSION`, build number from commit count; ad-hoc or Developer ID signing via `WREN_SIGN_IDENTITY` (hardened runtime, secure timestamp, no entitlements) |
| `scripts/package-dmg.sh` | tests → universal build → stage (Wren.app, /Applications link, `Install Wren.txt`) → UDZO DMG → SHA-256 → verify |
| `scripts/verify-dmg.sh` | checksum, `hdiutil verify`, contents, bundle id/version/LSUIElement/min OS, both slices present, no nested executables, no fixtures/secrets/debug strings, signature, notarization when required, `--smoke-test` on every slice this Mac can run |
| CI (`ci.yml`) | tests natively on `macos-15` (arm64) and `macos-15-intel`; universal unsigned preview DMG uploaded as an artifact; re-verified on Intel |
| Release (`release.yml`) | tag `v*`: tag must match `VERSION`; tests on both architectures; optional certificate import (temporary keychain) → sign → package → `notarytool submit --wait` → staple → verify; verify on Intel; publish. Stable tags require notarization; unsigned builds publish only under prerelease tags. Manual dispatch builds an artifact only. Actions pinned to commit SHAs; `contents: write` only in the publish job. |


## 30. Main window and activation (Milestone 5)

Wren stays an `LSUIElement` menu-bar app (no Dock icon). `MainWindowController` owns one `NSWindow` hosting `MainWindowView` (SwiftUI `NavigationSplitView`: Overview, Items, Goals, Review, Local AI, Settings). Items/Goals/Review/Settings reuse the popover panes through `RouteView` with `\.wrenInWindow` hiding popover chrome; the window and popover share `AppModel.route`.

| When | Behaviour |
|---|---|
| Launched normally (Finder, Spotlight, `open`) | window shown and activated (`NSApp.activate` + `makeKeyAndOrderFront` + `orderFrontRegardless`) |
| Launched as a login item (`keyAELaunchedAsLogInItem`) | stays in the menu bar |
| Opened again while running | `applicationShouldHandleReopen` → window to front |
| A second process starts | `InstanceGuard`: exits and activates the running copy; a `--relaunch` (restore) waits up to 10 s for the old copy to quit |
| Window closed | Wren keeps running (`applicationShouldTerminateAfterLastWindowClosed` → false) |

Frame is remembered (`WrenMainWindow` autosave). The logo is the bundled `Wren.icns` (generated from `assets/logo.png`), falling back to the traced vector mark.

## 31. Export format (`wren-export` v1)

`WrenExport` (Codable). Top level: `manifest` (format, formatVersion, exportedAt, appVersion, schemaVersion, timeZone, counts, includes, excludes), `items`, `goals`, `observations`, `dailyRuns`, `policy`, `activityLog`. Items carry `goalID`, `isMilestone`, `waiting` (who, what, since, follow-up, acknowledged) and `history` (at, kind, note); goals carry `linkedItemIDs`, the progress method and its explanation. Dates: ISO 8601 UTC with fractional seconds. `WrenExport.decode` validates format and version and rejects newer versions. `WrenExport.write` is atomic and refuses to replace a file unless the save dialog confirmed it. Excluded: credentials (none are stored), preferences, AI models, runtime state.

## 32. Backups and restore

`BackupManager` (in `WrenCore/Data`).

- **Snapshot:** `sqlite3_backup_*` from the live store (opened read-write so a closed WAL store can be read; only reads are issued) into `Backups/<timestamp>-<reason>/Wren.store`, switched to a single-file journal, then `PRAGMA integrity_check` and a Wren-table check.
- **Manifest** `wren-backup` v1: createdAt, appVersion, schemaVersion, reason (`manual · automatic · preMigration · preRestore · preReset`), SHA-256, size, counts.
- **Retention:** newest 7 automatic, 10 manual, 5 per other reason.
- **Verify:** manifest format/version, checksum, integrity → a verified temporary copy. Legacy `schema-vN` folders (0.2–0.4: store + WAL) are copied, checkpointed and checked.
- **Restore:** broker action `data.restoreBackup` (local destructive, always confirmed) → verify → `preRestore` backup → stage in `Restore/pending/`. Wren relaunches; before the store opens, `WrenStore.open(manager:)` moves the live store to `Restore/replaced-<ts>/` and the staged one into place. If the result won't open, it rolls back and reports `.failedAndRolledBack`. A corrupt staged file fails the integrity check before anything moves. The newest 3 replaced stores are kept. The restored database gets an audit entry noting the restore.
- **Delete:** `backup.delete` (confirmed); paths must be direct children of `Backups/`.
- Pre-upgrade backups use the same snapshot once per schema version.

## 33. Notification pause

`NotificationPause { since, until? }`, persisted in user defaults. `WrenEngine.tick` returns immediately while active: no deliveries, no daily-run changes, no schedule changes. When it ends (expiry on the next tick, or `resume()`), `deliverPauseSummary` sends one notification listing everything due; only if macOS accepts it is each reminder recorded as sent through `reminder.markSummarized` (covered by the auto-remind rule), with a history note. Then normal ticking resumes, and the DailyRun window rules decide whether today's briefing or check-in is still sent (once) or recorded missed.

## 34. Reset

- **Reset preferences:** app action `settings.reset` (local destructive, confirmed) removes exactly the keys in `WrenSettings.allKeys` and unregisters the login item.
- **Remove all data:** `data.eraseAll` (irreversible category, always confirmed; content-originated requests are denied) deletes all user models, keeps only this request's audit records, and re-seeds default grants and rules. "Back up first" makes a `preReset` backup and aborts if it fails. Backups, the app and anything outside `~/Library/Application Support/Wren` are untouched.
- No "clear test data": Wren can't distinguish test entries reliably.


## 35. Connector framework (as built, 0.9.0)

Files: `Sources/WrenCore/Connectors/`.

- `ConnectorCatalog` declares every connector once: id, name, icon, summary, `ConnectorAuth`, capabilities (each marked implemented or not), Wren permissions, privacy text, cleanup on disconnect, allowed hosts. Settings is generated from it.
- `ConnectorState` is `.connected` only after a successful, authorized provider call.
- `CredentialStore`: `FileCredentialStore` in the app: `<data folder>/Credentials/<key>`, folder 0700, files 0600, atomic writes. There is **no Keychain** use (it caused password prompts); legacy Keychain items are left untouched. Credentials never enter SwiftData, exports, backups or logs. "Remove all Wren data" revokes and deletes them.
- `ConnectorHTTP`: HTTPS only, per-connector host allowlist, maps 401/403/429/5xx/timeouts to `ConnectorError`, never logs bodies or headers.
- `ProviderConfig`: maintainer registrations injected into `Info.plist` at build time (`WrenGoogleClientID`, `WrenGoogleClientSecret`, `WrenGoogleStatus`). ChatGPT and Notion register Wren dynamically.

| Connector | Auth | "Connected" means | Hosts |
|---|---|---|---|
| ChatGPT | Sign in with ChatGPT (OAuth code + PKCE + nonce, dynamic client) | `GET /v1/models` succeeded with plan scope | auth.openai.com, api.openai.com |
| Gmail | Google installed-app OAuth (PKCE, loopback, Desktop client ID + secret) | `users/me/profile` read | gmail.googleapis.com, oauth2.googleapis.com, accounts.google.com |
| Google Calendar | same sign-in | `calendars/primary` read | www.googleapis.com |
| Calendar (this Mac) | macOS Calendars permission (EventKit) | access granted, calendars listed | — |
| Notion | Notion MCP (dynamic registration, OAuth + PKCE) | `notion-get-self` tool call | mcp.notion.com |
| Voice | macOS Microphone + Speech Recognition | permissions + on-device recognizer available | — |

## 36. Google OAuth

`GoogleOAuth`: authorization URL with S256 `code_challenge`, `state`, `access_type=offline`, `prompt=consent`, `include_granted_scopes=true`; `LoopbackReceiver` on `127.0.0.1` (random port, local-only) accepts exactly one GET with the expected `state`. `exchange` and `refresh` send the Desktop client's `client_secret`: Google rejects Desktop-client token requests without it (`invalid_request: client_secret is missing`, verified live 2026-10-11), and documents installed-app secrets as non-confidential. A build without the secret maps that answer to `OAuthError.clientSecretMissing` → state "not available in this build" (a maintainer problem, not the user's). One token (`google.account.tokens`) serves Gmail (`gmail.readonly`, optionally `gmail.modify`) and Calendar (`calendar.readonly`); each feature turns on only for the scopes Google granted. Disconnect revokes at Google.

## 37. Gmail inbox intelligence

Files: `Gmail.swift` (client), `MailIntelligence.swift` (pure logic), `WrenKit/AppModel+Mail.swift` (monitor), `WorkflowViews.swift` (Inbox UI).

- **Client** (`GmailClient: GmailAPI`): `profile` (email + `historyId`), `inboxMessageIDs` (`labelIds=INBOX`, `includeSpamTrash=false`), `history(since:)` (`messageAdded/Deleted`, `labelAdded/Removed`; HTTP 404 → `GmailSyncError.historyExpired`), metadata fetches (From, To, Subject, Date, `List-Unsubscribe`, labels, snippet; no bodies or attachments) a few at a time. The only write is `perform(_:on:)` over `GmailAllowedAction`, whose single case is `markRead` (`messages.modify` with `{"removeLabelIds":["UNREAD"]}`). No send, archive, trash, delete, label or filter code exists.
- **Sync** (`MailSync`): first run reads recent inbox mail (`newer_than:7d OR (is:unread is:important newer_than:30d)`, ≤150) as a *baseline* (never alerted as new). Afterwards only history changes: new inbox messages are fetched, label changes update read state, leaving INBOX or entering SPAM/TRASH removes the message. An expired cursor falls back to a full read where mail newer than the last sync still counts as new. A different account resets the state. Items older than 30 days are pruned.
- **Triage** (`MailTriage`): deterministic and explainable. Signals: user sender rules and important senders, Gmail IMPORTANT/STARRED, bulk (promotions/social/forums, `List-Unsubscribe`, no-reply senders), security notices, urgency words, deadlines parsed by `DateParser` (≤24 h urgent, ≤72 h time-sensitive), meeting changes, requests, recruiting/work, financial notices. Categories: urgent, timeSensitive, needsResponse, professional, financial, informational. Output = category, reasons, score, deadline, suggested action. The snippet shown is factual; reasons and suggestions are labelled inferred. Corrections: per-message category (sticky) and per-sender always/never-important rules.
- **Alerts** (`MailAlertPolicy`): only new, unread, not dismissed/snoozed messages whose category meets the user's level; once per message (`alertedAt`, `alertedCategory`); one per conversation within 6 h unless more urgent; at most 3 individual alerts, the rest as one summary; quiet hours hold alerts and release them afterwards.
- **Digest** (`MailDigest`): one per slot (`yyyy-MM-dd` in the chosen zone). `due` returns the latest slot without a record (missed slots collapse into one, marked late). `build` records the digest in state *before* delivery (at-most-once across restarts); it covers unread mail since the previous digest plus important unread mail ≤14 days, grouped by thread, most pressing first. With the digest on, the morning briefing omits email.
- **Monitor** (`AppModel+Mail`): a timer (default 5 min, 2–60) while Wren runs and Gmail is connected; also after wake. Each check is `ActionBroker.performExternal(email.read)` from origin `.system("mail monitor")`, allowed only by the standing rule `monitorConnectedEmail` (scoped to that origin, §15/§18), or `.user` for Check now. Errors: 401/403 → reconnect state; 429 and network errors → back off up to 6× the interval. Mark as read is `email.markRead` (external write, permission `emailModify`, granted only while Google granted `gmail.modify`; the button press on that message is the confirmation); success requires Gmail's returned labels to lack UNREAD; failure keeps the message unread and offers Retry.
- **Storage**: `MailboxStore` → `<data folder>/Mail/mailbox.json` (0600, complete file protection), outside `Wren.store`, so never in backups or exports; deleted on disconnect and "Remove all data". No email content goes to any AI service; the local model isn't used for mail either.

Calendar (`GoogleCalendarClient`, `MacCalendarConnector`) is unchanged: read-only, merged, de-duplicated.

## 38. Notion

Notion's hosted MCP server (`https://mcp.notion.com/mcp`): OAuth discovery, dynamic client registration, PKCE + state over the loopback receiver, token refresh, revocation. Tools used: `notion-get-self`, `notion-search`, `notion-fetch`, `notion-create-pages` (create is an external write, always confirmed). There is no integration token or REST client.

## 39. GPT delegation (Sign in with ChatGPT)

- **Routing** (`IntentRouter.aiRequest`): deterministic patterns for "ask/get/tell/have/search in/check with GPT …", "… on GPT", "GPT, …" and fixed handoff phrasings. The prompt keeps the whole request and drops only framing meant for Wren ("let me know when it's finished"). Reminders, explicit notes and stored-data questions are routed first and stay theirs; a pending reminder question never captures a new GPT request (`ReminderFollowUp`).
- **Auth** (`ChatGPTAuth`): OIDC discovery at auth.openai.com, dynamic client (`dynamic_agent_client` → `oaiapp_…`), scopes incl. `chatgpt.tokens.use.direct` (plan usage), RS256 ID-token verification against JWKS, refresh with rotation persisted before use, revocation.
- **Requests** (`ChatGPTPlanClient`): `GET /v1/models`, `POST /v1/responses` (`stream: true`, `store: false`) with the user's token only. Success requires `response.completed`. No API key, no fallback billing. The Responses call returns no ChatGPT conversation URL, so none is stored (`providerURL` stays nil).
- **Thinking and research (0.10)**: `DelegationIntent` reads the user's words: deep-thinking phrases set `depth = .deep` → `reasoning: {effort}` ("high", or the strongest level in the model's `supported_reasoning_levels`; none if the model lists none); research phrases set `kind = .research` → `tools: [{"type": "web_search"}]`. Nothing else is added (the plan route rejects sampling, background and conversation fields). Evidence comes from the stream: `response.output_item.done` items of type `web_search_call` are counted and `url_citation` annotations (`response.output_text.annotation.added` and finished message items) become `sources`; the completed response's `reasoning.effort` is `reportedEffort`. Observed live: on this route the completed event's `output` array is empty, so events are the source of truth. `subscription_sharing_unsupported_capability` (with `error.param`) maps to `ChatGPTError.unsupportedCapability` → failure `.unsupportedCapability`, not retryable as-is; `retryWithStandardSettings` reruns the same record without the extras only when the user chooses.
- **Jobs** (`AskService`): `start` persists a `DelegationRecord` as `running` (original words, prompt, channel) before sending, then runs independently of any UI; outcome `completed` / `partial` / `failed(failure)` / `cancelled`, with requested and reported model, start/completion times and attempts. Duplicates (same normalized prompt running, or finished within 15 s) return the existing record. `retry` reruns a retryable failure on the same record and refuses completed ones. `recoverInterrupted` (at launch) marks leftover `running` records as interrupted (and relabels pre-v6 plan answers as completed). `onFinished` fires once; the app sets `notifiedAt` and posts "GPT finished: … View result." unless that result is on screen; the notification, panel, overview and Delegate open `Route.delegation(id)`.
- **Privacy**: only the request text is sent by default. Delegate can add Wren items or Notion pages the user picks; private ones need ticking (`noPrivateDataToExternalAI` requires a confirmation minted with `includingPrivate`), secrets are redacted unless the user opts in. A retry re-sends exactly the same text with the same approval. Audit records hold labels and model names only.
- **Handoff fallback**: `chatgpt.handoff` copies the prompt and opens ChatGPT; status `handedOff` = "Awaiting submission" until the user pastes an answer. It is never reported as a completed GPT query.

## 40. Voice (0.10.1: push-to-talk)

Voice is explicitly activated only; there is no wake word, no idle listening and no setting for either (the 0.9 "Hey Wren" listener was removed in 0.10).

**Shortcut.** Push-to-talk is a Carbon `RegisterEventHotKey` hotkey (default ⌥ Space, `HotKeyService` id 2) registered for both `kEventHotKeyPressed` and `kEventHotKeyReleased`. Carbon reports the *key* going up; letting go of the *modifier* first is caught by polling `NSEvent.modifierFlags` (class property: current modifier state, no Accessibility or Input Monitoring permission) every 50 ms while listening. The hotkey consumes the key combination, so the focused app never receives the space. Typed capture moved to ⌥⇧ Space (`WrenSettings.hotKey` gives way automatically if a saved capture shortcut equals the push-to-talk one). New preference keys (`pushToTalkEnabled`, `pushToTalkHotKey`, `voiceCheckBeforeRunning`) replace the 0.10.0 ones, which are deleted at launch.

**Session** (`VoiceSession`, WrenCore, pure; microphone and permissions injected):

    idle → requestingPermission? → listening(hold|button) → transcribing → transcriptReady → processing
         → completed | needsClarification | failed            cancelled: from any step before processing

- `press(trigger)`: key-down or a Voice click. Ignored while busy (requestingPermission … processing), so key repeat and repeated presses can't start a second recording. Asks macOS only when a permission is undetermined; a key-up during the prompt (`releasedDuringPermission`) cancels this press (`cancelled(.releasedBeforeRecording)`); the user holds again to record. A `generation` counter makes late permission answers and late transcripts from cancelled utterances no-ops.
- `release()`: key-up (either key) or Stop → `transcribing`. `SpeechStreaming.finish` closes the microphone (`AVAudioEngine` stopped, tap removed) **before** `endAudio()`, then waits up to 5 s for the recogniser's final result (falls back to the last partial).
- `TranscriptAssessment`: empty → `cancelled(.nothingHeard)`; confidence below 0.35 (average of final-segment confidences, when reported) or a single short word → shown for confirmation, not run; otherwise run.
- The app runs a clear transcript ~0.45 s after showing it (`beginProcessing`) through `AppModel.submitFromCapture(channel: .voice)` → `ExecutionRouter` (§45), then reports the real reply with `finishProcessing`: answers → `completed(title)`, proposals / clarifications → `needsClarification`, not-found and failures → `failed(.commandFailed)`, GPT → `completed("GPT request submitted")` (the panel's headline follows the Ask card to "GPT finished"; the completion notification is unchanged).
- Button mode keeps `CommandEndpointer` (pause, 7 s silence, 30 s cap); a held shortcut is capped at 60 s.
- Screen lock / sleep → `cancel(.screenLocked)`; quit → `shutdown()`.

The panel (`CaptureView.voiceStatus`) renders one row per real phase: "I'm listening…" with a level-driven ring (real input level from the tap) and the recogniser's genuine interim text, "Transcribing your voice…", "Working on it…", the result, "One quick question", or the failure with its recovery action. Return after a result closes the panel instead of re-submitting the words. A reminder still missing its subject ("remind me every weekday at 3 PM") keeps its schedule when the next answer supplies the subject (`ReminderFollowUp.subjectAnswer`); an answer with its own date is treated as a new request.

`LocalSpeechModel.status()` reports Apple's on-device model for the current locale. macOS manages that model (Dictation settings); Wren bundles and downloads none and sets `requiresOnDeviceRecognition`.

## 41. Scheduled reminders

`ReminderScheduler` keeps macOS's pending `UNCalendarNotificationTrigger` requests equal to the store: identifiers encode item + time (`wren.reminder.<id>.at.<epoch>` / `.rep.<weekday>.<hhmm>`), so a changed time is a new request and stale ones are cancelled. Reconciled at launch, on every store change, on wake, time-zone/clock changes and when notification permission changes. Repeating rules use wall-clock components (DST-safe). Scheduled IDs are saved on the item. Delivered while Wren is quit.

## 42. Lifecycle

Single instance (`InstanceGuard` + `flock` on `Wren.lock`), one status item created in `applicationDidFinishLaunching` and removed on terminate, closing the window keeps Wren running, ⌘Q terminates (any recording stopped, shortcuts released, lock freed). When quit, Wren neither records nor checks mail; macOS still delivers already-scheduled reminders.

## 43. Schema history

v4: `Commitment.isPrivate`, `DelegationRecord`. v5: `recurrenceRaw`, `notificationIDsRaw`. v6 (0.9.0): `DelegationRecord.original, channelRaw, requestedModel, reportedModel, startedAt, completedAt, attempts, failureRaw, notifiedAt, seenAt, providerURL, includesPrivate`; new statuses `running` and `partial`. v7 (0.10.0): `DelegationRecord.kindRaw, requestedEffort, reportedEffort, webSearchRequested, webSearchCalls, sourcesJSON`. v8 (0.11.0): `DelegationRecord.webStateRaw, webMethodRaw, parentID`. Every change is additive (lightweight migration); a consistent backup is taken before a new schema first opens data, and a newer schema is refused by older Wren (`Wren.schema` marker). Verified on a copy of a real 0.8.0 store.

## 44. Standing-rule scope

Rules that let Wren read external data on its own name the scheduler they speak for (`systemScope`): `includeConnectedSourcesInBriefing` → `.system("briefing")`, `monitorConnectedEmail` → `.system("mail monitor")`. The Authorizer matches rule and origin, so turning one off can't be bypassed through the other.

## 45. Execution router (0.10)

`ExecutionRouter.operation(for:)` (WrenCore, pure) names one operation before anything runs: `CreateTask`, `CreateReminder`, `QueryStoredItems`, `ChangeItem`, `DelegateToChatGPT`, `SearchGmail`, `OpenEmail`, `MarkEmailRead`, `QueryCalendar`, `OpenDelegationResult`, `SaveNote`, `GeneralQuestion`, `Capture`, `ClarifyIntent`. It layers on the existing deterministic classifiers (`IntentRouter`, `ReminderCommand`, `ContextResolver`, `EmailQuestion`, `CalendarQuestion`) and adds email actions, result lookup and clarification for empty assistant requests. `AppModel.submitFromCapture` (typed, panel, voice, debug URL) runs the operation through its own subsystem: reminders via `BuiltInAction.createReminder`, item changes as confirmed proposals, GPT via `AskService`, Gmail via the broker. `MarkEmailRead` from words only opens the message; the provider change needs the button, its confirmation and the `gmail.modify` grant. Each run stores an `ExecutionResult` (operation, success, entity ID, error, needs-user) and logs it without user text. `SubmissionGuard` drops the same channel+text while it runs or within 3 s after, and the same guard keys notification actions (Done, Snooze, Mark as read, Snooze alert) so a duplicated action changes state once. Nothing the router reads (model output, email text, GPT answers) can grant a permission; authorization stays in the broker.

## 46. ChatGPT website vs. ChatGPT in Wren (0.11)

**Routing** (deterministic, WrenCore):
- `IntentRouter.aiRequest` matches the fixed phrasings and, as a general rule, any sentence naming GPT/ChatGPT as a destination ("in/on/with/via/using/through/into GPT", `destinationRequest`). That sentence goes to ChatGPT, with only the destination and the framing around it removed. "Email the GPT team" names it as a topic and doesn't match.
- Questions naming no assistant are `generalQuestion` → `AskLocalAI`.
- `DelegationFollowUp.detect` ("continue that research", "ask it to go deeper", "find more sources", "open that in GPT") runs before new-request detection, so "continue that research in ChatGPT" is a follow-up, not a new request about continuing.

**Two modes** (`ChatGPTMode`, setting *When you ask GPT*):
- **`web`** (default): the ChatGPT website, through the existing broker action `chatgpt.handoff` (permission `chatgptHandoff`, now granted by default and revocable in Connectors).
  - The record (`destination = .chatgptHandoff`) is saved as `prepared`. Then the prompt is copied (always) and `chatgpt.com` opened, and it becomes `awaitingSubmission`, or `openedInChatGPT` with the experimental link. If either step fails it becomes `failedToOpen`.
  - **I sent it** → `submittedUnverified`; a pasted link validated by `ChatGPTWeb.conversationURL` → `conversationLinked`, stored in `providerURL`.
  - `DelegationStatus` stays `handedOff` (not final), so a handoff is never announced, never notified and never shown as *Completed*.
- **`inWren`**: the Sign in with ChatGPT Responses path (§39), labelled *Run with connected ChatGPT in Wren*.
  - Its records say they aren't ChatGPT conversations. The primary action is *Open result in Wren*; *Open ChatGPT website* opens only the site.
  - If not signed in, the card offers Connect or *Open in ChatGPT website instead*, never the local model.
  - Switching a request between modes is an explicit user action (*Run in Wren instead*); Wren never switches silently.

**Why a handoff.** OpenAI documents no supported way for an app to create a ChatGPT website conversation, submit to it, read its answer or learn its URL. Sign in with ChatGPT explicitly "does not grant access to their ChatGPT conversations", and the plan route requires `store: false` and rejects `conversation`.
- `chatgpt.com/?q=` is undocumented and community-reported. Tenable (TRA-2025-22) reported that it auto-submitted, and OpenAI then added "auto-submit protections based on the sec-fetch-site header", so its behaviour varies.
- Wren therefore uses `?q=` only when the user opts in after checking it with **Check it in my browser…** (`PrefillCheck`). Even then it records *opened*, never *sent*, copies the prompt as well, and falls back to clipboard-only above 1,500 characters or for the ChatGPT Mac app.
- A browser extension that watched chatgpt.com to learn conversation URLs or completion was considered and **not built**: it would read the user's ChatGPT pages, depends on a private and changing UI, and needs a separate extension install and consent per browser. The user links the conversation instead (clipboard read only on click).

**0.11.1: Ask in ChatGPT.** The question goes into ChatGPT's composer by default, with no copying.
- Measured live on 2026-10-14 in the maintainer's signed-in Chrome, by watching the tab's address:
  - `?q=` was consumed (the address became `chatgpt.com/`) and no conversation was created within 40 s. `?prompt=` behaved the same.
  - So the website doesn't auto-submit an app-opened link. The state after opening is *Prompt loaded, submission unverified*.
- **Opt-in detection** (`chatgptDetectConversation`, `BrowserTabs`, `ChatGPTTabWatcher`):
  - Before opening, Wren reads the browser's ChatGPT tabs. This uses the standard AppleScript dictionary of Chromium browsers (stable tab `id`), filtered to chatgpt.com/openai.com inside the script, and needs the `NSAppleEventsUsageDescription` text and the `com.apple.security.automation.apple-events` entitlement.
  - After opening, the single new ChatGPT tab is Wren's. With more than one new tab, Wren doesn't guess and stops.
  - Every 2 s for up to 20 minutes, `chatgpt.com/c/<id>` means ChatGPT created the conversation, so the question was really sent: `submittedVerified`, with the link stored. An auth page means `signInRequired`; a closed tab ends the watch.
  - Pitfall found live: inside Chrome's `tell` block `tab` is Chrome's class, so the field separator must be made outside it.
  - Safari and other browsers aren't followed; the user links conversations there.
- Questions with apparent secrets aren't put in a URL (`WebStart.review`).

**Follow-ups.** `followUpTarget` is the delegation on screen, else the most recent assistant request.
- Web: a linked conversation opens directly, with only the new instruction copied to paste. Unlinked, a new chat opens with `ChatGPTWeb.followUpPrompt` quoting the earlier request, and Wren says so.
- In Wren: the follow-up runs in Wren with the earlier request and answer included in `input` (the plan route has no `previous_response_id`).
- Local: continues with the local AI. "Open that in GPT" on a local answer hands that request to the website.
- With no earlier request, Wren asks which one.

## 47. Command router and item execution (0.12)

**One decision, made once.** `CommandRouter.intent(for:now:calendar:)` (WrenCore, pure) returns a `CommandIntent`. Its fields:
- `operation`: an `ExecutionOperation` with its parameters, for example `createTask(TaskDraft)` or `changeItem(PendingCommand.Verb)`.
- `destination`: `wren`, `chatgpt`, `localAI`, `gmail`, `calendar` or `user`.
- `rule`: a `RoutingRule` with its letter A–E.
- `confidence`, `request` (politeness removed), `content` and `original`.

`AppModel.execute` logs `intent.summary` (no user text) and dispatches on it. It doesn't re-route: connector keyword checks no longer run before item commands or notes. `ExecutionRouter.operation(for:)` and `IntentRouter.route` are views of the same decision. Every entry point uses it: the capture panel, push-to-talk and the Voice button (`.voice`), the menu-bar field (through `runInCapturePanel`), the debug URL and `wren-tools route`.

**Outer request first.** `CommandGrammar.request` removes words addressed to Wren ("hey", "can you", "please", "I want you to"). Every frame is then anchored at the start of what's left, in this order:
1. An explicit note.
2. An advance reminder on an existing item.
3. A reminder frame (`ReminderCommand.canonical` maps "make a reminder to", "don't let me forget to", "I'd like a reminder", "ping me", "Reminder:", "Tomorrow at 9, remind me to…" to `remind me …`).
4. A task frame, an obligation ("I need to / have to / must…"), or a deadline statement ("X is due Friday").
5. ChatGPT follow-ups and requests.
6. Email actions.
7. Item changes.
8. Stored queries.
9. Gmail and calendar questions (only questions or lookups).
10. General questions.
11. A dated statement.
12. A note.

What the outer request carries ("ask GPT about …" inside "remind me to …") is its subject and can't change the operation. "I need to know what X is" without a date is a question (`knowledgeRequest`).

**Item execution.** `ItemExecution.createTask` and `ItemExecution.createReminder` (WrenCore, `CommandExecution.swift`) take these steps:
1. Save the user's words. A task is captured first; a reminder goes through the broker's `createReminder`.
2. Apply the reading through the broker, using `applyInterpretation` with state `.processed`. The confirmed reading isn't changed later by a model pass.
3. Reconcile with macOS.
4. Return a `ScheduledOutcome`: deadline, reminder time, planned requests, the identifiers macOS accepted, authorization and pause.

`allScheduled` is true only when macOS holds every planned request, and `schedulingFailed` marks a real failure. The panel's text is built from this outcome only.

**Deadline, reminder, notifications, status.** These are separate facts.
- A reminder request sets `nextReminderAt`. It sets `deadline` only when the user stated one (`ReminderCommand.statedDeadline`: "by/before/due …").
- A task's deadline implies a reminder on the day (`ReminderPolicy.initialReminder`, `reminderFromDeadline`).
- With `DeadlineAdvance` (the setting *Also remind me the day before a deadline*, plus the `autoRemindDeadlines` rule) it also gets one heads-up `days` before at the default reminder hour (`ReminderPolicy.advanceReminder`):
  - only while the reminder follows the deadline
  - only for deadlines set at least a day ahead
  - never at or after the deadline
- Its identifier is `wren.reminder.<id>.before.<epoch>`. Its category (`WREN_ADVANCE`) has only Done, so snoozing it can't move the real reminder. Reconcile adds, moves and removes it like any reminder.

**Email alerts.** `MailAlertText.make` builds the alert from:
- the sender
- the subject
- the first sentence of Gmail's preview (`excerpt`, about 120 characters; the `MailPreferences.alertPreviewSetting` setting is optional so old preferences decode)
- the reason

A click opens `EmailMessage.webURL` (`mail.google.com/mail/?authuser=<account>#all/<threadId>`, checked live as M-GMAIL-LINK). **Show in Wren** opens the message view.

**Quit.** `AppModel.stopBackgroundWork` sets `stopping` and invalidates the scheduler and mail timers. It cancels a pending reconcile and ends tab watching. macOS keeps the scheduled reminders.

**0.12.1.**
- `IntentRouter.normalizeAssistantName` runs before routing (speech spellings of ChatGPT and GPT). A
  request-noun pattern covers "make a query at/, ChatGPT …". `CommandIntent` also carries
  `authorization` and `handler`.
- `AskCard.headline` (WrenCore) is the only source of the panel's headline and of the voice outcome
  for ask cards. It is built from the destination that ran and its real phase.
- `ChatGPTAutoSend` (pure decisions), `BrowserTabs.focus` and `KeyPresser` (WrenKit, `CGEvent.postToPid`
  to the frontmost browser only) implement the opt-in **Send it for me** inside `watchConversation`. It
  presses once, after the page has dropped `q=`, and success is only the `/c/<id>` address.
- `TranscriptAssessment.checkBeforeSending` holds doubtful spoken ChatGPT requests for review.

