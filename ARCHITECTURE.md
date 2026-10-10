# Wren — Architecture

> **Implementation note (Milestone 1, 2026-10-10).** As built, this differs from the original plan in three places. Each is deliberate:
> 1. **Build:** a Swift package plus `scripts/build-app.sh`, instead of xcodegen and an Xcode project. This adds no dependency and lets `swift test` run everything. Xcode can still open `Package.swift`.
> 2. **Targets:** `WrenCore` (no UI), `WrenKit` (SwiftUI views and AppKit services), `Wren` (a three-line executable), and `wren-tools` (dev-only brand and snapshot tool).
> 3. **Data:** a single `Commitment` model holds the verbatim `originalText`, a `kind` (commitment, idea, question, waiting, research, unsorted) and a `processing` state. This replaces a separate `Capture` entity. Only `kind == .commitment` gets automatic reminders. A separate `Capture` can be split out later if Phase 5 needs it.
> 4. **UI:** the menu bar uses `NSStatusItem` + `NSPopover` rather than `MenuBarExtra`, so a notification tap can open the popover programmatically.

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

## 16. Email (Phase 10)

- `EmailProvider` protocol: `listChanges(since:)`, `fetchMetadata(ids:)`, `fetchBody(id:)`, `search(query:)`, plus write capabilities registered as broker tools. Gmail is the only implementation until another is built and tested.
- **Gmail auth.** OAuth 2.0 for installed apps with PKCE and a loopback redirect on `127.0.0.1:<random port>`, opened in the default browser through `ASWebAuthenticationSession` or `NSWorkspace`. Tokens go to Keychain under service `com.shibadityadeb.wren.oauth.gmail`.
- **Developer console setup, done once by you.** Create a Google Cloud project, enable the Gmail API, configure the consent screen, and create an OAuth client of type "Desktop app". If the account is on Google Workspace, user type "Internal" avoids review and token expiry, subject to your admin. With user type "External" in Testing status, Google expires refresh tokens after 7 days, so you would reconnect weekly. The README will document both. This is OAuth configuration, not an AI API key.
- **Scopes.** `gmail.readonly` at connect. `gmail.modify` when you enable archive, trash, or read state. `gmail.settings.basic` when you enable block or filters. Permanent delete needs full `https://mail.google.com/` access, so it stays off unless you enable it explicitly.
- **Sync.** `users.history.list` from the stored `historyId` every 10 minutes while awake, and on wake. Initial sync covers the last 14 days only.
- **Index.** `EmailMessage` SwiftData model with metadata only, see PROJECT_SPEC §9.7. Bodies cached only under the retention setting.
- **Classifier.** Deterministic signals first: your important-senders list, Gmail category labels, `List-Unsubscribe` header, known billing and security sender patterns, calendar invites. The local model then labels the remainder with a category and a one-line reason, validated like intents. Corrections you make are stored as sender or domain overrides that win over both. Email text is wrapped as quoted data in the prompt, and the model output schema has no tool-call field.
- **Briefing.** Details pending the rest of the Phase 10 prompt.

## 17. External AI delegation (phase to be specified)

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
