# Wren — Test Plan

Unit tests live in `Tests/WrenCoreTests` and run with `swift test` (no app launch). UI/system behaviours that cannot be unit tested are listed as manual checks with exact steps and are reported as verified or unverified at the end of each phase.

All date-sensitive tests inject a fixed `now` and a fixed `TimeZone` (tests run against both `Asia/Kolkata` and `America/Los_Angeles`); none use `Date()` directly.

## Phase 1 — Persistence and state

| ID | Test | Expected |
|---|---|---|
| P1-01 | Create commitment, reopen store from same file | Commitment present with identical fields |
| P1-02 | `complete()` | status `completed`, `completedAt` set, `nextReminderAt` nil, `ActivityEvent.completed` appended |
| P1-03 | `drop()` | status `dropped`, `droppedAt` set, `nextReminderAt` nil |
| P1-04 | `snooze(until:)` | `snoozedUntil` set, `snoozeCount` +1, `nextReminderAt == until`, event logged |
| P1-05 | Complete then snooze | rejected (no transition out of terminal states without explicit `reopen()`) |
| P1-06 | Fetch pending sorted | ordered by deadline asc, nil deadlines last, then priority |
| P1-07 | Store open on unwritable path | throws typed `StoreError.cannotOpen(path)`; no crash |
| Manual | Launch app, add via temp field, quit, relaunch | item still listed |

## Phase 2 — Capture

| ID | Test | Expected |
|---|---|---|
| P2-01 | Insert `Capture` with raw text | `processingState == .awaiting`, `timeZoneID` = current |
| P2-02 | Capture with processing disabled | stays `awaiting`, visible in inbox |
| P2-03 | Hotkey recorder maps key + modifiers to Carbon codes and back | round trip stable |
| Manual | Focus Safari, press ⌥Space, type, Enter | overlay appears over Safari, closes, Safari regains focus, item in inbox |
| Manual | Press ⌥Space, Escape | overlay closes, nothing saved |
| Manual | Disable shortcut in settings, press ⌥Space | nothing happens; popover capture field works |
| Manual | Change shortcut to ⌃⌥W | new shortcut works, old does not |

## Phase 3 — Intent processing

Fixtures are recorded Ollama responses (JSON files) so tests are deterministic and offline; one optional integration test runs against a live local Ollama when `WREN_LIVE_OLLAMA=1`.

| ID | Input / fixture | Expected |
|---|---|---|
| P3-01 | "I need to submit the form tomorrow." (now = Thu 2026-10-08 15:00 IST) | commitment, title "submit the form", deadline 2026-10-09, `deadlineHasTime == false` |
| P3-02 | "Remind me to call my friend at 8 tonight." | commitment, deadline today 20:00 local, `deadlineHasTime == true` |
| P3-03 | "I should read that paper this weekend." (Thu) | commitment, deadline Sun 2026-10-11, `deadlineIsUncertain == true` (weekend is a range) |
| P3-04 | "I might build an AI startup someday." | classification `idea`, no commitment created, no deadline |
| P3-05 | "I'm waiting for the recruiter to reply." | `waiting`, no reminder |
| P3-06 | "Find three open-source security scanners and tell me tomorrow." | `research`, dueAt tomorrow |
| P3-07 | "I need to submit something on Friday, but I forgot which form." | `needsClarification`, question mentions the form; raw text intact |
| P3-08 | Model returns deadline with `deadline_evidence` not in input | validator rejects deadline; commitment created **without** deadline and flagged uncertain |
| P3-09 | Model returns non-JSON | `Capture.failed`, `modelRawOutput` stored, raw text intact |
| P3-10 | Model returns unknown classification enum | `failed` |
| P3-11 | Model returns deadline 3 years out | rejected as implausible |
| P3-12 | Ollama unreachable (connection refused) | `awaiting`, retry available, no crash, under 3 s |
| P3-13 | `OllamaClient(baseURL: "https://api.example.com")` | init throws `nonLocalHost` |
| P3-14 | Grep test: `Sources/WrenCore` contains no `Process(`, `NSTask`, `system(` | passes |
| P3-15 | RelativeDateParser table: tomorrow, tonight, Friday (same weekday → next week), next Monday, in 2 hours, this weekend, end of month, "9", "9pm", "at 9" (evening if ambiguous and past 09:00) | each resolves to the documented value in both timezones |
| P3-16 | Capture at 23:50 IST "tomorrow" | tomorrow relative to IST, not UTC |

## Phase 4 — Reminder engine

All engine tests call `ReminderEngine.evaluate(now:settings:commitments:dailyRun:)` and assert on the returned actions. No notifications are sent in unit tests.

| ID | Scenario | Expected actions |
|---|---|---|
| P4-01 | now 10:59, no run today | none |
| P4-02 | now 11:00, 5 pending with varied deadlines | `.sendBriefing` with top 3 per selector scoring, `.markBriefingSent` |
| P4-03 | now 11:05, briefing already sent today | none (no duplicate) |
| P4-04 | now 11:40 after wake, no briefing today | briefing sent (window open) |
| P4-05 | now 20:30 after wake, nothing sent today | check-in only, briefing skipped |
| P4-06 | now 02:00, nothing sent yesterday | none; nothing in quiet hours |
| P4-07 | commitment `nextReminderAt` 21:00, now 21:00 | `.sendFollowUp` |
| P4-08 | same, `lastReminderAt == nextReminderAt` already | none |
| P4-09 | `nextReminderAt` 21:00, now 23:30 (late grace 3 h) | none until 07:00 next day, then one late follow-up |
| P4-10 | completed commitment with stale `nextReminderAt` | never surfaced (and store invariant test: complete clears it) |
| P4-11 | dropped commitment | never surfaced |
| P4-12 | idea / goal / waiting captures | never in briefing or check-in |
| P4-13 | reply "Done" | completed + event |
| P4-14 | reply "Not yet" | `nextReminderAt` = next check-in time, event `checkedIn(notYet)` |
| P4-15 | reply "remind me at 9" at 19:10 | `nextReminderAt` today 21:00 |
| P4-16 | reply "2h" | now + 2 h |
| P4-17 | reply "banana" | unparsed → action `.openOverlay(prefilled:)` |
| P4-18 | reminderCount reaches `settings.maxRemindersPerItem` | no further automatic follow-ups; event `postponementLimitReached` |
| P4-19 | Selector: overdue beats today beats high priority beats stale; uncertain deadline ranks lower | ordering as documented |
| Manual | Set check-in time to now+1 min, pending item | notification with Done / Not yet / Remind me later |
| Manual | Press Done | item completed in popover, no further notification |
| Manual | Press Remind me later, type "5m" | notification again in 5 min |
| Manual | Quit and relaunch between schedule and fire | fires once, not twice |
| Manual | Sleep Mac across the check-in time, wake | one check-in on wake |
| Manual | Deny notification permission | popover shows due items + explanation; capture still works |

## Phase 5 — Assistant behaviours

| ID | Scenario | Expected |
|---|---|---|
| P5-01 | "Publish three articles this month" | Goal target 3, due end of month |
| P5-02 | Complete two linked commitments | goal progress 2/3 |
| P5-03 | Snooze same item 3 times (limit 3) | next contact is the "still intend to?" variant with Reschedule / Drop / Keep, not a plain reminder |
| P5-04 | Item open 7 days, no deadline | appears in weekly review, not in daily briefing |
| P5-05 | "Move that to Sunday" right after one capture | that item's deadline → Sunday, event `rescheduled` |
| P5-06 | "Drop that" with two recent captures | clarification asked, nothing modified |
| P5-07 | "Actually I already finished it" with one item mentioned in last notification | that item completed |
| P5-08 | No reply to check-in for 3 days | item still pending; no auto-complete, no auto-drop |

## Phase 6 — Voice

| ID | Scenario | Expected |
|---|---|---|
| P6-01 | Transcriber with network disabled (manual: Wi‑Fi off) | transcription still works |
| P6-02 | Transcript "submit the form by Friday" | same commitment as text path (shared fixture) |
| P6-03 | After transcription | temp audio file does not exist |
| P6-04 | Speech model/permission missing | clear message; text field still usable |
| P6-05 | Low confidence transcript | shown for correction before save |

## Phase 7 — Research

| ID | Scenario | Expected |
|---|---|---|
| P7-01 | Research capture | `ResearchRequest.queued` |
| P7-02 | `webResearch` with stubbed HTTP returning 2 pages | summary with 2 sources, each `url + retrievedAt` |
| P7-03 | HTTP all fail | status `blocked`, error text, **no** summary |
| P7-04 | `robots.txt` disallows path | page not fetched, noted in errors |
| P7-05 | `answerLocally` with Ollama down | `blocked`, not fabricated |
| P7-06 | `searchLocalFiles` outside permitted folders | refused |
| P7-07 | Completion | notification sent, result retrievable after relaunch |

## Phase 8 — Reliability

| Check | Method |
|---|---|
| Launch at login | toggle on, log out/in, Wren in menu bar |
| Restart Mac | commitments and `nextReminderAt` intact; no duplicate briefing |
| Offline (Wi‑Fi off) | capture, intent (Ollama), reminders all work |
| Store corrupted (truncate file) | error UI with reset+backup; emergency capture file works |
| Export | JSON file contains all items and history; re-import round trip |
| Pause notifications | engine returns no send actions while paused; resumes correctly |
| Logs | contain errors, contain no raw capture text |
| Dependencies | `swift package show-dependencies` lists only what ARCHITECTURE.md §13 allows |

## Commands recorded per phase

```
swift test                                   # WrenCore
xcodebuild -project App/Wren.xcodeproj -scheme Wren -configuration Debug build
xcodebuild -project App/Wren.xcodeproj -scheme Wren test   # app-level tests, from Phase 2
```
