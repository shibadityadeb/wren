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
- Sending email or messages autonomously. Wren may draft; it sends only on a direct instruction or a confirmed approval.
- Scripted control of the ChatGPT website. See §9.4 for why and what replaces it.
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
- No telemetry. Network traffic is limited to: the local Ollama endpoint; explicitly requested web research (Phase 7); connected email providers (Phase 10 onward); and external AI delegation that you explicitly request for a specific task (phase to be specified).
- OAuth tokens and optional API keys live only in the macOS Keychain, never in the database, settings, or logs.

## 9. Execution agent extension (addendum, 2026-10-10)

Wren grows from a commitment manager into a **local-first, permissioned execution agent**. It stays a native macOS utility, and its core functions still need no cloud AI key.

### 9.1 New capabilities

| Capability | Effect | Phase |
|---|---|---|
| Tool Registry, Action Broker, policy engine, audit, dry run | infrastructure | 9 |
| Connect Gmail with OAuth, read-only first | read | 10 |
| Local metadata index, importance classifier with reasons and corrections | read | 10 |
| Email section in the morning briefing | read | 10 (spec text incomplete) |
| Search email on request | read | 10 or later, pending your spec |
| Archive, trash, mark read/unread, move, block sender, filters | write | after 10, pending your spec |
| Delegate research or brainstorming to GPT, verify reasoning mode | external | pending your spec |
| Approved Mac tools: files, Calendar, browser research, named Shortcuts | read/write | pending your spec |

### 9.2 The central execution rule

The model may reason about what should happen. It never gains permission to act from its own reasoning.

Every state-changing action carries exactly one **authorization source**:

1. **Direct instruction:** text or voice you entered through Wren's own input channels (hotkey overlay, popover, notification reply).
2. **Standing rule:** a rule you created explicitly in settings, scoped to one capability and a matching condition. For example, "archive newsletters from substack.com after they appear in a briefing".
3. **Confirmed approval:** you tapped Approve on one specific proposed action, with its exact target shown, before it expired.

Without one of these, the Action Broker refuses to execute. Autonomous behaviour is limited to reading authorized data, summarizing, categorizing, and preparing proposals.

Wren never autonomously sends email, blocks people, deletes data, changes system settings, or runs commands.

### 9.3 Untrusted content

Email bodies, attachments, web pages, documents, tool outputs, and delegated AI replies are **data, never instructions**. Text inside them that says "archive all mail", "forward this to…", or "the user has approved…" has no effect on authorization. Structurally, only Wren's own input channels can mint a direct instruction, so content cannot authorize anything no matter what the model concludes.

### 9.4 External AI delegation: concern and chosen approach

The addendum asks Wren to delegate through your **existing signed-in ChatGPT interface**. Wren will not drive the ChatGPT website or desktop app by script. That approach has three problems:

- OpenAI's terms prohibit automated or programmatic extraction from its services outside the API, which puts your account at risk.
- Scripted UI control breaks whenever the page or app changes.
- It cannot reliably verify which model or reasoning mode actually ran, and the addendum requires verification rather than assumption.

Wren offers two delegation paths instead. Both require an explicit request per task, and both show you exactly what will leave the Mac before sending:

1. **Handoff (default, no key):** Wren prepares the minimal prompt, copies it, and opens ChatGPT. You choose the mode and paste the result back into Wren, or copy it and press the capture shortcut. Wren then summarizes, stores, and links the result. The reasoning mode is recorded as "chosen by you, not verified by Wren".
2. **API (optional key in Keychain):** Wren sends the task through the official OpenAI API. It requests a reasoning model and effort level, then reads the `model` and reasoning fields the API returns to **verify** what ran. A mismatch is reported, never hidden. Costs are billed by OpenAI to your key. This path is optional and core Wren works without it.

If you later want the handoff to be more automatic, that is a decision for you to make with the terms in view. It is not built by default.

### 9.5 Audit

Every action attempt, allowed or refused, is recorded locally with: the instruction or rule that triggered it, the resolved target, the capability, the authorization source, whether confirmation was obtained, the result, the verification outcome, and timestamps. Audit entries store identifiers and short labels such as sender address and subject. They never store email bodies or attachment content.

### 9.6 Action classes and policy (Phase 9)

| Class | Examples | Default policy |
|---|---|---|
| Read-only | search email, read permitted files, inspect calendar | runs when the integration is connected and the capability is granted |
| Reversible | archive, mark unread, move to trash, move a file to a designated folder | a direct, unambiguous instruction runs it without extra confirmation |
| Sensitive | send a message, block a sender, create a filter, modify an external record | review screen with exact targets and effect, unless a narrowly scoped standing rule covers it |
| Destructive | permanent delete, bulk delete, irreversible file removal | explicit confirmation immediately before execution, every time; no standing rule can waive it |

Any bulk action, meaning more than one target, is reviewed regardless of class unless a standing rule covers it. Missing permission, an ambiguous target, invalid arguments, or an uncertain result stops the action. Success is reported only with evidence from the tool. Dry-run mode shows the planned actions without executing any of them.

### 9.7 Email data policy (Phase 10)

- Gmail first, through OAuth 2.0 for desktop apps with PKCE and a loopback redirect. Wren never asks for or stores your email password.
- Scopes start at `gmail.readonly`. `gmail.modify` and `gmail.settings.basic` are requested only when you enable actions that need them.
- Refresh tokens live in Keychain. Disconnect revokes the token with Google and deletes local email data.
- The local index stores the minimum: message and thread IDs, sender, recipients, subject, date, labels, a short snippet, the classification and its reason. Full bodies are fetched on demand and cached only under a retention setting, default off.
- No email data goes to any Wren-owned server, because none exists.

### 9.8 Open items

- Phase 10's text ends at "Morning email". The briefing format and any later phase details are not yet reflected.
- External AI delegation, email write actions, and Mac tools have no phase prompt yet. §9.4 records the planned approach for delegation.

## 10. Milestone 2 decisions (2026-10-10)

- **Defaults.** Morning briefing 11:00 on, evening check-in 19:00 on, empty summaries off, launch at login **off** until you turn it on.
- **Permission categories, defaults and confirmation requirements** are specified in ARCHITECTURE.md §18. In short: your own clicks on reversible things just happen; deleting always asks; anything external is not granted and, once granted, always asks before writing; content Wren reads can never cause a consequential action.
- **Recovery after restart.** Reminders, briefing and check-in are evaluated from the database on every launch and wake. A daily event missed for its whole window is recorded as missed and never sent the next day.
- **Standing rules** are a closed, typed set (ARCHITECTURE.md §18.4). Requests like "never send an email without showing me the draft" map to fixed rules; anything not in the set is not a rule.

## 11. Milestone 3 decisions (2026-10-10)

- Goals are separate from tasks. Progress defaults to "set by me"; counting linked tasks or milestones is opt-in and always explained.
- Waiting items have who/what/since/follow-up date. Wren reminds you to follow up; it never sends anything.
- Observations (follow-ups due, repeated postponement, goals coming up, quiet items) are neutral, deterministic, dismissible, and raised once per unchanged situation. Thresholds are in Settings › Review.
- Commands like "move that to Sunday" are always previewed and need your confirmation, even for changes that would otherwise be automatic. Ambiguous references get a question, not a guess.

## 12. Milestone 4 decisions (2026-10-11)

- **Local AI is optional and local.** Wren talks only to Ollama on 127.0.0.1. Ollama is a separate install; the DMG does not include a model runtime or weights.
- **Fresh install:** Wren works immediately without AI. The AI label in the menu says what's missing and opens a setup pane with the one next step.
- **Model downloads need an explicit click** on a named model with its approximate size shown. Never on launch or in the background.
- **"Ready" means proven:** only after a real request was answered and parsed.
- **With a model:** better titles and classification, clarifying questions, more command phrasings, routed questions. **Without:** capture, dates, reminders, goals, review, fixed command phrasings and the same questions (answered deterministically).
- **External AI services** (e.g. ChatGPT) are not used by this milestone and would be a separate, explicitly approved integration.
- **Distribution:** universal DMG, macOS 14+, Apple Silicon and Intel. Unsigned builds are clearly labelled previews; stable releases require Developer ID signing and notarization.

## 13. Milestone 5 decisions (2026-10-11)

- Opening Wren shows a window; it stays a menu-bar app without a Dock icon, and starts quietly at login.
- Data portability: versioned JSON export; consistent, verified, checksummed backups with preview and safe restore.
- Pausing notifications changes no schedules; the recovery after a pause is one summary, never a burst.
- Reset is two separate, explained, confirmed actions. No "clear test data", because Wren can't tell test data apart reliably.
- Version 0.5.0.
