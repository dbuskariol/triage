import CryptoKit
import Foundation
import GRDB

enum DiscussionCommentRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case discussionScopeMismatch
    case staleSynchronizationScope
    case invalidRawAuthority
    case conflictingRawPage
    case invalidRecord
}

/// Persists a fully traversed discussion comment/reply graph atomically. It
/// never treats a GraphQL omission as deletion evidence; retained rows remain
/// until a dedicated deletion/reconciliation contract exists.
actor DiscussionCommentRepository {
    private let vault: AccountVault
    init(vault: AccountVault) { self.vault = vault }

    func replace(
        _ inventory: GitHubDiscussionCommentInventory,
        scope: SynchronizationScope, accountID: AccountID, organization: GitHubOrganization,
        repositoryID: RepositoryID, discussionNodeID: GitHubNodeID,
        commentStreamID: SyncStreamID, replyStreamID: SyncStreamID,
        observedAt: Date, parserVersion: Int = 1, coverageRecords: [CoverageRecord]
    ) async throws {
        guard accountID == vault.accountID, scope.accountID == accountID, scope.organizationID == organization.id else { throw DiscussionCommentRepositoryError.accountScopeMismatch }
        try await vault.writeTransaction { database in
            try Self.validateScope(scope, accountID: accountID, organization: organization, repositoryID: repositoryID, discussionNodeID: discussionNodeID, in: database)
            try Self.validate(inventory, discussionNodeID: discussionNodeID)
            try Self.validateCompleteAuthority(
                inventory,
                discussionNodeID: discussionNodeID
            )
            try Self.save(inventory.comments + inventory.replies, accountID: accountID, organizationID: organization.id, repositoryID: repositoryID, observedAt: observedAt, in: database)
            // Reply-page provenance is attached to its DiscussionComment node.
            // Save the verified graph first; the enclosing transaction rolls it
            // back if immutable raw evidence or coverage cannot be retained.
            try Self.saveRaw(inventory.rawPages, scope: scope, accountID: accountID, discussionNodeID: discussionNodeID, commentStreamID: commentStreamID, replyStreamID: replyStreamID, observedAt: observedAt, parserVersion: parserVersion, complete: true, in: database)
            for coverage in coverageRecords { try CoverageRepository.save(coverage, attemptedAt: observedAt, expectedAccountID: accountID, in: database) }
        }
    }

    func recordFailure(
        pages: [GitHubDiscussionCommentRawPage], scope: SynchronizationScope, accountID: AccountID,
        organization: GitHubOrganization, repositoryID: RepositoryID, discussionNodeID: GitHubNodeID,
        commentStreamID: SyncStreamID, replyStreamID: SyncStreamID, observedAt: Date,
        diagnostic: String, parserVersion: Int = 1, coverageRecords: [CoverageRecord]
    ) async throws {
        guard accountID == vault.accountID, scope.accountID == accountID, scope.organizationID == organization.id else { throw DiscussionCommentRepositoryError.accountScopeMismatch }
        try await vault.writeTransaction { database in
            try Self.validateScope(scope, accountID: accountID, organization: organization, repositoryID: repositoryID, discussionNodeID: discussionNodeID, in: database)
            let snapshots = try Self.preparedRaw(pages, scope: scope, accountID: accountID, discussionNodeID: discussionNodeID, commentStreamID: commentStreamID, replyStreamID: replyStreamID, observedAt: observedAt, parserVersion: parserVersion, complete: false)
            for snapshot in snapshots {
                try Self.save(snapshot, at: observedAt, in: database)
                try NormalizationFailureRepository.record(.init(id: UUID(), accountID: accountID, rawSnapshotID: snapshot.id, githubNodeID: snapshot.githubNodeID, endpoint: snapshot.endpoint, parserVersion: parserVersion, occurredAt: observedAt, redactedDiagnostic: String(diagnostic.prefix(4_096))), in: database)
            }
            for coverage in coverageRecords { try CoverageRepository.save(coverage, attemptedAt: observedAt, expectedAccountID: accountID, in: database) }
        }
    }

    func validateCurrentScope(_ scope: SynchronizationScope) async throws {
        guard scope.accountID == vault.accountID else { throw DiscussionCommentRepositoryError.accountScopeMismatch }
        try await vault.read { database in try Self.validateCurrentScope(scope, in: database) }
    }

    private nonisolated static func validateScope(_ scope: SynchronizationScope, accountID: AccountID, organization: GitHubOrganization, repositoryID: RepositoryID, discussionNodeID: GitHubNodeID, in database: Database) throws {
        try validateCurrentScope(scope, in: database)
        let count = try Int.fetchOne(database, sql: """
            SELECT COUNT(*) FROM discussions
            JOIN github_nodes ON github_nodes.github_node_id = discussions.github_node_id
            JOIN repositories ON repositories.id = github_nodes.repository_id
            JOIN account_repository_access ON account_repository_access.repository_id = repositories.id
            WHERE discussions.github_node_id = ? AND github_nodes.account_id = ? AND github_nodes.organization_id = ?
              AND github_nodes.repository_id = ? AND repositories.github_node_id IS NOT NULL
              AND account_repository_access.account_id = ? AND account_repository_access.access_state = 'available'
            """, arguments: [discussionNodeID.rawValue, accountID.rawValue, organization.id.rawValue, repositoryID.rawValue, accountID.rawValue]) ?? 0
        guard count == 1 else { throw DiscussionCommentRepositoryError.discussionScopeMismatch }
    }

    private nonisolated static func validateCurrentScope(_ scope: SynchronizationScope, in database: Database) throws {
        do { try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database) }
        catch OrganizationSchedulerStateRepositoryError.staleSynchronizationScope, OrganizationSchedulerStateRepositoryError.organizationScopeMismatch { throw DiscussionCommentRepositoryError.staleSynchronizationScope }
    }

    private nonisolated static func validate(_ inventory: GitHubDiscussionCommentInventory, discussionNodeID: GitHubNodeID) throws {
        var IDs = Set<GitHubNodeID>()
        let comments = Set(inventory.comments.map(\.nodeID))
        guard comments.count == inventory.comments.count else { throw DiscussionCommentRepositoryError.invalidRecord }
        for record in inventory.comments + inventory.replies {
            guard IDs.insert(record.nodeID).inserted, record.discussionNodeID == discussionNodeID,
                  record.createdAt.timeIntervalSinceReferenceDate.isFinite, record.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  record.createdAt <= record.updatedAt, record.url.scheme == "https", record.url.host == "github.com" else { throw DiscussionCommentRepositoryError.invalidRecord }
            switch record.kind {
            case .discussionComment: guard record.parentNodeID == discussionNodeID else { throw DiscussionCommentRepositoryError.invalidRecord }
            case .discussionReply: guard comments.contains(record.parentNodeID) else { throw DiscussionCommentRepositoryError.invalidRecord }
            default: throw DiscussionCommentRepositoryError.invalidRecord
            }
        }
    }

    /// A complete publication is only authoritative when its root connection
    /// reached an authenticated terminal page and every returned root comment
    /// independently reached a terminal replies page. This intentionally also
    /// applies to an empty root connection: emptiness without a terminal page
    /// is unavailable evidence, not an authoritative empty result.
    private nonisolated static func validateCompleteAuthority(
        _ inventory: GitHubDiscussionCommentInventory,
        discussionNodeID: GitHubNodeID
    ) throws {
        let pages = inventory.rawPages
        try validatePages(pages, discussionNodeID: discussionNodeID, complete: true)

        let rootPages = pages.filter { $0.source == .comments }
        guard !rootPages.isEmpty else {
            throw DiscussionCommentRepositoryError.invalidRawAuthority
        }

        let expectedCommentIDs = Set(inventory.comments.map(\.nodeID))
        let expectedRepliesByParent = Dictionary(
            grouping: inventory.replies,
            by: \.parentNodeID
        ).mapValues { Set($0.map(\.nodeID)) }
        var rootCommentIDs = Set<GitHubNodeID>()
        var replyParents = Set<GitHubNodeID>()
        var replyIDsByParent = [GitHubNodeID: Set<GitHubNodeID>]()

        for page in pages {
            let pageAuthority = try authority(page, discussionNodeID: discussionNodeID)
            let nodeIDs = try connectionNodeIDs(
                page.payload,
                source: page.source,
                expectedNodeID: pageAuthority.nodeID
            )
            switch page.source {
            case .comments:
                guard rootCommentIDs.isDisjoint(with: nodeIDs) else {
                    throw DiscussionCommentRepositoryError.invalidRawAuthority
                }
                rootCommentIDs.formUnion(nodeIDs)
            case .replies:
                replyParents.insert(pageAuthority.nodeID)
                let prior = replyIDsByParent[pageAuthority.nodeID, default: []]
                guard prior.isDisjoint(with: nodeIDs) else {
                    throw DiscussionCommentRepositoryError.invalidRawAuthority
                }
                replyIDsByParent[pageAuthority.nodeID] = prior.union(nodeIDs)
            }
        }

        guard rootCommentIDs == expectedCommentIDs else {
            throw DiscussionCommentRepositoryError.invalidRawAuthority
        }
        let expectedReplyParents = expectedCommentIDs
        guard replyParents == expectedReplyParents else {
            throw DiscussionCommentRepositoryError.invalidRawAuthority
        }
        for commentID in expectedCommentIDs {
            guard replyIDsByParent[commentID, default: []]
                == expectedRepliesByParent[commentID, default: []]
            else {
                throw DiscussionCommentRepositoryError.invalidRawAuthority
            }
        }
    }

    private nonisolated static func save(_ records: [DiscussionCommentRecord], accountID: AccountID, organizationID: OrganizationID, repositoryID: RepositoryID, observedAt: Date, in database: Database) throws {
        let actors = Dictionary(records.compactMap(\.author).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for actor in actors.values { try ActorRepository.save(actor, observedAtMilliseconds: milliseconds(observedAt), in: database) }
        for record in records {
            try GitHubNodeRepository.save(.init(nodeID: record.nodeID, accountID: accountID, organizationID: organizationID, repositoryID: repositoryID, kind: record.kind, numericID: nil, number: nil, title: record.kind == .discussionComment ? "Discussion comment" : "Discussion reply", state: .unknown, url: record.url, bodyMarkdown: record.body, authorID: record.author?.id, createdAt: record.createdAt, updatedAt: record.updatedAt, closedAt: nil, mergedAt: nil, sourceRevision: record.updatedAt.ISO8601Format(), observedAt: observedAt, accessibility: .accessible), in: database)
            try database.execute(sql: """
                INSERT INTO comments (github_node_id, parent_node_id, author_id, kind, body_markdown, created_at_ms, updated_at_ms, html_url)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(github_node_id) DO UPDATE SET parent_node_id = excluded.parent_node_id, author_id = excluded.author_id, kind = excluded.kind, body_markdown = excluded.body_markdown, created_at_ms = excluded.created_at_ms, updated_at_ms = excluded.updated_at_ms, html_url = excluded.html_url
                """, arguments: [record.nodeID.rawValue, record.parentNodeID.rawValue, record.author?.id.rawValue, record.kind.rawValue, record.body, milliseconds(record.createdAt), milliseconds(record.updatedAt), record.url.absoluteString])
        }
    }

    private nonisolated static func saveRaw(_ pages: [GitHubDiscussionCommentRawPage], scope: SynchronizationScope, accountID: AccountID, discussionNodeID: GitHubNodeID, commentStreamID: SyncStreamID, replyStreamID: SyncStreamID, observedAt: Date, parserVersion: Int, complete: Bool, in database: Database) throws {
        for snapshot in try preparedRaw(pages, scope: scope, accountID: accountID, discussionNodeID: discussionNodeID, commentStreamID: commentStreamID, replyStreamID: replyStreamID, observedAt: observedAt, parserVersion: parserVersion, complete: complete) { try save(snapshot, at: observedAt, in: database) }
    }

    private nonisolated static func preparedRaw(_ pages: [GitHubDiscussionCommentRawPage], scope: SynchronizationScope, accountID: AccountID, discussionNodeID: GitHubNodeID, commentStreamID: SyncStreamID, replyStreamID: SyncStreamID, observedAt: Date, parserVersion: Int, complete: Bool) throws -> [RawAPISnapshot] {
        guard Set(pages.map(\.requestKey)).count == pages.count else { throw DiscussionCommentRepositoryError.invalidRawAuthority }
        try validatePages(pages, discussionNodeID: discussionNodeID, complete: complete)
        return try pages.map { page in
            let parsed = try authority(page, discussionNodeID: discussionNodeID)
            let stream = page.source == .comments ? commentStreamID : replyStreamID
            let identity = ConditionalRequestIdentity(scope: scope, feature: page.source.coverageFeature, streamID: stream, requestKey: page.requestKey)
            return .init(id: snapshotID(identity: identity, payload: page.payload, observedAt: observedAt, parserVersion: parserVersion), accountID: accountID, githubNodeID: parsed.nodeID, endpoint: page.endpoint, eTag: nil, parserVersion: parserVersion, observedAt: observedAt, payload: page.payload, requestIdentity: identity)
        }
    }

    private nonisolated static func validatePages(_ pages: [GitHubDiscussionCommentRawPage], discussionNodeID: GitHubNodeID, complete: Bool) throws {
        let groups = Dictionary(grouping: pages, by: { $0.source == .comments ? "comments" : $0.requestKey.components(separatedBy: "/after=").first! })
        for group in groups.values {
            var expected: String?; var priorHasNext: Bool?
            for (index, page) in group.enumerated() {
                let parsed = try authority(page, discussionNodeID: discussionNodeID)
                guard index == 0 ? parsed.cursor == nil : (priorHasNext == true && parsed.cursor == expected) else { throw DiscussionCommentRepositoryError.invalidRawAuthority }
                do {
                    let info = try pageInfo(page.payload, source: page.source, expectedNodeID: parsed.nodeID)
                    expected = info.endCursor; priorHasNext = info.hasNextPage
                } catch {
                    // An undecodable final response is still immutable failure
                    // evidence. It can never complete coverage or authorize a
                    // conditional replay, but must survive for parser repair.
                    guard !complete, index == group.count - 1 else { throw error }
                    priorHasNext = nil
                }
            }
            if complete, !group.isEmpty, priorHasNext != false { throw DiscussionCommentRepositoryError.invalidRawAuthority }
        }
    }

    private struct Authority { let nodeID: GitHubNodeID; let cursor: String? }
    private nonisolated static func authority(_ page: GitHubDiscussionCommentRawPage, discussionNodeID: GitHubNodeID) throws -> Authority {
        let prefix: String; let nodeID: GitHubNodeID
        switch page.source {
        case .comments: prefix = "graphql:TriageDiscussionComments/discussion=\(discussionNodeID.rawValue)/after="; nodeID = discussionNodeID
        case .replies:
            let marker = "graphql:TriageDiscussionCommentReplies/discussion=\(discussionNodeID.rawValue)/comment="
            guard page.requestKey.hasPrefix(marker), let commentEnd = page.requestKey.range(of: "/after=") else { throw DiscussionCommentRepositoryError.invalidRawAuthority }
            let comment = String(page.requestKey[page.requestKey.index(page.requestKey.startIndex, offsetBy: marker.count)..<commentEnd.lowerBound])
            guard let parsed = GitHubNodeID(rawValue: comment) else { throw DiscussionCommentRepositoryError.invalidRawAuthority }
            prefix = String(page.requestKey[..<commentEnd.lowerBound]) + "/after="; nodeID = parsed
        }
        guard page.requestKey.hasPrefix(prefix), page.payload.count <= RawAPISnapshotRepository.maximumPayloadBytes else { throw DiscussionCommentRepositoryError.invalidRawAuthority }
        let component = String(page.requestKey.dropFirst(prefix.count)); let cursor: String?
        if component == "none" { cursor = nil } else { guard let data = Data(base64Encoded: component), let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw DiscussionCommentRepositoryError.invalidRawAuthority }; cursor = value }
        let endpointBase = page.source == .comments ? "graphql:TriageDiscussionComments/discussion=\(discussionNodeID.rawValue)/page=" : "graphql:TriageDiscussionCommentReplies/discussion=\(discussionNodeID.rawValue)/comment=\(nodeID.rawValue)/page="
        guard page.endpoint.hasPrefix(endpointBase), Int(page.endpoint.dropFirst(endpointBase.count)) != nil else { throw DiscussionCommentRepositoryError.invalidRawAuthority }
        return .init(nodeID: nodeID, cursor: cursor)
    }

    private nonisolated static func pageInfo(_ data: Data, source: GitHubDiscussionCommentSource, expectedNodeID: GitHubNodeID) throws -> (hasNextPage: Bool, endCursor: String?) {
        let connection = try connection(data, source: source, expectedNodeID: expectedNodeID)
        guard let info = connection["pageInfo"] as? [String: Any], let next = info["hasNextPage"] as? Bool else { throw DiscussionCommentRepositoryError.invalidRawAuthority }
        let cursor = info["endCursor"] as? String; guard !next || cursor?.isEmpty == false else { throw DiscussionCommentRepositoryError.invalidRawAuthority }; return (next, cursor)
    }

    private nonisolated static func connectionNodeIDs(
        _ data: Data,
        source: GitHubDiscussionCommentSource,
        expectedNodeID: GitHubNodeID
    ) throws -> Set<GitHubNodeID> {
        let connection = try connection(data, source: source, expectedNodeID: expectedNodeID)
        guard let nodes = connection["nodes"] as? [Any] else {
            throw DiscussionCommentRepositoryError.invalidRawAuthority
        }
        let nodeIDs = try nodes.map { node -> GitHubNodeID in
            guard let object = node as? [String: Any],
                  let rawID = object["id"] as? String,
                  let nodeID = GitHubNodeID(rawValue: rawID)
            else {
                throw DiscussionCommentRepositoryError.invalidRawAuthority
            }
            return nodeID
        }
        guard Set(nodeIDs).count == nodeIDs.count else {
            throw DiscussionCommentRepositoryError.invalidRawAuthority
        }
        return Set(nodeIDs)
    }

    private nonisolated static func connection(
        _ data: Data,
        source: GitHubDiscussionCommentSource,
        expectedNodeID: GitHubNodeID
    ) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["errors"] == nil,
              let payload = root["data"] as? [String: Any],
              let node = payload["node"] as? [String: Any],
              node["id"] as? String == expectedNodeID.rawValue,
              let connection = node[source == .comments ? "comments" : "replies"] as? [String: Any]
        else {
            throw DiscussionCommentRepositoryError.invalidRawAuthority
        }
        return connection
    }

    private nonisolated static func save(_ snapshot: RawAPISnapshot, at date: Date, in database: Database) throws {
        guard let identity = snapshot.requestIdentity else { throw DiscussionCommentRepositoryError.invalidRawAuthority }
        let existing = try Data.fetchAll(database, sql: "SELECT payload FROM raw_api_snapshots WHERE account_id = ? AND authority_organization_id = ? AND authority_feature = ? AND authority_stream_id = ? AND authority_request_key = ? AND authority_credential_revision = ? AND authority_capability_revision = ? AND observed_at_ms = ?", arguments: [snapshot.accountID.rawValue, identity.scope.organizationID.rawValue, identity.feature.rawValue, identity.streamID.rawValue, identity.requestKey, identity.scope.credentialRevision.rawValue, identity.scope.capabilityRevision.rawValue, milliseconds(date)])
        guard existing.allSatisfy({ $0 == snapshot.payload }) else { throw DiscussionCommentRepositoryError.conflictingRawPage }
        try RawAPISnapshotRepository.save(snapshot, in: database)
    }

    private nonisolated static func snapshotID(identity: ConditionalRequestIdentity, payload: Data, observedAt: Date, parserVersion: Int) -> RawAPISnapshotID {
        let payloadDigest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(); let material = [identity.scope.accountID.rawValue, identity.scope.organizationID.rawValue, identity.feature.rawValue, identity.streamID.rawValue, identity.requestKey, identity.scope.credentialRevision.rawValue, identity.scope.capabilityRevision.rawValue, String(milliseconds(observedAt)), String(parserVersion), payloadDigest].joined(separator: "\u{1F}"); let hash = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined(); return RawAPISnapshotID(rawValue: "discussion-comment:\(hash)")!
    }
    private nonisolated static func milliseconds(_ value: Date) -> Int64 { Int64((value.timeIntervalSince1970 * 1_000).rounded()) }
}
