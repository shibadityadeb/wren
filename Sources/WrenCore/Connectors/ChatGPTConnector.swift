import Foundation

/// The account states the ChatGPT connector can be in, in the user's words.
public enum ChatGPTAccountState: Equatable, Sendable {
    case notConnected
    case connecting
    /// Signed in and verified, but Wren may not use the plan (permission not granted, or the plan
    /// isn't eligible). The reason says which.
    case accountOnly(String)
    case planEnabled
    case reauthorizationRequired(String)
    case usageLimitReached
    case temporarilyUnavailable(String)

    public var title: String {
        switch self {
        case .notConnected: "Not connected"
        case .connecting: "Waiting for ChatGPT sign-in"
        case .accountOnly: "Account connected, plan usage not authorized"
        case .planEnabled: "Connected and ChatGPT plan usage enabled"
        case .reauthorizationRequired: "Reauthorization required"
        case .usageLimitReached: "Usage limit reached"
        case .temporarilyUnavailable: "Temporarily unavailable"
        }
    }

    public var reason: String? {
        switch self {
        case let .accountOnly(r), let .reauthorizationRequired(r), let .temporarilyUnavailable(r): r
        case .usageLimitReached: ChatGPTError.usageLimitReached.errorDescription
        default: nil
        }
    }

    public var canSend: Bool { self == .planEnabled }

    public func connectorState(email: String?) -> ConnectorState {
        switch self {
        case .notConnected: .available
        case .connecting: .connecting
        case let .accountOnly(r): .partiallyConnected("\(title). \(r)")
        case .planEnabled: .connected(account: [email, "Using ChatGPT plan"].compactMap { $0 }.joined(separator: " · "))
        case let .reauthorizationRequired(r): .permissionDenied("\(title). \(r)")
        case .usageLimitReached: .temporarilyUnavailable("\(title). \(reason ?? "")")
        case let .temporarilyUnavailable(r): .temporarilyUnavailable("\(title). \(r)")
        }
    }

    public static func from(_ e: ChatGPTError) -> ChatGPTAccountState {
        switch e {
        case .usageLimitReached: .usageLimitReached
        case .planNotAuthorized, .notEligible: .accountOnly(e.errorDescription ?? "")
        case .reauthorizationRequired, .identityNotVerified, .accountMismatch, .clientRejected, .signInCancelled, .registrationIncomplete:
            .reauthorizationRequired(e.errorDescription ?? "")
        default: .temporarilyUnavailable(e.errorDescription ?? "")
        }
    }
}

/// ChatGPT: Sign in with ChatGPT (primary) plus the optional copy-and-open handoff (fallback).
/// "Connected" is only reported after OpenAI listed models for this connection, a real authorized call.
@MainActor
public final class ChatGPTConnector: BaseConnector, Connector {
    public nonisolated static let connectionKey = "chatgpt.connection"
    public nonisolated static let registrationKey = "chatgpt.registration"
    public nonisolated static let hostKey = "chatgpt.hostID"

    let store: CredentialStore
    let session: URLSession
    public let auth: ChatGPTAuth
    public private(set) var account: ChatGPTAccountState = .notConnected { didSet { state = account.connectorState(email: connection?.email) } }
    public private(set) var models: [ChatGPTModel] = []
    public var selectedModel: String? { didSet { modelChanged?(selectedModel) } }
    public var modelChanged: ((String?) -> Void)?
    /// The copy-and-open fallback. Independent of sign-in.
    public var handoffEnabled: Bool { didSet { handoffChanged?(handoffEnabled); grant(.chatgptHandoff, handoffAvailable) } }
    public var handoffChanged: ((Bool) -> Void)?
    /// Name of the app or browser that opens chatgpt.com (resolved by the app via NSWorkspace).
    public var destination: () -> String?
    /// Grants or revokes one Wren permission (set by the app to the policy store).
    public var grant: (Permission, Bool) -> Void = { _, _ in }
    public private(set) var disconnectNote: String?
    public private(set) var usageLimitSeenAt: Date?
    private var refreshing: Task<ChatGPTConnection, Error>?

    public init(store: CredentialStore, statusStore: ConnectorStatusStoring, session: URLSession = .shared, handoffEnabled: Bool,
                selectedModel: String?, destination: @escaping () -> String?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.session = session; self.handoffEnabled = handoffEnabled; self.selectedModel = selectedModel
        self.destination = destination
        auth = ChatGPTAuth(session: session, now: now)
        super.init(.chatgpt, statusStore: statusStore, now: now)
        account = connection == nil ? .notConnected
            : (connection?.accessToken == nil ? .reauthorizationRequired("Reconnect to keep using your plan.") : .temporarilyUnavailable("Not checked yet."))
        state = account.connectorState(email: connection?.email)
    }

    public var connection: ChatGPTConnection? { store.readJSON(Self.connectionKey, as: ChatGPTConnection.self) }
    public var email: String? { connection?.email }
    public var planType: String? { connection?.planType }
    public var handoffAvailable: Bool { handoffEnabled && destination() != nil }
    public var isUsingPlan: Bool { account.canSend }

    /// A stable per-Mac identifier OpenAI uses to group this copy of Wren's sign-ins.
    var hostID: String {
        if let h = store.readString(Self.hostKey) { return h }
        let h = "urn:uuid:\(UUID().uuidString.lowercased())"
        try? store.writeString(Self.hostKey, h)
        return h
    }

    static func random() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return PKCE.base64url(Data(b))
    }

    public var client: ChatGPTPlanClient {
        ChatGPTPlanClient(session: session) { [weak self] force in
            guard let self else { throw ChatGPTError.temporarilyUnavailable("Cancelled.") }
            return try await self.accessToken(force: force)
        }
    }

    /// Opens OpenAI's sign-in page in the browser and finishes when it redirects back to Wren.
    /// `reconsent` asks OpenAI to show the permission screen again (to allow plan usage).
    public func connect(reconsent: Bool = false, open: (URL) -> Void) async {
        let previous = connection
        account = .connecting
        disconnectNote = nil
        let stateToken = Self.random(), nonce = Self.random(), pkce = PKCE.make()
        let receiver = LoopbackReceiver(path: SIWC.callbackPath, expectedState: stateToken)
        do {
            let d = try await auth.discovery()
            try await receiver.start()
            let registered = store.readString(Self.registrationKey)
            open(ChatGPTAuth.authorizationURL(d, registeredClientID: registered, hostID: hostID, redirect: receiver.redirectURL,
                                              state: stateToken, nonce: nonce, pkce: pkce, loginHint: previous?.email, reconsent: reconsent))
            let callback = try await receiver.waitForRedirect()
            let (code, clientID) = try ChatGPTAuth.parseCallback(callback, expectedState: stateToken, registeredClientID: registered)
            // Keep the issued registration even if the one-time code later fails, so a retry
            // doesn't register Wren a second time.
            try store.writeString(Self.registrationKey, clientID)
            let c = try await auth.exchange(code: code, clientID: clientID, pkce: pkce, redirect: receiver.redirectURL,
                                            nonce: nonce, expectedSubject: previous?.subject)
            try store.writeJSON(Self.connectionKey, c)
            await verify()
        } catch {
            receiver.stop()
            fail(error, keepPrevious: previous)
        }
    }

    /// Checks the connection with a real call (model listing) and settles the state.
    func verify() async {
        guard let c = connection else { account = .notConnected; return }
        guard c.planUsageAuthorized else {
            grant(.externalAI, false)
            account = .accountOnly(ChatGPTError.planNotAuthorized.errorDescription ?? "")
            succeeded(account: c.email)
            onPermissions(false)
            return
        }
        do {
            models = try await client.models()
            if selectedModel == nil || !models.contains(where: { $0.slug == selectedModel }) { selectedModel = models.first?.slug }
            succeeded(account: c.email)
            if account != .usageLimitReached || usageLimitSeenAt.map({ now().timeIntervalSince($0) > 15 * 60 }) ?? true {
                usageLimitSeenAt = nil
                account = .planEnabled
            }
            grant(.externalAI, true)
        } catch { fail(error, keepPrevious: c) }
    }

    func fail(_ error: Error, keepPrevious previous: ChatGPTConnection?) {
        let e: ChatGPTError = (error as? ChatGPTError) ?? {
            switch error {
            case OAuthError.timedOut, OAuthError.stateMismatch: return .signInCancelled
            default: return ChatGPTError.fromTransport(error)
            }
        }()
        _ = failed(e)
        if e == .clientRejected { try? store.delete(Self.registrationKey) }
        guard let c = connection ?? previous else { account = .notConnected; grant(.externalAI, false); return }
        if c != connection { try? store.writeJSON(Self.connectionKey, c) }
        let next = ChatGPTAccountState.from(e)
        if case .reauthorizationRequired = next, e != .signInCancelled, e != .registrationIncomplete {
            // The tokens are no longer good; keep only who the account was, for the reconnect hint.
            var stripped = c; stripped.accessToken = nil; stripped.refreshToken = nil; stripped.expiresAt = nil
            try? store.writeJSON(Self.connectionKey, stripped)
        }
        if e == .signInCancelled || e == .registrationIncomplete, c.accessToken != nil {
            // An abandoned reconnect doesn't break a working connection.
            account = .temporarilyUnavailable("Not checked yet.")
            return
        }
        if e == .usageLimitReached { usageLimitSeenAt = now() }
        if !next.canSend { grant(.externalAI, next == .usageLimitReached || { if case .temporarilyUnavailable = next { true } else { false } }()) }
        account = next
    }

    /// A valid access token, refreshing when it's about to expire or when `force` is set (after a 401).
    public func accessToken(force: Bool) async throws -> String {
        guard let c = connection else { throw ChatGPTError.reauthorizationRequired("ChatGPT isn't connected.") }
        guard let token = c.accessToken else { throw ChatGPTError.reauthorizationRequired("Reconnect to keep using your plan.") }
        let expiring = c.expiresAt.map { $0.timeIntervalSince(now()) < 60 } ?? false
        guard force || expiring else { return token }
        if !force, let earliest = c.earliestRefreshAt, earliest > now(), let exp = c.expiresAt, exp > now() { return token }
        let task = refreshing ?? Task { [auth, store] in
            try await auth.refresh(c) { try store.writeJSON(ChatGPTConnector.connectionKey, $0) }
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            try store.writeJSON(Self.connectionKey, fresh)
            guard let t = fresh.accessToken else { throw ChatGPTError.reauthorizationRequired("Reconnect to keep using your plan.") }
            return t
        } catch {
            fail(error, keepPrevious: nil)
            throw (error as? ChatGPTError) ?? ChatGPTError.fromTransport(error)
        }
    }

    /// One request on the user's plan. Only for requests the user started and confirmed; Wren's
    /// background tasks are refused here as well as by the permission system.
    public func respond(model: String, input: String, instructions: String? = nil, origin: ActionOrigin,
                        onDelta: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ChatGPTReply {
        guard origin.isDirectUser else { throw ChatGPTError.backgroundUseNotAllowed }
        guard let c = connection, c.planUsageAuthorized else { throw ChatGPTError.planNotAuthorized }
        do {
            let r = try await client.respond(model: model, input: input, instructions: instructions, onDelta: onDelta)
            usageLimitSeenAt = nil
            succeeded(account: c.email)
            if account != .planEnabled { account = .planEnabled; grant(.externalAI, true) }
            return r
        } catch let e as ChatGPTError {
            switch e {
            case .incomplete, .interrupted, .unsupportedRequest, .invalidResponse: break
            default: fail(e, keepPrevious: nil)
            }
            throw e
        }
    }

    public func refresh() async {
        guard connection != nil else { account = .notConnected; return }
        guard connection?.accessToken != nil else { account = .reauthorizationRequired("Reconnect to keep using your plan."); return }
        await verify()
    }

    /// Revokes with OpenAI, deletes the tokens and turns off the handoff fallback. The registration and
    /// host identifier stay, so reconnecting doesn't register Wren again.
    public func disconnect() async {
        disconnectNote = nil
        if let c = connection, c.accessToken != nil || c.refreshToken != nil {
            do { try await auth.revoke(c) } catch {
                disconnectNote = "Wren deleted its ChatGPT tokens, but OpenAI didn't confirm the sign-out. To be sure, remove Wren under ChatGPT Settings."
            }
        }
        try? store.delete(Self.connectionKey)
        models = []
        refreshing?.cancel(); refreshing = nil
        usageLimitSeenAt = nil
        handoffEnabled = false
        grant(.externalAI, false)
        cleared()
        account = .notConnected
    }
}
