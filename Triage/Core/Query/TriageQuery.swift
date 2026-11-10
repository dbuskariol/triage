import Foundation

/// The one filter language for rules, search, saved searches, and rule
/// suggestions. GitHub-style: terms are AND-ed, `OR` joins alternatives,
/// parentheses group, `-` negates, quotes keep phrases together, and `@me`
/// is the signed-in user.
///
///     is:review status:failing -author:@me
///     repo:acme/* (label:security OR signal:security)
///
/// Stored as canonical text (`description`); `parse(print(q)) == q`.
struct TriageQuery: Hashable, Sendable, CustomStringConvertible {
    indirect enum Node: Hashable, Sendable {
        case all([Node])
        case any([Node])
        case not(Node)
        case qualifier(Qualifier, String)
        case text(String)
    }

    /// When a query can be evaluated: on GitHub facts alone, with local read
    /// state, or only once Copilot has decided.
    enum Phase: Int, Comparable, Sendable {
        case facts, local, ai
        static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let root: Node

    init(_ root: Node) { self.root = Self.normalized(root) }

    init(parsing text: String) throws(TriageQueryError) {
        var parser = TriageQueryParser(text)
        self.init(try parser.parse())
    }

    var description: String { Self.print(root, nested: false) }

    var phase: Phase { Self.phase(of: root) }

    /// Every qualifier the query uses.
    var qualifiers: [(key: Qualifier, value: String)] {
        var result: [(Qualifier, String)] = []
        func visit(_ node: Node) {
            switch node {
            case .all(let nodes), .any(let nodes): nodes.forEach(visit)
            case .not(let node): visit(node)
            case .qualifier(let key, let value): result.append((key, value))
            case .text: break
            }
        }
        visit(root)
        return result
    }

    /// Both queries must match.
    func and(_ other: TriageQuery) -> TriageQuery { TriageQuery(.all([root, other.root])) }

    // MARK: Qualifiers

    enum Qualifier: String, CaseIterable, Codable, Hashable, Sendable {
        // The first eight raw values are also legacy search-token kinds.
        case repo, author, label, team, `is`, status, priority, effort
        case assignee, commenter, reviewer, check, title, body, comment, updated, created, size
        case signal, topic, `in`

        var phase: Phase {
            switch self {
            case .signal, .topic, .priority, .effort, .in: .ai
            default: .facts
            }
        }

        /// Fixed values with short descriptions; `nil` means free values.
        var knownValues: [(value: String, title: String)]? {
            switch self {
            case .is:
                [
                    ("pr", "Pull requests"), ("issue", "Issues"), ("draft", "Draft pull requests"),
                    ("review", "Review requested"), ("direct", "Review requested from you directly"),
                    ("team", "Review requested from your team only"), ("assigned", "Assigned to you"),
                    ("mine", "Opened by you"), ("mentioned", "Mentions you"),
                    ("unread", "Unread"), ("read", "Read"),
                ]
            case .status:
                [
                    ("failing", "Checks failing"), ("required-failing", "Required checks failing"),
                    ("passing", "Checks passing"), ("pending", "Checks running"),
                    ("conflicts", "Has conflicts"), ("approved", "Approved"), ("changes", "Changes requested"),
                ]
            case .priority: [("high", "High priority"), ("medium", "Medium priority"), ("low", "Low priority")]
            case .effort: TriageEffort.allCases.map { ($0.rawValue, "\($0.title) · \($0.detail)") }
            case .in:
                [
                    ("action", "Needs your action"), ("inbox", "In your Inbox"), ("review", "Worth a look"),
                    ("waiting", "Waiting on others"), ("none", "No action needed"),
                ]
            default: nil
            }
        }

        var comparison: ComparisonKind? {
            switch self {
            case .updated, .created: .age
            case .size, .priority: .number
            default: nil
            }
        }

        var title: String {
            switch self {
            case .repo: "Repository"
            case .author: "Author"
            case .label: "Label"
            case .team: "Requested team"
            case .is: "Type and relationship"
            case .status: "Pull request status"
            case .priority: "Priority"
            case .effort: "Effort"
            case .assignee: "Assignee"
            case .commenter: "Commenter"
            case .reviewer: "Reviewer"
            case .check: "Check"
            case .title: "Title contains"
            case .body: "Description contains"
            case .comment: "Comment contains"
            case .updated: "Last updated"
            case .created: "Created"
            case .size: "Lines changed"
            case .signal: "Copilot signal"
            case .topic: "Topic"
            case .in: "Copilot decision"
            }
        }

        var example: String {
            switch self {
            case .repo: "repo:owner/name"
            case .author: "author:dependabot[bot]"
            case .label: "label:security"
            case .team: "team:org/team"
            case .is: "is:review"
            case .status: "status:failing"
            case .priority: "priority:high"
            case .effort: "effort:quick"
            case .assignee: "assignee:@me"
            case .commenter: "commenter:github-actions[bot]"
            case .reviewer: "reviewer:alice"
            case .check: "check:build:failing"
            case .title: "title:release"
            case .body: "body:\"approval required\""
            case .comment: "comment:\"approval required\""
            case .updated: "updated:>14d"
            case .created: "created:<2d"
            case .size: "size:>500"
            case .signal: "signal:ci-failing"
            case .topic: "topic:\"Compliance approvals\""
            case .in: "in:action"
            }
        }
    }

    enum ComparisonKind: Sendable { case age, number }

    /// States accepted after a check name: `check:build:failing`.
    static let checkStates = ["failing", "passing", "pending", "skipped"]

    /// Legacy spellings, rewritten when parsed.
    static let aliases: [String: (Qualifier, String)] = [
        "is:action": (.in, "action"),
        "status:changes-requested": (.status, "changes"),
        "status:success": (.status, "passing"),
    ]

    // MARK: Normalization and printing

    private static func normalized(_ node: Node) -> Node {
        switch node {
        case .all(let nodes):
            let flat = nodes.map(normalized).flatMap { node -> [Node] in if case .all(let inner) = node { inner } else { [node] } }
            return flat.count == 1 ? flat[0] : .all(flat)
        case .any(let nodes):
            let flat = nodes.map(normalized).flatMap { node -> [Node] in if case .any(let inner) = node { inner } else { [node] } }
            return flat.count == 1 ? flat[0] : .any(flat)
        case .not(let inner):
            let value = normalized(inner)
            if case .not(let double) = value { return double }
            return .not(value)
        case .qualifier, .text:
            return node
        }
    }

    private static func print(_ node: Node, nested: Bool) -> String {
        switch node {
        case .all(let nodes):
            let text = nodes.map { print($0, nested: true) }.joined(separator: " ")
            return nested ? "(\(text))" : text
        case .any(let nodes):
            let text = nodes.map { print($0, nested: true) }.joined(separator: " OR ")
            return nested ? "(\(text))" : text
        case .not(let inner):
            return "-" + print(inner, nested: true)
        case .qualifier(let key, let value):
            return "\(key.rawValue):\(printValue(value, for: key))"
        case .text(let text):
            return quotedIfNeeded(text, isText: true)
        }
    }

    private static func printValue(_ value: String, for key: Qualifier) -> String {
        if key == .check, let state = splitCheck(value).state {
            return "\(quotedIfNeeded(splitCheck(value).name, isText: false)):\(state)"
        }
        if key.comparison != nil { return value }
        return quotedIfNeeded(value, isText: false)
    }

    static func quotedIfNeeded(_ text: String, isText: Bool) -> String {
        var special = text.isEmpty || text.contains { $0.isWhitespace || "()\"".contains($0) }
        if isText { special = special || text.contains(":") || text.hasPrefix("-") || text == "OR" }
        guard special else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "") + "\""
    }

    /// `name` or `name:state`, where state is one of `checkStates`.
    static func splitCheck(_ value: String) -> (name: String, state: String?) {
        if let colon = value.lastIndex(of: ":") {
            let state = value[value.index(after: colon)...].lowercased()
            if checkStates.contains(state) { return (String(value[..<colon]), state) }
        }
        return (value, nil)
    }

    private static func phase(of node: Node) -> Phase {
        switch node {
        case .all(let nodes), .any(let nodes): nodes.map(phase(of:)).max() ?? .facts
        case .not(let inner): phase(of: inner)
        case .qualifier(.is, let value) where value == "unread" || value == "read": .local
        case .qualifier(let key, _): key.phase
        case .text: .facts
        }
    }
}

extension TriageQuery: Codable {
    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(parsing: text)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error.message))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A specific, user-facing problem with query text.
struct TriageQueryError: Error, Equatable, LocalizedError, Sendable {
    let message: String
    /// Character offset in the text where the problem starts.
    let position: Int

    var errorDescription: String? { message }
}
