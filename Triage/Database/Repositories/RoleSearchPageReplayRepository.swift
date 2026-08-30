import Foundation
import GRDB

enum RoleSearchPageReplayRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationScopeMismatch
    case streamScopeMismatch
    case snapshotScopeMismatch
    case snapshotEndpointMismatch
    case snapshotParserMismatch
    case snapshotRequestAuthorityMismatch
    case snapshotHasNormalizationFailure
    case snapshotValidatorMismatch
    case invalidRequestKey
    case invalidQuery
    case invalidPage
    case invalidEndpoint
    case invalidValidator
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
                SELECT COUNT(*) FROM account_organizations
                WHERE account_id = ? AND organization_id = ?
                """,
            arguments: [replay.accountID.rawValue, replay.organizationID.rawValue]
        ) ?? 0
        guard organizationCount == 1 else {
            throw RoleSearchPageReplayRepositoryError.organizationScopeMismatch
        }
        guard try hasCurrentAuthority(for: replay, in: database) else {
            throw RoleSearchPageReplayRepositoryError.streamScopeMismatch
        }
        guard let snapshotRow = try Row.fetchOne(
            database,
            sql: """
                SELECT id, account_id, github_node_id, endpoint, etag, last_modified,
                       authority_organization_id, authority_feature, authority_stream_id,
                       authority_request_key, authority_credential_revision,
                       authority_capability_revision, parser_version, observed_at_ms, payload
                FROM raw_api_snapshots
                WHERE id = ?
                """,
            arguments: [replay.rawSnapshotID.rawValue]
        ) else {
            throw RoleSearchPageReplayRepositoryError.snapshotScopeMismatch
        }
        let snapshot: RawAPISnapshot
        do {
            snapshot = try RawAPISnapshotRepository.snapshot(from: snapshotRow)
        } catch {
            throw RoleSearchPageReplayRepositoryError.snapshotScopeMismatch
        }
        guard snapshot.accountID == replay.accountID, snapshot.githubNodeID == nil else {
            throw RoleSearchPageReplayRepositoryError.snapshotScopeMismatch
        }
        guard snapshot.endpoint == replay.endpoint else {
            throw RoleSearchPageReplayRepositoryError.snapshotEndpointMismatch
        }
        guard snapshot.parserVersion == replay.parserVersion else {
            throw RoleSearchPageReplayRepositoryError.snapshotParserMismatch
        }
        guard snapshot.requestIdentity == requestIdentity(for: replay) else {
            throw RoleSearchPageReplayRepositoryError.snapshotRequestAuthorityMismatch
        }
        guard snapshot.eTag == replay.eTag,
              snapshot.lastModified == replay.lastModified
        else {
            throw RoleSearchPageReplayRepositoryError.snapshotValidatorMismatch
        }
        let normalizationFailureCount = try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM normalization_failures WHERE raw_snapshot_id = ?",
            arguments: [replay.rawSnapshotID.rawValue]
        ) ?? 0
        guard normalizationFailureCount == 0 else {
            throw RoleSearchPageReplayRepositoryError.snapshotHasNormalizationFailure
        }

        try database.execute(
            sql: """
                INSERT INTO role_search_page_replays (
                    account_id, organization_id, feature, stream_id, request_key,
                    query_value, page, endpoint, credential_revision, capability_revision,
                    raw_snapshot_id, etag, last_modified, parser_version,
                    last_validated_at_ms
                ) VALUES (?, ?, 'roleDiscovery', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(
                    account_id, organization_id, feature, stream_id, request_key,
                    credential_revision, capability_revision
                ) DO UPDATE SET
                    query_value = excluded.query_value,
                    page = excluded.page,
                    endpoint = excluded.endpoint,
                    raw_snapshot_id = excluded.raw_snapshot_id,
                    etag = excluded.etag,
                    last_modified = excluded.last_modified,
                    parser_version = excluded.parser_version,
                    last_validated_at_ms = excluded.last_validated_at_ms
                """,
            arguments: [
                replay.accountID.rawValue,
                replay.organizationID.rawValue,
                replay.streamID.rawValue,
                replay.requestKey,
                replay.queryValue,
                replay.page,
                replay.endpoint,
                replay.credentialRevision.rawValue,
                replay.capabilityRevision.rawValue,
                replay.rawSnapshotID.rawValue,
                replay.eTag,
                replay.lastModified,
                replay.parserVersion,
                milliseconds(replay.lastValidatedAt)
            ]
        )
    }

    func entry(
        requestKey: String,
        streamID: SyncStreamID,
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
            guard try Self.hasCurrentAuthority(
                accountID: accountID,
                organizationID: organizationID,
                streamID: streamID,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision,
                in: database
            ) else {
                return nil
            }
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT replay.request_key AS replay_request_key,
                           replay.account_id AS replay_account_id,
                           replay.organization_id AS replay_organization_id,
                           replay.stream_id AS replay_stream_id,
                           replay.query_value AS replay_query_value,
                           replay.page AS replay_page,
                           replay.endpoint AS replay_endpoint,
                           replay.credential_revision AS replay_credential_revision,
                           replay.capability_revision AS replay_capability_revision,
                           replay.raw_snapshot_id AS replay_raw_snapshot_id,
                           replay.etag AS replay_etag,
                           replay.last_modified AS replay_last_modified,
                           replay.parser_version AS replay_parser_version,
                           replay.last_validated_at_ms AS replay_last_validated_at_ms,
                           snapshot.id, snapshot.account_id, snapshot.github_node_id,
                           snapshot.endpoint, snapshot.etag, snapshot.last_modified,
                           snapshot.authority_organization_id, snapshot.authority_feature,
                           snapshot.authority_stream_id, snapshot.authority_request_key,
                           snapshot.authority_credential_revision,
                           snapshot.authority_capability_revision,
                           snapshot.parser_version, snapshot.observed_at_ms, snapshot.payload,
                           EXISTS (
                               SELECT 1 FROM normalization_failures
                               WHERE normalization_failures.raw_snapshot_id = snapshot.id
                           ) AS has_normalization_failure
                    FROM role_search_page_replays AS replay
                    JOIN raw_api_snapshots AS snapshot
                      ON snapshot.id = replay.raw_snapshot_id
                    WHERE replay.account_id = ? AND replay.organization_id = ?
                      AND replay.feature = 'roleDiscovery' AND replay.stream_id = ?
                      AND replay.request_key = ? AND replay.credential_revision = ?
                      AND replay.capability_revision = ?
                    """,
                arguments: [
                    accountID.rawValue,
                    organizationID.rawValue,
                    streamID.rawValue,
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
        streamID: SyncStreamID,
        accountID: AccountID,
        organizationID: OrganizationID,
        credentialRevision: CredentialRevision,
        capabilityRevision: CapabilityRevision
    ) async throws {
        guard accountID == vault.accountID else {
            throw RoleSearchPageReplayRepositoryError.accountScopeMismatch
        }
        try await vault.write { database in
            try Self.remove(
                requestKey: requestKey,
                streamID: streamID,
                accountID: accountID,
                organizationID: organizationID,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision,
                expectedAccountID: vault.accountID,
                in: database
            )
        }
    }

    nonisolated static func remove(
        requestKey: String,
        streamID: SyncStreamID,
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
        guard isValidRequestKey(requestKey) else {
            throw RoleSearchPageReplayRepositoryError.invalidRequestKey
        }
        try database.execute(
            sql: """
                DELETE FROM role_search_page_replays
                WHERE account_id = ? AND organization_id = ?
                  AND feature = 'roleDiscovery' AND stream_id = ?
                  AND request_key = ? AND credential_revision = ?
                  AND capability_revision = ?
                """,
            arguments: [
                accountID.rawValue,
                organizationID.rawValue,
                streamID.rawValue,
                requestKey,
                credentialRevision.rawValue,
                capabilityRevision.rawValue
            ]
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
        // A synchronizer can outlive a credential or capability change. Its
        // stale scope must not be allowed to evict bindings created by the
        // replacement synchronizer.
        guard try hasCurrentRevisionAuthority(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            in: database
        ) else {
            return
        }
        try database.execute(
            sql: """
                DELETE FROM role_search_page_replays
                WHERE account_id = ? AND organization_id = ?
                  AND feature = 'roleDiscovery'
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

    func removeStaleParserVersions(
        streamID: SyncStreamID,
        accountID: AccountID,
        organizationID: OrganizationID,
        credentialRevision: CredentialRevision,
        capabilityRevision: CapabilityRevision
    ) async throws {
        guard accountID == vault.accountID else {
            throw RoleSearchPageReplayRepositoryError.accountScopeMismatch
        }
        try await vault.write { database in
            try Self.removeStaleParserVersions(
                streamID: streamID,
                accountID: accountID,
                organizationID: organizationID,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision,
                expectedAccountID: vault.accountID,
                in: database
            )
        }
    }

    nonisolated static func removeStaleParserVersions(
        streamID: SyncStreamID,
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
        guard try hasCurrentAuthority(
            accountID: accountID,
            organizationID: organizationID,
            streamID: streamID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            in: database
        ) else {
            return
        }
        try database.execute(
            sql: """
                DELETE FROM role_search_page_replays
                WHERE account_id = ? AND organization_id = ?
                  AND feature = 'roleDiscovery' AND stream_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                  AND parser_version <> ?
                """,
            arguments: [
                accountID.rawValue,
                organizationID.rawValue,
                streamID.rawValue,
                credentialRevision.rawValue,
                capabilityRevision.rawValue,
                GitHubIssueSearchRequestIdentity.parserVersion
            ]
        )
    }

    private nonisolated static func hasCurrentAuthority(
        for replay: RoleSearchPageReplay,
        in database: Database
    ) throws -> Bool {
        try hasCurrentAuthority(
            accountID: replay.accountID,
            organizationID: replay.organizationID,
            streamID: replay.streamID,
            credentialRevision: replay.credentialRevision,
            capabilityRevision: replay.capabilityRevision,
            in: database
        )
    }

    private nonisolated static func hasCurrentAuthority(
        accountID: AccountID,
        organizationID: OrganizationID,
        streamID: SyncStreamID,
        credentialRevision: CredentialRevision,
        capabilityRevision: CapabilityRevision,
        in database: Database
    ) throws -> Bool {
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM accounts
                JOIN account_organizations
                  ON account_organizations.account_id = accounts.id
                JOIN sync_streams
                  ON sync_streams.account_id = account_organizations.account_id
                 AND sync_streams.organization_id = account_organizations.organization_id
                WHERE accounts.id = ? AND account_organizations.organization_id = ?
                  AND sync_streams.id = ? AND sync_streams.feature = 'roleDiscovery'
                  AND accounts.credential_revision = ?
                  AND account_organizations.capability_revision = ?
                """,
            arguments: [
                accountID.rawValue,
                organizationID.rawValue,
                streamID.rawValue,
                credentialRevision.rawValue,
                capabilityRevision.rawValue
            ]
        ) ?? 0
        return count == 1
    }

    private nonisolated static func hasCurrentRevisionAuthority(
        accountID: AccountID,
        organizationID: OrganizationID,
        credentialRevision: CredentialRevision,
        capabilityRevision: CapabilityRevision,
        in database: Database
    ) throws -> Bool {
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM accounts
                JOIN account_organizations
                  ON account_organizations.account_id = accounts.id
                WHERE accounts.id = ? AND account_organizations.organization_id = ?
                  AND accounts.credential_revision = ?
                  AND account_organizations.capability_revision = ?
                """,
            arguments: [
                accountID.rawValue,
                organizationID.rawValue,
                credentialRevision.rawValue,
                capabilityRevision.rawValue
            ]
        ) ?? 0
        return count == 1
    }

    private nonisolated static func requestIdentity(
        for replay: RoleSearchPageReplay
    ) -> ConditionalRequestIdentity {
        ConditionalRequestIdentity(
            scope: SynchronizationScope(
                accountID: replay.accountID,
                organizationID: replay.organizationID,
                credentialRevision: replay.credentialRevision,
                capabilityRevision: replay.capabilityRevision
            ),
            feature: .roleDiscovery,
            streamID: replay.streamID,
            requestKey: replay.requestKey
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
        do {
            _ = try GitHubHTTPValidators(
                eTag: replay.eTag,
                lastModified: replay.lastModified
            )
        } catch {
            throw RoleSearchPageReplayRepositoryError.invalidValidator
        }
        guard replay.parserVersion == GitHubIssueSearchRequestIdentity.parserVersion else {
            throw RoleSearchPageReplayRepositoryError.invalidParserVersion
        }
    }

    private nonisolated static func isValidRequestKey(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 2_048
    }

    private nonisolated static func entry(from row: Row) throws -> RoleSearchPageReplayEntry {
        guard let requestKey: String = row["replay_request_key"],
              let accountID = AccountID(rawValue: row["replay_account_id"]),
              let organizationID = OrganizationID(rawValue: row["replay_organization_id"]),
              let streamID = SyncStreamID(rawValue: row["replay_stream_id"]),
              let queryValue: String = row["replay_query_value"],
              let page: Int = row["replay_page"],
              let endpoint: String = row["replay_endpoint"],
              let credentialRevision = CredentialRevision(rawValue: row["replay_credential_revision"]),
              let capabilityRevision = CapabilityRevision(rawValue: row["replay_capability_revision"]),
              let rawSnapshotID = RawAPISnapshotID(rawValue: row["replay_raw_snapshot_id"]),
              let parserVersion: Int = row["replay_parser_version"],
              let lastValidatedAtMilliseconds: Int64 = row["replay_last_validated_at_ms"],
              let hasNormalizationFailure: Bool = row["has_normalization_failure"],
              !hasNormalizationFailure
        else {
            throw RoleSearchPageReplayRepositoryError.invalidPersistedData
        }
        let eTag: String? = row["replay_etag"]
        let lastModified: String? = row["replay_last_modified"]
        let replay = RoleSearchPageReplay(
            requestKey: requestKey,
            accountID: accountID,
            organizationID: organizationID,
            streamID: streamID,
            queryValue: queryValue,
            page: page,
            endpoint: endpoint,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            rawSnapshotID: rawSnapshotID,
            eTag: eTag,
            lastModified: lastModified,
            parserVersion: parserVersion,
            lastValidatedAt: date(lastValidatedAtMilliseconds)
        )
        do {
            try validate(replay)
            let snapshot = try RawAPISnapshotRepository.snapshot(from: row)
            guard snapshot.id == rawSnapshotID,
                  snapshot.accountID == accountID,
                  snapshot.githubNodeID == nil,
                  snapshot.endpoint == endpoint,
                  snapshot.eTag == eTag,
                  snapshot.lastModified == lastModified,
                  snapshot.parserVersion == parserVersion,
                  snapshot.requestIdentity == requestIdentity(for: replay)
            else {
                throw RoleSearchPageReplayRepositoryError.invalidPersistedData
            }
            return RoleSearchPageReplayEntry(replay: replay, snapshot: snapshot)
        } catch {
            throw RoleSearchPageReplayRepositoryError.invalidPersistedData
        }
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
    private var parserVersionPrunedStreams: Set<SyncStreamID> = []

    init(repository: RoleSearchPageReplayRepository, scope: SynchronizationScope) {
        self.repository = repository
        self.scope = scope
    }

    func entry(
        for query: GitHubIssueSearchQuery,
        page: Int,
        streamID: SyncStreamID
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
        if !parserVersionPrunedStreams.contains(streamID) {
            try await repository.removeStaleParserVersions(
                streamID: streamID,
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                credentialRevision: scope.credentialRevision,
                capabilityRevision: scope.capabilityRevision
            )
            parserVersionPrunedStreams.insert(streamID)
        }
        let identity = try GitHubIssueSearchRequestIdentity(
            query: query,
            page: page,
            scope: scope,
            streamID: streamID
        )
        let entry: RoleSearchPageReplayEntry?
        do {
            entry = try await repository.entry(
                requestKey: identity.requestKey,
                streamID: streamID,
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                credentialRevision: scope.credentialRevision,
                capabilityRevision: scope.capabilityRevision
            )
        } catch RoleSearchPageReplayRepositoryError.invalidPersistedData {
            try Task.checkCancellation()
            try await invalidate(identity, streamID: streamID)
            return nil
        }
        guard let entry else {
            return nil
        }
        guard entry.replay.requestKey == identity.requestKey,
              entry.replay.streamID == streamID,
              entry.replay.queryValue == identity.queryValue,
              entry.replay.page == identity.page,
              entry.replay.endpoint == identity.endpoint,
              entry.replay.accountID == scope.accountID,
              entry.replay.organizationID == scope.organizationID,
              entry.replay.credentialRevision == scope.credentialRevision,
              entry.replay.capabilityRevision == scope.capabilityRevision
        else {
            try Task.checkCancellation()
            try await invalidate(identity, streamID: streamID)
            return nil
        }
        return entry
    }

    func invalidate(
        query: GitHubIssueSearchQuery,
        page: Int,
        streamID: SyncStreamID
    ) async throws {
        try await invalidate(
            GitHubIssueSearchRequestIdentity(
                query: query,
                page: page,
                scope: scope,
                streamID: streamID
            ),
            streamID: streamID
        )
    }

    private func invalidate(
        _ identity: GitHubIssueSearchRequestIdentity,
        streamID: SyncStreamID
    ) async throws {
        try await repository.remove(
            requestKey: identity.requestKey,
            streamID: streamID,
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision
        )
    }
}
