import Foundation
import GRDB
import XCTest
@testable import Triage

/// Exercises the storage boundary shared by the final migration tranche. The
/// individual repositories validate their domain semantics elsewhere; this
/// fixture verifies that their durable evidence keeps its guarantees after an
/// encrypted-vault restart.
final class Migration040044EncryptedDurabilityFixtureTests: XCTestCase {
    func testMigration040Through044EvidenceAndReceiptsSurviveEncryptedRestartAndCompaction() async throws {
        let fixture = try await Migration040044EncryptedFixture()
        defer { fixture.remove() }
        try await fixture.persistMatrix()
        try await fixture.registry.closeAll()

        assertVaultFiles(at: fixture.paths.directory, doNotContain: fixture.plaintextMarker)

        let reopenedRegistry = try VaultRegistry(rootDirectory: fixture.rootDirectory)
        let vault = try await reopenedRegistry.open(accountID: fixture.accountID, vaultKey: fixture.vaultKey)
        defer { Task { try? await reopenedRegistry.closeAll() } }

        let durableState = try await vault.read { database -> ([String: String], Int, Int, Int, Int, Data?) in
            let migrations = Dictionary(uniqueKeysWithValues: try Row.fetchAll(
                database,
                sql: """
                    SELECT id, checksum FROM schema_migrations
                    WHERE id IN (
                        '040-review-candidate-failure-envelopes',
                        '041-notification-source-authority-v1',
                        '042-derived-intelligence-revision-evidence-v1',
                        '043-review-candidate-complete-traversal-receipts-v1',
                        '044-workspace-query-performance-indexes-v1',
                        '045-review-candidate-receipt-append-only-v1'
                    ) ORDER BY id
                    """
            ).map { row in
                ((row["id"] as String?) ?? "", (row["checksum"] as String?) ?? "")
            })
            return (
                migrations,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_candidate_failure_envelopes") ?? 0,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM notification_replay_receipts") ?? 0,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM rule_evaluation_evidence") ?? 0,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_candidate_complete_traversal_receipts") ?? 0,
                try Data.fetchOne(
                    database,
                    sql: "SELECT payload FROM raw_api_snapshots WHERE id = ?",
                    arguments: [fixture.discussionSnapshotID.rawValue]
                )
            )
        }

        XCTAssertEqual(durableState.0, [
            "040-review-candidate-failure-envelopes": "9241fecb2d6cffcfc87a91e553b8599f0913dc2e16b705fcd2b038cad30c5a81",
            "041-notification-source-authority-v1": "6e396d1e9e4142d866ad417b9845bcaa274bec64babb4b929ac3a42206153f7a",
            "042-derived-intelligence-revision-evidence-v1": "aee0510ac9a74c252acf9cf2d8227ebd7da278fa879d9fa64efa5a2370a0285f",
            "043-review-candidate-complete-traversal-receipts-v1": "1e339b7fbdaa9acafb7463f213ab27828b8d5e0a1d74cbb6d51a79c2620d8802",
            "044-workspace-query-performance-indexes-v1": "8b9e0ec0885167e950ef210c8d3a8697559ca1e1c897c41069830417afb90188",
            "045-review-candidate-receipt-append-only-v1": "a2f5e3bd86a41558c5f8e6c906c0e37318c4d9e511b7bb328fa1bcc765beed95"
        ])
        XCTAssertEqual(durableState.1, 1, "040 failure envelope must survive restart")
        XCTAssertEqual(durableState.2, 1, "041 notification receipt must survive restart")
        XCTAssertEqual(durableState.3, 1, "042 evidence binding must survive restart")
        XCTAssertEqual(durableState.4, 1, "043 review completion receipt must survive restart")
        XCTAssertEqual(durableState.5, Data("\(fixture.plaintextMarker)::discussion".utf8))

        let removed = try await RawAPISnapshotRepository(vault: vault).compact(
            accountID: fixture.accountID,
            retainingMostRecentPerSource: 1,
            before: fixture.date.addingTimeInterval(60)
        )
        XCTAssertEqual(removed, 2, "only superseded, unreferenced raw rows may compact")

        let retained = try await vault.read { database in
            Set(try String.fetchAll(database, sql: "SELECT id FROM raw_api_snapshots"))
        }
        XCTAssertTrue(retained.isSuperset(of: Set([
            fixture.failureSnapshotID.rawValue,
            fixture.notificationSnapshotID.rawValue,
            fixture.derivedEvidenceSnapshotID.rawValue,
            fixture.reviewReceiptSnapshotID.rawValue,
            fixture.newestSnapshotID.rawValue
        ])))
        XCTAssertFalse(retained.contains(fixture.discussionSnapshotID.rawValue))
        XCTAssertFalse(retained.contains(fixture.unprotectedSnapshotID.rawValue))
    }

    func testEncryptedFixtureAccountIsolationDoesNotLeakRawEvidenceAcrossVaults() async throws {
        let fixture = try await Migration040044EncryptedFixture()
        defer { fixture.remove() }
        try await fixture.persistMatrix()

        let isolatedAccountID = AccountID(rawValue: "migration-matrix-isolated-account")!
        let isolatedKey = try VaultKey.generate()
        let isolatedVault = try await fixture.registry.open(
            accountID: isolatedAccountID,
            vaultKey: isolatedKey
        )
        try await AccountRepository(vault: isolatedVault).save(
            GitHubAccount(
                id: isolatedAccountID,
                githubUserID: 4_045,
                nodeID: GitHubNodeID(rawValue: "MIGRATION_MATRIX_ISOLATED_USER")!,
                login: "matrix-isolated-user",
                authenticationKind: .oauth,
                credentialID: CredentialID(rawValue: "migration-matrix-isolated-credential")!,
                credentialStatus: .active,
                createdAt: fixture.date,
                lastValidatedAt: fixture.date
            ),
            credentialRevision: CredentialRevision(rawValue: "migration-matrix-isolated-revision")!
        )
        try await RawAPISnapshotRepository(vault: isolatedVault).save(
            RawAPISnapshot(
                id: RawAPISnapshotID(rawValue: "migration-matrix-isolated-raw")!,
                accountID: isolatedAccountID,
                githubNodeID: nil,
                endpoint: "/fixture/migration-matrix",
                eTag: "isolated",
                parserVersion: 1,
                observedAt: fixture.date,
                payload: Data("isolated-raw".utf8)
            )
        )

        let firstSnapshots = try await RawAPISnapshotRepository(vault: fixture.vault).snapshots(
            for: fixture.accountID,
            limit: 100
        )
        let secondSnapshots = try await RawAPISnapshotRepository(vault: isolatedVault).snapshots(
            for: isolatedAccountID,
            limit: 100
        )
        XCTAssertTrue(firstSnapshots.contains(where: { $0.id == fixture.failureSnapshotID }))
        XCTAssertFalse(firstSnapshots.contains(where: { $0.id.rawValue == "migration-matrix-isolated-raw" }))
        XCTAssertEqual(secondSnapshots.map(\.id.rawValue), ["migration-matrix-isolated-raw"])
        XCTAssertNotEqual(
            VaultPaths(rootDirectory: fixture.rootDirectory, accountID: fixture.accountID).directory,
            VaultPaths(rootDirectory: fixture.rootDirectory, accountID: isolatedAccountID).directory
        )
    }
}

private final class Migration040044EncryptedFixture: @unchecked Sendable {
    let rootDirectory: URL
    let accountID = AccountID(rawValue: "migration-matrix-account")!
    let organizationID = OrganizationID(rawValue: "migration-matrix-organization")!
    let reviewStreamID = SyncStreamID(rawValue: "migration-matrix-reviews")!
    let notificationStreamID = SyncStreamID(rawValue: "migration-matrix-notifications")!
    let credentialRevision = CredentialRevision(rawValue: "migration-matrix-credential")!
    let capabilityRevision = CapabilityRevision(rawValue: "migration-matrix-capability")!
    let vaultKey: VaultKey
    let registry: VaultRegistry
    let vault: AccountVault
    let date = Date(timeIntervalSinceReferenceDate: 50_000)
    let plaintextMarker = "migration-040-044-secret-marker"

    let failureSnapshotID = RawAPISnapshotID(rawValue: "migration-matrix-failure")!
    let notificationSnapshotID = RawAPISnapshotID(rawValue: "migration-matrix-notification")!
    let derivedEvidenceSnapshotID = RawAPISnapshotID(rawValue: "migration-matrix-derived")!
    let reviewReceiptSnapshotID = RawAPISnapshotID(rawValue: "migration-matrix-review-receipt")!
    let discussionSnapshotID = RawAPISnapshotID(rawValue: "migration-matrix-discussion")!
    let unprotectedSnapshotID = RawAPISnapshotID(rawValue: "migration-matrix-unprotected")!
    let newestSnapshotID = RawAPISnapshotID(rawValue: "migration-matrix-newest")!
    private let workItemID: WorkItemID

    var paths: VaultPaths {
        VaultPaths(rootDirectory: rootDirectory, accountID: accountID)
    }

    init() async throws {
        rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            ".migration-040-044-encrypted-fixtures-\(UUID().uuidString)",
            isDirectory: true
        )
        vaultKey = try VaultKey.generate()
        registry = try VaultRegistry(rootDirectory: rootDirectory)
        vault = try await registry.open(accountID: accountID, vaultKey: vaultKey)

        try await AccountRepository(vault: vault).save(
            GitHubAccount(
                id: accountID,
                githubUserID: 4_004,
                nodeID: GitHubNodeID(rawValue: "MIGRATION_MATRIX_USER")!,
                login: "matrix-user",
                authenticationKind: .oauth,
                credentialID: CredentialID(rawValue: "migration-matrix-credential-id")!,
                credentialStatus: .active,
                createdAt: date,
                lastValidatedAt: date
            ),
            credentialRevision: credentialRevision
        )
        try await AccountRepository(vault: vault).save(
            GitHubOrganization(
                id: organizationID,
                githubOrganizationID: 4_044,
                nodeID: GitHubNodeID(rawValue: "MIGRATION_MATRIX_ORGANIZATION")!,
                login: "matrix-org"
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
        for (id, feature) in [(reviewStreamID, CoverageFeature.reviews), (notificationStreamID, .notifications)] {
            try await SyncStreamRepository(vault: vault).save(
                SyncStream(
                    id: id,
                    accountID: accountID,
                    organizationID: organizationID,
                    feature: feature,
                    highWater: nil,
                    lastSuccessfulAt: nil,
                    lastAttemptAt: nil,
                    status: .complete,
                    failureDetail: nil
                )
            )
        }
        let node = NormalizedGitHubNode(
            nodeID: GitHubNodeID(rawValue: "MIGRATION_MATRIX_ISSUE")!,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: nil,
            kind: .issue,
            numericID: "4044",
            number: 4044,
            title: "Migration matrix issue",
            state: .open,
            url: URL(string: "https://github.com/matrix-org/matrix/issues/4044")!,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: date,
            updatedAt: date,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "migration-matrix-node-revision",
            observedAt: date,
            accessibility: .accessible
        )
        try await GitHubNodeRepository(vault: vault).save(node)
        workItemID = try await WorkItemRepository(vault: vault).ensureWorkItem(for: node)
    }

    func persistMatrix() async throws {
        let rawRepository = RawAPISnapshotRepository(vault: vault)
        let snapshots: [(RawAPISnapshotID, TimeInterval)] = [
            (failureSnapshotID, 0),
            (notificationSnapshotID, 1),
            (derivedEvidenceSnapshotID, 2),
            (reviewReceiptSnapshotID, 3),
            (discussionSnapshotID, 4),
            (unprotectedSnapshotID, 5),
            (newestSnapshotID, 120)
        ]
        for (id, offset) in snapshots {
            try await rawRepository.save(
                RawAPISnapshot(
                    id: id,
                    accountID: accountID,
                    githubNodeID: nil,
                    endpoint: "/fixture/migration-040-044/evidence",
                    eTag: "fixture-\(id.rawValue)",
                    parserVersion: 1,
                    observedAt: date.addingTimeInterval(offset),
                    payload: Data("\(plaintextMarker)::\(id.rawValue.replacingOccurrences(of: "migration-matrix-", with: ""))".utf8)
                )
            )
        }

        let milliseconds = Self.milliseconds(date)
        let sourceRevision = String(repeating: "a", count: 64)
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO review_candidate_failure_envelopes (
                        id, account_id, organization_id, feature, stream_id, candidate_node_id,
                        repository_id, request_key, credential_revision, capability_revision,
                        parser_version, attempted_at_ms, terminal_at_ms, classification,
                        redacted_diagnostic, raw_page_count
                    ) VALUES ('migration-matrix-failure-envelope', ?, ?, 'reviews', ?,
                              'MIGRATION_MATRIX_CANDIDATE', 'MIGRATION_MATRIX_REPOSITORY',
                              'GET /repos/matrix-org/matrix/pulls/4044/reviews', ?, ?, 1, ?, ?,
                              'transportFailure', 'network unavailable', 1)
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue, reviewStreamID.rawValue,
                    credentialRevision.rawValue, capabilityRevision.rawValue, milliseconds, milliseconds
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO review_candidate_failure_pages (
                        envelope_id, request_key, page_ordinal, raw_snapshot_id
                    ) VALUES ('migration-matrix-failure-envelope',
                              'GET /repos/matrix-org/matrix/pulls/4044/reviews', 1, ?)
                    """,
                arguments: [failureSnapshotID.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO notification_current_pages (
                        account_id, organization_id, feature, stream_id, credential_revision,
                        capability_revision, source_revision, page_index, raw_snapshot_id,
                        request_key, observed_at_ms, is_terminal
                    ) VALUES (?, ?, 'notifications', ?, ?, ?, ?, 1, ?,
                              'GET /notifications?all=true&participating=false&per_page=100', ?, 1)
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue, notificationStreamID.rawValue,
                    credentialRevision.rawValue, capabilityRevision.rawValue, sourceRevision,
                    notificationSnapshotID.rawValue, milliseconds
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO notification_replay_receipts (
                        account_id, organization_id, feature, stream_id, request_key,
                        credential_revision, capability_revision, etag, last_modified,
                        parser_version, source_revision, notification_count,
                        notification_digest, completed_at_ms
                    ) VALUES (?, ?, 'notifications', ?,
                              'GET /notifications?all=true&participating=false&per_page=100',
                              ?, ?, 'fixture-etag', NULL, 1, ?, 1, ?, ?)
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue, notificationStreamID.rawValue,
                    credentialRevision.rawValue, capabilityRevision.rawValue, sourceRevision,
                    sourceRevision, milliseconds
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO rule_evaluations (
                        id, account_id, organization_id, work_item_id, credential_revision,
                        capability_revision, source_revision, rule_id, rule_version, category,
                        strength, title, explanation, evaluated_at_ms
                    ) VALUES ('migration-matrix-evaluation', ?, ?, ?, ?, ?, ?,
                              'migrationMatrix', 1, 'pullRequest', 1,
                              'Migration evidence', 'Evidence must remain durable.', ?)
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue, workItemID.rawValue,
                    credentialRevision.rawValue, capabilityRevision.rawValue, sourceRevision, milliseconds
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO rule_evaluation_evidence (
                        rule_evaluation_id, evidence_id, source, source_locator_kind,
                        source_locator, authority_kind, authority_account_id,
                        authority_organization_id, authority_feature, authority_stream_id,
                        authority_credential_revision, authority_capability_revision,
                        source_node_id, source_event_id, source_revision, raw_snapshot_id,
                        confidence, confirmation, observed_at_ms, excerpt
                    ) VALUES ('migration-matrix-evaluation', 'migration-matrix-evidence',
                              'restReview', 'endpoint', '/repos/matrix-org/matrix/pulls/4044/reviews',
                              'github', ?, ?, 'reviews', ?, ?, ?, NULL, NULL, ?, ?,
                              'provisional', 'provisional', ?, NULL)
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue, reviewStreamID.rawValue,
                    credentialRevision.rawValue, capabilityRevision.rawValue, sourceRevision,
                    derivedEvidenceSnapshotID.rawValue, milliseconds
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO review_candidate_complete_traversal_receipts (
                        id, account_id, organization_id, feature, stream_id, candidate_node_id,
                        repository_id, candidate_source_revision, credential_revision,
                        capability_revision, parser_version, observed_at_ms, normalized_digest,
                        segment_count, page_count
                    ) VALUES ('migration-matrix-review-receipt', ?, ?, 'reviews', ?,
                              'MIGRATION_MATRIX_CANDIDATE', 'MIGRATION_MATRIX_REPOSITORY',
                              'migration-matrix-source', ?, ?, 1, ?, ?, 1, 1)
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue, reviewStreamID.rawValue,
                    credentialRevision.rawValue, capabilityRevision.rawValue, milliseconds,
                    Data(repeating: 0x42, count: 32)
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO review_candidate_complete_traversal_segments (
                        receipt_id, segment_key, segment_kind, parent_thread_node_id,
                        page_count, terminal_page_ordinal
                    ) VALUES ('migration-matrix-review-receipt', 'review-history',
                              'reviewHistory', NULL, 1, 1)
                    """
            )
            try database.execute(
                sql: """
                    INSERT INTO review_candidate_complete_traversal_pages (
                        receipt_id, segment_key, page_ordinal, raw_snapshot_id, request_key, is_terminal
                    ) VALUES ('migration-matrix-review-receipt', 'review-history', 1, ?,
                              'GET /repos/matrix-org/matrix/pulls/4044/reviews', 1)
                    """,
                arguments: [reviewReceiptSnapshotID.rawValue]
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

private func assertVaultFiles(at directory: URL, doNotContain plaintext: String) {
    let manager = FileManager.default
    let enumerator = manager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    while let file = enumerator?.nextObject() as? URL {
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe)
        else {
            continue
        }
        XCTAssertNil(
            data.range(of: Data(plaintext.utf8)),
            "plaintext leaked to \(file.lastPathComponent)"
        )
        XCTAssertFalse(data.starts(with: Data("SQLite format 3\0".utf8)), "unencrypted SQLite header in \(file.lastPathComponent)")
    }
}
