import GRDB
import XCTest
@testable import Triage

final class AccountVaultTests: XCTestCase {
    func testVaultPersistsOnlyWithTheCorrectKey() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let key = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: accountID, vaultKey: key)

        try await vault.write { database in
            try database.execute(sql: "CREATE TABLE test_value (value TEXT NOT NULL)")
            try database.execute(sql: "INSERT INTO test_value (value) VALUES ('encrypted')")
        }
        try await registry.close(accountID: accountID)

        let reopenedRegistry = try VaultRegistry(rootDirectory: directory)
        let reopenedVault = try await reopenedRegistry.open(accountID: accountID, vaultKey: key)
        let value = try await reopenedVault.read { database in
            try String.fetchOne(database, sql: "SELECT value FROM test_value")
        }

        XCTAssertEqual(value, "encrypted")
        try await reopenedRegistry.closeAll()
    }

    func testVaultRejectsAnIncorrectKey() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let correctKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        _ = try await registry.open(accountID: accountID, vaultKey: correctKey)
        try await registry.close(accountID: accountID)

        let secondRegistry = try VaultRegistry(rootDirectory: directory)
        await XCTAssertThrowsErrorAsync {
            _ = try await secondRegistry.open(
                accountID: accountID,
                vaultKey: try VaultKey.generate()
            )
        }
    }

    func testMigrationsAreIdempotentAndRecordChecksums() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(
            accountID: AccountID.make(),
            vaultKey: try VaultKey.generate()
        )

        try await vault.applyMigrations()
        try await vault.applyMigrations()

        let migrations = try await vault.read { database -> [(id: String, checksum: String)] in
            try Row.fetchAll(
                database,
                sql: "SELECT id, checksum FROM schema_migrations ORDER BY id"
            ).map { row in
                let id: String = row["id"]
                let checksum: String = row["checksum"]
                return (id, checksum)
            }
        }
        XCTAssertEqual(migrations.count, TriageDatabaseMigrator.migrationCount)
        XCTAssertEqual(migrations[0].id, "001-vault-metadata")
        XCTAssertFalse(migrations[0].checksum.isEmpty)
        XCTAssertEqual(migrations.last?.id, "058-ai-action-confidence-threshold-v1")
        XCTAssertEqual(
            migrations.last?.checksum,
            "d6e912d44f3aa0234d807203d5fce4d7d0322c5753156bba467ea29744251d16"
        )
        let timelineMembershipSchema = try await vault.read { database in
            (
                try database.tableExists("timeline_current_pages"),
                try database.tableExists("timeline_staged_pages"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM timeline_current_pages"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM timeline_staged_pages")
            )
        }
        XCTAssertTrue(timelineMembershipSchema.0)
        XCTAssertTrue(timelineMembershipSchema.1)
        XCTAssertEqual(timelineMembershipSchema.2, 0)
        XCTAssertEqual(timelineMembershipSchema.3, 0)
        let reviewFailureSchema = try await vault.read { database in
            (
                try database.tableExists("review_candidate_failure_envelopes"),
                try database.tableExists("review_candidate_failure_pages"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_candidate_failure_envelopes"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_candidate_failure_pages")
            )
        }
        XCTAssertTrue(reviewFailureSchema.0)
        XCTAssertTrue(reviewFailureSchema.1)
        XCTAssertEqual(reviewFailureSchema.2, 0)
        XCTAssertEqual(reviewFailureSchema.3, 0)
        let notificationSchema = try await vault.read { database in
            (
                try database.tableExists("notification_threads"),
                try database.tableExists("notification_current_pages"),
                try database.tableExists("notification_replay_receipts"),
                try database.tableExists("notification_failure_envelopes"),
                try database.tableExists("notification_failure_pages")
            )
        }
        XCTAssertTrue(notificationSchema.0)
        XCTAssertTrue(notificationSchema.1)
        XCTAssertTrue(notificationSchema.2)
        XCTAssertTrue(notificationSchema.3)
        XCTAssertTrue(notificationSchema.4)
        let derivedIntelligenceSchema = try await vault.read { database in
            (
                try database.tableExists("derived_intelligence_runs"),
                try database.tableExists("rule_evaluations"),
                try database.tableExists("rule_evaluation_evidence"),
                try database.tableExists("ai_action_candidates")
            )
        }
        XCTAssertTrue(derivedIntelligenceSchema.0)
        XCTAssertTrue(derivedIntelligenceSchema.1)
        XCTAssertTrue(derivedIntelligenceSchema.2)
        XCTAssertTrue(derivedIntelligenceSchema.3)
        let workflowHistoryColumns = try await vault.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(workflow_history)").map { row in
                let name: String = row["name"]
                return name
            }
        }
        XCTAssertTrue(workflowHistoryColumns.contains("transaction_id"))
        XCTAssertTrue(workflowHistoryColumns.contains("account_id"))
        XCTAssertTrue(workflowHistoryColumns.contains("organization_id"))
        XCTAssertTrue(workflowHistoryColumns.contains("is_undone"))
        try await registry.closeAll()
    }

    func testMigration038RetainsLegacyRelationEvidenceAsProvisionalUnverified() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "github")!
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: accountID, vaultKey: try VaultKey.generate())
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: date,
            lastValidatedAt: date
        )
        let organization = GitHubOrganization(
            id: organizationID,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "MDEyOk9yZ2FuaXphdGlvbjE=")!,
            login: "github"
        )
        try await AccountRepository(vault: vault).save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!
        )
        try await AccountRepository(vault: vault).save(
            organization,
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                capabilities: [],
                checkedAt: date
            ),
            selectedAt: date
        )
        let node = NormalizedGitHubNode(
            nodeID: GitHubNodeID(rawValue: "MDU6SXNzdWUx")!,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: nil,
            kind: .issue,
            numericID: "1",
            number: 1,
            title: "Legacy relation",
            state: .open,
            url: URL(string: "https://github.com/github/triage/issues/1")!,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: date,
            updatedAt: date,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "legacy-revision",
            observedAt: date,
            accessibility: .accessible
        )
        try await GitHubNodeRepository(vault: vault).save(node)
        try await vault.write { database in
            try Self.removeMigration038Schema(from: database)
            try database.execute(
                sql: """
                    INSERT INTO relations (
                        id, account_id, subject_node_id, object_node_id, kind, confidence, observed_at_ms
                    ) VALUES ('legacy-relation', ?, ?, NULL, 'assigned', 'confirmed', ?)
                    """,
                arguments: [accountID.rawValue, node.nodeID.rawValue, 100_000]
            )
            try database.execute(
                sql: """
                    INSERT INTO relation_evidence (
                        relation_id, evidence_id, source, source_node_id, source_event_id,
                        source_revision, observed_at_ms, excerpt
                    ) VALUES ('legacy-relation', 'legacy-evidence', 'restTimeline', ?, 'event-1', 'legacy-revision', ?, 'legacy')
                    """,
                arguments: [node.nodeID.rawValue, 100_000]
            )
            try database.execute(
                sql: """
                    INSERT INTO relation_evidence (
                        relation_id, evidence_id, source, source_node_id, source_event_id,
                        source_revision, observed_at_ms, excerpt
                    ) VALUES ('legacy-relation', 'legacy-local-workflow', 'localWorkflow', ?, NULL, 'legacy-workflow', ?, 'legacy local')
                    """,
                arguments: [node.nodeID.rawValue, 100_001]
            )
        }
        try await vault.applyMigrations()
        let migrated = try await vault.read { database -> (String, String, String, String, String?, String?, String?) in
            let row = try XCTUnwrap(Row.fetchOne(
                database,
                sql: """
                    SELECT authority_kind, source_locator_kind, confirmation, confidence,
                           authority_feature, authority_credential_revision, raw_snapshot_id
                    FROM relation_evidence WHERE evidence_id = 'legacy-evidence'
                    """
            ))
            return (
                row["authority_kind"], row["source_locator_kind"], row["confirmation"], row["confidence"],
                row["authority_feature"], row["authority_credential_revision"], row["raw_snapshot_id"]
            )
        }
        XCTAssertEqual(migrated.0, "legacyUnverified")
        XCTAssertEqual(migrated.1, "legacyUnverified")
        XCTAssertEqual(migrated.2, "provisional")
        XCTAssertEqual(migrated.3, "provisional")
        XCTAssertNil(migrated.4)
        XCTAssertNil(migrated.5)
        XCTAssertNil(migrated.6)
        let migratedLocalSource = try await vault.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT source FROM relation_evidence WHERE evidence_id = 'legacy-local-workflow'"
            )
        }
        XCTAssertEqual(migratedLocalSource, "legacyUnverified")
        try await registry.closeAll()
    }

    func testConditionalRequestMigrationInvalidatesLegacyUnscopedValidators() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = try VaultRegistry(rootDirectory: directory.appendingPathComponent("source"))
        let vault = try await registry.open(
            accountID: AccountID.make(),
            vaultKey: try VaultKey.generate()
        )
        let priorMigrations = try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, checksum, applied_at_ms
                    FROM schema_migrations
                    WHERE id NOT IN (
                        '030-revision-scoped-conditional-requests',
                        '031-raw-request-authority',
                        '032-timeline-replay-receipts',
                        '033-role-search-page-replay-v2',
                        '034-role-search-page-replay-parser-identity',
                        '035-source-access-observations',
                        '036-repository-inventory-replay-receipts',
                        '037-repository-inventory-replay-snapshot-idempotency',
                        '038-relation-evidence-authority-provisional'
                    )
                    ORDER BY id
                    """
            ).map { row in
                (
                    row["id"] as String,
                    row["checksum"] as String,
                    row["applied_at_ms"] as Int64
                )
            }
        }
        try await registry.closeAll()

        let legacyPool = try DatabasePool(
            path: directory.appendingPathComponent("legacy.sqlite").path
        )
        try await legacyPool.write { database in
            try database.execute(sql: """
                CREATE TABLE schema_migrations (
                    id TEXT PRIMARY KEY NOT NULL,
                    checksum TEXT NOT NULL,
                    applied_at_ms INTEGER NOT NULL
                )
                """)
            for migration in priorMigrations {
                try database.execute(
                    sql: "INSERT INTO schema_migrations VALUES (?, ?, ?)",
                    arguments: [migration.0, migration.1, migration.2]
                )
            }
            try database.execute(sql: "CREATE TABLE accounts (id TEXT PRIMARY KEY NOT NULL)")
            try database.execute(sql: "CREATE TABLE organizations (id TEXT PRIMARY KEY NOT NULL)")
            try database.execute(sql: """
                CREATE TABLE account_organizations (
                    account_id TEXT NOT NULL,
                    organization_id TEXT NOT NULL,
                    PRIMARY KEY (account_id, organization_id)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE sync_streams (
                    id TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL,
                    organization_id TEXT NOT NULL,
                    feature TEXT NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE raw_api_snapshots (
                    id TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL,
                    github_node_id TEXT,
                    endpoint TEXT NOT NULL,
                    etag TEXT,
                    parser_version INTEGER NOT NULL,
                    observed_at_ms INTEGER NOT NULL,
                    payload BLOB NOT NULL
                )
                """)
            try database.execute(
                sql: "INSERT INTO raw_api_snapshots VALUES (?, ?, NULL, ?, ?, ?, ?, ?)",
                arguments: [
                    "legacy-raw", "account", "/legacy", "\"legacy\"", 1, 1, Data("{}".utf8)
                ]
            )
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
            try database.execute(
                sql: "INSERT INTO role_search_page_replays VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    "account", "organization", "legacy-search", "org:legacy", 1,
                    "/legacy", "credential", "capability", "legacy-raw",
                    "\"legacy\"", 1, 1
                ]
            )
            try database.execute(sql: """
                CREATE TABLE conditional_request_cache (
                    request_key TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL,
                    etag TEXT,
                    last_modified TEXT,
                    observed_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(
                sql: "INSERT INTO conditional_request_cache VALUES (?, ?, ?, NULL, ?)",
                arguments: ["GET /legacy", "account", "\"legacy\"", 1]
            )
        }

        try TriageDatabaseMigrator.migrate(
            legacyPool,
            beforeDestructiveMigration: { _ in }
        )

        let migrated = try await legacyPool.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM conditional_request_cache"),
                try Row.fetchAll(
                    database,
                    sql: "PRAGMA table_info(conditional_request_cache)"
                ).map { $0["name"] as String },
                try Row.fetchAll(
                    database,
                    sql: "PRAGMA table_info(raw_api_snapshots)"
                ).map { $0["name"] as String },
                try Row.fetchOne(
                    database,
                    sql: """
                        SELECT last_modified, authority_request_key
                        FROM raw_api_snapshots WHERE id = 'legacy-raw'
                        """
                ).map { row in
                    (row["last_modified"] as String?) == nil
                        && (row["authority_request_key"] as String?) == nil
                } ?? false,
                try String.fetchOne(
                    database,
                    sql: """
                        SELECT checksum FROM schema_migrations
                        WHERE id = '030-revision-scoped-conditional-requests'
                        """
                ),
                try String.fetchOne(
                    database,
                    sql: """
                        SELECT checksum FROM schema_migrations
                        WHERE id = '031-raw-request-authority'
                        """
                ),
                try String.fetchOne(
                    database,
                    sql: """
                        SELECT checksum FROM schema_migrations
                        WHERE id = '032-timeline-replay-receipts'
                        """
                ),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM role_search_page_replays"),
                try Row.fetchAll(
                    database,
                    sql: "PRAGMA table_info(role_search_page_replays)"
                ).map { $0["name"] as String },
                try String.fetchOne(
                    database,
                    sql: """
                        SELECT checksum FROM schema_migrations
                        WHERE id = '033-role-search-page-replay-v2'
                        """
                ),
                try String.fetchOne(
                    database,
                    sql: """
                        SELECT checksum FROM schema_migrations
                        WHERE id = '034-role-search-page-replay-parser-identity'
                        """
                ),
                try String.fetchOne(
                    database,
                    sql: """
                        SELECT checksum FROM schema_migrations
                        WHERE id = '035-source-access-observations'
                        """
                ),
                try String.fetchOne(
                    database,
                    sql: """
                        SELECT checksum FROM schema_migrations
                        WHERE id = '036-repository-inventory-replay-receipts'
                        """
                )
            )
        }
        XCTAssertEqual(migrated.0, 0)
        XCTAssertTrue(migrated.1.contains("organization_id"))
        XCTAssertTrue(migrated.1.contains("credential_revision"))
        XCTAssertTrue(migrated.1.contains("capability_revision"))
        XCTAssertTrue(migrated.2.contains("last_modified"))
        XCTAssertTrue(migrated.2.contains("authority_request_key"))
        XCTAssertTrue(migrated.3)
        XCTAssertEqual(
            migrated.4,
            "f742e3ff68ae96471ddeacf0f191fa032cd4c343f353b17f313f005810fe7f02"
        )
        XCTAssertEqual(
            migrated.5,
            "5d7c3aa43bbc9a8a962b2bf34625b8e86fc59da3157656e5d1897182b72f5db3"
        )
        XCTAssertEqual(
            migrated.6,
            "7df5b7b72474a35f4ec6fe1e3c850661553c3ecd8ab05a502347d2013b89db88"
        )
        XCTAssertEqual(migrated.7, 0)
        XCTAssertTrue(migrated.8.contains("stream_id"))
        XCTAssertTrue(migrated.8.contains("last_modified"))
        XCTAssertEqual(
            migrated.9,
            "3567bf0a5bf1e6fd2edb7b0ed017db386b9ed39b29a2533540b81de5197a2f12"
        )
        XCTAssertEqual(
            migrated.10,
            "2cd58affc40f404812fdc6a4a32ee8ec50116fd0e813a8af3eddfee9b99a6170"
        )
        XCTAssertEqual(
            migrated.11,
            "0e3720d9d2f00f2d1cc517da11b4402d9c447bc641b7e3b9fc907fce73c09b6e"
        )
        XCTAssertEqual(
            migrated.12,
            "a5aaff89b48f88fba57988ab8f6fde3d7bdfde58d1e9ada4d51c2c1179c19a52"
        )
    }

    func testMigration033CreatesVerifiedEncryptedBackupBeforeDroppingLegacyReplayMetadata() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let key = try VaultKey.generate()
        let paths = try await makePre033LegacyRoleReplayVault(
            directory: directory,
            accountID: accountID,
            key: key
        )
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: accountID, vaultKey: key)
        let liveReplayCount = try await vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM role_search_page_replays")
        }
        XCTAssertEqual(liveReplayCount, 0)
        try await registry.closeAll()

        let backup = paths.migrationBackups
            .appendingPathComponent("033-role-search-page-replay-v2.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let backupBytes = try Data(contentsOf: backup)
        XCTAssertFalse(backupBytes.starts(with: Data("SQLite format 3\0".utf8)))

        do {
            _ = try await readRoleReplayCount(at: backup, configuration: .init())
            XCTFail("A SQLCipher backup must not be readable without its vault key.")
        } catch {
            // Expected.
        }
        do {
            _ = try await readRoleReplayCount(
                at: backup,
                configuration: encryptedConfiguration(vaultKey: try VaultKey.generate())
            )
            XCTFail("A SQLCipher backup must reject an unrelated vault key.")
        } catch {
            // Expected.
        }

        let verifiedBackup = try DatabasePool(
            path: backup.path,
            configuration: encryptedConfiguration(vaultKey: key)
        )
        defer { try? verifiedBackup.close() }
        let backupState = try await verifiedBackup.read { database in
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
        XCTAssertEqual(backupState.0, "org:legacy is:open")
        XCTAssertNil(backupState.1)
    }

    func testFailedMigration033LeavesPreMigrationEncryptedDatabaseReadable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let key = try VaultKey.generate()
        let paths = try await makePre033LegacyRoleReplayVault(
            directory: directory,
            accountID: accountID,
            key: key
        )
        let vault = try AccountVault(
            accountID: accountID,
            vaultKey: key,
            rootDirectory: directory
        )
        try await vault.write { database in
            try database.execute(sql: "CREATE TABLE migration_033_conflict (value TEXT NOT NULL)")
            try database.execute(sql: """
                CREATE INDEX role_search_page_replays_snapshot
                ON migration_033_conflict (value)
                """)
        }
        await XCTAssertThrowsErrorAsync {
            try await vault.applyMigrations()
        }
        let preservedState = try await vault.read { database in
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
        XCTAssertEqual(preservedState.0, "org:legacy is:open")
        XCTAssertNil(preservedState.1)
        let backup = paths.migrationBackups
            .appendingPathComponent("033-role-search-page-replay-v2.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        try await vault.close()

        let reopened = try AccountVault(
            accountID: accountID,
            vaultKey: key,
            rootDirectory: directory
        )
        let replayCount = try await reopened.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM role_search_page_replays")
        }
        XCTAssertEqual(replayCount, 1)
        try await reopened.close()
    }

    func testVerifiedMigrationBackupRestorePreservesOriginalEncryptedVaultBeforeRecovery() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let key = try VaultKey.generate()
        let paths = try await makePre033LegacyRoleReplayVault(
            directory: directory,
            accountID: accountID,
            key: key
        )
        let interrupted = try AccountVault(
            accountID: accountID,
            vaultKey: key,
            rootDirectory: directory
        )
        try await interrupted.write { database in
            try database.execute(sql: "CREATE TABLE migration_033_conflict (value TEXT NOT NULL)")
            try database.execute(sql: """
                CREATE INDEX role_search_page_replays_snapshot
                ON migration_033_conflict (value)
                """)
        }
        await XCTAssertThrowsErrorAsync {
            try await interrupted.applyMigrations()
        }
        try await interrupted.close()

        let originalBytes = try Data(contentsOf: paths.database)
        let originalWALBytes = Data("test-only-live-wal".utf8)
        let originalSHMBytes = Data("test-only-live-shm".utf8)
        let liveWAL = URL(fileURLWithPath: paths.database.path + "-wal")
        let liveSHM = URL(fileURLWithPath: paths.database.path + "-shm")
        try originalWALBytes.write(to: liveWAL)
        try originalSHMBytes.write(to: liveSHM)
        let registry = try VaultRegistry(rootDirectory: directory)
        let candidates = try await registry.verifiedMigrationBackupIDs(
            accountID: accountID,
            vaultKey: key
        )
        XCTAssertEqual(candidates, ["033-role-search-page-replay-v2"])

        try await registry.restoreVerifiedMigrationBackup(
            accountID: accountID,
            vaultKey: key,
            migrationID: "033-role-search-page-replay-v2"
        )

        let recoveryCopies = try FileManager.default.contentsOfDirectory(
            at: paths.recoveryCopies,
            includingPropertiesForKeys: nil
        )
        let recoveryCopyDirectory = try XCTUnwrap(recoveryCopies.first)
        let preservedCopy = recoveryCopyDirectory.appendingPathComponent("triage.sqlite")
        XCTAssertEqual(try Data(contentsOf: preservedCopy), originalBytes)
        XCTAssertEqual(
            try Data(contentsOf: recoveryCopyDirectory.appendingPathComponent("triage.sqlite-wal")),
            originalWALBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: recoveryCopyDirectory.appendingPathComponent("triage.sqlite-shm")),
            originalSHMBytes
        )

        let restored = try await registry.open(accountID: accountID, vaultKey: key)
        let replayCount = try await restored.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM role_search_page_replays")
        }
        XCTAssertEqual(replayCount, 0)

        // A subsequent recovery with no live sidecars must still preserve the
        // database and must not manufacture WAL/SHM artifacts in the archive.
        try await registry.closeAll()
        let sidecarlessOriginalBytes = try Data(contentsOf: paths.database)
        for sidecar in [liveWAL, liveSHM] where FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.removeItem(at: sidecar)
        }
        try await registry.restoreVerifiedMigrationBackup(
            accountID: accountID,
            vaultKey: key,
            migrationID: "033-role-search-page-replay-v2"
        )
        let sidecarlessRecovery = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: paths.recoveryCopies,
                includingPropertiesForKeys: nil
            ).first(where: {
                (try? Data(contentsOf: $0.appendingPathComponent("triage.sqlite"))) == sidecarlessOriginalBytes
            })
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sidecarlessRecovery.appendingPathComponent("triage.sqlite-wal").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sidecarlessRecovery.appendingPathComponent("triage.sqlite-shm").path
        ))
    }

    func testMigration034PreservesMigration033RowsAndDistinguishesParserVersions() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = try VaultKey.generate()
        let fixture = try await makeMigration033ReplayVault(directory: directory, key: key)
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: fixture.accountID, vaultKey: key)
        let migratedCount = try await vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM role_search_page_replays")
        }
        XCTAssertEqual(migratedCount, 1)
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO role_search_page_replays VALUES
                    (?, ?, 'roleDiscovery', ?, 'parser-v2', 'org:legacy is:open', 1,
                     '/search/issues?legacy', ?, ?, ?, '\"legacy-v2\"', NULL, 2, 2)
                    """,
                arguments: [
                    fixture.accountID.rawValue,
                    fixture.organizationID.rawValue,
                    fixture.streamID.rawValue,
                    fixture.credentialRevision.rawValue,
                    fixture.capabilityRevision.rawValue,
                    fixture.rawSnapshotID.rawValue
                ]
            )
        }
        let parserVersions = try await vault.read { database in
            try Int.fetchAll(
                database,
                sql: "SELECT parser_version FROM role_search_page_replays ORDER BY parser_version"
            )
        }
        XCTAssertEqual(parserVersions, [1, 2])
        try await registry.closeAll()
    }

    func testMigration035BuildsStreamIndependentAccessEvidenceSchemaFrom034() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let key = try VaultKey.generate()
        let fixtureRegistry = try VaultRegistry(rootDirectory: directory)
        let fixtureVault = try await fixtureRegistry.open(accountID: accountID, vaultKey: key)
        try await fixtureVault.write { database in
            try Self.removeMigration036Through038Schema(from: database)
            try database.execute(sql: "DROP TRIGGER source_access_protect_deletion_receipt")
            try database.execute(
                sql: "DROP TRIGGER source_access_protect_deletion_receipt_update"
            )
            try database.execute(sql: "DROP TABLE source_access_projections")
            try database.execute(sql: "DROP TABLE source_access_observations")
            try database.execute(
                sql: "DELETE FROM schema_migrations WHERE id = '035-source-access-observations'"
            )
        }
        try await fixtureRegistry.closeAll()

        let migratedRegistry = try VaultRegistry(rootDirectory: directory)
        let migratedVault = try await migratedRegistry.open(accountID: accountID, vaultKey: key)
        let schema = try await migratedVault.read { database in
            let observationForeignKeys = try Row.fetchAll(
                database,
                sql: "SELECT * FROM pragma_foreign_key_list('source_access_observations')"
            ).map { row in
                "\(row["from"] as String):\(row["table"] as String):\(row["on_delete"] as String)"
            }
            let projectionForeignKeys = try Row.fetchAll(
                database,
                sql: "SELECT * FROM pragma_foreign_key_list('source_access_projections')"
            ).map { row in
                "\(row["from"] as String):\(row["table"] as String):\(row["on_delete"] as String)"
            }
            let projectionPrimaryKey = try Row.fetchAll(
                database,
                sql: "PRAGMA table_info(source_access_projections)"
            ).compactMap { row -> (Int, String)? in
                let position: Int = row["pk"]
                guard position > 0 else { return nil }
                return (position, row["name"] as String)
            }.sorted { $0.0 < $1.0 }.map(\.1)
            return (
                try String.fetchOne(
                    database,
                    sql: """
                        SELECT checksum FROM schema_migrations
                        WHERE id = '035-source-access-observations'
                        """
                ),
                observationForeignKeys,
                projectionForeignKeys,
                projectionPrimaryKey,
                try String.fetchAll(
                    database,
                    sql: """
                        SELECT name FROM sqlite_master
                        WHERE type = 'trigger'
                          AND name IN (
                              'source_access_protect_deletion_receipt',
                              'source_access_protect_deletion_receipt_update'
                          )
                        ORDER BY name
                        """
                )
            )
        }

        XCTAssertEqual(
            schema.0,
            "0e3720d9d2f00f2d1cc517da11b4402d9c447bc641b7e3b9fc907fce73c09b6e"
        )
        XCTAssertTrue(
            schema.1.contains("raw_snapshot_id:raw_api_snapshots:SET NULL"),
            "Observation foreign keys: \(schema.1)"
        )
        XCTAssertFalse(schema.1.contains { $0.hasPrefix("source_event_id:") })
        XCTAssertFalse(schema.1.contains { $0.contains(":sync_streams:") })
        XCTAssertTrue(
            schema.2.contains("winning_observation_id:source_access_observations:CASCADE"),
            "Projection foreign keys: \(schema.2)"
        )
        XCTAssertFalse(schema.2.contains { $0.contains(":sync_streams:") })
        XCTAssertEqual(
            schema.3,
            [
                "account_id", "organization_id", "feature", "stream_id",
                "target_kind", "target_id"
            ]
        )
        XCTAssertEqual(
            schema.4,
            [
                "source_access_protect_deletion_receipt",
                "source_access_protect_deletion_receipt_update"
            ]
        )
        try await migratedRegistry.closeAll()
    }

    func testMigration036And037BuildDurableIdempotentRepositoryInventoryReplaySchema() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "migration-036-org")!
        let streamID = SyncStreamID(rawValue: "inventory-repositories-migration-036-org")!
        let credentialRevision = CredentialRevision(rawValue: "credential-036")!
        let capabilityRevision = CapabilityRevision(rawValue: "capability-036")!
        let rawSnapshotID = RawAPISnapshotID(rawValue: "raw-migration-036")!
        let observedAt = Date(timeIntervalSinceReferenceDate: 3_600)
        let key = try VaultKey.generate()
        let fixtureRegistry = try VaultRegistry(rootDirectory: directory)
        let fixtureVault = try await fixtureRegistry.open(accountID: accountID, vaultKey: key)
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 36,
            nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjM2")!,
            login: "migration-user",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: observedAt,
            lastValidatedAt: observedAt
        )
        let organization = GitHubOrganization(
            id: organizationID,
            githubOrganizationID: 3_600,
            nodeID: GitHubNodeID(rawValue: "MDEyOk9yZ2FuaXphdGlvbjM2")!,
            login: "migration-org"
        )
        try await AccountRepository(vault: fixtureVault).save(
            account,
            credentialRevision: credentialRevision
        )
        try await AccountRepository(vault: fixtureVault).save(
            organization,
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: capabilityRevision,
                capabilities: [],
                checkedAt: observedAt
            ),
            selectedAt: observedAt
        )
        try await CoverageRepository(vault: fixtureVault).save(
            CoverageRecord(
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                feature: .repositories,
                streamID: streamID,
                intervalStart: nil,
                intervalEnd: nil,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision,
                status: .complete,
                lastSuccessfulAt: observedAt,
                failureDetail: nil
            ),
            attemptedAt: observedAt
        )
        let requestKey = "GET /orgs/migration-org/repos?type=all&per_page=100"
        try await RawAPISnapshotRepository(vault: fixtureVault).save(
            RawAPISnapshot(
                id: rawSnapshotID,
                accountID: accountID,
                githubNodeID: nil,
                endpoint: "/orgs/migration-org/repos?type=all&per_page=100",
                eTag: "\"migration-036\"",
                parserVersion: 1,
                observedAt: observedAt,
                payload: Data("[]".utf8),
                requestIdentity: ConditionalRequestIdentity(
                    scope: SynchronizationScope(
                        accountID: accountID,
                        organizationID: organizationID,
                        credentialRevision: credentialRevision,
                        capabilityRevision: capabilityRevision
                    ),
                    feature: .repositories,
                    streamID: streamID,
                    requestKey: requestKey
                )
            )
        )
        try await fixtureVault.write { database in
            try Self.removeMigration036Through038Schema(from: database)
        }
        try await fixtureRegistry.closeAll()

        let migratedRegistry = try VaultRegistry(rootDirectory: directory)
        let migratedVault = try await migratedRegistry.open(accountID: accountID, vaultKey: key)
        let schema = try await migratedVault.read { database in
            Migration036SchemaInspection(
                checksum: try String.fetchOne(
                    database,
                    sql: """
                        SELECT checksum FROM schema_migrations
                        WHERE id = '036-repository-inventory-replay-receipts'
                        """
                ),
                replaySnapshotUpdateChecksum: try String.fetchOne(
                    database,
                    sql: """
                        SELECT checksum FROM schema_migrations
                        WHERE id = '037-repository-inventory-replay-snapshot-idempotency'
                        """
                ),
                parentColumns: try Row.fetchAll(
                    database,
                    sql: "PRAGMA table_info(repository_inventory_replay_receipts)"
                ).map { $0["name"] as String },
                pageColumns: try Row.fetchAll(
                    database,
                    sql: "PRAGMA table_info(repository_inventory_replay_receipt_pages)"
                ).map { $0["name"] as String },
                parentForeignKeys: try Self.foreignKeyDescriptions(
                    table: "repository_inventory_replay_receipts",
                    in: database
                ),
                pageForeignKeys: try Self.foreignKeyDescriptions(
                    table: "repository_inventory_replay_receipt_pages",
                    in: database
                ),
                indexes: try String.fetchAll(
                    database,
                    sql: """
                        SELECT name FROM sqlite_master
                        WHERE type = 'index'
                          AND name IN (
                              'sync_streams_exact_scope',
                              'repository_inventory_replay_receipts_current_scope',
                              'repository_inventory_replay_receipt_pages_snapshot'
                          )
                        ORDER BY name
                        """
                ),
                triggers: try String.fetchAll(
                    database,
                    sql: """
                        SELECT name FROM sqlite_master
                        WHERE type = 'trigger'
                          AND name IN (
                              'repository_inventory_protect_replay_snapshot_delete',
                              'repository_inventory_protect_replay_snapshot_update'
                          )
                        ORDER BY name
                        """
                ),
                parentSQL: try String.fetchOne(
                    database,
                    sql: """
                        SELECT sql FROM sqlite_master
                        WHERE type = 'table'
                          AND name = 'repository_inventory_replay_receipts'
                        """
                ) ?? "",
                pageSQL: try String.fetchOne(
                    database,
                    sql: """
                        SELECT sql FROM sqlite_master
                        WHERE type = 'table'
                          AND name = 'repository_inventory_replay_receipt_pages'
                        """
                ) ?? "",
                replaySnapshotUpdateTriggerSQL: try String.fetchOne(
                    database,
                    sql: """
                        SELECT sql FROM sqlite_master
                        WHERE type = 'trigger'
                          AND name = 'repository_inventory_protect_replay_snapshot_update'
                        """
                ) ?? ""
            )
        }

        XCTAssertEqual(
            schema.checksum,
            "a5aaff89b48f88fba57988ab8f6fde3d7bdfde58d1e9ada4d51c2c1179c19a52"
        )
        XCTAssertEqual(
            schema.replaySnapshotUpdateChecksum,
            "49c98f3a558dda06ff7205416691c1cb02cc002c0752f8c4ed36a2d58a5db4fb"
        )
        XCTAssertEqual(
            schema.parentColumns,
            [
                "id", "account_id", "organization_id", "feature", "stream_id",
                "request_key", "credential_revision", "capability_revision",
                "raw_source_revision", "etag", "last_modified", "raw_observed_at_ms",
                "normalized_committed_at_ms", "last_validated_at_ms", "parser_version",
                "page_count", "normalized_repository_count", "normalized_digest"
            ]
        )
        XCTAssertEqual(
            schema.pageColumns,
            [
                "receipt_id", "page_index", "endpoint", "request_key", "link_header",
                "next_endpoint", "raw_snapshot_id", "object_count", "raw_payload_digest",
                "repository_id_digest"
            ]
        )
        for expected in [
            "account_id:account_organizations.account_id:CASCADE",
            "organization_id:account_organizations.organization_id:CASCADE",
            "account_id:sync_streams.account_id:CASCADE",
            "organization_id:sync_streams.organization_id:CASCADE",
            "feature:sync_streams.feature:CASCADE",
            "stream_id:sync_streams.id:CASCADE"
        ] {
            XCTAssertTrue(
                schema.parentForeignKeys.contains(expected),
                "Parent foreign keys: \(schema.parentForeignKeys)"
            )
        }
        XCTAssertEqual(
            Set(schema.pageForeignKeys),
            Set([
                "receipt_id:repository_inventory_replay_receipts.id:CASCADE",
                "raw_snapshot_id:raw_api_snapshots.id:CASCADE"
            ])
        )
        XCTAssertEqual(
            schema.indexes,
            [
                "repository_inventory_replay_receipt_pages_snapshot",
                "repository_inventory_replay_receipts_current_scope",
                "sync_streams_exact_scope"
            ]
        )
        XCTAssertEqual(
            schema.triggers,
            [
                "repository_inventory_protect_replay_snapshot_delete",
                "repository_inventory_protect_replay_snapshot_update"
            ]
        )
        XCTAssertTrue(schema.parentSQL.contains("feature TEXT NOT NULL CHECK (feature = 'repositories')"))
        XCTAssertTrue(schema.parentSQL.contains("page_count BETWEEN 1 AND 100"))
        XCTAssertTrue(schema.parentSQL.contains("normalized_repository_count BETWEEN 0 AND 10000"))
        XCTAssertTrue(schema.parentSQL.contains("length(normalized_digest) = 32"))
        XCTAssertTrue(schema.parentSQL.contains("last_validated_at_ms >= normalized_committed_at_ms"))
        XCTAssertTrue(schema.pageSQL.contains("request_key = 'GET ' || endpoint"))
        XCTAssertTrue(schema.pageSQL.contains("length(link_header) BETWEEN 1 AND 8192"))
        XCTAssertTrue(schema.pageSQL.contains("next_endpoint IS NULL OR link_header IS NOT NULL"))
        for column in [
            "id", "account_id", "github_node_id", "endpoint", "etag", "last_modified",
            "authority_organization_id", "authority_feature", "authority_stream_id",
            "authority_request_key", "authority_credential_revision",
            "authority_capability_revision", "parser_version", "observed_at_ms", "payload"
        ] {
            XCTAssertTrue(
                schema.replaySnapshotUpdateTriggerSQL.contains("OLD.\(column) IS NOT NEW.\(column)"),
                "037 update trigger must compare \(column) with NULL-safe identity semantics."
            )
        }

        try await migratedVault.write { database in
            try Self.insertMigration036Receipt(
                accountID: accountID,
                organizationID: organizationID,
                streamID: streamID,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision,
                rawSnapshotID: rawSnapshotID,
                requestKey: requestKey,
                in: database
            )
            try database.execute(
                sql: "UPDATE raw_api_snapshots SET endpoint = endpoint WHERE id = ?",
                arguments: [rawSnapshotID.rawValue]
            )
            try database.execute(sql: """
                INSERT INTO raw_api_snapshots (
                    id, account_id, github_node_id, endpoint, etag, parser_version,
                    observed_at_ms, payload, last_modified, authority_organization_id,
                    authority_feature, authority_stream_id, authority_request_key,
                    authority_credential_revision, authority_capability_revision
                )
                SELECT id, account_id, github_node_id, endpoint, etag, parser_version,
                       observed_at_ms, payload, last_modified, authority_organization_id,
                       authority_feature, authority_stream_id, authority_request_key,
                       authority_credential_revision, authority_capability_revision
                FROM raw_api_snapshots
                WHERE id = ?
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                """, arguments: [rawSnapshotID.rawValue])
        }
        do {
            try await migratedVault.write { database in
                try database.execute(
                    sql: "DELETE FROM raw_api_snapshots WHERE id = ?",
                    arguments: [rawSnapshotID.rawValue]
                )
            }
            XCTFail("A raw snapshot bound to a replay receipt must be durable.")
        } catch {
            // Expected: migration 036 protects the raw receipt while its account exists.
        }
        do {
            try await migratedVault.write { database in
                try database.execute(
                    sql: "UPDATE raw_api_snapshots SET endpoint = '/changed' WHERE id = ?",
                    arguments: [rawSnapshotID.rawValue]
                )
            }
            XCTFail("A raw snapshot bound to a replay receipt must be immutable.")
        } catch {
            // Expected: migration 037 rejects material receipt-evidence mutation.
        }
        do {
            try await migratedVault.write { database in
                try database.execute(
                    sql: "UPDATE raw_api_snapshots SET last_modified = ? WHERE id = ?",
                    arguments: ["Wed, 21 Oct 2015 07:28:00 GMT", rawSnapshotID.rawValue]
                )
            }
            XCTFail("A NULL-to-value replay snapshot update must be rejected.")
        } catch {
            // Expected: migration 037 uses NULL-safe material comparisons.
        }
        do {
            try await migratedVault.write { database in
                try database.execute(
                    sql: "UPDATE raw_api_snapshots SET payload = ? WHERE id = ?",
                    arguments: [Data("[1]".utf8), rawSnapshotID.rawValue]
                )
            }
            XCTFail("A payload mutation of a receipt-bound raw snapshot must be rejected.")
        } catch {
            // Expected: migration 037 protects raw receipt bytes.
        }
        let protectedEndpoint = try await migratedVault.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT endpoint FROM raw_api_snapshots WHERE id = ?",
                arguments: [rawSnapshotID.rawValue]
            )
        }
        XCTAssertEqual(protectedEndpoint, "/orgs/migration-org/repos?type=all&per_page=100")

        try await migratedVault.write { database in
            try database.execute(
                sql: """
                    DELETE FROM account_organizations
                    WHERE account_id = ? AND organization_id = ?
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
        }
        var counts = try await Self.migration036Counts(
            vault: migratedVault,
            rawSnapshotID: rawSnapshotID
        )
        XCTAssertEqual(counts, Migration036Counts(receipts: 0, pages: 0, rawSnapshots: 1))

        try await migratedVault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO account_organizations (
                        account_id, organization_id, access_state, capability_revision,
                        selected_at_ms, checked_at_ms
                    ) VALUES (?, ?, 'available', ?, ?, ?)
                    """,
                arguments: [
                    accountID.rawValue,
                    organizationID.rawValue,
                    capabilityRevision.rawValue,
                    Int64(3_600_000),
                    Int64(3_600_000)
                ]
            )
            try Self.insertMigration036Receipt(
                accountID: accountID,
                organizationID: organizationID,
                streamID: streamID,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision,
                rawSnapshotID: rawSnapshotID,
                requestKey: requestKey,
                in: database
            )
            try database.execute(
                sql: "DELETE FROM accounts WHERE id = ?",
                arguments: [accountID.rawValue]
            )
        }
        counts = try await Self.migration036Counts(
            vault: migratedVault,
            rawSnapshotID: rawSnapshotID
        )
        XCTAssertEqual(counts, Migration036Counts(receipts: 0, pages: 0, rawSnapshots: 0))
        try await migratedRegistry.closeAll()
    }

    func testTransactionRollsBackAllWritesWhenItsOperationFails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(
            accountID: AccountID.make(),
            vaultKey: try VaultKey.generate()
        )
        try await vault.write { database in
            try database.execute(sql: "CREATE TABLE transactional_values (value TEXT NOT NULL)")
        }

        await XCTAssertThrowsErrorAsync {
            try await vault.writeTransaction { database in
                try database.execute(sql: "INSERT INTO transactional_values (value) VALUES ('first')")
                try database.execute(sql: "INSERT INTO transactional_values (value) VALUES ('second')")
                throw TransactionTestError.expectedFailure
            }
        }

        let count = try await vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transactional_values")
        }
        XCTAssertEqual(count, 0)
        try await registry.closeAll()
    }

    func testRemovingAnOpenVaultClosesAndErasesIt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        try await vault.write { database in
            try database.execute(sql: "CREATE TABLE account_private_value (value TEXT NOT NULL)")
        }

        try await registry.remove(accountID: accountID)

        let paths = VaultPaths(rootDirectory: directory, accountID: accountID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.directory.path))
    }

    func testRemovalRejectsNonOpaqueAccountIDBeforeConstructingAPath() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = try VaultRegistry(rootDirectory: directory)
        let unsafeAccountID = AccountID(rawValue: "../outside")!

        do {
            try await registry.remove(accountID: unsafeAccountID)
            XCTFail("Expected unsafe account path rejection.")
        } catch let error as VaultError {
            XCTAssertEqual(error, .unsafeAccountIDPath)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.deletingLastPathComponent().appendingPathComponent("outside").path
            )
        )
    }

    func testOpeningRejectsNonOpaqueAccountIDsBeforeCreatingOrOpeningAVault() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = try VaultRegistry(rootDirectory: directory)
        let unsafeAccountIDs = ["../outside", "not-a-uuid", UUID().uuidString.uppercased()]

        for rawValue in unsafeAccountIDs {
            let accountID = try XCTUnwrap(AccountID(rawValue: rawValue))
            do {
                _ = try await registry.open(accountID: accountID, vaultKey: try VaultKey.generate())
                XCTFail("Expected unsafe account path rejection for \(rawValue).")
            } catch let error as VaultError {
                XCTAssertEqual(error, .unsafeAccountIDPath)
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Vaults", isDirectory: true).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.deletingLastPathComponent().appendingPathComponent("outside").path
        ))
    }

    func testDirectVaultInitializationRejectsTraversalLikeAccountIDBeforeCreatingPaths() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = try XCTUnwrap(AccountID(rawValue: "../outside"))

        XCTAssertThrowsError(
            try AccountVault(
                accountID: accountID,
                vaultKey: try VaultKey.generate(),
                rootDirectory: directory
            )
        ) { error in
            XCTAssertEqual(error as? VaultError, .unsafeAccountIDPath)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Vaults", isDirectory: true).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.deletingLastPathComponent().appendingPathComponent("outside").path
        ))
    }

    func testOpeningRefusesSymlinkedVaultPathComponentsWithoutOpeningOutsideRoot() async throws {
        let directory = try makeTemporaryDirectory()
        let external = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: external)
        }

        let accountID = AccountID.make()
        let key = try VaultKey.generate()

        let symlinkedRoot = directory.appendingPathComponent("symlinked-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkedRoot, withDestinationURL: external)
        try await assertOpenRefusesUnsafePath(
            root: symlinkedRoot,
            accountID: accountID,
            key: key,
            externalDirectory: external
        )

        let vaultsRoot = directory.appendingPathComponent("vaults-root", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultsRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: vaultsRoot.appendingPathComponent("Vaults", isDirectory: true),
            withDestinationURL: external
        )
        try await assertOpenRefusesUnsafePath(
            root: vaultsRoot,
            accountID: accountID,
            key: key,
            externalDirectory: external
        )

        let accountRoot = directory.appendingPathComponent("account-root", isDirectory: true)
        let vaults = accountRoot.appendingPathComponent("Vaults", isDirectory: true)
        try FileManager.default.createDirectory(at: vaults, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: vaults.appendingPathComponent(accountID.rawValue, isDirectory: true),
            withDestinationURL: external
        )
        try await assertOpenRefusesUnsafePath(
            root: accountRoot,
            accountID: accountID,
            key: key,
            externalDirectory: external
        )
    }

    private func assertOpenRefusesUnsafePath(
        root: URL,
        accountID: AccountID,
        key: VaultKey,
        externalDirectory: URL
    ) async throws {
        let registry = try VaultRegistry(rootDirectory: root)

        do {
            _ = try await registry.open(accountID: accountID, vaultKey: key)
            XCTFail("Expected a symlinked vault path component to be refused.")
        } catch let error as VaultError {
            XCTAssertEqual(error, .unsafeAccountIDPath)
        }
        let isOpen = await registry.isOpen(accountID: accountID)
        XCTAssertFalse(isOpen)

        XCTAssertThrowsError(
            try AccountVault(accountID: accountID, vaultKey: key, rootDirectory: root)
        ) { error in
            XCTAssertEqual(error as? VaultError, .unsafeAccountIDPath)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: externalDirectory,
                includingPropertiesForKeys: nil
            ),
            []
        )
    }

    func testRemovalRefusesSymlinkedVaultRootWithoutDeletingItsTarget() async throws {
        let directory = try makeTemporaryDirectory()
        let external = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: external)
        }

        let accountID = AccountID.make()
        let externalVault = external.appendingPathComponent(accountID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: externalVault, withIntermediateDirectories: true)
        let marker = externalVault.appendingPathComponent("must-not-delete")
        try Data("outside".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("Vaults", isDirectory: true),
            withDestinationURL: external
        )
        let registry = try VaultRegistry(rootDirectory: directory)

        do {
            try await registry.remove(accountID: accountID)
            XCTFail("Expected a symlinked vault root to be refused.")
        } catch let error as VaultError {
            XCTAssertEqual(error, .unsafeAccountIDPath)
        }

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "outside")
    }

    func testHeldMigrationBackupsDescriptorResistsDirectorySwapAndSymlinkRedirection() throws {
        let directory = try makeTemporaryDirectory()
        let external = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: external)
        }

        let accountID = AccountID.make()
        let components = ["Vaults", accountID.rawValue, "MigrationBackups"]
        let migrationBackups = directory
            .appendingPathComponent("Vaults", isDirectory: true)
            .appendingPathComponent(accountID.rawValue, isDirectory: true)
            .appendingPathComponent("MigrationBackups", isDirectory: true)
        let heldLocation = migrationBackups.deletingLastPathComponent()
            .appendingPathComponent("MigrationBackups-held", isDirectory: true)
        let source = migrationBackups.appendingPathComponent("source.sqlite")

        try NoFollowFilesystem.ensureDirectory(at: directory, components: components)
        try Data("encrypted-backup".utf8).write(to: source)

        try NoFollowFilesystem.withDirectory(
            beneath: directory,
            components: components,
            create: false
        ) { descriptor in
            // Model an attacker replacing the path after the backup creator
            // has opened MigrationBackups but before it publishes the file.
            try FileManager.default.moveItem(at: migrationBackups, to: heldLocation)
            try FileManager.default.createSymbolicLink(at: migrationBackups, withDestinationURL: external)

            try NoFollowFilesystem.copyRegularFileWithinDirectoryAtomically(
                descriptor,
                sourceName: "source.sqlite",
                destinationName: "033-role-search-page-replay-v2.sqlite"
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: external.appendingPathComponent("033-role-search-page-replay-v2.sqlite").path
        ))
        XCTAssertEqual(
            try Data(contentsOf: heldLocation.appendingPathComponent("033-role-search-page-replay-v2.sqlite")),
            Data("encrypted-backup".utf8)
        )
    }

    func testHeldDirectorySQLCipherVerificationPathsResistCandidateAndInstalledDatabaseSwaps() throws {
        let directory = try makeTemporaryDirectory()
        let external = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: external)
        }

        let key = try VaultKey.generate()
        for (accountID, leafDirectory, databaseName) in [
            (AccountID.make(), "MigrationBackups", "033-role-search-page-replay-v2.sqlite"),
            (AccountID.make(), "", "triage.sqlite")
        ] {
            var components = ["Vaults", accountID.rawValue]
            if !leafDirectory.isEmpty { components.append(leafDirectory) }
            try NoFollowFilesystem.ensureDirectory(at: directory, components: components)
            let targetDirectory = components.reduce(directory) { partial, component in
                partial.appendingPathComponent(component, isDirectory: true)
            }
            let database = targetDirectory.appendingPathComponent(databaseName)
            var configuration = AccountVault.configuration(vaultKey: key)
            configuration.journalMode = .default
            let queue = try DatabaseQueue(
                path: database.path,
                configuration: configuration
            )
            try queue.write { database in
                try database.execute(sql: "CREATE TABLE held_descriptor_values (value INTEGER NOT NULL)")
                try database.execute(sql: "INSERT INTO held_descriptor_values (value) VALUES (1)")
            }
            try queue.close()

            let heldDirectory = targetDirectory.deletingLastPathComponent()
                .appendingPathComponent("\(targetDirectory.lastPathComponent)-held", isDirectory: true)
            try NoFollowFilesystem.withDirectory(
                beneath: directory,
                components: components,
                create: false
            ) { descriptor in
                // Both backup-candidate and post-install verification must keep
                // reading the opened account directory after its pathname has
                // been replaced by an attacker-controlled symlink.
                try FileManager.default.moveItem(at: targetDirectory, to: heldDirectory)
                try FileManager.default.createSymbolicLink(at: targetDirectory, withDestinationURL: external)

                let pool = try DatabasePool(
                    path: "/dev/fd/\(descriptor)/\(databaseName)",
                    configuration: AccountVault.configuration(vaultKey: key, readonly: true)
                )
                defer { try? pool.close() }
                try AccountVault.verify(pool)
                let value = try pool.read { database in
                    try Int.fetchOne(database, sql: "SELECT value FROM held_descriptor_values")
                }
                XCTAssertEqual(value, 1)
            }

            XCTAssertFalse(FileManager.default.fileExists(
                atPath: external.appendingPathComponent(databaseName).path
            ))
        }
    }

    private func makePre033LegacyRoleReplayVault(
        directory: URL,
        accountID: AccountID,
        key: VaultKey
    ) async throws -> VaultPaths {
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: accountID, vaultKey: key)
        try await vault.write { database in
            try Self.removeMigration036Through038Schema(from: database)
            try database.execute(
                sql: "DELETE FROM schema_migrations WHERE id = '035-source-access-observations'"
            )
            try database.execute(
                sql: "DELETE FROM schema_migrations WHERE id = '033-role-search-page-replay-v2'"
            )
            try database.execute(
                sql: "DELETE FROM schema_migrations WHERE id = '034-role-search-page-replay-parser-identity'"
            )
            try database.execute(sql: "DROP TRIGGER source_access_protect_deletion_receipt")
            try database.execute(
                sql: "DROP TRIGGER source_access_protect_deletion_receipt_update"
            )
            try database.execute(sql: "DROP TABLE source_access_projections")
            try database.execute(sql: "DROP TABLE source_access_observations")
            try database.execute(sql: "DROP TABLE role_search_page_replays")
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
            try database.execute(
                sql: """
                    INSERT INTO role_search_page_replays VALUES
                    ('account', 'organization', 'legacy-role-search', 'org:legacy is:open',
                     1, '/search/issues?legacy', 'credential', 'capability', 'legacy-raw',
                     '\"legacy\"', 1, 1)
                    """
            )
        }
        try await registry.closeAll()
        return VaultPaths(rootDirectory: directory, accountID: accountID)
    }

    private func makeMigration033ReplayVault(
        directory: URL,
        key: VaultKey
    ) async throws -> Migration034Fixture {
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "legacy-org")!
        let streamID = SyncStreamID(rawValue: "legacy-role-discovery")!
        let credentialRevision = CredentialRevision(rawValue: "credential-1")!
        let capabilityRevision = CapabilityRevision(rawValue: "capability-1")!
        let observedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let rawSnapshotID = RawAPISnapshotID.make()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: accountID, vaultKey: key)
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: observedAt,
            lastValidatedAt: observedAt
        )
        let organization = GitHubOrganization(
            id: organizationID,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "MDEyOk9yZ2FuaXphdGlvbjE=")!,
            login: "legacy-org"
        )
        let access = OrganizationAccess(
            accountID: accountID,
            organizationID: organizationID,
            state: .available,
            capabilityRevision: capabilityRevision,
            capabilities: [],
            checkedAt: observedAt
        )
        try await AccountRepository(vault: vault).save(
            account,
            credentialRevision: credentialRevision
        )
        try await AccountRepository(vault: vault).save(
            organization,
            access: access,
            selectedAt: observedAt
        )
        try await CoverageRepository(vault: vault).save(
            CoverageRecord(
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                feature: .roleDiscovery,
                streamID: streamID,
                intervalStart: nil,
                intervalEnd: nil,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            ),
            attemptedAt: observedAt
        )
        try await RawAPISnapshotRepository(vault: vault).save(
            RawAPISnapshot(
                id: rawSnapshotID,
                accountID: accountID,
                githubNodeID: nil,
                endpoint: "/search/issues?legacy",
                eTag: "\"legacy\"",
                parserVersion: 1,
                observedAt: observedAt,
                payload: Data("{}".utf8)
            )
        )
        try await vault.write { database in
            try Self.removeMigration036Through038Schema(from: database)
            try database.execute(
                sql: "DELETE FROM schema_migrations WHERE id = '035-source-access-observations'"
            )
            try database.execute(
                sql: "DELETE FROM schema_migrations WHERE id = '034-role-search-page-replay-parser-identity'"
            )
            try database.execute(sql: "DROP TRIGGER source_access_protect_deletion_receipt")
            try database.execute(
                sql: "DROP TRIGGER source_access_protect_deletion_receipt_update"
            )
            try database.execute(sql: "DROP TABLE source_access_projections")
            try database.execute(sql: "DROP TABLE source_access_observations")
            try database.execute(sql: "DROP INDEX role_search_page_replays_snapshot")
            try database.execute(sql: "DROP TABLE role_search_page_replays")
            try database.execute(sql: """
                CREATE TABLE role_search_page_replays (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    feature TEXT NOT NULL CHECK (feature = 'roleDiscovery'),
                    stream_id TEXT NOT NULL REFERENCES sync_streams(id) ON DELETE CASCADE,
                    request_key TEXT NOT NULL,
                    query_value TEXT NOT NULL,
                    page INTEGER NOT NULL,
                    endpoint TEXT NOT NULL,
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    raw_snapshot_id TEXT NOT NULL
                        REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT,
                    etag TEXT,
                    last_modified TEXT,
                    parser_version INTEGER NOT NULL,
                    last_validated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (
                        account_id, organization_id, feature, stream_id, request_key,
                        credential_revision, capability_revision
                    ),
                    UNIQUE (
                        account_id, organization_id, feature, stream_id, endpoint,
                        credential_revision, capability_revision
                    ),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE
                )
                """)
            try database.execute(
                sql: """
                    INSERT INTO role_search_page_replays VALUES
                    (?, ?, 'roleDiscovery', ?, 'parser-v1', 'org:legacy is:open', 1,
                     '/search/issues?legacy', ?, ?, ?, '\"legacy\"', NULL, 1, 1)
                    """,
                arguments: [
                    accountID.rawValue,
                    organizationID.rawValue,
                    streamID.rawValue,
                    credentialRevision.rawValue,
                    capabilityRevision.rawValue,
                    rawSnapshotID.rawValue
                ]
            )
            try database.execute(sql: """
                CREATE INDEX role_search_page_replays_snapshot
                ON role_search_page_replays (raw_snapshot_id)
                """)
        }
        try await registry.closeAll()
        return Migration034Fixture(
            accountID: accountID,
            organizationID: organizationID,
            streamID: streamID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            rawSnapshotID: rawSnapshotID
        )
    }

    private nonisolated static func removeMigration036Through038Schema(from database: Database) throws {
        try removeMigration038Schema(from: database)
        try database.execute(
            sql: "DROP TRIGGER IF EXISTS repository_inventory_protect_replay_snapshot_update"
        )
        try database.execute(
            sql: "DELETE FROM schema_migrations WHERE id = '037-repository-inventory-replay-snapshot-idempotency'"
        )
        try database.execute(
            sql: "DROP TRIGGER IF EXISTS repository_inventory_protect_replay_snapshot_delete"
        )
        try database.execute(
            sql: "DROP TABLE IF EXISTS repository_inventory_replay_receipt_pages"
        )
        try database.execute(
            sql: "DROP TABLE IF EXISTS repository_inventory_replay_receipts"
        )
        try database.execute(sql: "DROP INDEX IF EXISTS sync_streams_exact_scope")
        try database.execute(
            sql: """
                DELETE FROM schema_migrations
                WHERE id = '036-repository-inventory-replay-receipts'
                """
        )
    }

    private nonisolated static func removeMigration038Schema(from database: Database) throws {
        try database.execute(sql: "DROP INDEX IF EXISTS relation_evidence_exact_authority")
        try database.execute(sql: "DROP INDEX IF EXISTS relation_evidence_raw_snapshot")
        try database.execute(sql: "ALTER TABLE relation_evidence RENAME TO relation_evidence_038")
        try database.execute(sql: """
            CREATE TABLE relation_evidence (
                relation_id TEXT NOT NULL REFERENCES relations(id) ON DELETE CASCADE,
                evidence_id TEXT NOT NULL,
                source TEXT NOT NULL,
                source_node_id TEXT,
                source_event_id TEXT,
                source_revision TEXT,
                observed_at_ms INTEGER NOT NULL,
                excerpt TEXT,
                PRIMARY KEY (relation_id, evidence_id)
            )
            """)
        try database.execute(sql: """
            INSERT INTO relation_evidence (
                relation_id, evidence_id, source, source_node_id, source_event_id,
                source_revision, observed_at_ms, excerpt
            )
            SELECT relation_id, evidence_id, source, source_node_id, source_event_id,
                   source_revision, observed_at_ms, excerpt
            FROM relation_evidence_038
            WHERE source != 'legacyUnverified'
            """)
        try database.execute(sql: "DROP TABLE relation_evidence_038")
        try database.execute(
            sql: "DELETE FROM schema_migrations WHERE id = '038-relation-evidence-authority-provisional'"
        )
    }

    private nonisolated static func foreignKeyDescriptions(
        table: String,
        in database: Database
    ) throws -> [String] {
        try Row.fetchAll(
            database,
            sql: "SELECT * FROM pragma_foreign_key_list(?)",
            arguments: [table]
        ).map { row in
            let source: String = row["from"]
            let parent: String = row["table"]
            let destination: String = row["to"]
            let deletion: String = row["on_delete"]
            return "\(source):\(parent).\(destination):\(deletion)"
        }
    }

    private nonisolated static func insertMigration036Receipt(
        accountID: AccountID,
        organizationID: OrganizationID,
        streamID: SyncStreamID,
        credentialRevision: CredentialRevision,
        capabilityRevision: CapabilityRevision,
        rawSnapshotID: RawAPISnapshotID,
        requestKey: String,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO repository_inventory_replay_receipts (
                    id, account_id, organization_id, feature, stream_id, request_key,
                    credential_revision, capability_revision, raw_source_revision,
                    etag, last_modified, raw_observed_at_ms, normalized_committed_at_ms,
                    last_validated_at_ms, parser_version, page_count,
                    normalized_repository_count, normalized_digest
                ) VALUES (?, ?, ?, 'repositories', ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, 1, 1, 0, ?)
                """,
            arguments: [
                "repository-inventory-receipt-036",
                accountID.rawValue,
                organizationID.rawValue,
                streamID.rawValue,
                requestKey,
                credentialRevision.rawValue,
                capabilityRevision.rawValue,
                "repository-inventory-v1:migration-036",
                "\"migration-036\"",
                Int64(3_600_000),
                Int64(3_600_000),
                Int64(3_600_000),
                Data(repeating: 0x36, count: 32)
            ]
        )
        try database.execute(
            sql: """
                INSERT INTO repository_inventory_replay_receipt_pages (
                    receipt_id, page_index, endpoint, request_key, link_header,
                    next_endpoint, raw_snapshot_id, object_count,
                    raw_payload_digest, repository_id_digest
                ) VALUES (?, 1, ?, ?, NULL, NULL, ?, 0, ?, ?)
                """,
            arguments: [
                "repository-inventory-receipt-036",
                "/orgs/migration-org/repos?type=all&per_page=100",
                requestKey,
                rawSnapshotID.rawValue,
                Data(repeating: 0x37, count: 32),
                Data(repeating: 0x38, count: 32)
            ]
        )
    }

    private nonisolated static func migration036Counts(
        vault: AccountVault,
        rawSnapshotID: RawAPISnapshotID
    ) async throws -> Migration036Counts {
        try await vault.read { database in
            Migration036Counts(
                receipts: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM repository_inventory_replay_receipts"
                ) ?? 0,
                pages: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM repository_inventory_replay_receipt_pages"
                ) ?? 0,
                rawSnapshots: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM raw_api_snapshots WHERE id = ?",
                    arguments: [rawSnapshotID.rawValue]
                ) ?? 0
            )
        }
    }

    private func encryptedConfiguration(vaultKey: VaultKey) -> Configuration {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { database in
            try database.usePassphrase(vaultKey.data)
            try database.execute(sql: "PRAGMA cipher_memory_security = ON")
        }
        return configuration
    }

    private func readRoleReplayCount(
        at url: URL,
        configuration: Configuration
    ) async throws -> Int {
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        defer { try? pool.close() }
        return try await pool.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM role_search_page_replays") ?? 0
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct Migration034Fixture {
    let accountID: AccountID
    let organizationID: OrganizationID
    let streamID: SyncStreamID
    let credentialRevision: CredentialRevision
    let capabilityRevision: CapabilityRevision
    let rawSnapshotID: RawAPISnapshotID
}

private struct Migration036SchemaInspection: Sendable {
    let checksum: String?
    let replaySnapshotUpdateChecksum: String?
    let parentColumns: [String]
    let pageColumns: [String]
    let parentForeignKeys: [String]
    let pageForeignKeys: [String]
    let indexes: [String]
    let triggers: [String]
    let parentSQL: String
    let pageSQL: String
    let replaySnapshotUpdateTriggerSQL: String
}

private struct Migration036Counts: Equatable, Sendable {
    let receipts: Int
    let pages: Int
    let rawSnapshots: Int
}

private enum TransactionTestError: Error {
    case expectedFailure
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw an error.", file: file, line: line)
    } catch {
        // Expected.
    }
}
