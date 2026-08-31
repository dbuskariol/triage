import Foundation
import GRDB

enum CoverageRequirementProfileError: Error, Equatable, Sendable {
    case invalidPersistedTopology
    case duplicateRequirement
    case tooManyRequirements
}

/// Builds the exact coverage topology expected from the currently integrated
/// organization refresh pipeline.
///
/// The profile is assembled only inside the encrypted finalization transaction.
/// Static roots ensure that an omitted source can never disappear merely because
/// it wrote no coverage. Dynamic leaves come from authoritative repository and
/// project inventories. Hydration leaves are diagnostic additions to mandatory
/// aggregate requirements because hydration candidates are not independently
/// persisted yet.
enum CoverageRequirementProfile {
    static let maximumRequirementCount = 20_000

    nonisolated static func build(
        for scope: SynchronizationScope,
        coverage: [CoverageRecord],
        in database: Database,
        maximumRequirementCount: Int = Self.maximumRequirementCount
    ) throws -> [CoverageRequirement] {
        guard (0...Self.maximumRequirementCount).contains(maximumRequirementCount),
              coverage.count <= maximumRequirementCount
        else {
            throw CoverageRequirementProfileError.tooManyRequirements
        }
        guard coverage.allSatisfy({
            $0.accountID == scope.accountID
                && $0.organizationID == scope.organizationID
                && $0.credentialRevision == scope.credentialRevision
                && $0.capabilityRevision == scope.capabilityRevision
        }) else {
            throw CoverageRequirementProfileError.invalidPersistedTopology
        }

        let organization = scope.organizationID.rawValue
        let roleRoot = SyncStreamID(rawValue: "role-discovery-\(organization)")!
        let roleInterval = latestInterval(
            feature: .roleDiscovery,
            repositoryID: nil,
            streamID: roleRoot,
            in: coverage
        )
        var requirements: [CoverageRequirement] = []
        var identities: Set<String> = []
        func append(_ requirement: CoverageRequirement) throws {
            guard requirements.count < maximumRequirementCount else {
                throw CoverageRequirementProfileError.tooManyRequirements
            }
            guard identities.insert(identity(requirement)).inserted else {
                throw CoverageRequirementProfileError.duplicateRequirement
            }
            requirements.append(requirement)
        }

        for staticRequirement in [
            requirement(.repositories, stream: "inventory-repositories-\(organization)"),
            requirement(.teams, stream: "inventory-teams-\(organization)"),
            requirement(.issues, stream: "hydration-issues-\(organization)"),
            requirement(.pullRequests, stream: "hydration-pull-requests-\(organization)"),
            requirement(.reviews, stream: "pull-request-reviews-\(organization)"),
            requirement(.reviewThreads, stream: "pull-request-review-threads-\(organization)"),
            requirement(.statusChecks, stream: "pull-request-status-checks-\(organization)"),
            requirement(.timelines, stream: "timelines-\(organization)"),
            requirement(
                .discussions,
                stream: "discussions-\(organization)",
                interval: latestInterval(
                    feature: .discussions,
                    repositoryID: nil,
                    streamID: SyncStreamID(rawValue: "discussions-\(organization)")!,
                    in: coverage
                )
            ),
            requirement(
                .discussionComments,
                stream: "discussion-comments-\(organization)",
                interval: latestInterval(
                    feature: .discussionComments,
                    repositoryID: nil,
                    streamID: SyncStreamID(rawValue: "discussion-comments-\(organization)")!,
                    in: coverage
                )
            ),
            requirement(
                .discussionReplies,
                stream: "discussion-replies-\(organization)",
                interval: latestInterval(
                    feature: .discussionReplies,
                    repositoryID: nil,
                    streamID: SyncStreamID(rawValue: "discussion-replies-\(organization)")!,
                    in: coverage
                )
            ),
            requirement(
                .projects,
                stream: "projects-v2-inventory-\(organization)",
                interval: latestInterval(
                    feature: .projects,
                    repositoryID: nil,
                    streamID: SyncStreamID(rawValue: "projects-v2-inventory-\(organization)")!,
                    in: coverage
                )
            ),
            requirement(
                .projectItems,
                stream: "projects-v2-items-\(organization)",
                interval: latestInterval(
                    feature: .projectItems,
                    repositoryID: nil,
                    streamID: SyncStreamID(rawValue: "projects-v2-items-\(organization)")!,
                    in: coverage
                )
            ),
            CoverageRequirement(
                feature: .roleDiscovery,
                repositoryID: nil,
                streamID: roleRoot,
                intervalStart: roleInterval?.start,
                intervalEnd: roleInterval?.end
            )
        ] {
            try append(staticRequirement)
        }

        for kind in RoleDiscoveryStreamKind.allCases {
            try append(CoverageRequirement(
                feature: .roleDiscovery,
                repositoryID: nil,
                streamID: SyncStreamID(rawValue: "\(roleRoot.rawValue)-\(kind.rawValue)")!,
                intervalStart: roleInterval?.start,
                intervalEnd: roleInterval?.end
            ))
        }

        let maximumRepositoryCount = (maximumRequirementCount - requirements.count) / 5
        let repositoryIDs = try knownRepositoryIDs(
            for: scope,
            maximumCount: maximumRepositoryCount,
            in: database
        )
        for repositoryID in repositoryIDs {
            for repositoryRequirement in [
                requirement(
                    .repositories,
                    repositoryID: repositoryID,
                    stream: "inventory-repositories-\(organization)"
                ),
                requirement(
                    .timelines,
                    repositoryID: repositoryID,
                    stream: "timelines-\(organization)-\(repositoryID.rawValue)"
                ),
                intervalRequirement(
                    .discussions,
                    repositoryID: repositoryID,
                    stream: "discussions-\(organization)-\(repositoryID.rawValue)",
                    coverage: coverage
                ),
                intervalRequirement(
                    .discussionComments,
                    repositoryID: repositoryID,
                    stream: "discussion-comments-\(organization)-\(repositoryID.rawValue)",
                    coverage: coverage
                ),
                intervalRequirement(
                    .discussionReplies,
                    repositoryID: repositoryID,
                    stream: "discussion-replies-\(organization)-\(repositoryID.rawValue)",
                    coverage: coverage
                )
            ] {
                try append(repositoryRequirement)
            }
        }

        for projectID in try projectIDs(
            for: scope,
            maximumCount: maximumRequirementCount - requirements.count,
            in: database
        ) {
            try append(intervalRequirement(
                .projectItems,
                repositoryID: nil,
                stream: "projects-v2-items-\(organization)-\(projectID.rawValue)",
                coverage: coverage
            ))
        }

        for record in coverage {
            guard (record.feature == .issues || record.feature == .pullRequests),
                  record.repositoryID != nil,
                  record.streamID.rawValue.hasPrefix("hydration-"),
                  record.intervalStart == nil,
                  record.intervalEnd == nil
            else {
                continue
            }
            try append(CoverageRequirement(
                feature: record.feature,
                repositoryID: record.repositoryID,
                streamID: record.streamID
            ))
        }

        return requirements.sorted { identity($0) < identity($1) }
    }

    private struct Interval: Sendable {
        let start: Date
        let end: Date
    }

    private nonisolated static func latestInterval(
        feature: CoverageFeature,
        repositoryID: RepositoryID?,
        streamID: SyncStreamID,
        in coverage: [CoverageRecord]
    ) -> Interval? {
        coverage.compactMap { record -> Interval? in
            guard record.feature == feature,
                  record.repositoryID == repositoryID,
                  record.streamID == streamID,
                  let start = record.intervalStart,
                  let end = record.intervalEnd
            else {
                return nil
            }
            return Interval(start: start, end: end)
        }.max {
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.start < $1.start
        }
    }

    private nonisolated static func requirement(
        _ feature: CoverageFeature,
        repositoryID: RepositoryID? = nil,
        stream: String,
        interval: Interval? = nil
    ) -> CoverageRequirement {
        CoverageRequirement(
            feature: feature,
            repositoryID: repositoryID,
            streamID: SyncStreamID(rawValue: stream)!,
            intervalStart: interval?.start,
            intervalEnd: interval?.end
        )
    }

    private nonisolated static func intervalRequirement(
        _ feature: CoverageFeature,
        repositoryID: RepositoryID?,
        stream: String,
        coverage: [CoverageRecord]
    ) -> CoverageRequirement {
        let streamID = SyncStreamID(rawValue: stream)!
        return requirement(
            feature,
            repositoryID: repositoryID,
            stream: stream,
            interval: latestInterval(
                feature: feature,
                repositoryID: repositoryID,
                streamID: streamID,
                in: coverage
            )
        )
    }

    /// Includes retained non-available topology. Candidate scheduling may use
    /// only `available`, but a permission change must not make known private
    /// sources disappear from the completeness contract.
    private nonisolated static func knownRepositoryIDs(
        for scope: SynchronizationScope,
        maximumCount: Int,
        in database: Database
    ) throws -> [RepositoryID] {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT repositories.id, account_repository_access.access_state
                FROM repositories
                JOIN account_repository_access
                  ON account_repository_access.repository_id = repositories.id
                WHERE repositories.organization_id = ?
                  AND account_repository_access.account_id = ?
                ORDER BY repositories.id
                LIMIT ?
                """,
            arguments: [
                scope.organizationID.rawValue,
                scope.accountID.rawValue,
                maximumCount + 1
            ]
        )
        guard rows.count <= maximumCount else {
            throw CoverageRequirementProfileError.tooManyRequirements
        }
        return try rows.map { row in
            guard let repositoryID = RepositoryID(rawValue: row["id"]),
                  let rawAccessState: String = row["access_state"],
                  RepositoryAccessState(rawValue: rawAccessState) != nil
            else {
                throw CoverageRequirementProfileError.invalidPersistedTopology
            }
            return repositoryID
        }
    }

    private nonisolated static func projectIDs(
        for scope: SynchronizationScope,
        maximumCount: Int,
        in database: Database
    ) throws -> [GitHubNodeID] {
        let identifiers = try String.fetchAll(
            database,
            sql: """
                SELECT projects.github_node_id
                FROM projects
                JOIN github_nodes
                  ON github_nodes.github_node_id = projects.github_node_id
                WHERE projects.organization_id = ?
                  AND github_nodes.account_id = ?
                  AND github_nodes.organization_id = ?
                  AND github_nodes.kind = ?
                ORDER BY projects.github_node_id
                LIMIT ?
                """,
            arguments: [
                scope.organizationID.rawValue,
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                GitHubContentKind.project.rawValue,
                maximumCount + 1
            ]
        )
        guard identifiers.count <= maximumCount else {
            throw CoverageRequirementProfileError.tooManyRequirements
        }
        return try identifiers.map {
            guard let projectID = GitHubNodeID(rawValue: $0) else {
                throw CoverageRequirementProfileError.invalidPersistedTopology
            }
            return projectID
        }
    }

    private nonisolated static func identity(_ requirement: CoverageRequirement) -> String {
        let fields: [String] = [
            requirement.feature.rawValue,
            requirement.repositoryID?.rawValue ?? "",
            requirement.streamID.rawValue,
            requirement.intervalStart.map(milliseconds).map(String.init) ?? "",
            requirement.intervalEnd.map(milliseconds).map(String.init) ?? ""
        ]
        return fields.map { field in
            String(field.utf8.count) + ":" + field
        }.joined(separator: "|")
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
