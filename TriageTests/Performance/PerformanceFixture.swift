import Foundation
import GRDB
@testable import Triage

/// The production-scale fixture described in IMPLEMENTATION_PLAN §24.
///
/// Values are intentionally source-controlled instead of being inferred from
/// the current database. This makes capacity regressions reviewable and lets
/// the generated data remain private, deterministic, and reproducible.
enum PerformanceFixtureScale {
    static let workItems = 10_000
    static let timelineEvents = 100_000
    static let repositories = 250
    static let projects = 50
    static let projectItems = 10_000
    static let discussions = 5_000
    static let discussionReplies = 5_000
    static let searchableComments = 25_000
    static let actionableItems = 500
    static let batchSize = 256
}

/// Deliberate upper bounds for the benchmark's representative read paths.
/// These stay separate from timing assertions so ordinary tests can protect
/// query shape without relying on wall-clock observations.
enum PerformanceFixtureQueryShape {
    static let workspacePageLimit = 50
    static let inboxPageLimit = 50
    static let searchPageLimit = 50
    static let timelinePageLimit = 100
    static let commentPageLimit = 32
}

enum PerformanceFixtureRecordKind: CaseIterable, Hashable {
    case repository
    case workItem
    case timelineEvent
    case project
    case projectItem
    case discussion
    case discussionReply
    case searchableComment
    case actionableItem

    var count: Int {
        switch self {
        case .repository: PerformanceFixtureScale.repositories
        case .workItem: PerformanceFixtureScale.workItems
        case .timelineEvent: PerformanceFixtureScale.timelineEvents
        case .project: PerformanceFixtureScale.projects
        case .projectItem: PerformanceFixtureScale.projectItems
        case .discussion: PerformanceFixtureScale.discussions
        case .discussionReply: PerformanceFixtureScale.discussionReplies
        case .searchableComment: PerformanceFixtureScale.searchableComments
        case .actionableItem: PerformanceFixtureScale.actionableItems
        }
    }

    var prefix: String {
        switch self {
        case .repository: "repository"
        case .workItem: "work-item"
        case .timelineEvent: "timeline-event"
        case .project: "project"
        case .projectItem: "project-item"
        case .discussion: "discussion"
        case .discussionReply: "discussion-reply"
        case .searchableComment: "comment"
        case .actionableItem: "action"
        }
    }
}

struct PerformanceFixtureRecord: Equatable {
    let kind: PerformanceFixtureRecordKind
    let ordinal: Int

    var identifier: String { "\(kind.prefix)-\(ordinal)" }
}

/// Streams fixture records in bounded batches. It intentionally never builds a
/// 100k-event array, so fixture generation exercises the memory discipline the
/// benchmark is meant to protect.
struct PerformanceFixtureGenerator {
    func batches(
        maximumBatchSize: Int = PerformanceFixtureScale.batchSize
    ) -> AnySequence<[PerformanceFixtureRecord]> {
        precondition(maximumBatchSize > 0)

        return AnySequence {
            var kindIndex = 0
            var ordinal = 0
            return AnyIterator {
                while kindIndex < PerformanceFixtureRecordKind.allCases.count {
                    let kind = PerformanceFixtureRecordKind.allCases[kindIndex]
                    guard ordinal < kind.count else {
                        kindIndex += 1
                        ordinal = 0
                        continue
                    }
                    let upperBound = min(ordinal + maximumBatchSize, kind.count)
                    let batch = (ordinal..<upperBound).map { index in
                        PerformanceFixtureRecord(kind: kind, ordinal: index)
                    }
                    ordinal = upperBound
                    return batch
                }
                return nil
            }
        }
    }

    func countByKind() -> [PerformanceFixtureRecordKind: Int] {
        var result = Dictionary(uniqueKeysWithValues: PerformanceFixtureRecordKind.allCases.map { ($0, 0) })
        for batch in batches() {
            for record in batch {
                result[record.kind, default: 0] += 1
            }
        }
        return result
    }

    /// A stable, non-cryptographic checksum for fixture shape. It is not used
    /// for security; it makes accidental generator changes conspicuous in a
    /// lightweight normal test.
    func shapeChecksum() -> UInt64 {
        var value: UInt64 = 1_469_598_103_934_665_603
        for batch in batches() {
            for byte in recordBytes(batch) {
                value ^= UInt64(byte)
                value &*= 1_099_511_628_211
            }
        }
        return value
    }

    private func recordBytes(_ batch: [PerformanceFixtureRecord]) -> [UInt8] {
        batch.flatMap { record in
            Array("\(record.kind.prefix):\(record.ordinal)\n".utf8)
        }
    }
}

/// A disposable encrypted-vault fixture used only by the opt-in benchmark. It
/// keeps each insert bounded and uses the same SQLCipher configuration,
/// migrations, and query surfaces as the app without adding benchmark code to
/// the production target.
final class PerformanceFixtureStore: @unchecked Sendable {
    let directory: URL
    let vault: AccountVault

    let accountID = "performance-account"
    let organizationID = "performance-organization"
    private let scope = SynchronizationScope(
        accountID: AccountID(rawValue: "performance-account")!,
        organizationID: OrganizationID(rawValue: "performance-organization")!,
        credentialRevision: CredentialRevision(rawValue: "performance-revision")!,
        capabilityRevision: CapabilityRevision(rawValue: "performance-capability")!
    )

    init() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-performance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // This fixed value is a fixture input, not a persisted credential. The
        // enclosing temporary directory is removed after every benchmark run.
        let fixtureKey = try VaultKey(data: Data((0..<VaultKey.byteCount).map(UInt8.init)))
        let fixtureAccountID = AccountID(rawValue: "00000000-0000-4000-8000-000000000024")!
        vault = try AccountVault(
            accountID: fixtureAccountID,
            vaultKey: fixtureKey,
            rootDirectory: directory
        )
        try await vault.applyMigrations()
        try await vault.write(seedIdentity)
    }

    func close() async {
        try? await vault.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func seed() async throws {
        try await vault.write { database in
            try seedRepositories(database)
            try seedWorkItems(database)
            try seedProjects(database)
            try seedDiscussions(database)
            try seedComments(database)
            try seedTimeline(database)
            try seedSearchDocuments(database)
        }
    }

    func recordCounts() async throws -> [String: Int] {
        try await vault.read { database in
            try [
                "repositories": Int.fetchOne(database, sql: "SELECT COUNT(*) FROM repositories") ?? 0,
                "work_items": Int.fetchOne(database, sql: "SELECT COUNT(*) FROM work_items") ?? 0,
                "timeline_events": Int.fetchOne(database, sql: "SELECT COUNT(*) FROM timeline_events") ?? 0,
                "projects": Int.fetchOne(database, sql: "SELECT COUNT(*) FROM projects") ?? 0,
                "project_items": Int.fetchOne(database, sql: "SELECT COUNT(*) FROM project_items") ?? 0,
                "discussions": Int.fetchOne(database, sql: "SELECT COUNT(*) FROM discussions") ?? 0,
                "discussion_replies": Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM comments WHERE kind = 'discussionReply'"
                ) ?? 0,
                "searchable_comments": Int.fetchOne(database, sql: "SELECT COUNT(*) FROM comments") ?? 0,
                "actionable_items": Int.fetchOne(database, sql: "SELECT COUNT(*) FROM action_items") ?? 0
            ]
        }
    }

    /// Exercises the production compact workspace-observation pipeline. This
    /// is the read that gives a cached account/organization switch its first
    /// coherent presentation, rather than a benchmark-only SQL approximation.
    func cachedWorkspaceSnapshot() async throws -> Int {
        let service = WorkspaceDatabaseObservationService(
            bridge: await vault.workspaceObservationBridge()
        )
        let values = service.values(for: scope, selectedWorkItemID: nil)
        for try await snapshot in values {
            return snapshot.workItems.count
        }
        throw CancellationError()
    }

    /// The native Inbox is derived from the full production work-item graph.
    /// There is no paged Inbox repository yet, so retain the production graph
    /// contract and its local eligibility rule instead of issuing private SQL.
    func inboxFirstPage() async throws -> Int {
        let workItems = try await workItems()
        return workItems.lazy
            .filter { InboxEligibilityRule().disposition(for: $0, at: .now) == .inbox }
            .prefix(PerformanceFixtureQueryShape.inboxPageLimit)
            .count
    }

    func searchFirstPage() async throws -> Int {
        try await SearchRepository(vault: vault).search(
            "benchmark",
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            limit: PerformanceFixtureQueryShape.searchPageLimit
        ).count
    }

    /// Detail views load the selected item's authoritative local source and a
    /// bounded timeline page through the production detail repository.
    func detailInitialPresentation() async throws -> Int {
        let workItems = try await workItems()
        guard let item = workItems.first(where: { $0.id.rawValue == workItemID(0) }) else {
            throw PerformanceFixtureError.missingSelectedWorkItem
        }
        let repository = WorkDetailRepository(vault: vault)
        async let source = repository.source(for: item)
        async let timeline = repository.timelinePage(
            for: item,
            after: nil,
            limit: PerformanceFixtureQueryShape.timelinePageLimit
        )
        let (resolvedSource, resolvedTimeline) = try await (source, timeline)
        return (resolvedSource?.bodyMarkdown?.utf8.count ?? 0) + resolvedTimeline.entries.count
    }

    private func workItems() async throws -> [WorkItem] {
        try await WorkItemRepository(vault: vault).fetch(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            authorityScope: scope
        )
    }

    private func seedIdentity(_ database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO accounts (
                    id, github_user_id, github_node_id, login, display_name, avatar_url,
                    authentication_kind, credential_id, credential_status, credential_revision,
                    created_at_ms, last_validated_at_ms, disabled_at_ms
                ) VALUES (?, '1', 'performance-account-node', 'performance', NULL, NULL,
                          'oauth', 'performance-credential', 'active', 'performance-revision',
                          1, 1, NULL)
                """,
            arguments: [accountID]
        )
        try database.execute(
            sql: """
                INSERT INTO organizations (
                    id, github_organization_id, github_node_id, login, display_name, avatar_url, updated_at_ms
                ) VALUES (?, '2', 'performance-organization-node', 'performance-org', NULL, NULL, 1)
                """,
            arguments: [organizationID]
        )
        try database.execute(
            sql: """
                INSERT INTO account_organizations (
                    account_id, organization_id, access_state, capability_revision, selected_at_ms, checked_at_ms
                ) VALUES (?, ?, 'available', 'performance-capability', 1, 1)
                """,
            arguments: [accountID, organizationID]
        )
    }

    private func seedRepositories(_ database: Database) throws {
        for index in 0..<PerformanceFixtureScale.repositories {
            let id = repositoryID(index)
            try database.execute(
                sql: """
                    INSERT INTO repositories (
                        id, organization_id, github_repository_id, github_node_id, owner_login, name,
                        is_private, is_archived, has_discussions, html_url, updated_at_ms, archived_at_ms
                    ) VALUES (?, ?, ?, ?, 'performance-org', ?, 1, 0, 1, ?, ?, NULL)
                    """,
                arguments: [
                    id, organizationID, "repository-number-\(index)", "repository-node-\(index)",
                    "repository-\(index)", "https://example.invalid/repositories/\(index)", Int64(index)
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_repository_access (account_id, repository_id, access_state, observed_at_ms)
                    VALUES (?, ?, 'available', ?)
                    """,
                arguments: [accountID, id, Int64(index)]
            )
        }
    }

    private func seedWorkItems(_ database: Database) throws {
        for index in 0..<PerformanceFixtureScale.workItems {
            let nodeID = workNodeID(index)
            let workID = workItemID(index)
            try insertNode(
                id: nodeID,
                repositoryID: repositoryID(index % PerformanceFixtureScale.repositories),
                kind: "pullRequest",
                title: "Benchmark work item \(index)",
                body: "benchmark searchable cached work item \(index)",
                updatedAt: Int64(index),
                into: database
            )
            try database.execute(
                sql: """
                    INSERT INTO pull_requests (
                        github_node_id, is_draft, mergeable_state, head_ref, base_ref,
                        review_decision, unresolved_thread_count, latest_commit_at_ms, updated_at_ms
                    ) VALUES (?, 0, NULL, NULL, NULL, NULL, 0, NULL, ?)
                    """,
                arguments: [nodeID, Int64(index)]
            )
            try database.execute(
                sql: """
                    INSERT INTO work_items (
                        id, account_id, organization_id, primary_node_id, state,
                        last_relevant_activity_at_ms, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, 'active', ?, ?, ?)
                    """,
                arguments: [workID, accountID, organizationID, nodeID, Int64(index), Int64(index), Int64(index)]
            )
            try database.execute(
                sql: """
                    INSERT INTO workflow_states (
                        work_item_id, status, pinned, priority, snoozed_until_ms, follow_up_at_ms, local_note, updated_at_ms
                    ) VALUES (?, 'active', 0, 0, NULL, NULL, NULL, ?)
                    """,
                arguments: [workID, Int64(index)]
            )
            if index < PerformanceFixtureScale.actionableItems {
                try database.execute(
                    sql: """
                        INSERT INTO attention_reasons (
                            id, work_item_id, rule_id, rule_version, category, strength,
                            title, explanation, evaluated_at_ms
                        ) VALUES (?, ?, 'assigned', 1, 'directResponsibility', 100,
                                  'Benchmark action', 'Deterministic benchmark action.', ?)
                        """,
                    arguments: ["reason-\(index)", workID, Int64(index)]
                )
                try database.execute(
                    sql: """
                        INSERT INTO action_items (
                            id, work_item_id, title, detail, origin, state, priority,
                            due_at_ms, source_fingerprint, created_at_ms, updated_at_ms,
                            completed_at_ms, dismissed_at_ms
                        ) VALUES (?, ?, 'Benchmark action', NULL, 'manual', 'open', 2,
                                  NULL, NULL, ?, ?, NULL, NULL)
                        """,
                    arguments: ["action-\(index)", workID, Int64(index), Int64(index)]
                )
            }
        }
    }

    private func seedProjects(_ database: Database) throws {
        for index in 0..<PerformanceFixtureScale.projects {
            let nodeID = "project-node-\(index)"
            try insertNode(
                id: nodeID,
                repositoryID: nil,
                kind: "projectV2",
                title: "Benchmark project \(index)",
                body: nil,
                updatedAt: Int64(index),
                into: database
            )
            try database.execute(
                sql: """
                    INSERT INTO projects (github_node_id, organization_id, number, title, state, updated_at_ms)
                    VALUES (?, ?, ?, ?, 'OPEN', ?)
                    """,
                arguments: [nodeID, organizationID, index + 1, "Benchmark project \(index)", Int64(index)]
            )
        }
        for index in 0..<PerformanceFixtureScale.projectItems {
            let nodeID = "project-item-node-\(index)"
            try insertNode(
                id: nodeID,
                repositoryID: nil,
                kind: "projectV2Item",
                title: "Benchmark project item \(index)",
                body: nil,
                updatedAt: Int64(index),
                into: database
            )
            try database.execute(
                sql: """
                    INSERT INTO project_items (
                        github_node_id, project_node_id, content_node_id, content_kind, updated_at_ms
                    ) VALUES (?, ?, ?, 'pullRequest', ?)
                    """,
                arguments: [
                    nodeID, "project-node-\(index % PerformanceFixtureScale.projects)",
                    workNodeID(index % PerformanceFixtureScale.workItems), Int64(index)
                ]
            )
        }
    }

    private func seedDiscussions(_ database: Database) throws {
        for index in 0..<PerformanceFixtureScale.discussions {
            let nodeID = discussionNodeID(index)
            try insertNode(
                id: nodeID,
                repositoryID: repositoryID(index % PerformanceFixtureScale.repositories),
                kind: "discussion",
                title: "Benchmark discussion \(index)",
                body: "benchmark discussion body \(index)",
                updatedAt: Int64(index),
                into: database
            )
            try database.execute(
                sql: """
                    INSERT INTO discussions (
                        github_node_id, category_name, answer_comment_node_id, comments_count, updated_at_ms
                    ) VALUES (?, 'General', NULL, 1, ?)
                    """,
                arguments: [nodeID, Int64(index)]
            )
        }
    }

    private func seedComments(_ database: Database) throws {
        for index in 0..<PerformanceFixtureScale.searchableComments {
            let isReply = index < PerformanceFixtureScale.discussionReplies
            let nodeID = "comment-node-\(index)"
            let parentID = isReply
                ? discussionNodeID(index)
                : workNodeID(index % PerformanceFixtureScale.workItems)
            let kind = isReply ? "discussionReply" : "issueComment"
            try insertNode(
                id: nodeID,
                repositoryID: nil,
                kind: kind,
                title: "Benchmark comment \(index)",
                body: "benchmark searchable comment \(index)",
                updatedAt: Int64(index),
                into: database
            )
            try database.execute(
                sql: """
                    INSERT INTO comments (
                        github_node_id, parent_node_id, author_id, kind, body_markdown,
                        created_at_ms, updated_at_ms, html_url
                    ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    nodeID, parentID, kind, "benchmark searchable comment \(index)",
                    Int64(index), Int64(index), "https://example.invalid/comments/\(index)"
                ]
            )
        }
    }

    private func seedTimeline(_ database: Database) throws {
        for index in 0..<PerformanceFixtureScale.timelineEvents {
            let subjectNodeID = workNodeID(index % PerformanceFixtureScale.workItems)
            let occurredAt = Date(timeIntervalSince1970: TimeInterval(index) / 1_000)
            let event = TimelineEventSummary(
                id: GitHubEventID(rawValue: "timeline-event-\(index)")!,
                subjectNodeID: GitHubNodeID(rawValue: subjectNodeID)!,
                kind: .commented,
                actor: nil,
                occurredAt: occurredAt,
                url: nil,
                body: "Benchmark timeline event \(index)"
            )
            try database.execute(
                sql: """
                    INSERT INTO timeline_events (
                        github_event_id, subject_node_id, actor_id, kind, occurred_at_ms, payload_json, source_revision
                    ) VALUES (?, ?, NULL, 'commented', ?, ?, 'performance')
                    """,
                arguments: [
                    event.id.rawValue, subjectNodeID, Int64(index), try JSONEncoder().encode(event)
                ]
            )
        }
    }

    private func seedSearchDocuments(_ database: Database) throws {
        for index in 0..<PerformanceFixtureScale.workItems {
            try database.execute(
                sql: """
                    INSERT INTO search_documents (
                        title, body, repository, labels, people, project_values, action_text, local_note
                    ) VALUES (?, ?, ?, '', '', '', '', '')
                    """,
                arguments: [
                    "Benchmark work item \(index)", "benchmark searchable work item \(index)",
                    "performance-org/repository-\(index % PerformanceFixtureScale.repositories)"
                ]
            )
            let documentID = database.lastInsertedRowID
            try database.execute(
                sql: """
                    INSERT INTO search_document_metadata (
                        id, account_id, organization_id, work_item_id, github_node_id, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [documentID, accountID, organizationID, workItemID(index), workNodeID(index), Int64(index)]
            )
        }
    }

    private func insertNode(
        id: String,
        repositoryID: String?,
        kind: String,
        title: String,
        body: String?,
        updatedAt: Int64,
        into database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO github_nodes (
                    github_node_id, account_id, organization_id, repository_id,
                    kind, numeric_id, number, title, state, html_url, body_markdown,
                    author_id, created_at_ms, updated_at_ms, closed_at_ms, merged_at_ms,
                    source_revision, last_observed_at_ms, accessibility_state
                ) VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, 'open', ?, ?,
                          NULL, ?, ?, NULL, NULL, 'performance', ?, 'accessible')
                """,
            arguments: [
                id, accountID, organizationID, repositoryID, kind, title,
                "https://example.invalid/\(id)", body, updatedAt, updatedAt, updatedAt
            ]
        )
    }

    private func repositoryID(_ index: Int) -> String { "repository-\(index)" }
    private func workItemID(_ index: Int) -> String { "work-item-\(index)" }
    private func workNodeID(_ index: Int) -> String { "work-node-\(index)" }
    private func discussionNodeID(_ index: Int) -> String { "discussion-node-\(index)" }
}

private enum PerformanceFixtureError: Error {
    case missingSelectedWorkItem
}
