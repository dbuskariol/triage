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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
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
