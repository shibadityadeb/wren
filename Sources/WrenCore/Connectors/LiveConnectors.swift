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
        case OAuthError.invalidClient, OAuthError.clientSecretMissing: onPermissions(false); return .notAvailableInBuild(m)
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

/// One Google sign-in for Gmail and Calendar, through Wren's maintainer-registered desktop client
/// (public client: loopback redirect + PKCE + state, no client secret). The user picks permissions on
/// Google's own screen; Wren keeps one token and turns on only what Google actually granted, and
/// reports "connected" only after a real read with that token.
@MainActor
public final class GoogleAccount {
    public static let gmailScope = ConnectorCatalog.gmailScope
    public static let calendarScope = ConnectorCatalog.calendarScope
    public let config: GoogleOAuthConfig?
    public let session: GoogleSession
    let urlSession: URLSession
    let now: @Sendable () -> Date
    /// How long to wait for the browser to come back.
    public var signInTimeout: TimeInterval = 300
    public private(set) var isConnecting = false
    /// Set when the last disconnect couldn't be confirmed with Google.
    public private(set) var disconnectNote: String?

    public init(config: GoogleOAuthConfig?, store: CredentialStore, session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config; self.urlSession = session; self.now = now
        self.session = GoogleSession(store: store)
        Self.adoptLegacyTokens(store)
    }

    /// Earlier builds kept one token per connector. Keep the first one found as the shared sign-in.
    static func adoptLegacyTokens(_ store: CredentialStore) {
        let legacy = ["google.gmail.tokens", "google.googleCalendar.tokens"]
        if store.readJSON(GoogleSession.accountKey, as: OAuthTokens.self) == nil,
           let t = legacy.lazy.compactMap({ store.readJSON($0, as: OAuthTokens.self) }).first {
            try? store.writeJSON(GoogleSession.accountKey, t)
        }
        for k in legacy { try? store.delete(k) }
    }

    public var isConfigured: Bool { config != nil }
    public var isSignedIn: Bool { session.tokens != nil }
    public var email: String? { session.tokens?.account }
    public static let gmailModifyScope = ConnectorCatalog.gmailModifyScope
    public var grantedScopes: Set<String> { session.grantedScopes.intersection([Self.gmailScope, Self.calendarScope, Self.gmailModifyScope]) }
    /// Gmail can be read with either the read-only or the modify permission.
    public var canReadMail: Bool { !grantedScopes.isDisjoint(with: [Self.gmailScope, Self.gmailModifyScope]) }
    /// Mark as read is possible only when Google granted gmail.modify.
    public var canMarkRead: Bool { grantedScopes.contains(Self.gmailModifyScope) }
    var oauth: GoogleOAuth? { config.map { GoogleOAuth(config: $0, session: urlSession, now: now) } }

    public func token() async throws -> String {
        guard let oauth else { throw ConnectorError.notConfigured(ProviderConfig.notInBuild("Google", feature: "Gmail and Google Calendar")) }
        return try await session.accessToken(oauth: oauth)
    }

    public var gmail: GmailClient { GmailClient(session: urlSession) { [weak self] in try await self?.token() ?? { throw ConnectorError.cancelled }() } }
    public var calendar: GoogleCalendarClient { GoogleCalendarClient(session: urlSession) { [weak self] in try await self?.token() ?? { throw ConnectorError.cancelled }() } }

    /// Opens Google's sign-in and consent page for `scopes` (added to anything already granted) and
    /// waits for the redirect. Afterwards it makes a real read for each granted permission and saves
    /// the account name from it. Throws on cancel, denial, timeout or if nothing was granted.
    public func connect(scopes requested: [String], open: (URL) -> Void) async throws {
        guard let oauth else { throw ConnectorError.notConfigured(ProviderConfig.notInBuild("Google", feature: "Gmail and Google Calendar")) }
        isConnecting = true
        defer { isConnecting = false }
        disconnectNote = nil
        let previous = session.tokens
        let scopes = Array(Set(requested).union(grantedScopes)).sorted()
        let stateToken = UUID().uuidString
        let receiver = LoopbackReceiver(path: "/", expectedState: stateToken)
        do {
            try await receiver.start()
            let pkce = PKCE.make()
            open(oauth.authorizationURL(scopes: scopes, redirect: receiver.redirectURL, state: stateToken, pkce: pkce, loginHint: previous?.account))
            let callback = try await receiver.waitForRedirect(timeout: signInTimeout)
            let code = try GoogleOAuth.parseCallback(callback, expectedState: stateToken)
            var tokens = try await oauth.exchange(code: code, pkce: pkce, redirect: receiver.redirectURL, requestedScopes: scopes)
            try session.save(tokens)
            tokens.account = try await verifiedAccount()
            try session.save(tokens)
        } catch {
            receiver.stop()
            // A failed or cancelled attempt never leaves half a sign-in behind; an existing one stays.
            if let previous { try? session.save(previous) } else { try? session.clear() }
            throw error
        }
    }

    /// A real, authorized read for each granted permission. Returns the Google account it belongs to.
    @discardableResult
    public func verifiedAccount() async throws -> String {
        var account: String?
        if canReadMail { account = try await gmail.profileEmail() }
        if grantedScopes.contains(Self.calendarScope) {
            let id = try await calendar.accountID()
            account = account ?? id
        }
        guard let account else { throw OAuthError.scopeNotGranted(Self.gmailScope) }
        return account
    }

    /// Revokes Wren's access with Google (all permissions) and deletes the token.
    public func disconnect() async {
        disconnectNote = nil
        if let t = session.tokens, let oauth {
            if !(await oauth.revokeConfirmed(t.refreshToken ?? t.accessToken)) {
                disconnectNote = "Wren deleted its Google sign-in, but Google didn't confirm the revocation. You can also remove Wren at myaccount.google.com › Security › Third-party access."
            }
        }
        try? session.clear()
    }
}

/// Gmail or Google Calendar: one feature of the shared Google account, active only when Google
/// granted its read-only permission and a real read with it succeeded.
@MainActor
public final class GoogleConnector: BaseConnector, Connector {
    public let account: GoogleAccount
    public var emailCache: EmailCache?
    public var scope: String { descriptor.id == .gmail ? GoogleAccount.gmailScope : GoogleAccount.calendarScope }
    var featureName: String { descriptor.id == .gmail ? "read your email" : "see your calendars" }

    public init(_ id: ConnectorID, account: GoogleAccount, statusStore: ConnectorStatusStoring, now: @escaping @Sendable () -> Date = { Date() }) {
        precondition(id == .gmail || id == .googleCalendar)
        self.account = account
        super.init(id, statusStore: statusStore, now: now)
        state = initialState
    }

    public var isConfigured: Bool { account.isConfigured }
    public var isGranted: Bool { descriptor.id == .gmail ? account.canReadMail : account.grantedScopes.contains(scope) }
    /// Kept for callers that read the token store directly.
    public var google: GoogleSession { account.session }

    var notGrantedState: ConnectorState {
        .missingPermissions("Your Google account is connected, but you didn't allow Wren to \(featureName). Choose “Add \(descriptor.name)” and tick it on Google's page.")
    }

    var initialState: ConnectorState {
        guard account.isConfigured else { return .notAvailableInBuild(ProviderConfig.notInBuild("Google", feature: descriptor.name)) }
        guard account.isSignedIn else { return .available }
        return isGranted ? .temporarilyUnavailable("Not checked yet.") : notGrantedState
    }

    public var gmail: GmailClient { account.gmail }
    public var calendar: GoogleCalendarClient { account.calendar }

    func fetchAccount() async throws -> String {
        descriptor.id == .gmail ? try await gmail.profileEmail() : try await calendar.accountID()
    }

    /// Connect Google (or add this permission to the existing sign-in).
    public func connect(open: (URL) -> Void) async {
        guard account.isConfigured else { state = initialState; return }
        state = .connecting
        do {
            try await account.connect(scopes: [scope], open: open)
            await refresh()
        } catch { state = account.isSignedIn && !isGranted ? notGrantedState : stateFor(error) }
    }

    public func refresh() async {
        guard account.isConfigured else { state = initialState; return }
        guard account.isSignedIn else { state = .available; onPermissions(false); return }
        guard isGranted else { onPermissions(false); state = notGrantedState; return }
        do {
            let who = try await fetchAccount()
            // A refresh may have narrowed the grant (the user removed it at Google).
            guard isGranted else { onPermissions(false); state = notGrantedState; return }
            succeeded(account: who)
            state = .connected(account: who)
        } catch { state = stateFor(error) }
    }

    /// Disconnecting either one disconnects Google (Google revokes all of Wren's access at once).
    public func disconnect() async {
        await account.disconnect()
        emailCache?.clear()
        cleared()
    }
}

/// Notion through Notion's hosted MCP server. Wren registers itself at sign-in (no integration,
/// no secret, no server of Wren's own); the user signs in and chooses access on Notion's page.
@MainActor
public final class NotionConnector: BaseConnector, Connector {
    public nonisolated static let key = "notion.mcp"
    let store: CredentialStore
    let session: URLSession
    let auth: NotionMCPAuth
    public var signInTimeout: TimeInterval = 300
    /// Set when the last disconnect couldn't be confirmed with Notion.
    public private(set) var disconnectNote: String?
    private var cachedMCP: MCPClient?

    public init(store: CredentialStore, statusStore: ConnectorStatusStoring, session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.session = session
        auth = NotionMCPAuth(session: session, now: now)
        // Earlier builds kept a token from the old integration; it can't be used with Notion MCP.
        for legacy in ["notion.oauth", "notion.token"] { try? store.delete(legacy) }
        super.init(.notion, statusStore: statusStore, now: now)
        state = connection == nil ? .available : .temporarilyUnavailable("Not checked yet.")
    }

    public var connection: NotionMCPConnection? { store.readJSON(Self.key, as: NotionMCPConnection.self) }
    public var workspace: String? { connection?.workspace }
    public var isSignedIn: Bool { connection != nil }

    func accessToken(force: Bool) async throws -> String {
        guard var c = connection else { throw ConnectorError.notConfigured("Notion isn't connected.") }
        let expiring = c.expiresAt.map { $0.timeIntervalSince(now()) < 60 } ?? false
        if force || expiring {
            c = try await auth.refresh(c)
            try store.writeJSON(Self.key, c)
        }
        return c.accessToken
    }

    public var client: NotionMCPClient {
        if let m = cachedMCP { return NotionMCPClient(mcp: m) }
        let m = MCPClient(session: session) { [weak self] force in
            guard let self else { throw ConnectorError.cancelled }
            return try await self.accessToken(force: force)
        }
        cachedMCP = m
        return NotionMCPClient(mcp: m)
    }

    /// Opens Notion's sign-in and access page; Notion sends the browser back to Wren's loopback.
    public func connect(open: (URL) -> Void) async {
        state = .connecting
        disconnectNote = nil
        let previous = connection
        let stateToken = UUID().uuidString
        let receiver = LoopbackReceiver(path: NotionMCP.callbackPath, expectedState: stateToken)
        do {
            let meta = try await auth.metadata()
            try await receiver.start()
            let redirect = receiver.redirectURL
            let clientID = try await auth.register(meta, redirect: redirect)
            let pkce = PKCE.make()
            open(NotionMCPAuth.authorizationURL(meta, clientID: clientID, redirect: redirect, state: stateToken, pkce: pkce))
            let callback = try await receiver.waitForRedirect(timeout: signInTimeout)
            let code = try NotionMCPAuth.parseCallback(callback, expectedState: stateToken)
            let c = try await auth.exchange(meta, code: code, clientID: clientID, redirect: redirect, pkce: pkce)
            try store.writeJSON(Self.key, c)
            cachedMCP = nil
            try await verify()
        } catch {
            receiver.stop()
            // A failed attempt never leaves half a sign-in; an existing one stays.
            if let previous { try? store.writeJSON(Self.key, previous) } else { try? store.delete(Self.key) }
            cachedMCP = nil
            lastConnectError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            if previous != nil { state = .temporarilyUnavailable("Not checked yet."); return }
            switch error {
            case OAuthError.timedOut, OAuthError.denied, OAuthError.stateMismatch: _ = failed(error); state = .available
            default: state = stateFor(error)
            }
        }
    }

    /// Why the last Connect Notion didn't finish.
    public private(set) var lastConnectError: String?

    /// A real, authorized call: which workspace this connection is.
    func verify() async throws {
        let who = try await client.identity()
        if var c = connection, c.workspace != who.workspace || c.user != who.user {
            c.workspace = who.workspace; c.user = who.user
            try? store.writeJSON(Self.key, c)
        }
        let account = who.workspace ?? who.user ?? "Notion"
        lastConnectError = nil
        succeeded(account: account)
        state = .connected(account: account)
    }

    public func refresh() async {
        guard connection != nil else { state = .available; return }
        do { try await verify() } catch { state = stateFor(error) }
    }

    public func disconnect() async {
        disconnectNote = nil
        if let c = connection, !(await auth.revoke(c)) {
            disconnectNote = "Wren deleted its Notion sign-in, but Notion didn't confirm the revocation. You can also remove Wren in Notion › Settings › Connections."
        }
        try? store.delete(Self.key)
        cachedMCP = nil
        cleared()
    }
}
