import CryptoKit
import Foundation
import GRDB

enum DiscussionRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationScopeMismatch
    case repositoryScopeMismatch
    case staleSynchronizationScope
    case invalidRawAuthority
    case conflictingRawPage
}

actor DiscussionRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func replace(
        _ discussions: [GitHubDiscussionRecord],
        rawPages: [GitHubDiscussionRawPage],
        scope: SynchronizationScope,
        accountID: AccountID,
        organization: GitHubOrganization,
        repositoryID: RepositoryID,
        repositoryNodeID: GitHubNodeID,
        streamID: SyncStreamID,
        observedAt: Date,
        parserVersion: Int = 1,
        coverageRecords: [CoverageRecord] = []
    ) async throws {
        guard accountID == vault.accountID, scope.accountID == accountID,
              scope.organizationID == organization.id else { throw DiscussionRepositoryError.accountScopeMismatch }
        try await vault.writeTransaction { database in
            try Self.validateCurrentScope(scope, in: database)
            try Self.validateScope(accountID: accountID, organization: organization, repositoryID: repositoryID, repositoryNodeID: repositoryNodeID, in: database)
            try discussions.forEach(Self.validate)
            try Self.saveRaw(
                rawPages, scope: scope, streamID: streamID,
                repositoryNodeID: repositoryNodeID, accountID: accountID,
                requiresCompleteTraversal: true, observedAt: observedAt,
                parserVersion: parserVersion, in: database
            )
            let identifiers = Set(discussions.map(\.nodeID))
            guard identifiers.count == discussions.count else { throw GitHubDiscussionNormalizationError.duplicateDiscussionID }
            for discussion in discussions {
                try GitHubNodeRepository.save(
                    .init(nodeID: discussion.nodeID, accountID: accountID, organizationID: organization.id,
                          repositoryID: repositoryID, kind: .discussion, numericID: nil, number: discussion.number,
                          title: discussion.title, state: discussion.state, url: discussion.url, bodyMarkdown: discussion.body,
                          authorID: nil, createdAt: discussion.createdAt, updatedAt: discussion.updatedAt,
                          closedAt: discussion.closedAt, mergedAt: nil, sourceRevision: discussion.updatedAt.ISO8601Format(),
                          observedAt: observedAt, accessibility: .accessible),
                    in: database
                )
                try database.execute(
                    sql: """
                    INSERT INTO discussions (github_node_id, category_name, answer_comment_node_id, comments_count, updated_at_ms)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(github_node_id) DO UPDATE SET
                      category_name = excluded.category_name, answer_comment_node_id = excluded.answer_comment_node_id,
                      comments_count = excluded.comments_count, updated_at_ms = excluded.updated_at_ms
                    """,
                    arguments: [discussion.nodeID.rawValue, discussion.categoryName, discussion.answerCommentNodeID?.rawValue,
                                discussion.commentsCount, Self.milliseconds(discussion.updatedAt)]
                )
            }
            // A GraphQL inventory omission is not deletion evidence. Physical
            // deletion remains disabled until a source-specific reconciliation
            // contract can prove it for this repository and revision.
            for record in coverageRecords {
                try CoverageRepository.save(
                    record,
                    attemptedAt: observedAt,
                    expectedAccountID: accountID,
                    in: database
                )
            }
        }
    }

    func recordFailedPage(
        _ page: GitHubDiscussionRawPage,
        scope: SynchronizationScope,
        accountID: AccountID,
        organization: GitHubOrganization,
        repositoryID: RepositoryID,
        repositoryNodeID: GitHubNodeID,
        streamID: SyncStreamID,
        observedAt: Date,
        diagnostic: String,
        parserVersion: Int = 1
    ) async throws {
        try await recordFailure(
            pages: [page],
            scope: scope,
            accountID: accountID,
            organization: organization,
            repositoryID: repositoryID,
            repositoryNodeID: repositoryNodeID,
            streamID: streamID,
            observedAt: observedAt,
            diagnostic: diagnostic,
            parserVersion: parserVersion,
            coverageRecord: nil
        )
    }

    /// Stores replay provenance and its scoped coverage transition together.
    /// A failure in either write rolls the whole failure record back, preventing
    /// coverage from claiming evidence that was not retained.
    func recordFailure(
        pages: [GitHubDiscussionRawPage],
        scope: SynchronizationScope,
        accountID: AccountID,
        organization: GitHubOrganization,
        repositoryID: RepositoryID,
        repositoryNodeID: GitHubNodeID,
        streamID: SyncStreamID,
        observedAt: Date,
        diagnostic: String,
        parserVersion: Int = 1,
        coverageRecord: CoverageRecord?
    ) async throws {
        guard accountID == vault.accountID, scope.accountID == accountID,
              scope.organizationID == organization.id else { throw DiscussionRepositoryError.accountScopeMismatch }
        try await vault.writeTransaction { database in
            try Self.validateCurrentScope(scope, in: database)
            try Self.validateScope(accountID: accountID, organization: organization, repositoryID: repositoryID, repositoryNodeID: repositoryNodeID, in: database)
            let snapshots = try Self.preparedRaw(
                pages, scope: scope, streamID: streamID, repositoryNodeID: repositoryNodeID,
                accountID: accountID, requiresCompleteTraversal: false,
                observedAt: observedAt, parserVersion: parserVersion
            )
            for snapshot in snapshots {
                try Self.save(snapshot, rejectingConflictAt: observedAt, in: database)
                try NormalizationFailureRepository.record(
                    .init(id: UUID(), accountID: accountID, rawSnapshotID: snapshot.id, githubNodeID: snapshot.githubNodeID,
                          endpoint: snapshot.endpoint, parserVersion: parserVersion, occurredAt: observedAt,
                          redactedDiagnostic: String(diagnostic.prefix(4_096))),
                    in: database
                )
            }
            if let coverageRecord {
                try CoverageRepository.save(
                    coverageRecord,
                    attemptedAt: observedAt,
                    expectedAccountID: accountID,
                    in: database
                )
            }
        }
    }

    private nonisolated static func validateScope(
        accountID: AccountID, organization: GitHubOrganization, repositoryID: RepositoryID, repositoryNodeID: GitHubNodeID, in database: Database
    ) throws {
        let organizationCount = try Int.fetchOne(database, sql: """
            SELECT COUNT(*) FROM account_organizations
            JOIN organizations ON organizations.id = account_organizations.organization_id
            WHERE account_organizations.account_id = ? AND organizations.id = ?
              AND organizations.github_organization_id = ? AND lower(organizations.login) = lower(?)
            """, arguments: [accountID.rawValue, organization.id.rawValue, String(organization.githubOrganizationID), organization.login]) ?? 0
        guard organizationCount == 1 else { throw DiscussionRepositoryError.organizationScopeMismatch }
        let repositoryCount = try Int.fetchOne(database, sql: """
            SELECT COUNT(*) FROM repositories
            JOIN account_repository_access ON account_repository_access.repository_id = repositories.id
            WHERE repositories.id = ? AND repositories.organization_id = ?
              AND repositories.github_node_id = ?
              AND account_repository_access.account_id = ?
              AND account_repository_access.access_state = 'available'
            """, arguments: [repositoryID.rawValue, organization.id.rawValue, repositoryNodeID.rawValue, accountID.rawValue]) ?? 0
        guard repositoryCount == 1 else { throw DiscussionRepositoryError.repositoryScopeMismatch }
    }

    private nonisolated static func validateCurrentScope(_ scope: SynchronizationScope, in database: Database) throws {
        do {
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
        } catch OrganizationSchedulerStateRepositoryError.staleSynchronizationScope,
                OrganizationSchedulerStateRepositoryError.organizationScopeMismatch {
            throw DiscussionRepositoryError.staleSynchronizationScope
        }
    }

    func validateCurrentScope(_ scope: SynchronizationScope) async throws {
        guard scope.accountID == vault.accountID else { throw DiscussionRepositoryError.accountScopeMismatch }
        try await vault.read { database in
            try Self.validateCurrentScope(scope, in: database)
        }
    }

    private nonisolated static func saveRaw(
        _ pages: [GitHubDiscussionRawPage], scope: SynchronizationScope,
        streamID: SyncStreamID, repositoryNodeID: GitHubNodeID, accountID: AccountID,
        requiresCompleteTraversal: Bool,
        observedAt: Date, parserVersion: Int, in database: Database
    ) throws {
        for snapshot in try preparedRaw(
            pages, scope: scope, streamID: streamID, repositoryNodeID: repositoryNodeID,
            accountID: accountID, requiresCompleteTraversal: requiresCompleteTraversal,
            observedAt: observedAt, parserVersion: parserVersion
        ) {
            try save(snapshot, rejectingConflictAt: observedAt, in: database)
        }
    }

    private nonisolated static func preparedRaw(
        _ pages: [GitHubDiscussionRawPage], scope: SynchronizationScope,
        streamID: SyncStreamID, repositoryNodeID: GitHubNodeID, accountID: AccountID,
        requiresCompleteTraversal: Bool,
        observedAt: Date, parserVersion: Int
    ) throws -> [RawAPISnapshot] {
        guard Set(pages.map(\.requestKey)).count == pages.count else {
            throw DiscussionRepositoryError.invalidRawAuthority
        }
        try validateTraversal(
            pages,
            repositoryNodeID: repositoryNodeID,
            requiresCompleteTraversal: requiresCompleteTraversal
        )
        return try pages.enumerated().map { index, page in
            let pageNumber = index + 1
            guard page.payload.count <= RawAPISnapshotRepository.maximumPayloadBytes,
                  page.endpoint == "graphql:TriageRepositoryDiscussions/repository=\(repositoryNodeID.rawValue)/page=\(pageNumber)",
                  isDiscussionRequestKey(page.requestKey, repositoryNodeID: repositoryNodeID)
            else { throw DiscussionRepositoryError.invalidRawAuthority }
            let identity = ConditionalRequestIdentity(
                scope: scope, feature: .discussions, streamID: streamID, requestKey: page.requestKey
            )
            return RawAPISnapshot(
                id: snapshotID(identity: identity, payload: page.payload, observedAt: observedAt, parserVersion: parserVersion), accountID: accountID,
                githubNodeID: repositoryNodeID, endpoint: page.endpoint, eTag: nil, parserVersion: parserVersion,
                observedAt: observedAt, payload: page.payload, requestIdentity: identity
            )
        }
    }

    private nonisolated static func save(
        _ snapshot: RawAPISnapshot, rejectingConflictAt observedAt: Date, in database: Database
    ) throws {
        guard let identity = snapshot.requestIdentity else { throw DiscussionRepositoryError.invalidRawAuthority }
        let values = try Data.fetchAll(database, sql: """
            SELECT payload FROM raw_api_snapshots
            WHERE account_id = ? AND authority_organization_id = ? AND authority_feature = ?
              AND authority_stream_id = ? AND authority_request_key = ?
              AND authority_credential_revision = ? AND authority_capability_revision = ?
              AND observed_at_ms = ?
            """, arguments: [
                snapshot.accountID.rawValue, identity.scope.organizationID.rawValue, identity.feature.rawValue,
                identity.streamID.rawValue, identity.requestKey, identity.scope.credentialRevision.rawValue,
                identity.scope.capabilityRevision.rawValue, milliseconds(observedAt)
            ])
        guard values.allSatisfy({ $0 == snapshot.payload }) else {
            throw DiscussionRepositoryError.conflictingRawPage
        }
        try RawAPISnapshotRepository.save(snapshot, in: database)
    }

    private nonisolated static func isDiscussionRequestKey(
        _ key: String, repositoryNodeID: GitHubNodeID
    ) -> Bool {
        let prefix = "graphql:TriageRepositoryDiscussions/repository=\(repositoryNodeID.rawValue)/after="
        guard key.hasPrefix(prefix) else { return false }
        let cursor = String(key.dropFirst(prefix.count))
        return cursor == "none" || (Data(base64Encoded: cursor).flatMap { String(data: $0, encoding: .utf8) }?.isEmpty == false)
    }

    private struct DiscussionPageInfo {
        let hasNextPage: Bool
        let endCursor: String?
    }

    private nonisolated static func validateTraversal(
        _ pages: [GitHubDiscussionRawPage],
        repositoryNodeID: GitHubNodeID,
        requiresCompleteTraversal: Bool
    ) throws {
        let prefix = "graphql:TriageRepositoryDiscussions/repository=\(repositoryNodeID.rawValue)/after="
        var priorInfo: DiscussionPageInfo?
        for (offset, page) in pages.enumerated() {
            guard page.requestKey.hasPrefix(prefix) else {
                throw DiscussionRepositoryError.invalidRawAuthority
            }
            let component = String(page.requestKey.dropFirst(prefix.count))
            let cursor: String?
            if component == "none" {
                cursor = nil
            } else {
                guard let data = Data(base64Encoded: component),
                      let decoded = String(data: data, encoding: .utf8),
                      !decoded.isEmpty else {
                    throw DiscussionRepositoryError.invalidRawAuthority
                }
                cursor = decoded
            }
            if offset == 0 {
                guard cursor == nil else { throw DiscussionRepositoryError.invalidRawAuthority }
            } else {
                guard let priorInfo, priorInfo.hasNextPage,
                      let expectedCursor = priorInfo.endCursor,
                      cursor == expectedCursor else {
                    throw DiscussionRepositoryError.invalidRawAuthority
                }
            }
            do {
                priorInfo = try discussionPageInfo(
                    page.payload,
                    expectedRepositoryNodeID: repositoryNodeID
                )
            } catch {
                guard !requiresCompleteTraversal, offset == pages.count - 1 else { throw error }
                priorInfo = nil
            }
        }
        if requiresCompleteTraversal, !pages.isEmpty {
            guard priorInfo?.hasNextPage == false else {
                throw DiscussionRepositoryError.invalidRawAuthority
            }
        }
    }

    private nonisolated static func discussionPageInfo(
        _ payload: Data,
        expectedRepositoryNodeID: GitHubNodeID
    ) throws -> DiscussionPageInfo {
        guard payload.count <= RawAPISnapshotRepository.maximumPayloadBytes,
              let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              root["errors"] == nil,
              let data = root["data"] as? [String: Any],
              let node = data["node"] as? [String: Any],
              node["id"] as? String == expectedRepositoryNodeID.rawValue,
              let discussions = node["discussions"] as? [String: Any],
              let pageInfo = discussions["pageInfo"] as? [String: Any],
              let hasNextPage = pageInfo["hasNextPage"] as? Bool else {
            throw DiscussionRepositoryError.invalidRawAuthority
        }
        let endCursor = pageInfo["endCursor"] as? String
        guard !hasNextPage || endCursor?.isEmpty == false else {
            throw DiscussionRepositoryError.invalidRawAuthority
        }
        return DiscussionPageInfo(hasNextPage: hasNextPage, endCursor: endCursor)
    }

    private nonisolated static func snapshotID(
        identity: ConditionalRequestIdentity, payload: Data, observedAt: Date, parserVersion: Int
    ) -> RawAPISnapshotID {
        let payloadDigest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let material = [identity.scope.accountID.rawValue, identity.scope.organizationID.rawValue,
                        identity.feature.rawValue, identity.streamID.rawValue, identity.requestKey,
                        identity.scope.credentialRevision.rawValue, identity.scope.capabilityRevision.rawValue,
                        String(milliseconds(observedAt)), String(parserVersion), payloadDigest].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return RawAPISnapshotID(rawValue: "discussion:\(digest)")!
    }

    private nonisolated static func validate(_ discussion: GitHubDiscussionRecord) throws {
        guard discussion.number > 0,
              !discussion.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              discussion.createdAt <= discussion.updatedAt,
              discussion.closedAt.map({ $0 >= discussion.createdAt }) ?? true,
              discussion.commentsCount >= 0,
              discussion.url.scheme == "https",
              discussion.url.host == "github.com"
        else {
            throw GitHubDiscussionNormalizationError.invalidDiscussion
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
