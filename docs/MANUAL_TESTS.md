# Manual and live tests

Automated tests (`swift test`) cover the
logic with fakes: they are not live tests. This page lists what needs a real Mac session, a person,
an account or real time, and what has actually been run. Use a **Wren Dev** build
(`scripts/build-app.sh debug --dev-identity`) so tests never touch the installed Wren's data.

## Status of the last pass (2026-10-11, Wren Dev 0.8.0 debug, macOS 26, Apple Silicon)

| Area | Test | Result |
|---|---|---|
| Lifecycle | App runs as a regular foreground app (Dock icon) | Run: macOS reports `ApplicationType = Foreground` |
| Lifecycle | Opening a second copy exits and activates the running one | Run: second process logged "another Wren instance is running; exiting" |
| Lifecycle | Quit removes the menu-bar item, releases shortcuts and the data lock, and the process ends | Run with a Quit Apple Event (log shows the clean-up line, process gone) |
| Lifecycle | Relaunch after quit | Run |
| Lifecycle | Quit never opens the microphone | Run, after a fix: quitting used to touch the audio input and could raise the microphone prompt |
| Lifecycle | Exactly one bird in the menu bar, ⌘Q from the keyboard, Dock click reopens the window, menu-bar Quit | Not run by hand (needs someone at the screen) |
| Reminders | "Remind me to call Sam tomorrow at 3" asks "Is that 3 AM or 3 PM?" | Run in the app |
| Reminders | A past time is refused with a suggestion | Run in the app |
| Reminders | Notification actually appears at the time, after quitting, not again after completion | **Not run**: needs a person to allow notifications for the app, then waiting |
| Voice | Command step after transcription (answers, proposals, saving) | Run in the app via `wren-dev://debug/voice-command` |
| Voice | On-device speech model installed | Run: available |
| Voice | Real microphone, "Hey Wren", the voice shortcut | **Not run**: needs a person to allow Microphone and Speech Recognition |
| ChatGPT | Wren's authorization request is accepted by OpenAI (reaches the sign-in page; a made-up client is rejected) | Run in a browser |
| ChatGPT | Full sign-in, model list, a real answer, reconnect, refresh, usage limit, disconnect | **Not run**: needs your ChatGPT Plus or Pro sign-in |
| Google | Consent, partial grant, adding a permission, cancel, denial, nothing granted, expiry, revocation, disconnect | Run against stubbed Google endpoints over a real loopback redirect (automated); **not run against Google**: no maintainer client ID registered yet |
| Notion | Registration with a loopback redirect and reaching Notion's consent page | Run against the live Notion MCP service; full sign-in **not run** (needs a Notion account) |
| Notion | Sign-in, tools, denial, cancel, wrong issuer, refresh, expiry, network, disconnect | Run against stubbed Notion endpoints over a real loopback redirect (automated) |
| Calendar (this Mac) | Reading events through macOS | **Not run**: needs a person to allow Calendars access |

## Steps

### Lifecycle
1. Quit any other Wren. Open Wren Dev. Check: one Dock icon, one bird in the menu bar, the window opens.
2. Close the window: the bird stays; click the Dock icon: the window comes back.
3. Open the app again from Finder: no second bird; the existing window comes forward.
4. Right-click the bird: Open Wren, New Capture, Settings…, Quit Wren.
5. ⌘Q: the bird disappears, the Dock icon goes, and the orange microphone indicator (if "Hey Wren" was on) goes off.
6. Open it from the Dock or Finder again.

### Reminders (needs notifications allowed)
1. In the capture panel (⌥ Space), type `remind me to test Wren in 2 minutes`. macOS asks for notifications the first time; allow.
   Expected reply: "Reminder set … Scheduled with macOS".
2. Quit Wren (⌘Q). Wait 2 minutes: the notification appears without Wren running.
3. Open Wren: the item shows the reminder as sent; no second notification arrives.
4. `remind me to stretch every weekday at <a time 2 minutes ahead>`: fires; **Done** in the notification keeps the series (next weekday shown in the item).
5. `snooze the current reminder for 5 minutes`: the preview shows the time; Return confirms; it fires 5 minutes later.
6. Set a reminder, then complete it before it fires: nothing fires. Same with delete.
7. Turn notifications off for Wren in System Settings; set a reminder: Wren says it will only show inside Wren. Turn them back on; within a moment Settings › Notifications shows it scheduled.
8. Time zone: change the Mac's time zone; a repeating 3 PM reminder still fires at 3 PM local.

Debug check at any point: `open -a "$PWD/build/Wren Dev.app" "wren-dev://debug/reminders"`, then read
`/usr/bin/log show --last 1m --predicate 'subsystem == "com.shibadityadeb.wren"'` for `debug pending` lines.

### Voice (needs Microphone and Speech Recognition allowed)
1. Connectors › Voice: turn on "Listen for “Hey Wren”". Allow the microphone and speech prompts. The bird gets a dot; macOS shows the orange indicator.
2. With Wren in the background, say: "Hey Wren, remind me to call Sam tomorrow at 10 AM." The panel opens, shows the words as you speak, stops when you pause, and replies "Reminder set: Call Sam, tomorrow at 10:00 AM".
3. Press ⌥⇧ Space, say "snooze the current reminder for 30 minutes", pause: same pipeline; a preview to confirm.
4. Start speaking and press Esc: nothing happens and recording stops.
5. Say "Hey Wren" and nothing else: after a few seconds, "Didn't hear a command".
6. Unplug or switch microphones while listening: listening resumes on the new input.
7. Quit: the orange indicator goes off.

### ChatGPT (needs a Plus or Pro account)
1. Connectors › ChatGPT › Continue with ChatGPT; sign in and approve plan usage. Expect "Connected and ChatGPT plan usage enabled", the account email, a model list, "Using ChatGPT plan" and "Manage usage".
2. Delegate › "Reply with the word ready" › Send with ChatGPT: the answer streams in, labelled with the model.
3. Reconnect, then Disconnect: tokens are removed and the state returns to "Available to connect".
4. Sign in but untick plan usage: "Account connected, plan usage not authorized".

### Google (after the maintainers' setup in MAINTAINER_SETUP.md, with a listed test account)
1. Connectors › Gmail: both permissions ticked › Connect Google. Google's page opens. Approve both. Wren comes forward and shows the account, both permissions as Granted, and Gmail and Calendar as Connected.
2. Ask "anything from the recruiter?", "summarise my unread mail", "what meetings do I have tomorrow?": real results.
3. Disconnect Google, then connect again and untick Gmail on Google's page: Calendar is Connected and Gmail shows Missing permissions with Add…. Choose Add… and approve: Gmail turns on, Calendar stays.
4. Close Google's tab without approving: after 5 minutes (or on the next try) Wren says nothing changed. Choose Cancel on Google's page: "You chose not to allow access".
5. Remove Wren at myaccount.google.com › Security › Third-party access, then Check again: Reauthorization required.
6. Disconnect Google: Wren's entry disappears from your Google account's third-party access list.

### Notion (no setup needed)
1. Connectors › Notion › Connect Notion. Sign in on Notion's page and allow. Wren comes back and shows "Connected to the workspace …".
2. Search Notion in the connector page and in Delegate; add a page as context; create a page (confirm first).
3. Deny on Notion's page: Wren says nothing was connected. Disconnect: Wren removes the sign-in.

### Calendar (this Mac)
1. Connectors › Calendar › Use this Mac's calendars. macOS asks for Calendars access; allow.
2. Wren shows how many calendars it found and which accounts. Ask "what meetings do I have tomorrow?".
3. Deny access instead: Missing permissions with a Privacy Settings button.
