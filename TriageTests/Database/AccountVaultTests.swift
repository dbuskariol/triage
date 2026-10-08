import GRDB
import XCTest
@testable import Triage

final class AccountVaultTests: XCTestCase {
    func testFreshVaultCreatesOnlyCompactSchema() async throws {
        let (directory, registry, vault) = try await openVault()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { Task { try? await registry.closeAll() } }

        let objects = try await vault.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        }
        XCTAssertEqual(objects, [
            "account_capabilities", "account_organizations", "accounts", "ai_consents", "capabilities",
            "organizations", "rate_limit_buckets", "rate_limit_secondary_cooldowns", "schema_migrations",
            "triage_analysis_failures", "triage_decisions", "triage_items", "triage_local_status", "triage_read_state",
            "triage_refreshes", "triage_rules", "vault_metadata"
        ])
        let migrations = try await vault.read { database in
            try String.fetchAll(database, sql: "SELECT id FROM schema_migrations")
        }
        XCTAssertEqual(migrations, [TriageDatabaseMigrator.schemaVersion])
    }

    func testLegacyVaultDropsDeletedTablesAndPreservesCurrentRows() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = AccountID.make()
        let key = try VaultKey.generate()
        try createLegacyFixture(root: directory, accountID: accountID, key: key)

        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: accountID, vaultKey: key)
        defer { Task { try? await registry.closeAll() } }
        let values = try await vault.read { database in
            (
                try String.fetchOne(database, sql: "SELECT login FROM accounts"),
                try Int.fetchOne(database, sql: "SELECT enabled FROM ai_consents"),
                try String.fetchOne(database, sql: "SELECT fingerprint FROM triage_items"),
                try database.tableExists("repositories"),
                try database.tableExists("role_search_page_replays"),
                try String.fetchAll(database, sql: "SELECT id FROM schema_migrations")
            )
        }
        XCTAssertEqual(values.0, "octocat")
        XCTAssertEqual(values.1, 1)
        XCTAssertEqual(values.2, "fingerprint")
        XCTAssertFalse(values.3)
        XCTAssertFalse(values.4)
        XCTAssertEqual(values.5, [TriageDatabaseMigrator.schemaVersion])
    }

    /// The state left by the first compact migration: legacy tables gone, but
    /// retained tables still carrying a foreign key to the removed
    /// `repositories` table, which made every vault open fail.
    func testPartiallyCompactedVaultWithDanglingForeignKeyOpensAndKeepsRows() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = AccountID.make()
        let key = try VaultKey.generate()
        try createLegacyFixture(root: directory, accountID: accountID, key: key, migrationID: "v2-001-schema", includeLegacyTables: false)

        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: accountID, vaultKey: key)
        defer { Task { try? await registry.closeAll() } }
        let values = try await vault.read { database in
            (
                try String.fetchOne(database, sql: "SELECT login FROM accounts"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM capabilities"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM triage_items"),
                try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").count,
                try String.fetchOne(database, sql: "SELECT sql FROM sqlite_master WHERE name = 'capabilities'") ?? "",
                try String.fetchOne(database, sql: "SELECT sql FROM sqlite_master WHERE name = 'triage_items'") ?? ""
            )
        }
        XCTAssertEqual(values.0, "octocat")
        XCTAssertEqual(values.1, 1)
        XCTAssertEqual(values.2, 1)
        XCTAssertEqual(values.3, 0)
        XCTAssertFalse(values.4.contains("repositories"))
        // Observed tables must be rowid tables so live UI updates fire.
        XCTAssertFalse(values.5.uppercased().contains("WITHOUT ROWID"))
    }

    func testMigrationsAreIdempotent() async throws {
        let (directory, registry, vault) = try await openVault()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { Task { try? await registry.closeAll() } }
        try await vault.applyMigrations()
        XCTAssertEqual(TriageDatabaseMigrator.migrationCount, 1)
    }

    func testVaultPersistsOnlyWithCorrectKey() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = AccountID.make()
        let key = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: accountID, vaultKey: key)
        try await vault.write { database in try database.execute(sql: "CREATE TABLE test_value (value TEXT NOT NULL)") }
        try await vault.write { database in try database.execute(sql: "INSERT INTO test_value VALUES ('encrypted')") }
        try await registry.closeAll()
        let reopened = try await VaultRegistry(rootDirectory: directory).open(accountID: accountID, vaultKey: key)
        let value = try await reopened.read { try String.fetchOne($0, sql: "SELECT value FROM test_value") }
        XCTAssertEqual(value, "encrypted")
    }

    private func openVault() async throws -> (URL, VaultRegistry, AccountVault) {
        let directory = try temporaryDirectory()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: .make(), vaultKey: try VaultKey.generate())
        return (directory, registry, vault)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TriageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func createLegacyFixture(
        root: URL, accountID: AccountID, key: VaultKey,
        migrationID: String = "061-triage-store-v1", includeLegacyTables: Bool = true
    ) throws {
        let path = VaultPaths(rootDirectory: root, accountID: accountID).database
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try DatabaseQueue(path: path.path, configuration: AccountVault.configuration(vaultKey: key))
        defer { try? database.close() }
        try database.write { db in
            try db.execute(sql: "CREATE TABLE schema_migrations (id TEXT PRIMARY KEY NOT NULL, checksum TEXT NOT NULL, applied_at_ms INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO schema_migrations VALUES (?, 'legacy', 1)", arguments: [migrationID])
            try db.execute(sql: "CREATE TABLE vault_metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
            try db.execute(sql: "CREATE TABLE accounts (id TEXT PRIMARY KEY NOT NULL, github_user_id TEXT NOT NULL, github_node_id TEXT NOT NULL, login TEXT NOT NULL, display_name TEXT, avatar_url TEXT, authentication_kind TEXT NOT NULL, credential_id TEXT NOT NULL, credential_status TEXT NOT NULL, credential_revision TEXT NOT NULL, created_at_ms INTEGER NOT NULL, last_validated_at_ms INTEGER, disabled_at_ms INTEGER, access_token_expires_at_ms INTEGER, refresh_token_expires_at_ms INTEGER)")
            try db.execute(sql: "INSERT INTO accounts VALUES ('\(accountID.rawValue)', '1', 'node', 'octocat', NULL, NULL, 'oauth', 'credential', 'active', 'revision', 1, NULL, NULL, NULL, NULL)")
            try db.execute(sql: "CREATE TABLE organizations (id TEXT PRIMARY KEY NOT NULL, github_organization_id TEXT NOT NULL UNIQUE, github_node_id TEXT NOT NULL UNIQUE, login TEXT NOT NULL, display_name TEXT, avatar_url TEXT, updated_at_ms INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO organizations VALUES ('org', '2', 'org-node', 'github', NULL, NULL, 1)")
            try db.execute(sql: "CREATE TABLE account_organizations (account_id TEXT NOT NULL, organization_id TEXT NOT NULL, access_state TEXT NOT NULL, capability_revision TEXT NOT NULL, selected_at_ms INTEGER, checked_at_ms INTEGER NOT NULL, PRIMARY KEY (account_id, organization_id))")
            try db.execute(sql: "INSERT INTO account_organizations VALUES ('\(accountID.rawValue)', 'org', 'available', 'cap', NULL, 1)")
            try db.execute(sql: "CREATE TABLE ai_consents (account_id TEXT NOT NULL, organization_id TEXT NOT NULL, enabled INTEGER NOT NULL, selected_model TEXT, updated_at_ms INTEGER NOT NULL, automatic_action_confidence_threshold REAL NOT NULL DEFAULT 0.92, PRIMARY KEY (account_id, organization_id))")
            try db.execute(sql: "INSERT INTO ai_consents VALUES ('\(accountID.rawValue)', 'org', 1, NULL, 1, 0.92)")
            try db.execute(sql: "CREATE TABLE triage_items (account_id TEXT NOT NULL, organization_id TEXT NOT NULL, node_id TEXT NOT NULL, item_json BLOB NOT NULL, fingerprint TEXT NOT NULL, urgency_rank INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, is_active INTEGER NOT NULL, last_seen_at_ms INTEGER NOT NULL, PRIMARY KEY (account_id, organization_id, node_id)) WITHOUT ROWID")
            try db.execute(sql: "INSERT INTO triage_items VALUES ('\(accountID.rawValue)', 'org', 'node', X'00', 'fingerprint', 1, 1, 1, 1)")
            try db.execute(sql: "CREATE TABLE repositories (id TEXT PRIMARY KEY)")
            try db.execute(sql: "CREATE TABLE capabilities (id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE, repository_id TEXT REFERENCES repositories(id) ON DELETE CASCADE, capability TEXT NOT NULL, status TEXT NOT NULL, checked_at_ms INTEGER NOT NULL, detail_fingerprint TEXT)")
            try db.execute(sql: "INSERT INTO capabilities VALUES ('cap', '\(accountID.rawValue)', 'org', NULL, 'issues', 'available', 1, NULL)")
            if includeLegacyTables {
                try db.execute(sql: "CREATE TABLE role_search_page_replays (id TEXT PRIMARY KEY)")
            } else {
                // Reproduce a retained table whose foreign key names a dropped table.
                try db.execute(sql: "DROP TABLE repositories")
            }
        }
    }
}
