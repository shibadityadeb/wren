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
        case ConnectorError.unauthorized: onPermissions(false); return .reauthorizationRequired(m)
        // The provider rejected this build's own registration: the maintainers have to fix it.
        case OAuthError.invalidClient: onPermissions(false); return .notAvailableInBuild(m)
        case ConnectorError.forbidden: return .missingPermissions(m)
        case OAuthError.denied, OAuthError.scopeNotGranted: onPermissions(false); return .missingPermissions(m)
        default: return .temporarilyUnavailable(m)
        }
    }
    func cleared() {
        statusStore.setStatus(ConnectorStatus(), for: descriptor.id)
        onPermissions(false)
        state = .disconnected
    }
}

/// Gmail or Google Calendar: Google sign-in (PKCE + loopback) with Wren's maintainer-registered client,
/// read-only scope. Each connector verifies that Google granted its scope and is enabled only then.
@MainActor
public final class GoogleConnector: BaseConnector, Connector {
    let store: CredentialStore
    let session: URLSession
    let config: GoogleOAuthConfig?
    public let google: GoogleSession
    public var emailCache: EmailCache?
    public var scope: String { descriptor.id == .gmail ? ConnectorCatalog.gmailScope : ConnectorCatalog.calendarScope }

    public init(_ id: ConnectorID, config: GoogleOAuthConfig?, store: CredentialStore, statusStore: ConnectorStatusStoring,
                session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        precondition(id == .gmail || id == .googleCalendar)
        self.store = store; self.session = session; self.config = config
        google = GoogleSession(connector: id, store: store)
        super.init(id, statusStore: statusStore, now: now)
        state = initialState
    }

    public var isConfigured: Bool { config != nil }
    var oauth: GoogleOAuth? { config.map { GoogleOAuth(config: $0, session: session, now: now) } }

    var initialState: ConnectorState {
        guard config != nil else { return .notAvailableInBuild(ProviderConfig.notInBuild("Google", feature: descriptor.name)) }
        return google.tokens == nil ? .available : .temporarilyUnavailable("Not checked yet.")
    }

    public func token() async throws -> String {
        guard let oauth else { throw ConnectorError.notConfigured(ProviderConfig.notInBuild("Google", feature: descriptor.name)) }
        return try await google.accessToken(oauth: oauth)
    }

    public var gmail: GmailClient { GmailClient(session: session) { [weak self] in try await self?.token() ?? { throw ConnectorError.cancelled }() } }
    public var calendar: GoogleCalendarClient { GoogleCalendarClient(session: session) { [weak self] in try await self?.token() ?? { throw ConnectorError.cancelled }() } }

    func fetchAccount() async throws -> String {
        descriptor.id == .gmail ? try await gmail.profileEmail() : try await calendar.accountID()
    }

    func checkScope() throws {
        guard let t = google.tokens else { return }
        if !t.scope.split(separator: " ").map(String.init).contains(scope) { throw OAuthError.scopeNotGranted(scope) }
    }

    /// Full sign-in: opens Google's consent page in the browser and waits for the loopback redirect.
    /// Reports connected only after a real read with the new token succeeded.
    public func connect(open: (URL) -> Void) async {
        guard let oauth else { state = initialState; return }
        state = .connecting
        let stateToken = UUID().uuidString
        let receiver = LoopbackReceiver(path: "/", expectedState: stateToken)
        do {
            try await receiver.start()
            let pkce = PKCE.make()
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
            try checkScope()
            let account = try await fetchAccount()
            try checkScope()   // a refresh may have narrowed the grant
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

/// Notion through Wren's public integration (OAuth). The user picks pages on Notion's consent screen.
@MainActor
public final class NotionConnector: BaseConnector, Connector {
    let store: CredentialStore
    let session: URLSession
    let config: NotionOAuthConfig?
    public let notion: NotionSession
    /// Set when the last disconnect couldn't confirm revocation with Notion.
    public private(set) var disconnectNote: String?

    public init(config: NotionOAuthConfig?, store: CredentialStore, statusStore: ConnectorStatusStoring, session: URLSession = .shared,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.session = session; self.config = config
        notion = NotionSession(store: store)
        super.init(.notion, statusStore: statusStore, now: now)
        state = initialState
    }

    public var isConfigured: Bool { config != nil }
    var oauth: NotionOAuth? { config.map { NotionOAuth(config: $0, session: session, now: now) } }

    var initialState: ConnectorState {
        guard config != nil else { return .notAvailableInBuild(ProviderConfig.notInBuild("Notion", feature: "Notion")) }
        return notion.tokens == nil ? .available : .temporarilyUnavailable("Not checked yet.")
    }

    public var workspace: String? { notion.tokens?.workspaceName }

    public var client: NotionClient {
        let s = notion, o = oauth
        return NotionClient(session: session) { try await s.accessToken(oauth: o) }
    }

    /// Opens Notion's consent page; Notion redirects to Wren's relay, which bounces to 127.0.0.1.
    public func connect(open: (URL) -> Void) async {
        guard let oauth else { state = initialState; return }
        state = .connecting
        disconnectNote = nil
        let receiver = LoopbackReceiver(path: NotionOAuth.callbackPath)
        do {
            try await receiver.start()
            let stateToken = NotionOAuth.makeState(port: receiver.port)
            receiver.expectedState = stateToken
            open(oauth.authorizationURL(state: stateToken))
            let callback = try await receiver.waitForRedirect()
            let code = try GoogleOAuth.parseCallback(callback, expectedState: stateToken)
            let tokens = try await oauth.exchange(code: code)
            try notion.save(tokens)
            try await verify()
        } catch {
            receiver.stop()
            if (error as? OAuthError) != nil { try? notion.clear() }
            state = stateFor(error)
        }
    }

    /// A real authorized call: who Notion says this connection is.
    func verify() async throws {
        let who = try await client.identity()
        let account = notion.tokens?.workspaceName ?? who
        succeeded(account: account)
        state = .connected(account: account)
    }

    public func refresh() async {
        guard config != nil else { state = initialState; return }
        guard notion.tokens != nil else { state = .available; return }
        do { try await verify() } catch { state = stateFor(error) }
    }

    public func disconnect() async {
        disconnectNote = nil
        if let t = notion.tokens, let oauth {
            do { try await oauth.revoke(t.accessToken) } catch {
                disconnectNote = "Wren removed its copy of the Notion token, but Notion didn't confirm the revocation. You can also remove Wren in Notion › Settings › Connections."
            }
        }
        try? notion.clear()
        cleared()
    }
}
