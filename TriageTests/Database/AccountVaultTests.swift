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
        XCTAssertEqual(migrations.last?.id, "035-source-access-observations")
        XCTAssertEqual(
            migrations.last?.checksum,
            "0e3720d9d2f00f2d1cc517da11b4402d9c447bc641b7e3b9fc907fce73c09b6e"
        )
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
                        '035-source-access-observations'
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
            try database.execute(sql: "CREATE TABLE sync_streams (id TEXT PRIMARY KEY NOT NULL)")
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

    private func makePre033LegacyRoleReplayVault(
        directory: URL,
        accountID: AccountID,
        key: VaultKey
    ) async throws -> VaultPaths {
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: accountID, vaultKey: key)
        try await vault.write { database in
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
