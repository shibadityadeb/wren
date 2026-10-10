# Wren — Roadmap

Each phase ends with: a green build, tests passing (commands recorded), a git commit, and a report of what remains unverified. Phases are run one at a time.

## Phase 0 — Architecture and plan ✅ (this commit)
Deliverables: PROJECT_SPEC.md, ARCHITECTURE.md, ROADMAP.md, TEST_PLAN.md, git repository initialised in `Wren/`.
Acceptance: architecture documented, MVP scope unambiguous, every dependency justified, core vs. later clearly split.

## Milestone 1 status (2026-10-10)

The first implementation milestone covers Phase 1, Phase 2, the foundation of Phase 3, and the notification foundation of Phase 4.

| Area | Built | Verified |
|---|---|---|
| Menu-bar agent with logo, popover, settings, quit | yes | App launches, adds one menu-bar item, no errors logged. Views inspected as offscreen renders in light and dark. The live popover has not been seen on screen, because this terminal lacks Screen Recording permission. |
| Global shortcut ⌥ Space, configurable, can be disabled | yes | Registration confirmed in the log. Pressing it could not be automated, because sending keystrokes needs Accessibility permission. **Needs a manual check.** |
| Capture overlay (Return, Esc, focus stays in the previous app) | yes | Opened via `wren://capture`: the floating panel appeared and the other app stayed frontmost. Typing into it is not automated. |
| Fallback capture | yes | Popover field, pencil button, and `wren://capture` |
| Persistent commitments, original text, history | yes | Unit tests, plus a debug-build run: 3 captures, then quit and relaunch, and all 3 were intact |
| Create, edit, complete, snooze, drop, reopen, delete | yes | Unit tests cover the store transitions. The UI buttons were not clicked in an automated run. |
| Local Ollama client, model picker, validation | yes | Stubbed tests pass. There is **no live test**, because no chat model is installed (only `nomic-embed-text`). |
| Rules-only date reading without a model | yes | 19 phrases × 2 timezones; live run gave the correct Friday and 10:00 reminder |
| Notification service, permission flow, actions | yes | A due reminder with permission still undecided stayed due and was not marked sent. **Delivery and the Done, Snooze, and Remind-at actions are unverified**, because granting permission needs a click on the macOS prompt. |
| Duplicate prevention, closed items never remind | yes | Unit tests, including across a store reopen |

### Manual checks for you

1. Open `build/Wren.app`, click the bird, then click **Allow…** for notifications.
2. Switch to any app and press ⌥ Space. Type `Stretch in 1 minute` and press Return. Focus should return to your app.
3. Wait one minute. A banner should appear. Try **Done**, then repeat the capture and try **Remind me at…** with `in 2 minutes`.
4. Quit from the menu, reopen, and confirm your items are still there.
5. If ⌥ Space does nothing, Claude.app's quick-entry shortcut may be catching it first. Change Wren's shortcut in Settings.

### Known limitations

- Reminders only fire while Wren is running. Launch at login is not built yet; it is planned as an explicit opt-in.
- Morning briefing and evening check-in are not built yet. That is Phase 4.
- Without a chat model, captures with no date stay "unsorted". They are kept but get no reminder until you set one or a model classifies them.
- The text-input notification action depends on macOS. If it is unavailable, use **Remind me in 1 hour**, or set the time from the menu.
- Three test captures made during verification are in your store: the scholarship form, stretch in 1 minute, and the AI startup idea. Drop or delete them from the menu.

### Next recommended milestone

Finish Phase 3 and Phase 4:
- install a chat model and run the live intent test;
- add the 11:00 briefing and 19:00 check-in with `DailyRun` deduplication;
- add sleep and wake reconciliation tests with a fake clock;
- add the opt-in login item through `SMAppService`.

## Phase 1 — Native foundation
- Install `xcodegen`; create `Package.swift` (WrenCore) and `App/project.yml` → `Wren.xcodeproj`.
- Menu-bar app (`LSUIElement`), `MenuBarExtra` popover listing pending commitments grouped by due date.
- SwiftData store at the Application Support path; `Commitment` and `ActivityEvent` models; `WrenStore` with create / fetch / update / complete / snooze / drop.
- Temporary text field in the popover to add a commitment manually.
- Tests: persistence round trip, status transitions, snooze sets `snoozedUntil`, drop/complete clear `nextReminderAt`.
**Acceptance:** builds and launches; create and view a commitment; change status; data survives relaunch; tests pass.

## Phase 2 — Instant capture
- Carbon hotkey service, default Option + Space, recorder in settings, enable/disable toggle.
- Non-activating `NSPanel` overlay with one text field. Enter saves, Escape dismisses.
- `Capture` model; raw text persisted synchronously before anything else; provisional state `awaiting`.
- Popover shows an "Inbox" of unprocessed captures with a manual "make this a commitment" action.
- Fallback: capture field in the popover.
**Acceptance:** shortcut works while another app is focused; overlay opens in under ~100 ms and dismisses cleanly; focus returns; raw text saved even if processing is disabled; shortcut can be changed or disabled.

## Phase 3 — Local intent processor
- `OllamaClient` (local-only URL validation, `/api/tags`, `/api/chat` with JSON schema).
- Model picker in settings listing installed models; setup instructions when none.
- `IntentSchema`, `IntentValidator` (evidence-span rule), `RelativeDateParser`.
- `IntentProcessor` turns `awaiting` captures into commitments / goals-as-captures / ideas / questions / waiting / research, or `needsClarification` / `failed`.
- Retry and manual-edit paths in the popover.
**Acceptance:** fixtures for normal, ambiguous-date, idea, question, missing-detail, and malformed output all behave per TEST_PLAN; network layer refuses non-local hosts; raw input survives every failure; no `Process` usage in WrenCore.

## Phase 4 — Reminder and follow-up engine *(the critical phase)*
- `ScheduleSettings` (briefing 11:00, check-in 19:00, quiet hours, limits), persisted.
- `ReminderEngine.evaluate` as a pure function; `BriefingSelector`; `DailyRun` dedupe.
- `SchedulerRunner` with launch / wake / clock-change / 60 s timer.
- `NotificationService` with categories and actions; reply parsing; overlay fallback for custom times.
- Permission request flow and denied-state UI.
**Acceptance:** one-minute-ahead reminder fires with actions; Done / Not yet / Snooze each update state and history; restart preserves schedule and does not duplicate; completed items never reappear; sleep/wake reconciliation tested with a fake clock.

## Phase 5 — Assistant behaviours
- `Goal`, `WaitingItem` models; ideas/questions stay as classified captures.
- Postponement limit → "still intend to?" check-in with Reschedule / Drop / Keep.
- Stale-item rule (open > N days, no deadline) → weekly review notification, not daily.
- Reference resolution for "move that to Sunday", "drop that idea", "I already finished it": candidates = last 3 captures + items mentioned in the last notification; one strong candidate → act and log; otherwise ask.
- Activity history view in the popover.
**Acceptance:** goal with linked commitments and progress; postponement and completion events recorded; stale vs. new handled differently; ambiguous references ask; briefing stays ≤ 3 items.

## Phase 6 — Local voice capture
- Push-to-talk in the overlay (hold the hotkey or a second key); `AVAudioEngine` capture; on-device transcription (SFSpeechRecognizer on-device or whisper.cpp, chosen after a quick test).
- Low-confidence or date-bearing transcripts shown for correction before submission.
- Temp audio deleted after transcription; mic permission and "model missing" states.
**Acceptance:** works offline; spoken deadlines parsed or flagged; same pipeline as text; no audio retained; text capture unaffected by speech failure.

## Phase 7 — Research requests and bounded actions
- `ResearchRequest` model; `ActionEngine` with `answerLocally`, `searchLocalFiles` (user-picked folders), `webResearch` (no-key retrieval, robots-aware, sources with URL + date).
- Queue runner, completion notification, result view in the popover.
**Acceptance:** capture → queued → executed → completed or blocked; persisted and retrievable; sources traceable; no cloud key; failure never reported as success.

## Phase 8 — Packaging, startup, reliability
- Release build script producing a signed `.app`; login-item toggle; model/notification/hotkey status indicators; configurable times; full item editor; JSON export/backup; file logging; safe reset with backup; pause notifications; quit.
- End-to-end manual test script and README.
**Acceptance:** the ten-point final product acceptance test in the master prompt, each item recorded as verified or not.

## Phase 9 — Tool Registry and Action Broker
- `Tool`, `CapabilityDescriptor`, `ActionRequest`, `Authorization`, `AuditEntry`, `StandingRule`, `Approval` in WrenCore.
- Broker pipeline: lookup, validate, grants, authorization, policy, dry run, execute, verify, audit.
- Policy engine with the four effect classes and editable defaults, destructive confirmation fixed.
- Keychain wrapper for tool credentials.
- Migrate commitment actions to a built-in `wren.tasks` tool through the existing `apply` seam.
- Review and confirmation UI in the overlay; Connections screen with grants, rules, revoke; global dry-run toggle.
- Mock tools only. No real accounts.
**Acceptance:** all actions use one broker; capabilities and grants inspectable; every attempt audited; unauthorized requests rejected; dry run works; injected email instruction cannot authorize deletion; forged model tool call cannot bypass policy; Phase 1–8 tests still pass.

## Phase 10 — Email integration and essential inbox briefing
- `EmailProvider` protocol; Gmail implementation only.
- OAuth 2.0 desktop flow with PKCE and loopback redirect; `gmail.readonly` at connect; incremental scopes later; Keychain storage; disconnect with revocation and local data deletion.
- README section for Google Cloud console setup, including the 7-day token caveat for External Testing apps.
- Incremental sync with `historyId`; metadata-only `EmailMessage` index; body retention setting, default off.
- Importance classifier: deterministic signals first, local model second, reasons shown, user corrections stored as overrides.
- Email section in the briefing: **pending the rest of the Phase 10 prompt**, which ends at "Morning email".
**Acceptance (from the prompt so far):** connect and disconnect work without a password; tokens only in Keychain; only metadata indexed by default; classifier explains each essential message and accepts corrections; newsletters and promotions kept out of the briefing; Apple Mail and Outlook not claimed as supported.

## Not yet specified
Email write actions, email search UX, external AI delegation, and Mac tools have no phase prompt. Planned approaches are in ARCHITECTURE.md §15–17.

## Sequencing note

Phase 9 comes after packaging in your numbering. Phases 4, 5, and 7 already change state, so they all route through a single `apply` function from Phase 4 on. That keeps the Phase 9 migration mechanical. An alternative is to build Phase 9 right after Phase 4, before assistant behaviours and research, which avoids running two authorization models at all. That reordering is your call; the plan works either way.

## Core vs. later

| Core (Phases 1–4) | Later (5–8) | Execution agent (9–10+) |
|---|---|---|
| Commitments, capture, local intent, briefing + check-in, notification actions, persistence | Goals, waiting items, reference resolution, voice, research, packaging polish | Broker, policy, audit, Keychain, Gmail read and briefing, later actions and delegation |

A Phase 4 build is already a usable daily assistant. Everything after it is additive.
