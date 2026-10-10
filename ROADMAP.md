# Wren — Roadmap

Each phase ends with: a green build, tests passing (commands recorded), a git commit, and a report of what remains unverified. Phases are run one at a time.

## Phase 0 — Architecture and plan ✅ (this commit)
Deliverables: PROJECT_SPEC.md, ARCHITECTURE.md, ROADMAP.md, TEST_PLAN.md, git repository initialised in `Wren/`.
Acceptance: architecture documented, MVP scope unambiguous, every dependency justified, core vs. later clearly split.

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

## Core vs. later

| Core (Phases 1–4) | Later (5–8) |
|---|---|
| Commitments, capture, local intent, briefing + check-in, notification actions, persistence | Goals, waiting items, reference resolution, voice, research, packaging polish |

A Phase 4 build is already a usable daily assistant. Everything after it is additive.
