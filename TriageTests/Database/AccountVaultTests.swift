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
        XCTAssertEqual(migrations.last?.id, "031-raw-request-authority")
        XCTAssertEqual(
            migrations.last?.checksum,
            "5d7c3aa43bbc9a8a962b2bf34625b8e86fc59da3157656e5d1897182b72f5db3"
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
                        '031-raw-request-authority'
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

        try TriageDatabaseMigrator.migrate(legacyPool)

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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
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
