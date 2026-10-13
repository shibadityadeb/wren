import AppKit
import WrenCore

/// Gmail inbox intelligence while Wren runs: incremental checks, alerts for urgent new mail, the daily
/// digest, corrections, and Mark as read when Google granted it. Every Gmail read and write goes
/// through the broker (audited, permission-checked). Nothing here runs when Wren isn't running.
@MainActor
extension AppModel {
    var mailStore: MailboxStore { MailboxStore(directory: WrenStore.defaultDirectory) }
    var gmailUsable: Bool { previewGmail ?? hub.gmail.state.isUsable }
    var canMarkRead: Bool { previewGmail ?? (gmailUsable && hub.google.canMarkRead && policy.grants.contains(.emailModify)) }
    var backgroundMailAllowed: Bool { policy.rules.contains(.monitorConnectedEmail) }

    var triageSettings: MailTriageSettings { MailTriageSettings(importantSenders: Set(settings.importantSenders), senderRules: mailbox.senderRules) }

    func startMail() {
        mailbox = mailStore.load()
        scheduleMailCheck(after: 5)
    }

    func updateMail(_ f: (inout MailPreferences) -> Void) {
        var p = mailPrefs; f(&p)
        mailPrefs = p.normalized()
        settings.mail = mailPrefs
        scheduleMailCheck(after: 1)
    }

    func scheduleMailCheck(after seconds: TimeInterval? = nil) {
        mailTimer?.invalidate()
        let interval = seconds ?? TimeInterval(mailPrefs.pollingMinutes * 60) * mailBackoff
        mailTimer = Timer.scheduledTimer(withTimeInterval: max(1, interval), repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.checkMail(.system("mail monitor")) }
        }
        mailTimer?.tolerance = min(30, interval * 0.1)
        nextMailCheck = Date().addingTimeInterval(interval)
    }

    /// One check: sync, alerts, then the digest if one is due. `origin` is the user for "Check now".
    func checkMail(_ origin: ActionOrigin) async {
        defer { if gmailUsable { scheduleMailCheck() } else { mailTimer?.invalidate(); nextMailCheck = nil } }
        guard gmailUsable, let broker, !mailSyncing else { return }
        if case .system = origin, !backgroundMailAllowed { mailStatus = "Background checking is off."; return }
        mailSyncing = true
        defer { mailSyncing = false }
        let api: GmailAPI = hub.gmail.gmail
        let triage = triageSettings, now = clock.now, cal = clock.calendar
        var working = mailbox
        do {
            let result = try await broker.performExternal(emailRead(origin), detail: { "\($0.mode.rawValue) sync: \($0.newMessageIDs.count) new" }) {
                try await MailSync.sync(&working, api: api, settings: triage, now: now, calendar: cal)
            }
            mailBackoff = 1
            mailbox = working
            mailStatus = nil
            await deliverMailAlerts(newIDs: result.newMessageIDs)
            await deliverDigestIfDue()
        } catch {
            mailbox.lastError = Self.mailProblem(error); mailbox.lastErrorAt = now
            mailStatus = mailbox.lastError
            switch error {
            case ConnectorError.rateLimited(let after): mailBackoff = min(6, max(2, (after ?? 0) / Double(mailPrefs.pollingMinutes * 60)))
            case ConnectorError.unauthorized, ConnectorError.forbidden: await hub.gmail.refresh(); connectorsChanged()
            case ConnectorError.network, ConnectorError.timedOut, ConnectorError.server: mailBackoff = min(6, mailBackoff * 2)
            default: break
            }
        }
        saveMailbox()
    }

    static func mailProblem(_ e: Error) -> String {
        switch e {
        case ConnectorError.unauthorized: "Google no longer accepts Wren's sign-in. Reconnect Google to keep checking mail."
        case ConnectorError.forbidden: "Google denied access to Gmail. Reconnect Google and allow Gmail."
        case ConnectorError.rateLimited: "Gmail asked Wren to slow down. Wren will check less often for a while."
        case ConnectorError.network, ConnectorError.timedOut: "Couldn't reach Gmail. Wren will try again."
        case ActionBroker.ExternalOutcome.denied(let m): m
        default: (e as? LocalizedError)?.errorDescription ?? "\(e)"
        }
    }

    func saveMailbox() {
        do { try mailStore.save(mailbox) } catch { log.error("mailbox save failed: \(error.localizedDescription, privacy: .public)") }
        mailVersion += 1
    }

    // MARK: Alerts

    func deliverMailAlerts(newIDs: [String]) async {
        guard mailPrefs.alertsEnabled, pause?.isActive(at: clock.now) != true else { return }
        guard await notifications.canDeliver() else { return }
        let d = MailAlertPolicy.decide(&mailbox, candidates: newIDs, level: mailPrefs.alertLevel, quiet: mailPrefs.quietHours,
                                       now: clock.now, calendar: clock.calendar)
        for id in d.individual {
            guard let item = mailbox.items[id] else { continue }
            let c = item.classification
            let n = MailAlertText.make(item)
            _ = await notifications.deliverMailAlert(id: id, title: n.title, body: n.body, canMarkRead: canMarkRead)
        }
        if !d.summarized.isEmpty {
            _ = await notifications.deliverMailAlert(id: "summary-\(Int(clock.now.timeIntervalSince1970))",
                                                     title: "\(d.summarized.count) more important emails",
                                                     body: "Open Wren's Inbox to see them.", canMarkRead: false, isSummary: true)
        }
        if !d.individual.isEmpty || !d.summarized.isEmpty {
            log.notice("mail alerts: \(d.individual.count, privacy: .public) individual, \(d.summarized.count, privacy: .public) summarized")
        }
    }

    // MARK: Digest

    func deliverDigestIfDue() async {
        guard let due = MailDigest.due(mailbox, settings: mailPrefs.digest, now: clock.now, base: clock.calendar) else { return }
        // Recorded (and saved) before delivery: a restart can't deliver this digest again.
        let rec = MailDigest.build(&mailbox, key: due.key, slot: due.slot, late: due.late, now: clock.now)
        saveMailbox()
        guard rec.state == .pending else { return }
        let n = MailDigest.notification(rec)
        var ok = false
        if pause?.isActive(at: clock.now) != true, await notifications.canDeliver() {
            ok = await notifications.deliverDigest(key: rec.key, title: n.title, body: n.body)
        }
        MailDigest.mark(&mailbox, key: rec.key, ok ? .delivered : .undelivered)
        saveMailbox()
    }

    var latestDigest: DigestRecord? { let _ = mailVersion; return mailbox.lastDigest }

    // MARK: User actions

    func handleMail(_ r: NotificationService.MailResponse) {
        switch r {
        case let .open(id): openMail(id)
        case let .markRead(id): Task { await markRead(id) }
        case let .dismiss(id): dismissMailAlert(id)
        case let .snooze(id): snoozeMail(id, hours: 1)
        case .openDigest: route = .inbox; openMainWindow()
        }
    }

    func openMail(_ id: String) {
        route = mailbox.items[id] != nil ? .mailMessage(id) : .inbox
        openMainWindow()
    }

    /// Wren's alert only; the Gmail message is unchanged.
    func dismissMailAlert(_ id: String) {
        mailbox.items[id]?.dismissedAt = clock.now
        notifications.withdrawMailAlert(id: id)
        saveMailbox()
    }

    func snoozeMail(_ id: String, hours: Double) {
        MailAlertPolicy.snooze(&mailbox, id: id, until: clock.now.addingTimeInterval(hours * 3600))
        notifications.withdrawMailAlert(id: id)
        // Check again when the snooze ends, so the alert comes back on time even between polls.
        DispatchQueue.main.asyncAfter(deadline: .now() + hours * 3600 + 1) { [weak self] in
            MainActor.assumeIsolated { guard let self else { return }; Task { await self.deliverMailAlerts(newIDs: []); self.saveMailbox() } }
        }
        saveMailbox()
    }

    func correctMail(_ id: String, to c: MailCategory) {
        MailCorrections.setCategory(&mailbox, id: id, c)
        saveMailbox()
    }

    func setSenderRule(_ sender: String, _ rule: SenderRule?) {
        MailCorrections.setSenderRule(&mailbox, sender: sender, rule, settings: MailTriageSettings(importantSenders: Set(settings.importantSenders)),
                                      now: clock.now, calendar: clock.calendar)
        saveMailbox()
    }

    /// Marks the real Gmail message read: permission check, provider call, provider confirmation,
    /// then the local state. On failure the message stays unread here and Retry is offered.
    @discardableResult
    func markRead(_ id: String) async -> String? {
        guard let broker, let item = mailbox.items[id] else { return "That email isn't in Wren's inbox anymore." }
        guard canMarkRead else { return "Mark as read needs Google's permission to change your email's read state. Choose “Allow Mark as read…” first." }
        let client = hub.gmail.gmail
        let req = ActionRequest(action: BuiltInAction.markEmailRead, target: TargetRef(kind: "gmail.message", id: id, label: "Email from \(item.message.senderName)"),
                                origin: .user(.popover), createdAt: clock.now)
        do {
            // The button press on exactly this message is the confirmation.
            let labels = try await broker.performExternal(req, confirmation: broker.confirm(req), detail: { _ in "UNREAD removed (confirmed by Gmail)" }) {
                let labels = try await client.perform(.markRead, on: id)
                guard !labels.contains("UNREAD") else { throw ConnectorError.badResponse("Gmail still reports the message as unread") }
                return labels
            }
            mailbox.items[id]?.message.labels = labels
            mailbox.items[id]?.lastActionError = nil
            mailbox.record(MailActionRecord(at: clock.now, action: GmailAllowedAction.markRead.rawValue, messageID: id, succeeded: true, detail: "confirmed by Gmail"))
            notifications.withdrawMailAlert(id: id)
            saveMailbox()
            return nil
        } catch {
            let m = Self.mailProblem(error)
            mailbox.items[id]?.lastActionError = m
            mailbox.record(MailActionRecord(at: clock.now, action: GmailAllowedAction.markRead.rawValue, messageID: id, succeeded: false, detail: String(m.prefix(120))))
            saveMailbox()
            return m
        }
    }

    /// Asks Google for the extra permission (gmail.modify) on top of what's granted.
    func allowMarkAsRead() { connectGoogle(scopes: [ConnectorCatalog.gmailModifyScope]) }

    func setBackgroundMail(_ on: Bool) {
        setRule(.monitorConnectedEmail, on)
        if on { scheduleMailCheck(after: 1) }
    }

    /// Disconnect or "Remove all data": cached mail and its bookkeeping go too.
    func clearMailData() {
        mailStore.clear()
        mailbox = MailboxState()
        mailTimer?.invalidate(); nextMailCheck = nil
        mailVersion += 1
    }

    /// After "Remove all Wren data": revoke and delete every connector sign-in and cached mail.
    func removeConnectorData() async {
        await hub.google.disconnect()
        await hub.notion.disconnect()
        await hub.chatgpt.disconnect()
        hub.gmail.emailCache?.clear()
        try? (hub.credentials as? FileCredentialStore)?.deleteAll()
        clearMailData()
        await hub.registry.refreshAll()
        connectorsChanged()
    }

    /// "Add task…" from an email: prefilled, never saved without the user pressing Return.
    func taskFromMail(_ item: MailItem) {
        openCapturePanel()
        prefillCapture?("Reply to \(item.message.senderName) about \(item.message.subject)")
    }
}
