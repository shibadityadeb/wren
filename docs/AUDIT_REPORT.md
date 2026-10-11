# Wren audit report

Date: 2026-10-11 · Branch: `feat/audit-real-integrations` (from `main` @ `83e90ef`) · Version after this work: 0.9.0 (data schema 6)

This report records what Wren actually does, how that was checked, what was fixed, and what still needs
a person, an account or maintainer action. "Live" means a real provider or real macOS was exercised;
"mock" means a stubbed provider in `swift test`. Opening an authorization page, getting a token, a
passing unit test or a "Connected" card is not counted as live.

## 1. Repository state (established before any change)

| Item | Finding |
|---|---|
| Working tree | Clean, on `feat/notion-mcp-mac-calendar` |
| Remote | `origin` = github.com/shibadityadeb/wren |
| PR #6 ("Bring 0.8.0 and the ChatGPT routing fix to main") | **Merged** 2026-10-11 10:37 UTC as `33bbba9`. PRs #1–#8 are all merged; #8 (`83e90ef`) is `main`'s head. The local branch equals `main` minus that merge commit (no content difference). No discrepancy remains between reported and actual PR state. |
| Tags | Only `v0.4.0-preview.1`; 0.5–0.8 were never tagged |
| `VERSION` | 0.8.0 → now 0.9.0 |
| Installed app | `/Applications/Wren.app` 0.8.0 build 36 (`com.shibadityadeb.wren`), running. Its data: schema marker 5, 8 items, 1 delegation, 22 audit records. Built from 0.8.0-era `main`; Google client ID injected, **no Google client secret**. |
| Credentials on disk | `chatgpt.connection` (plan scope `chatgpt.tokens.use.direct` granted), registration and host ID. **No Google token** (Google has never connected). No Notion token. |
| Features only on branches | None: every branch was merged into `main` |
| Baseline tests | `swift test`: **255 tests, 0 failures, 3 skipped** (the opt-in live tests `WREN_LIVE_OLLAMA` ×2 and `WREN_LIVE_SIWC`) |
| After this work | `swift test`: **303 tests, 0 failures, 4 skipped** (+ the opt-in `WREN_MIGRATION_COPY`) |

The installed app and its data were not modified, apart from the ChatGPT token rotation described in
M-GPT-2. Live app tests used the separate "Wren Dev" identity. One unexplained event: the installed
Wren quit cleanly (its own quit handler ran) at 19:37:20, 14 s after a scripted quit of Wren Dev
that was addressed only to `com.shibadityadeb.wren.dev`. No quit request to the installed app appears
in the system log. It was relaunched at once; its data was unaffected (still schema 5).

## 2. Feature matrix

Statuses: **Live** = implemented and tested live · **Mock** = implemented, tested with mocks only ·
**Awaiting** = implemented, awaiting user permission or account authorization · **Blocked** = blocked by
maintainer configuration or provider verification · **Partial** · **Not implemented** · **Failing** ·
**Docs inconsistent**.

| Feature | Before (0.8.0 on main) | After (this branch) |
|---|---|---|
| GPT: natural-language routing ("search in GPT: …", "ask/get/tell GPT …") | Partial: completion phrases and "what X is" kept in prompt | **Mock** (unit) + **Live** in the running app (routes to GPT; Wren Dev not signed in, so not sent) |
| GPT: real request on the ChatGPT plan | Live once (user's request 12:41 UTC, audit `succeeded`, gpt-6-luna) | **Live** through the new pipeline (M-GPT-1) |
| GPT: tracked job, persisted before sending, survives panel close and restart | Not implemented (tied to panel; record said "Prepared (not sent)" while in flight) | **Live** (CLI) + **Mock** |
| GPT: completion announcement + clickable result page | Not implemented | **Mock**; notification delivery **Awaiting** (notifications denied for Wren Dev) |
| GPT: duplicate prevention | Partial (in-flight only, same text) | **Live** (CLI) + **Mock** (running and just-finished) |
| GPT: retry, usage limit, expired auth, interrupted, cancelled | Partial (retry created new records; no interrupted state) | **Mock** |
| GPT: ChatGPT conversation link | n/a | Investigated: the plan Responses call (`store: false`) returns no conversation URL; none is stored or invented. "Open ChatGPT" is labelled as opening ChatGPT only. |
| GPT: manual handoff fallback | Implemented; status said "waiting for you to send" | Relabelled **Awaiting submission**; never shown as completed |
| Gmail: Connect Google | **Failing**: token exchange rejected (`client_secret is missing`) | Code fixed; **Blocked** (maintainer must supply `WREN_GOOGLE_CLIENT_SECRET`) |
| Gmail: triage with reasons and corrections | Partial (flags only, no categories, no corrections) | **Mock**; live **Blocked** |
| Gmail: daily digest | Not implemented | **Mock**; live **Blocked** |
| Gmail: background new/urgent alerts, incremental sync | Not implemented | **Mock**; live **Blocked** |
| Gmail: Mark as read (separate permission) | Not implemented | **Mock**; live **Blocked** |
| Gmail: Spam/Trash exclusion | Implicit (API default) | Explicit (INBOX label, `includeSpamTrash=false`, label checks); **Mock** |
| Gmail: "summarise mail" / "suggest tasks" | **Docs inconsistent** (claimed implemented; no summariser) | Catalog corrected: "Add a task from an email (you review it)"; external summarisation listed as not implemented |
| Google Calendar (direct) | Mock; blocked by the same Google defect | Mock; **Blocked** (same secret) |
| Calendar (this Mac, EventKit) | Implemented, not run | **Awaiting** (needs Calendars permission) |
| Notion (MCP) | Mock; registration and consent page reached live earlier | Unchanged: **Awaiting** a Notion sign-in |
| Tasks from natural language ("I need to … by Friday", "Create a task for … next Monday") | Partial: saved with framing and date left in the title | **Live** in Wren Dev (M-REM-1) + **Mock** pipeline test |
| Reminders scheduled with macOS, reconciled at launch/wake, recurrence, snooze | Implemented, mock-tested; trigger dates never checked | **Mock**; trigger dates checked with `UNCalendarNotificationTrigger.nextTriggerDate()`; denied path **Live**; delivery while quit **Awaiting** (notifications denied for Wren Dev) |
| Voice: one pipeline for shortcut and "Hey Wren" | Implemented (continuous on-device recognizer, not push-to-talk only) | Post-transcription path **Live** (debug URL); microphone **Awaiting** |
| Voice: Siri-style listening UI, editable transcript before acting, gated idle listening, pause on lock | Not implemented (acted immediately; recognised all audio continuously) | Implemented; **Mock** (gate, suspend) + review mode **Live** in Wren Dev; microphone **Awaiting** |
| Voice: microphone purpose string | **Docs inconsistent** (said push-to-talk only) | Fixed |
| Single instance, quit, relaunch | Live (earlier pass) | **Live** again (M-LIFE-1/2) |
| One bird, ⌘Q from keyboard, Dock reopen | Not run | Not run (needs someone at the screen) |
| Schema upgrade without data loss, newer-schema refusal | Mock | **Live** on a copy of the real 0.8.0 store (M-DATA-1) |
| Remove all data | **Failing** (left GPT prompts/answers and connector tokens) | Fixed; **Mock** |
| Export / backup / restore / pause / reset | Mock-tested; not changed | Unchanged (export and backups contain `Wren.store` only; mail lives outside it) |
| Local model (Ollama) | Live checks opt-in | Unchanged |
| Documentation | **Docs inconsistent** (Keychain, API key, push-to-talk only, REST Notion, "Wren doesn't use ChatGPT", "no microphone") | Corrected in README, ARCHITECTURE §35–§44, PROJECT_SPEC/ROADMAP banners, TEST_PLAN, MAINTAINER_SETUP |

## 3. Findings

Severity: Critical (a core workflow can't work) · High · Medium · Low.

### F1 · Critical · Connect Google can never complete
- **Location**: `Sources/WrenCore/Connectors/GoogleOAuth.swift` `exchange`, `refresh`; `ProviderConfig.swift`; `scripts/build-app.sh`.
- **Evidence**: a live probe of `https://oauth2.googleapis.com/token` with this build's client ID and a deliberately invalid code returned `{"error":"invalid_request","error_description":"client_secret is missing."}`. With a dummy secret it returned `invalid_client`, so the secret is checked. No account was involved. There is also no Google token on disk.
- **Repro**: install 0.8.0, Connectors › Gmail › Connect Google, approve. The exchange fails with "HTTP 400: invalid_request: client_secret is missing."
- **Expected**: Gmail and Calendar connect. **Actual**: every attempt fails after consent.
- **Fix**: `GoogleOAuthConfig.clientSecret`, injected at build time (`WREN_GOOGLE_CLIENT_SECRET` → `WrenGoogleClientSecret`), and sent on exchange and refresh, never in the browser URL. A missing secret maps to `OAuthError.clientSecretMissing`, shown as a build problem. Build and verify scripts warn when it's missing; the release workflow passes it.
- **Blocker**: the maintainer must add the Desktop client's secret (docs/MAINTAINER_SETUP.md). Google publishing or verification also applies: `gmail.readonly` and `gmail.modify` are restricted scopes.

### F2 · High · GPT requests weren't tracked, announced or reopenable
- **Location (before)**: `AskService.askChatGPT`, `AppDelegate.askAction`, `AppModel+Connectors.sendToChatGPT`.
- **Evidence**:
  - The record was inserted with status `prepared` ("Prepared (not sent)") while the request was in flight.
  - Nothing announced completion.
  - "Open in Wren" went to the generic Delegate page.
  - Retry created a new record.
  - A request cut off by quit stayed "Prepared (not sent)" forever.
  - Delegate had a second implementation with its own semantics.
- **Expected**: a persistent job with live status, a once-only completion notification, a result page, and retry without duplicates.
- **Fix**: `AskService` became a job runner (`start`, `outcome`, `retry`, `cancel`, `recoverInterrupted`, `onFinished`). New schema-v6 fields record status, models, times, attempts and failure kind. `DelegationDetailView` (`Route.delegation`), the "GPT finished: … View result." notification, Overview › GPT requests, and the Delegate history all link to it. Delegate and the panel now share one path.
- **Verified**: live (M-GPT-1) and mock (`DelegationLifecycleTests`).

### F3 · High · Gmail was a search box, not inbox intelligence
- **Location (before)**: `Gmail.swift` (search plus a keyword `EmailTriage`), on-demand reads only.
- **Evidence**: the code had no polling, history sync, digest, alerts, Mark as read or corrections. Metadata fetches ran sequentially (N+1). The catalog marked "Suggest tasks" as implemented and the README promised "summarise mail".
- **Fix**: `MailIntelligence.swift` (classification, sync, alert policy, digest, corrections), `GmailAPI` with history and an allowlisted `perform`, `AppModel+Mail` (monitor, alerts, digest, Mark as read through the broker), Inbox and message views, mail settings, and the `monitorConnectedEmail` standing rule. Mail is stored in a private file outside the database. Docs were corrected.
- **Verified**: mock (`MailIntelligenceTests`, 28 tests). Live **blocked** by F1.

### F4 · High · "Remove all Wren data" left personal data and sign-ins behind
- **Location**: `WrenStore+Context.eraseAllUserData`; `FileCredentialStore.deleteAll` existed but was never called.
- **Evidence**: no `DelegationRecord` delete (prompts and answers survived); credential files survived. README said everything was removed.
- **Fix**: GPT records are deleted. After a successful erase, Google, Notion and ChatGPT are revoked, the credential folder is deleted, and the mail cache and mailbox file are removed.

### F5 · Medium · Standing rules weren't tied to the scheduler they authorize
- **Location**: `Authorizer.decide`, `.system` origin.
- **Evidence**: any `.system(...)` origin could use any rule that allowed the action. Adding a mail-monitor rule would have let the briefing keep reading Gmail after the user turned the briefing rule off; an existing test caught this.
- **Fix**: `StandingRuleKind.systemScope` and `covers(_:system:)`; tests cover both directions.

### F6 · Medium · A pending reminder question could swallow the next request
- **Location**: `AppModel+Context.reminderRequest`.
- **Repro**: "remind me to call Sam" (Wren asks when), then "ask GPT what to prepare for Friday's launch". Before the fix, the second input became "remind me to call Sam … Friday".
- **Fix**: `ReminderFollowUp.mayAnswer` rejects explicit GPT requests and notes.

### F7 · Medium · Prompt extraction kept instructions meant for Wren
- **Evidence**: "Tell GPT to investigate this and let me know when it is finished" sent "Investigate this and let me know when it is finished."; "ask GPT what quantum physics is" sent "What quantum physics is?".
- **Fix**: `IntentRouter.cleanPrompt` (completion phrases, embedded questions). Tests cover every phrasing in the brief plus negatives (reminder, note, "email the GPT team", "I compared GPT…").

### F8 · Medium · Task titles kept their framing and date
- **Evidence**: "Create a task for the recruiter follow-up next Monday" was titled exactly that; "I need to finish this report by Friday" was titled "Finish this report by Friday".
- **Fix**: `IntentProcessor.cleanTitle` and date stripping in `rulesOnly`, matching the model path. Live in Wren Dev: a task due Friday with a reminder Friday 10:00.

### F9 · Medium · Microphone purpose string was wrong
- `scripts/build-app.sh` said Wren "records only while you hold the push-to-talk shortcut", but "Hey Wren" listens continuously when on. The string has been rewritten.

### F10 · Medium · Documentation contradicted the code
- Keychain storage (the code uses files), an OpenAI API-key path (removed in 0.7), push-to-talk only, a REST Notion client and integration token, "Wren does not use ChatGPT", "Wren uses no microphone", a "no maintainer client ID" note in MANUAL_TESTS, and non-existent tests (`testRealKeychain`).
- **Fix**: see §2, last row.

### F11 · Low · "Open" email link could open the wrong Gmail account
- It used `/mail/u/0/`. It now uses `authuser=<account>#all/<thread>`.

### F12 · Low · Delegate's Done/Discard rewrote real plan results
- On a ChatGPT-plan answer these set "completed" or "cancelled" by hand. They're now shown only for handoffs and local answers.

### F13 · Low · Pre-v6 plan answers would be mislabelled after upgrade
- Answers were stored as `responseImported`, which now reads "Answer pasted by you". They are now normalised to completed at launch and not re-announced.

### F14 · Low · Notion catalog listed the wrong host (`api.notion.com`)
- Corrected to `mcp.notion.com`.

### Checked, no defect
- ChatGPT model listing: the docs agent flagged the `{"models":[…slug…]}` parser as possibly wrong for `/v1/models`. Live, it listed 3 models on the plan resource, so it is correct for this API.
- Notification trigger construction: `nextTriggerDate()` returned the intended instant (one-off) and next weekday 15:00 (repeating).
- Spam versus priority: Wren never labels mail "spam"; promotions are "Informational". Gmail's SPAM and TRASH labels exclude mail entirely.

## 4. Fixed issues, by priority

1. F1: Google token exchange (code; maintainer secret still needed).
2. F2: GPT delegation as a tracked, announced, reopenable, retryable job.
3. F3: Gmail inbox intelligence: sync, triage, corrections, digest, alerts, Mark as read, privacy.
4. F4: complete data removal.
5. F5: rule scoping.
6. F6–F8: routing and task-capture correctness.
7. F9–F14: accuracy of permissions text, docs, links and labels.

## 5. Remaining blockers (need a person, an account or the maintainer)

| Blocker | Owner | What to do |
|---|---|---|
| Google token endpoint needs the Desktop client secret | Maintainer | Add `WREN_GOOGLE_CLIENT_SECRET` to `config/providers.env` and the repository secrets; rebuild. Then run M-GMAIL-1…10. |
| Google app status and verification | Maintainer and Google | `gmail.readonly` and `gmail.modify` are restricted scopes. Until Google verifies the app, only listed test users (7-day tokens) or ≤100 users on the unverified screen can connect. Add `gmail.modify` to the consent screen's scopes for Mark as read. |
| Notifications denied for "Wren Dev" on this Mac | Person at the Mac | System Settings › Notifications › Wren Dev › Allow, then M-REM-3 and M-GPT-5 |
| Microphone, Speech Recognition, Calendars permissions | Person at the Mac | M-VOICE-1, M-CAL-1 |
| Notion sign-in | Person with a Notion account | M-NOTION-1 |
| ChatGPT sign-in in Wren Dev (for the UI path) | Person | The CLI live check already covers the provider path |
| Installing 0.9.0 over the installed 0.8.0 | Person | Opening the real data with 0.9.0 upgrades it to schema 6 (a backup is made first); 0.8.0 then refuses it. Not done here. |

## 6. Security and privacy review (as built)

- Tokens are private files (0700/0600), never in SwiftData, exports, backups or logs. Logs record counts, IDs (truncated) and states, never prompts, answers or email content.
- Every Gmail read and the Mark-as-read write go through `ActionBroker.performExternal`. The audit holds labels only. Mark as read needs the `emailModify` grant (only while Google granted `gmail.modify`) plus a per-message confirmation. The scheduler and content-derived origins can't trigger it.
- Wren's code has no Gmail send, archive, trash, delete, label or filter calls (`GmailAllowedAction` has one case), even when the OAuth scope would allow them.
- Email text is data. A prompt-injection email is classified like any other message and can't cause actions (`testInstructionsInsideAnEmailAreJustData`). Email is never passed to ChatGPT or the local model.
- GPT requests send only the user's request text unless the user adds context in Delegate. Private items require explicit inclusion, which carries over to a retry of the same text only.
- Disconnecting Google deletes the mailbox file and revokes access at Google. "Remove all data" revokes and deletes all sign-ins.

## 7. Commands and results

```
swift test                                   # 303 tests, 0 failures, 4 skipped
WREN_MIGRATION_COPY=<copy> swift test --filter RealStoreUpgradeTests   # passed on a copy of the real store
wren-tools live-check chatgpt "Hey Wren, search in GPT: …"             # completed live in 3.2 s
scripts/build-app.sh debug --dev-identity    # builds; warns that the Google client secret is missing
wren-tools snapshot <dir>                    # renders the new result, Inbox, message and panel views
```
