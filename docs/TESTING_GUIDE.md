# Testing Wren for real

This is a hands-on checklist for trying Wren with your own accounts, microphone and notifications.
Each step says what to do and what you should see. It takes about 30 minutes; you can stop after any
section.

(Automated tests mock the providers. [MANUAL_TESTS.md](MANUAL_TESTS.md) records which live checks
have been run and their results.)

## 1. Pick how to run it

| Option | Use it when | How |
|---|---|---|
| **A. The preview release** | You want the real app, as friends would get it | Download `Wren-macOS-universal-unsigned.dmg` (named `Wren-macOS-universal.dmg` once releases are signed) from the [latest release](https://github.com/shibadityadeb/wren/releases), check it (below), drag Wren to Applications, open it. macOS blocks unsigned builds the first time: open it once, then **System Settings › Privacy & Security › Open Anyway** |
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

The log records what Wren did (operation names, states, counts), not your words, emails or answers. Skim it before sharing anyway: some macOS error messages may name a file or account.

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
- [ ] **A polite reminder.** Hold ⌥ Space: "can you make a reminder to call Sam tomorrow at 10 AM?". Expected: "Reminder created: Call Sam", tomorrow 10:00 AM. Never a "who should answer?" choice.
- [ ] **A spoken task.** Hold ⌥ Space: "I need to finish the report by Friday". Expected: "Task created: Finish the report", the deadline Friday, and the reminders: Thursday at your default time (the day before) and Friday.
- [ ] **A spoken GPT request.** Hold ⌥ Space: "ask GPT to research quantum physics".
  - Expected (website mode, the default): ChatGPT opens in your browser with the request copied, and the panel says it's awaiting your submission.
  - In "run in Wren" mode: "GPT request submitted", later "GPT has finished".
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
  - Expected: "Task created: Finish the report", "Deadline: Friday", "Reminders: Thursday 10:00 AM (the day before) and Friday 10:00 AM", "Scheduled with macOS".
  - Settings › Notifications › **Also remind me the day before a deadline** off: only the Friday reminder.
- [ ] `remind me to ask GPT about quantum physics tomorrow`
  - Expected: "Reminder created: Ask GPT about quantum physics", tomorrow at your default time. Nothing opens in ChatGPT.
- [ ] `make a task to follow up with the recruiter`, then `remind me one day before the deadline`
  - Expected: "No deadline was given, so none is set", then "has no deadline yet" (Wren doesn't invent one). With a task that has a deadline, the second sentence shows a preview for the day before.
- [ ] `remind me every weekday at 3 PM`
  - Expected: Wren asks "What should I remind you about?". Answer `to stretch`: a repeating weekday reminder.
- [ ] Set `remind me to water the plants tomorrow at 9 AM`, then type `move that reminder to Sunday`.
  - Expected: a preview "Move “Water the plants” to Sunday". Return confirms.
- [ ] **Delivery while Wren is quit.** Wait for the 2-minute reminder from setup, but quit Wren (⌘Q) before it's due.
  - Expected: the notification still appears on time.
  - Click it: Wren opens on that item. Then try **Done** and **Remind me in 1 hour** on another reminder.
- [ ] Reopen Wren. Expected: no second notification for the same reminder.

## 5. GPT and local AI

Wren uses the ChatGPT **website** for "ask GPT" by default: it opens chatgpt.com in your browser with your question already in the message box. Your browser should be signed in to ChatGPT. Press Enter there to send it: ChatGPT doesn't let apps send for you.

- [ ] **Scenario 1: an explicit GPT request.** `Ask ChatGPT what gradient descent is`.
  - Expected: no "who should answer?" question. ChatGPT opens with the question in its box, and the card says "Prompt loaded, submission unverified".
  - Click **Detect conversation automatically…** and allow Wren to control your browser when macOS asks. Then press Enter in ChatGPT.
  - Expected: the card turns to "Submitted to ChatGPT", and **Open conversation in ChatGPT** opens that exact chat. Never "Completed".
- [ ] **Link the conversation.** In ChatGPT, copy the address bar (`https://chatgpt.com/c/…`). In Wren choose **Link conversation**. Expected: "Conversation linked".
  - Copying something else (the ChatGPT home page, another site) is refused with an explanation.
- [ ] **Scenario 5: open that in GPT.** `open that in GPT`. Expected: your browser opens that exact conversation.
  - Without a link it opens ChatGPT and says the link is missing.
- [ ] **Scenario 4: continue in ChatGPT.** `continue that research in ChatGPT`. Expected: the linked conversation opens, and the follow-up is on the clipboard to paste there.
  - Without a link, a new ChatGPT chat opens with a request that quotes your earlier one, and Wren says so.
- [ ] **Scenario 3: research.** `ask GPT to research this topic: the history of the transistor`. Expected: the instruction "research" is kept in what's copied or filled in.
  - `ask ChatGPT to use Deep Research to investigate this` adds a note that Wren can't turn on Deep Research; choose it in ChatGPT yourself.
- [ ] **Scenario 2: no assistant named.** `What is gradient descent?`. Expected: Wren's local AI answers.
  - If no local AI is set up, you get choices (Ask local AI / Open in ChatGPT / Save as a note), not an automatic ChatGPT request.
- [ ] **Follow-ups keep their tool.** After a local answer, `continue that research` continues with local AI. After an in-Wren GPT answer, it continues in Wren.
- [ ] **Experimental prefill (optional).** Connectors › ChatGPT › **Check it in my browser…**. Report what you saw: filled in and sent / filled in, not sent / empty.
  - Only if it was filled in can you turn on **Fill in my request automatically**. Then an `ask GPT …` request opens ChatGPT with the request already there, and the status reads "Opened in ChatGPT", not "sent".
- [ ] **Scenario 7: run with connected ChatGPT in Wren** (uses your plan's allowance). Connectors › ChatGPT › When you ask GPT › *Run with connected ChatGPT in Wren*. Then `ask GPT to think deeply about whether I should learn Rust or Go first`.
  - Expected: a "GPT has finished" notification, and the result opens in Wren with Mode "Run with connected ChatGPT in Wren…".
  - There's no "Open conversation" button; **Open ChatGPT website** only opens the site.
  - `ask GPT to research the latest stable Swift release and cite sources` shows the web searches and sources ChatGPT reports.
- [ ] **Scenario 6: not signed in.** In that mode, disconnect ChatGPT and `ask GPT what a monad is`.
  - Expected: **Connect ChatGPT** and **Open in ChatGPT website instead**. Never an answer from the local model.
- [ ] **Scenario 8: no duplicates.** Press Return twice quickly on a GPT request.
  - Expected: one browser tab (website mode) or one request in Delegate (in-Wren mode).
  - Retry reruns the same entry. Opening the browser or copying is never shown as completed.
- [ ] `Ask GPT.` with nothing else. Expected: Wren asks what ChatGPT should do and opens nothing.

## 6. Gmail (while Wren runs)

- [ ] `do I have an important email from <a real sender>?`
  - Expected: an answer from your inbox, with reasons.
- [ ] **Alerts.** Turn on Inbox › "Check for new mail while Wren runs". From another account, send yourself `Urgent: please confirm by today`.
  - Expected: within the check interval (default 5 minutes), one notification "Important email from …" with the subject and "Why: …".
- [ ] **Snooze.** Choose **Snooze alert for 1 hour** on that alert. Expected: it comes back once about an hour later if it's still unread, and not if you read it meanwhile.
- [ ] **Opening an alert.** Click an alert. Expected: your browser opens that exact conversation in Gmail, in the account you connected (Gmail may mark it read when it opens, as it always does). **Show in Wren** opens it in Wren instead, without changing Gmail.
- [ ] **What's in an alert.** Expected: the sender, the subject, the email's first sentence and "Why: …". Inbox settings › **Include the email's first sentence in alerts** off: subject and reason only.
- [ ] **Mark as read (optional).** In the message, choose **Allow Mark as read…** and approve on Google's page. Then **Mark as read**. Expected: it's read in Gmail too.
- [ ] Quit Wren and send another urgent email. Expected: no alert until Wren runs again.

## 7. Settings and quitting

- [ ] Settings › **Voice, GPT and Gmail** shows each tool's real state. Toggle **Play notification sounds** off: the next alert is silent.
- [ ] Close the window: the bird stays in the menu bar. ⌘Q: the bird and Dock icon go.
- [ ] After ⌘Q, a reminder set earlier still arrives on time, and no email alert arrives until Wren runs again.

## Reporting a problem

Open an [issue](https://github.com/shibadityadeb/wren/issues) with:
- the step number
- what you expected and what happened
- your macOS version and Mac model
- the log file

Don't paste tokens or email content. Wren doesn't log them, but read the log over and remove anything personal before attaching it.
