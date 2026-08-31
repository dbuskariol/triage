import Foundation
import GRDB
import XCTest
@testable import Triage

final class NotificationSourceMigrationTests: XCTestCase {
    func testNotificationSourceSchemaHasScopedTablesIndexesAndProvenanceGuards() async throws {
        let fixture = try await NotificationSourceMigrationFixture()
        defer { fixture.remove() }

        let schema = try await fixture.vault.read { database -> (Set<String>, Set<String>, Set<String>) in
            let tables = try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'notification_%'"
            )
            let indexes = try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'notification_%'"
            )
            let triggers = try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'notification_%'"
            )
            return (Set(tables), Set(indexes), Set(triggers))
        }

        XCTAssertTrue(schema.0.isSuperset(of: Set([
            "notification_threads",
            "notification_current_pages",
            "notification_replay_receipts",
            "notification_failure_envelopes",
            "notification_failure_pages"
        ])))
        XCTAssertTrue(schema.1.isSuperset(of: Set([
            "notification_threads_current_scope",
            "notification_threads_raw_snapshot",
            "notification_current_pages_scope",
            "notification_current_pages_raw_snapshot",
            "notification_replay_receipts_scope",
            "notification_failure_envelopes_scope",
            "notification_failure_pages_raw_snapshot"
        ])))
        XCTAssertEqual(schema.2, Set([
            "notification_protect_provenance_snapshot_delete",
            "notification_protect_provenance_snapshot_update"
        ]))
    }

    func testNotificationAuthorityChecksRejectUnboundedPageAndValidatorlessReceipt() async throws {
        let fixture = try await NotificationSourceMigrationFixture()
        defer { fixture.remove() }

        await XCTAssertThrowsErrorAsync {
            try await fixture.vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO notification_current_pages (
                            account_id, organization_id, feature, stream_id,
                            credential_revision, capability_revision, source_revision,
                            page_index, raw_snapshot_id, request_key, observed_at_ms, is_terminal
                        ) VALUES (?, ?, 'notifications', ?, ?, ?, ?, 101, ?, ?, ?, 1)
                        """,
                    arguments: [
                        fixture.accountID.rawValue,
                        fixture.organizationID.rawValue,
                        fixture.streamID.rawValue,
                        fixture.credentialRevision.rawValue,
                        fixture.capabilityRevision.rawValue,
                        fixture.sourceRevision,
                        fixture.currentSnapshotID.rawValue,
                        fixture.requestKey,
                        fixture.observedAtMilliseconds
                    ]
                )
            }
        }

        await XCTAssertThrowsErrorAsync {
            try await fixture.vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO notification_replay_receipts (
                            account_id, organization_id, feature, stream_id, request_key,
                            credential_revision, capability_revision, etag, last_modified,
                            parser_version, source_revision, notification_count,
                            notification_digest, completed_at_ms
                        ) VALUES (?, ?, 'notifications', ?, ?, ?, ?, NULL, NULL, 1, ?, 0, ?, ?)
                        """,
                    arguments: [
                        fixture.accountID.rawValue,
                        fixture.organizationID.rawValue,
                        fixture.streamID.rawValue,
                        fixture.requestKey,
                        fixture.credentialRevision.rawValue,
                        fixture.capabilityRevision.rawValue,
                        fixture.sourceRevision,
                        fixture.sourceRevision,
                        fixture.observedAtMilliseconds
                    ]
                )
            }
        }
    }

    func testNotificationProvenanceCannotBeUpdatedDeletedOrCompacted() async throws {
        let fixture = try await NotificationSourceMigrationFixture()
        defer { fixture.remove() }
        try await fixture.persistProvenanceReferences()

        for snapshotID in [fixture.threadSnapshotID, fixture.currentSnapshotID, fixture.failureSnapshotID] {
            await XCTAssertThrowsErrorAsync {
                try await fixture.vault.write { database in
                    try database.execute(
                        sql: "DELETE FROM raw_api_snapshots WHERE id = ?",
                        arguments: [snapshotID.rawValue]
                    )
                }
            }
        }

        await XCTAssertThrowsErrorAsync {
            try await fixture.vault.write { database in
                try database.execute(
                    sql: "UPDATE raw_api_snapshots SET payload = ? WHERE id = ?",
                    arguments: [Data("tampered".utf8), fixture.threadSnapshotID.rawValue]
                )
            }
        }

        let removed = try await RawAPISnapshotRepository(vault: fixture.vault).compact(
            accountID: fixture.accountID,
            retainingMostRecentPerSource: 1,
            before: fixture.date.addingTimeInterval(60)
        )
        XCTAssertEqual(removed, 0)
        let count = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")
        }
        XCTAssertEqual(count, 3)
    }
}

private final class NotificationSourceMigrationFixture: @unchecked Sendable {
    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "notification-migration-org")!
    let streamID = SyncStreamID(rawValue: "notification-migration-stream")!
    let credentialRevision = CredentialRevision(rawValue: "notification-credential")!
    let capabilityRevision = CapabilityRevision(rawValue: "notification-capability")!
    let date = Date(timeIntervalSinceReferenceDate: 9_000)
    let sourceRevision = String(repeating: "a", count: 64)
    let requestKey = "GET /notifications?all=true&participating=false&per_page=100"
    let threadSnapshotID = RawAPISnapshotID(rawValue: "notification-thread-snapshot")!
    let currentSnapshotID = RawAPISnapshotID(rawValue: "notification-current-snapshot")!
    let failureSnapshotID = RawAPISnapshotID(rawValue: "notification-failure-snapshot")!
    let vault: AccountVault

    var observedAtMilliseconds: Int64 {
        Self.milliseconds(date)
    }

    var scope: SynchronizationScope {
        .init(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )
    }

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        try await AccountRepository(vault: vault).save(
            GitHubAccount(
                id: accountID,
                githubUserID: 41,
                nodeID: GitHubNodeID(rawValue: "NOTIFICATION_MIGRATION_USER")!,
                login: "octocat",
                authenticationKind: .oauth,
                credentialID: CredentialID.make(),
                credentialStatus: .active,
                createdAt: date,
                lastValidatedAt: date
            ),
            credentialRevision: credentialRevision
        )
        try await AccountRepository(vault: vault).save(
            GitHubOrganization(
                id: organizationID,
                githubOrganizationID: 42,
                nodeID: GitHubNodeID(rawValue: "NOTIFICATION_MIGRATION_ORG")!,
                login: "acme"
            ),
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: capabilityRevision,
                capabilities: [],
                checkedAt: date
            ),
            selectedAt: date
        )
        try await SyncStreamRepository(vault: vault).save(
            SyncStream(
                id: streamID,
                accountID: accountID,
                organizationID: organizationID,
                feature: .notifications,
                highWater: nil,
                lastSuccessfulAt: nil,
                lastAttemptAt: nil,
                status: .partial,
                failureDetail: nil
            )
        )

        let repository = RawAPISnapshotRepository(vault: vault)
        for (id, offset) in [
            (threadSnapshotID, 0.0),
            (currentSnapshotID, 1.0),
            (failureSnapshotID, 2.0)
        ] {
            try await repository.save(
                RawAPISnapshot(
                    id: id,
                    accountID: accountID,
                    githubNodeID: nil,
                    endpoint: "/notifications?all=true&participating=false&per_page=100",
                    eTag: "etag-\(id.rawValue)",
                    lastModified: "Mon, 01 Jan 2024 00:00:00 GMT",
                    parserVersion: 1,
                    observedAt: date.addingTimeInterval(offset),
                    payload: Data("[]".utf8),
                    requestIdentity: .init(
                        scope: scope,
                        feature: .notifications,
                        streamID: streamID,
                        requestKey: requestKey
                    )
                )
            )
        }
    }

    func persistProvenanceReferences() async throws {
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO notification_threads (
                        account_id, organization_id, notification_id, repository_node_id, reason,
                        is_unread, subject_type, subject_title, subject_url, updated_at_ms,
                        last_read_at_ms, source_revision, raw_snapshot_id, credential_revision,
                        capability_revision, observed_at_ms
                    ) VALUES (?, ?, 'notification-1', 'NOTIFICATION_REPOSITORY', 'mention',
                              1, 'Issue', 'Test notification', NULL, ?, NULL, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue, observedAtMilliseconds,
                    sourceRevision, threadSnapshotID.rawValue, credentialRevision.rawValue,
                    capabilityRevision.rawValue, observedAtMilliseconds
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO notification_current_pages (
                        account_id, organization_id, feature, stream_id, credential_revision,
                        capability_revision, source_revision, page_index, raw_snapshot_id,
                        request_key, observed_at_ms, is_terminal
                    ) VALUES (?, ?, 'notifications', ?, ?, ?, ?, 1, ?, ?, ?, 1)
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue, streamID.rawValue,
                    credentialRevision.rawValue, capabilityRevision.rawValue, sourceRevision,
                    currentSnapshotID.rawValue, requestKey, observedAtMilliseconds
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO notification_failure_envelopes (
                        id, account_id, organization_id, feature, stream_id,
                        credential_revision, capability_revision, classification, retry_at_ms,
                        observed_at_ms
                    ) VALUES ('notification-failure', ?, ?, 'notifications', ?, ?, ?,
                              'rateLimited', NULL, ?)
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue, streamID.rawValue,
                    credentialRevision.rawValue, capabilityRevision.rawValue, observedAtMilliseconds
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO notification_failure_pages (failure_id, raw_snapshot_id, page_index)
                    VALUES ('notification-failure', ?, 1)
                    """,
                arguments: [failureSnapshotID.rawValue]
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping @Sendable () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        // Expected.
    }
}
