import Foundation
import GRDB

enum ReviewCandidateFailureEnvelopeRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case staleSynchronizationScope
    case invalidFeature
    case invalidRequestIdentity
    case invalidCandidateScope
    case invalidParserVersion
    case invalidAttemptTimes
    case invalidRedactedDiagnostic
    case invalidRawPages
    case immutableEnvelopeConflict
    case invalidPersistedData
}

/// Durable, append-only provenance for failed REST review and GraphQL review
/// thread candidate traversals. Publication saves all accumulated raw pages,
/// the attempted and terminal evidence, and the fair-scheduler cursor in one
/// transaction. It deliberately has no header parameters or header columns.
actor ReviewCandidateFailureEnvelopeRepository {
    static let maximumDiagnosticLength = 4_096
    static let maximumEndpointLength = 2_048

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func publish(
        _ publication: ReviewCandidateFailurePublication,
        advanceSchedule: Bool = true
    ) async throws {
        guard publication.scope.accountID == vault.accountID else {
            throw ReviewCandidateFailureEnvelopeRepositoryError.accountScopeMismatch
        }
        try await vault.writeTransaction { database in
            try Self.publish(publication, advanceSchedule: advanceSchedule, in: database)
        }
    }

    /// Use this form from a caller-owned normalized or coverage transaction.
    /// If any raw page, envelope, or scheduling mutation fails, GRDB rolls the
    /// entire attempted/terminal publication back.
    nonisolated static func publish(
        _ publication: ReviewCandidateFailurePublication,
        advanceSchedule: Bool = true,
        in database: Database
    ) throws {
        try validate(publication, in: database)

        if let existing = try Row.fetchOne(
            database,
            sql: "SELECT * FROM review_candidate_failure_envelopes WHERE id = ?",
            arguments: [publication.id.uuidString.lowercased()]
        ) {
            guard try matchesPersistedPublication(existing, publication: publication, in: database) else {
                throw ReviewCandidateFailureEnvelopeRepositoryError.immutableEnvelopeConflict
            }
            return
        }

        for page in publication.rawPages {
            try RawAPISnapshotRepository.save(
                RawAPISnapshot(
                    id: page.rawSnapshotID,
                    accountID: publication.scope.accountID,
                    githubNodeID: publication.candidate.nodeID,
                    endpoint: page.endpoint,
                    eTag: page.eTag,
                    lastModified: page.lastModified,
                    parserVersion: publication.parserVersion,
                    observedAt: publication.terminalAt,
                    payload: page.payload,
                    requestIdentity: page.requestIdentity
                ),
                in: database
            )
        }

        try database.execute(
            sql: """
                INSERT INTO review_candidate_failure_envelopes (
                    id, account_id, organization_id, feature, stream_id,
                    candidate_node_id, repository_id, request_key,
                    credential_revision, capability_revision, parser_version,
                    attempted_at_ms, terminal_at_ms, classification,
                    redacted_diagnostic, raw_page_count
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                publication.id.uuidString.lowercased(),
                publication.scope.accountID.rawValue,
                publication.scope.organizationID.rawValue,
                publication.feature.rawValue,
                publication.streamID.rawValue,
                publication.candidate.nodeID.rawValue,
                publication.candidate.repositoryID.rawValue,
                publication.requestIdentity.requestKey,
                publication.scope.credentialRevision.rawValue,
                publication.scope.capabilityRevision.rawValue,
                publication.parserVersion,
                milliseconds(publication.attemptedAt),
                milliseconds(publication.terminalAt),
                publication.classification.rawValue,
                publication.redactedDiagnostic,
                publication.rawPages.count
            ]
        )
        for page in publication.rawPages {
            try database.execute(
                sql: """
                    INSERT INTO review_candidate_failure_pages (
                        envelope_id, request_key, page_ordinal, raw_snapshot_id
                    ) VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    publication.id.uuidString.lowercased(),
                    page.requestIdentity.requestKey,
                    page.ordinal,
                    page.rawSnapshotID.rawValue
                ]
            )
        }
        if advanceSchedule {
            try PullRequestReviewCandidateRepository.advanceFairSchedule(
                after: publication.candidate,
                scope: publication.scope,
                streamID: publication.streamID,
                feature: publication.feature,
                at: publication.terminalAt,
                in: database
            )
        }
    }

    func envelopes(
        scope: SynchronizationScope,
        feature: CoverageFeature,
        candidateNodeID: GitHubNodeID? = nil,
        limit: Int = 100
    ) async throws -> [ReviewCandidateFailureEnvelope] {
        guard scope.accountID == vault.accountID else {
            throw ReviewCandidateFailureEnvelopeRepositoryError.accountScopeMismatch
        }
        guard limit >= 0 else {
            throw ReviewCandidateFailureEnvelopeRepositoryError.invalidPersistedData
        }
        return try await vault.read { database in
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
            var sql = """
                SELECT id, account_id, organization_id, feature, stream_id,
                       candidate_node_id, repository_id, request_key,
                       credential_revision, capability_revision, parser_version,
                       attempted_at_ms, terminal_at_ms, classification,
                       redacted_diagnostic, raw_page_count
                FROM review_candidate_failure_envelopes
                WHERE account_id = ? AND organization_id = ? AND feature = ?
                """
            var arguments: [DatabaseValueConvertible?] = [
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                feature.rawValue
            ]
            if let candidateNodeID {
                sql += " AND candidate_node_id = ?"
                arguments.append(candidateNodeID.rawValue)
            }
            sql += " ORDER BY terminal_at_ms DESC, id DESC LIMIT ?"
            arguments.append(limit)
            return try Row.fetchAll(database, sql: sql, arguments: StatementArguments(arguments)).map {
                try Self.envelope(from: $0, expectedScope: scope, expectedFeature: feature, in: database)
            }
        }
    }

    private nonisolated static func validate(
        _ publication: ReviewCandidateFailurePublication,
        in database: Database
    ) throws {
        guard publication.feature == .reviews || publication.feature == .reviewThreads else {
            throw ReviewCandidateFailureEnvelopeRepositoryError.invalidFeature
        }
        guard publication.streamID == publication.requestIdentity.streamID,
              publication.feature == publication.requestIdentity.feature,
              publication.scope == publication.requestIdentity.scope,
              !publication.requestIdentity.requestKey.isEmpty,
              publication.requestIdentity.requestKey.count <= 2_048
        else {
            throw ReviewCandidateFailureEnvelopeRepositoryError.invalidRequestIdentity
        }
        guard publication.parserVersion > 0 else {
            throw ReviewCandidateFailureEnvelopeRepositoryError.invalidParserVersion
        }
        guard publication.attemptedAt.timeIntervalSinceReferenceDate.isFinite,
              publication.terminalAt.timeIntervalSinceReferenceDate.isFinite,
              publication.attemptedAt <= publication.terminalAt
        else {
            throw ReviewCandidateFailureEnvelopeRepositoryError.invalidAttemptTimes
        }
        guard redactedDiagnosticIsSafe(publication.redactedDiagnostic) else {
            throw ReviewCandidateFailureEnvelopeRepositoryError.invalidRedactedDiagnostic
        }
        do {
            try OrganizationSchedulerStateRepository.validateCurrentScope(publication.scope, in: database)
        } catch OrganizationSchedulerStateRepositoryError.staleSynchronizationScope,
                OrganizationSchedulerStateRepositoryError.organizationScopeMismatch {
            throw ReviewCandidateFailureEnvelopeRepositoryError.staleSynchronizationScope
        }
        guard rawPagesAreContiguousAndSafe(
            publication.rawPages,
            scope: publication.scope,
            feature: publication.feature,
            streamID: publication.streamID
        ) else {
            throw ReviewCandidateFailureEnvelopeRepositoryError.invalidRawPages
        }
        switch publication.rawProvenance {
        case .terminalRawPage:
            guard let terminalPage = publication.rawPages.last,
                  terminalPage.requestIdentity == publication.requestIdentity
            else { throw ReviewCandidateFailureEnvelopeRepositoryError.invalidRawPages }
        case .zeroRawTransportFailure:
            guard publication.classification == .transportFailure,
                  publication.rawPages.isEmpty
            else { throw ReviewCandidateFailureEnvelopeRepositoryError.invalidRawPages }
        case let .zeroRawBodylessHTTPAccessFailure(statusCode):
            guard publication.classification == .unavailableOrPermission,
                  statusCode == 403 || statusCode == 404,
                  publication.rawPages.isEmpty
            else { throw ReviewCandidateFailureEnvelopeRepositoryError.invalidRawPages }
        case .zeroRawBodylessSelectedOrganizationSSOFailure:
            guard publication.classification == .ssoRequired,
                  publication.rawPages.isEmpty
            else { throw ReviewCandidateFailureEnvelopeRepositoryError.invalidRawPages }
        }
        try validateScheduleStream(publication, in: database)
        try validateCandidate(publication.candidate, scope: publication.scope, in: database)
    }

    private nonisolated static func validateScheduleStream(
        _ publication: ReviewCandidateFailurePublication,
        in database: Database
    ) throws {
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM sync_streams
                WHERE id = ? AND account_id = ? AND organization_id = ? AND feature = ?
                """,
            arguments: [
                publication.streamID.rawValue,
                publication.scope.accountID.rawValue,
                publication.scope.organizationID.rawValue,
                publication.feature.rawValue
            ]
        ) ?? 0
        guard count == 1 else {
            throw ReviewCandidateFailureEnvelopeRepositoryError.invalidCandidateScope
        }
    }

    private nonisolated static func validateCandidate(
        _ candidate: PullRequestReviewCandidate,
        scope: SynchronizationScope,
        in database: Database
    ) throws {
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM pull_requests
                JOIN github_nodes ON github_nodes.github_node_id = pull_requests.github_node_id
                JOIN repositories ON repositories.id = github_nodes.repository_id
                JOIN account_repository_access
                  ON account_repository_access.repository_id = repositories.id
                WHERE github_nodes.github_node_id = ?
                  AND github_nodes.account_id = ?
                  AND github_nodes.organization_id = ?
                  AND github_nodes.repository_id = ?
                  AND repositories.owner_login = ?
                  AND repositories.name = ?
                  AND github_nodes.number = ?
                  AND github_nodes.accessibility_state = ?
                  AND account_repository_access.account_id = ?
                  AND account_repository_access.access_state = 'available'
                """,
            arguments: [
                candidate.nodeID.rawValue,
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                candidate.repositoryID.rawValue,
                candidate.repository.owner,
                candidate.repository.repository,
                candidate.number,
                GitHubNodeAccessibility.accessible.rawValue,
                scope.accountID.rawValue
            ]
        ) ?? 0
        guard count == 1 else {
            throw ReviewCandidateFailureEnvelopeRepositoryError.invalidCandidateScope
        }
    }

    private nonisolated static func rawPagesAreContiguousAndSafe(
        _ pages: [ReviewCandidateFailureRawPage],
        scope: SynchronizationScope,
        feature: CoverageFeature,
        streamID: SyncStreamID
    ) -> Bool {
        guard Set(pages.map(\.rawSnapshotID)).count == pages.count else { return false }
        for page in pages {
            guard page.requestIdentity.scope == scope,
                  page.requestIdentity.feature == feature,
                  page.requestIdentity.streamID == streamID,
                  !page.requestIdentity.requestKey.isEmpty,
                  page.requestIdentity.requestKey.count <= 2_048,
                  page.ordinal > 0,
                  !page.endpoint.isEmpty,
                  page.endpoint.count <= maximumEndpointLength,
                  !page.endpoint.contains(where: { $0 == "\r" || $0 == "\n" }),
                  page.payload.count <= RawAPISnapshotRepository.maximumPayloadBytes
            else { return false }
        }
        return Dictionary(grouping: pages, by: \.requestIdentity.requestKey).values.allSatisfy { pages in
            pages.sorted { $0.ordinal < $1.ordinal }.map(\.ordinal) == Array(1...pages.count)
        }
    }

    private nonisolated static func redactedDiagnosticIsSafe(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maximumDiagnosticLength else { return false }
        let lowered = value.lowercased()
        let forbidden = [
            "authorization:", "proxy-authorization:", "cookie:",
            "set-cookie:", "x-oauth-scopes:", "x-github-sso:",
            "bearer ", "token ", "ghp_", "gho_", "ghu_", "github_pat_"
        ]
        return !forbidden.contains(where: lowered.contains)
    }

    private nonisolated static func envelope(
        from row: Row,
        expectedScope: SynchronizationScope,
        expectedFeature: CoverageFeature,
        in database: Database
    ) throws -> ReviewCandidateFailureEnvelope {
        guard let idValue: String = row["id"], let id = UUID(uuidString: idValue),
              let accountID = AccountID(rawValue: row["account_id"]),
              let organizationID = OrganizationID(rawValue: row["organization_id"]),
              let featureValue: String = row["feature"], let feature = CoverageFeature(rawValue: featureValue),
              let streamID = SyncStreamID(rawValue: row["stream_id"]),
              let candidateNodeID = GitHubNodeID(rawValue: row["candidate_node_id"]),
              let repositoryID = RepositoryID(rawValue: row["repository_id"]),
              let requestKey: String = row["request_key"], !requestKey.isEmpty,
              let credentialRevision = CredentialRevision(rawValue: row["credential_revision"]),
              let capabilityRevision = CapabilityRevision(rawValue: row["capability_revision"]),
              let parserVersion: Int = row["parser_version"], parserVersion > 0,
              let attemptedAtMilliseconds: Int64 = row["attempted_at_ms"],
              let terminalAtMilliseconds: Int64 = row["terminal_at_ms"],
              let classificationValue: String = row["classification"],
              let classification = ReviewCandidateFailureClassification(rawValue: classificationValue),
              let diagnostic: String = row["redacted_diagnostic"],
              let rawPageCount: Int = row["raw_page_count"]
        else { throw ReviewCandidateFailureEnvelopeRepositoryError.invalidPersistedData }
        let scope = SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )
        guard scope == expectedScope, feature == expectedFeature,
              feature == .reviews || feature == .reviewThreads,
              rawPageCount >= 0,
              (rawPageCount > 0
                || classification == .transportFailure
                || classification == .unavailableOrPermission
                || classification == .ssoRequired),
              redactedDiagnosticIsSafe(diagnostic)
        else { throw ReviewCandidateFailureEnvelopeRepositoryError.invalidPersistedData }
        let attemptedAt = Date(timeIntervalSince1970: TimeInterval(attemptedAtMilliseconds) / 1_000)
        let terminalAt = Date(timeIntervalSince1970: TimeInterval(terminalAtMilliseconds) / 1_000)
        guard attemptedAt <= terminalAt else {
            throw ReviewCandidateFailureEnvelopeRepositoryError.invalidPersistedData
        }
        let pageRows = try Row.fetchAll(
            database,
            sql: """
                SELECT request_key, page_ordinal, raw_snapshot_id
                FROM review_candidate_failure_pages
                WHERE envelope_id = ? ORDER BY request_key ASC, page_ordinal ASC
                """,
            arguments: [idValue]
        )
        guard pageRows.count == rawPageCount else {
            throw ReviewCandidateFailureEnvelopeRepositoryError.invalidPersistedData
        }
        let groupedPageRows = Dictionary(grouping: pageRows) { (row: Row) -> String? in row["request_key"] }
        guard !groupedPageRows.keys.contains(nil) else {
            throw ReviewCandidateFailureEnvelopeRepositoryError.invalidPersistedData
        }
        let rawSnapshotIDs = try pageRows.map { row -> RawAPISnapshotID in
            guard let requestKey: String = row["request_key"], !requestKey.isEmpty,
                  let ordinal: Int = row["page_ordinal"], ordinal > 0,
                  let value: String = row["raw_snapshot_id"], let rawID = RawAPISnapshotID(rawValue: value)
            else { throw ReviewCandidateFailureEnvelopeRepositoryError.invalidPersistedData }
            let snapshotCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) FROM raw_api_snapshots
                    WHERE id = ? AND account_id = ? AND github_node_id = ?
                      AND authority_organization_id = ? AND authority_feature = ?
                      AND authority_stream_id = ? AND authority_request_key = ?
                      AND authority_credential_revision = ? AND authority_capability_revision = ?
                      AND parser_version = ?
                    """,
                arguments: [
                    rawID.rawValue, accountID.rawValue, candidateNodeID.rawValue,
                    organizationID.rawValue, feature.rawValue, streamID.rawValue, requestKey,
                    credentialRevision.rawValue, capabilityRevision.rawValue, parserVersion
                ]
            ) ?? 0
            guard snapshotCount == 1 else {
                throw ReviewCandidateFailureEnvelopeRepositoryError.invalidPersistedData
            }
            return rawID
        }
        guard groupedPageRows.values.allSatisfy({ rows in
            rows.compactMap { (row: Row) -> Int? in row["page_ordinal"] }.sorted() == Array(1...rows.count)
        }) else { throw ReviewCandidateFailureEnvelopeRepositoryError.invalidPersistedData }
        return ReviewCandidateFailureEnvelope(
            id: id,
            scope: scope,
            feature: feature,
            streamID: streamID,
            candidateNodeID: candidateNodeID,
            repositoryID: repositoryID,
            requestIdentity: .init(scope: scope, feature: feature, streamID: streamID, requestKey: requestKey),
            parserVersion: parserVersion,
            attemptedAt: attemptedAt,
            terminalAt: terminalAt,
            classification: classification,
            redactedDiagnostic: diagnostic,
            rawSnapshotIDs: rawSnapshotIDs
        )
    }

    private nonisolated static func matchesPersistedPublication(
        _ row: Row,
        publication: ReviewCandidateFailurePublication,
        in database: Database
    ) throws -> Bool {
        let persisted = try envelope(
            from: row,
            expectedScope: publication.scope,
            expectedFeature: publication.feature,
            in: database
        )
        return persisted.id == publication.id
            && persisted.streamID == publication.streamID
            && persisted.candidateNodeID == publication.candidate.nodeID
            && persisted.repositoryID == publication.candidate.repositoryID
            && persisted.requestIdentity == publication.requestIdentity
            && persisted.parserVersion == publication.parserVersion
            && milliseconds(persisted.attemptedAt) == milliseconds(publication.attemptedAt)
            && milliseconds(persisted.terminalAt) == milliseconds(publication.terminalAt)
            && persisted.classification == publication.classification
            && persisted.redactedDiagnostic == publication.redactedDiagnostic
            && persisted.rawSnapshotIDs == publication.rawPages.sorted {
                ($0.requestIdentity.requestKey, $0.ordinal) < ($1.requestIdentity.requestKey, $1.ordinal)
            }.map(\.rawSnapshotID)
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
