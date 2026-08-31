import CryptoKit
import Foundation
import GRDB

struct DerivedIntelligenceSupplementalSource: Equatable, Sendable {
    let kind: String
    let identity: String
    let revision: String
}

enum DerivedIntelligenceSourceRevision {
    /// Preserves the original primary-source digest when no supplemental source
    /// exists, while binding every admitted supplemental authority when it does.
    nonisolated static func aggregate(
        primaryRevisions: [WorkItemID: String],
        supplementalSources: [DerivedIntelligenceSupplementalSource]
    ) -> String {
        var material = Data("triage.derived-input.source-revision.v1".utf8)
        for (workItemID, revision) in primaryRevisions.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            appendLengthPrefixed(Data(workItemID.rawValue.utf8), to: &material)
            appendLengthPrefixed(Data(revision.utf8), to: &material)
        }
        guard !supplementalSources.isEmpty else {
            return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        }
        appendLengthPrefixed(Data("supplemental-authorities-v1".utf8), to: &material)
        for source in supplementalSources.sorted(by: sourceOrder) {
            appendLengthPrefixed(Data(source.kind.utf8), to: &material)
            appendLengthPrefixed(Data(source.identity.utf8), to: &material)
            appendLengthPrefixed(Data(source.revision.utf8), to: &material)
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func supplementalSources(
        for scope: SynchronizationScope,
        in database: Database
    ) throws -> [DerivedIntelligenceSupplementalSource] {
        var result = try reviewSources(for: scope, in: database)
        result += try reviewThreadSources(for: scope, in: database)
        result += try statusCheckSources(for: scope, in: database)
        result += try projectFieldSources(for: scope, in: database)
        return result.sorted(by: sourceOrder)
    }

    private nonisolated static func reviewSources(
        for scope: SynchronizationScope,
        in database: Database
    ) throws -> [DerivedIntelligenceSupplementalSource] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT work_items.id AS work_item_id, reviews.github_node_id, review_nodes.source_revision
                FROM work_items
                JOIN reviews ON reviews.pull_request_node_id = work_items.primary_node_id
                JOIN github_nodes AS review_nodes ON review_nodes.github_node_id = reviews.github_node_id
                WHERE work_items.account_id = ? AND work_items.organization_id = ?
                  AND review_nodes.account_id = ? AND review_nodes.organization_id = ?
                ORDER BY work_items.id, reviews.github_node_id
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue
            ]
        ).map { row in
            guard let workItemID: String = row["work_item_id"],
                  let nodeID: String = row["github_node_id"],
                  let revision: String = row["source_revision"],
                  !revision.isEmpty
            else { throw DerivedIntelligenceInputAdapterError.invalidPersistedData }
            return DerivedIntelligenceSupplementalSource(
                kind: "review",
                identity: "\(workItemID)\u{0}\(nodeID)",
                revision: revision
            )
        }
    }

    private nonisolated static func reviewThreadSources(
        for scope: SynchronizationScope,
        in database: Database
    ) throws -> [DerivedIntelligenceSupplementalSource] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT work_items.id AS work_item_id, review_threads.github_node_id, thread_nodes.source_revision
                FROM work_items
                JOIN review_threads ON review_threads.pull_request_node_id = work_items.primary_node_id
                JOIN github_nodes AS thread_nodes ON thread_nodes.github_node_id = review_threads.github_node_id
                WHERE work_items.account_id = ? AND work_items.organization_id = ?
                  AND thread_nodes.account_id = ? AND thread_nodes.organization_id = ?
                ORDER BY work_items.id, review_threads.github_node_id
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue
            ]
        ).map { row in
            guard let workItemID: String = row["work_item_id"],
                  let nodeID: String = row["github_node_id"],
                  let revision: String = row["source_revision"],
                  !revision.isEmpty
            else { throw DerivedIntelligenceInputAdapterError.invalidPersistedData }
            return DerivedIntelligenceSupplementalSource(
                kind: "review-thread",
                identity: "\(workItemID)\u{0}\(nodeID)",
                revision: revision
            )
        }
    }

    private nonisolated static func projectFieldSources(
        for scope: SynchronizationScope,
        in database: Database
    ) throws -> [DerivedIntelligenceSupplementalSource] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT work_items.id AS work_item_id, project_items.github_node_id AS project_item_node_id,
                       project_field_values.field_name, project_field_values.display_value,
                       project_field_values.date_value_ms, project_field_values.actor_node_id,
                       project_item_nodes.source_revision AS project_item_revision,
                       project_nodes.source_revision AS project_revision
                FROM work_items
                JOIN project_items ON project_items.content_node_id = work_items.primary_node_id
                JOIN project_field_values
                  ON project_field_values.project_item_node_id = project_items.github_node_id
                JOIN github_nodes AS project_item_nodes
                  ON project_item_nodes.github_node_id = project_items.github_node_id
                JOIN projects ON projects.github_node_id = project_items.project_node_id
                JOIN github_nodes AS project_nodes ON project_nodes.github_node_id = projects.github_node_id
                WHERE work_items.account_id = ? AND work_items.organization_id = ?
                  AND project_item_nodes.account_id = ? AND project_item_nodes.organization_id = ?
                  AND project_nodes.account_id = ? AND project_nodes.organization_id = ?
                ORDER BY work_items.id, project_items.github_node_id, project_field_values.field_name
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue
            ]
        ).map { row in
            guard let workItemID: String = row["work_item_id"],
                  let projectItemID: String = row["project_item_node_id"],
                  let fieldName: String = row["field_name"],
                  let itemRevision: String = row["project_item_revision"],
                  let projectRevision: String = row["project_revision"],
                  !itemRevision.isEmpty, !projectRevision.isEmpty
            else { throw DerivedIntelligenceInputAdapterError.invalidPersistedData }
            let displayValue: String? = row["display_value"]
            let dateValue: Int64? = row["date_value_ms"]
            let actorNodeID: String? = row["actor_node_id"]
            let fields: [String?] = [
                itemRevision, projectRevision, fieldName,
                displayValue,
                dateValue.map { String($0) },
                actorNodeID
            ]
            return DerivedIntelligenceSupplementalSource(
                kind: "project-field",
                identity: "\(workItemID)\u{0}\(projectItemID)\u{0}\(fieldName)",
                revision: canonical(fields)
            )
        }
    }

    /// A status rollup can change without changing the pull request's own
    /// hydrated body revision. Include both the current coverage record and
    /// each revision-fenced normalized context so a derived projection cannot
    /// retain an old all-green result after a check changes or coverage drops.
    private nonisolated static func statusCheckSources(
        for scope: SynchronizationScope,
        in database: Database
    ) throws -> [DerivedIntelligenceSupplementalSource] {
        var sources = try Row.fetchAll(
            database,
            sql: """
                SELECT id, repository_id, stream_id, status, last_successful_at_ms, failure_detail
                FROM coverage_records
                WHERE account_id = ? AND organization_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                  AND feature = ?
                ORDER BY id
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                CoverageFeature.statusChecks.rawValue
            ]
        ).map { row -> DerivedIntelligenceSupplementalSource in
            guard let id: String = row["id"], let status: String = row["status"] else {
                throw DerivedIntelligenceInputAdapterError.invalidPersistedData
            }
            return .init(
                kind: "status-check-coverage",
                identity: id,
                revision: canonical([
                    row["repository_id"] as String?, row["stream_id"] as String?, status,
                    (row["last_successful_at_ms"] as Int64?).map(String.init),
                    row["failure_detail"] as String?
                ])
            )
        }
        sources += try Row.fetchAll(
            database,
            sql: """
                SELECT work_items.id AS work_item_id, status_check_rollup_markers.mergeable_state,
                       status_check_rollup_markers.source_revision,
                       status_check_rollup_markers.observed_at_ms
                FROM work_items
                JOIN github_nodes ON github_nodes.github_node_id = work_items.primary_node_id
                JOIN status_check_rollup_markers
                  ON status_check_rollup_markers.github_node_id = work_items.primary_node_id
                WHERE work_items.account_id = ? AND work_items.organization_id = ?
                  AND github_nodes.kind = 'pullRequest'
                  AND status_check_rollup_markers.account_id = ? AND status_check_rollup_markers.organization_id = ?
                  AND status_check_rollup_markers.credential_revision = ?
                  AND status_check_rollup_markers.capability_revision = ?
                  AND status_check_rollup_markers.source_revision = github_nodes.pull_request_head_commit_sha
                ORDER BY work_items.id
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue
            ]
        ).map { row -> DerivedIntelligenceSupplementalSource in
            guard let workItemID: String = row["work_item_id"],
                  let mergeable: String = row["mergeable_state"],
                  let sourceRevision: String = row["source_revision"], !sourceRevision.isEmpty,
                  let observedAt: Int64 = row["observed_at_ms"]
            else { throw DerivedIntelligenceInputAdapterError.invalidPersistedData }
            return .init(
                kind: "status-check-rollup",
                identity: workItemID,
                revision: canonical([sourceRevision, mergeable, String(observedAt)])
            )
        }
        sources += try Row.fetchAll(
            database,
            sql: """
                SELECT work_items.id AS work_item_id, status_checks.context, status_checks.state,
                       status_checks.is_required, status_checks.completed_at_ms,
                       status_checks.source_revision, status_checks.observed_at_ms
                FROM work_items
                JOIN github_nodes ON github_nodes.github_node_id = work_items.primary_node_id
                JOIN status_checks ON status_checks.github_node_id = work_items.primary_node_id
                WHERE work_items.account_id = ? AND work_items.organization_id = ?
                  AND github_nodes.kind = 'pullRequest'
                  AND status_checks.account_id = ? AND status_checks.organization_id = ?
                  AND status_checks.credential_revision = ? AND status_checks.capability_revision = ?
                  AND status_checks.source_revision = github_nodes.pull_request_head_commit_sha
                ORDER BY work_items.id, status_checks.context
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue
            ]
        ).map { row -> DerivedIntelligenceSupplementalSource in
            guard let workItemID: String = row["work_item_id"],
                  let context: String = row["context"], let state: String = row["state"],
                  let sourceRevision: String = row["source_revision"], !sourceRevision.isEmpty,
                  let observedAt: Int64 = row["observed_at_ms"]
            else { throw DerivedIntelligenceInputAdapterError.invalidPersistedData }
            return .init(
                kind: "status-check",
                identity: "\(workItemID)\u{0}\(context)",
                revision: canonical([
                    sourceRevision, state, (row["is_required"] as Bool?).map { $0 ? "1" : "0" },
                    (row["completed_at_ms"] as Int64?).map(String.init), String(observedAt)
                ])
            )
        }
        return sources
    }

    private nonisolated static func canonical(_ fields: [String?]) -> String {
        fields.map { value in
            guard let value else { return "-1:" }
            return "\(value.utf8.count):\(value)"
        }.joined(separator: "|")
    }

    private nonisolated static func sourceOrder(
        _ left: DerivedIntelligenceSupplementalSource,
        _ right: DerivedIntelligenceSupplementalSource
    ) -> Bool {
        if left.kind != right.kind { return left.kind < right.kind }
        if left.identity != right.identity { return left.identity < right.identity }
        return left.revision < right.revision
    }

    private nonisolated static func appendLengthPrefixed(_ value: Data, to material: inout Data) {
        var length = UInt64(value.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }
        material.append(value)
    }
}
