import Foundation
import GRDB

enum ReviewCandidateCompleteTraversalReceiptRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case staleSynchronizationScope
    case invalidFeature
    case invalidStream
    case invalidCandidateScope
    case staleCandidateSourceRevision
    case invalidTraversal
    case invalidRawPage
    case immutableReceiptConflict
    case invalidReceiptToken
}

/// Persists append-only proof that every source segment needed to replace a
/// review candidate's normalized children reached a terminal page. Callers
/// keep this in the same transaction as their raw, normalized, pruning, and
/// fair-schedule mutations; this type intentionally performs none of those
/// destructive mutations itself.
actor ReviewCandidateCompleteTraversalReceiptRepository {
    static let normalizedDigestLength = 32
    static let maximumEndpointLength = 2_048
    static let maximumSourceRevisionLength = 500

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func persist(
        _ traversal: ReviewCandidateCompleteTraversal
    ) async throws -> ReviewCandidateCompleteTraversalReceiptToken {
        guard traversal.scope.accountID == vault.accountID else {
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.accountScopeMismatch
        }
        return try await vault.writeTransaction { database in
            try Self.persist(traversal, in: database)
        }
    }

    /// Use this within the caller's publication transaction. Any raw snapshot
    /// conflict or receipt validation failure rolls back the entire caller
    /// transaction, including later normalization/pruning work.
    nonisolated static func persist(
        _ traversal: ReviewCandidateCompleteTraversal,
        in database: Database
    ) throws -> ReviewCandidateCompleteTraversalReceiptToken {
        try validate(traversal, in: database)
        let token = token(for: traversal)
        let receiptID = token.id.uuidString.lowercased()
        if let row = try Row.fetchOne(
            database,
            sql: "SELECT id FROM review_candidate_complete_traversal_receipts WHERE id = ?",
            arguments: [receiptID]
        ) {
            guard try persistedReceiptMatches(traversal, row: row, in: database) else {
                throw ReviewCandidateCompleteTraversalReceiptRepositoryError.immutableReceiptConflict
            }
            return token
        }

        for segment in traversal.segments {
            for page in segment.pages {
                try RawAPISnapshotRepository.save(
                    RawAPISnapshot(
                        id: page.rawSnapshotID,
                        accountID: traversal.scope.accountID,
                        githubNodeID: traversal.candidate.nodeID,
                        endpoint: page.endpoint,
                        eTag: page.eTag,
                        lastModified: page.lastModified,
                        parserVersion: traversal.parserVersion,
                        observedAt: traversal.observedAt,
                        payload: page.payload,
                        requestIdentity: page.requestIdentity
                    ),
                    in: database
                )
            }
        }

        try database.execute(
            sql: """
                INSERT INTO review_candidate_complete_traversal_receipts (
                    id, account_id, organization_id, feature, stream_id,
                    candidate_node_id, repository_id, candidate_source_revision,
                    credential_revision, capability_revision, parser_version,
                    observed_at_ms, normalized_digest, segment_count, page_count
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                receiptID, traversal.scope.accountID.rawValue,
                traversal.scope.organizationID.rawValue, traversal.feature.rawValue,
                traversal.streamID.rawValue, traversal.candidate.nodeID.rawValue,
                traversal.candidate.repositoryID.rawValue, traversal.candidateSourceRevision,
                traversal.scope.credentialRevision.rawValue, traversal.scope.capabilityRevision.rawValue,
                traversal.parserVersion, milliseconds(traversal.observedAt), traversal.normalizedDigest,
                traversal.segments.count, traversal.segments.reduce(0) { $0 + $1.pages.count }
            ]
        )
        for segment in traversal.segments {
            let key = segmentKey(segment)
            try database.execute(
                sql: """
                    INSERT INTO review_candidate_complete_traversal_segments (
                        receipt_id, segment_key, segment_kind, parent_thread_node_id,
                        page_count, terminal_page_ordinal
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    receiptID, key, segment.kind.rawValue, segment.parentThreadNodeID?.rawValue,
                    segment.pages.count, segment.pages.count
                ]
            )
            for page in segment.pages {
                try database.execute(
                    sql: """
                        INSERT INTO review_candidate_complete_traversal_pages (
                            receipt_id, segment_key, page_ordinal, raw_snapshot_id, request_key, is_terminal
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        receiptID, key, page.ordinal, page.rawSnapshotID.rawValue,
                        page.requestIdentity.requestKey, page.isTerminal ? 1 : 0
                    ]
                )
            }
        }
        return token
    }

    /// Rechecks the persisted proof before a repository deletes stale review
    /// rows. This detects authority rotation, source changes, missing raw
    /// bindings, and receipt substitution without granting any delete rights.
    nonisolated static func validate(
        _ token: ReviewCandidateCompleteTraversalReceiptToken,
        in database: Database
    ) throws {
        do {
            try OrganizationSchedulerStateRepository.validateCurrentScope(token.scope, in: database)
        } catch OrganizationSchedulerStateRepositoryError.staleSynchronizationScope,
                OrganizationSchedulerStateRepositoryError.organizationScopeMismatch {
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.staleSynchronizationScope
        }
        guard token.feature == .reviews || token.feature == .reviewThreads else {
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidFeature
        }
        let rowCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM review_candidate_complete_traversal_receipts
                WHERE id = ? AND account_id = ? AND organization_id = ? AND feature = ? AND stream_id = ?
                  AND candidate_node_id = ? AND repository_id = ? AND candidate_source_revision = ?
                  AND credential_revision = ? AND capability_revision = ?
                """,
            arguments: [
                token.id.uuidString.lowercased(), token.scope.accountID.rawValue,
                token.scope.organizationID.rawValue, token.feature.rawValue, token.streamID.rawValue,
                token.candidateNodeID.rawValue, token.repositoryID.rawValue, token.candidateSourceRevision,
                token.scope.credentialRevision.rawValue, token.scope.capabilityRevision.rawValue
            ]
        ) ?? 0
        guard rowCount == 1 else {
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidReceiptToken
        }
        try validateCandidate(
            nodeID: token.candidateNodeID,
            repositoryID: token.repositoryID,
            sourceRevision: token.candidateSourceRevision,
            scope: token.scope,
            in: database
        )
        let rawBindingCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM review_candidate_complete_traversal_pages pages
                JOIN raw_api_snapshots raw ON raw.id = pages.raw_snapshot_id
                JOIN review_candidate_complete_traversal_receipts receipt
                  ON receipt.id = pages.receipt_id
                WHERE pages.receipt_id = ? AND raw.account_id = ? AND raw.github_node_id = ?
                  AND raw.authority_organization_id = ? AND raw.authority_feature = ?
                  AND raw.authority_stream_id = ? AND raw.authority_credential_revision = ?
                  AND raw.authority_capability_revision = ?
                  AND raw.authority_request_key = pages.request_key
                  AND raw.parser_version = receipt.parser_version
                """,
            arguments: [
                token.id.uuidString.lowercased(), token.scope.accountID.rawValue, token.candidateNodeID.rawValue,
                token.scope.organizationID.rawValue, token.feature.rawValue, token.streamID.rawValue,
                token.scope.credentialRevision.rawValue, token.scope.capabilityRevision.rawValue
            ]
        ) ?? 0
        let expectedPageCount = try Int.fetchOne(
            database,
            sql: "SELECT page_count FROM review_candidate_complete_traversal_receipts WHERE id = ?",
            arguments: [token.id.uuidString.lowercased()]
        ) as Int? ?? -1
        guard rawBindingCount == expectedPageCount else {
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidReceiptToken
        }
        let segments = try Row.fetchAll(
            database,
            sql: """
                SELECT segments.page_count, segments.terminal_page_ordinal,
                       COUNT(pages.page_ordinal) AS actual_count,
                       MIN(pages.page_ordinal) AS first_ordinal,
                       MAX(pages.page_ordinal) AS last_ordinal,
                       SUM(pages.is_terminal) AS terminal_count,
                       MAX(CASE WHEN pages.is_terminal = 1 THEN pages.page_ordinal ELSE 0 END) AS terminal_ordinal
                FROM review_candidate_complete_traversal_segments segments
                LEFT JOIN review_candidate_complete_traversal_pages pages
                  ON pages.receipt_id = segments.receipt_id AND pages.segment_key = segments.segment_key
                WHERE segments.receipt_id = ?
                GROUP BY segments.receipt_id, segments.segment_key
                """,
            arguments: [token.id.uuidString.lowercased()]
        )
        guard !segments.isEmpty, segments.allSatisfy({ row in
            let expected: Int? = row["page_count"]
            let terminalExpected: Int? = row["terminal_page_ordinal"]
            let actual: Int? = row["actual_count"]
            let first: Int? = row["first_ordinal"]
            let last: Int? = row["last_ordinal"]
            let terminalCount: Int? = row["terminal_count"]
            let terminalOrdinal: Int? = row["terminal_ordinal"]
            return expected != nil && expected! > 0 && terminalExpected == expected
                && actual == expected && first == 1 && last == expected
                && terminalCount == 1 && terminalOrdinal == expected
        }) else {
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidReceiptToken
        }
        try validatePersistedTopology(token, in: database)
    }

    /// Rebuilds the persisted receipt from its immutable raw bindings before
    /// permitting a destructive replacement. This rejects count-preserving
    /// corruption of segment kinds, request keys, endpoints, or GraphQL page
    /// topology even if a database predates append-only receipt triggers.
    private nonisolated static func validatePersistedTopology(
        _ token: ReviewCandidateCompleteTraversalReceiptToken,
        in database: Database
    ) throws {
        guard let candidateRow = try Row.fetchOne(
            database,
            sql: """
                SELECT repositories.owner_login, repositories.name, github_nodes.number
                FROM github_nodes
                JOIN repositories ON repositories.id = github_nodes.repository_id
                WHERE github_nodes.github_node_id = ? AND github_nodes.repository_id = ?
                """,
            arguments: [token.candidateNodeID.rawValue, token.repositoryID.rawValue]
        ),
        let owner: String = candidateRow["owner_login"],
        let repository: String = candidateRow["name"],
        let number: Int = candidateRow["number"],
        let repositoryPath = try? GitHubRepositoryPath(owner: owner, repository: repository),
        let receiptRow = try Row.fetchOne(
            database,
            sql: "SELECT parser_version, observed_at_ms, normalized_digest FROM review_candidate_complete_traversal_receipts WHERE id = ?",
            arguments: [token.id.uuidString.lowercased()]
        ),
        let parserVersion: Int = receiptRow["parser_version"],
        let observedAtMilliseconds: Int64 = receiptRow["observed_at_ms"],
        let normalizedDigest: Data = receiptRow["normalized_digest"]
        else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidReceiptToken }

        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT segments.segment_key, segments.segment_kind, segments.parent_thread_node_id,
                       pages.page_ordinal, pages.raw_snapshot_id, pages.request_key, pages.is_terminal,
                       raw.endpoint, raw.etag, raw.last_modified, raw.payload
                FROM review_candidate_complete_traversal_segments segments
                JOIN review_candidate_complete_traversal_pages pages
                  ON pages.receipt_id = segments.receipt_id AND pages.segment_key = segments.segment_key
                JOIN raw_api_snapshots raw ON raw.id = pages.raw_snapshot_id
                WHERE segments.receipt_id = ?
                ORDER BY segments.segment_key, pages.page_ordinal
                """,
            arguments: [token.id.uuidString.lowercased()]
        )
        let grouped = Dictionary(grouping: rows) { (row: Row) -> String? in row["segment_key"] }
        guard !grouped.isEmpty, !grouped.keys.contains(nil) else {
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidReceiptToken
        }
        let scope = token.scope
        let reconstructed = try grouped.values.map { rows -> ReviewCandidateTraversalSegment in
            guard let first = rows.first,
                  let key: String = first["segment_key"],
                  let kindValue: String = first["segment_kind"],
                  let kind = ReviewCandidateTraversalSegmentKind(rawValue: kindValue)
            else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidReceiptToken }
            let parentValue: String? = first["parent_thread_node_id"]
            let parent = parentValue.flatMap(GitHubNodeID.init(rawValue:))
            guard (parentValue == nil) == (parent == nil), key == segmentKey(kind: kind, parentThreadNodeID: parent) else {
                throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidReceiptToken
            }
            let pages = try rows.map { row -> ReviewCandidateTraversalPage in
                guard let ordinal: Int = row["page_ordinal"],
                      let rawValue: String = row["raw_snapshot_id"], let rawSnapshotID = RawAPISnapshotID(rawValue: rawValue),
                      let requestKey: String = row["request_key"],
                      let terminal: Int = row["is_terminal"], terminal == 0 || terminal == 1,
                      let endpoint: String = row["endpoint"],
                      let payload: Data = row["payload"]
                else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidReceiptToken }
                let eTag: String? = row["etag"]
                let lastModified: String? = row["last_modified"]
                return .init(
                    ordinal: ordinal, rawSnapshotID: rawSnapshotID,
                    requestIdentity: .init(scope: scope, feature: token.feature, streamID: token.streamID, requestKey: requestKey),
                    endpoint: endpoint, eTag: eTag, lastModified: lastModified, payload: payload,
                    isTerminal: terminal == 1
                )
            }
            return .init(kind: kind, parentThreadNodeID: parent, pages: pages)
        }
        let candidate = PullRequestReviewCandidate(
            nodeID: token.candidateNodeID, repositoryID: token.repositoryID,
            repository: repositoryPath, number: number, sourceRevision: token.candidateSourceRevision
        )
        var discoveredCommentNodeIDsByThread = [GitHubNodeID: [GitHubNodeID]]()
        if token.feature == .reviewThreads {
            for segment in reconstructed where segment.kind == .threadComments {
                guard let threadNodeID = segment.parentThreadNodeID,
                      discoveredCommentNodeIDsByThread[threadNodeID] == nil
                else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidReceiptToken }
                let commentNodeIDs = try segment.pages.flatMap { page -> [GitHubNodeID] in
                    guard let evidence = graphQLCommentEvidence(
                        page.payload,
                        threadNodeID: threadNodeID
                    ) else {
                        throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidReceiptToken
                    }
                    return evidence.commentNodeIDs
                }
                discoveredCommentNodeIDsByThread[threadNodeID] = commentNodeIDs
            }
        }
        let traversal = ReviewCandidateCompleteTraversal(
            id: token.id, scope: scope, feature: token.feature, streamID: token.streamID,
            candidate: candidate, candidateSourceRevision: token.candidateSourceRevision,
            parserVersion: parserVersion,
            observedAt: Date(timeIntervalSince1970: TimeInterval(observedAtMilliseconds) / 1_000),
            normalizedDigest: normalizedDigest,
            discoveredThreadNodeIDs: reconstructed.compactMap { segment in
                segment.kind == .threadComments ? segment.parentThreadNodeID : nil
            },
            discoveredCommentNodeIDsByThread: discoveredCommentNodeIDsByThread,
            segments: reconstructed
        )
        do {
            try validateTopology(traversal)
        } catch {
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidReceiptToken
        }
    }

    private nonisolated static func validate(
        _ traversal: ReviewCandidateCompleteTraversal,
        in database: Database
    ) throws {
        guard traversal.feature == .reviews || traversal.feature == .reviewThreads else {
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidFeature
        }
        guard traversal.parserVersion > 0,
              traversal.candidateSourceRevision.count > 0,
              traversal.candidateSourceRevision.count <= maximumSourceRevisionLength,
              traversal.observedAt.timeIntervalSinceReferenceDate.isFinite,
              traversal.normalizedDigest.count == normalizedDigestLength
        else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidTraversal }
        do {
            try OrganizationSchedulerStateRepository.validateCurrentScope(traversal.scope, in: database)
        } catch OrganizationSchedulerStateRepositoryError.staleSynchronizationScope,
                OrganizationSchedulerStateRepositoryError.organizationScopeMismatch {
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.staleSynchronizationScope
        }
        let streamCount = try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM sync_streams WHERE id = ? AND account_id = ? AND organization_id = ? AND feature = ?",
            arguments: [traversal.streamID.rawValue, traversal.scope.accountID.rawValue,
                        traversal.scope.organizationID.rawValue, traversal.feature.rawValue]
        ) ?? 0
        guard streamCount == 1 else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidStream }
        try validateCandidate(
            nodeID: traversal.candidate.nodeID, repositoryID: traversal.candidate.repositoryID,
            sourceRevision: traversal.candidateSourceRevision, scope: traversal.scope,
            candidate: traversal.candidate, in: database
        )
        try validateTopology(traversal)
    }

    private nonisolated static func validateCandidate(
        nodeID: GitHubNodeID,
        repositoryID: RepositoryID,
        sourceRevision: String,
        scope: SynchronizationScope,
        candidate: PullRequestReviewCandidate? = nil,
        in database: Database
    ) throws {
        var sql = """
            SELECT COUNT(*) FROM pull_requests
            JOIN github_nodes ON github_nodes.github_node_id = pull_requests.github_node_id
            JOIN repositories ON repositories.id = github_nodes.repository_id
            JOIN account_repository_access ON account_repository_access.repository_id = repositories.id
            WHERE github_nodes.github_node_id = ? AND github_nodes.account_id = ?
              AND github_nodes.organization_id = ? AND github_nodes.repository_id = ?
              AND github_nodes.source_revision = ? AND github_nodes.accessibility_state = 'accessible'
              AND account_repository_access.account_id = ? AND account_repository_access.access_state = 'available'
            """
        var arguments: [DatabaseValueConvertible?] = [
            nodeID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue,
            repositoryID.rawValue, sourceRevision, scope.accountID.rawValue
        ]
        if let candidate {
            sql += " AND repositories.owner_login = ? AND repositories.name = ? AND github_nodes.number = ?"
            arguments += [candidate.repository.owner, candidate.repository.repository, candidate.number]
        }
        let count = try Int.fetchOne(database, sql: sql, arguments: StatementArguments(arguments)) ?? 0
        guard count == 1 else {
            // A matching candidate with changed source data is materially different from a bad path.
            let exists = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM github_nodes WHERE github_node_id = ? AND account_id = ?",
                arguments: [nodeID.rawValue, scope.accountID.rawValue]
            ) ?? 0
            throw exists == 1
                ? ReviewCandidateCompleteTraversalReceiptRepositoryError.staleCandidateSourceRevision
                : ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidCandidateScope
        }
    }

    private nonisolated static func validateTopology(_ traversal: ReviewCandidateCompleteTraversal) throws {
        guard Set(traversal.discoveredThreadNodeIDs).count == traversal.discoveredThreadNodeIDs.count,
              Set(traversal.segments.map(segmentKey)).count == traversal.segments.count,
              Set(traversal.segments.flatMap(\.pages).map(\.rawSnapshotID)).count
                == traversal.segments.reduce(0, { $0 + $1.pages.count })
        else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidTraversal }

        for segment in traversal.segments {
            let requiresParent = segment.kind == .threadComments
            guard requiresParent == (segment.parentThreadNodeID != nil),
                  !segment.pages.isEmpty,
                  segment.pages.map(\.ordinal) == Array(1...segment.pages.count),
                  segment.pages.enumerated().allSatisfy({ offset, page in
                      page.isTerminal == (offset == segment.pages.count - 1)
                  })
            else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidTraversal }
            for page in segment.pages {
                guard page.requestIdentity.scope == traversal.scope,
                      page.requestIdentity.feature == traversal.feature,
                      page.requestIdentity.streamID == traversal.streamID,
                      !page.requestIdentity.requestKey.isEmpty,
                      page.requestIdentity.requestKey.count <= 2_048,
                      !page.endpoint.isEmpty, page.endpoint.count <= maximumEndpointLength,
                      !page.endpoint.contains("\r"), !page.endpoint.contains("\n"),
                      page.payload.count <= RawAPISnapshotRepository.maximumPayloadBytes
                else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidRawPage }
            }
        }
        switch traversal.feature {
        case .reviews:
            guard traversal.discoveredThreadNodeIDs.isEmpty,
                  traversal.discoveredCommentNodeIDsByThread.isEmpty,
                  traversal.segments.count == 2,
                  traversal.segments.contains(where: { $0.kind == .reviewHistory && $0.parentThreadNodeID == nil }),
                  let requested = traversal.segments.first(where: { $0.kind == .requestedReviewers }),
                  requested.parentThreadNodeID == nil, requested.pages.count == 1
            else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidTraversal }
            guard let reviews = traversal.segments.first(where: { $0.kind == .reviewHistory }) else {
                throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidTraversal
            }
            try validateRESTReviewPages(reviews.pages, candidate: traversal.candidate)
            try validateRESTRequestedReviewerPage(requested.pages[0], candidate: traversal.candidate)
        case .reviewThreads:
            let roots = traversal.segments.filter { $0.kind == .reviewThreads && $0.parentThreadNodeID == nil }
            let comments = traversal.segments.filter { $0.kind == .threadComments }
            guard roots.count == 1,
                  Set(comments.compactMap(\.parentThreadNodeID)) == Set(traversal.discoveredThreadNodeIDs),
                  comments.count == traversal.discoveredThreadNodeIDs.count,
                  Set(traversal.discoveredCommentNodeIDsByThread.keys) == Set(traversal.discoveredThreadNodeIDs),
                  traversal.discoveredCommentNodeIDsByThread.values.flatMap({ $0 }).count
                    == Set(traversal.discoveredCommentNodeIDsByThread.values.flatMap({ $0 })).count,
                  !traversal.segments.contains(where: { $0.kind == .reviewHistory || $0.kind == .requestedReviewers })
            else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidTraversal }
            try validateGraphQLThreadTopology(
                rootPages: roots[0].pages,
                commentSegments: comments,
                candidateNodeID: traversal.candidate.nodeID,
                discoveredThreadNodeIDs: traversal.discoveredThreadNodeIDs,
                discoveredCommentNodeIDsByThread: traversal.discoveredCommentNodeIDsByThread
            )
        default:
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidFeature
        }
    }

    private nonisolated static func validateRESTReviewPages(
        _ pages: [ReviewCandidateTraversalPage],
        candidate: PullRequestReviewCandidate
    ) throws {
        let path = "\(candidate.repository.path)/pulls/\(candidate.number)/reviews"
        for page in pages {
            guard page.endpoint == page.requestIdentity.requestKey else {
                throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidRawPage
            }
            if page.ordinal == 1 {
                guard page.requestIdentity.requestKey == "GET \(path)?per_page=100" else {
                    throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidRawPage
                }
                continue
            }
            guard let components = RESTRequestComponents(page.requestIdentity.requestKey),
                  components.percentEncodedPath == path,
                  components.fragment == nil,
                  components.user == nil, components.password == nil,
                  components.queryItems?.count == 2,
                  components.queryItems?.filter({ $0.name == "per_page" }).map(\.value) == ["100"],
                  components.queryItems?.filter({ $0.name == "page" }).map(\.value) == [String(page.ordinal)]
            else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidRawPage }
        }
    }

    private nonisolated static func validateRESTRequestedReviewerPage(
        _ page: ReviewCandidateTraversalPage,
        candidate: PullRequestReviewCandidate
    ) throws {
        let expected = "GET \(candidate.repository.path)/pulls/\(candidate.number)/requested_reviewers"
        guard page.endpoint == expected, page.requestIdentity.requestKey == expected else {
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidRawPage
        }
    }

    private nonisolated static func RESTRequestComponents(_ requestKey: String) -> URLComponents? {
        guard requestKey.hasPrefix("GET /") else { return nil }
        return URLComponents(string: "https://api.github.com" + requestKey.dropFirst(4))
    }

    private nonisolated static func validateGraphQLThreadTopology(
        rootPages: [ReviewCandidateTraversalPage],
        commentSegments: [ReviewCandidateTraversalSegment],
        candidateNodeID: GitHubNodeID,
        discoveredThreadNodeIDs: [GitHubNodeID],
        discoveredCommentNodeIDsByThread: [GitHubNodeID: [GitHubNodeID]]
    ) throws {
        guard Set(rootPages.map(\.requestIdentity.requestKey)).count == rootPages.count else {
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidRawPage
        }
        var payloadThreadIDs = Set<GitHubNodeID>()
        var expectedRootCursor: String? = ""
        for page in rootPages {
            let expectedEndpoint = "graphql:TriagePullRequestReviewThreads/page=\(page.ordinal)"
            guard page.endpoint == expectedEndpoint,
                  graphQLCursorRequest(
                    page.requestIdentity.requestKey,
                    prefix: "graphql:TriagePullRequestReviewThreads/pull-request=\(candidateNodeID.rawValue)/after="
                  ) == expectedRootCursor,
                  let evidence = graphQLRootEvidence(page.payload, candidateNodeID: candidateNodeID),
                  evidence.pageInfo.isTerminal == page.isTerminal
            else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidRawPage }
            payloadThreadIDs.formUnion(evidence.threadIDs)
            expectedRootCursor = evidence.pageInfo.endCursor
        }
        guard payloadThreadIDs == Set(discoveredThreadNodeIDs) else {
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidTraversal
        }
        for segment in commentSegments {
            guard let threadNodeID = segment.parentThreadNodeID,
                  let expectedCommentNodeIDs = discoveredCommentNodeIDsByThread[threadNodeID],
                  Set(segment.pages.map(\.requestIdentity.requestKey)).count == segment.pages.count
            else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidTraversal }
            var expectedCommentCursor: String? = ""
            var payloadCommentNodeIDs = [GitHubNodeID]()
            for page in segment.pages {
                let expectedEndpoint = "graphql:TriagePullRequestReviewThreadComments/thread=\(threadNodeID.rawValue)/page=\(page.ordinal)"
                guard page.endpoint == expectedEndpoint,
                      graphQLCursorRequest(
                        page.requestIdentity.requestKey,
                        prefix: "graphql:TriagePullRequestReviewThreadComments/thread=\(threadNodeID.rawValue)/after="
                      ) == expectedCommentCursor,
                      let evidence = graphQLCommentEvidence(page.payload, threadNodeID: threadNodeID),
                      evidence.pageInfo.isTerminal == page.isTerminal
                else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidRawPage }
                payloadCommentNodeIDs.append(contentsOf: evidence.commentNodeIDs)
                expectedCommentCursor = evidence.pageInfo.endCursor
            }
            guard payloadCommentNodeIDs.count == expectedCommentNodeIDs.count,
                  Set(payloadCommentNodeIDs) == Set(expectedCommentNodeIDs)
            else { throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidTraversal }
        }
    }

    private nonisolated static func graphQLCursorRequest(_ value: String, prefix: String) -> String? {
        guard value.hasPrefix(prefix) else { return nil }
        let cursor = String(value.dropFirst(prefix.count))
        guard cursor != "none" else { return "" }
        guard let data = Data(base64Encoded: cursor),
              let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty
        else { return nil }
        return decoded
    }

    private nonisolated static func graphQLRootEvidence(
        _ payload: Data,
        candidateNodeID: GitHubNodeID
    ) -> GraphQLRootEvidence? {
        guard let node = graphQLNode(payload),
              node["id"] as? String == candidateNodeID.rawValue,
              let connection = node["reviewThreads"] as? [String: Any],
              let nodes = connection["nodes"] as? [[String: Any]],
              let pageInfo = graphQLPageInfo(connection["pageInfo"])
        else { return nil }
        let identifiers = nodes.compactMap { $0["id"] as? String }.compactMap(GitHubNodeID.init(rawValue:))
        guard identifiers.count == nodes.count else { return nil }
        return .init(threadIDs: Set(identifiers), pageInfo: pageInfo)
    }

    private nonisolated static func graphQLCommentEvidence(
        _ payload: Data,
        threadNodeID: GitHubNodeID
    ) -> GraphQLCommentEvidence? {
        guard let node = graphQLNode(payload),
              node["id"] as? String == threadNodeID.rawValue,
              let comments = node["comments"] as? [String: Any],
              let nodes = comments["nodes"] as? [[String: Any]],
              let pageInfo = graphQLPageInfo(comments["pageInfo"])
        else { return nil }
        let identifiers = nodes.compactMap { $0["id"] as? String }.compactMap(GitHubNodeID.init(rawValue:))
        guard identifiers.count == nodes.count else { return nil }
        return .init(commentNodeIDs: identifiers, pageInfo: pageInfo)
    }

    private nonisolated static func graphQLPageInfo(_ value: Any?) -> GraphQLPageInfo? {
        guard let value = value as? [String: Any],
              let hasNextPage = value["hasNextPage"] as? Bool
        else { return nil }
        let endCursor = value["endCursor"] as? String
        guard hasNextPage ? endCursor?.isEmpty == false : true else { return nil }
        return .init(hasNextPage: hasNextPage, endCursor: endCursor)
    }

    private nonisolated static func graphQLNode(_ payload: Data) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let node = data["node"] as? [String: Any]
        else { return nil }
        return node
    }

    private struct GraphQLPageInfo {
        let hasNextPage: Bool
        let endCursor: String?

        var isTerminal: Bool { !hasNextPage }
    }

    private struct GraphQLRootEvidence {
        let threadIDs: Set<GitHubNodeID>
        let pageInfo: GraphQLPageInfo
    }

    private struct GraphQLCommentEvidence {
        let commentNodeIDs: [GitHubNodeID]
        let pageInfo: GraphQLPageInfo
    }

    private nonisolated static func persistedReceiptMatches(
        _ traversal: ReviewCandidateCompleteTraversal,
        row: Row,
        in database: Database
    ) throws -> Bool {
        // The receipt identifier is immutable. Validate its complete token and
        // compare all count-bearing fields before accepting an idempotent retry.
        let token = token(for: traversal)
        try validate(token, in: database)
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM review_candidate_complete_traversal_receipts
                WHERE id = ? AND parser_version = ? AND observed_at_ms = ?
                  AND normalized_digest = ? AND segment_count = ? AND page_count = ?
                """,
            arguments: [token.id.uuidString.lowercased(), traversal.parserVersion,
                        milliseconds(traversal.observedAt), traversal.normalizedDigest,
                        traversal.segments.count, traversal.segments.reduce(0) { $0 + $1.pages.count }]
        ) ?? 0
        guard count == 1 else { return false }
        let persisted = try Row.fetchAll(
            database,
            sql: "SELECT segment_key, page_ordinal, raw_snapshot_id, request_key, is_terminal FROM review_candidate_complete_traversal_pages WHERE receipt_id = ? ORDER BY segment_key, page_ordinal",
            arguments: [token.id.uuidString.lowercased()]
        )
        let expected = traversal.segments.flatMap { segment in
            segment.pages.map { (segmentKey(segment), $0.ordinal, $0.rawSnapshotID.rawValue, $0.requestIdentity.requestKey, $0.isTerminal ? 1 : 0) }
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        guard persisted.count == expected.count else { return false }
        return zip(persisted, expected).allSatisfy { row, expected in
            let key: String? = row["segment_key"]
            let ordinal: Int? = row["page_ordinal"]
            let rawID: String? = row["raw_snapshot_id"]
            let requestKey: String? = row["request_key"]
            let terminal: Int? = row["is_terminal"]
            return key == expected.0 && ordinal == expected.1 && rawID == expected.2
                && requestKey == expected.3 && terminal == expected.4
        }
    }

    private nonisolated static func token(
        for traversal: ReviewCandidateCompleteTraversal
    ) -> ReviewCandidateCompleteTraversalReceiptToken {
        .init(id: traversal.id, scope: traversal.scope, feature: traversal.feature,
              streamID: traversal.streamID, candidateNodeID: traversal.candidate.nodeID,
              repositoryID: traversal.candidate.repositoryID,
              candidateSourceRevision: traversal.candidateSourceRevision)
    }

    private nonisolated static func segmentKey(_ segment: ReviewCandidateTraversalSegment) -> String {
        segmentKey(kind: segment.kind, parentThreadNodeID: segment.parentThreadNodeID)
    }

    private nonisolated static func segmentKey(
        kind: ReviewCandidateTraversalSegmentKind,
        parentThreadNodeID: GitHubNodeID?
    ) -> String {
        switch kind {
        case .threadComments:
            guard let parentThreadNodeID else { return "" }
            return "threadComments:\(parentThreadNodeID.rawValue)"
        default:
            return kind.rawValue
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
