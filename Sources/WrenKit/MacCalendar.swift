import EventKit
import WrenCore

/// Calendars already on this Mac (Apple Calendar: iCloud, Google, Exchange… accounts from System
/// Settings › Internet Accounts), read-only through EventKit. No sign-in; macOS asks once.
@MainActor
final class MacCalendarConnector: Connector {
    let descriptor = ConnectorCatalog.descriptor(.macCalendar)
    private let store = EKEventStore()
    var enabled: Bool
    var onEnabledChange: (Bool) -> Void = { _ in }
    private(set) var state: ConnectorState = .available
    var onPermissions: (Bool) -> Void = { _ in }

    init(enabled: Bool) {
        self.enabled = enabled
        state = baseState
    }

    var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    var hasAccess: Bool { status == .fullAccess }

    /// State from the permission alone; `refresh` confirms with a real read.
    var baseState: ConnectorState {
        guard enabled else { return .available }
        switch status {
        case .fullAccess: return .temporarilyUnavailable("Not checked yet.")
        case .notDetermined: return .available
        case .writeOnly: return .missingPermissions("Wren has add-only access to Calendars. Allow full access in System Settings › Privacy & Security › Calendars so it can read events.")
        default: return .missingPermissions("Calendars access is off for Wren. Turn it on in System Settings › Privacy & Security › Calendars.")
        }
    }

    /// Turns it on; macOS asks for access the first time.
    func connect() async {
        enabled = true; onEnabledChange(true)
        if status == .notDetermined { _ = try? await store.requestFullAccessToEvents() }
        await refresh()
    }

    func refresh() async {
        guard enabled, hasAccess else { state = baseState; onPermissions(false); return }
        store.reset()
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else {
            state = .missingPermissions("No calendars on this Mac yet. Add your Google, iCloud or Outlook account in System Settings › Internet Accounts, then Check again.")
            onPermissions(false); return
        }
        // A real read: today's events.
        _ = events(from: Calendar.current.startOfDay(for: .now), to: .now.addingTimeInterval(86_400))
        let names = Set(calendars.compactMap { $0.source?.title }).sorted()
        state = .connected(account: "\(calendars.count) calendar\(calendars.count == 1 ? "" : "s")" + (names.isEmpty ? "" : " · " + names.joined(separator: ", ")))
        onPermissions(true)
    }

    func disconnect() async {
        enabled = false; onEnabledChange(false)
        onPermissions(false)
        state = .available
    }

    func events(from: Date, to: Date, search: String? = nil) -> [CalendarEvent] {
        guard enabled, hasAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate)
            .filter { e in search.map { q in (e.title ?? "").localizedCaseInsensitiveContains(q) } ?? true }
            .sorted { $0.startDate < $1.startDate }
            .map { e in
                CalendarEvent(id: e.eventIdentifier ?? e.calendarItemIdentifier, title: e.title ?? "Untitled", start: e.startDate, end: e.endDate,
                              isAllDay: e.isAllDay, location: e.location, isRecurring: e.hasRecurrenceRules, link: e.url)
            }
    }
}
