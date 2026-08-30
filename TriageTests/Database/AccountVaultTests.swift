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
        XCTAssertEqual(migrations.last?.id, "028-account-organization-durable-state")
        XCTAssertEqual(
            migrations.last?.checksum,
            "594034d7445efa2e5c4893fc2daff3687810fb9b5c04579a165627dd4c95b2b6"
        )
        try await registry.closeAll()
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
