import AppKit
import WrenCore

/// GPT delegations: started from the capture panel (typed or spoken) or the Delegate pane, tracked
/// in the store, announced once when they finish, and reopened from a persistent result view.
@MainActor
extension AppModel {
    func wireDelegations() {
        guard let asks else { return }
        // A request still "running" from a Wren that quit never finished here: say so, offer retry.
        let interrupted = asks.recoverInterrupted()
        if interrupted > 0 { log.notice("marked \(interrupted, privacy: .public) interrupted delegation(s) at launch") }
        asks.onFinished = { [weak self] r in self?.delegationFinished(r) }
    }

    func startDelegation(_ r: AIRequest, channel: UserChannel, reviewed: HandoffDraft? = nil,
                         onDelta: @escaping @MainActor (String) -> Void = { _ in }) -> AskStart {
        guard let asks else { return .notRun(.failed("Wren's database isn't available.", retryable: false)) }
        let s = asks.start(r, channel: channel, reviewed: reviewed, onDelta: onDelta)
        delegationVersion += 1
        if case .started = s { ensureNotificationPermission() }
        return s
    }

    func retryDelegation(_ id: UUID) -> AskStart {
        guard let asks else { return .notRun(.failed("Wren's database isn't available.", retryable: false)) }
        let s = asks.retry(id)
        delegationVersion += 1
        return s
    }

    func cancelDelegation(_ id: UUID) { asks?.cancel(id) }

    /// Running and recent finished delegations for the compact overview list.
    var recentDelegations: [DelegationRecord] {
        let _ = delegationVersion
        return Array(delegations.filter { $0.destination == .chatgptPlan || $0.destination == .chatgptHandoff }.prefix(5))
    }

    var unseenDelegations: Int {
        let _ = delegationVersion
        return delegations.filter { $0.status.isFinal && $0.seenAt == nil && $0.notifiedAt != nil }.count
    }

    /// Opens the saved request and its real result in the main window.
    func openDelegation(_ id: UUID) {
        if let r = asks?.record(id), r.seenAt == nil, r.status.isFinal { r.seenAt = clock.now; try? store?.context.save() }
        delegationVersion += 1
        route = .delegation(id)
        openMainWindow()
    }

    /// Exactly one announcement per finished request: the in-app entry always, and a macOS
    /// notification unless the user is already looking at that result.
    func delegationFinished(_ r: DelegationRecord) {
        delegationVersion += 1
        connectorVersion += 1
        guard r.notifiedAt == nil else { return }
        r.notifiedAt = clock.now
        try? store?.context.save()
        if isShowingDelegation(r.id) { return }
        Task { _ = await notifications.deliverDelegation(r) }
    }
}
