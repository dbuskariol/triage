import Foundation
import GRDB
import XCTest
@testable import Triage

final class EncryptedVaultPersistenceFixtureTests: XCTestCase {
    func testWrongVaultKeyCannotOpenPersistedEncryptedFixture() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let accountID = AccountID(rawValue: "encrypted-wrong-key")!
        let correctKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: root)
        _ = try await registry.open(accountID: accountID, vaultKey: correctKey)
        try await registry.closeAll()

        let reopenedRegistry = try VaultRegistry(rootDirectory: root)
        await assertThrowsAsync({
            _ = try await reopenedRegistry.open(
                accountID: accountID,
                vaultKey: try VaultKey.generate()
            )
        }) { _ in }
    }

    func testInterruptedDestructiveMigrationBackupCanRestorePriorEncryptedVault() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let accountID = AccountID(rawValue: "encrypted-migration-interruption")!
        let key = try VaultKey.generate()
        let paths = try await makePreMigration033Fixture(
            root: root,
            accountID: accountID,
            key: key
        )
        let interruptedVault = try AccountVault(
            accountID: accountID,
            vaultKey: key,
            rootDirectory: root
        )
        try await interruptedVault.write { database in
            try database.execute(sql: "CREATE TABLE migration_033_conflict (value TEXT NOT NULL)")
            try database.execute(sql: """
                CREATE INDEX role_search_page_replays_snapshot
                ON migration_033_conflict (value)
                """)
        }

        await assertThrowsAsync({
            try await interruptedVault.applyMigrations()
        }) { _ in }
        try await interruptedVault.close()

        let backup = paths.migrationBackups
            .appendingPathComponent("033-role-search-page-replay-v2.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(try Data(contentsOf: backup).starts(with: Data("SQLite format 3\0".utf8)))

        try restoreDatabase(at: paths.database, from: backup)
        let restoredVault = try AccountVault(
            accountID: accountID,
            vaultKey: key,
            rootDirectory: root
        )
        let restoredState = try await restoredVault.read { database in
            (
                try String.fetchOne(
                    database,
                    sql: "SELECT query_value FROM role_search_page_replays"
                ),
                try String.fetchOne(
                    database,
                    sql: "SELECT checksum FROM schema_migrations WHERE id = '033-role-search-page-replay-v2'"
                )
            )
        }
        XCTAssertEqual(restoredState.0, "org:legacy is:open")
        XCTAssertNil(restoredState.1)
        // The deliberately injected name collision is part of the captured
        // pre-migration state. Remove that test-only blocker before proving a
        // restored vault can continue its normal migration path.
        try await restoredVault.write { database in
            try database.execute(sql: "DROP INDEX role_search_page_replays_snapshot")
            try database.execute(sql: "DROP TABLE migration_033_conflict")
        }
        try await restoredVault.close()

        let registry = try VaultRegistry(rootDirectory: root)
        let migrated = try await registry.open(accountID: accountID, vaultKey: key)
        let count = try await migrated.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM schema_migrations")
        }
        XCTAssertEqual(count, TriageDatabaseMigrator.migrationCount)
        try await registry.closeAll()
    }

    func testLatestSchemaReopensIdempotentlyWithStableChecksums() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let accountID = AccountID(rawValue: "encrypted-latest-schema")!
        let key = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: root)
        let vault = try await registry.open(accountID: accountID, vaultKey: key)
        let firstMigrations = try await migrationRows(in: vault)
        try await registry.closeAll()

        let reopenedRegistry = try VaultRegistry(rootDirectory: root)
        let reopenedVault = try await reopenedRegistry.open(accountID: accountID, vaultKey: key)
        let reopenedMigrations = try await migrationRows(in: reopenedVault)

        XCTAssertEqual(firstMigrations, reopenedMigrations)
        XCTAssertEqual(reopenedMigrations.count, TriageDatabaseMigrator.migrationCount)
        XCTAssertEqual(reopenedMigrations.last?.id, "045-review-candidate-receipt-append-only-v1")
        XCTAssertEqual(
            reopenedMigrations.last?.checksum,
            "a2f5e3bd86a41558c5f8e6c906c0e37318c4d9e511b7bb328fa1bcc765beed95"
        )
        XCTAssertTrue(reopenedMigrations.allSatisfy { migration in
            migration.checksum.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ) != nil
        })
        try await reopenedRegistry.closeAll()
    }

    func testPersistedSchema039EncryptedVaultUpgradesThrough045WithStableChecksums() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let accountID = AccountID(rawValue: "encrypted-schema-039-upgrade")!
        let key = try VaultKey.generate()
        let paths = try await makePersistedSchema039Fixture(
            root: root,
            accountID: accountID,
            key: key
        )
        let schema039State = try persistedSchemaState(at: paths.database, key: key)
        let schema039Migrations = schema039State.migrations
        XCTAssertEqual(schema039Migrations.last?.id, "039-timeline-current-page-membership")
        XCTAssertFalse(schema039State.hasFailureEnvelopes)

        let registry = try VaultRegistry(rootDirectory: root)
        let upgradedVault = try await registry.open(accountID: accountID, vaultKey: key)
        let upgradedMigrations = try await migrationRows(in: upgradedVault)
        XCTAssertEqual(Array(upgradedMigrations.suffix(6)), [
            MigrationRow(
                id: "040-review-candidate-failure-envelopes",
                checksum: "9241fecb2d6cffcfc87a91e553b8599f0913dc2e16b705fcd2b038cad30c5a81"
            ),
            MigrationRow(
                id: "041-notification-source-authority-v1",
                checksum: "6e396d1e9e4142d866ad417b9845bcaa274bec64babb4b929ac3a42206153f7a"
            ),
            MigrationRow(
                id: "042-derived-intelligence-revision-evidence-v1",
                checksum: "aee0510ac9a74c252acf9cf2d8227ebd7da278fa879d9fa64efa5a2370a0285f"
            ),
            MigrationRow(
                id: "043-review-candidate-complete-traversal-receipts-v1",
                checksum: "1e339b7fbdaa9acafb7463f213ab27828b8d5e0a1d74cbb6d51a79c2620d8802"
            ),
            MigrationRow(
                id: "044-workspace-query-performance-indexes-v1",
                checksum: "8b9e0ec0885167e950ef210c8d3a8697559ca1e1c897c41069830417afb90188"
            ),
            MigrationRow(
                id: "045-review-candidate-receipt-append-only-v1",
                checksum: "a2f5e3bd86a41558c5f8e6c906c0e37318c4d9e511b7bb328fa1bcc765beed95"
            )
        ])
        let upgradedSchema = try await upgradedVault.read { database in
            (
                try database.tableExists("review_candidate_failure_envelopes"),
                try database.tableExists("notification_replay_receipts"),
                try database.tableExists("derived_intelligence_runs"),
                try database.tableExists("review_candidate_complete_traversal_receipts"),
                (try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?",
                    arguments: ["workspace_work_items_scope_activity"]
                ) ?? 0) == 1
            )
        }
        XCTAssertEqual(upgradedSchema.0, true)
        XCTAssertEqual(upgradedSchema.1, true)
        XCTAssertEqual(upgradedSchema.2, true)
        XCTAssertEqual(upgradedSchema.3, true)
        XCTAssertEqual(upgradedSchema.4, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.database.path))
        try await registry.closeAll()
    }

    func testPhysicalEncryptedDatabaseByteTamperFailsClosedOnNextOpen() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let accountID = AccountID(rawValue: "encrypted-byte-tamper")!
        let key = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: root)
        let vault = try await registry.open(accountID: accountID, vaultKey: key)
        try await vault.write { database in
            try database.execute(sql: "CREATE TABLE tamper_fixture (payload BLOB NOT NULL)")
            try database.execute(
                sql: "INSERT INTO tamper_fixture (payload) VALUES (?)",
                arguments: [Data(repeating: 0x5A, count: 8_192)]
            )
        }
        try await registry.closeAll()

        let paths = VaultPaths(rootDirectory: root, accountID: accountID)
        let sidecars = [
            URL(fileURLWithPath: paths.database.path + "-wal"),
            URL(fileURLWithPath: paths.database.path + "-shm")
        ]
        for sidecar in sidecars where FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.removeItem(at: sidecar)
        }
        var encryptedDatabase = try Data(contentsOf: paths.database)
        XCTAssertGreaterThan(encryptedDatabase.count, 1_024)
        XCTAssertFalse(encryptedDatabase.starts(with: Data("SQLite format 3\0".utf8)))
        encryptedDatabase[encryptedDatabase.count - 1] ^= 0x01
        try encryptedDatabase.write(to: paths.database, options: .atomic)

        let tamperedRegistry = try VaultRegistry(rootDirectory: root)
        await assertThrowsAsync({
            _ = try await tamperedRegistry.open(accountID: accountID, vaultKey: key)
        }) { _ in }
    }

    func testCorruptPersistedAccountRowFailsClosedAfterReopen() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let account = makeAccount(id: "encrypted-corrupt-row", credentialID: "credential-valid")
        let key = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: root)
        let vault = try await registry.open(accountID: account.id, vaultKey: key)
        try await AccountRepository(vault: vault).save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-revision-valid")!
        )
        try await vault.write { database in
            try database.execute(
                sql: "UPDATE accounts SET credential_id = '' WHERE id = ?",
                arguments: [account.id.rawValue]
            )
        }
        try await registry.closeAll()

        let reopenedRegistry = try VaultRegistry(rootDirectory: root)
        let reopenedVault = try await reopenedRegistry.open(accountID: account.id, vaultKey: key)
        await assertThrowsAsync({
            _ = try await AccountRepository(vault: reopenedVault).accounts()
        }) { error in
            XCTAssertEqual(error as? AccountRepositoryError, .invalidPersistedIdentifier)
        }
        try await reopenedRegistry.closeAll()
    }

    func testCredentialAndCapabilityRevisionsPersistAsOneRotatedScope() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let account = makeAccount(id: "encrypted-rotation", credentialID: "credential-old")
        let organizationID = OrganizationID(rawValue: "encrypted-rotation-org")!
        let organization = GitHubOrganization(
            id: organizationID,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "O_encrypted_rotation")!,
            login: "encrypted-rotation-org"
        )
        let key = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: root)
        let vault = try await registry.open(accountID: account.id, vaultKey: key)
        let repository = AccountRepository(vault: vault)
        let oldAccess = OrganizationAccess(
            accountID: account.id,
            organizationID: organizationID,
            state: .available,
            capabilityRevision: CapabilityRevision(rawValue: "capability-old")!,
            capabilities: [
                CapabilityAvailability(
                    capability: .privateRepositories,
                    status: .available,
                    checkedAt: fixtureDate
                )
            ],
            checkedAt: fixtureDate
        )
        try await repository.save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-old")!
        )
        try await repository.save(organization, access: oldAccess)

        let rotatedAccount = account.replacingCredential(
            credentialID: CredentialID(rawValue: "credential-new")!,
            login: account.login,
            displayName: account.displayName,
            avatarURL: account.avatarURL,
            accessTokenExpiresAt: nil,
            refreshTokenExpiresAt: nil,
            status: .active,
            validatedAt: fixtureDate.addingTimeInterval(60)
        )
        let rotatedAccess = OrganizationAccess(
            accountID: account.id,
            organizationID: organizationID,
            state: .available,
            capabilityRevision: CapabilityRevision(rawValue: "capability-new")!,
            capabilities: [
                CapabilityAvailability(
                    capability: .privateRepositories,
                    status: .unavailable,
                    checkedAt: fixtureDate.addingTimeInterval(60)
                )
            ],
            checkedAt: fixtureDate.addingTimeInterval(60)
        )
        try await repository.save(
            rotatedAccount,
            credentialRevision: CredentialRevision(rawValue: "credential-new")!
        )
        try await repository.save(organization, access: rotatedAccess)
        try await registry.closeAll()

        let reopenedRegistry = try VaultRegistry(rootDirectory: root)
        let reopenedVault = try await reopenedRegistry.open(accountID: account.id, vaultKey: key)
        let reopenedRepository = AccountRepository(vault: reopenedVault)
        let reopenedAccounts = try await reopenedRepository.accounts()
        let reopenedAccesses = try await reopenedRepository.organizationAccesses(for: account.id)
        XCTAssertEqual(reopenedAccounts, [rotatedAccount])
        XCTAssertEqual(
            reopenedAccesses[organizationID],
            rotatedAccess
        )
        let scope = try await reopenedRepository.synchronizationScope(
            for: account.id,
            organizationID: organizationID
        )
        XCTAssertEqual(scope.credentialRevision, CredentialRevision(rawValue: "credential-new")!)
        XCTAssertEqual(scope.capabilityRevision, CapabilityRevision(rawValue: "capability-new")!)
        try await reopenedRegistry.closeAll()
    }

    func testAccountVaultsRemainIsolatedOnDiskAndAtReadBoundary() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstAccountID = AccountID(rawValue: "encrypted-isolation-first")!
        let secondAccountID = AccountID(rawValue: "encrypted-isolation-second")!
        let firstKey = try VaultKey.generate()
        let secondKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: root)
        let firstVault = try await registry.open(accountID: firstAccountID, vaultKey: firstKey)
        let secondVault = try await registry.open(accountID: secondAccountID, vaultKey: secondKey)
        try await firstVault.write { database in
            try database.execute(sql: "CREATE TABLE first_account_only (value TEXT NOT NULL)")
            try database.execute(sql: "INSERT INTO first_account_only (value) VALUES ('first')")
        }

        let secondSeesFirstTable = try await secondVault.read { database in
            try database.tableExists("first_account_only")
        }
        XCTAssertFalse(secondSeesFirstTable)
        XCTAssertNotEqual(
            VaultPaths(rootDirectory: root, accountID: firstAccountID).directory,
            VaultPaths(rootDirectory: root, accountID: secondAccountID).directory
        )
        try await registry.closeAll()

        let reopenRegistry = try VaultRegistry(rootDirectory: root)
        await assertThrowsAsync({
            _ = try await reopenRegistry.open(accountID: firstAccountID, vaultKey: secondKey)
        }) { _ in }
    }

    func testMissingVaultKeyLeavesOnlyThatAccountUnavailableDuringRestoration() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let availableAccount = makeAccount(id: "encrypted-key-present", credentialID: "credential-present")
        let missingAccountID = AccountID(rawValue: "encrypted-key-missing")!
        let availableKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: root)
        let vault = try await registry.open(accountID: availableAccount.id, vaultKey: availableKey)
        try await AccountRepository(vault: vault).save(
            availableAccount,
            credentialRevision: CredentialRevision(rawValue: "credential-present-revision")!
        )
        try await registry.closeAll()

        let secretStore = FixtureSecretStore(
            accountIDs: [missingAccountID, availableAccount.id],
            values: [
                .init(kind: .vaultKey, accountID: availableAccount.id, credentialID: nil): availableKey.data,
                .init(
                    kind: .oauthAccessToken,
                    accountID: availableAccount.id,
                    credentialID: availableAccount.credentialID
                ): Data("available-token".utf8)
            ]
        )
        let restored = try await AccountRestorationService(
            secretStore: secretStore,
            vaultRegistry: registry
        ).restore()

        XCTAssertEqual(restored.accounts, [availableAccount])
        XCTAssertEqual(restored.unavailableAccountIDs, [missingAccountID])
        try await registry.closeAll()
    }

    private let fixtureDate = Date(timeIntervalSinceReferenceDate: 1_000)

    private func makeAccount(id: String, credentialID: String) -> GitHubAccount {
        GitHubAccount(
            id: AccountID(rawValue: id)!,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_\(id)")!,
            login: id,
            authenticationKind: .oauth,
            credentialID: CredentialID(rawValue: credentialID)!,
            credentialStatus: .active,
            createdAt: fixtureDate,
            lastValidatedAt: fixtureDate
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makePreMigration033Fixture(
        root: URL,
        accountID: AccountID,
        key: VaultKey
    ) async throws -> VaultPaths {
        let registry = try VaultRegistry(rootDirectory: root)
        let vault = try await registry.open(accountID: accountID, vaultKey: key)
        try await vault.write { database in
            try database.execute(sql: "DROP INDEX IF EXISTS role_search_page_replays_snapshot")
            try database.execute(sql: "DROP TABLE role_search_page_replays")
            try database.execute(sql: """
                DELETE FROM schema_migrations
                WHERE id IN (
                    '033-role-search-page-replay-v2',
                    '034-role-search-page-replay-parser-identity'
                )
                """)
            try database.execute(sql: """
                CREATE TABLE role_search_page_replays (
                    account_id TEXT NOT NULL,
                    organization_id TEXT NOT NULL,
                    request_key TEXT NOT NULL,
                    query_value TEXT NOT NULL,
                    page INTEGER NOT NULL,
                    endpoint TEXT NOT NULL,
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    raw_snapshot_id TEXT NOT NULL,
                    etag TEXT NOT NULL,
                    parser_version INTEGER NOT NULL,
                    last_validated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, organization_id, request_key)
                )
                """)
            try database.execute(sql: """
                INSERT INTO role_search_page_replays VALUES
                ('legacy-account', 'legacy-organization', 'legacy-request', 'org:legacy is:open',
                 1, '/search/issues?legacy', 'credential-legacy', 'capability-legacy',
                 'legacy-raw', '"legacy"', 1, 1)
                """)
        }
        try await registry.closeAll()
        return VaultPaths(rootDirectory: root, accountID: accountID)
    }

    private func makePersistedSchema039Fixture(
        root: URL,
        accountID: AccountID,
        key: VaultKey
    ) async throws -> VaultPaths {
        let registry = try VaultRegistry(rootDirectory: root)
        let vault = try await registry.open(accountID: accountID, vaultKey: key)
        try await vault.write { database in
            for index in [
                "workspace_work_items_scope_activity",
                "workspace_attention_reasons_order",
                "workspace_attention_reasons_rule",
                "workspace_relations_subject_kind",
                "workspace_relation_evidence_order",
                "search_comments_parent_updated",
                "search_reviews_parent_updated",
                "search_project_items_content_updated",
                "search_action_items_work_updated",
                "derived_work_items_scope_id",
                "derived_team_memberships_account_state_expiry",
                "derived_timeline_events_subject_occurred_id",
                "derived_review_threads_pull_request_updated",
                "derived_project_items_content_node",
                "review_candidate_complete_traversal_pages_raw_snapshot",
                "review_candidate_complete_traversal_receipts_current_scope",
                "rule_evaluation_evidence_authority",
                "rule_evaluation_evidence_raw_snapshot",
                "rule_evaluations_current_scope",
                "ai_action_candidates_current_scope",
                "notification_threads_current_scope",
                "notification_threads_raw_snapshot",
                "notification_current_pages_scope",
                "notification_current_pages_raw_snapshot",
                "notification_replay_receipts_scope",
                "notification_failure_envelopes_scope",
                "notification_failure_pages_raw_snapshot",
                "review_candidate_failure_envelopes_scope_candidate_terminal",
                "review_candidate_failure_pages_raw_snapshot"
            ] {
                try database.execute(sql: "DROP INDEX IF EXISTS \(index)")
            }
            for trigger in [
                "review_candidate_complete_traversal_receipt_no_update",
                "review_candidate_complete_traversal_receipt_no_delete",
                "review_candidate_complete_traversal_segment_no_update",
                "review_candidate_complete_traversal_segment_no_delete",
                "review_candidate_complete_traversal_page_no_update",
                "review_candidate_complete_traversal_page_no_delete",
                "review_candidate_complete_traversal_protect_snapshot_delete",
                "review_candidate_complete_traversal_protect_snapshot_update",
                "derived_intelligence_protect_evidence_snapshot_delete",
                "derived_intelligence_protect_evidence_snapshot_update",
                "notification_protect_provenance_snapshot_delete",
                "notification_protect_provenance_snapshot_update"
            ] {
                try database.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
            }
            for table in [
                "review_candidate_complete_traversal_pages",
                "review_candidate_complete_traversal_segments",
                "review_candidate_complete_traversal_receipts",
                "ai_action_candidates",
                "rule_evaluation_evidence",
                "rule_evaluations",
                "derived_intelligence_runs",
                "notification_failure_pages",
                "notification_failure_envelopes",
                "notification_replay_receipts",
                "notification_current_pages",
                "notification_threads",
                "review_candidate_failure_pages",
                "review_candidate_failure_envelopes"
            ] {
                try database.execute(sql: "DROP TABLE IF EXISTS \(table)")
            }
            try database.execute(
                sql: """
                    DELETE FROM schema_migrations
                    WHERE id IN (
                        '040-review-candidate-failure-envelopes',
                        '041-notification-source-authority-v1',
                        '042-derived-intelligence-revision-evidence-v1',
                        '043-review-candidate-complete-traversal-receipts-v1',
                        '044-workspace-query-performance-indexes-v1',
                        '045-review-candidate-receipt-append-only-v1'
                    )
                    """
            )
        }
        try await registry.closeAll()
        return VaultPaths(rootDirectory: root, accountID: accountID)
    }

    private func migrationRows(in vault: AccountVault) async throws -> [MigrationRow] {
        try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT id, checksum FROM schema_migrations ORDER BY id"
            ).map { row in
                MigrationRow(id: row["id"], checksum: row["checksum"])
            }
        }
    }

    private func restoreDatabase(at database: URL, from backup: URL) throws {
        let artifacts = [
            database,
            URL(fileURLWithPath: database.path + "-wal"),
            URL(fileURLWithPath: database.path + "-shm")
        ]
        for artifact in artifacts where FileManager.default.fileExists(atPath: artifact.path) {
            try FileManager.default.removeItem(at: artifact)
        }
        try FileManager.default.copyItem(at: backup, to: database)
    }

    private func persistedSchemaState(
        at databaseURL: URL,
        key: VaultKey
    ) throws -> (migrations: [MigrationRow], hasFailureEnvelopes: Bool) {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { database in
            try database.usePassphrase(key.data)
        }
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        defer { try? pool.close() }
        return try pool.read { database in
            (
                try Row.fetchAll(
                    database,
                    sql: "SELECT id, checksum FROM schema_migrations ORDER BY id"
                ).map { row in
                    MigrationRow(id: row["id"], checksum: row["checksum"])
                },
                try database.tableExists("review_candidate_failure_envelopes")
            )
        }
    }
}

private struct MigrationRow: Equatable, Sendable {
    let id: String
    let checksum: String
}

private actor FixtureSecretStore: SecretStore {
    struct Key: Hashable, Sendable {
        let kind: TriageSecretKind
        let accountID: AccountID
        let credentialID: CredentialID?
    }

    private let knownAccountIDs: [AccountID]
    private var values: [Key: Data]

    init(accountIDs: [AccountID], values: [Key: Data]) {
        knownAccountIDs = accountIDs
        self.values = values
    }

    func read(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws -> Data? {
        values[Key(kind: kind, accountID: accountID, credentialID: credentialID)]
    }

    func write(
        _ value: Data,
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws {
        values[Key(kind: kind, accountID: accountID, credentialID: credentialID)] = value
    }

    func remove(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws {
        values[Key(kind: kind, accountID: accountID, credentialID: credentialID)] = nil
    }

    func accountIDs() async throws -> [AccountID] {
        knownAccountIDs
    }
}

private func assertThrowsAsync(
    _ operation: @escaping () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        verify(error)
    }
}
