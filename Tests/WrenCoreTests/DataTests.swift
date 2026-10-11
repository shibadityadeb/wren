import XCTest
@testable import WrenCore

@MainActor
final class ExportTests: XCTestCase {
    let cal = calendar("Asia/Kolkata")
    var now: Date { at(cal, 2026, 10, 8, 12) }

    func populated() throws -> Harness {
        let h = try Harness(url: tempStoreURL(), now: now, calendar: cal)
        let g = try h.store.createGoal(title: "Publish article", originalText: "I want to publish an article by end of month",
                                       targetDate: at(cal, 2026, 10, 31), method: .milestones, now: now)
        let a = try h.add("Outline", deadline: at(cal, 2026, 10, 10))
        try h.store.link(a, to: g, asMilestone: true, now: now)
        try h.store.snooze(a, until: now.addingTimeInterval(3600), now: now)
        let w = try h.add("Contract from legal", kind: .waiting)
        try h.store.updateWaiting(w, waitingOn: "Legal", expected: "Signed contract", followUpAt: at(cal, 2026, 10, 9), now: now)
        try h.store.acknowledgeFollowUp(w, next: at(cal, 2026, 10, 12), note: "emailed", now: now)
        let d = try h.add("Pay rent"); try h.store.complete(d, now: now)
        try h.policy.setRule(.autoApplyInterpretations, enabled: false)
        return h
    }

    func testRoundTripPreservesRecordsAndRelationships() throws {
        let h = try populated()
        let export = try WrenExport.make(from: h.store, appVersion: "0.5.0", now: now, timeZone: cal.timeZone)
        let data = try export.encoded()
        let back = try WrenExport.decode(data)
        XCTAssertEqual(back, export, "lossless round trip")

        XCTAssertEqual(back.manifest.format, "wren-export")
        XCTAssertEqual(back.manifest.formatVersion, 1)
        XCTAssertEqual(back.manifest.timeZone, "Asia/Kolkata")
        XCTAssertEqual(back.manifest.counts["items"], 3)
        let outline = try XCTUnwrap(back.items.first { $0.title == "Outline" })
        let goal = try XCTUnwrap(back.goals.first)
        XCTAssertEqual(outline.goalID, goal.id)
        XCTAssertTrue(outline.isMilestone)
        XCTAssertEqual(goal.linkedItemIDs, [outline.id])
        XCTAssertEqual(outline.deadline, at(cal, 2026, 10, 10))
        XCTAssertEqual(outline.postponementCount, 1)
        XCTAssertTrue(outline.history.contains { $0.kind == "snoozed" })
        let w = try XCTUnwrap(back.items.first { $0.kind == "waiting" })
        XCTAssertEqual(w.waiting?.waitingOn, "Legal")
        XCTAssertEqual(w.waiting?.followUpAt, at(cal, 2026, 10, 12))
        XCTAssertTrue(w.history.contains { $0.kind == "followedUp" && $0.note == "emailed" })
        XCTAssertTrue(goal.progressExplanation.contains("milestone"))
        XCTAssertFalse(back.policy.standingRules.contains("autoApplyInterpretations"))
    }

    func testReadableOutsideWrenAndNoSecrets() throws {
        let h = try populated()
        let json = String(decoding: try WrenExport.make(from: h.store, appVersion: "0.5.0", now: now).encoded(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"format\" : \"wren-export\""))
        XCTAssertTrue(json.contains("2026-10-10T") || json.contains("2026-10-09T"), "ISO 8601 dates")
        for secret in ["password", "apiKey", "api_key", "token\"", "p12", "secret"] {
            XCTAssertFalse(json.lowercased().contains(secret.lowercased()) && !json.contains("tokens and credentials"), secret)
        }
        // Plain JSON a script can read.
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertNotNil(obj?["items"])
    }

    func testRejectsWrongFormatAndNewerVersion() throws {
        XCTAssertThrowsError(try WrenExport.decode(Data(#"{"hello":1}"#.utf8))) { XCTAssertEqual($0 as? WrenExport.ExportError, .notAnExport) }
        let newer = #"{"manifest":{"format":"wren-export","formatVersion":99}}"#
        XCTAssertThrowsError(try WrenExport.decode(Data(newer.utf8))) { XCTAssertEqual($0 as? WrenExport.ExportError, .unsupportedVersion(99)) }
    }

    func testNeverSilentlyOverwrites() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wren-export-\(UUID()).json")
        try WrenExport.write(Data("first".utf8), to: url, replacingConfirmed: false)
        XCTAssertThrowsError(try WrenExport.write(Data("second".utf8), to: url, replacingConfirmed: false))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "first")
        try WrenExport.write(Data("second".utf8), to: url, replacingConfirmed: true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "second")
        let bad = URL(fileURLWithPath: "/System/wren-nope/export.json")
        XCTAssertThrowsError(try WrenExport.write(Data("x".utf8), to: bad, replacingConfirmed: false)) {
            guard case .writeFailed = $0 as? WrenExport.ExportError else { return XCTFail("\($0)") }
        }
    }
}

@MainActor
final class BackupTests: XCTestCase {
    let cal = calendar("Asia/Kolkata")
    var now: Date { at(cal, 2026, 10, 8, 12) }

    func testConsistentBackupWhileStoreIsOpenAndVerified() throws {
        let h = try Harness(url: tempStoreURL(), now: now, calendar: cal)
        for i in 0..<20 { _ = try h.add("Item \(i)") }   // store is open and in WAL mode
        let b = try h.backups.createBackup(reason: .manual, appVersion: "0.5.0", now: now)
        let m = try XCTUnwrap(b.manifest)
        XCTAssertEqual(m.format, "wren-backup")
        XCTAssertEqual(m.counts["items"], 20)
        XCTAssertEqual(m.schemaVersion, WrenStore.schemaVersion)
        XCTAssertEqual(m.sha256.count, 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.directory.appendingPathComponent("Wren.store-wal").path), "single self-contained file")
        let p = try h.backups.preview(b)
        XCTAssertEqual(p.counts["items"], 20)
        XCTAssertEqual(p.newestItemTitles.count, 5)
        XCTAssertEqual(h.backups.list().map(\.id), [b.id])
    }

    func testTamperedAndCorruptedBackupsAreRejected() throws {
        let h = try Harness(url: tempStoreURL(), now: now, calendar: cal)
        _ = try h.add("x")
        let b = try h.backups.createBackup(reason: .manual, appVersion: "t", now: now)
        let file = b.directory.appendingPathComponent("Wren.store")
        // Flip bytes in the middle of the file.
        var data = try Data(contentsOf: file)
        data.replaceSubrange(2000..<2016, with: Data(repeating: 0xFF, count: 16))
        try data.write(to: file)
        XCTAssertThrowsError(try h.backups.verify(b)) { XCTAssertEqual($0 as? BackupError, .checksumMismatch) }

        // Not a database at all, and no manifest (looks legacy).
        let junk = h.backups.backupsDirectory.appendingPathComponent("junk")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data("not sqlite".utf8).write(to: junk.appendingPathComponent("Wren.store"))
        let entry = try XCTUnwrap(h.backups.list().first { $0.id == "junk" })
        XCTAssertThrowsError(try h.backups.verify(entry))

        // Newer format.
        let newer = try h.backups.createBackup(reason: .manual, appVersion: "t", now: now.addingTimeInterval(1))
        var m = try XCTUnwrap(newer.manifest); m.formatVersion = 9
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(m).write(to: newer.directory.appendingPathComponent("manifest.json"))
        let reread = try XCTUnwrap(h.backups.list().first { $0.id == newer.id })
        XCTAssertThrowsError(try h.backups.verify(reread)) { XCTAssertEqual($0 as? BackupError, .unsupportedFormat(9)) }
    }

    func testLegacyBackupFromOlderReleaseIsReadable() throws {
        // Older releases copied the store and its WAL files into Backups/schema-vN.
        let src = try XCTUnwrap(Bundle.module.url(forResource: "Wren", withExtension: "store", subdirectory: "Fixtures/v2"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wren-legacy-\(UUID())")
        let legacy = dir.appendingPathComponent("Backups/schema-v2")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: legacy.appendingPathComponent("Wren.store"))
        let mgr = BackupManager(dataDirectory: dir)
        let e = try XCTUnwrap(mgr.list().first)
        XCTAssertTrue(e.isLegacy)
        XCTAssertEqual(try mgr.preview(e).counts["items"], 4)
    }

    func testRetentionKeepsNewestPerReason() throws {
        let h = try Harness(url: tempStoreURL(), now: now, calendar: cal)
        _ = try h.add("x")
        for i in 0..<9 { try h.backups.createBackup(reason: .automatic, appVersion: "t", now: now.addingTimeInterval(Double(i) * 86400)) }
        try h.backups.createBackup(reason: .manual, appVersion: "t", now: now)
        XCTAssertEqual(h.backups.list().filter { $0.manifest?.reason == .automatic }.count, 7)
        XCTAssertEqual(h.backups.list().filter { $0.manifest?.reason == .manual }.count, 1, "manual backups aren't pruned by automatic ones")
    }

    func testDeleteRefusesPathsOutsideBackups() throws {
        let h = try Harness(url: tempStoreURL(), now: now, calendar: cal)
        let outside = BackupEntry(directory: URL(fileURLWithPath: NSHomeDirectory()), manifest: nil, createdAt: now)
        XCTAssertThrowsError(try h.backups.delete(outside)) { XCTAssertEqual($0 as? BackupError, .outsideBackupFolder) }
        let sneaky = BackupEntry(directory: h.backups.backupsDirectory.appendingPathComponent("../.."), manifest: nil, createdAt: now)
        XCTAssertThrowsError(try h.backups.delete(sneaky))
    }

    /// Full restore: confirmation required, safety backup, staged, applied at next open.
    func testRestoreThroughBrokerAndNextLaunch() async throws {
        let url = tempStoreURL()
        let mgr = BackupManager(dataDirectory: url.deletingLastPathComponent())
        do {
            let h = try Harness(url: url, now: now, calendar: cal)
            _ = try h.add("Before backup")
            let b = try h.backups.createBackup(reason: .manual, appVersion: "t", now: now)
            _ = try h.add("Added after backup")
            let req = ActionRequest(action: BuiltInAction.restoreBackup, target: b.targetRef, origin: .user(.settings), createdAt: now)
            let first = await h.broker.submit(req)
            XCTAssertEqual(first.status, .awaitingConfirmation, "replacing data always asks")
            XCTAssertFalse(mgr.hasPendingRestore)
            let ok = await h.broker.submit(req, confirmation: h.broker.confirm(req))
            XCTAssertEqual(ok.status, .succeeded)
            XCTAssertTrue(mgr.hasPendingRestore)
            XCTAssertEqual(mgr.list().filter { $0.manifest?.reason == .preRestore }.count, 1, "safety backup of current data first")
            XCTAssertEqual(try h.store.all().count, 2, "live data untouched until restart")
        }
        let (store, outcome) = try WrenStore.open(manager: mgr, appVersion: "t")
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(try store.all().map(\.title), ["Before backup"])
        XCTAssertFalse(mgr.hasPendingRestore)
    }

    func testFailedRestoreKeepsCurrentData() throws {
        let url = tempStoreURL()
        let mgr = BackupManager(dataDirectory: url.deletingLastPathComponent())
        do {
            let s = try WrenStore(url: url)
            _ = try s.capture("Precious", source: .manual)
        }
        // A corrupt file sneaks into the staging area.
        let pending = url.deletingLastPathComponent().appendingPathComponent("Restore/pending")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: pending.appendingPathComponent("Wren.store"))
        let (store, outcome) = try WrenStore.open(manager: mgr, appVersion: "t")
        XCTAssertEqual(outcome, .none, "integrity check refused it before anything moved")
        XCTAssertEqual(try store.all().map(\.title), ["Precious"])
    }

    func testRollbackPutsPreviousStoreBack() throws {
        let url = tempStoreURL()
        let mgr = BackupManager(dataDirectory: url.deletingLastPathComponent())
        do { let s = try WrenStore(url: url); _ = try s.capture("Current", source: .manual) }
        let b = try mgr.createBackup(reason: .manual, appVersion: "t")
        try mgr.stageRestore(verifiedStore: try mgr.verify(b))
        let replaced = try XCTUnwrap(try mgr.applyPendingRestore())
        try mgr.rollbackRestore(replaced: replaced)
        let reopened = try WrenStore(url: url)
        XCTAssertEqual(try reopened.all().map(\.title), ["Current"])
    }
}

@MainActor
final class PauseTests: XCTestCase {
    let cal = calendar("Asia/Kolkata")

    final class PauseBox { var value: NotificationPause? }

    func harness(_ url: URL, at now: Date, box: PauseBox, notifier: FakeNotifier = FakeNotifier()) throws -> Harness {
        let h = try Harness(url: url, now: now, calendar: cal, notifier: notifier)
        h.engine.pause = { box.value }
        h.engine.clearPause = { box.value = nil }
        return h
    }

    func testPausedDeliversNothingAndKeepsSchedulesAcrossRestart() async throws {
        let url = tempStoreURL()
        let defaults = UserDefaults(suiteName: "wren-pause-\(UUID())")!
        let start = at(cal, 2026, 10, 8, 9)
        let box = PauseBox()
        do {
            let h = try harness(url, at: start, box: box)
            let c = try h.add("Stretch", deadline: at(cal, 2026, 10, 8))
            try h.store.scheduleReminder(c, at: at(cal, 2026, 10, 8, 9, 30), now: start)
            box.value = NotificationPause.make(.untilResumed, now: start, calendar: cal)
            defaults.set(try JSONEncoder().encode(box.value), forKey: "pause")
        }
        // Restart: pause read back from persisted settings.
        let restored = PauseBox()
        restored.value = try JSONDecoder().decode(NotificationPause.self, from: defaults.data(forKey: "pause")!)
        let n = FakeNotifier()
        let h = try harness(url, at: at(cal, 2026, 10, 8, 11, 30), box: restored, notifier: n)
        let r = await h.engine.tick()
        XCTAssertTrue(r.paused)
        XCTAssertTrue(n.reminders.isEmpty && n.briefings.isEmpty)
        let c = try XCTUnwrap(try h.store.all().first)
        XCTAssertEqual(c.nextReminderAt, at(cal, 2026, 10, 8, 9, 30), "schedule untouched")
        XCTAssertNil(c.lastReminderAt, "never recorded as sent")
        XCTAssertEqual(c.deadline, at(cal, 2026, 10, 8))
    }

    /// Long pause: many reminders came due. Resume sends one summary, not a burst.
    func testResumeAfterLongPauseSendsOneSummary() async throws {
        let n = FakeNotifier(); let box = PauseBox()
        let start = at(cal, 2026, 10, 8, 9)
        let h = try harness(tempStoreURL(), at: start, box: box, notifier: n)
        var items: [Commitment] = []
        for i in 0..<6 {
            let c = try h.add("Task \(i)")
            try h.store.scheduleReminder(c, at: start.addingTimeInterval(Double(i + 1) * 3600 * 10), now: start)
            items.append(c)
        }
        box.value = NotificationPause.make(.untilResumed, now: start, calendar: cal)
        for d in 0..<3 { h.clock.set(start.addingTimeInterval(Double(d) * 86400 + 3600)); _ = await h.engine.tick() }
        XCTAssertTrue(n.reminders.isEmpty)

        h.clock.set(at(cal, 2026, 10, 11, 8)) // before the day's briefing window
        let r = await h.engine.resume()
        XCTAssertNil(box.value)
        XCTAssertEqual(n.pauseSummaries.count, 1)
        XCTAssertEqual(n.pauseSummaries[0].count, 6)
        XCTAssertTrue(n.reminders.isEmpty, "no burst of individual reminders")
        XCTAssertEqual(r.summarizedAfterPause, 6)
        for c in items {
            XCTAssertNotNil(c.lastReminderAt)
            XCTAssertTrue(c.events.contains { $0.note?.contains("summary after notifications were paused") == true })
        }
        // Nothing repeats afterwards.
        h.clock.advance(60); _ = await h.engine.tick()
        XCTAssertEqual(n.pauseSummaries.count, 1)
        XCTAssertTrue(n.reminders.isEmpty)
    }

    func testTimedPauseExpiresOnItsOwnAndDailyRulesStillApply() async throws {
        let n = FakeNotifier(); let box = PauseBox()
        let start = at(cal, 2026, 10, 8, 10, 30)
        let h = try harness(tempStoreURL(), at: start, box: box, notifier: n)
        _ = try h.add("Due today", deadline: at(cal, 2026, 10, 8))
        box.value = NotificationPause.make(.oneHour, now: start, calendar: cal)
        h.clock.set(at(cal, 2026, 10, 8, 11, 0))
        do { let r1 = await h.engine.tick(); XCTAssertTrue(r1.paused, "briefing time, but paused") }
        XCTAssertTrue(n.briefings.isEmpty)
        h.clock.set(at(cal, 2026, 10, 8, 11, 31))
        let r = await h.engine.tick()
        XCTAssertFalse(r.paused)
        XCTAssertNil(box.value, "expired pause cleared")
        XCTAssertEqual(r.briefing, .sent, "briefing window still open: sent once")
        h.clock.advance(60); _ = await h.engine.tick()
        XCTAssertEqual(n.briefings.count, 1)
    }

    func testEndOfDayPause() {
        let p = NotificationPause.make(.endOfDay, now: at(cal, 2026, 10, 8, 15), calendar: cal)
        XCTAssertEqual(p.until, at(cal, 2026, 10, 9))
        XCTAssertTrue(p.isActive(at: at(cal, 2026, 10, 8, 23, 59)))
        XCTAssertFalse(p.isActive(at: at(cal, 2026, 10, 9)))
    }

    func testSummaryNotRecordedWhenNotificationsUnavailable() async throws {
        let n = FakeNotifier(); n.allowed = false
        let box = PauseBox()
        let start = at(cal, 2026, 10, 8, 9)
        let h = try harness(tempStoreURL(), at: start, box: box, notifier: n)
        let c = try h.add("x")
        try h.store.scheduleReminder(c, at: start.addingTimeInterval(60), now: start)
        box.value = NotificationPause.make(.untilResumed, now: start, calendar: cal)
        h.clock.advance(3600)
        _ = await h.engine.resume()
        XCTAssertNil(c.lastReminderAt, "macOS never received it, so it stays due")
        XCTAssertTrue(ReminderPolicy.isDue(c, now: h.clock.now))
    }
}

@MainActor
final class ResetTests: XCTestCase {
    let cal = calendar("Asia/Kolkata")
    var now: Date { at(cal, 2026, 10, 8, 12) }

    func testEraseNeedsConfirmationThenLeavesACleanWorkingStore() async throws {
        let h = try Harness(url: tempStoreURL(), now: now, calendar: cal)
        _ = try h.add("Real task")
        _ = try h.store.createGoal(title: "Goal", targetDate: nil, now: now)
        try h.policy.setRule(.autoApplyInterpretations, enabled: false)
        try h.policy.setGrant(.deleteItems, granted: true)
        let req = ActionRequest(action: BuiltInAction.eraseAllData, target: BuiltInAction.allDataTarget, origin: .user(.settings), createdAt: now)

        do { let r2 = await h.broker.submit(req); XCTAssertEqual(r2.status, .awaitingConfirmation) }
        XCTAssertEqual(try h.store.all().count, 1, "nothing removed without confirmation")
        let modelReq = ActionRequest(action: BuiltInAction.eraseAllData, target: BuiltInAction.allDataTarget, origin: .model("m"), createdAt: now)
        do { let r3 = await h.broker.submit(modelReq); XCTAssertEqual(r3.status, .awaitingConfirmation) }
        let content = ActionRequest(action: BuiltInAction.eraseAllData, target: BuiltInAction.allDataTarget, origin: .untrustedContent("email"), createdAt: now)
        do { let r4 = await h.broker.submit(content); XCTAssertEqual(r4.status, .denied) }

        let ok = await h.broker.submit(req, confirmation: h.broker.confirm(req))
        XCTAssertEqual(ok.status, .succeeded)
        XCTAssertTrue(try h.store.all().isEmpty)
        XCTAssertTrue(try h.store.goals().isEmpty)
        XCTAssertEqual(try h.policy.load().rules, StandingRuleKind.defaults, "permissions back to defaults")
        let audit = h.audit()
        XCTAssertEqual(Set(audit.map(\.requestID)), [req.id], "only the erase itself (asked, then confirmed) is logged")
        XCTAssertTrue(audit.contains { $0.status == .succeeded && $0.confirmationObtained })
        XCTAssertFalse(audit.first?.targetLabel.contains("Real task") ?? true)

        // Clean store works.
        let c = try h.store.capture("Fresh start tomorrow at 9am", source: .hotkey, now: now)
        do { let r5 = await h.broker.submit(h.request(BuiltInAction.complete, c)); XCTAssertEqual(r5.status, .succeeded) }
    }

    func testEraseRefusesOtherTargets() async throws {
        let h = try Harness(url: tempStoreURL(), now: now, calendar: cal)
        _ = try h.add("x")
        let req = ActionRequest(action: BuiltInAction.eraseAllData, target: TargetRef(kind: "path", id: "/", label: "/"), origin: .user(.settings), createdAt: now)
        let r = await h.broker.submit(req, confirmation: h.broker.confirm(req))
        XCTAssertEqual(r.status, .failed)
        XCTAssertEqual(try h.store.all().count, 1)
    }

    func testInstanceGuard() {
        XCTAssertEqual(InstanceGuard.decide(othersRunning: false, isRelaunch: false, waited: 0), .proceed)
        XCTAssertEqual(InstanceGuard.decide(othersRunning: true, isRelaunch: false, waited: 0), .exit, "a second copy never runs a second scheduler")
        XCTAssertEqual(InstanceGuard.decide(othersRunning: true, isRelaunch: true, waited: 2), .waitForPrevious, "relaunch after restore waits for the old copy")
        XCTAssertEqual(InstanceGuard.decide(othersRunning: true, isRelaunch: true, waited: 11), .exit)
    }
}
