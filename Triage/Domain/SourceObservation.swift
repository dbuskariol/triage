import Foundation

struct SourceAccessObservationID: Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init?(rawValue: String) {
        guard (1...128).contains(rawValue.count),
              rawValue.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace })
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    static func make() -> Self {
        Self(rawValue: UUID().uuidString.lowercased())!
    }

    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let identifier = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid source access observation identifier."
            )
        }
        self = identifier
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum SourceAccessTargetKind: String, Codable, CaseIterable, Sendable {
    case repository
    case githubNode
    case team
}

enum SourceAccessTarget: Equatable, Hashable, Sendable {
    case repository(RepositoryID)
    case githubNode(GitHubNodeID)
    case team(TeamID)

    var kind: SourceAccessTargetKind {
        switch self {
        case .repository: .repository
        case .githubNode: .githubNode
        case .team: .team
        }
    }

    var rawValue: String {
        switch self {
        case let .repository(identifier): identifier.rawValue
        case let .githubNode(identifier): identifier.rawValue
        case let .team(identifier): identifier.rawValue
        }
    }

    init?(kind: SourceAccessTargetKind, rawValue: String) {
        switch kind {
        case .repository:
            guard let identifier = RepositoryID(rawValue: rawValue) else { return nil }
            self = .repository(identifier)
        case .githubNode:
            guard let identifier = GitHubNodeID(rawValue: rawValue) else { return nil }
            self = .githubNode(identifier)
        case .team:
            guard let identifier = TeamID(rawValue: rawValue) else { return nil }
            self = .team(identifier)
        }
    }
}

enum SourceAccessLocatorKind: String, Codable, CaseIterable, Sendable {
    case endpoint
    case query
}

enum SourceAccessLocator: Equatable, Hashable, Sendable {
    case endpoint(String)
    case query(String)

    var kind: SourceAccessLocatorKind {
        switch self {
        case .endpoint: .endpoint
        case .query: .query
        }
    }

    var value: String {
        switch self {
        case let .endpoint(value), let .query(value): value
        }
    }

    init(kind: SourceAccessLocatorKind, value: String) {
        switch kind {
        case .endpoint: self = .endpoint(value)
        case .query: self = .query(value)
        }
    }
}

enum SourceAccessResult: String, Codable, CaseIterable, Sendable {
    case accessible
    case inaccessible
    case unknown
    case authoritativelyDeleted
}

enum SourceAccessReason: String, Codable, CaseIterable, Sendable {
    case directResponse
    case privateNotFound
    case forbidden
    case ssoRequired
    case approvalRequired
    case inventoryOmission
    case authoritativeOmission
    case immutableIdentityReplacement
}

enum SourceAccessAuthority: String, Codable, CaseIterable, Sendable {
    case incremental
    case directProbe
    case fullReconciliation
}

enum SourceAccessConfirmation: String, Codable, CaseIterable, Sendable {
    case provisional
    case confirmed
}

struct SourceAccessObservation: Equatable, Sendable, Identifiable {
    let id: SourceAccessObservationID
    let scope: SynchronizationScope
    let feature: CoverageFeature
    let streamID: SyncStreamID
    let target: SourceAccessTarget
    let source: SourceAccessLocator
    let sourceNodeID: GitHubNodeID?
    let sourceEventID: GitHubEventID?
    let sourceRevision: String
    let rawSnapshotID: RawAPISnapshotID?
    let result: SourceAccessResult
    let reason: SourceAccessReason
    let authority: SourceAccessAuthority
    let confirmation: SourceAccessConfirmation
    let observedAt: Date
}

struct SourceAccessProjection: Equatable, Sendable {
    let scope: SynchronizationScope
    let feature: CoverageFeature
    let streamID: SyncStreamID
    let target: SourceAccessTarget
    let result: SourceAccessResult
    let winningObservationID: SourceAccessObservationID
    let observedAt: Date
}
