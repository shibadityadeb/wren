import Foundation

/// Persists last sync and last error per connector.
public protocol ConnectorStatusStoring: AnyObject, Sendable {
    func status(_ id: ConnectorID) -> ConnectorStatus
    func setStatus(_ s: ConnectorStatus, for id: ConnectorID)
}

public final class DefaultsStatusStore: ConnectorStatusStoring, @unchecked Sendable {
    let d: UserDefaults
    public init(_ d: UserDefaults = .standard) { self.d = d }
    public func status(_ id: ConnectorID) -> ConnectorStatus {
        d.data(forKey: "connector.\(id.rawValue)").flatMap { try? JSONDecoder().decode(ConnectorStatus.self, from: $0) } ?? ConnectorStatus()
    }
    public func setStatus(_ s: ConnectorStatus, for id: ConnectorID) { d.set(try? JSONEncoder().encode(s), forKey: "connector.\(id.rawValue)") }
    public func clear(_ id: ConnectorID) { d.removeObject(forKey: "connector.\(id.rawValue)") }
}

public final class MemoryStatusStore: ConnectorStatusStoring, @unchecked Sendable {
    var items: [ConnectorID: ConnectorStatus] = [:]
    public init() {}
    public func status(_ id: ConnectorID) -> ConnectorStatus { items[id] ?? ConnectorStatus() }
    public func setStatus(_ s: ConnectorStatus, for id: ConnectorID) { items[id] = s }
}

/// Shared plumbing: state, status bookkeeping, permission grant/revoke hooks.
@MainActor
public class BaseConnector {
    public let descriptor: ConnectorDescriptor
    public internal(set) var state: ConnectorState
    let statusStore: ConnectorStatusStoring
    let now: @Sendable () -> Date
    /// Grant or revoke this connector's Wren permissions (set by the app to the policy store).
    public var onPermissions: (Bool) -> Void = { _ in }

    init(_ id: ConnectorID, statusStore: ConnectorStatusStoring, now: @escaping @Sendable () -> Date) {
        descriptor = ConnectorCatalog.descriptor(id); self.statusStore = statusStore; self.now = now; state = .available
    }
    public var status: ConnectorStatus { statusStore.status(descriptor.id) }

    func succeeded(account: String?) {
        var s = status; s.lastSuccessfulSync = now(); s.lastError = nil; s.account = account
        statusStore.setStatus(s, for: descriptor.id)
        onPermissions(true)
    }
    func failed(_ e: Error) -> String {
        let m = (e as? LocalizedError)?.errorDescription ?? "\(e)"
        var s = status; s.lastError = m; s.lastErrorAt = now()
        statusStore.setStatus(s, for: descriptor.id)
        return m
    }
    /// Maps an error to an honest state.
    func stateFor(_ e: Error) -> ConnectorState {
        let m = failed(e)
        switch e {
        case ConnectorError.unauthorized, OAuthError.invalidClient: onPermissions(false); return .permissionDenied(m)
        case ConnectorError.forbidden: return .permissionDenied(m)
        case OAuthError.denied: return .permissionDenied(m)
        default: return .temporarilyUnavailable(m)
        }
    }
    func cleared() {
        statusStore.setStatus(ConnectorStatus(), for: descriptor.id)
        onPermissions(false)
        state = .disconnected
    }
}

/// Gmail or Google Calendar: Google OAuth (PKCE + loopback), read-only scope.
@MainActor
public final class GoogleConnector: BaseConnector, Connector {
    let store: CredentialStore
    let session: URLSession
    public let google: GoogleSession
    public var emailCache: EmailCache?
    var scope: String { descriptor.id == .gmail ? ConnectorCatalog.gmailScope : ConnectorCatalog.calendarScope }

    public init(_ id: ConnectorID, store: CredentialStore, statusStore: ConnectorStatusStoring, session: URLSession = .shared,
                now: @escaping @Sendable () -> Date = { Date() }) {
        precondition(id == .gmail || id == .googleCalendar)
        self.store = store; self.session = session
        google = GoogleSession(connector: id, store: store)
        super.init(id, statusStore: statusStore, now: now)
        state = initialState
    }

    var config: GoogleOAuthConfig? { GoogleSession.config(store) }
    var oauth: GoogleOAuth? { config.map { GoogleOAuth(config: $0, session: session, now: now) } }

    var initialState: ConnectorState {
        guard config != nil else { return .setupRequired("Add your Google OAuth client ID (Connectors › Google setup).") }
        return google.tokens == nil ? .available : .temporarilyUnavailable("Not checked yet.")
    }

    public func token() async throws -> String {
        guard let oauth else { throw ConnectorError.notConfigured("Google isn't set up.") }
        return try await google.accessToken(oauth: oauth)
    }

    public var gmail: GmailClient { GmailClient(session: session) { [weak self] in try await self?.token() ?? { throw ConnectorError.cancelled }() } }
    public var calendar: GoogleCalendarClient { GoogleCalendarClient(session: session) { [weak self] in try await self?.token() ?? { throw ConnectorError.cancelled }() } }

    func fetchAccount() async throws -> String {
        descriptor.id == .gmail ? try await gmail.profileEmail() : try await calendar.accountID()
    }

    /// Full sign-in: opens Google's consent page in the browser and waits for the loopback redirect.
    public func connect(open: (URL) -> Void) async {
        guard let oauth else { state = initialState; return }
        state = .connecting
        let receiver = LoopbackReceiver()
        do {
            try await receiver.start()
            let pkce = PKCE.make()
            let stateToken = UUID().uuidString
            open(oauth.authorizationURL(scopes: [scope], redirect: receiver.redirectURL, state: stateToken, pkce: pkce))
            let callback = try await receiver.waitForRedirect()
            let code = try GoogleOAuth.parseCallback(callback, expectedState: stateToken)
            var tokens = try await oauth.exchange(code: code, pkce: pkce, redirect: receiver.redirectURL, requiredScope: scope)
            try google.save(tokens)
            let account = try await fetchAccount()
            tokens.account = account
            try google.save(tokens)
            succeeded(account: account)
            state = .connected(account: account)
        } catch {
            receiver.stop()
            if google.tokens == nil || (error as? OAuthError) != nil { try? google.clear() }
            state = stateFor(error)
        }
    }

    public func refresh() async {
        guard config != nil else { state = initialState; return }
        guard google.tokens != nil else { state = .available; return }
        do {
            let account = try await fetchAccount()
            succeeded(account: account)
            state = .connected(account: account)
        } catch { state = stateFor(error) }
    }

    public func disconnect() async {
        if let t = google.tokens, let oauth { await oauth.revoke(t.refreshToken ?? t.accessToken) }
        try? google.clear()
        emailCache?.clear()
        cleared()
    }
}

/// Notion with an internal integration token. Only pages shared with the integration are visible.
@MainActor
public final class NotionConnector: BaseConnector, Connector {
    let store: CredentialStore
    let session: URLSession
    nonisolated static let key = "notion.token"

    public init(store: CredentialStore, statusStore: ConnectorStatusStoring, session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.session = session
        super.init(.notion, statusStore: statusStore, now: now)
        state = store.readString(Self.key) == nil ? .available : .temporarilyUnavailable("Not checked yet.")
    }

    public var client: NotionClient {
        let s = store
        return NotionClient(session: session) { guard let t = s.readString(NotionConnector.key) else { throw ConnectorError.notConfigured("Notion isn't connected.") }; return t }
    }

    /// Saves the token only after Notion accepted it.
    public func connect(token raw: String) async {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("ntn_") || token.hasPrefix("secret_") else {
            state = .setupRequired("That doesn't look like a Notion integration token (it starts with ntn_ or secret_)."); return
        }
        state = .connecting
        let probe = NotionClient(session: session) { token }
        do {
            let who = try await probe.identity()
            try store.writeString(Self.key, token)
            succeeded(account: who)
            state = .connected(account: who)
        } catch { state = stateFor(error) }
    }

    public func refresh() async {
        guard store.readString(Self.key) != nil else { state = .available; return }
        do { let who = try await client.identity(); succeeded(account: who); state = .connected(account: who) } catch { state = stateFor(error) }
    }

    public func disconnect() async { try? store.delete(Self.key); cleared() }
}

/// Optional OpenAI API key connector.
@MainActor
public final class OpenAIConnector: BaseConnector, Connector {
    let store: CredentialStore
    let session: URLSession
    nonisolated static let key = "openai.apiKey"
    public var selectedModel: String? { didSet { modelChanged?(selectedModel) } }
    public var modelChanged: ((String?) -> Void)?
    public private(set) var models: [String] = []

    public init(store: CredentialStore, statusStore: ConnectorStatusStoring, session: URLSession = .shared, selectedModel: String?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.session = session; self.selectedModel = selectedModel
        super.init(.openaiAPI, statusStore: statusStore, now: now)
        state = store.readString(Self.key) == nil ? .available : .temporarilyUnavailable("Not checked yet.")
    }

    public var client: OpenAIClient {
        let s = store
        return OpenAIClient(session: session) { guard let k = s.readString(OpenAIConnector.key) else { throw ConnectorError.notConfigured("No API key.") }; return k }
    }

    public func connect(key raw: String) async {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count > 20 else { state = .setupRequired("That doesn't look like an OpenAI API key (sk-…)."); return }
        state = .connecting
        do {
            models = try await OpenAIClient(session: session) { key }.models()
            try store.writeString(Self.key, key)
            settle()
        } catch { state = stateFor(error) }
    }

    func settle() {
        succeeded(account: selectedModel)
        if let m = selectedModel, models.isEmpty || models.contains(m) { state = .connected(account: "Model: \(m)") }
        else { state = .partiallyConnected("Key accepted. Choose a model to use.") }
    }

    public func refresh() async {
        guard store.readString(Self.key) != nil else { state = .available; return }
        do { models = try await client.models(); settle() } catch { state = stateFor(error) }
    }

    public func disconnect() async { try? store.delete(Self.key); models = []; selectedModel = nil; cleared() }
}

/// ChatGPT handoff: no credentials. "Ready" means a destination exists; Wren can't see your sign-in.
@MainActor
public final class ChatGPTConnector: BaseConnector, Connector {
    public var enabled: Bool { didSet { enabledChanged?(enabled); evaluate() } }
    public var enabledChanged: ((Bool) -> Void)?
    /// Name of the app or browser that opens chatgpt.com (resolved by the app via NSWorkspace).
    public var destination: () -> String?

    public init(enabled: Bool, statusStore: ConnectorStatusStoring, destination: @escaping () -> String?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.enabled = enabled; self.destination = destination
        super.init(.chatgpt, statusStore: statusStore, now: now)
        evaluate()
    }

    func evaluate() {
        guard enabled else { state = .available; return }
        guard let d = destination() else { state = .setupRequired("No browser or ChatGPT app was found to open chatgpt.com."); return }
        onPermissions(true)
        state = .partiallyConnected("Ready for handoff via \(d). Wren can't check your ChatGPT sign-in, and you send each message yourself.")
    }

    public func refresh() async { evaluate() }
    public func disconnect() async { enabled = false; cleared(); state = .available }
}
