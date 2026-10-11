import Foundation

public struct NotionPage: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var url: URL?
    public var lastEdited: Date?
}

public struct NotionBlock: Equatable, Sendable {
    public var type: String
    public var text: String
    public var supported: Bool
    public var depth: Int
}

