import Foundation
import GRDB

enum RoleSearchPageReplayRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationScopeMismatch
    case snapshotScopeMismatch
    case snapshotETagMismatch
    case invalidRequestKey
    case invalidQuery
    case invalidPage
    case invalidEndpoint
    case invalidETag
    case invalidParserVersion
    case invalidPersistedData
}

actor RoleSearchPageReplayRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(_ replay: RoleSearchPageReplay) async throws {
        guard replay.accountID == vault.accountID else {
            throw RoleSearchPageReplayRepositoryError.accountScopeMismatch
        }
        try await vault.write { database in
            try Self.save(replay, expectedAccountID: vault.accountID, in: database)
        }
    }

    nonisolated static func save(
        _ replay: RoleSearchPageReplay,
        expectedAccountID: AccountID,
        in database: Database
    ) throws {
        guard replay.accountID == expectedAccountID else {
            throw RoleSearchPageReplayRepositoryError.accountScopeMismatch
        }
        try validate(replay)
        let organizationCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM account_organizations
                WHERE account_id = ? AND organization_id = ?
                """,
            arguments: [replay.accountID.rawValue, replay.organizationID.rawValue]
        ) ?? 0
        guard organizationCount == 1 else {
            throw RoleSearchPageReplayRepositoryError.organizationScopeMismatch
        }
        guard let snapshotRow = try Row.fetchOne(
            database,
            sql: "SELECT account_id, endpoint, etag FROM raw_api_snapshots WHERE id = ?",
            arguments: [replay.rawSnapshotID.rawValue]
        ), let snapshotAccountID = AccountID(rawValue: snapshotRow["account_id"])
        else {
            throw RoleSearchPageReplayRepositoryError.snapshotScopeMismatch
        }
        guard snapshotAccountID == replay.accountID else {
            throw RoleSearchPageReplayRepositoryError.snapshotScopeMismatch
        }
        let snapshotETag: String? = snapshotRow["etag"]
        guard snapshotETag == replay.eTag else {
            throw RoleSearchPageReplayRepositoryError.snapshotETagMismatch
        }
        let snapshotEndpoint: String? = snapshotRow["endpoint"]
        guard snapshotEndpoint == replay.endpoint else {
            throw RoleSearchPageReplayRepositoryError.snapshotScopeMismatch
        }
        try database.execute(
            sql: """
                INSERT INTO role_search_page_replays (
                    account_id, organization_id, request_key, query_value, page, endpoint,
                    credential_revision, capability_revision, raw_snapshot_id, etag,
                    parser_version, last_validated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_id, organization_id, request_key) DO UPDATE SET
                    query_value = excluded.query_value,
                    page = excluded.page,
                    endpoint = excluded.endpoint,
                    credential_revision = excluded.credential_revision,
                    capability_revision = excluded.capability_revision,
                    raw_snapshot_id = excluded.raw_snapshot_id,
                    etag = excluded.etag,
                    parser_version = excluded.parser_version,
                    last_validated_at_ms = excluded.last_validated_at_ms
                """,
            arguments: [
                replay.accountID.rawValue,
                replay.organizationID.rawValue,
                replay.requestKey,
                replay.queryValue,
                replay.page,
                replay.endpoint,
                replay.credentialRevision.rawValue,
                replay.capabilityRevision.rawValue,
                replay.rawSnapshotID.rawValue,
                replay.eTag,
                replay.parserVersion,
                milliseconds(replay.lastValidatedAt)
            ]
        )
    }

    func entry(
        requestKey: String,
        accountID: AccountID,
        organizationID: OrganizationID,
        credentialRevision: CredentialRevision,
        capabilityRevision: CapabilityRevision
    ) async throws -> RoleSearchPageReplayEntry? {
        guard accountID == vault.accountID else {
            throw RoleSearchPageReplayRepositoryError.accountScopeMismatch
        }
        guard Self.isValidRequestKey(requestKey) else {
            throw RoleSearchPageReplayRepositoryError.invalidRequestKey
        }
        return try await vault.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT replay.account_id, replay.organization_id, replay.request_key,
                           replay.query_value, replay.page, replay.endpoint, replay.credential_revision,
                           replay.capability_revision, replay.raw_snapshot_id, replay.etag,
                           replay.parser_version, replay.last_validated_at_ms,
                           snapshot.github_node_id, snapshot.endpoint AS snapshot_endpoint,
                           snapshot.etag AS snapshot_etag,
                           snapshot.last_modified AS snapshot_last_modified,
                           snapshot.parser_version AS snapshot_parser_version,
                           snapshot.observed_at_ms, snapshot.payload
                    FROM role_search_page_replays AS replay
                    JOIN raw_api_snapshots AS snapshot
                      ON snapshot.id = replay.raw_snapshot_id
                     AND snapshot.account_id = replay.account_id
                    WHERE replay.account_id = ? AND replay.organization_id = ?
                      AND replay.request_key = ? AND replay.credential_revision = ?
                      AND replay.capability_revision = ?
                    """,
                arguments: [
                    accountID.rawValue,
                    organizationID.rawValue,
                    requestKey,
                    credentialRevision.rawValue,
                    capabilityRevision.rawValue
                ]
            ) else {
                return nil
            }
            return try Self.entry(from: row)
        }
    }

    func remove(
        requestKey: String,
        accountID: AccountID,
        organizationID: OrganizationID
    ) async throws {
        guard accountID == vault.accountID else {
            throw RoleSearchPageReplayRepositoryError.accountScopeMismatch
        }
        guard Self.isValidRequestKey(requestKey) else {
            throw RoleSearchPageReplayRepositoryError.invalidRequestKey
        }
        try await vault.write { database in
            try Self.remove(
                requestKey: requestKey,
                accountID: accountID,
                organizationID: organizationID,
                expectedAccountID: vault.accountID,
                in: database
            )
        }
    }

    nonisolated static func remove(
        requestKey: String,
        accountID: AccountID,
        organizationID: OrganizationID,
        expectedAccountID: AccountID,
        in database: Database
    ) throws {
        guard accountID == expectedAccountID else {
            throw RoleSearchPageReplayRepositoryError.accountScopeMismatch
        }
        guard isValidRequestKey(requestKey) else {
            throw RoleSearchPageReplayRepositoryError.invalidRequestKey
        }
        try database.execute(
            sql: """
                DELETE FROM role_search_page_replays
                WHERE account_id = ? AND organization_id = ? AND request_key = ?
                """,
            arguments: [accountID.rawValue, organizationID.rawValue, requestKey]
        )
    }

    func removeStaleRevisions(
        accountID: AccountID,
        organizationID: OrganizationID,
        credentialRevision: CredentialRevision,
        capabilityRevision: CapabilityRevision
    ) async throws {
        guard accountID == vault.accountID else {
            throw RoleSearchPageReplayRepositoryError.accountScopeMismatch
        }
        try await vault.write { database in
            try Self.removeStaleRevisions(
                accountID: accountID,
                organizationID: organizationID,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision,
                expectedAccountID: vault.accountID,
                in: database
            )
        }
    }

    nonisolated static func removeStaleRevisions(
        accountID: AccountID,
        organizationID: OrganizationID,
        credentialRevision: CredentialRevision,
        capabilityRevision: CapabilityRevision,
        expectedAccountID: AccountID,
        in database: Database
    ) throws {
        guard accountID == expectedAccountID else {
            throw RoleSearchPageReplayRepositoryError.accountScopeMismatch
        }
        try database.execute(
            sql: """
                DELETE FROM role_search_page_replays
                WHERE account_id = ? AND organization_id = ?
                  AND (credential_revision <> ? OR capability_revision <> ?)
                """,
            arguments: [
                accountID.rawValue,
                organizationID.rawValue,
                credentialRevision.rawValue,
                capabilityRevision.rawValue
            ]
        )
    }

    private nonisolated static func validate(_ replay: RoleSearchPageReplay) throws {
        guard isValidRequestKey(replay.requestKey) else {
            throw RoleSearchPageReplayRepositoryError.invalidRequestKey
        }
        guard !replay.queryValue.isEmpty, replay.queryValue.count <= 2_048 else {
            throw RoleSearchPageReplayRepositoryError.invalidQuery
        }
        guard (1...100).contains(replay.page) else {
            throw RoleSearchPageReplayRepositoryError.invalidPage
        }
        guard !replay.endpoint.isEmpty, replay.endpoint.count <= 2_048 else {
            throw RoleSearchPageReplayRepositoryError.invalidEndpoint
        }
        guard !replay.eTag.isEmpty, replay.eTag.count <= 2_048 else {
            throw RoleSearchPageReplayRepositoryError.invalidETag
        }
        guard replay.parserVersion > 0 else {
            throw RoleSearchPageReplayRepositoryError.invalidParserVersion
        }
    }

    private nonisolated static func isValidRequestKey(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 2_048
    }

    private nonisolated static func entry(from row: Row) throws -> RoleSearchPageReplayEntry {
        guard let accountID = AccountID(rawValue: row["account_id"]),
              let organizationID = OrganizationID(rawValue: row["organization_id"]),
              let requestKey: String = row["request_key"],
              let queryValue: String = row["query_value"],
              let page: Int = row["page"],
              let endpoint: String = row["endpoint"],
              let credentialRevision = CredentialRevision(rawValue: row["credential_revision"]),
              let capabilityRevision = CapabilityRevision(rawValue: row["capability_revision"]),
              let snapshotID = RawAPISnapshotID(rawValue: row["raw_snapshot_id"]),
              let eTag: String = row["etag"],
              let parserVersion: Int = row["parser_version"],
              let lastValidatedAtMilliseconds: Int64 = row["last_validated_at_ms"],
              let snapshotEndpoint: String = row["snapshot_endpoint"],
              let snapshotETag: String = row["snapshot_etag"],
              let snapshotParserVersion: Int = row["snapshot_parser_version"],
              let observedAtMilliseconds: Int64 = row["observed_at_ms"],
              let payload: Data = row["payload"]
        else {
            throw RoleSearchPageReplayRepositoryError.invalidPersistedData
        }
        let rawNodeID: String? = row["github_node_id"]
        let nodeID = rawNodeID.flatMap(GitHubNodeID.init(rawValue:))
        let snapshotLastModified: String? = row["snapshot_last_modified"]
        guard rawNodeID == nil || nodeID != nil,
              parserVersion == snapshotParserVersion,
              endpoint == snapshotEndpoint,
              eTag == snapshotETag
        else {
            throw RoleSearchPageReplayRepositoryError.invalidPersistedData
        }
        let replay = RoleSearchPageReplay(
            requestKey: requestKey,
            accountID: accountID,
            organizationID: organizationID,
            queryValue: queryValue,
            page: page,
            endpoint: endpoint,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            rawSnapshotID: snapshotID,
            eTag: eTag,
            parserVersion: parserVersion,
            lastValidatedAt: date(lastValidatedAtMilliseconds)
        )
        try validate(replay)
        return RoleSearchPageReplayEntry(
            replay: replay,
            snapshot: RawAPISnapshot(
                id: snapshotID,
                accountID: accountID,
                githubNodeID: nodeID,
                endpoint: snapshotEndpoint,
                eTag: eTag,
                lastModified: snapshotLastModified,
                parserVersion: snapshotParserVersion,
                observedAt: date(observedAtMilliseconds),
                payload: payload
            )
        )
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}

actor RoleSearchPageReplayCache {
    private let repository: RoleSearchPageReplayRepository
    let scope: SynchronizationScope
    private var didRemoveStaleRevisions = false

    init(repository: RoleSearchPageReplayRepository, scope: SynchronizationScope) {
        self.repository = repository
        self.scope = scope
    }

    func entry(
        for query: GitHubIssueSearchQuery,
        page: Int
    ) async throws -> RoleSearchPageReplayEntry? {
        if !didRemoveStaleRevisions {
            try await repository.removeStaleRevisions(
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                credentialRevision: scope.credentialRevision,
                capabilityRevision: scope.capabilityRevision
            )
            didRemoveStaleRevisions = true
        }
        let identity = try GitHubIssueSearchRequestIdentity(
            query: query,
            page: page,
            scope: scope
        )
        let entry: RoleSearchPageReplayEntry?
        do {
            entry = try await repository.entry(
                requestKey: identity.requestKey,
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                credentialRevision: scope.credentialRevision,
                capabilityRevision: scope.capabilityRevision
            )
        } catch RoleSearchPageReplayRepositoryError.invalidPersistedData {
            try await invalidate(identity)
            return nil
        }
        guard let entry else {
            return nil
        }
        guard entry.replay.requestKey == identity.requestKey,
              entry.replay.queryValue == identity.queryValue,
              entry.replay.page == identity.page,
              entry.replay.endpoint == identity.endpoint,
              entry.replay.accountID == scope.accountID,
              entry.replay.organizationID == scope.organizationID,
              entry.replay.credentialRevision == scope.credentialRevision,
              entry.replay.capabilityRevision == scope.capabilityRevision
        else {
            try await invalidate(identity)
            return nil
        }
        return entry
    }

    func invalidate(
        query: GitHubIssueSearchQuery,
        page: Int
    ) async throws {
        try await invalidate(
            GitHubIssueSearchRequestIdentity(query: query, page: page, scope: scope)
        )
    }

    private func invalidate(_ identity: GitHubIssueSearchRequestIdentity) async throws {
        try await repository.remove(
            requestKey: identity.requestKey,
            accountID: scope.accountID,
            organizationID: scope.organizationID
        )
    }
}
