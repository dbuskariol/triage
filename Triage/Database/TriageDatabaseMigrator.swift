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
    static var migrationCount: Int { migrations.count }

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
        }
    ]
}
