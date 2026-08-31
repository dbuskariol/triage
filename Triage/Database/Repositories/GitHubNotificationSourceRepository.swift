import CryptoKit
import Foundation
import GRDB

enum GitHubNotificationSourceRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case staleSynchronizationScope
    case invalidAuthority
    case invalidPageTopology
    case conflictingRawPage
    case invalidPersistedData
}

/// Encrypted persistence for the read-only notifications discovery feed.
///
/// The tables used here are intentionally separate from local notification
/// delivery. GitHub notification records are source metadata, not a local
/// read/unread workflow and never authorize content or tombstones.
actor GitHubNotificationSourceRepository: GitHubNotificationSourcePersisting {
    private static let parserVersion = 1
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func validator(for identity: ConditionalRequestIdentity) async throws -> ConditionalRequestValidator? {
        guard identity.scope.accountID == vault.accountID, identity.feature == .notifications else {
            throw GitHubNotificationSourceRepositoryError.accountScopeMismatch
        }
        return try await vault.read { database in
            try Self.validateCurrentScope(identity.scope, in: database)
            return try ConditionalRequestCacheRepository.validator(
                for: identity,
                expectedAccountID: identity.scope.accountID,
                in: database
            )
        }
    }

    func persistValidatedUnchanged(
        for validator: ConditionalRequestValidator,
        coverage: CoverageRecord,
        observedAt: Date
    ) async throws -> Bool {
        let identity = validator.identity
        guard identity.scope.accountID == vault.accountID,
              identity.feature == .notifications,
              coverage.accountID == identity.scope.accountID,
              coverage.organizationID == identity.scope.organizationID,
              coverage.repositoryID == nil,
              coverage.feature == .notifications,
              coverage.streamID == identity.streamID,
              coverage.credentialRevision == identity.scope.credentialRevision,
              coverage.capabilityRevision == identity.scope.capabilityRevision,
              coverage.status == .complete
        else {
            throw GitHubNotificationSourceRepositoryError.accountScopeMismatch
        }
        return try await vault.writeTransaction { database in
            try Self.validateCurrentScope(identity.scope, in: database)
            guard try Self.hasValidatedUnchangedReceipt(
                for: validator,
                in: database
            ) else {
                return false
            }
            try CoverageRepository.save(
                coverage,
                attemptedAt: observedAt,
                expectedAccountID: identity.scope.accountID,
                in: database
            )
            return true
        }
    }

    private nonisolated static func hasValidatedUnchangedReceipt(
        for validator: ConditionalRequestValidator,
        in database: Database
    ) throws -> Bool {
        let identity = validator.identity
        guard let receipt = try Row.fetchOne(database, sql: """
                SELECT etag, last_modified, parser_version, source_revision,
                       notification_count, notification_digest
                FROM notification_replay_receipts
                WHERE account_id = ? AND organization_id = ? AND feature = ? AND stream_id = ?
                  AND request_key = ? AND credential_revision = ? AND capability_revision = ?
            """, arguments: Self.identityArguments(identity)) else {
            return false
        }
        let receiptETag: String? = receipt["etag"]
        let receiptLastModified: String? = receipt["last_modified"]
        guard receiptETag == validator.eTag,
              receiptLastModified == validator.lastModified,
              (receipt["parser_version"] as Int?) == Self.parserVersion,
              let sourceRevision: String = receipt["source_revision"],
              let expectedCount: Int = receipt["notification_count"],
              let expectedDigest: String = receipt["notification_digest"],
              expectedCount >= 0,
              Self.isDigest(expectedDigest)
        else { return false }
        let pages = try Self.currentPageRows(identity: identity, sourceRevision: sourceRevision, in: database)
        guard !pages.isEmpty, pages.last?.isTerminal == true else { return false }
        let rows = try Row.fetchAll(database, sql: """
                SELECT notification_id, repository_node_id, reason, is_unread, subject_type,
                       subject_title, subject_url, updated_at_ms, last_read_at_ms, source_revision,
                       raw_snapshot_id
                FROM notification_threads
                WHERE account_id = ? AND organization_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                  AND source_revision = ?
                ORDER BY notification_id
            """, arguments: [
                identity.scope.accountID.rawValue, identity.scope.organizationID.rawValue,
                identity.scope.credentialRevision.rawValue, identity.scope.capabilityRevision.rawValue,
                sourceRevision
            ])
        guard rows.count == expectedCount,
              Self.digest(rows) == expectedDigest,
              Self.allNotificationRowsBindToCurrentPages(rows, pages: pages)
        else { return false }
        return true
    }

    func persist(
        _ inventory: GitHubNotificationInventory,
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        organizationLogin: String,
        coverage: CoverageRecord,
        observedAt: Date
    ) async throws {
        guard scope.accountID == vault.accountID,
              coverage.accountID == scope.accountID,
              coverage.organizationID == scope.organizationID,
              coverage.feature == .notifications,
              coverage.streamID == streamID,
              coverage.credentialRevision == scope.credentialRevision,
              coverage.capabilityRevision == scope.capabilityRevision,
              coverage.status == .complete
        else { throw GitHubNotificationSourceRepositoryError.accountScopeMismatch }
        try await vault.writeTransaction { database in
            try Self.validateCurrentScope(scope, in: database)
            let prepared = try Self.preparePages(inventory.pages, scope: scope, streamID: streamID, observedAt: observedAt)
            let sourceRevision = Self.sourceRevision(prepared)
            let selected = inventory.notifications.filter {
                $0.repository.owner.login.caseInsensitiveCompare(organizationLogin) == .orderedSame
            }
            guard Set(selected.map(\.id)).count == selected.count else {
                throw GitHubNotificationSourceRepositoryError.invalidAuthority
            }
            let rawByNotificationID = try Self.rawPageByNotificationID(
                inventory.pages,
                prepared: prepared,
                selectedIDs: Set(selected.map(\.id))
            )
            for page in prepared {
                try Self.save(page.snapshot, rejectingConflictAt: observedAt, in: database)
            }
            // The page and receipt tables have a composite foreign key to the
            // exact stream. Coverage creates that stream in this same atomic
            // transaction; no completed state is externally visible until all
            // raw, membership, metadata, and validator writes also succeed.
            try CoverageRepository.save(
                coverage,
                attemptedAt: observedAt,
                expectedAccountID: scope.accountID,
                in: database
            )
            try Self.replaceCurrentPages(
                prepared,
                scope: scope,
                streamID: streamID,
                sourceRevision: sourceRevision,
                observedAt: observedAt,
                in: database
            )
            for notification in selected {
                guard let rawSnapshotID = rawByNotificationID[notification.id] else {
                    throw GitHubNotificationSourceRepositoryError.invalidPageTopology
                }
                try Self.saveNotification(
                    notification,
                    rawSnapshotID: rawSnapshotID,
                    sourceRevision: sourceRevision,
                    scope: scope,
                    observedAt: observedAt,
                    in: database
                )
            }
            let identity = Self.firstPageIdentity(scope: scope, streamID: streamID)
            if let firstPage = prepared.first,
               firstPage.snapshot.eTag != nil || firstPage.snapshot.lastModified != nil {
                try ConditionalRequestCacheRepository.save(
                    .init(
                        identity: identity,
                        eTag: firstPage.snapshot.eTag,
                        lastModified: firstPage.snapshot.lastModified,
                        observedAt: observedAt
                    ),
                    expectedAccountID: scope.accountID,
                    in: database
                )
                try Self.saveReplayReceipt(
                    sourceRevision: sourceRevision,
                    notifications: selected,
                    firstPage: firstPage,
                    identity: identity,
                    observedAt: observedAt,
                    in: database
                )
            } else {
                try ConditionalRequestCacheRepository.remove(
                    for: identity,
                    expectedAccountID: scope.accountID,
                    in: database
                )
                try database.execute(sql: """
                    DELETE FROM notification_replay_receipts
                    WHERE account_id = ? AND organization_id = ? AND feature = ? AND stream_id = ?
                      AND request_key = ? AND credential_revision = ? AND capability_revision = ?
                    """, arguments: Self.identityArguments(identity))
            }
        }
    }

    func recordFailure(
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        organizationLogin: String,
        pages: [GitHubNotificationPage],
        classification: GitHubNotificationFailureClassification,
        coverage: CoverageRecord,
        observedAt: Date
    ) async throws {
        guard scope.accountID == vault.accountID,
              coverage.accountID == scope.accountID,
              coverage.organizationID == scope.organizationID,
              coverage.feature == .notifications,
              coverage.streamID == streamID,
              coverage.status != .complete
        else { throw GitHubNotificationSourceRepositoryError.accountScopeMismatch }
        try await vault.writeTransaction { database in
            try Self.validateCurrentScope(scope, in: database)
            let prepared = try Self.preparePages(pages, scope: scope, streamID: streamID, observedAt: observedAt)
            for page in prepared {
                try Self.save(page.snapshot, rejectingConflictAt: observedAt, in: database)
            }
            try CoverageRepository.save(
                coverage,
                attemptedAt: observedAt,
                expectedAccountID: scope.accountID,
                in: database
            )
            try Self.saveFailureEnvelope(
                scope: scope,
                streamID: streamID,
                pages: prepared,
                classification: classification,
                observedAt: observedAt,
                in: database
            )
            _ = organizationLogin // Target filtering does not change failure authority.
        }
    }

    private struct PreparedPage {
        let index: Int
        let requestKey: String
        let isTerminal: Bool
        let notificationIDs: Set<String>
        let snapshot: RawAPISnapshot
    }

    private struct CurrentPageRow {
        let index: Int
        let rawSnapshotID: RawAPISnapshotID
        let isTerminal: Bool
    }

    private nonisolated static func preparePages(
        _ pages: [GitHubNotificationPage],
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        observedAt: Date
    ) throws -> [PreparedPage] {
        guard !pages.isEmpty, pages.count <= 100 else {
            throw GitHubNotificationSourceRepositoryError.invalidPageTopology
        }
        return try pages.enumerated().map { offset, page in
            let index = offset + 1
            let requestKey = try notificationRequestKey(endpoint: page.endpoint, pageIndex: index)
            let ids = page.page.values.map(\.id)
            guard Set(ids).count == ids.count,
                  page.page.payload.count <= RawAPISnapshotRepository.maximumPayloadBytes
            else { throw GitHubNotificationSourceRepositoryError.invalidPageTopology }
            let identity = ConditionalRequestIdentity(
                scope: scope,
                feature: .notifications,
                streamID: streamID,
                requestKey: requestKey
            )
            let snapshot = RawAPISnapshot(
                id: snapshotID(identity: identity, payload: page.page.payload, observedAt: observedAt),
                accountID: scope.accountID,
                githubNodeID: nil,
                endpoint: page.endpoint,
                eTag: page.page.etag,
                lastModified: page.page.lastModified,
                parserVersion: parserVersion,
                observedAt: observedAt,
                payload: page.page.payload,
                requestIdentity: identity
            )
            return PreparedPage(
                index: index,
                requestKey: requestKey,
                isTerminal: page.page.nextPageURL == nil,
                notificationIDs: Set(ids),
                snapshot: snapshot
            )
        }
    }

    private nonisolated static func rawPageByNotificationID(
        _ pages: [GitHubNotificationPage],
        prepared: [PreparedPage],
        selectedIDs: Set<String>
    ) throws -> [String: RawAPISnapshotID] {
        guard pages.count == prepared.count else { throw GitHubNotificationSourceRepositoryError.invalidPageTopology }
        var result = [String: RawAPISnapshotID]()
        for (page, prepared) in zip(pages, prepared) {
            for notification in page.page.values where selectedIDs.contains(notification.id) {
                guard result[notification.id] == nil else {
                    throw GitHubNotificationSourceRepositoryError.invalidPageTopology
                }
                result[notification.id] = prepared.snapshot.id
            }
        }
        guard result.count == selectedIDs.count else { throw GitHubNotificationSourceRepositoryError.invalidPageTopology }
        return result
    }

    private nonisolated static func save(_ snapshot: RawAPISnapshot, rejectingConflictAt observedAt: Date, in database: Database) throws {
        guard let identity = snapshot.requestIdentity else { throw GitHubNotificationSourceRepositoryError.invalidAuthority }
        let existing = try Data.fetchAll(database, sql: """
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
        guard existing.allSatisfy({ $0 == snapshot.payload }) else {
            throw GitHubNotificationSourceRepositoryError.conflictingRawPage
        }
        try RawAPISnapshotRepository.save(snapshot, in: database)
    }

    private nonisolated static func replaceCurrentPages(
        _ pages: [PreparedPage],
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        sourceRevision: String,
        observedAt: Date,
        in database: Database
    ) throws {
        guard pages.enumerated().allSatisfy({ $0.offset + 1 == $0.element.index }),
              pages.filter(\.isTerminal).count == 1,
              pages.last?.isTerminal == true
        else { throw GitHubNotificationSourceRepositoryError.invalidPageTopology }
        try database.execute(sql: """
            DELETE FROM notification_current_pages
            WHERE account_id = ? AND organization_id = ? AND feature = ? AND stream_id = ?
              AND credential_revision = ? AND capability_revision = ?
            """, arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue, CoverageFeature.notifications.rawValue,
                streamID.rawValue, scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue
            ])
        for page in pages {
            try database.execute(sql: """
                INSERT INTO notification_current_pages (
                    account_id, organization_id, feature, stream_id, credential_revision,
                    capability_revision, source_revision, page_index, raw_snapshot_id,
                    request_key, observed_at_ms, is_terminal
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    scope.accountID.rawValue, scope.organizationID.rawValue, CoverageFeature.notifications.rawValue,
                    streamID.rawValue, scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                    sourceRevision, page.index, page.snapshot.id.rawValue, page.requestKey,
                    milliseconds(observedAt), page.isTerminal
                ])
        }
    }

    private nonisolated static func saveNotification(
        _ notification: GitHubNotificationDTO,
        rawSnapshotID: RawAPISnapshotID,
        sourceRevision: String,
        scope: SynchronizationScope,
        observedAt: Date,
        in database: Database
    ) throws {
        try database.execute(sql: """
            INSERT INTO notification_threads (
                account_id, organization_id, notification_id, repository_node_id, reason,
                is_unread, subject_type, subject_title, subject_url, updated_at_ms,
                last_read_at_ms, source_revision, raw_snapshot_id, credential_revision,
                capability_revision, observed_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, organization_id, notification_id) DO UPDATE SET
                repository_node_id = excluded.repository_node_id,
                reason = excluded.reason,
                is_unread = excluded.is_unread,
                subject_type = excluded.subject_type,
                subject_title = excluded.subject_title,
                subject_url = excluded.subject_url,
                updated_at_ms = excluded.updated_at_ms,
                last_read_at_ms = excluded.last_read_at_ms,
                source_revision = excluded.source_revision,
                raw_snapshot_id = excluded.raw_snapshot_id,
                credential_revision = excluded.credential_revision,
                capability_revision = excluded.capability_revision,
                observed_at_ms = excluded.observed_at_ms
            """, arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue, notification.id,
                notification.repository.nodeID, notification.reason, notification.unread,
                notification.subject.type, notification.subject.title, notification.subject.url?.absoluteString,
                milliseconds(notification.updatedAt), notification.lastReadAt.map(milliseconds), sourceRevision,
                rawSnapshotID.rawValue, scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                milliseconds(observedAt)
            ])
    }

    private nonisolated static func saveReplayReceipt(
        sourceRevision: String,
        notifications: [GitHubNotificationDTO],
        firstPage: PreparedPage?,
        identity: ConditionalRequestIdentity,
        observedAt: Date,
        in database: Database
    ) throws {
        guard let firstPage else { throw GitHubNotificationSourceRepositoryError.invalidPageTopology }
        try database.execute(sql: """
            INSERT INTO notification_replay_receipts (
                account_id, organization_id, feature, stream_id, request_key, credential_revision,
                capability_revision, etag, last_modified, parser_version, source_revision,
                notification_count, notification_digest, completed_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, organization_id, feature, stream_id, request_key,
                        credential_revision, capability_revision) DO UPDATE SET
                etag = excluded.etag, last_modified = excluded.last_modified,
                parser_version = excluded.parser_version, source_revision = excluded.source_revision,
                notification_count = excluded.notification_count,
                notification_digest = excluded.notification_digest,
                completed_at_ms = excluded.completed_at_ms
            """, arguments: [
                identity.scope.accountID.rawValue, identity.scope.organizationID.rawValue,
                identity.feature.rawValue, identity.streamID.rawValue, identity.requestKey,
                identity.scope.credentialRevision.rawValue, identity.scope.capabilityRevision.rawValue,
                firstPage.snapshot.eTag, firstPage.snapshot.lastModified, parserVersion, sourceRevision,
                notifications.count, digest(notifications), milliseconds(observedAt)
            ])
    }

    private nonisolated static func saveFailureEnvelope(
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        pages: [PreparedPage],
        classification: GitHubNotificationFailureClassification,
        observedAt: Date,
        in database: Database
    ) throws {
        let failureID = UUID().uuidString.lowercased()
        let (kind, retryAt) = failureFields(classification)
        try database.execute(sql: """
            INSERT INTO notification_failure_envelopes (
                id, account_id, organization_id, feature, stream_id, credential_revision,
                capability_revision, classification, retry_at_ms, observed_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                failureID, scope.accountID.rawValue, scope.organizationID.rawValue,
                CoverageFeature.notifications.rawValue, streamID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                kind, retryAt.map(milliseconds), milliseconds(observedAt)
            ])
        for page in pages {
            try database.execute(sql: """
                INSERT INTO notification_failure_pages (failure_id, raw_snapshot_id, page_index)
                VALUES (?, ?, ?)
                """, arguments: [failureID, page.snapshot.id.rawValue, page.index])
        }
    }

    private nonisolated static func currentPageRows(
        identity: ConditionalRequestIdentity,
        sourceRevision: String,
        in database: Database
    ) throws -> [CurrentPageRow] {
        let rows = try Row.fetchAll(database, sql: """
            SELECT page_index, raw_snapshot_id, is_terminal
            FROM notification_current_pages
            WHERE account_id = ? AND organization_id = ? AND feature = ? AND stream_id = ?
              AND credential_revision = ? AND capability_revision = ? AND source_revision = ?
            ORDER BY page_index
            """, arguments: [
                identity.scope.accountID.rawValue, identity.scope.organizationID.rawValue, identity.feature.rawValue,
                identity.streamID.rawValue, identity.scope.credentialRevision.rawValue,
                identity.scope.capabilityRevision.rawValue, sourceRevision
            ])
        let decoded = try rows.map { row -> CurrentPageRow in
            guard let index: Int = row["page_index"],
                  let rawID = (row["raw_snapshot_id"] as String?).flatMap(RawAPISnapshotID.init(rawValue:)),
                  let isTerminal: Bool = row["is_terminal"]
            else { throw GitHubNotificationSourceRepositoryError.invalidPersistedData }
            return .init(index: index, rawSnapshotID: rawID, isTerminal: isTerminal)
        }
        guard decoded.enumerated().allSatisfy({ $0.offset + 1 == $0.element.index }) else {
            throw GitHubNotificationSourceRepositoryError.invalidPersistedData
        }
        return decoded
    }

    private nonisolated static func allNotificationRowsBindToCurrentPages(_ rows: [Row], pages: [CurrentPageRow]) -> Bool {
        let validIDs = Set(pages.map(\.rawSnapshotID.rawValue))
        return rows.allSatisfy { row in
            guard let rawSnapshotID: String = row["raw_snapshot_id"] else { return false }
            return validIDs.contains(rawSnapshotID)
        }
    }

    private nonisolated static func sourceRevision(_ pages: [PreparedPage]) -> String {
        digest(pages.map { "\($0.index):\($0.snapshot.id.rawValue)" })
    }

    private nonisolated static func digest(_ notifications: [GitHubNotificationDTO]) -> String {
        digest(notifications.sorted { $0.id < $1.id }.map {
            [
                $0.id, $0.repository.nodeID, $0.reason, String($0.unread), $0.subject.type,
                $0.subject.title, $0.subject.url?.absoluteString ?? "", String(milliseconds($0.updatedAt)),
                $0.lastReadAt.map(milliseconds).map(String.init) ?? ""
            ].joined(separator: "\u{1F}")
        })
    }

    private nonisolated static func digest(_ rows: [Row]) -> String {
        digest(rows.compactMap { row in
            guard let id: String = row["notification_id"],
                  let repositoryNodeID: String = row["repository_node_id"],
                  let reason: String = row["reason"],
                  let unread: Bool = row["is_unread"],
                  let subjectType: String = row["subject_type"],
                  let subjectTitle: String = row["subject_title"],
                  let updatedAt: Int64 = row["updated_at_ms"]
            else { return nil }
            let subjectURL: String = row["subject_url"] ?? ""
            let lastReadAt: Int64? = row["last_read_at_ms"]
            return [id, repositoryNodeID, reason, String(unread), subjectType, subjectTitle, subjectURL,
                    String(updatedAt), lastReadAt.map(String.init) ?? ""]
                .joined(separator: "\u{1F}")
        })
    }

    private nonisolated static func digest(_ values: [String]) -> String {
        SHA256.hash(data: Data(values.sorted().joined(separator: "\u{1E}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func notificationRequestKey(endpoint: String, pageIndex: Int) throws -> String {
        let expected = pageIndex == 1
            ? "/notifications?all=true&participating=false&per_page=100"
            : "/notifications?all=true&participating=false&per_page=100&page=\(pageIndex)"
        guard endpoint == expected else { throw GitHubNotificationSourceRepositoryError.invalidPageTopology }
        return "GET \(expected)"
    }

    private nonisolated static func firstPageIdentity(scope: SynchronizationScope, streamID: SyncStreamID) -> ConditionalRequestIdentity {
        .init(scope: scope, feature: .notifications, streamID: streamID, requestKey: GitHubNotificationClient.firstPageRequestKey)
    }

    private nonisolated static func snapshotID(identity: ConditionalRequestIdentity, payload: Data, observedAt: Date) -> RawAPISnapshotID {
        let material = [identity.scope.accountID.rawValue, identity.scope.organizationID.rawValue,
                        identity.feature.rawValue, identity.streamID.rawValue, identity.requestKey,
                        identity.scope.credentialRevision.rawValue, identity.scope.capabilityRevision.rawValue,
                        String(milliseconds(observedAt)), String(parserVersion), digest([payload.base64EncodedString()])]
            .joined(separator: "\u{1F}")
        let hash = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return RawAPISnapshotID(rawValue: "notification:\(hash)")!
    }

    private nonisolated static func identityArguments(_ identity: ConditionalRequestIdentity) -> StatementArguments {
        [identity.scope.accountID.rawValue, identity.scope.organizationID.rawValue, identity.feature.rawValue,
         identity.streamID.rawValue, identity.requestKey, identity.scope.credentialRevision.rawValue,
         identity.scope.capabilityRevision.rawValue]
    }

    private nonisolated static func failureFields(_ classification: GitHubNotificationFailureClassification) -> (String, Date?) {
        switch classification {
        case .ssoRequired: ("ssoRequired", nil)
        case .approvalRequired: ("approvalRequired", nil)
        case .authenticationRequired: ("authenticationRequired", nil)
        case let .rateLimited(retryAt): ("rateLimited", retryAt)
        case .unavailableOrPermission: ("unavailableOrPermission", nil)
        case .integrity: ("integrity", nil)
        case .transient: ("transient", nil)
        }
    }

    private nonisolated static func validateCurrentScope(_ scope: SynchronizationScope, in database: Database) throws {
        do {
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
        } catch OrganizationSchedulerStateRepositoryError.staleSynchronizationScope,
                OrganizationSchedulerStateRepositoryError.organizationScopeMismatch {
            throw GitHubNotificationSourceRepositoryError.staleSynchronizationScope
        }
    }

    private nonisolated static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isHexDigit) }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
