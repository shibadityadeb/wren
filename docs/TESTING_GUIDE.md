# Testing Wren for real

This is a hands-on checklist for trying Wren with your own accounts, microphone and notifications.
Each step says what to do and what you should see. It takes about 30 minutes; you can stop after any
section.

(Automated tests mock the providers. [MANUAL_TESTS.md](MANUAL_TESTS.md) records which live checks
have been run and their results.)

## 1. Pick how to run it

| Option | Use it when | How |
|---|---|---|
| **A. The preview release** | You want the real app, as friends would get it | Download `Wren-macOS-universal-unsigned.dmg` from the [latest release](https://github.com/shibadityadeb/wren/releases), check it (below), drag Wren to Applications, open it. macOS blocks unsigned builds the first time: open it once, then **System Settings › Privacy & Security › Open Anyway** |
| **B. A side-by-side test copy** | You have a source checkout and want to keep your installed Wren untouched | `scripts/try-wren.sh`. It builds **Wren Dev** (own data folder, sign-ins and permissions), opens it, and records a log in `build/test-logs/` until you press Ctrl-C |

Option A replaces an installed Wren. Your data is kept and backed up before the upgrade (to data
version 7), but **Wren 0.9 can't open it afterwards**. Option B never touches the installed Wren.

Check a download before opening it:

```bash
shasum -a 256 -c Wren-macOS-universal-unsigned.dmg.sha256
```

For option A, record a log the same way with `scripts/try-wren.sh --installed`, or run:

```bash
/usr/bin/log stream --style compact --predicate 'subsystem == "com.shibadityadeb.wren"' | tee wren-test.log
```

The log records what Wren did (operation names, states, counts), never your words, emails or answers.

## 2. Setup (5 minutes)

- [ ] **Notifications.** Type `remind me to test Wren in 2 minutes` in the capture panel (⌥⇧ Space) and press Return. macOS asks to allow notifications: allow them.
  - Expected: "Reminder set: Test Wren … Scheduled with macOS".
  - If you once said no, go to System Settings › Notifications › Wren (or Wren Dev) › Allow Notifications.
- [ ] **ChatGPT.** Connectors › ChatGPT › **Continue with ChatGPT**. Sign in and approve plan usage.
  - Expected: "Connected and ChatGPT plan usage enabled" and a list of models.
  - Needs a Plus or Pro plan.
- [ ] **Google.** Connectors › Gmail › **Connect Google** and approve Gmail (read-only).
  - Expected: Gmail Connected, with your address shown.
  - While Wren's Google app is in testing, only accounts on its test-user list can connect, and Google asks you to reconnect every 7 days.
- [ ] **Voice.** Connectors › Voice should show "Installed: Apple on-device speech (your language)". If it says "Not installed", open Dictation Settings…, turn Dictation on once and choose your language, then **Check again**.

## 3. Voice (push-to-talk)

- [ ] **Nothing listens by itself.** Use the Mac normally for a minute with Wren open. Expected: the orange microphone dot never appears.
- [ ] **First use.** Close Wren's window. In any app, press and hold **⌥ Space**. The first time, macOS asks for Microphone and Speech Recognition: allow both. Then let go and hold ⌥ Space again.
  - Expected: Wren's panel says "Microphone access is set. Hold the shortcut again and speak."
  - The space you pressed is never typed into the other app.
- [ ] **A spoken reminder.** Hold ⌥ Space and say "remind me to call Sam tomorrow at 10 AM", then let go.
  - While holding: "I'm listening…", a red dot, the moving ring, your words appearing, and the orange microphone dot.
  - On release: the orange dot goes off immediately, then "Transcribing your voice…".
  - Then: the sentence stays in the field, "Working on it…", and finally "Reminder created: Call Sam" with tomorrow 10:00 AM. You don't press Return.
- [ ] **A spoken task.** Hold ⌥ Space: "I need to finish the report by Friday". Expected: saved as a task due Friday.
- [ ] **A spoken GPT request.** Hold ⌥ Space: "ask GPT to research quantum physics".
  - Expected: "GPT request submitted", and later a "GPT has finished" notification.
  - If ChatGPT isn't connected: "ChatGPT isn't connected" with **Connect ChatGPT**, and your request is still shown.
- [ ] **A spoken question.** Hold ⌥ Space: "what am I waiting for?". Expected: the answer from your items.
- [ ] **A follow-up question.** Hold ⌥ Space: "remind me every weekday at 3 PM".
  - Expected: "One quick question: What should I remind you about?".
  - Hold again: "to stretch". Expected: "Reminder created: Stretch", repeating on weekdays at 3 PM.
- [ ] **Letting go of Option first.** While holding ⌥ Space, let go of ⌥ but keep Space down. Expected: recording ends exactly as if you'd let go of both.
- [ ] **Nothing said.** Tap ⌥ Space and let go at once. Expected: "Didn't hear anything, so nothing was done." No item is created.
- [ ] **Cancel and repeat presses.** Press Esc while holding: nothing is done. Mash ⌥ Space while "Working on it…" shows: nothing new starts and nothing runs twice.
- [ ] **Mumble.** Speak very unclearly. Expected: the words wait in the field ("I'm not sure I heard that right"). Return runs them, and **Record again** discards them.
- [ ] **Screen lock.** Hold ⌥ Space and lock the screen (⌃⌘Q) with your other hand. Expected: the recording is cancelled and nothing restarts after unlocking.
- [ ] **Voice button.** In the capture panel (⌥⇧ Space), click **Voice**, speak, and pause. Expected: the same flow, ending on the pause.

## 4. Tasks and reminders

- [ ] `I need to finish the report by Friday`
  - Expected: a task "Finish the report", due Friday.
- [ ] `remind me every weekday at 3 PM`
  - Expected: Wren asks "What should I remind you about?". Answer `to stretch`: a repeating weekday reminder.
- [ ] Set `remind me to water the plants tomorrow at 9 AM`, then type `move that reminder to Sunday`.
  - Expected: a preview "Move “Water the plants” to Sunday". Return confirms.
- [ ] **Delivery while Wren is quit.** Wait for the 2-minute reminder from setup, but quit Wren (⌘Q) before it's due.
  - Expected: the notification still appears on time.
  - Click it: Wren opens on that item. Then try **Done** and **Remind me in 1 hour** on another reminder.
- [ ] Reopen Wren. Expected: no second notification for the same reminder.

## 5. GPT (uses your ChatGPT plan's allowance)

- [ ] `ask GPT to think deeply about whether I should learn Rust or Go first`
  - Expected: the card says it asks for high reasoning effort and runs.
  - You can close the panel. A notification "GPT has finished" with "Deep thinking: …" appears.
  - Click it: the exact result opens. Reasoning should read "high (asked for and reported)".
- [ ] `ask GPT to research the latest stable Swift release and cite sources`
  - Expected: the result shows "Web search: Used: N searches" and a "Sources ChatGPT cited" list.
  - If ChatGPT didn't search, it says so.
  - Find in answer highlights words.
- [ ] Press Return twice quickly on a new GPT request. Expected: only one request in Delegate.
- [ ] Turn Wi-Fi off and ask GPT something. Expected: Failed, with a reason. Turn Wi-Fi on and press **Retry**: it completes on the same entry.
- [ ] `Ask GPT.` with nothing else. Expected: Wren asks what ChatGPT should do and sends nothing.

## 6. Gmail (while Wren runs)

- [ ] `do I have an important email from <a real sender>?`
  - Expected: an answer from your inbox, with reasons.
- [ ] **Alerts.** Turn on Inbox › "Check for new mail while Wren runs". From another account, send yourself `Urgent: please confirm by today`.
  - Expected: within the check interval (default 5 minutes), one notification "Important email from …" with the subject and "Why: …".
- [ ] **Snooze.** Choose **Snooze alert for 1 hour** on that alert. Expected: it comes back once about an hour later if it's still unread, and not if you read it meanwhile.
- [ ] **Opening an alert.** Click an alert. Expected: Wren opens that exact message, and **Open in Gmail** opens the right conversation. The email stays unread in Gmail.
- [ ] **Mark as read (optional).** In the message, choose **Allow Mark as read…** and approve on Google's page. Then **Mark as read**. Expected: it's read in Gmail too.
- [ ] Quit Wren and send another urgent email. Expected: no alert until Wren runs again.

## 7. Settings and quitting

- [ ] Settings › **Voice, GPT and Gmail** shows each tool's real state. Toggle **Play notification sounds** off: the next alert is silent.
- [ ] Close the window: the bird stays in the menu bar. ⌘Q: the bird and Dock icon go.

## Reporting a problem

Open an [issue](https://github.com/shibadityadeb/wren/issues) with:
- the step number
- what you expected and what happened
- your macOS version and Mac model
- the log file

Don't paste tokens or email content. Wren never logs them, so the log is safe to attach.
