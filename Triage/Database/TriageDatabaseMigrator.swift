import Foundation
import GRDB

enum TriageDatabaseMigrationError: Error, Equatable, Sendable {
    case foreignKeyViolation
}

/// Reconciles any vault to the current schema in one transaction.
///
/// The schema is declared once (`tables` + `indexes`). A vault whose recorded
/// version differs — including vaults from the pre-rebuild architecture — is
/// reconciled by dropping every unknown object and rebuilding each known table
/// from its canonical definition while copying the columns both versions
/// share. Foreign keys are verified before commit, so a failed reconcile
/// leaves the vault exactly as it was.
enum TriageDatabaseMigrator {
    /// Bump when `tables` or `indexes` change.
    static let schemaVersion = "v2-005-schema"
    static let migrationCount = 1

    private struct Table {
        let name: String
        /// Column definitions and table constraints, without the table name.
        let body: String

        /// Never use WITHOUT ROWID: SQLite's update hook ignores those tables,
        /// so GRDB observations (the live Inbox) would never see their writes.
        func create(as tableName: String) -> String {
            "CREATE TABLE \(tableName) (\(body))"
        }
    }

    /// Parents before children.
    private static let tables: [Table] = [
        Table(name: "vault_metadata", body: """
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
            """),
        Table(name: "accounts", body: """
            id TEXT PRIMARY KEY NOT NULL,
            github_user_id TEXT NOT NULL,
            github_node_id TEXT NOT NULL,
            login TEXT NOT NULL,
            display_name TEXT,
            avatar_url TEXT,
            authentication_kind TEXT NOT NULL,
            credential_id TEXT NOT NULL,
            credential_status TEXT NOT NULL,
            credential_revision TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            last_validated_at_ms INTEGER,
            disabled_at_ms INTEGER,
            access_token_expires_at_ms INTEGER,
            refresh_token_expires_at_ms INTEGER,
            UNIQUE (github_user_id, credential_id),
            UNIQUE (github_node_id, credential_id)
            """),
        Table(name: "organizations", body: """
            id TEXT PRIMARY KEY NOT NULL,
            github_organization_id TEXT NOT NULL UNIQUE,
            github_node_id TEXT NOT NULL UNIQUE,
            login TEXT NOT NULL,
            display_name TEXT,
            avatar_url TEXT,
            updated_at_ms INTEGER NOT NULL
            """),
        Table(name: "account_organizations", body: """
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
            access_state TEXT NOT NULL,
            capability_revision TEXT NOT NULL,
            selected_at_ms INTEGER,
            checked_at_ms INTEGER NOT NULL,
            PRIMARY KEY (account_id, organization_id)
            """),
        Table(name: "capabilities", body: """
            id TEXT PRIMARY KEY NOT NULL,
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
            repository_id TEXT,
            capability TEXT NOT NULL,
            status TEXT NOT NULL,
            checked_at_ms INTEGER NOT NULL,
            detail_fingerprint TEXT
            """),
        Table(name: "account_capabilities", body: """
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            capability TEXT NOT NULL,
            status TEXT NOT NULL,
            checked_at_ms INTEGER NOT NULL,
            detail_fingerprint TEXT,
            PRIMARY KEY (account_id, capability)
            """),
        Table(name: "ai_consents", body: """
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
            enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
            selected_model TEXT,
            reasoning_effort TEXT,
            context_tier TEXT,
            updated_at_ms INTEGER NOT NULL,
            automatic_action_confidence_threshold REAL NOT NULL DEFAULT 0.92,
            PRIMARY KEY (account_id, organization_id)
            """),
        Table(name: "rate_limit_buckets", body: """
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            resource TEXT NOT NULL,
            remaining INTEGER,
            reset_at_ms INTEGER,
            retry_after_ms INTEGER,
            updated_at_ms INTEGER NOT NULL,
            rate_limit INTEGER,
            PRIMARY KEY (account_id, resource)
            """),
        Table(name: "rate_limit_secondary_cooldowns", body: """
            account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            pause_until_ms INTEGER NOT NULL
            """),
        Table(name: "triage_items", body: """
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            organization_id TEXT NOT NULL,
            node_id TEXT NOT NULL,
            item_json BLOB NOT NULL,
            fingerprint TEXT NOT NULL,
            urgency_rank INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            is_active INTEGER NOT NULL,
            last_seen_at_ms INTEGER NOT NULL,
            PRIMARY KEY (account_id, organization_id, node_id)
            """),
        Table(name: "triage_decisions", body: """
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            organization_id TEXT NOT NULL,
            node_id TEXT NOT NULL,
            fingerprint TEXT NOT NULL,
            decision_json BLOB NOT NULL,
            decided_at_ms INTEGER NOT NULL,
            rules_digest TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (account_id, organization_id, node_id)
            """),
        Table(name: "triage_analysis_failures", body: """
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            organization_id TEXT NOT NULL,
            node_id TEXT NOT NULL,
            fingerprint TEXT NOT NULL,
            reason TEXT NOT NULL,
            retry_at_ms INTEGER NOT NULL,
            attempts INTEGER NOT NULL,
            PRIMARY KEY (account_id, organization_id, node_id)
            """),
        Table(name: "triage_local_status", body: """
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            organization_id TEXT NOT NULL,
            node_id TEXT NOT NULL,
            status_json BLOB NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (account_id, organization_id, node_id)
            """),
        Table(name: "triage_refreshes", body: """
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            organization_id TEXT NOT NULL,
            last_refresh_at_ms INTEGER NOT NULL,
            PRIMARY KEY (account_id, organization_id)
            """),
        Table(name: "triage_rules", body: """
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            organization_id TEXT NOT NULL,
            rules_json BLOB NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (account_id, organization_id)
            """)
    ]

    private static let indexes = [
        "CREATE INDEX account_organizations_selected ON account_organizations (account_id, selected_at_ms DESC)",
        "CREATE INDEX capabilities_lookup ON capabilities (account_id, organization_id, repository_id, capability)",
        "CREATE INDEX triage_items_analysis_selection ON triage_items (account_id, organization_id, is_active, urgency_rank, updated_at_ms DESC)"
    ]

    static func migrate(
        _ databasePool: DatabasePool,
        beforeDestructiveMigration _: @escaping @Sendable (String) throws -> Void = { _ in }
    ) throws {
        // Foreign keys cannot be toggled inside a transaction.
        try databasePool.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA foreign_keys = OFF")
        }
        defer {
            try? databasePool.writeWithoutTransaction { database in
                try database.execute(sql: "PRAGMA foreign_keys = ON")
            }
        }
        let reconciled = try databasePool.write { database -> Bool in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    id TEXT PRIMARY KEY NOT NULL,
                    checksum TEXT NOT NULL,
                    applied_at_ms INTEGER NOT NULL
                )
                """)
            let applied = try String.fetchAll(database, sql: "SELECT id FROM schema_migrations")
            guard applied != [schemaVersion] else { return false }
            try reconcile(database)
            try database.execute(sql: "DELETE FROM schema_migrations")
            try database.execute(
                sql: "INSERT INTO schema_migrations (id, checksum, applied_at_ms) VALUES (?, ?, ?)",
                arguments: [schemaVersion, schemaVersion, Int64(Date().timeIntervalSince1970 * 1_000)]
            )
            guard try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty else {
                throw TriageDatabaseMigrationError.foreignKeyViolation
            }
            return true
        }
        if reconciled {
            // Reclaim space held by removed or rebuilt tables (one time per schema change).
            try databasePool.writeWithoutTransaction { try $0.execute(sql: "VACUUM") }
        }
    }

    private static func reconcile(_ database: Database) throws {
        let known = Set(tables.map(\.name) + ["schema_migrations"])
        let objects = try Row.fetchAll(database, sql: """
            SELECT type, name FROM sqlite_master
            WHERE type IN ('table', 'index', 'trigger', 'view') AND name NOT LIKE 'sqlite_%'
            """)
        // Drop every trigger, view, and index (canonical indexes are recreated),
        // and every table this version does not declare.
        for row in objects {
            let type: String = row["type"]
            let name: String = row["name"]
            guard type != "table" || !known.contains(name) else { continue }
            try database.execute(sql: "DROP \(type.uppercased()) IF EXISTS \(quoted(name))")
        }
        for table in tables {
            let staging = "\(table.name)__rebuild"
            try database.execute(sql: "DROP TABLE IF EXISTS \(quoted(staging))")
            try database.execute(sql: table.create(as: quoted(staging)))
            if try database.tableExists(table.name) {
                let current = Set(try database.columns(in: table.name).map(\.name))
                let shared = try database.columns(in: staging).map(\.name).filter(current.contains)
                if !shared.isEmpty {
                    let columns = shared.map(quoted).joined(separator: ", ")
                    try database.execute(sql: """
                        INSERT INTO \(quoted(staging)) (\(columns))
                        SELECT \(columns) FROM \(quoted(table.name))
                        """)
                }
                try database.execute(sql: "DROP TABLE \(quoted(table.name))")
            }
            try database.execute(sql: "ALTER TABLE \(quoted(staging)) RENAME TO \(quoted(table.name))")
        }
        for index in indexes {
            try database.execute(sql: index)
        }
        try database.execute(sql: "INSERT OR IGNORE INTO vault_metadata (key, value) VALUES ('schema_family', 'triage')")
    }

    private static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
