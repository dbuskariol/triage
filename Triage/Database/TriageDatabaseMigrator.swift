import Foundation
import GRDB

enum TriageDatabaseMigrationError: Error, Equatable, Sendable {
    case checksumMismatch(migrationID: String)
}

private struct TriageDatabaseMigration: Sendable {
    let id: String
    let checksum: String
    let apply: @Sendable (Database) throws -> Void
}

enum TriageDatabaseMigrator {
    static func migrate(_ databasePool: DatabasePool) throws {
        try databasePool.write { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    id TEXT PRIMARY KEY NOT NULL,
                    checksum TEXT NOT NULL,
                    applied_at_ms INTEGER NOT NULL
                )
                """)
        }

        for migration in migrations {
            try databasePool.write { database in
                try database.inTransaction {
                    let storedChecksum = try String.fetchOne(
                        database,
                        sql: "SELECT checksum FROM schema_migrations WHERE id = ?",
                        arguments: [migration.id]
                    )
                    if let storedChecksum {
                        guard storedChecksum == migration.checksum else {
                            throw TriageDatabaseMigrationError.checksumMismatch(
                                migrationID: migration.id
                            )
                        }
                        return .commit
                    }

                    try migration.apply(database)
                    try database.execute(
                        sql: """
                            INSERT INTO schema_migrations (id, checksum, applied_at_ms)
                            VALUES (?, ?, ?)
                            """,
                        arguments: [
                            migration.id,
                            migration.checksum,
                            Int64(Date().timeIntervalSince1970 * 1_000)
                        ]
                    )
                    return .commit
                }
            }
        }
    }

    private static let migrations: [TriageDatabaseMigration] = [
        TriageDatabaseMigration(
            id: "001-vault-metadata",
            checksum: "9de651412d414a84f9342c82bc1a5fd89a3be6bd4a577708ba6078097e6f915f"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE vault_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                )
                """)
            try database.execute(
                sql: """
                    INSERT INTO vault_metadata (key, value)
                    VALUES ('schema_family', 'triage')
                    """
            )
        }
    ]
}
