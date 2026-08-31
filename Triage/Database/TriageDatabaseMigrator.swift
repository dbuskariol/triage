import Foundation
import GRDB

enum TriageDatabaseMigrationError: Error, Equatable, Sendable {
    case checksumMismatch(migrationID: String)
}

private struct TriageDatabaseMigration: Sendable {
    let id: String
    let checksum: String
    let requiresVerifiedBackup: Bool
    let apply: @Sendable (Database) throws -> Void

    init(
        id: String,
        checksum: String,
        requiresVerifiedBackup: Bool = false,
        apply: @escaping @Sendable (Database) throws -> Void
    ) {
        self.id = id
        self.checksum = checksum
        self.requiresVerifiedBackup = requiresVerifiedBackup
        self.apply = apply
    }
}

enum TriageDatabaseMigrator {
    static var migrationCount: Int { migrations.count }

    static func migrate(
        _ databasePool: DatabasePool,
        beforeDestructiveMigration: @escaping @Sendable (String) throws -> Void
    ) throws {
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
            let isApplied = try databasePool.read { database in
                try String.fetchOne(
                    database,
                    sql: "SELECT checksum FROM schema_migrations WHERE id = ?",
                    arguments: [migration.id]
                ) != nil
            }
            if !isApplied, migration.requiresVerifiedBackup {
                try beforeDestructiveMigration(migration.id)
            }
            try databasePool.write { database in
                // DatabasePool.write already wraps this closure in a transaction.
                // Keeping the migration body and checksum record in that transaction
                // preserves atomicity without attempting an unsupported nested BEGIN.
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
                    return
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
        },
        TriageDatabaseMigration(
            id: "006-discussions-and-projects",
            checksum: "e4afdf87b0742673738d11b331717bce3f7defb4af12e81e09f56f3e58a9074f"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE discussions (
                    github_node_id TEXT PRIMARY KEY NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    category_name TEXT,
                    answer_comment_node_id TEXT,
                    comments_count INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE projects (
                    github_node_id TEXT PRIMARY KEY NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    number INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    state TEXT NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    UNIQUE (organization_id, number)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE project_items (
                    github_node_id TEXT PRIMARY KEY NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    project_node_id TEXT NOT NULL REFERENCES projects(github_node_id) ON DELETE CASCADE,
                    content_node_id TEXT REFERENCES github_nodes(github_node_id) ON DELETE SET NULL,
                    content_kind TEXT,
                    updated_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE project_field_values (
                    project_item_node_id TEXT NOT NULL REFERENCES project_items(github_node_id) ON DELETE CASCADE,
                    field_name TEXT NOT NULL,
                    display_value TEXT,
                    date_value_ms INTEGER,
                    actor_node_id TEXT,
                    PRIMARY KEY (project_item_node_id, field_name)
                )
                """)
        },
        TriageDatabaseMigration(
            id: "007-workflow-state",
            checksum: "2ca0b7df2981f7c26d75f342a67b6d1e2a1132398bd6257e492fae0a58d064bc"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE workflow_states (
                    work_item_id TEXT PRIMARY KEY NOT NULL,
                    status TEXT NOT NULL,
                    pinned INTEGER NOT NULL CHECK (pinned IN (0, 1)),
                    priority INTEGER NOT NULL,
                    snoozed_until_ms INTEGER,
                    follow_up_at_ms INTEGER,
                    local_note TEXT,
                    updated_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE action_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    work_item_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    detail TEXT,
                    origin TEXT NOT NULL,
                    state TEXT NOT NULL,
                    priority INTEGER NOT NULL,
                    due_at_ms INTEGER,
                    source_fingerprint TEXT,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    completed_at_ms INTEGER,
                    dismissed_at_ms INTEGER
                )
                """)
            try database.execute(sql: """
                CREATE TABLE action_item_evidence (
                    action_item_id TEXT NOT NULL REFERENCES action_items(id) ON DELETE CASCADE,
                    evidence_id TEXT NOT NULL,
                    PRIMARY KEY (action_item_id, evidence_id)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE workflow_history (
                    id TEXT PRIMARY KEY NOT NULL,
                    work_item_id TEXT NOT NULL,
                    action_item_id TEXT REFERENCES action_items(id) ON DELETE SET NULL,
                    kind TEXT NOT NULL,
                    prior_state_json BLOB,
                    next_state_json BLOB,
                    created_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE user_corrections (
                    id TEXT PRIMARY KEY NOT NULL,
                    work_item_id TEXT NOT NULL,
                    action_item_id TEXT REFERENCES action_items(id) ON DELETE SET NULL,
                    source_fingerprint TEXT,
                    correction_kind TEXT NOT NULL,
                    detail TEXT,
                    created_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE undo_transactions (
                    id TEXT PRIMARY KEY NOT NULL,
                    operation_kind TEXT NOT NULL,
                    inverse_payload_json BLOB NOT NULL,
                    expires_at_ms INTEGER NOT NULL,
                    created_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE INDEX action_items_work_item_state
                ON action_items (work_item_id, state, due_at_ms)
                """)
            try database.execute(sql: """
                CREATE INDEX workflow_history_work_item_created
                ON workflow_history (work_item_id, created_at_ms DESC)
                """)
        },
        TriageDatabaseMigration(
            id: "008-sync-and-coverage",
            checksum: "f77f0a5b7ce44a6cccb6173d07079d58f46ba7597c54281d935c9a7b29473b5d"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE sync_streams (
                    id TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    feature TEXT NOT NULL,
                    high_water_ms INTEGER,
                    last_successful_at_ms INTEGER,
                    last_attempt_at_ms INTEGER,
                    state TEXT NOT NULL,
                    failure_detail TEXT
                )
                """)
            try database.execute(sql: """
                CREATE TABLE sync_shards (
                    id TEXT PRIMARY KEY NOT NULL,
                    stream_id TEXT NOT NULL REFERENCES sync_streams(id) ON DELETE CASCADE,
                    query_kind TEXT NOT NULL,
                    interval_start_ms INTEGER,
                    interval_end_ms INTEGER,
                    page_cursor TEXT,
                    state TEXT NOT NULL,
                    completed_at_ms INTEGER
                )
                """)
            try database.execute(sql: """
                CREATE TABLE conditional_request_cache (
                    request_key TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    etag TEXT,
                    last_modified TEXT,
                    observed_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE rate_limit_buckets (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    resource TEXT NOT NULL,
                    remaining INTEGER,
                    reset_at_ms INTEGER,
                    retry_after_ms INTEGER,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, resource)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE coverage_records (
                    id TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    repository_id TEXT REFERENCES repositories(id) ON DELETE CASCADE,
                    feature TEXT NOT NULL,
                    stream_id TEXT NOT NULL REFERENCES sync_streams(id) ON DELETE CASCADE,
                    interval_start_ms INTEGER,
                    interval_end_ms INTEGER,
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    status TEXT NOT NULL,
                    last_successful_at_ms INTEGER,
                    failure_detail TEXT
                )
                """)
            try database.execute(sql: """
                CREATE TABLE raw_api_snapshots (
                    id TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    github_node_id TEXT,
                    endpoint TEXT NOT NULL,
                    etag TEXT,
                    parser_version INTEGER NOT NULL,
                    observed_at_ms INTEGER NOT NULL,
                    payload BLOB NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE INDEX coverage_records_lookup
                ON coverage_records (account_id, organization_id, feature, status)
                """)
        },
        TriageDatabaseMigration(
            id: "009-work-graph",
            checksum: "6a4ecbc4cda66da3aa8e38f38344d8b6a4c2ef99c9fb3e734404438847e49860"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE work_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    primary_node_id TEXT NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    state TEXT NOT NULL,
                    last_relevant_activity_at_ms INTEGER NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    UNIQUE (account_id, primary_node_id)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE work_item_members (
                    work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
                    github_node_id TEXT NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    role TEXT NOT NULL,
                    PRIMARY KEY (work_item_id, github_node_id)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE work_item_context_links (
                    work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
                    github_node_id TEXT NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    relation TEXT NOT NULL,
                    PRIMARY KEY (work_item_id, github_node_id, relation)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE relations (
                    id TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    subject_node_id TEXT NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    object_node_id TEXT,
                    kind TEXT NOT NULL,
                    confidence TEXT NOT NULL,
                    observed_at_ms INTEGER NOT NULL,
                    UNIQUE (account_id, subject_node_id, object_node_id, kind)
                )
                """)
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
                CREATE TABLE grouping_decisions (
                    source_node_id TEXT NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    destination_node_id TEXT NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    relation TEXT NOT NULL,
                    strength TEXT NOT NULL,
                    evidence_json BLOB NOT NULL,
                    decided_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (source_node_id, destination_node_id)
                )
                """)
        },
        TriageDatabaseMigration(
            id: "010-intelligence",
            checksum: "8e8c2fe3dc92a5814a9491d3b3c1199d290dd6aedb49b19a85efaf9bf8a7a5ee"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE attention_reasons (
                    id TEXT PRIMARY KEY NOT NULL,
                    work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
                    rule_id TEXT NOT NULL,
                    rule_version INTEGER NOT NULL,
                    category TEXT NOT NULL,
                    strength INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    explanation TEXT NOT NULL,
                    evaluated_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE attention_scores (
                    work_item_id TEXT PRIMARY KEY NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
                    score INTEGER NOT NULL,
                    breakdown_json BLOB NOT NULL,
                    evaluated_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE ai_consents (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
                    selected_model TEXT,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, organization_id)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE ai_analyses (
                    id TEXT PRIMARY KEY NOT NULL,
                    work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
                    fingerprint TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    prompt_version INTEGER NOT NULL,
                    output_schema_version INTEGER NOT NULL,
                    result_json BLOB NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    UNIQUE (work_item_id, fingerprint, model_id, prompt_version, output_schema_version)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE ai_model_cache (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    model_id TEXT NOT NULL,
                    metadata_json BLOB NOT NULL,
                    expires_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, organization_id, model_id)
                )
                """)
        },
        TriageDatabaseMigration(
            id: "011-search",
            checksum: "f9b78501a43ff2e4452b2b18d2be650b7287e9fc5f5f36e4b2d16aa3a5ec4c53"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE search_document_metadata (
                    id INTEGER PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    work_item_id TEXT REFERENCES work_items(id) ON DELETE CASCADE,
                    github_node_id TEXT REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    updated_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE VIRTUAL TABLE search_documents USING fts5(
                    title,
                    body,
                    repository,
                    labels,
                    people,
                    project_values,
                    action_text,
                    local_note,
                    tokenize = 'unicode61 remove_diacritics 2'
                )
                """)
            try database.execute(sql: """
                CREATE INDEX search_document_scope
                ON search_document_metadata (account_id, organization_id, updated_at_ms DESC)
                """)
        },
        TriageDatabaseMigration(
            id: "012-capability-record-identity",
            checksum: "a77b4849f5a7716183b4acb25c2ee4a7211e00a1265fd0f9bd21c0d15f1d3abc"
        ) { database in
            try database.execute(sql: "DROP INDEX capabilities_lookup")
            try database.execute(sql: "ALTER TABLE capabilities RENAME TO capabilities_legacy")
            try database.execute(sql: """
                CREATE TABLE capabilities (
                    id TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    repository_id TEXT REFERENCES repositories(id) ON DELETE CASCADE,
                    capability TEXT NOT NULL,
                    status TEXT NOT NULL,
                    checked_at_ms INTEGER NOT NULL,
                    detail_fingerprint TEXT
                )
                """)
            try database.execute(sql: """
                INSERT INTO capabilities (
                    id, account_id, organization_id, repository_id, capability, status, checked_at_ms, detail_fingerprint
                )
                SELECT
                    account_id || ':' || organization_id || ':' || COALESCE(repository_id, '-') || ':' || capability,
                    account_id, organization_id, repository_id, capability, status, checked_at_ms, detail_fingerprint
                FROM capabilities_legacy
                """)
            try database.execute(sql: "DROP TABLE capabilities_legacy")
            try database.execute(sql: """
                CREATE INDEX capabilities_lookup
                ON capabilities (account_id, organization_id, repository_id, capability)
                """)
        },
        TriageDatabaseMigration(
            id: "013-attention-reason-evidence",
            checksum: "7f5d7c2e98b2dcbd20d0794f1c81a64ba6fef2c114aa11f7abf7e6b2704f1ca3"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE attention_reason_evidence (
                    attention_reason_id TEXT NOT NULL REFERENCES attention_reasons(id) ON DELETE CASCADE,
                    evidence_id TEXT NOT NULL,
                    source TEXT NOT NULL,
                    source_node_id TEXT,
                    source_event_id TEXT,
                    source_revision TEXT,
                    observed_at_ms INTEGER NOT NULL,
                    excerpt TEXT,
                    PRIMARY KEY (attention_reason_id, evidence_id)
                )
                """)
        },
        TriageDatabaseMigration(
            id: "014-notification-deliveries",
            checksum: "e1c8dc56da0071a03b6814be2c88fd8ce3f3294032551a89b1777c2f6ca56d11"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE notification_deliveries (
                    dedupe_key TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
                    reason TEXT NOT NULL,
                    evidence_version TEXT NOT NULL,
                    delivered_at_ms INTEGER NOT NULL
                )
                """)
        },
        TriageDatabaseMigration(
            id: "015-credential-expiration",
            checksum: "f0d7a3e0a5d285e0fb9a7cb3d5c1e8cf8d3b2d9e77d8b3d9a7f2c6e4a7b5d0c2"
        ) { database in
            try database.execute(sql: "ALTER TABLE accounts ADD COLUMN access_token_expires_at_ms INTEGER")
            try database.execute(sql: "ALTER TABLE accounts ADD COLUMN refresh_token_expires_at_ms INTEGER")
        },
        TriageDatabaseMigration(
            id: "016-pull-request-review-context",
            checksum: "c5d90183a6714e7f82ad6fc2c344e87d6bc9a2b4f07e3b75d39fa3b2ca5d787e"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE review_threads (
                    github_node_id TEXT PRIMARY KEY NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    pull_request_node_id TEXT NOT NULL REFERENCES pull_requests(github_node_id) ON DELETE CASCADE,
                    is_resolved INTEGER NOT NULL CHECK (is_resolved IN (0, 1)),
                    requires_current_user_response INTEGER NOT NULL CHECK (requires_current_user_response IN (0, 1)),
                    updated_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE review_requests (
                    pull_request_node_id TEXT NOT NULL REFERENCES pull_requests(github_node_id) ON DELETE CASCADE,
                    requested_reviewer_node_id TEXT NOT NULL,
                    reviewer_kind TEXT NOT NULL,
                    requested_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (pull_request_node_id, requested_reviewer_node_id)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE status_checks (
                    github_node_id TEXT NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    context TEXT NOT NULL,
                    state TEXT NOT NULL,
                    is_required INTEGER NOT NULL CHECK (is_required IN (0, 1)),
                    completed_at_ms INTEGER,
                    PRIMARY KEY (github_node_id, context)
                )
                """)
            try database.execute(sql: """
                CREATE INDEX review_threads_pull_request_state
                ON review_threads (pull_request_node_id, is_resolved)
                """)
        },
        TriageDatabaseMigration(
            id: "017-rate-limit-cooldown",
            checksum: "9626f1440fd0d13900a7efefc7cf33102d0756a0367bea5d669b417b50868003"
        ) { database in
            try database.execute(sql: "ALTER TABLE rate_limit_buckets ADD COLUMN rate_limit INTEGER")
            try database.execute(sql: """
                CREATE TABLE rate_limit_secondary_cooldowns (
                    account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    pause_until_ms INTEGER NOT NULL
                )
                """)
        },
        TriageDatabaseMigration(
            id: "018-account-capabilities",
            checksum: "19c799017e05deefcf2b409765c1a068c50fedf8e87ca6c4ebc6b9099d1e7a92"
        ) { database in
            try database.execute(
                sql: "DELETE FROM capabilities WHERE capability = ?",
                arguments: [GitHubCapability.notifications.rawValue]
            )
            try database.execute(sql: """
                CREATE TABLE account_capabilities (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    capability TEXT NOT NULL,
                    status TEXT NOT NULL,
                    checked_at_ms INTEGER NOT NULL,
                    detail_fingerprint TEXT,
                    PRIMARY KEY (account_id, capability)
                )
                """)
        },
        TriageDatabaseMigration(
            id: "019-coverage-scope-index",
            checksum: "1c7ac6e9ab0875da22db9348e75cf4f3e5b76355e837d177c393f955fa1fdf36"
        ) { database in
            try database.execute(sql: """
                CREATE INDEX coverage_records_current_scope
                ON coverage_records (
                    account_id, organization_id, feature, stream_id, repository_id,
                    credential_revision, capability_revision, interval_start_ms, interval_end_ms
                )
                """)
        },
        TriageDatabaseMigration(
            id: "020-normalization-failures",
            checksum: "3b96595fd56c2e79a7f2b4294c44b31e59382561dc55ccdb7f5757196455f568"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE normalization_failures (
                    id TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    raw_snapshot_id TEXT NOT NULL REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT,
                    github_node_id TEXT,
                    endpoint TEXT NOT NULL,
                    parser_version INTEGER NOT NULL,
                    occurred_at_ms INTEGER NOT NULL,
                    redacted_diagnostic TEXT NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE INDEX normalization_failures_account_occurred
                ON normalization_failures (account_id, occurred_at_ms DESC)
                """)
        },
        TriageDatabaseMigration(
            id: "021-raw-snapshot-retention-index",
            checksum: "ce1a5bf39b3a307fa5ef6ae6a22e794bffd209ef2d060fb5b26bf5e6a8b1a432"
        ) { database in
            try database.execute(sql: """
                CREATE INDEX raw_api_snapshots_retention
                ON raw_api_snapshots (
                    account_id, github_node_id, endpoint, parser_version, observed_at_ms DESC, id DESC
                )
                """)
        },
        TriageDatabaseMigration(
            id: "022-hydrated-label-names",
            checksum: "c66056d6cf83dc2cb66a6bc5cbd9c065873cf7a526cb9ca1f0f0b3db2fd7e368"
        ) { database in
            try database.execute(sql: "ALTER TABLE issues ADD COLUMN label_names_json BLOB NOT NULL DEFAULT '[]'")
            try database.execute(sql: "ALTER TABLE pull_requests ADD COLUMN assignee_node_ids_json BLOB NOT NULL DEFAULT '[]'")
            try database.execute(sql: "ALTER TABLE pull_requests ADD COLUMN label_node_ids_json BLOB NOT NULL DEFAULT '[]'")
            try database.execute(sql: "ALTER TABLE pull_requests ADD COLUMN label_names_json BLOB NOT NULL DEFAULT '[]'")
        },
        TriageDatabaseMigration(
            id: "023-hydration-batch-metrics",
            checksum: "ef792a505bc5c9d451bfef8f5ff4fec9982487809643551b4c7fc67c2099a43c"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE github_hydration_batch_metrics (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    requested_node_count INTEGER NOT NULL CHECK (requested_node_count BETWEEN 1 AND 50),
                    response_bytes INTEGER NOT NULL CHECK (response_bytes BETWEEN 1 AND 4194304),
                    query_cost INTEGER NOT NULL CHECK (query_cost >= 0),
                    rate_limit_remaining INTEGER NOT NULL CHECK (rate_limit_remaining >= 0),
                    rate_limit_reset_at_ms INTEGER NOT NULL,
                    observed_at_ms INTEGER NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE INDEX github_hydration_batch_metrics_recent
                ON github_hydration_batch_metrics (account_id, observed_at_ms DESC, id DESC)
                """)
        },
        TriageDatabaseMigration(
            id: "024-project-v2-field-provenance",
            checksum: "f50dc66cc4a3786040a4d49376b7d9e48b3c546de0b1b2869cc45ae982dd9b4d"
        ) { database in
            try database.execute(sql: "ALTER TABLE project_field_values ADD COLUMN value_kind TEXT NOT NULL DEFAULT 'legacy'")
            try database.execute(sql: "ALTER TABLE project_field_values ADD COLUMN context TEXT NOT NULL DEFAULT 'legacy'")
            try database.execute(sql: "ALTER TABLE project_items ADD COLUMN content_node_reference TEXT")
        },
        TriageDatabaseMigration(
            id: "025-role-search-page-replay",
            checksum: "8821992560f9890caca36a34f7a56f5189483068e9253c08768d45964d2458d0"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE role_search_page_replays (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    request_key TEXT NOT NULL,
                    query_value TEXT NOT NULL,
                    page INTEGER NOT NULL CHECK (page BETWEEN 1 AND 100),
                    endpoint TEXT NOT NULL,
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    raw_snapshot_id TEXT NOT NULL REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT,
                    etag TEXT NOT NULL,
                    parser_version INTEGER NOT NULL CHECK (parser_version > 0),
                    last_validated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, organization_id, request_key),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE UNIQUE INDEX role_search_page_replays_scope
                ON role_search_page_replays (
                    account_id, organization_id, credential_revision, capability_revision,
                    query_value, page
                )
                """)
            try database.execute(sql: """
                CREATE INDEX role_search_page_replays_snapshot
                ON role_search_page_replays (raw_snapshot_id)
                """)
        },
        TriageDatabaseMigration(
            id: "026-organization-refresh-schedules",
            checksum: "b3fef9ead04a411d230992182a61efae48f7c5b6b7d4575cc87ab51d1803d5f4"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE organization_scheduler_states (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    next_incremental_refresh_at_ms INTEGER NOT NULL,
                    next_full_reconciliation_at_ms INTEGER NOT NULL,
                    rate_limited_until_ms INTEGER,
                    blocked_reason TEXT CHECK (
                        blocked_reason IS NULL OR blocked_reason IN (
                            'authenticationRequired', 'ssoRequired', 'approvalRequired'
                        )
                    ),
                    consecutive_transient_failure_count INTEGER NOT NULL
                        CHECK (consecutive_transient_failure_count BETWEEN 0 AND 20),
                    active_attempt_id TEXT,
                    last_attempt_at_ms INTEGER,
                    last_completed_at_ms INTEGER,
                    generation INTEGER NOT NULL CHECK (generation >= 0),
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, organization_id),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE,
                    CHECK (
                        active_attempt_id IS NULL OR last_attempt_at_ms IS NOT NULL
                    ),
                    CHECK (
                        last_attempt_at_ms IS NULL OR last_completed_at_ms IS NULL
                        OR (
                            active_attempt_id IS NULL
                            AND last_completed_at_ms >= last_attempt_at_ms
                        ) OR (
                            active_attempt_id IS NOT NULL
                            AND last_completed_at_ms <= last_attempt_at_ms
                        )
                    ),
                    CHECK (
                        last_attempt_at_ms IS NULL OR updated_at_ms >= last_attempt_at_ms
                    ),
                    CHECK (
                        last_completed_at_ms IS NULL OR updated_at_ms >= last_completed_at_ms
                    )
                )
                """)
            try database.execute(sql: """
                CREATE INDEX organization_scheduler_states_due
                ON organization_scheduler_states (
                    account_id, blocked_reason, next_incremental_refresh_at_ms, organization_id
                )
                """)
            try database.execute(sql: """
                CREATE INDEX organization_scheduler_states_reconciliation_due
                ON organization_scheduler_states (
                    account_id, blocked_reason, next_full_reconciliation_at_ms, organization_id
                )
                """)
        },
        TriageDatabaseMigration(
            id: "027-organization-scheduler-cancelled-attempts",
            checksum: "a989337fe48737cb48e606df087eb83b5add6bbde807a530bbea3d94ddd4147c"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE organization_scheduler_states_rebuilt (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    next_incremental_refresh_at_ms INTEGER NOT NULL,
                    next_full_reconciliation_at_ms INTEGER NOT NULL,
                    rate_limited_until_ms INTEGER,
                    blocked_reason TEXT CHECK (
                        blocked_reason IS NULL OR blocked_reason IN (
                            'authenticationRequired', 'ssoRequired', 'approvalRequired'
                        )
                    ),
                    consecutive_transient_failure_count INTEGER NOT NULL
                        CHECK (consecutive_transient_failure_count BETWEEN 0 AND 20),
                    active_attempt_id TEXT,
                    last_attempt_at_ms INTEGER,
                    last_completed_at_ms INTEGER,
                    generation INTEGER NOT NULL CHECK (generation >= 0),
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, organization_id),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE,
                    CHECK (
                        active_attempt_id IS NULL OR last_attempt_at_ms IS NOT NULL
                    ),
                    CHECK (
                        active_attempt_id IS NULL OR last_attempt_at_ms IS NULL
                        OR last_completed_at_ms IS NULL
                        OR last_completed_at_ms <= last_attempt_at_ms
                    ),
                    CHECK (
                        last_attempt_at_ms IS NULL OR updated_at_ms >= last_attempt_at_ms
                    ),
                    CHECK (
                        last_completed_at_ms IS NULL OR updated_at_ms >= last_completed_at_ms
                    )
                )
                """)
            try database.execute(sql: """
                INSERT INTO organization_scheduler_states_rebuilt (
                    account_id, organization_id, credential_revision,
                    capability_revision, next_incremental_refresh_at_ms,
                    next_full_reconciliation_at_ms, rate_limited_until_ms,
                    blocked_reason, consecutive_transient_failure_count,
                    active_attempt_id, last_attempt_at_ms, last_completed_at_ms,
                    generation, updated_at_ms
                )
                SELECT account_id, organization_id, credential_revision,
                       capability_revision, next_incremental_refresh_at_ms,
                       next_full_reconciliation_at_ms, rate_limited_until_ms,
                       blocked_reason, consecutive_transient_failure_count,
                       active_attempt_id, last_attempt_at_ms, last_completed_at_ms,
                       generation, updated_at_ms
                FROM organization_scheduler_states
                """)
            try database.execute(sql: "DROP TABLE organization_scheduler_states")
            try database.execute(sql: """
                ALTER TABLE organization_scheduler_states_rebuilt
                RENAME TO organization_scheduler_states
                """)
            try database.execute(sql: """
                CREATE INDEX organization_scheduler_states_due
                ON organization_scheduler_states (
                    account_id, blocked_reason, next_incremental_refresh_at_ms, organization_id
                )
                """)
            try database.execute(sql: """
                CREATE INDEX organization_scheduler_states_reconciliation_due
                ON organization_scheduler_states (
                    account_id, blocked_reason, next_full_reconciliation_at_ms, organization_id
                )
                """)
        },
        TriageDatabaseMigration(
            id: "028-account-organization-durable-state",
            checksum: "594034d7445efa2e5c4893fc2daff3687810fb9b5c04579a165627dd4c95b2b6"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE account_organization_durable_states (
                    account_id TEXT NOT NULL,
                    organization_id TEXT NOT NULL,
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    scheduler_generation INTEGER NOT NULL
                        CHECK (scheduler_generation >= 0),
                    format_version INTEGER NOT NULL CHECK (format_version = 1),
                    state_payload BLOB NOT NULL
                        CHECK (length(state_payload) <= 4194304),
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, organization_id),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE
                )
                """)
        },
        TriageDatabaseMigration(
            id: "029-repository-discussion-capability-provenance",
            checksum: "c994cb4855836e571bc45a4baeedf4b154959027e67c397ed1ff7b0875288544"
        ) { database in
            try database.execute(sql: """
                ALTER TABLE repositories
                ADD COLUMN has_discussions_known INTEGER NOT NULL DEFAULT 0
                    CHECK (has_discussions_known IN (0, 1))
                """)
        },
        TriageDatabaseMigration(
            id: "030-revision-scoped-conditional-requests",
            checksum: "f742e3ff68ae96471ddeacf0f191fa032cd4c343f353b17f313f005810fe7f02"
        ) { database in
            // Legacy rows did not identify organization, source stream, or
            // credential/capability authority. They cannot safely authorize a
            // 304 after migration, so invalidate them instead of guessing.
            try database.execute(sql: "DROP TABLE conditional_request_cache")
            try database.execute(sql: """
                CREATE TABLE conditional_request_cache (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    feature TEXT NOT NULL,
                    stream_id TEXT NOT NULL REFERENCES sync_streams(id) ON DELETE CASCADE,
                    request_key TEXT NOT NULL CHECK (
                        length(request_key) BETWEEN 1 AND 2048
                    ),
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    etag TEXT CHECK (
                        etag IS NULL OR length(etag) BETWEEN 1 AND 2048
                    ),
                    last_modified TEXT CHECK (
                        last_modified IS NULL OR length(last_modified) BETWEEN 1 AND 2048
                    ),
                    observed_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (
                        account_id, organization_id, feature, stream_id, request_key,
                        credential_revision, capability_revision
                    ),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE,
                    CHECK (etag IS NOT NULL OR last_modified IS NOT NULL)
                )
                """)
        },
        TriageDatabaseMigration(
            id: "031-raw-request-authority",
            checksum: "5d7c3aa43bbc9a8a962b2bf34625b8e86fc59da3157656e5d1897182b72f5db3"
        ) { database in
            // Existing raw rows remain encrypted parser/failure evidence, but
            // their missing authority columns deliberately prevent them from
            // authorizing a conditional replay.
            try database.execute(sql: "ALTER TABLE raw_api_snapshots ADD COLUMN last_modified TEXT")
            try database.execute(sql: "ALTER TABLE raw_api_snapshots ADD COLUMN authority_organization_id TEXT")
            try database.execute(sql: "ALTER TABLE raw_api_snapshots ADD COLUMN authority_feature TEXT")
            try database.execute(sql: "ALTER TABLE raw_api_snapshots ADD COLUMN authority_stream_id TEXT")
            try database.execute(sql: "ALTER TABLE raw_api_snapshots ADD COLUMN authority_request_key TEXT")
            try database.execute(sql: "ALTER TABLE raw_api_snapshots ADD COLUMN authority_credential_revision TEXT")
            try database.execute(sql: "ALTER TABLE raw_api_snapshots ADD COLUMN authority_capability_revision TEXT")
            try database.execute(sql: """
                CREATE INDEX raw_api_snapshots_request_authority
                ON raw_api_snapshots (
                    account_id, authority_organization_id, authority_feature,
                    authority_stream_id, authority_request_key,
                    authority_credential_revision, authority_capability_revision,
                    parser_version, observed_at_ms DESC, id DESC
                )
                """)
        },
        TriageDatabaseMigration(
            id: "032-timeline-replay-receipts",
            checksum: "7df5b7b72474a35f4ec6fe1e3c850661553c3ecd8ab05a502347d2013b89db88"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE timeline_replay_receipts (
                    id TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    github_node_id TEXT NOT NULL
                        REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    feature TEXT NOT NULL CHECK (feature = 'timelines'),
                    stream_id TEXT NOT NULL REFERENCES sync_streams(id) ON DELETE CASCADE,
                    request_key TEXT NOT NULL CHECK (
                        length(request_key) BETWEEN 1 AND 2048
                    ),
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    normalized_source_revision TEXT NOT NULL CHECK (
                        length(normalized_source_revision) BETWEEN 1 AND 500
                    ),
                    raw_source_revision TEXT NOT NULL CHECK (
                        length(raw_source_revision) BETWEEN 1 AND 500
                    ),
                    etag TEXT CHECK (
                        etag IS NULL OR length(etag) BETWEEN 1 AND 2048
                    ),
                    last_modified TEXT CHECK (
                        last_modified IS NULL OR length(last_modified) BETWEEN 1 AND 2048
                    ),
                    validator_observed_at_ms INTEGER NOT NULL,
                    first_raw_snapshot_id TEXT NOT NULL
                        REFERENCES raw_api_snapshots(id) ON DELETE CASCADE,
                    parser_version INTEGER NOT NULL CHECK (parser_version > 0),
                    page_count INTEGER NOT NULL CHECK (page_count BETWEEN 1 AND 100),
                    normalized_event_count INTEGER NOT NULL CHECK (normalized_event_count >= 0),
                    normalized_digest BLOB NOT NULL CHECK (length(normalized_digest) = 32),
                    completed_at_ms INTEGER NOT NULL,
                    UNIQUE (
                        account_id, organization_id, github_node_id, feature, stream_id,
                        request_key, credential_revision, capability_revision
                    ),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE,
                    CHECK (etag IS NOT NULL OR last_modified IS NOT NULL)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE timeline_replay_receipt_pages (
                    receipt_id TEXT NOT NULL
                        REFERENCES timeline_replay_receipts(id) ON DELETE CASCADE,
                    page_index INTEGER NOT NULL CHECK (page_index BETWEEN 1 AND 100),
                    raw_snapshot_id TEXT NOT NULL
                        REFERENCES raw_api_snapshots(id) ON DELETE CASCADE,
                    PRIMARY KEY (receipt_id, page_index),
                    UNIQUE (receipt_id, raw_snapshot_id)
                )
                """)
            try database.execute(sql: """
                CREATE INDEX timeline_replay_receipt_pages_snapshot
                ON timeline_replay_receipt_pages (raw_snapshot_id)
                """)
        },
        TriageDatabaseMigration(
            id: "033-role-search-page-replay-v2",
            checksum: "3567bf0a5bf1e6fd2edb7b0ed017db386b9ed39b29a2533540b81de5197a2f12",
            requiresVerifiedBackup: true
        ) { database in
            // Migration 025 bindings did not identify their role stream or
            // retain full raw request authority. They are conditional cache
            // metadata, not source observations, and must not authorize 304s.
            // Raw snapshots remain encrypted evidence under their own policy.
            try database.execute(sql: "DROP TABLE role_search_page_replays")
            try database.execute(sql: """
                CREATE TABLE role_search_page_replays (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    feature TEXT NOT NULL CHECK (feature = 'roleDiscovery'),
                    stream_id TEXT NOT NULL REFERENCES sync_streams(id) ON DELETE CASCADE,
                    request_key TEXT NOT NULL CHECK (
                        length(request_key) BETWEEN 1 AND 2048
                    ),
                    query_value TEXT NOT NULL CHECK (
                        length(query_value) BETWEEN 1 AND 2048
                    ),
                    page INTEGER NOT NULL CHECK (page BETWEEN 1 AND 100),
                    endpoint TEXT NOT NULL CHECK (
                        length(endpoint) BETWEEN 1 AND 2048
                    ),
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    raw_snapshot_id TEXT NOT NULL
                        REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT,
                    etag TEXT CHECK (
                        etag IS NULL OR length(etag) BETWEEN 1 AND 2048
                    ),
                    last_modified TEXT CHECK (
                        last_modified IS NULL OR length(last_modified) BETWEEN 1 AND 2048
                    ),
                    parser_version INTEGER NOT NULL CHECK (parser_version > 0),
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
                        ON DELETE CASCADE,
                    CHECK (etag IS NOT NULL OR last_modified IS NOT NULL)
                )
                """)
            try database.execute(sql: """
                CREATE INDEX role_search_page_replays_snapshot
                ON role_search_page_replays (raw_snapshot_id)
                """)
        },
        TriageDatabaseMigration(
            id: "034-role-search-page-replay-parser-identity",
            checksum: "2cd58affc40f404812fdc6a4a32ee8ec50116fd0e813a8af3eddfee9b99a6170",
            requiresVerifiedBackup: true
        ) { database in
            try database.execute(sql: "DROP INDEX role_search_page_replays_snapshot")
            try database.execute(sql: "ALTER TABLE role_search_page_replays RENAME TO role_search_page_replays_v2")
            try database.execute(sql: """
                CREATE TABLE role_search_page_replays (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    feature TEXT NOT NULL CHECK (feature = 'roleDiscovery'),
                    stream_id TEXT NOT NULL REFERENCES sync_streams(id) ON DELETE CASCADE,
                    request_key TEXT NOT NULL CHECK (
                        length(request_key) BETWEEN 1 AND 2048
                    ),
                    query_value TEXT NOT NULL CHECK (
                        length(query_value) BETWEEN 1 AND 2048
                    ),
                    page INTEGER NOT NULL CHECK (page BETWEEN 1 AND 100),
                    endpoint TEXT NOT NULL CHECK (
                        length(endpoint) BETWEEN 1 AND 2048
                    ),
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    raw_snapshot_id TEXT NOT NULL
                        REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT,
                    etag TEXT CHECK (
                        etag IS NULL OR length(etag) BETWEEN 1 AND 2048
                    ),
                    last_modified TEXT CHECK (
                        last_modified IS NULL OR length(last_modified) BETWEEN 1 AND 2048
                    ),
                    parser_version INTEGER NOT NULL CHECK (parser_version > 0),
                    last_validated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (
                        account_id, organization_id, feature, stream_id, request_key,
                        credential_revision, capability_revision
                    ),
                    UNIQUE (
                        account_id, organization_id, feature, stream_id, endpoint,
                        parser_version, credential_revision, capability_revision
                    ),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE,
                    CHECK (etag IS NOT NULL OR last_modified IS NOT NULL)
                )
                """)
            try database.execute(sql: """
                INSERT INTO role_search_page_replays (
                    account_id, organization_id, feature, stream_id, request_key,
                    query_value, page, endpoint, credential_revision, capability_revision,
                    raw_snapshot_id, etag, last_modified, parser_version, last_validated_at_ms
                )
                SELECT account_id, organization_id, feature, stream_id, request_key,
                       query_value, page, endpoint, credential_revision, capability_revision,
                       raw_snapshot_id, etag, last_modified, parser_version, last_validated_at_ms
                FROM role_search_page_replays_v2
                """)
            try database.execute(sql: "DROP TABLE role_search_page_replays_v2")
            try database.execute(sql: """
                CREATE INDEX role_search_page_replays_snapshot
                ON role_search_page_replays (raw_snapshot_id)
                """)
        },
        TriageDatabaseMigration(
            id: "035-source-access-observations",
            checksum: "0e3720d9d2f00f2d1cc517da11b4402d9c447bc641b7e3b9fc907fce73c09b6e"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE source_access_observations (
                    id TEXT PRIMARY KEY NOT NULL CHECK (length(id) BETWEEN 1 AND 128),
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE
                        CHECK (length(account_id) BETWEEN 1 AND 512),
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE
                        CHECK (length(organization_id) BETWEEN 1 AND 512),
                    credential_revision TEXT NOT NULL
                        CHECK (length(credential_revision) BETWEEN 1 AND 512),
                    capability_revision TEXT NOT NULL
                        CHECK (length(capability_revision) BETWEEN 1 AND 512),
                    feature TEXT NOT NULL CHECK (length(feature) BETWEEN 1 AND 128),
                    stream_id TEXT NOT NULL CHECK (length(stream_id) BETWEEN 1 AND 512),
                    target_kind TEXT NOT NULL CHECK (
                        target_kind IN ('repository', 'githubNode', 'team')
                    ),
                    target_id TEXT NOT NULL CHECK (length(target_id) BETWEEN 1 AND 512),
                    source_locator_kind TEXT NOT NULL CHECK (
                        source_locator_kind IN ('endpoint', 'query')
                    ),
                    source_locator TEXT NOT NULL
                        CHECK (length(source_locator) BETWEEN 1 AND 2048),
                    source_node_id TEXT CHECK (
                        source_node_id IS NULL OR length(source_node_id) BETWEEN 1 AND 512
                    ),
                    source_event_id TEXT CHECK (
                        source_event_id IS NULL OR length(source_event_id) BETWEEN 1 AND 512
                    ),
                    source_revision TEXT NOT NULL
                        CHECK (length(source_revision) BETWEEN 1 AND 500),
                    raw_snapshot_id TEXT REFERENCES raw_api_snapshots(id)
                        ON DELETE SET NULL CHECK (
                            raw_snapshot_id IS NULL
                                OR length(raw_snapshot_id) BETWEEN 1 AND 512
                        ),
                    result TEXT NOT NULL CHECK (
                        result IN (
                            'accessible', 'inaccessible', 'unknown', 'authoritativelyDeleted'
                        )
                    ),
                    reason TEXT NOT NULL CHECK (
                        reason IN (
                            'directResponse', 'privateNotFound', 'forbidden', 'ssoRequired',
                            'approvalRequired', 'inventoryOmission', 'authoritativeOmission',
                            'immutableIdentityReplacement'
                        )
                    ),
                    authority TEXT NOT NULL CHECK (
                        authority IN ('incremental', 'directProbe', 'fullReconciliation')
                    ),
                    confirmation TEXT NOT NULL CHECK (
                        confirmation IN ('provisional', 'confirmed')
                    ),
                    observed_at_ms INTEGER NOT NULL,
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE,
                    CHECK (
                        (result = 'accessible' AND reason = 'directResponse')
                        OR (
                            result = 'inaccessible'
                            AND reason IN (
                                'privateNotFound', 'forbidden', 'ssoRequired', 'approvalRequired'
                            )
                        )
                        OR (
                            result = 'unknown'
                            AND reason = 'inventoryOmission'
                            AND confirmation = 'provisional'
                        )
                        OR (
                            result = 'authoritativelyDeleted'
                            AND reason IN (
                                'authoritativeOmission', 'immutableIdentityReplacement'
                            )
                            AND authority = 'fullReconciliation'
                            AND confirmation = 'confirmed'
                        )
                    )
                )
                """)
            try database.execute(sql: """
                CREATE INDEX source_access_observations_history
                ON source_access_observations (
                    account_id, organization_id, feature, stream_id,
                    target_kind, target_id, credential_revision, capability_revision,
                    observed_at_ms DESC, id DESC
                )
                """)
            try database.execute(sql: """
                CREATE INDEX source_access_observations_authority
                ON source_access_observations (
                    account_id, organization_id, feature, stream_id,
                    credential_revision, capability_revision, observed_at_ms, id
                )
                """)
            try database.execute(sql: """
                CREATE INDEX source_access_observations_raw_snapshot
                ON source_access_observations (raw_snapshot_id)
                """)
            try database.execute(sql: """
                CREATE TRIGGER source_access_protect_deletion_receipt
                BEFORE DELETE ON raw_api_snapshots
                WHEN EXISTS (
                    SELECT 1 FROM source_access_observations
                    WHERE raw_snapshot_id = OLD.id
                      AND result = 'authoritativelyDeleted'
                )
                AND EXISTS (
                    SELECT 1 FROM accounts WHERE id = OLD.account_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'authoritative deletion receipt is durable');
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER source_access_protect_deletion_receipt_update
                BEFORE UPDATE ON raw_api_snapshots
                WHEN EXISTS (
                    SELECT 1 FROM source_access_observations
                    WHERE raw_snapshot_id = OLD.id
                      AND result = 'authoritativelyDeleted'
                )
                AND EXISTS (
                    SELECT 1 FROM accounts WHERE id = OLD.account_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'authoritative deletion receipt is immutable');
                END
                """)
            try database.execute(sql: """
                CREATE TABLE source_access_projections (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE
                        CHECK (length(account_id) BETWEEN 1 AND 512),
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE
                        CHECK (length(organization_id) BETWEEN 1 AND 512),
                    credential_revision TEXT NOT NULL
                        CHECK (length(credential_revision) BETWEEN 1 AND 512),
                    capability_revision TEXT NOT NULL
                        CHECK (length(capability_revision) BETWEEN 1 AND 512),
                    feature TEXT NOT NULL CHECK (length(feature) BETWEEN 1 AND 128),
                    stream_id TEXT NOT NULL CHECK (length(stream_id) BETWEEN 1 AND 512),
                    target_kind TEXT NOT NULL CHECK (
                        target_kind IN ('repository', 'githubNode', 'team')
                    ),
                    target_id TEXT NOT NULL CHECK (length(target_id) BETWEEN 1 AND 512),
                    result TEXT NOT NULL CHECK (
                        result IN (
                            'accessible', 'inaccessible', 'unknown', 'authoritativelyDeleted'
                        )
                    ),
                    winning_observation_id TEXT NOT NULL UNIQUE
                        REFERENCES source_access_observations(id) ON DELETE CASCADE,
                    observed_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (
                        account_id, organization_id, feature, stream_id, target_kind, target_id
                    ),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE INDEX source_access_projections_current_revision
                ON source_access_projections (
                    account_id, organization_id, credential_revision,
                    capability_revision, feature, stream_id, target_kind, target_id
                )
                """)
        },
        TriageDatabaseMigration(
            id: "036-repository-inventory-replay-receipts",
            checksum: "a5aaff89b48f88fba57988ab8f6fde3d7bdfde58d1e9ada4d51c2c1179c19a52"
        ) { database in
            try database.execute(sql: """
                CREATE UNIQUE INDEX sync_streams_exact_scope
                ON sync_streams (account_id, organization_id, feature, id)
                """)
            try database.execute(sql: """
                CREATE TABLE repository_inventory_replay_receipts (
                    id TEXT PRIMARY KEY NOT NULL
                        CHECK (length(id) BETWEEN 1 AND 128),
                    account_id TEXT NOT NULL
                        CHECK (length(account_id) BETWEEN 1 AND 512),
                    organization_id TEXT NOT NULL
                        CHECK (length(organization_id) BETWEEN 1 AND 512),
                    feature TEXT NOT NULL CHECK (feature = 'repositories'),
                    stream_id TEXT NOT NULL
                        CHECK (length(stream_id) BETWEEN 1 AND 512),
                    request_key TEXT NOT NULL
                        CHECK (length(request_key) BETWEEN 1 AND 2048),
                    credential_revision TEXT NOT NULL
                        CHECK (length(credential_revision) BETWEEN 1 AND 512),
                    capability_revision TEXT NOT NULL
                        CHECK (length(capability_revision) BETWEEN 1 AND 512),
                    raw_source_revision TEXT NOT NULL
                        CHECK (length(raw_source_revision) BETWEEN 1 AND 500),
                    etag TEXT CHECK (
                        etag IS NULL OR length(etag) BETWEEN 1 AND 2048
                    ),
                    last_modified TEXT CHECK (
                        last_modified IS NULL OR length(last_modified) BETWEEN 1 AND 2048
                    ),
                    raw_observed_at_ms INTEGER NOT NULL,
                    normalized_committed_at_ms INTEGER NOT NULL,
                    last_validated_at_ms INTEGER NOT NULL,
                    parser_version INTEGER NOT NULL CHECK (parser_version > 0),
                    page_count INTEGER NOT NULL CHECK (page_count BETWEEN 1 AND 100),
                    normalized_repository_count INTEGER NOT NULL CHECK (
                        normalized_repository_count BETWEEN 0 AND 10000
                    ),
                    normalized_digest BLOB NOT NULL CHECK (length(normalized_digest) = 32),
                    UNIQUE (
                        account_id, organization_id, feature, stream_id, request_key
                    ),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE,
                    FOREIGN KEY (account_id, organization_id, feature, stream_id)
                        REFERENCES sync_streams(account_id, organization_id, feature, id)
                        ON DELETE CASCADE,
                    CHECK (etag IS NOT NULL OR last_modified IS NOT NULL),
                    CHECK (normalized_committed_at_ms >= raw_observed_at_ms),
                    CHECK (last_validated_at_ms >= normalized_committed_at_ms)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE repository_inventory_replay_receipt_pages (
                    receipt_id TEXT NOT NULL
                        REFERENCES repository_inventory_replay_receipts(id) ON DELETE CASCADE
                        CHECK (length(receipt_id) BETWEEN 1 AND 128),
                    page_index INTEGER NOT NULL CHECK (page_index BETWEEN 1 AND 100),
                    endpoint TEXT NOT NULL CHECK (length(endpoint) BETWEEN 1 AND 2048),
                    request_key TEXT NOT NULL CHECK (
                        length(request_key) BETWEEN 1 AND 2048
                        AND request_key = 'GET ' || endpoint
                    ),
                    link_header TEXT CHECK (
                        link_header IS NULL OR length(link_header) BETWEEN 1 AND 8192
                    ),
                    next_endpoint TEXT CHECK (
                        next_endpoint IS NULL OR length(next_endpoint) BETWEEN 1 AND 2048
                    ),
                    raw_snapshot_id TEXT NOT NULL
                        REFERENCES raw_api_snapshots(id) ON DELETE CASCADE
                        CHECK (length(raw_snapshot_id) BETWEEN 1 AND 512),
                    object_count INTEGER NOT NULL CHECK (object_count BETWEEN 0 AND 100),
                    raw_payload_digest BLOB NOT NULL CHECK (length(raw_payload_digest) = 32),
                    repository_id_digest BLOB NOT NULL CHECK (length(repository_id_digest) = 32),
                    PRIMARY KEY (receipt_id, page_index),
                    UNIQUE (receipt_id, endpoint),
                    UNIQUE (receipt_id, request_key),
                    UNIQUE (receipt_id, raw_snapshot_id),
                    CHECK (next_endpoint IS NULL OR link_header IS NOT NULL)
                )
                """)
            try database.execute(sql: """
                CREATE INDEX repository_inventory_replay_receipts_current_scope
                ON repository_inventory_replay_receipts (
                    account_id, organization_id, feature, stream_id,
                    credential_revision, capability_revision, last_validated_at_ms
                )
                """)
            try database.execute(sql: """
                CREATE INDEX repository_inventory_replay_receipt_pages_snapshot
                ON repository_inventory_replay_receipt_pages (raw_snapshot_id)
                """)
            try database.execute(sql: """
                CREATE TRIGGER repository_inventory_protect_replay_snapshot_delete
                BEFORE DELETE ON raw_api_snapshots
                WHEN EXISTS (
                    SELECT 1 FROM repository_inventory_replay_receipt_pages
                    WHERE raw_snapshot_id = OLD.id
                )
                AND EXISTS (
                    SELECT 1 FROM accounts WHERE id = OLD.account_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'repository inventory replay receipt is durable');
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER repository_inventory_protect_replay_snapshot_update
                BEFORE UPDATE ON raw_api_snapshots
                WHEN EXISTS (
                    SELECT 1 FROM repository_inventory_replay_receipt_pages
                    WHERE raw_snapshot_id = OLD.id
                )
                AND EXISTS (
                    SELECT 1 FROM accounts WHERE id = OLD.account_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'repository inventory replay receipt is immutable');
                END
                """)
        },
        TriageDatabaseMigration(
            id: "037-repository-inventory-replay-snapshot-idempotency",
            checksum: "49c98f3a558dda06ff7205416691c1cb02cc002c0752f8c4ed36a2d58a5db4fb"
        ) { database in
            // Migration 036 rejected every UPDATE, including byte-identical
            // UPSERT replays. Receipt evidence must remain immutable while its
            // account exists, but exact replay persistence is intentionally
            // idempotent.
            try database.execute(
                sql: "DROP TRIGGER repository_inventory_protect_replay_snapshot_update"
            )
            try database.execute(sql: """
                CREATE TRIGGER repository_inventory_protect_replay_snapshot_update
                BEFORE UPDATE ON raw_api_snapshots
                WHEN EXISTS (
                    SELECT 1 FROM repository_inventory_replay_receipt_pages
                    WHERE raw_snapshot_id = OLD.id
                )
                AND EXISTS (
                    SELECT 1 FROM accounts WHERE id = OLD.account_id
                )
                AND (
                    OLD.id IS NOT NEW.id
                    OR OLD.account_id IS NOT NEW.account_id
                    OR OLD.github_node_id IS NOT NEW.github_node_id
                    OR OLD.endpoint IS NOT NEW.endpoint
                    OR OLD.etag IS NOT NEW.etag
                    OR OLD.last_modified IS NOT NEW.last_modified
                    OR OLD.authority_organization_id IS NOT NEW.authority_organization_id
                    OR OLD.authority_feature IS NOT NEW.authority_feature
                    OR OLD.authority_stream_id IS NOT NEW.authority_stream_id
                    OR OLD.authority_request_key IS NOT NEW.authority_request_key
                    OR OLD.authority_credential_revision IS NOT NEW.authority_credential_revision
                    OR OLD.authority_capability_revision IS NOT NEW.authority_capability_revision
                    OR OLD.parser_version IS NOT NEW.parser_version
                    OR OLD.observed_at_ms IS NOT NEW.observed_at_ms
                    OR OLD.payload IS NOT NEW.payload
                )
                BEGIN
                    SELECT RAISE(ABORT, 'repository inventory replay receipt is immutable');
                END
                """)
        },
        TriageDatabaseMigration(
            id: "038-relation-evidence-authority-provisional",
            checksum: "c5904a2808b9f2133c456a65b5a512af8eb14be282dfdd19c5ce3f02c5b33a76"
        ) { database in
            // Migration 009 evidence had no source scope, locator, revision
            // authority, raw binding, or reconciliation confirmation. Preserve
            // it for explainability, but make it explicitly legacy and
            // provisional rather than inventing GitHub authority.
            // Synthetic legacy fixtures may intentionally begin after the
            // work-graph migration without materializing its empty child
            // table. Create that exact empty 009 shape before rebuilding.
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS relation_evidence (
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
            try database.execute(sql: "ALTER TABLE relation_evidence RENAME TO relation_evidence_009")
            try database.execute(sql: """
                CREATE TABLE relation_evidence (
                    relation_id TEXT NOT NULL REFERENCES relations(id) ON DELETE CASCADE,
                    evidence_id TEXT NOT NULL CHECK (length(evidence_id) BETWEEN 1 AND 512),
                    source TEXT NOT NULL CHECK (
                        source IN (
                            'restSearch', 'restTimeline', 'restReview', 'restNotification',
                            'graphQL', 'localWorkflow', 'copilot', 'legacyUnverified'
                        )
                    ),
                    source_locator_kind TEXT NOT NULL CHECK (
                        source_locator_kind IN ('endpoint', 'query', 'localWorkflow', 'legacyUnverified')
                    ),
                    source_locator TEXT NOT NULL CHECK (length(source_locator) BETWEEN 1 AND 2048),
                    authority_kind TEXT NOT NULL CHECK (
                        authority_kind IN ('github', 'localWorkflow', 'legacyUnverified')
                    ),
                    authority_account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
                    authority_organization_id TEXT REFERENCES organizations(id) ON DELETE CASCADE,
                    authority_feature TEXT,
                    authority_stream_id TEXT REFERENCES sync_streams(id) ON DELETE CASCADE,
                    authority_credential_revision TEXT,
                    authority_capability_revision TEXT,
                    source_node_id TEXT,
                    source_event_id TEXT,
                    source_revision TEXT,
                    raw_snapshot_id TEXT REFERENCES raw_api_snapshots(id) ON DELETE SET NULL,
                    confidence TEXT NOT NULL CHECK (confidence IN ('provisional', 'confirmed')),
                    confirmation TEXT NOT NULL CHECK (confirmation IN ('provisional', 'confirmed')),
                    observed_at_ms INTEGER NOT NULL,
                    excerpt TEXT,
                    PRIMARY KEY (relation_id, evidence_id),
                    CHECK (
                        (
                            authority_kind = 'github'
                            AND authority_account_id IS NOT NULL
                            AND authority_organization_id IS NOT NULL
                            AND authority_feature IS NOT NULL
                            AND authority_stream_id IS NOT NULL
                            AND authority_credential_revision IS NOT NULL
                            AND authority_capability_revision IS NOT NULL
                            AND source_locator_kind IN ('endpoint', 'query')
                            AND source != 'localWorkflow'
                            AND source != 'legacyUnverified'
                        )
                        OR (
                            authority_kind = 'localWorkflow'
                            AND source = 'localWorkflow'
                            AND authority_account_id IS NOT NULL
                            AND authority_organization_id IS NOT NULL
                            AND authority_feature IS NULL
                            AND authority_stream_id IS NULL
                            AND authority_credential_revision IS NULL
                            AND authority_capability_revision IS NULL
                            AND source_locator_kind = 'localWorkflow'
                        )
                        OR (
                            authority_kind = 'legacyUnverified'
                            AND authority_account_id IS NOT NULL
                            AND authority_organization_id IS NOT NULL
                            AND authority_feature IS NULL
                            AND authority_stream_id IS NULL
                            AND authority_credential_revision IS NULL
                            AND authority_capability_revision IS NULL
                            AND source_locator_kind = 'legacyUnverified'
                            AND source != 'localWorkflow'
                            AND confirmation = 'provisional'
                        )
                    )
                )
                """)
            let hasWorkGraph = try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'relations')"
            ) ?? false
            if hasWorkGraph {
                try database.execute(sql: """
                    INSERT INTO relation_evidence (
                    relation_id, evidence_id, source, source_locator_kind, source_locator,
                    authority_kind, authority_account_id, authority_organization_id,
                    authority_feature, authority_stream_id, authority_credential_revision,
                    authority_capability_revision, source_node_id, source_event_id,
                    source_revision, raw_snapshot_id, confidence, confirmation,
                    observed_at_ms, excerpt
                )
                SELECT
                    relation_evidence_009.relation_id,
                    relation_evidence_009.evidence_id,
                    CASE relation_evidence_009.source
                        WHEN 'localWorkflow' THEN 'legacyUnverified'
                        ELSE relation_evidence_009.source
                    END,
                    'legacyUnverified',
                    'legacy-unverified',
                    'legacyUnverified',
                    relations.account_id,
                    github_nodes.organization_id,
                    NULL, NULL, NULL, NULL,
                    relation_evidence_009.source_node_id,
                    relation_evidence_009.source_event_id,
                    relation_evidence_009.source_revision,
                    NULL,
                    'provisional',
                    'provisional',
                    relation_evidence_009.observed_at_ms,
                    relation_evidence_009.excerpt
                FROM relation_evidence_009
                JOIN relations ON relations.id = relation_evidence_009.relation_id
                JOIN github_nodes ON github_nodes.github_node_id = relations.subject_node_id
                """)
                // A relation without legacy evidence must not silently look
                // supported. Retain it as one explicit unverified migration row.
                try database.execute(sql: """
                INSERT INTO relation_evidence (
                    relation_id, evidence_id, source, source_locator_kind, source_locator,
                    authority_kind, authority_account_id, authority_organization_id,
                    authority_feature, authority_stream_id, authority_credential_revision,
                    authority_capability_revision, source_node_id, source_event_id,
                    source_revision, raw_snapshot_id, confidence, confirmation,
                    observed_at_ms, excerpt
                )
                SELECT
                    relations.id, 'legacy-' || relations.id, 'legacyUnverified',
                    'legacyUnverified', 'legacy-unverified', 'legacyUnverified',
                    relations.account_id, github_nodes.organization_id,
                    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                    relations.confidence, 'provisional', relations.observed_at_ms, NULL
                FROM relations
                JOIN github_nodes ON github_nodes.github_node_id = relations.subject_node_id
                WHERE NOT EXISTS (
                    SELECT 1 FROM relation_evidence_009
                    WHERE relation_evidence_009.relation_id = relations.id
                )
                """)
                // All migration-009 relation strength was inseparable from
                // unscoped evidence. Do not let it continue to drive derived
                // intelligence as confirmed GitHub fact.
                try database.execute(sql: "UPDATE relations SET confidence = 'provisional'")
            }
            try database.execute(sql: "DROP TABLE relation_evidence_009")
            try database.execute(sql: """
                CREATE INDEX relation_evidence_exact_authority
                ON relation_evidence (
                    authority_account_id, authority_organization_id, authority_feature,
                    authority_stream_id, authority_credential_revision,
                    authority_capability_revision, source, source_locator_kind,
                    source_locator, source_revision, relation_id
                )
                """)
            try database.execute(sql: """
                CREATE INDEX relation_evidence_raw_snapshot
                ON relation_evidence (raw_snapshot_id)
                """)
        },
        TriageDatabaseMigration(
            id: "039-timeline-current-page-membership",
            checksum: "498de3f54c04aa6d9c271a9f18a235859ae1fdbbe1d806b566038ed6115f64b7"
        ) { database in
            // Raw pages are immutable historical evidence. This table is only
            // the exact page set selected for the current normalized timeline
            // traversal; legacy raw rows are intentionally not backfilled.
            try database.execute(sql: """
                CREATE TABLE timeline_current_pages (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    github_node_id TEXT NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    feature TEXT NOT NULL CHECK (feature = 'timelines'),
                    stream_id TEXT NOT NULL REFERENCES sync_streams(id) ON DELETE CASCADE,
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    source_revision TEXT NOT NULL CHECK (length(source_revision) BETWEEN 1 AND 500),
                    page_index INTEGER NOT NULL CHECK (page_index BETWEEN 1 AND 100),
                    raw_snapshot_id TEXT NOT NULL REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT,
                    request_key TEXT NOT NULL CHECK (length(request_key) BETWEEN 1 AND 2048),
                    observed_at_ms INTEGER NOT NULL,
                    is_terminal INTEGER NOT NULL CHECK (is_terminal IN (0, 1)),
                    PRIMARY KEY (
                        account_id, organization_id, github_node_id, feature, stream_id,
                        credential_revision, capability_revision, source_revision, page_index
                    ),
                    UNIQUE (
                        account_id, organization_id, github_node_id, feature, stream_id,
                        credential_revision, capability_revision, source_revision, raw_snapshot_id
                    ),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE INDEX timeline_current_pages_subject_scope
                ON timeline_current_pages (
                    account_id, organization_id, github_node_id, feature, stream_id,
                    credential_revision, capability_revision, source_revision, page_index
                )
                """)
            // Downloaded pages are deliberately separate from the published
            // membership. A cancelled traversal may retain immutable raw
            // evidence and a resumable checkpoint, but must never claim that
            // those pages describe the current normalized projection.
            try database.execute(sql: """
                CREATE TABLE timeline_staged_pages (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    github_node_id TEXT NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    feature TEXT NOT NULL CHECK (feature = 'timelines'),
                    stream_id TEXT NOT NULL REFERENCES sync_streams(id) ON DELETE CASCADE,
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    source_revision TEXT NOT NULL CHECK (length(source_revision) BETWEEN 1 AND 500),
                    page_index INTEGER NOT NULL CHECK (page_index BETWEEN 1 AND 100),
                    raw_snapshot_id TEXT NOT NULL REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT,
                    request_key TEXT NOT NULL CHECK (length(request_key) BETWEEN 1 AND 2048),
                    observed_at_ms INTEGER NOT NULL,
                    is_terminal INTEGER NOT NULL CHECK (is_terminal IN (0, 1)),
                    PRIMARY KEY (
                        account_id, organization_id, github_node_id, feature, stream_id,
                        credential_revision, capability_revision, source_revision, page_index
                    ),
                    UNIQUE (
                        account_id, organization_id, github_node_id, feature, stream_id,
                        credential_revision, capability_revision, source_revision, raw_snapshot_id
                    ),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE INDEX timeline_staged_pages_subject_scope
                ON timeline_staged_pages (
                    account_id, organization_id, github_node_id, feature, stream_id,
                    credential_revision, capability_revision, source_revision, page_index
                )
                """)
        },
        TriageDatabaseMigration(
            id: "040-review-candidate-failure-envelopes",
            checksum: "9241fecb2d6cffcfc87a91e553b8599f0913dc2e16b705fcd2b038cad30c5a81"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE review_candidate_failure_envelopes (
                    id TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    feature TEXT NOT NULL CHECK (feature IN ('reviews', 'reviewThreads')),
                    stream_id TEXT NOT NULL REFERENCES sync_streams(id) ON DELETE CASCADE,
                    candidate_node_id TEXT NOT NULL CHECK (length(candidate_node_id) BETWEEN 1 AND 512),
                    repository_id TEXT NOT NULL CHECK (length(repository_id) BETWEEN 1 AND 512),
                    request_key TEXT NOT NULL CHECK (length(request_key) BETWEEN 1 AND 2048),
                    credential_revision TEXT NOT NULL CHECK (length(credential_revision) BETWEEN 1 AND 512),
                    capability_revision TEXT NOT NULL CHECK (length(capability_revision) BETWEEN 1 AND 512),
                    parser_version INTEGER NOT NULL CHECK (parser_version > 0),
                    attempted_at_ms INTEGER NOT NULL,
                    terminal_at_ms INTEGER NOT NULL CHECK (terminal_at_ms >= attempted_at_ms),
                    classification TEXT NOT NULL CHECK (classification IN (
                        'authenticationRequired', 'ssoRequired', 'approvalRequired',
                        'rateLimited', 'unavailableOrPermission', 'transportFailure',
                        'serverFailure', 'malformedResponse', 'normalizationFailure'
                    )),
                    redacted_diagnostic TEXT NOT NULL CHECK (length(redacted_diagnostic) BETWEEN 1 AND 4096),
                    raw_page_count INTEGER NOT NULL CHECK (raw_page_count >= 0),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE TABLE review_candidate_failure_pages (
                    envelope_id TEXT NOT NULL
                        REFERENCES review_candidate_failure_envelopes(id) ON DELETE CASCADE,
                    request_key TEXT NOT NULL CHECK (length(request_key) BETWEEN 1 AND 2048),
                    page_ordinal INTEGER NOT NULL CHECK (page_ordinal > 0),
                    raw_snapshot_id TEXT NOT NULL
                        REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT,
                    PRIMARY KEY (envelope_id, request_key, page_ordinal),
                    UNIQUE (envelope_id, raw_snapshot_id)
                )
                """)
            try database.execute(sql: """
                CREATE INDEX review_candidate_failure_envelopes_scope_candidate_terminal
                ON review_candidate_failure_envelopes (
                    account_id, organization_id, feature, stream_id, candidate_node_id,
                    credential_revision, capability_revision, terminal_at_ms DESC, id DESC
                )
                """)
            try database.execute(sql: """
                CREATE INDEX review_candidate_failure_pages_raw_snapshot
                ON review_candidate_failure_pages (raw_snapshot_id)
                """)
        },
        TriageDatabaseMigration(
            id: "041-notification-source-authority-v1",
            checksum: "6e396d1e9e4142d866ad417b9845bcaa274bec64babb4b929ac3a42206153f7a"
        ) { database in
            // Account notifications remain discovery evidence. Their current
            // page membership and 304 receipt must never be confused with
            // local notification delivery or deletion authority.
            try database.execute(sql: """
                CREATE TABLE notification_threads (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE CHECK (length(account_id) BETWEEN 1 AND 512),
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE CHECK (length(organization_id) BETWEEN 1 AND 512),
                    notification_id TEXT NOT NULL CHECK (length(notification_id) BETWEEN 1 AND 512),
                    repository_node_id TEXT NOT NULL CHECK (length(repository_node_id) BETWEEN 1 AND 512),
                    reason TEXT NOT NULL CHECK (length(reason) BETWEEN 1 AND 100),
                    is_unread INTEGER NOT NULL CHECK (is_unread IN (0, 1)),
                    subject_type TEXT NOT NULL CHECK (length(subject_type) BETWEEN 1 AND 100),
                    subject_title TEXT NOT NULL CHECK (length(subject_title) BETWEEN 1 AND 8192),
                    subject_url TEXT CHECK (subject_url IS NULL OR length(subject_url) BETWEEN 1 AND 2048),
                    updated_at_ms INTEGER NOT NULL,
                    last_read_at_ms INTEGER,
                    source_revision TEXT NOT NULL CHECK (length(source_revision) = 64 AND source_revision NOT GLOB '*[^0-9a-f]*'),
                    raw_snapshot_id TEXT NOT NULL REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT CHECK (length(raw_snapshot_id) BETWEEN 1 AND 512),
                    credential_revision TEXT NOT NULL CHECK (length(credential_revision) BETWEEN 1 AND 512),
                    capability_revision TEXT NOT NULL CHECK (length(capability_revision) BETWEEN 1 AND 512),
                    observed_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, organization_id, notification_id),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id) ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE TABLE notification_current_pages (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE CHECK (length(account_id) BETWEEN 1 AND 512),
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE CHECK (length(organization_id) BETWEEN 1 AND 512),
                    feature TEXT NOT NULL CHECK (feature = 'notifications'),
                    stream_id TEXT NOT NULL CHECK (length(stream_id) BETWEEN 1 AND 512),
                    credential_revision TEXT NOT NULL CHECK (length(credential_revision) BETWEEN 1 AND 512),
                    capability_revision TEXT NOT NULL CHECK (length(capability_revision) BETWEEN 1 AND 512),
                    source_revision TEXT NOT NULL CHECK (length(source_revision) = 64 AND source_revision NOT GLOB '*[^0-9a-f]*'),
                    page_index INTEGER NOT NULL CHECK (page_index BETWEEN 1 AND 100),
                    raw_snapshot_id TEXT NOT NULL REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT CHECK (length(raw_snapshot_id) BETWEEN 1 AND 512),
                    request_key TEXT NOT NULL CHECK (length(request_key) BETWEEN 1 AND 2048 AND request_key LIKE 'GET /notifications?%'),
                    observed_at_ms INTEGER NOT NULL,
                    is_terminal INTEGER NOT NULL CHECK (is_terminal IN (0, 1)),
                    PRIMARY KEY (account_id, organization_id, feature, stream_id, credential_revision, capability_revision, source_revision, page_index),
                    UNIQUE (account_id, organization_id, feature, stream_id, credential_revision, capability_revision, source_revision, raw_snapshot_id),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id) ON DELETE CASCADE,
                    FOREIGN KEY (account_id, organization_id, feature, stream_id)
                        REFERENCES sync_streams(account_id, organization_id, feature, id) ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE TABLE notification_replay_receipts (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE CHECK (length(account_id) BETWEEN 1 AND 512),
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE CHECK (length(organization_id) BETWEEN 1 AND 512),
                    feature TEXT NOT NULL CHECK (feature = 'notifications'),
                    stream_id TEXT NOT NULL CHECK (length(stream_id) BETWEEN 1 AND 512),
                    request_key TEXT NOT NULL CHECK (request_key = 'GET /notifications?all=true&participating=false&per_page=100'),
                    credential_revision TEXT NOT NULL CHECK (length(credential_revision) BETWEEN 1 AND 512),
                    capability_revision TEXT NOT NULL CHECK (length(capability_revision) BETWEEN 1 AND 512),
                    etag TEXT CHECK (etag IS NULL OR length(etag) BETWEEN 1 AND 2048),
                    last_modified TEXT CHECK (last_modified IS NULL OR length(last_modified) BETWEEN 1 AND 2048),
                    parser_version INTEGER NOT NULL CHECK (parser_version > 0),
                    source_revision TEXT NOT NULL CHECK (length(source_revision) = 64 AND source_revision NOT GLOB '*[^0-9a-f]*'),
                    notification_count INTEGER NOT NULL CHECK (notification_count BETWEEN 0 AND 10000),
                    notification_digest TEXT NOT NULL CHECK (length(notification_digest) = 64 AND notification_digest NOT GLOB '*[^0-9a-f]*'),
                    completed_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, organization_id, feature, stream_id, request_key, credential_revision, capability_revision),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id) ON DELETE CASCADE,
                    FOREIGN KEY (account_id, organization_id, feature, stream_id)
                        REFERENCES sync_streams(account_id, organization_id, feature, id) ON DELETE CASCADE,
                    CHECK (etag IS NOT NULL OR last_modified IS NOT NULL)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE notification_failure_envelopes (
                    id TEXT PRIMARY KEY NOT NULL CHECK (length(id) BETWEEN 1 AND 128),
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE CHECK (length(account_id) BETWEEN 1 AND 512),
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE CHECK (length(organization_id) BETWEEN 1 AND 512),
                    feature TEXT NOT NULL CHECK (feature = 'notifications'),
                    stream_id TEXT NOT NULL CHECK (length(stream_id) BETWEEN 1 AND 512),
                    credential_revision TEXT NOT NULL CHECK (length(credential_revision) BETWEEN 1 AND 512),
                    capability_revision TEXT NOT NULL CHECK (length(capability_revision) BETWEEN 1 AND 512),
                    classification TEXT NOT NULL CHECK (classification IN ('ssoRequired', 'approvalRequired', 'authenticationRequired', 'rateLimited', 'unavailableOrPermission', 'integrity', 'transient')),
                    retry_at_ms INTEGER,
                    observed_at_ms INTEGER NOT NULL,
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id) ON DELETE CASCADE,
                    FOREIGN KEY (account_id, organization_id, feature, stream_id)
                        REFERENCES sync_streams(account_id, organization_id, feature, id) ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE TABLE notification_failure_pages (
                    failure_id TEXT NOT NULL REFERENCES notification_failure_envelopes(id) ON DELETE CASCADE CHECK (length(failure_id) BETWEEN 1 AND 128),
                    raw_snapshot_id TEXT NOT NULL REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT CHECK (length(raw_snapshot_id) BETWEEN 1 AND 512),
                    page_index INTEGER NOT NULL CHECK (page_index BETWEEN 1 AND 100),
                    PRIMARY KEY (failure_id, page_index),
                    UNIQUE (failure_id, raw_snapshot_id)
                )
                """)
            try database.execute(sql: """
                CREATE INDEX notification_threads_current_scope
                ON notification_threads (account_id, organization_id, credential_revision, capability_revision, updated_at_ms DESC, notification_id)
                """)
            try database.execute(sql: """
                CREATE INDEX notification_threads_raw_snapshot ON notification_threads (raw_snapshot_id)
                """)
            try database.execute(sql: """
                CREATE INDEX notification_current_pages_scope
                ON notification_current_pages (account_id, organization_id, feature, stream_id, credential_revision, capability_revision, source_revision, page_index)
                """)
            try database.execute(sql: """
                CREATE INDEX notification_current_pages_raw_snapshot ON notification_current_pages (raw_snapshot_id)
                """)
            try database.execute(sql: """
                CREATE INDEX notification_replay_receipts_scope
                ON notification_replay_receipts (account_id, organization_id, feature, stream_id, credential_revision, capability_revision, completed_at_ms DESC)
                """)
            try database.execute(sql: """
                CREATE INDEX notification_failure_envelopes_scope
                ON notification_failure_envelopes (account_id, organization_id, feature, stream_id, credential_revision, capability_revision, observed_at_ms DESC, id DESC)
                """)
            try database.execute(sql: """
                CREATE INDEX notification_failure_pages_raw_snapshot ON notification_failure_pages (raw_snapshot_id)
                """)
            try database.execute(sql: """
                CREATE TRIGGER notification_protect_provenance_snapshot_delete
                BEFORE DELETE ON raw_api_snapshots
                WHEN (
                    EXISTS (SELECT 1 FROM notification_current_pages WHERE raw_snapshot_id = OLD.id)
                    OR EXISTS (SELECT 1 FROM notification_threads WHERE raw_snapshot_id = OLD.id)
                    OR EXISTS (SELECT 1 FROM notification_failure_pages WHERE raw_snapshot_id = OLD.id)
                ) AND EXISTS (SELECT 1 FROM accounts WHERE id = OLD.account_id)
                BEGIN SELECT RAISE(ABORT, 'notification source provenance is durable'); END
                """)
            try database.execute(sql: """
                CREATE TRIGGER notification_protect_provenance_snapshot_update
                BEFORE UPDATE ON raw_api_snapshots
                WHEN (
                    EXISTS (SELECT 1 FROM notification_current_pages WHERE raw_snapshot_id = OLD.id)
                    OR EXISTS (SELECT 1 FROM notification_threads WHERE raw_snapshot_id = OLD.id)
                    OR EXISTS (SELECT 1 FROM notification_failure_pages WHERE raw_snapshot_id = OLD.id)
                ) AND EXISTS (SELECT 1 FROM accounts WHERE id = OLD.account_id)
                AND (
                    OLD.id IS NOT NEW.id OR OLD.account_id IS NOT NEW.account_id
                    OR OLD.github_node_id IS NOT NEW.github_node_id OR OLD.endpoint IS NOT NEW.endpoint
                    OR OLD.etag IS NOT NEW.etag OR OLD.last_modified IS NOT NEW.last_modified
                    OR OLD.authority_organization_id IS NOT NEW.authority_organization_id
                    OR OLD.authority_feature IS NOT NEW.authority_feature
                    OR OLD.authority_stream_id IS NOT NEW.authority_stream_id
                    OR OLD.authority_request_key IS NOT NEW.authority_request_key
                    OR OLD.authority_credential_revision IS NOT NEW.authority_credential_revision
                    OR OLD.authority_capability_revision IS NOT NEW.authority_capability_revision
                    OR OLD.parser_version IS NOT NEW.parser_version OR OLD.observed_at_ms IS NOT NEW.observed_at_ms
                    OR OLD.payload IS NOT NEW.payload
                )
                BEGIN SELECT RAISE(ABORT, 'notification source provenance is immutable'); END
                """)
        },
        TriageDatabaseMigration(
            id: "042-derived-intelligence-revision-evidence-v1",
            checksum: "aee0510ac9a74c252acf9cf2d8227ebd7da278fa879d9fa64efa5a2370a0285f"
        ) { database in
            // This is the single current derived projection for a selected
            // account/organization. `source_revision` is the adapter's
            // canonical SHA-256 over the normalized primary-source revisions.
            try database.execute(sql: """
                CREATE TABLE derived_intelligence_runs (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE
                        CHECK (length(account_id) BETWEEN 1 AND 512),
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE
                        CHECK (length(organization_id) BETWEEN 1 AND 512),
                    credential_revision TEXT NOT NULL CHECK (length(credential_revision) BETWEEN 1 AND 512),
                    capability_revision TEXT NOT NULL CHECK (length(capability_revision) BETWEEN 1 AND 512),
                    source_revision TEXT NOT NULL CHECK (
                        length(source_revision) = 64
                        AND source_revision NOT GLOB '*[^0-9a-f]*'
                    ),
                    evaluated_at_ms INTEGER NOT NULL,
                    coverage_state TEXT NOT NULL CHECK (coverage_state IN ('trusted', 'incomplete', 'unknown')),
                    freshness_status TEXT NOT NULL CHECK (freshness_status IN (
                        'fresh', 'refreshing', 'stale', 'partial', 'offline',
                        'authenticationRequired', 'ssoRequired', 'approvalRequired',
                        'rateLimited', 'failed'
                    )),
                    is_provisional INTEGER NOT NULL CHECK (is_provisional IN (0, 1)),
                    freshness_last_successful_at_ms INTEGER,
                    freshness_next_retry_at_ms INTEGER,
                    freshness_detail TEXT,
                    missing_coverage_json BLOB NOT NULL CHECK (length(missing_coverage_json) <= 4194304),
                    PRIMARY KEY (account_id, organization_id),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE TABLE rule_evaluations (
                    id TEXT PRIMARY KEY NOT NULL CHECK (length(id) BETWEEN 1 AND 512),
                    account_id TEXT NOT NULL CHECK (length(account_id) BETWEEN 1 AND 512),
                    organization_id TEXT NOT NULL CHECK (length(organization_id) BETWEEN 1 AND 512),
                    work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE
                        CHECK (length(work_item_id) BETWEEN 1 AND 512),
                    credential_revision TEXT NOT NULL CHECK (length(credential_revision) BETWEEN 1 AND 512),
                    capability_revision TEXT NOT NULL CHECK (length(capability_revision) BETWEEN 1 AND 512),
                    source_revision TEXT NOT NULL CHECK (
                        length(source_revision) = 64
                        AND source_revision NOT GLOB '*[^0-9a-f]*'
                    ),
                    rule_id TEXT NOT NULL CHECK (length(rule_id) BETWEEN 1 AND 512),
                    rule_version INTEGER NOT NULL CHECK (rule_version > 0),
                    category TEXT NOT NULL CHECK (category IN (
                        'directResponsibility', 'conversation', 'pullRequest',
                        'progress', 'waiting', 'deadline'
                    )),
                    strength INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    explanation TEXT NOT NULL,
                    evaluated_at_ms INTEGER NOT NULL,
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE TABLE rule_evaluation_evidence (
                    rule_evaluation_id TEXT NOT NULL REFERENCES rule_evaluations(id) ON DELETE CASCADE,
                    evidence_id TEXT NOT NULL CHECK (length(evidence_id) BETWEEN 1 AND 512),
                    source TEXT NOT NULL CHECK (source IN (
                        'restSearch', 'restTimeline', 'restReview', 'restNotification',
                        'graphQL', 'localWorkflow', 'legacyUnverified'
                    )),
                    source_locator_kind TEXT NOT NULL CHECK (source_locator_kind IN (
                        'endpoint', 'query', 'localWorkflow', 'legacyUnverified'
                    )),
                    source_locator TEXT NOT NULL CHECK (length(source_locator) BETWEEN 1 AND 2048),
                    authority_kind TEXT NOT NULL CHECK (authority_kind IN (
                        'github', 'localWorkflow', 'legacyUnverified'
                    )),
                    authority_account_id TEXT,
                    authority_organization_id TEXT,
                    authority_feature TEXT,
                    authority_stream_id TEXT,
                    authority_credential_revision TEXT,
                    authority_capability_revision TEXT,
                    source_node_id TEXT,
                    source_event_id TEXT,
                    source_revision TEXT CHECK (source_revision IS NULL OR length(source_revision) BETWEEN 1 AND 500),
                    raw_snapshot_id TEXT REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT,
                    confidence TEXT NOT NULL CHECK (confidence IN ('provisional', 'confirmed')),
                    confirmation TEXT NOT NULL CHECK (confirmation IN ('provisional', 'confirmed')),
                    observed_at_ms INTEGER NOT NULL,
                    excerpt TEXT,
                    PRIMARY KEY (rule_evaluation_id, evidence_id),
                    CHECK (
                        (
                            authority_kind = 'github'
                            AND source IN ('restSearch', 'restTimeline', 'restReview', 'restNotification', 'graphQL')
                            AND source_locator_kind IN ('endpoint', 'query')
                            AND authority_account_id IS NOT NULL
                            AND authority_organization_id IS NOT NULL
                            AND authority_feature IS NOT NULL
                            AND authority_stream_id IS NOT NULL
                            AND authority_credential_revision IS NOT NULL
                            AND authority_capability_revision IS NOT NULL
                        ) OR (
                            authority_kind = 'localWorkflow'
                            AND source = 'localWorkflow'
                            AND source_locator_kind = 'localWorkflow'
                            AND authority_account_id IS NOT NULL
                            AND authority_organization_id IS NOT NULL
                            AND authority_feature IS NULL
                            AND authority_stream_id IS NULL
                            AND authority_credential_revision IS NULL
                            AND authority_capability_revision IS NULL
                        ) OR (
                            authority_kind = 'legacyUnverified'
                            AND source = 'legacyUnverified'
                            AND source_locator_kind = 'legacyUnverified'
                            AND source_locator = 'legacy-unverified'
                            AND authority_account_id IS NULL
                            AND authority_organization_id IS NULL
                            AND authority_feature IS NULL
                            AND authority_stream_id IS NULL
                            AND authority_credential_revision IS NULL
                            AND authority_capability_revision IS NULL
                            AND confidence = 'provisional'
                            AND confirmation = 'provisional'
                        )
                    )
                )
                """)
            try database.execute(sql: """
                CREATE TABLE ai_action_candidates (
                    account_id TEXT NOT NULL CHECK (length(account_id) BETWEEN 1 AND 512),
                    organization_id TEXT NOT NULL CHECK (length(organization_id) BETWEEN 1 AND 512),
                    work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE
                        CHECK (length(work_item_id) BETWEEN 1 AND 512),
                    credential_revision TEXT NOT NULL CHECK (length(credential_revision) BETWEEN 1 AND 512),
                    capability_revision TEXT NOT NULL CHECK (length(capability_revision) BETWEEN 1 AND 512),
                    source_revision TEXT NOT NULL CHECK (
                        length(source_revision) = 64
                        AND source_revision NOT GLOB '*[^0-9a-f]*'
                    ),
                    candidate_id TEXT CHECK (candidate_id IS NULL OR length(candidate_id) BETWEEN 1 AND 512),
                    disposition TEXT NOT NULL CHECK (disposition IN ('candidate', 'excluded')),
                    exclusion_reason TEXT CHECK (exclusion_reason IN (
                        'incompleteCoverage', 'policyUnavailable', 'unchangedFingerprint', 'cachedAnalysis'
                    )),
                    score INTEGER,
                    score_breakdown_json BLOB,
                    trigger_reason_ids_json BLOB,
                    evaluated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, organization_id, work_item_id),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE,
                    CHECK (
                        (disposition = 'candidate'
                            AND candidate_id IS NOT NULL AND exclusion_reason IS NULL
                            AND score IS NOT NULL AND score_breakdown_json IS NOT NULL
                            AND trigger_reason_ids_json IS NOT NULL)
                        OR
                        (disposition = 'excluded'
                            AND candidate_id IS NULL AND exclusion_reason IS NOT NULL
                            AND score IS NULL AND score_breakdown_json IS NULL
                            AND trigger_reason_ids_json IS NULL)
                    )
                )
                """)
            try database.execute(sql: """
                CREATE INDEX rule_evaluations_current_scope
                ON rule_evaluations (
                    account_id, organization_id, credential_revision, capability_revision,
                    source_revision, work_item_id, evaluated_at_ms DESC, id
                )
                """)
            try database.execute(sql: """
                CREATE INDEX rule_evaluation_evidence_authority
                ON rule_evaluation_evidence (
                    authority_account_id, authority_organization_id, authority_feature,
                    authority_stream_id, authority_credential_revision,
                    authority_capability_revision, source_revision, rule_evaluation_id
                )
                """)
            try database.execute(sql: """
                CREATE INDEX rule_evaluation_evidence_raw_snapshot
                ON rule_evaluation_evidence (raw_snapshot_id)
                """)
            try database.execute(sql: """
                CREATE INDEX ai_action_candidates_current_scope
                ON ai_action_candidates (
                    account_id, organization_id, credential_revision, capability_revision,
                    source_revision, disposition, work_item_id
                )
                """)
            try database.execute(sql: """
                CREATE TRIGGER derived_intelligence_protect_evidence_snapshot_delete
                BEFORE DELETE ON raw_api_snapshots
                WHEN EXISTS (
                    SELECT 1 FROM rule_evaluation_evidence
                    WHERE raw_snapshot_id = OLD.id
                ) AND EXISTS (SELECT 1 FROM accounts WHERE id = OLD.account_id)
                BEGIN SELECT RAISE(ABORT, 'derived intelligence evidence is durable'); END
                """)
            try database.execute(sql: """
                CREATE TRIGGER derived_intelligence_protect_evidence_snapshot_update
                BEFORE UPDATE ON raw_api_snapshots
                WHEN EXISTS (
                    SELECT 1 FROM rule_evaluation_evidence
                    WHERE raw_snapshot_id = OLD.id
                ) AND EXISTS (SELECT 1 FROM accounts WHERE id = OLD.account_id)
                AND (
                    OLD.id IS NOT NEW.id OR OLD.account_id IS NOT NEW.account_id
                    OR OLD.github_node_id IS NOT NEW.github_node_id OR OLD.endpoint IS NOT NEW.endpoint
                    OR OLD.etag IS NOT NEW.etag OR OLD.last_modified IS NOT NEW.last_modified
                    OR OLD.authority_organization_id IS NOT NEW.authority_organization_id
                    OR OLD.authority_feature IS NOT NEW.authority_feature
                    OR OLD.authority_stream_id IS NOT NEW.authority_stream_id
                    OR OLD.authority_request_key IS NOT NEW.authority_request_key
                    OR OLD.authority_credential_revision IS NOT NEW.authority_credential_revision
                    OR OLD.authority_capability_revision IS NOT NEW.authority_capability_revision
                    OR OLD.parser_version IS NOT NEW.parser_version OR OLD.observed_at_ms IS NOT NEW.observed_at_ms
                    OR OLD.payload IS NOT NEW.payload
                )
                BEGIN SELECT RAISE(ABORT, 'derived intelligence evidence is immutable'); END
                """)
        },
        TriageDatabaseMigration(
            id: "043-review-candidate-complete-traversal-receipts-v1",
            checksum: "1e339b7fbdaa9acafb7463f213ab27828b8d5e0a1d74cbb6d51a79c2620d8802"
        ) { database in
            // This receipt is the source-completeness gate for review and
            // thread reconciliation. Candidate identifiers intentionally are
            // evidence rather than cascading foreign keys so a later source
            // tombstone cannot silently erase provenance.
            try database.execute(sql: """
                CREATE TABLE review_candidate_complete_traversal_receipts (
                    id TEXT PRIMARY KEY NOT NULL CHECK (length(id) BETWEEN 1 AND 512),
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE
                        CHECK (length(account_id) BETWEEN 1 AND 512),
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE
                        CHECK (length(organization_id) BETWEEN 1 AND 512),
                    feature TEXT NOT NULL CHECK (feature IN ('reviews', 'reviewThreads')),
                    stream_id TEXT NOT NULL REFERENCES sync_streams(id) ON DELETE CASCADE
                        CHECK (length(stream_id) BETWEEN 1 AND 512),
                    candidate_node_id TEXT NOT NULL CHECK (length(candidate_node_id) BETWEEN 1 AND 512),
                    repository_id TEXT NOT NULL CHECK (length(repository_id) BETWEEN 1 AND 512),
                    candidate_source_revision TEXT NOT NULL
                        CHECK (length(candidate_source_revision) BETWEEN 1 AND 500),
                    credential_revision TEXT NOT NULL CHECK (length(credential_revision) BETWEEN 1 AND 512),
                    capability_revision TEXT NOT NULL CHECK (length(capability_revision) BETWEEN 1 AND 512),
                    parser_version INTEGER NOT NULL CHECK (parser_version > 0),
                    observed_at_ms INTEGER NOT NULL,
                    normalized_digest BLOB NOT NULL CHECK (length(normalized_digest) = 32),
                    segment_count INTEGER NOT NULL CHECK (segment_count > 0),
                    page_count INTEGER NOT NULL CHECK (page_count > 0),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE TABLE review_candidate_complete_traversal_segments (
                    receipt_id TEXT NOT NULL
                        REFERENCES review_candidate_complete_traversal_receipts(id) ON DELETE CASCADE,
                    segment_key TEXT NOT NULL CHECK (length(segment_key) BETWEEN 1 AND 1024),
                    segment_kind TEXT NOT NULL CHECK (segment_kind IN (
                        'reviewHistory', 'requestedReviewers', 'reviewThreads', 'threadComments'
                    )),
                    parent_thread_node_id TEXT CHECK (
                        parent_thread_node_id IS NULL OR length(parent_thread_node_id) BETWEEN 1 AND 512
                    ),
                    page_count INTEGER NOT NULL CHECK (page_count > 0),
                    terminal_page_ordinal INTEGER NOT NULL CHECK (terminal_page_ordinal > 0),
                    PRIMARY KEY (receipt_id, segment_key),
                    CHECK (
                        (segment_kind = 'threadComments' AND parent_thread_node_id IS NOT NULL)
                        OR (segment_kind != 'threadComments' AND parent_thread_node_id IS NULL)
                    ),
                    CHECK (terminal_page_ordinal = page_count)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE review_candidate_complete_traversal_pages (
                    receipt_id TEXT NOT NULL,
                    segment_key TEXT NOT NULL,
                    page_ordinal INTEGER NOT NULL CHECK (page_ordinal > 0),
                    raw_snapshot_id TEXT NOT NULL REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT
                        CHECK (length(raw_snapshot_id) BETWEEN 1 AND 512),
                    request_key TEXT NOT NULL CHECK (length(request_key) BETWEEN 1 AND 2048),
                    is_terminal INTEGER NOT NULL CHECK (is_terminal IN (0, 1)),
                    PRIMARY KEY (receipt_id, segment_key, page_ordinal),
                    UNIQUE (receipt_id, raw_snapshot_id),
                    FOREIGN KEY (receipt_id, segment_key)
                        REFERENCES review_candidate_complete_traversal_segments(receipt_id, segment_key)
                        ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE INDEX review_candidate_complete_traversal_receipts_current_scope
                ON review_candidate_complete_traversal_receipts (
                    account_id, organization_id, feature, stream_id, candidate_node_id,
                    repository_id, candidate_source_revision, credential_revision,
                    capability_revision, observed_at_ms DESC, id DESC
                )
                """)
            try database.execute(sql: """
                CREATE INDEX review_candidate_complete_traversal_pages_raw_snapshot
                ON review_candidate_complete_traversal_pages (raw_snapshot_id)
                """)
            try database.execute(sql: """
                CREATE TRIGGER review_candidate_complete_traversal_protect_snapshot_delete
                BEFORE DELETE ON raw_api_snapshots
                WHEN EXISTS (
                    SELECT 1 FROM review_candidate_complete_traversal_pages
                    WHERE raw_snapshot_id = OLD.id
                ) AND EXISTS (SELECT 1 FROM accounts WHERE id = OLD.account_id)
                BEGIN SELECT RAISE(ABORT, 'review complete traversal provenance is durable'); END
                """)
            try database.execute(sql: """
                CREATE TRIGGER review_candidate_complete_traversal_protect_snapshot_update
                BEFORE UPDATE ON raw_api_snapshots
                WHEN EXISTS (
                    SELECT 1 FROM review_candidate_complete_traversal_pages
                    WHERE raw_snapshot_id = OLD.id
                ) AND EXISTS (SELECT 1 FROM accounts WHERE id = OLD.account_id)
                AND (
                    OLD.id IS NOT NEW.id OR OLD.account_id IS NOT NEW.account_id
                    OR OLD.github_node_id IS NOT NEW.github_node_id OR OLD.endpoint IS NOT NEW.endpoint
                    OR OLD.etag IS NOT NEW.etag OR OLD.last_modified IS NOT NEW.last_modified
                    OR OLD.authority_organization_id IS NOT NEW.authority_organization_id
                    OR OLD.authority_feature IS NOT NEW.authority_feature
                    OR OLD.authority_stream_id IS NOT NEW.authority_stream_id
                    OR OLD.authority_request_key IS NOT NEW.authority_request_key
                    OR OLD.authority_credential_revision IS NOT NEW.authority_credential_revision
                    OR OLD.authority_capability_revision IS NOT NEW.authority_capability_revision
                    OR OLD.parser_version IS NOT NEW.parser_version OR OLD.observed_at_ms IS NOT NEW.observed_at_ms
                    OR OLD.payload IS NOT NEW.payload
                )
                BEGIN SELECT RAISE(ABORT, 'review complete traversal provenance is immutable'); END
                """)
        },
        TriageDatabaseMigration(
            id: "044-workspace-query-performance-indexes-v1",
            checksum: "8b9e0ec0885167e950ef210c8d3a8697559ca1e1c897c41069830417afb90188"
        ) { database in
            // Workspace graph, observation, and bounded FTS rebuild paths.
            // Do not duplicate the existing project_field_values primary key
            // (project_item_node_id, field_name).
            try database.execute(sql: """
                CREATE INDEX workspace_work_items_scope_activity
                ON work_items (account_id, organization_id, last_relevant_activity_at_ms DESC, id)
                """)
            try database.execute(sql: """
                CREATE INDEX workspace_attention_reasons_order
                ON attention_reasons (work_item_id, strength DESC, id)
                """)
            try database.execute(sql: """
                CREATE INDEX workspace_attention_reasons_rule
                ON attention_reasons (work_item_id, rule_id)
                """)
            try database.execute(sql: """
                CREATE INDEX workspace_relations_subject_kind
                ON relations (account_id, subject_node_id, kind)
                """)
            try database.execute(sql: """
                CREATE INDEX workspace_relation_evidence_order
                ON relation_evidence (
                    relation_id, observed_at_ms, source, source_locator_kind, source_locator, evidence_id
                )
                """)
            try database.execute(sql: """
                CREATE INDEX search_comments_parent_updated
                ON comments (parent_node_id, updated_at_ms DESC, github_node_id)
                """)
            try database.execute(sql: """
                CREATE INDEX search_reviews_parent_updated
                ON reviews (pull_request_node_id, updated_at_ms DESC, github_node_id)
                """)
            try database.execute(sql: """
                CREATE INDEX search_project_items_content_updated
                ON project_items (content_node_id, updated_at_ms DESC, github_node_id)
                """)
            try database.execute(sql: """
                CREATE INDEX search_action_items_work_updated
                ON action_items (work_item_id, updated_at_ms DESC, id)
                """)

            // DerivedIntelligenceInputAdapter fence and supplemental reads.
            try database.execute(sql: """
                CREATE INDEX derived_work_items_scope_id
                ON work_items (account_id, organization_id, id, primary_node_id)
                """)
            try database.execute(sql: """
                CREATE INDEX derived_team_memberships_account_state_expiry
                ON team_memberships (account_id, membership_state, expires_at_ms, team_id)
                """)
            try database.execute(sql: """
                CREATE INDEX derived_timeline_events_subject_occurred_id
                ON timeline_events (subject_node_id, occurred_at_ms, github_event_id)
                """)
            try database.execute(sql: """
                CREATE INDEX derived_review_threads_pull_request_updated
                ON review_threads (pull_request_node_id, updated_at_ms, github_node_id)
                """)
            try database.execute(sql: """
                CREATE INDEX derived_project_items_content_node
                ON project_items (content_node_id, github_node_id)
                """)
        },
        TriageDatabaseMigration(
            id: "045-review-candidate-receipt-append-only-v1",
            checksum: "a2f5e3bd86a41558c5f8e6c906c0e37318c4d9e511b7bb328fa1bcc765beed95"
        ) { database in
            // Complete traversal receipts authorize destructive reconciliation.
            // Their topology is as immutable as the raw snapshots they bind.
            try database.execute(sql: """
                CREATE TRIGGER review_candidate_complete_traversal_receipt_no_update
                BEFORE UPDATE ON review_candidate_complete_traversal_receipts
                BEGIN SELECT RAISE(ABORT, 'review complete traversal receipt is append-only'); END
                """)
            try database.execute(sql: """
                CREATE TRIGGER review_candidate_complete_traversal_receipt_no_delete
                BEFORE DELETE ON review_candidate_complete_traversal_receipts
                BEGIN SELECT RAISE(ABORT, 'review complete traversal receipt is append-only'); END
                """)
            try database.execute(sql: """
                CREATE TRIGGER review_candidate_complete_traversal_segment_no_update
                BEFORE UPDATE ON review_candidate_complete_traversal_segments
                BEGIN SELECT RAISE(ABORT, 'review complete traversal segment is append-only'); END
                """)
            try database.execute(sql: """
                CREATE TRIGGER review_candidate_complete_traversal_segment_no_delete
                BEFORE DELETE ON review_candidate_complete_traversal_segments
                BEGIN SELECT RAISE(ABORT, 'review complete traversal segment is append-only'); END
                """)
            try database.execute(sql: """
                CREATE TRIGGER review_candidate_complete_traversal_page_no_update
                BEFORE UPDATE ON review_candidate_complete_traversal_pages
                BEGIN SELECT RAISE(ABORT, 'review complete traversal page is append-only'); END
                """)
            try database.execute(sql: """
                CREATE TRIGGER review_candidate_complete_traversal_page_no_delete
                BEFORE DELETE ON review_candidate_complete_traversal_pages
                BEGIN SELECT RAISE(ABORT, 'review complete traversal page is append-only'); END
                """)
        },
        TriageDatabaseMigration(
            id: "046-post-account-identity-replay-receipts-v1",
            checksum: "a45a35a571e3d543645d24e8dcdf86ca11eeb76c1a51391c2513cdce71fd3771"
        ) { database in
            // Account organization discovery is deliberately account-scoped:
            // it must never borrow a sentinel organization to satisfy the
            // organization-scoped conditional-request schema.
            try database.execute(sql: """
                CREATE TABLE account_organization_inventory_replay_receipts (
                    id TEXT PRIMARY KEY NOT NULL CHECK (length(id) BETWEEN 1 AND 512),
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    credential_revision TEXT NOT NULL CHECK (length(credential_revision) BETWEEN 1 AND 512),
                    request_key TEXT NOT NULL CHECK (request_key = 'GET /user/orgs?per_page=100'),
                    etag TEXT, last_modified TEXT,
                    parser_version INTEGER NOT NULL CHECK (parser_version > 0),
                    source_revision TEXT NOT NULL CHECK (length(source_revision) BETWEEN 1 AND 512),
                    normalized_digest BLOB NOT NULL CHECK (length(normalized_digest) = 32),
                    page_count INTEGER NOT NULL CHECK (page_count > 0),
                    organization_count INTEGER NOT NULL CHECK (organization_count >= 0),
                    observed_at_ms INTEGER NOT NULL, committed_at_ms INTEGER NOT NULL,
                    validated_at_ms INTEGER NOT NULL, receipt_version INTEGER NOT NULL CHECK (receipt_version = 1),
                    CHECK (etag IS NOT NULL OR last_modified IS NOT NULL),
                    UNIQUE (account_id, credential_revision, request_key)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE account_organization_inventory_replay_receipt_pages (
                    receipt_id TEXT NOT NULL REFERENCES account_organization_inventory_replay_receipts(id) ON DELETE CASCADE,
                    page_ordinal INTEGER NOT NULL CHECK (page_ordinal > 0),
                    raw_snapshot_id TEXT NOT NULL REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT,
                    request_key TEXT NOT NULL CHECK (length(request_key) BETWEEN 1 AND 2048),
                    raw_payload_digest BLOB NOT NULL CHECK (length(raw_payload_digest) = 32),
                    organization_ids_digest BLOB NOT NULL CHECK (length(organization_ids_digest) = 32),
                    is_terminal INTEGER NOT NULL CHECK (is_terminal IN (0, 1)),
                    PRIMARY KEY (receipt_id, page_ordinal), UNIQUE (receipt_id, raw_snapshot_id)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE organization_metadata_replay_receipts (
                    id TEXT PRIMARY KEY NOT NULL CHECK (length(id) BETWEEN 1 AND 512),
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    feature TEXT NOT NULL CHECK (feature = 'organizationMetadata'),
                    stream_id TEXT NOT NULL REFERENCES sync_streams(id) ON DELETE CASCADE,
                    credential_revision TEXT NOT NULL CHECK (length(credential_revision) BETWEEN 1 AND 512),
                    capability_revision TEXT NOT NULL CHECK (length(capability_revision) BETWEEN 1 AND 512),
                    request_key TEXT NOT NULL CHECK (request_key LIKE 'GET /orgs/%'),
                    etag TEXT, last_modified TEXT,
                    raw_snapshot_id TEXT NOT NULL REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT,
                    raw_payload_digest BLOB NOT NULL CHECK (length(raw_payload_digest) = 32),
                    normalized_digest BLOB NOT NULL CHECK (length(normalized_digest) = 32),
                    parser_version INTEGER NOT NULL CHECK (parser_version > 0),
                    source_revision TEXT NOT NULL CHECK (length(source_revision) BETWEEN 1 AND 512),
                    observed_at_ms INTEGER NOT NULL, committed_at_ms INTEGER NOT NULL,
                    validated_at_ms INTEGER NOT NULL, receipt_version INTEGER NOT NULL CHECK (receipt_version = 1),
                    CHECK (etag IS NOT NULL OR last_modified IS NOT NULL),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id) ON DELETE CASCADE,
                    UNIQUE (account_id, organization_id, credential_revision, capability_revision, feature, stream_id, request_key)
                )
                """)
            try database.execute(sql: """
                CREATE INDEX account_organization_inventory_replay_receipts_scope
                ON account_organization_inventory_replay_receipts (account_id, credential_revision, request_key, validated_at_ms DESC)
                """)
            try database.execute(sql: """
                CREATE INDEX account_organization_inventory_replay_pages_snapshot
                ON account_organization_inventory_replay_receipt_pages (raw_snapshot_id)
                """)
            try database.execute(sql: """
                CREATE INDEX organization_metadata_replay_receipts_scope
                ON organization_metadata_replay_receipts (account_id, organization_id, credential_revision, capability_revision, feature, stream_id, request_key, validated_at_ms DESC)
                """)
            try database.execute(sql: """
                CREATE TRIGGER account_organization_inventory_replay_protect_snapshot_delete
                BEFORE DELETE ON raw_api_snapshots WHEN EXISTS (
                    SELECT 1 FROM account_organization_inventory_replay_receipt_pages WHERE raw_snapshot_id = OLD.id
                ) AND EXISTS (SELECT 1 FROM accounts WHERE id = OLD.account_id)
                BEGIN SELECT RAISE(ABORT, 'account organization replay provenance is durable'); END
                """)
            try database.execute(sql: """
                CREATE TRIGGER account_organization_inventory_replay_protect_snapshot_update
                BEFORE UPDATE ON raw_api_snapshots
                WHEN EXISTS (
                    SELECT 1 FROM account_organization_inventory_replay_receipt_pages
                    WHERE raw_snapshot_id = OLD.id
                ) AND EXISTS (SELECT 1 FROM accounts WHERE id = OLD.account_id)
                AND (
                    OLD.id IS NOT NEW.id OR OLD.account_id IS NOT NEW.account_id
                    OR OLD.github_node_id IS NOT NEW.github_node_id OR OLD.endpoint IS NOT NEW.endpoint
                    OR OLD.etag IS NOT NEW.etag OR OLD.last_modified IS NOT NEW.last_modified
                    OR OLD.authority_organization_id IS NOT NEW.authority_organization_id
                    OR OLD.authority_feature IS NOT NEW.authority_feature
                    OR OLD.authority_stream_id IS NOT NEW.authority_stream_id
                    OR OLD.authority_request_key IS NOT NEW.authority_request_key
                    OR OLD.authority_credential_revision IS NOT NEW.authority_credential_revision
                    OR OLD.authority_capability_revision IS NOT NEW.authority_capability_revision
                    OR OLD.parser_version IS NOT NEW.parser_version OR OLD.observed_at_ms IS NOT NEW.observed_at_ms
                    OR OLD.payload IS NOT NEW.payload
                )
                BEGIN SELECT RAISE(ABORT, 'account organization replay provenance is immutable'); END
                """)
            try database.execute(sql: """
                CREATE TRIGGER organization_metadata_replay_protect_snapshot_delete
                BEFORE DELETE ON raw_api_snapshots WHEN EXISTS (
                    SELECT 1 FROM organization_metadata_replay_receipts WHERE raw_snapshot_id = OLD.id
                ) AND EXISTS (SELECT 1 FROM accounts WHERE id = OLD.account_id)
                BEGIN SELECT RAISE(ABORT, 'organization metadata replay provenance is durable'); END
                """)
            try database.execute(sql: """
                CREATE TRIGGER organization_metadata_replay_protect_snapshot_update
                BEFORE UPDATE ON raw_api_snapshots
                WHEN EXISTS (
                    SELECT 1 FROM organization_metadata_replay_receipts
                    WHERE raw_snapshot_id = OLD.id
                ) AND EXISTS (SELECT 1 FROM accounts WHERE id = OLD.account_id)
                AND (
                    OLD.id IS NOT NEW.id OR OLD.account_id IS NOT NEW.account_id
                    OR OLD.github_node_id IS NOT NEW.github_node_id OR OLD.endpoint IS NOT NEW.endpoint
                    OR OLD.etag IS NOT NEW.etag OR OLD.last_modified IS NOT NEW.last_modified
                    OR OLD.authority_organization_id IS NOT NEW.authority_organization_id
                    OR OLD.authority_feature IS NOT NEW.authority_feature
                    OR OLD.authority_stream_id IS NOT NEW.authority_stream_id
                    OR OLD.authority_request_key IS NOT NEW.authority_request_key
                    OR OLD.authority_credential_revision IS NOT NEW.authority_credential_revision
                    OR OLD.authority_capability_revision IS NOT NEW.authority_capability_revision
                    OR OLD.parser_version IS NOT NEW.parser_version OR OLD.observed_at_ms IS NOT NEW.observed_at_ms
                    OR OLD.payload IS NOT NEW.payload
                )
                BEGIN SELECT RAISE(ABORT, 'organization metadata replay provenance is immutable'); END
                """)
        },
        TriageDatabaseMigration(
            id: "047-work-item-graph-revision-v1",
            checksum: "f149203a03a55c374e285177e05b7d13b80bf12d9104ddedc653666c5ef4a9e7"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE work_item_graph_runs (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    source_revision TEXT NOT NULL CHECK (length(source_revision) = 64),
                    projected_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, organization_id),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id) ON DELETE CASCADE
                )
                """)
        },
        TriageDatabaseMigration(
            id: "048-review-candidate-incremental-state-v1",
            checksum: "ad313bbe07cfc7c98d3783a006db26aea26637edbda5e8a87801c3101d5a8902"
        ) { database in
            // Mutable per-candidate scheduling/replay state remains separate
            // from append-only traversal receipts. It cannot itself authorize
            // a 304 replacement.
            try database.execute(sql: """
                CREATE TABLE review_candidate_incremental_states (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    feature TEXT NOT NULL CHECK (feature IN ('reviews', 'reviewThreads')),
                    stream_id TEXT NOT NULL REFERENCES sync_streams(id) ON DELETE CASCADE,
                    candidate_node_id TEXT NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    source_revision TEXT NOT NULL CHECK (length(source_revision) BETWEEN 1 AND 500),
                    first_page_request_key TEXT NOT NULL CHECK (length(first_page_request_key) BETWEEN 1 AND 2048),
                    high_water_ms INTEGER NOT NULL,
                    root_cursor TEXT,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (
                        account_id, organization_id, feature, stream_id,
                        candidate_node_id, credential_revision, capability_revision
                    ),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id) ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE INDEX review_candidate_incremental_states_lookup
                ON review_candidate_incremental_states (
                    account_id, organization_id, feature, stream_id,
                    candidate_node_id, credential_revision, capability_revision,
                    updated_at_ms DESC
                )
                """)
        },
        TriageDatabaseMigration(
            id: "049-authenticated-user-replay-receipts-v1",
            checksum: "79113d268c469caf4c7b2641c443768e8aced6ec4956a64248887e5a08c5d209"
        ) { database in
            // `/user` is account-scoped and credential-revision-bound. It
            // deliberately has no invented organization or capability scope.
            try database.execute(sql: """
                CREATE TABLE authenticated_user_replay_receipts (
                    id TEXT PRIMARY KEY NOT NULL CHECK (length(id) BETWEEN 1 AND 512),
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    credential_revision TEXT NOT NULL CHECK (length(credential_revision) BETWEEN 1 AND 512),
                    request_key TEXT NOT NULL CHECK (request_key = 'GET /user'),
                    etag TEXT, last_modified TEXT,
                    raw_snapshot_id TEXT NOT NULL REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT,
                    raw_payload_digest BLOB NOT NULL CHECK (length(raw_payload_digest) = 32),
                    normalized_digest BLOB NOT NULL CHECK (length(normalized_digest) = 32),
                    parser_version INTEGER NOT NULL CHECK (parser_version > 0),
                    source_revision TEXT NOT NULL CHECK (length(source_revision) = 64),
                    observed_at_ms INTEGER NOT NULL, committed_at_ms INTEGER NOT NULL,
                    validated_at_ms INTEGER NOT NULL, receipt_version INTEGER NOT NULL CHECK (receipt_version = 1),
                    CHECK (etag IS NOT NULL OR last_modified IS NOT NULL),
                    UNIQUE (account_id, credential_revision, request_key)
                )
                """)
            try database.execute(sql: """
                CREATE INDEX authenticated_user_replay_receipts_scope
                ON authenticated_user_replay_receipts (
                    account_id, credential_revision, request_key, validated_at_ms DESC
                )
                """)
            try database.execute(sql: """
                CREATE TRIGGER authenticated_user_replay_protect_snapshot_delete
                BEFORE DELETE ON raw_api_snapshots WHEN EXISTS (
                    SELECT 1 FROM authenticated_user_replay_receipts
                    WHERE raw_snapshot_id = OLD.id
                ) AND EXISTS (SELECT 1 FROM accounts WHERE id = OLD.account_id)
                BEGIN SELECT RAISE(ABORT, 'authenticated user replay provenance is durable'); END
                """)
            try database.execute(sql: """
                CREATE TRIGGER authenticated_user_replay_protect_snapshot_update
                BEFORE UPDATE ON raw_api_snapshots
                WHEN EXISTS (
                    SELECT 1 FROM authenticated_user_replay_receipts
                    WHERE raw_snapshot_id = OLD.id
                ) AND EXISTS (SELECT 1 FROM accounts WHERE id = OLD.account_id)
                AND (
                    OLD.id IS NOT NEW.id OR OLD.account_id IS NOT NEW.account_id
                    OR OLD.github_node_id IS NOT NEW.github_node_id OR OLD.endpoint IS NOT NEW.endpoint
                    OR OLD.etag IS NOT NEW.etag OR OLD.last_modified IS NOT NEW.last_modified
                    OR OLD.authority_organization_id IS NOT NEW.authority_organization_id
                    OR OLD.authority_feature IS NOT NEW.authority_feature
                    OR OLD.authority_stream_id IS NOT NEW.authority_stream_id
                    OR OLD.authority_request_key IS NOT NEW.authority_request_key
                    OR OLD.authority_credential_revision IS NOT NEW.authority_credential_revision
                    OR OLD.authority_capability_revision IS NOT NEW.authority_capability_revision
                    OR OLD.parser_version IS NOT NEW.parser_version OR OLD.observed_at_ms IS NOT NEW.observed_at_ms
                    OR OLD.payload IS NOT NEW.payload
                )
                BEGIN SELECT RAISE(ABORT, 'authenticated user replay provenance is immutable'); END
                """)
        },
        TriageDatabaseMigration(
            id: "050-review-thread-root-checkpoints-v1",
            checksum: "5ce9b7c173f946abfd8f4fbbfdc663401a8d4a77ed673d36787da2ce4f5939b6"
        ) { database in
            try database.execute(sql: """
                CREATE TABLE review_candidate_thread_checkpoint_pages (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    stream_id TEXT NOT NULL REFERENCES sync_streams(id) ON DELETE CASCADE,
                    candidate_node_id TEXT NOT NULL REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    source_revision TEXT NOT NULL CHECK (length(source_revision) BETWEEN 1 AND 500),
                    page_ordinal INTEGER NOT NULL CHECK (page_ordinal > 0),
                    raw_snapshot_id TEXT NOT NULL REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT,
                    PRIMARY KEY (account_id, organization_id, stream_id, candidate_node_id,
                                 credential_revision, capability_revision, page_ordinal),
                    UNIQUE (raw_snapshot_id),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id) ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE INDEX review_candidate_thread_checkpoint_lookup
                ON review_candidate_thread_checkpoint_pages (
                    account_id, organization_id, stream_id, candidate_node_id,
                    credential_revision, capability_revision, page_ordinal
                )
                """)
        },
        TriageDatabaseMigration(
            id: "051-work-item-canonical-groups-v1",
            checksum: "7e5c14941fd63d377605b07c96a19d923715a5119774120c1cb470156ee382d7"
        ) { database in
            // A Work Item keeps its own durable identity, workflow, actions,
            // and notification history even while it is represented by another
            // Work Item in a strong graph component. Reconciliation replaces
            // this complete mapping, making a later split reversible without
            // recreating donor records.
            try database.execute(sql: """
                CREATE TABLE work_item_group_memberships (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    constituent_work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
                    canonical_work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    source_revision TEXT NOT NULL CHECK (length(source_revision) = 64),
                    projected_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (constituent_work_item_id),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id) ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE INDEX work_item_group_memberships_canonical_scope
                ON work_item_group_memberships (
                    account_id, organization_id, canonical_work_item_id,
                    credential_revision, capability_revision
                )
                """)
        },
        TriageDatabaseMigration(
            id: "052-repository-ranking-preferences-v1",
            checksum: "84b477e7573f5fe89d48f412aefca3146b7794dcd3f474f2bfd59bb7fc9222bb"
        ) { database in
            // Ranking preference is deliberately account and organization
            // scoped even though repository identity is organization-owned:
            // a user may prioritize the same repository differently through
            // different connected GitHub accounts.
            try database.execute(sql: """
                CREATE TABLE repository_ranking_preferences (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
                    preference INTEGER NOT NULL CHECK (preference BETWEEN -100 AND 100),
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, organization_id, repository_id),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id) ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE INDEX repository_ranking_preferences_scope
                ON repository_ranking_preferences (account_id, organization_id, repository_id)
                """)
        },
        TriageDatabaseMigration(
            id: "053-notification-preferences-v1",
            checksum: "2be45e4714b196a094c3f8d8f68d1d1ca5490f8604c899aad50b63977b5dc690"
        ) { database in
            // Organization consent is private account-vault state. A globally
            // shared GitHub organization must never carry consent between
            // distinct local accounts.
            try database.execute(sql: """
                CREATE TABLE notification_preferences (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    is_enabled INTEGER NOT NULL CHECK (is_enabled IN (0, 1)),
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (account_id, organization_id),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id) ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE INDEX notification_preferences_scope
                ON notification_preferences (account_id, organization_id)
                """)
        },
        TriageDatabaseMigration(
            id: "054-project-item-raw-provenance-v1",
            checksum: "c1cf5a86a3ff80f0fcb47bdc1ce8e46579e62a641db686625a4f2b46863b6f2a"
        ) { database in
            // A project-items page is scoped to its project root. This map is
            // the explicit bridge that proves an individual item was present
            // on that exact raw page; it must not be inferred from current
            // normalized rows alone.
            try database.execute(sql: """
                CREATE TABLE project_item_raw_provenance (
                    project_item_node_id TEXT PRIMARY KEY
                        REFERENCES github_nodes(github_node_id) ON DELETE CASCADE,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    project_node_id TEXT NOT NULL REFERENCES projects(github_node_id) ON DELETE CASCADE,
                    raw_snapshot_id TEXT NOT NULL REFERENCES raw_api_snapshots(id) ON DELETE RESTRICT,
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    source_revision TEXT NOT NULL CHECK (length(source_revision) BETWEEN 1 AND 500),
                    observed_at_ms INTEGER NOT NULL,
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id) ON DELETE CASCADE
                )
                """)
            try database.execute(sql: """
                CREATE INDEX project_item_raw_provenance_current_scope
                ON project_item_raw_provenance (
                    account_id, organization_id, project_node_id,
                    credential_revision, capability_revision, source_revision
                )
                """)
        },
        TriageDatabaseMigration(
            id: "055-workflow-history-durable-undo-v1",
            checksum: "a72e9b9d18f7bc9424a497a4320f9d1a381425d7f4c1f1652cd007454c313147"
        ) { database in
            // The original workflow history was per-row audit data only.
            // Durable undo groups reversible local transitions by an opaque
            // transaction ID and scopes them to the encrypted account vault.
            try database.execute(sql: "ALTER TABLE workflow_history ADD COLUMN transaction_id TEXT")
            try database.execute(sql: "ALTER TABLE workflow_history ADD COLUMN account_id TEXT")
            try database.execute(sql: "ALTER TABLE workflow_history ADD COLUMN organization_id TEXT")
            try database.execute(sql: "ALTER TABLE workflow_history ADD COLUMN is_undone INTEGER NOT NULL DEFAULT 0")
            try database.execute(sql: """
                UPDATE workflow_history
                SET account_id = (
                        SELECT account_id FROM work_items
                        WHERE work_items.id = workflow_history.work_item_id
                    ),
                    organization_id = (
                        SELECT organization_id FROM work_items
                        WHERE work_items.id = workflow_history.work_item_id
                    )
                """)
            try database.execute(sql: """
                CREATE INDEX workflow_history_durable_undo_scope
                ON workflow_history (account_id, organization_id, is_undone, created_at_ms DESC, transaction_id)
                """)
        },
        TriageDatabaseMigration(
            id: "056-pull-request-status-check-authority-v1",
            checksum: "51aecb18f9132ff0d3d1f17d14c9d33df0d77b6241d0c3666877ee0a1f14d3be"
        ) { database in
            // Status check names are not globally authoritative. Bind every
            // normalized row to one current pull-request revision and source
            // scope so an older all-green rollup cannot survive a new commit.
            try database.execute(sql: "ALTER TABLE status_checks ADD COLUMN account_id TEXT NOT NULL DEFAULT ''")
            try database.execute(sql: "ALTER TABLE status_checks ADD COLUMN organization_id TEXT NOT NULL DEFAULT ''")
            try database.execute(sql: "ALTER TABLE status_checks ADD COLUMN credential_revision TEXT NOT NULL DEFAULT ''")
            try database.execute(sql: "ALTER TABLE status_checks ADD COLUMN capability_revision TEXT NOT NULL DEFAULT ''")
            try database.execute(sql: "ALTER TABLE status_checks ADD COLUMN source_revision TEXT NOT NULL DEFAULT ''")
            try database.execute(sql: "ALTER TABLE status_checks ADD COLUMN observed_at_ms INTEGER NOT NULL DEFAULT 0")
            try database.execute(sql: """
                CREATE INDEX status_checks_current_pull_request_scope
                ON status_checks (
                    github_node_id, account_id, organization_id,
                    credential_revision, capability_revision, source_revision
                )
                """)
            try database.execute(sql: """
                CREATE TABLE status_check_rollup_markers (
                    github_node_id TEXT PRIMARY KEY NOT NULL REFERENCES pull_requests(github_node_id) ON DELETE CASCADE,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    credential_revision TEXT NOT NULL,
                    capability_revision TEXT NOT NULL,
                    source_revision TEXT NOT NULL CHECK (length(source_revision) = 64 AND source_revision NOT GLOB '*[^0-9a-f]*'),
                    mergeable_state TEXT NOT NULL CHECK (mergeable_state IN ('MERGEABLE', 'CONFLICTING', 'UNKNOWN')),
                    observed_at_ms INTEGER NOT NULL,
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id) ON DELETE CASCADE
                )
                """)
        },
        TriageDatabaseMigration(
            id: "057-copilot-candidate-budget-v1",
            checksum: "1b91d9eacb16b18cbebe278e2aefae89fdc0a01eaee99d8bb31342a0bb378412"
        ) { database in
            // This is an encrypted-vault counter, not telemetry. It contains
            // only local opaque request/fingerprint keys and timing required
            // to enforce the candidate limits.
            try database.execute(sql: """
                CREATE TABLE ai_candidate_budget_attempts (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    utc_day TEXT NOT NULL CHECK (length(utc_day) = 10),
                    candidate_id TEXT NOT NULL CHECK (length(candidate_id) BETWEEN 1 AND 512),
                    source_fingerprint TEXT NOT NULL CHECK (
                        length(source_fingerprint) = 64
                        AND source_fingerprint NOT GLOB '*[^0-9a-f]*'
                    ),
                    priority INTEGER NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('leased', 'completed', 'cancelled')),
                    lease_id TEXT NOT NULL CHECK (length(lease_id) = 36),
                    started_at_ms INTEGER NOT NULL,
                    finished_at_ms INTEGER,
                    PRIMARY KEY (account_id, organization_id, utc_day, candidate_id, source_fingerprint),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE,
                    CHECK (
                        (state = 'leased' AND finished_at_ms IS NULL)
                        OR (state IN ('completed', 'cancelled') AND finished_at_ms IS NOT NULL)
                    )
                )
                """)
            try database.execute(sql: """
                CREATE INDEX ai_candidate_budget_scope_started
                ON ai_candidate_budget_attempts (
                    account_id, organization_id, utc_day, started_at_ms DESC
                )
                """)
            try database.execute(sql: """
                CREATE INDEX ai_candidate_budget_scope_active
                ON ai_candidate_budget_attempts (
                    account_id, organization_id, state, started_at_ms DESC
                )
                """)
        },
        TriageDatabaseMigration(
            id: "058-ai-action-confidence-threshold-v1",
            checksum: "d6e912d44f3aa0234d807203d5fce4d7d0322c5753156bba467ea29744251d16"
        ) { database in
            // Existing consent rows retain the product safety minimum.  The
            // encrypted row remains the sole authority for an organization's
            // user-raised automatic-action threshold.
            try database.execute(sql: """
                ALTER TABLE ai_consents
                ADD COLUMN automatic_action_confidence_threshold REAL NOT NULL
                DEFAULT 0.92
                CHECK (
                    automatic_action_confidence_threshold >= 0.92
                    AND automatic_action_confidence_threshold <= 1.0
                )
                """)
        },
        TriageDatabaseMigration(
            id: "059-pull-request-head-commit-authority-v1",
            checksum: "f2d54196288e2c0c0b1dc01b20b06bc45da27e2bfb73ab710a0114f59f311d4a"
        ) { database in
            // `updatedAt` remains node freshness only. Status-check rollups
            // are fenced by the immutable pull-request head commit.
            try database.execute(sql: """
                ALTER TABLE github_nodes
                ADD COLUMN pull_request_head_commit_sha TEXT
                CHECK (pull_request_head_commit_sha IS NULL OR (
                    length(pull_request_head_commit_sha) = 64
                    AND pull_request_head_commit_sha NOT GLOB '*[^0-9a-f]*'
                ))
                """)
        },
        TriageDatabaseMigration(
            id: "060-workspace-inbox-presentation-revision-v1",
            checksum: "47e96afd4aec1db46e8036d516ceebed62dc1f9c3fc9ce1f9aedacda70809046"
        ) { database in
            // Inbox page observation must not sort every workflow/action/
            // derived row merely to discover a local eligibility or rank
            // change. These database-owned generations are updated by the
            // same transaction as every source mutation, including writes
            // from another process using the vault.
            try database.execute(sql: """
                CREATE TABLE workspace_inbox_revisions (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0),
                    PRIMARY KEY (account_id, organization_id),
                    FOREIGN KEY (account_id, organization_id)
                        REFERENCES account_organizations(account_id, organization_id)
                        ON DELETE CASCADE
                )
                """)

            // `workflow_states`, `action_items`, and `attention_scores` are
            // work-item-owned, so their triggers recover the durable scope
            // from the owning work item. DELETE triggers run before a parent
            // cascade can remove that owning row.
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_workflow_insert
                AFTER INSERT ON workflow_states
                BEGIN
                    INSERT INTO workspace_inbox_revisions (account_id, organization_id, generation)
                    SELECT account_id, organization_id, 1 FROM work_items WHERE id = NEW.work_item_id
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_workflow_update
                AFTER UPDATE ON workflow_states
                BEGIN
                    INSERT INTO workspace_inbox_revisions (account_id, organization_id, generation)
                    SELECT account_id, organization_id, 1 FROM work_items
                    WHERE id IN (OLD.work_item_id, NEW.work_item_id)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_workflow_delete
                BEFORE DELETE ON workflow_states
                BEGIN
                    INSERT INTO workspace_inbox_revisions (account_id, organization_id, generation)
                    SELECT account_id, organization_id, 1 FROM work_items WHERE id = OLD.work_item_id
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_action_insert
                AFTER INSERT ON action_items
                BEGIN
                    INSERT INTO workspace_inbox_revisions (account_id, organization_id, generation)
                    SELECT account_id, organization_id, 1 FROM work_items WHERE id = NEW.work_item_id
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_action_update
                AFTER UPDATE ON action_items
                BEGIN
                    INSERT INTO workspace_inbox_revisions (account_id, organization_id, generation)
                    SELECT account_id, organization_id, 1 FROM work_items
                    WHERE id IN (OLD.work_item_id, NEW.work_item_id)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_action_delete
                BEFORE DELETE ON action_items
                BEGIN
                    INSERT INTO workspace_inbox_revisions (account_id, organization_id, generation)
                    SELECT account_id, organization_id, 1 FROM work_items WHERE id = OLD.work_item_id
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_score_insert
                AFTER INSERT ON attention_scores
                BEGIN
                    INSERT INTO workspace_inbox_revisions (account_id, organization_id, generation)
                    SELECT account_id, organization_id, 1 FROM work_items WHERE id = NEW.work_item_id
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_score_update
                AFTER UPDATE ON attention_scores
                BEGIN
                    INSERT INTO workspace_inbox_revisions (account_id, organization_id, generation)
                    SELECT account_id, organization_id, 1 FROM work_items
                    WHERE id IN (OLD.work_item_id, NEW.work_item_id)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_score_delete
                BEFORE DELETE ON attention_scores
                BEGIN
                    INSERT INTO workspace_inbox_revisions (account_id, organization_id, generation)
                    SELECT account_id, organization_id, 1 FROM work_items WHERE id = OLD.work_item_id
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)

            // Rule and grouping projections already carry their scope. Bump
            // both old and new scopes for a defensive primary-key/scope move.
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_rule_insert
                AFTER INSERT ON rule_evaluations
                BEGIN
                    INSERT INTO workspace_inbox_revisions VALUES (NEW.account_id, NEW.organization_id, 1)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_rule_update
                AFTER UPDATE ON rule_evaluations
                BEGIN
                    INSERT INTO workspace_inbox_revisions VALUES (OLD.account_id, OLD.organization_id, 1)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                    INSERT INTO workspace_inbox_revisions VALUES (NEW.account_id, NEW.organization_id, 1)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_rule_delete
                BEFORE DELETE ON rule_evaluations
                BEGIN
                    INSERT INTO workspace_inbox_revisions VALUES (OLD.account_id, OLD.organization_id, 1)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_rule_evidence_insert
                AFTER INSERT ON rule_evaluation_evidence
                BEGIN
                    INSERT INTO workspace_inbox_revisions (account_id, organization_id, generation)
                    SELECT account_id, organization_id, 1 FROM rule_evaluations WHERE id = NEW.rule_evaluation_id
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_rule_evidence_update
                AFTER UPDATE ON rule_evaluation_evidence
                BEGIN
                    INSERT INTO workspace_inbox_revisions (account_id, organization_id, generation)
                    SELECT account_id, organization_id, 1 FROM rule_evaluations
                    WHERE id IN (OLD.rule_evaluation_id, NEW.rule_evaluation_id)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_rule_evidence_delete
                BEFORE DELETE ON rule_evaluation_evidence
                BEGIN
                    INSERT INTO workspace_inbox_revisions (account_id, organization_id, generation)
                    SELECT account_id, organization_id, 1 FROM rule_evaluations WHERE id = OLD.rule_evaluation_id
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_group_insert
                AFTER INSERT ON work_item_group_memberships
                BEGIN
                    INSERT INTO workspace_inbox_revisions VALUES (NEW.account_id, NEW.organization_id, 1)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_group_update
                AFTER UPDATE ON work_item_group_memberships
                BEGIN
                    INSERT INTO workspace_inbox_revisions VALUES (OLD.account_id, OLD.organization_id, 1)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                    INSERT INTO workspace_inbox_revisions VALUES (NEW.account_id, NEW.organization_id, 1)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_group_delete
                BEFORE DELETE ON work_item_group_memberships
                BEGIN
                    INSERT INTO workspace_inbox_revisions VALUES (OLD.account_id, OLD.organization_id, 1)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_graph_run_insert
                AFTER INSERT ON work_item_graph_runs
                BEGIN
                    INSERT INTO workspace_inbox_revisions VALUES (NEW.account_id, NEW.organization_id, 1)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_graph_run_update
                AFTER UPDATE ON work_item_graph_runs
                BEGIN
                    INSERT INTO workspace_inbox_revisions VALUES (OLD.account_id, OLD.organization_id, 1)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                    INSERT INTO workspace_inbox_revisions VALUES (NEW.account_id, NEW.organization_id, 1)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
            try database.execute(sql: """
                CREATE TRIGGER workspace_inbox_revision_graph_run_delete
                BEFORE DELETE ON work_item_graph_runs
                BEGIN
                    INSERT INTO workspace_inbox_revisions VALUES (OLD.account_id, OLD.organization_id, 1)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET generation = generation + 1;
                END
                """)
        }
    ]
}
