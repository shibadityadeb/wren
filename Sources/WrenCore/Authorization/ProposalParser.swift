import Foundation

/// Turns a model's suggested action (JSON) into an ActionRequest.
///
/// Only `action`, `target` and `parameters` are read. Fields such as `origin`,
/// `authorization`, `confirmed`, `approved_by_user` or `priority` are ignored: the origin
/// is always the model (or the untrusted content it was reading), so a proposal can never
/// carry permission with it.
public enum ProposalParser {
    public enum ParseError: Error, Equatable { case notJSON, missing(String) }

    public static func parse(_ json: String, model: String, readingUntrustedContentFrom source: String? = nil,
                             now: Date) throws -> ActionRequest {
        guard let data = json.data(using: .utf8),
              case let .object(o)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw ParseError.notJSON }
        guard case let .string(action)? = o["action"] else { throw ParseError.missing("action") }
        guard case let .object(t)? = o["target"], case let .string(kind)? = t["kind"], case let .string(id)? = t["id"] else {
            throw ParseError.missing("target")
        }
        var label = id
        if case let .string(l)? = t["label"] { label = l }
        var params: [String: JSONValue] = [:]
        if case let .object(p)? = o["parameters"] { params = p }
        let origin: ActionOrigin = source.map { .untrustedContent($0) } ?? .model(model)
        return ActionRequest(action: ActionID(rawValue: action), target: TargetRef(kind: kind, id: id, label: label),
                             parameters: params, origin: origin, createdAt: now)
    }
}
