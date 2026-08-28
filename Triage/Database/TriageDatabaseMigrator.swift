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
        },
        TriageDatabaseMigration(
            id: "002-identity",
            checksum: "4c291acecae8c15df9a05f767b84adad5c9d82fa28bd2f20d0aa53583d77121a"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE accounts (
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
                    UNIQUE (github_user_id, credential_id),
                    UNIQUE (github_node_id, credential_id)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE organizations (
                    id TEXT PRIMARY KEY NOT NULL,
                    github_organization_id TEXT NOT NULL UNIQUE,
                    github_node_id TEXT NOT NULL UNIQUE,
                    login TEXT NOT NULL,
                    display_name TEXT,
                    avatar_url TEXT,
                    updated_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE account_organizations (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    access_state TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    selected_at_ms INTEGER,
                    checked_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, organization_id)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE actors (
                    id TEXT PRIMARY KEY NOT NULL,
                    github_node_id TEXT NOT NULL UNIQUE,
                    github_actor_id TEXT,
                    login TEXT NOT NULL,
                    display_name TEXT,
                    avatar_url TEXT,
                    kind TEXT NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE teams (
                    id TEXT PRIMARY KEY NOT NULL,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    github_node_id TEXT NOT NULL UNIQUE,
                    slug TEXT NOT NULL,
                    name TEXT NOT NULL,
                    privacy TEXT,
                    updated_at_ms INTEGER NOT NULL,
                    UNIQUE (organization_id, slug)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE team_memberships (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
                    membership_state TEXT NOT NULL,
                    observed_at_ms INTEGER NOT NULL,
                    expires_at_ms INTEGER,
                    PRIMARY KEY (account_id, team_id)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE repositories (
                    id TEXT PRIMARY KEY NOT NULL,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    github_repository_id TEXT NOT NULL UNIQUE,
                    github_node_id TEXT NOT NULL UNIQUE,
                    owner_login TEXT NOT NULL,
                    name TEXT NOT NULL,
                    is_private INTEGER NOT NULL CHECK (is_private IN (0, 1)),
                    is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1)),
                    has_discussions INTEGER NOT NULL CHECK (has_discussions IN (0, 1)),
                    html_url TEXT NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    archived_at_ms INTEGER,
                    UNIQUE (organization_id, owner_login, name)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE account_repository_access (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
                    access_state TEXT NOT NULL,
                    observed_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, repository_id)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE capabilities (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    repository_id TEXT REFERENCES repositories(id) ON DELETE CASCADE,
                    capability TEXT NOT NULL,
                    status TEXT NOT NULL,
                    checked_at_ms INTEGER NOT NULL,
                    detail_fingerprint TEXT,
                    PRIMARY KEY (account_id, organization_id, repository_id, capability)
                )
                """)
            try database.execute(sql: """
                CREATE INDEX account_organizations_selected
                ON account_organizations (account_id, selected_at_ms DESC)
                """)
            try database.execute(sql: """
                CREATE INDEX repositories_organization_updated
                ON repositories (organization_id, updated_at_ms DESC)
                """)
            try database.execute(sql: """
                CREATE INDEX capabilities_lookup
                ON capabilities (account_id, organization_id, capability)
                """)
        },
        TriageDatabaseMigration(
            id: "003-github-nodes",
            checksum: "b9072cbeb59ca8924e2e551bac03cb225c1f4b2d4114d19326e8657d1a34fcc5"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE github_nodes (
                    github_node_id TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    repository_id TEXT REFERENCES repositories(id) ON DELETE SET NULL,
                    kind TEXT NOT NULL,
                    numeric_id TEXT,
                    number INTEGER,
                    title TEXT NOT NULL,
                    state TEXT NOT NULL,
                    html_url TEXT NOT NULL,
                    body_markdown TEXT,
                    author_id TEXT REFERENCES actors(id) ON DELETE SET NULL,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    closed_at_ms INTEGER,
                    merged_at_ms INTEGER,
                    source_revision TEXT NOT NULL,
                    last_observed_at_ms INTEGER NOT NULL,
                    accessibility_state TEXT NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE INDEX github_nodes_org_kind_updated
                ON github_nodes (account_id, organization_id, kind, updated_at_ms DESC)
                """)
            try database.execute(sql: """
                CREATE INDEX github_nodes_repository_number
                ON github_nodes (repository_id, number)
                """)
        },
        TriageDatabaseMigration(
            id: "004-issues-and-pull-requests",
            checksum: "ab60c6c3f98275b0fefb127c7d730e70d40514b4249bded7504b59b54ea50bf9"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE issues (
                    github_node_id TEXT PRIMARY KEY NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    locked INTEGER NOT NULL CHECK (locked IN (0, 1)),
                    comments_count INTEGER NOT NULL,
                    assignee_node_ids_json BLOB NOT NULL,
                    label_node_ids_json BLOB NOT NULL,
                    milestone_node_id TEXT,
                    updated_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE pull_requests (
                    github_node_id TEXT PRIMARY KEY NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    is_draft INTEGER NOT NULL CHECK (is_draft IN (0, 1)),
                    mergeable_state TEXT,
                    head_ref TEXT,
                    base_ref TEXT,
                    review_decision TEXT,
                    unresolved_thread_count INTEGER NOT NULL,
                    latest_commit_at_ms INTEGER,
                    updated_at_ms INTEGER NOT NULL
                )
                """)
        },
        TriageDatabaseMigration(
            id: "005-reviews-comments-timeline",
            checksum: "579128bcabd7698d18e2d79e2d6f31cd04b2df4bf25827815195a17c25e27ee1"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE reviews (
                    github_node_id TEXT PRIMARY KEY NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    pull_request_node_id TEXT NOT NULL REFERENCES pull_requests(github_node_id) ON DELETE CASCADE,
                    author_id TEXT REFERENCES actors(id) ON DELETE SET NULL,
                    state TEXT NOT NULL,
                    body_markdown TEXT,
                    submitted_at_ms INTEGER,
                    html_url TEXT,
                    updated_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE comments (
                    github_node_id TEXT PRIMARY KEY NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    parent_node_id TEXT NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    author_id TEXT REFERENCES actors(id) ON DELETE SET NULL,
                    kind TEXT NOT NULL,
                    body_markdown TEXT NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    html_url TEXT NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE timeline_events (
                    github_event_id TEXT PRIMARY KEY NOT NULL,
                    subject_node_id TEXT NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    actor_id TEXT REFERENCES actors(id) ON DELETE SET NULL,
                    kind TEXT NOT NULL,
                    occurred_at_ms INTEGER NOT NULL,
                    payload_json BLOB NOT NULL,
                    source_revision TEXT NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE INDEX timeline_events_subject_occurred
                ON timeline_events (subject_node_id, occurred_at_ms DESC)
                """)
        }
    ]
}
