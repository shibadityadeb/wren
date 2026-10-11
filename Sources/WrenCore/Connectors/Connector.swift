import Foundation

public enum ConnectorID: String, Codable, Sendable, CaseIterable, Identifiable {
    case chatgpt, voice, gmail, notion, googleCalendar, localFiles, shortcuts
    public var id: String { rawValue }
}

/// Honest connection states. `.connected` is only ever set after a real check succeeded.
public enum ConnectorState: Equatable, Sendable {
    /// Implemented and ready to connect; not connected.
    case available
    /// Needs something from you first (an app or a macOS permission). Never developer credentials.
    case setupRequired(String)
    /// This build of Wren doesn't include the provider's app registration. A blocker for Wren's
    /// maintainers, not a task for the user.
    case notAvailableInBuild(String)
    case connecting
    /// Verified against the provider. `account` is what the provider reported (email, workspace).
    case connected(account: String?)
    /// Works, but something is missing (for example a scope or a selected model).
    case partiallyConnected(String)
    /// Was working; the last check failed for a reason that may pass.
    case temporarilyUnavailable(String)
    /// A permission Wren needs wasn't granted (unticked on a consent screen, or refused in macOS).
    case missingPermissions(String)
    /// The sign-in expired or was revoked; connecting again fixes it.
    case reauthorizationRequired(String)
    /// The provider's allowance for this account is used up for now.
    case usageLimitReached(String)
    /// You disconnected it; credentials and cached data were removed.
    case disconnected
    /// Not implemented yet.
    case planned

    public var label: String {
        switch self {
        case .available: "Available to connect"
        case .setupRequired: "Setup required"
        case .notAvailableInBuild: "Maintainer setup required"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .partiallyConnected: "Partially connected"
        case .temporarilyUnavailable: "Temporarily unavailable"
        case .missingPermissions: "Missing permissions"
        case .reauthorizationRequired: "Reauthorization required"
        case .usageLimitReached: "Usage limit reached"
        case .disconnected: "Disconnected"
        case .planned: "Not implemented"
        }
    }

    public var detail: String? {
        switch self {
        case let .setupRequired(s), let .notAvailableInBuild(s), let .partiallyConnected(s), let .temporarilyUnavailable(s), let .missingPermissions(s),
             let .reauthorizationRequired(s), let .usageLimitReached(s): s
        case let .connected(a): a
        default: nil
        }
    }

    public var isConnected: Bool { if case .connected = self { true } else { false } }
    /// Usable for its implemented capabilities (fully or partially).
    public var isUsable: Bool {
        switch self { case .connected, .partiallyConnected: true; default: false }
    }

    public enum Bucket: String, Sendable, CaseIterable { case connected, needsSetup, unavailable, notConnected, planned }
    public var bucket: Bucket {
        switch self {
        case .connected, .partiallyConnected: .connected
        case .setupRequired, .connecting, .missingPermissions, .reauthorizationRequired: .needsSetup
        case .temporarilyUnavailable, .usageLimitReached, .notAvailableInBuild: .unavailable
        case .available, .disconnected: .notConnected
        case .planned: .planned
        }
    }
}

public enum ConnectorAuth: Equatable, Sendable {
    case none
    case macOSPermission([String])
    case chatgptSignIn
    case googleOAuth(scopes: [String])
    case notionOAuth
    case planned

    public var label: String {
        switch self {
        case .none: "None"
        case let .macOSPermission(p): "macOS permission: \(p.joined(separator: ", "))"
        case .chatgptSignIn: "Sign in with ChatGPT in your browser. No API key; uses your ChatGPT plan, not API billing."
        case let .googleOAuth(s): "Sign in with Google in your browser. Read-only: \(s.map(OAuthError.plain).joined(separator: ", "))."
        case .notionOAuth: "Connect Notion in your browser and choose the pages Wren may use."
        case .planned: "Not decided yet"
        }
    }
}

public struct ConnectorCapability: Equatable, Sendable, Identifiable {
    public var name: String
    public var implemented: Bool
    /// Leaves the Mac when used.
    public var external: Bool
    public var id: String { name }
}

/// Everything Settings needs to describe a connector. Declared once per connector.
public struct ConnectorDescriptor: Sendable, Identifiable {
    public var id: ConnectorID
    public var name: String
    public var systemImage: String
    public var summary: String
    public var auth: ConnectorAuth
    public var capabilities: [ConnectorCapability]
    /// Wren permissions (policy) granted while connected.
    public var permissions: [Permission]
    /// What is read, what leaves the Mac, what is stored where.
    public var privacy: String
    /// What disconnecting removes.
    public var cleanup: String
    public var hosts: Set<String>
    public var isPlanned: Bool
}

/// Last check and sync, kept per connector (in user defaults by the app).
public struct ConnectorStatus: Codable, Equatable, Sendable {
    public var lastSuccessfulSync: Date?
    public var lastError: String?
    public var lastErrorAt: Date?
    public var account: String?
    public init(lastSuccessfulSync: Date? = nil, lastError: String? = nil, lastErrorAt: Date? = nil, account: String? = nil) {
        self.lastSuccessfulSync = lastSuccessfulSync; self.lastError = lastError; self.lastErrorAt = lastErrorAt; self.account = account
    }
}

public extension Permission {
    static let chatgptHandoff: Permission = "external.chatgpt.handoff"
    static let calendarRead: Permission = "external.calendar.read"
    static let notionRead: Permission = "external.notion.read"
    static let notionWrite: Permission = "external.notion.write"
    static let microphone: Permission = "local.microphone"
}

public enum ConnectorCatalog {
    public static let gmailScope = "https://www.googleapis.com/auth/gmail.readonly"
    public static let calendarScope = "https://www.googleapis.com/auth/calendar.readonly"

    public static let all: [ConnectorDescriptor] = [
        .init(id: .chatgpt, name: "ChatGPT", systemImage: "bubble.left.and.text.bubble.right",
              summary: "Sign in with your ChatGPT account so Wren can send requests you approve and bring the answer back, using your ChatGPT plan (Plus or Pro). Copy-and-open handoff stays available as an optional fallback.",
              auth: .chatgptSignIn,
              capabilities: [.init(name: "Sign in with ChatGPT", implemented: true, external: true),
                             .init(name: "Send a request you approve and stream the answer back", implemented: true, external: true),
                             .init(name: "List the models your plan offers", implemented: true, external: true),
                             .init(name: "Copy the prompt and open ChatGPT (optional fallback)", implemented: true, external: true),
                             .init(name: "Import an answer, summarise it locally, propose follow-ups", implemented: true, external: false),
                             .init(name: "Use your plan from background tasks", implemented: false, external: true)],
              permissions: [.externalAI, .chatgptHandoff],
              privacy: "You sign in on OpenAI's page in your browser; Wren never sees your password. Wren keeps your account email and the sign-in tokens in a private file in Wren's data folder that only your macOS account can read, never in its database, exports, backups, logs or on screen. Each request shows the exact text first and is sent only after you confirm. It counts against your ChatGPT plan's allowance and never switches to paid API billing. Requests are sent with storage off. Wren can't see your ChatGPT conversations, memories or custom instructions.",
              cleanup: "Disconnecting revokes the sign-in with OpenAI and deletes the tokens from this Mac. You can also remove Wren under ChatGPT Settings.",
              hosts: ["auth.openai.com", "api.openai.com", "chatgpt.com"], isPlanned: false),
        .init(id: .voice, name: "Voice", systemImage: "mic",
              summary: "Say “Hey Wren” or press the voice shortcut, then say what you need, for example “remind me to call Sam tomorrow at 10 AM”. Wren shows what it heard and what it did.",
              auth: .macOSPermission(["Microphone", "Speech Recognition"]),
              capabilities: [.init(name: "“Hey Wren” wake phrase (opt-in)", implemented: true, external: false),
                             .init(name: "Voice shortcut (default ⌥⇧ Space)", implemented: true, external: false),
                             .init(name: "On-device transcription", implemented: true, external: false),
                             .init(name: "Run the spoken command (reminders, snooze, questions)", implemented: true, external: false)],
              permissions: [.microphone],
              privacy: "Speech is recognised on this Mac (on-device mode is required; Wren refuses server recognition) and no audio is stored or sent anywhere. With “Hey Wren” on, the microphone stays open in the background and only the wake phrase starts a command; recording stops when the command ends.",
              cleanup: "Turning it off stops listening. Quitting Wren stops the microphone. Revoke the macOS permissions in System Settings › Privacy & Security.",
              hosts: [], isPlanned: false),
        .init(id: .gmail, name: "Gmail", systemImage: "envelope",
              summary: "Read-only: search mail, flag what needs attention (requests, deadlines, bills, interviews, security alerts), summarise it, add it to the morning briefing, and suggest tasks you review first.",
              auth: .googleOAuth(scopes: [gmailScope]),
              capabilities: [.init(name: "Search and read messages", implemented: true, external: true),
                             .init(name: "Flag important mail with reasons", implemented: true, external: false),
                             .init(name: "Email in the morning briefing", implemented: true, external: false),
                             .init(name: "Suggest tasks (you review them)", implemented: true, external: false),
                             .init(name: "Send, archive, delete, mark read", implemented: false, external: true)],
              permissions: [.emailRead],
              privacy: "Read-only access. Messages are fetched on demand; by default nothing is stored on disk. Optional 7-day local cache of headers and snippets. Tokens are kept in a private file in Wren's data folder that only your macOS account can read. Instructions inside emails are treated as text, never as commands.",
              cleanup: "Disconnecting revokes Wren's access with Google, deletes the token from this Mac and deletes any cached mail.",
              hosts: ["gmail.googleapis.com", "oauth2.googleapis.com", "accounts.google.com"], isPlanned: false),
        .init(id: .notion, name: "Notion", systemImage: "doc.text",
              summary: "Connect your Notion workspace and choose, on Notion's own screen, which pages Wren may use. Search and read those pages, include them in a request, and create a page after you confirm.",
              auth: .notionOAuth,
              capabilities: [.init(name: "Search the pages you chose", implemented: true, external: true),
                             .init(name: "Read page content", implemented: true, external: true),
                             .init(name: "Create a page (asks first)", implemented: true, external: true)],
              permissions: [.notionRead, .notionWrite],
              privacy: "Wren sees only the pages you pick when you connect. Page content is fetched when you ask and not stored. Sign-in finishes through a small Wren service that holds Wren's Notion app secret; it passes the token to Wren and keeps nothing. The token is kept in a private file in Wren's data folder that only your macOS account can read.",
              cleanup: "Disconnecting revokes the token with Notion and deletes it from this Mac.",
              hosts: ["api.notion.com"], isPlanned: false),
        .init(id: .googleCalendar, name: "Google Calendar", systemImage: "calendar",
              summary: "Read-only: today's schedule, upcoming events, search, questions like “what meetings do I have tomorrow?”, events in the morning briefing, and reminders from events.",
              auth: .googleOAuth(scopes: [calendarScope]),
              capabilities: [.init(name: "Read and search events", implemented: true, external: true),
                             .init(name: "Events in the morning briefing", implemented: true, external: false),
                             .init(name: "Create a Wren reminder from an event", implemented: true, external: false),
                             .init(name: "Create or change events", implemented: false, external: true)],
              permissions: [.calendarRead],
              privacy: "Read-only. Events are fetched when needed and not stored. Tokens are kept in a private file in Wren's data folder that only your macOS account can read.",
              cleanup: "Disconnecting revokes the token with Google and deletes it from this Mac.",
              hosts: ["www.googleapis.com", "oauth2.googleapis.com", "accounts.google.com"], isPlanned: false),
        .init(id: .localFiles, name: "Local files", systemImage: "folder",
              summary: "Planned: search and summarise documents in folders you choose, through macOS's file picker. No Full Disk Access.",
              auth: .planned, capabilities: [.init(name: "Search chosen folders", implemented: false, external: false)],
              permissions: [], privacy: "Will only read folders you pick, with security-scoped bookmarks.", cleanup: "", hosts: [], isPlanned: true),
        .init(id: .shortcuts, name: "Apple Shortcuts", systemImage: "square.stack.3d.up",
              summary: "Planned: list your shortcuts, and run one you name only after you confirm, under Wren's permission rules.",
              auth: .planned, capabilities: [.init(name: "List shortcuts", implemented: false, external: false),
                                             .init(name: "Run a shortcut (asks first)", implemented: false, external: false)],
              permissions: [], privacy: "Listing and running will be separate permissions; running always asks.", cleanup: "", hosts: [], isPlanned: true),
    ]

    public static func descriptor(_ id: ConnectorID) -> ConnectorDescriptor { all.first { $0.id == id }! }
}

/// One live connector. Implementations validate against the provider for real.
@MainActor
public protocol Connector: AnyObject {
    var descriptor: ConnectorDescriptor { get }
    var state: ConnectorState { get }
    /// Checks with the provider (or macOS) and updates `state`.
    func refresh() async
    /// Removes credentials and local data; revokes with the provider where supported.
    func disconnect() async
}

/// Holds every connector; Settings reads only this.
@MainActor
public final class ConnectorRegistry {
    public private(set) var connectors: [Connector] = []
    public init() {}
    public func register(_ c: Connector) { connectors.removeAll { $0.descriptor.id == c.descriptor.id }; connectors.append(c) }
    public func connector(_ id: ConnectorID) -> Connector? { connectors.first { $0.descriptor.id == id } }
    public func state(_ id: ConnectorID) -> ConnectorState { connector(id)?.state ?? (ConnectorCatalog.descriptor(id).isPlanned ? .planned : .available) }

    public var summary: [ConnectorState.Bucket: Int] {
        var out: [ConnectorState.Bucket: Int] = [:]
        for d in ConnectorCatalog.all { out[state(d.id).bucket, default: 0] += 1 }
        return out
    }
    public func refreshAll() async { for c in connectors { await c.refresh() } }
}

/// A catalog entry that isn't implemented. Always `.planned`, no actions.
@MainActor
public final class PlannedConnector: Connector {
    public let descriptor: ConnectorDescriptor
    public init(_ id: ConnectorID) { descriptor = ConnectorCatalog.descriptor(id) }
    public var state: ConnectorState { .planned }
    public func refresh() async {}
    public func disconnect() async {}
}
