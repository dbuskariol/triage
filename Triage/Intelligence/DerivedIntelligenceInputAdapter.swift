import Foundation
import GRDB

/// The visibility of a source contribution to a derived-intelligence input.
///
/// This is deliberately separate from `CoverageStatus`: it describes whether
/// a particular contribution was admitted into a point-in-time input snapshot.
/// A missing or partial source is never represented as a trusted empty array.
enum DerivedIntelligenceSourceAvailability: Equatable, Sendable {
    case trusted
    case provisional
    case excluded
}

struct DerivedIntelligenceSourceState: Equatable, Sendable {
    let workItemID: WorkItemID
    let feature: CoverageFeature
    let availability: DerivedIntelligenceSourceAvailability
}

/// A database-free, Sendable hand-off from normalized storage to the pure
/// derived-intelligence coordinator. Its provisional state is derived from the
/// input so the coordinator, persistence, and presentation layers cannot
/// disagree about whether AI work is eligible.
struct DerivedIntelligenceInputSnapshot: Sendable {
    let input: DerivedIntelligenceInput
    let sourceStates: [DerivedIntelligenceSourceState]
    let sourceRevisions: [WorkItemID: String]
    /// Stable SHA-256 digest of primary and scoped supplemental source
    /// authorities, suitable for binding a durable derived projection.
    let aggregateSourceRevision: String

    /// The exact normalized-source authority that an observation owner must
    /// compare with its durable derived run before publishing a projection.
    let publicationMarker: DerivedIntelligenceSourceRevisionMarker

    var isProvisional: Bool { input.isProvisional }
}

/// Revision-qualified hand-off for consumers that publish derived results.
/// It intentionally contains no database handle or observation state: the
/// owner can compare it with its observed durable run and suppress stale
/// publication without recomputing presentation data.
struct DerivedIntelligenceSourceRevisionMarker: Equatable, Sendable {
    let scope: SynchronizationScope
    let sourceRevision: String
}

enum DerivedIntelligenceInputAdapterError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case staleSynchronizationScope
    case invalidEvaluationDate
    case invalidPersistedData
    case sourceChangedDuringRead
}

/// Builds a revision-qualified derived input without exposing GRDB, a vault,
/// or any repository handle to presentation code. It uses a read/check/read
/// fence around `WorkItemRepository` because that repository is intentionally
/// the sole decoder of the complete work-item graph.
actor DerivedIntelligenceInputAdapter {
    private let vault: AccountVault
    private let workItems: WorkItemRepository
    private let aiAnalysis: AIAnalysisRepository
    private let repositoryRankingPreferences: RepositoryRankingPreferenceRepository

    init(vault: AccountVault) {
        self.vault = vault
        self.workItems = WorkItemRepository(vault: vault)
        self.aiAnalysis = AIAnalysisRepository(vault: vault)
        self.repositoryRankingPreferences = RepositoryRankingPreferenceRepository(vault: vault)
    }

    func snapshot(
        for scope: SynchronizationScope,
        aiPolicy: DerivedAIPolicy,
        evaluatedAt: Date = .now,
        businessDayPolicy: BusinessDayPolicy = .init(),
        calendar: Calendar = .current
    ) async throws -> DerivedIntelligenceInputSnapshot {
        guard scope.accountID == vault.accountID else {
            throw DerivedIntelligenceInputAdapterError.accountScopeMismatch
        }
        guard evaluatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DerivedIntelligenceInputAdapterError.invalidEvaluationDate
        }

        let before = try await fence(for: scope, evaluatedAt: evaluatedAt)
        let persistedWorkItems = try await workItems.fetch(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            authorityScope: scope
        )
        let after = try await fence(for: scope, evaluatedAt: evaluatedAt)
        guard before == after,
              persistedWorkItems.count == after.primarySources.count,
              zip(persistedWorkItems.sorted { $0.id.rawValue < $1.id.rawValue }, after.primarySources).allSatisfy({
                  $0.id == $1.workItemID && $0.primaryNodeID == $1.nodeID
              })
        else {
            throw DerivedIntelligenceInputAdapterError.sourceChangedDuringRead
        }

        let fullCoverage = CoverageEvaluator().evaluate(
            requirements: after.coverageRequirements,
            records: after.coverageRecords,
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision
        )
        let support = try await supplementalData(
            scope: scope,
            workItems: persistedWorkItems,
            fence: after
        )
        let repositoryPreferences = try await repositoryRankingPreferences.preferences(for: scope)
        // Supplemental timeline, review, thread, and project reads occur in a
        // separate vault read. Re-fence afterward so a normalized commit or
        // authority rotation cannot publish a mixed input snapshot.
        let final = try await fence(for: scope, evaluatedAt: evaluatedAt)
        guard final == after else {
            throw DerivedIntelligenceInputAdapterError.sourceChangedDuringRead
        }
        let refreshedItems = persistedWorkItems.map {
            Self.replacing($0, freshness: Self.freshness(for: $0, coverage: fullCoverage, fence: after))
        }
        var inputItems: [DerivedIntelligenceItemInput] = []
        inputItems.reserveCapacity(refreshedItems.count)
        for workItem in refreshedItems {
            guard let primary = after.primarySources.first(where: { $0.workItemID == workItem.id }),
                  primary.nodeID == workItem.primaryNodeID
            else {
                throw DerivedIntelligenceInputAdapterError.sourceChangedDuringRead
            }
            let document = support.documents[workItem.id] ?? Self.document(for: workItem)
            let cacheDecision = try await aiCacheDecision(
                for: workItem,
                document: document,
                sourceRevision: after.primarySources.first(where: { $0.workItemID == workItem.id })?.sourceRevision,
                scope: scope,
                selectedModelID: aiPolicy.selectedModelID,
                effectiveModelID: aiPolicy.effectiveModelID,
                automaticActionConfidenceThreshold: aiPolicy.automaticActionConfidenceThreshold,
                evaluatedAt: evaluatedAt
            )
            inputItems.append(DerivedIntelligenceItemInput(
                workItem: workItem,
                primaryEvidence: Self.primaryEvidence(for: primary, scope: scope),
                timeline: support.timelines[workItem.id] ?? [],
                timelineEvidence: support.timelineEvidence[workItem.id] ?? [:],
                pullRequestReviews: support.reviews[workItem.id] ?? [],
                pullRequestReviewThreads: support.reviewThreads[workItem.id] ?? [],
                pullRequestStatusChecks: support.statusChecks[workItem.id] ?? [],
                pullRequestMergeableState: support.mergeableStates[workItem.id],
                pullRequestStatusCheckMarkerEvidence: support.statusCheckMarkerEvidence[workItem.id],
                pullRequestStatusCheckRevision: primary.pullRequestHeadCommitSHA,
                searchDocument: document,
                hasChangedAIFingerprint: cacheDecision.hasChanged,
                hasValidCachedAIAnalysis: cacheDecision.hasCachedAnalysis
            ))
        }

        let sourceStates = support.sourceStates.sorted { left, right in
            if left.workItemID != right.workItemID {
                return left.workItemID.rawValue < right.workItemID.rawValue
            }
            return left.feature.rawValue < right.feature.rawValue
        }
        let sourceRevisions = Dictionary(uniqueKeysWithValues: after.primarySources.map {
            ($0.workItemID, $0.sourceRevision)
        })
        let isProvisional = !fullCoverage.isComplete
            || after.primarySources.contains(where: { !$0.isCurrent })
            || sourceStates.contains(where: { $0.availability != .trusted })
        let aggregateSourceRevision = DerivedIntelligenceSourceRevision.aggregate(
            primaryRevisions: sourceRevisions,
            supplementalSources: after.supplementalSources
        )
        let marker = DerivedIntelligenceSourceRevisionMarker(
            scope: scope,
            sourceRevision: aggregateSourceRevision
        )
        return DerivedIntelligenceInputSnapshot(
            input: DerivedIntelligenceInput(
                scope: scope,
                currentUserNodeID: after.currentUserNodeID,
                visibleTeamNodeIDs: after.visibleTeamNodeIDs,
                coverageRequirements: after.coverageRequirements,
                coverageRecords: after.coverageRecords,
                businessDayPolicy: businessDayPolicy,
                calendar: calendar,
                aiPolicy: aiPolicy,
                repositoryPreferences: repositoryPreferences,
                isProvisional: isProvisional,
                evaluatedAt: evaluatedAt,
                items: inputItems
            ),
            sourceStates: sourceStates,
            sourceRevisions: sourceRevisions,
            aggregateSourceRevision: aggregateSourceRevision,
            publicationMarker: marker
        )
    }

    /// Returns the current normalized-source marker without building rule or
    /// AI inputs. Observation owners can call this to gate an already durable
    /// projection before notifying presentation consumers.
    func currentSourceRevisionMarker(
        for scope: SynchronizationScope,
        evaluatedAt: Date = .now
    ) async throws -> DerivedIntelligenceSourceRevisionMarker {
        guard scope.accountID == vault.accountID else {
            throw DerivedIntelligenceInputAdapterError.accountScopeMismatch
        }
        guard evaluatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DerivedIntelligenceInputAdapterError.invalidEvaluationDate
        }
        let sourceFence = try await fence(for: scope, evaluatedAt: evaluatedAt)
        let primaryRevisions = Dictionary(uniqueKeysWithValues: sourceFence.primarySources.map {
            ($0.workItemID, $0.sourceRevision)
        })
        return DerivedIntelligenceSourceRevisionMarker(
            scope: scope,
            sourceRevision: DerivedIntelligenceSourceRevision.aggregate(
                primaryRevisions: primaryRevisions,
                supplementalSources: sourceFence.supplementalSources
            )
        )
    }

    private func aiCacheDecision(
        for workItem: WorkItem,
        document: SearchDocument,
        sourceRevision: String?,
        scope: SynchronizationScope,
        selectedModelID: String?,
        effectiveModelID: String?,
        automaticActionConfidenceThreshold: Double,
        evaluatedAt: Date
    ) async throws -> (hasChanged: Bool, hasCachedAnalysis: Bool) {
        guard let sourceRevision else {
            throw DerivedIntelligenceInputAdapterError.invalidPersistedData
        }
        // Auto must already have been resolved by the authenticated
        // organization controller. Without an exact model, no cache entry may
        // suppress a future authorized request.
        guard let effectiveModelID else { return (true, false) }
        let reasons = workItem.attentionReasons.map(\.id).sorted()
        let input: CopilotAnalysisInput
        if !reasons.isEmpty,
           let candidateID = try? CopilotCandidateInputBuilder.derivedCandidateID(
               workItemID: workItem.id,
               triggerReasonIDs: reasons
           ),
           let currentInput = try? CopilotCandidateInputBuilder.make(
               candidateID: candidateID,
               triggerReasonIDs: reasons,
               workItem: workItem,
               document: document,
               scope: scope
           ) {
            // Match the production request exactly so an unchanged candidate
            // cannot relaunch the helper after the next derived refresh.
            input = currentInput
        } else {
            // Before the first derived publication there may be no current
            // reason/evidence set. This placeholder is cache-only; it never
            // leaves the process because no persisted candidate exists yet.
            guard let candidateID = AIRequestID(rawValue: "derived-\(workItem.id.rawValue)") else {
                throw DerivedIntelligenceInputAdapterError.invalidPersistedData
            }
            input = CopilotAnalysisInput(
                candidateID: candidateID,
                workItemTitle: workItem.title,
                workItemState: workItem.state.rawValue,
                deterministicReasons: ["derived-input"],
                body: document.body,
                conversation: [],
                evidenceIDs: []
            )
        }
        let fingerprint = try AIFingerprint.make(
            scope: scope,
            input: input,
            sourceRevision: sourceRevision,
            selectedModelID: selectedModelID,
            effectiveModelID: effectiveModelID,
            automaticActionConfidenceThreshold: automaticActionConfidenceThreshold,
            promptVersion: 1,
            outputSchemaVersion: 1
        )
        let key = AIAnalysisCacheKey(
            workItemID: workItem.id,
            fingerprint: fingerprint,
            selectedModelID: selectedModelID,
            effectiveModelID: effectiveModelID,
            promptVersion: 1,
            outputSchemaVersion: 1
        )
        let analysis = try await aiAnalysis.validAnalysis(for: scope, key: key, at: evaluatedAt)
        return (analysis == nil, analysis != nil)
    }

    private struct PrimarySource: Equatable, Sendable {
        let workItemID: WorkItemID
        let nodeID: GitHubNodeID
        let repositoryID: RepositoryID?
        let kind: GitHubContentKind
        let sourceRevision: String
        let pullRequestHeadCommitSHA: String?
        let lastObservedAt: Date?

        var isCurrent: Bool {
            !sourceRevision.isEmpty && lastObservedAt != nil
        }
    }

    private struct Fence: Equatable, Sendable {
        let scope: SynchronizationScope
        let currentUserNodeID: GitHubNodeID
        let visibleTeamNodeIDs: Set<GitHubNodeID>
        let coverageRecords: [CoverageRecord]
        let coverageRequirements: [CoverageRequirement]
        let primarySources: [PrimarySource]
        let supplementalSources: [DerivedIntelligenceSupplementalSource]
    }

    private struct SupplementalData: Sendable {
        let timelines: [WorkItemID: [TimelineEventSummary]]
        let timelineEvidence: [WorkItemID: [GitHubEventID: EvidenceReference]]
        let reviews: [WorkItemID: [PullRequestReviewFeedback]]
        let reviewThreads: [WorkItemID: [PullRequestReviewThread]]
        let statusChecks: [WorkItemID: [PullRequestStatusCheck]]
        let mergeableStates: [WorkItemID: String]
        let statusCheckMarkerEvidence: [WorkItemID: EvidenceReference]
        let documents: [WorkItemID: SearchDocument]
        let sourceStates: [DerivedIntelligenceSourceState]
    }

    private func fence(for scope: SynchronizationScope, evaluatedAt: Date) async throws -> Fence {
        try await vault.read { database in
            guard let account = try Row.fetchOne(
                database,
                sql: """
                    SELECT accounts.github_node_id, accounts.credential_revision,
                           account_organizations.capability_revision
                    FROM accounts
                    JOIN account_organizations
                      ON account_organizations.account_id = accounts.id
                    WHERE accounts.id = ? AND account_organizations.organization_id = ?
                      AND accounts.disabled_at_ms IS NULL
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
            ),
            let currentUserNodeID = GitHubNodeID(rawValue: account["github_node_id"]),
            CredentialRevision(rawValue: account["credential_revision"]) == scope.credentialRevision,
            CapabilityRevision(rawValue: account["capability_revision"]) == scope.capabilityRevision
            else {
                throw DerivedIntelligenceInputAdapterError.staleSynchronizationScope
            }

            let coverage = try CoverageRepository.currentRecords(for: scope, in: database)
            let requirements = try CoverageRequirementProfile.build(for: scope, coverage: coverage, in: database)
            var supplementalSources = try DerivedIntelligenceSourceRevision.supplementalSources(
                for: scope,
                in: database
            )
            supplementalSources += try RepositoryRankingPreferenceRepository.sourceRevisions(
                for: scope,
                in: database
            )
            supplementalSources.sort {
                if $0.kind != $1.kind { return $0.kind < $1.kind }
                if $0.identity != $1.identity { return $0.identity < $1.identity }
                return $0.revision < $1.revision
            }
            let teams = try Row.fetchAll(
                database,
                sql: """
                    SELECT teams.github_node_id
                    FROM teams
                    JOIN team_memberships ON team_memberships.team_id = teams.id
                    WHERE teams.organization_id = ? AND team_memberships.account_id = ?
                      AND team_memberships.membership_state = 'active'
                      AND (team_memberships.expires_at_ms IS NULL OR team_memberships.expires_at_ms > ?)
                    ORDER BY teams.github_node_id
                    """,
                arguments: [
                    scope.organizationID.rawValue,
                    scope.accountID.rawValue,
                    Self.milliseconds(evaluatedAt)
                ]
            ).compactMap { row in
                (row["github_node_id"] as String?).flatMap(GitHubNodeID.init(rawValue:))
            }
            let teamRequirement = Self.featureTrusted(
                .teams,
                repositoryID: nil,
                requirements: requirements,
                records: coverage,
                scope: scope
            )
            let sources = try Row.fetchAll(
                database,
                sql: """
                    SELECT work_items.id, work_items.primary_node_id, github_nodes.repository_id,
                           github_nodes.kind, github_nodes.source_revision, github_nodes.pull_request_head_commit_sha,
                           github_nodes.last_observed_at_ms
                    FROM work_items
                    JOIN github_nodes ON github_nodes.github_node_id = work_items.primary_node_id
                    LEFT JOIN work_item_group_memberships
                      ON work_item_group_memberships.constituent_work_item_id = work_items.id
                     AND work_item_group_memberships.account_id = work_items.account_id
                     AND work_item_group_memberships.organization_id = work_items.organization_id
                    WHERE work_items.account_id = ? AND work_items.organization_id = ?
                      AND github_nodes.account_id = ? AND github_nodes.organization_id = ?
                      AND (
                          work_item_group_memberships.constituent_work_item_id IS NULL
                          OR work_item_group_memberships.canonical_work_item_id = work_items.id
                      )
                    ORDER BY work_items.id
                    """,
                arguments: [
                    scope.accountID.rawValue, scope.organizationID.rawValue,
                    scope.accountID.rawValue, scope.organizationID.rawValue
                ]
            ).map { row -> PrimarySource in
                guard let workItemID = WorkItemID(rawValue: row["id"]),
                      let nodeID = GitHubNodeID(rawValue: row["primary_node_id"]),
                      let kind = GitHubContentKind(rawValue: row["kind"]),
                      let sourceRevision: String = row["source_revision"]
                else {
                    throw DerivedIntelligenceInputAdapterError.invalidPersistedData
                }
                let repositoryID = (row["repository_id"] as String?).flatMap(RepositoryID.init(rawValue:))
                guard row["repository_id"] == nil || repositoryID != nil else {
                    throw DerivedIntelligenceInputAdapterError.invalidPersistedData
                }
                return PrimarySource(
                    workItemID: workItemID,
                    nodeID: nodeID,
                    repositoryID: repositoryID,
                    kind: kind,
                    sourceRevision: sourceRevision,
                    pullRequestHeadCommitSHA: row["pull_request_head_commit_sha"],
                    lastObservedAt: Self.date(milliseconds: row["last_observed_at_ms"])
                )
            }
            return Fence(
                scope: scope,
                currentUserNodeID: currentUserNodeID,
                visibleTeamNodeIDs: teamRequirement ? Set(teams) : [],
                coverageRecords: coverage,
                coverageRequirements: requirements,
                primarySources: sources,
                supplementalSources: supplementalSources
            )
        }
    }

    private func supplementalData(
        scope: SynchronizationScope,
        workItems: [WorkItem],
        fence: Fence
    ) async throws -> SupplementalData {
        try await vault.read { database in
            var timelines = [WorkItemID: [TimelineEventSummary]]()
            var timelineEvidence = [WorkItemID: [GitHubEventID: EvidenceReference]]()
            var reviews = [WorkItemID: [PullRequestReviewFeedback]]()
            var reviewThreads = [WorkItemID: [PullRequestReviewThread]]()
            var statusChecks = [WorkItemID: [PullRequestStatusCheck]]()
            var mergeableStates = [WorkItemID: String]()
            var statusCheckMarkerEvidence = [WorkItemID: EvidenceReference]()
            var documents = [WorkItemID: SearchDocument]()
            var states = [DerivedIntelligenceSourceState]()

            let sourcesByWorkItemID = Dictionary(uniqueKeysWithValues: fence.primarySources.map {
                ($0.workItemID, $0)
            })
            for workItem in workItems {
                guard let primary = sourcesByWorkItemID[workItem.id],
                      primary.nodeID == workItem.primaryNodeID
                else {
                    throw DerivedIntelligenceInputAdapterError.sourceChangedDuringRead
                }
                let itemFeature = Self.primaryFeature(for: primary.kind)
                let itemTrusted = primary.isCurrent && Self.featureTrusted(
                    itemFeature,
                    repositoryID: primary.repositoryID,
                    requirements: fence.coverageRequirements,
                    records: fence.coverageRecords,
                    scope: scope
                )
                states.append(.init(
                    workItemID: workItem.id,
                    feature: itemFeature,
                    availability: itemTrusted ? .trusted : .provisional
                ))

                if primary.kind == .issue || primary.kind == .pullRequest {
                    let timelineCoverageTrusted = itemTrusted && Self.featureTrusted(
                        .timelines,
                        repositoryID: primary.repositoryID,
                        requirements: fence.coverageRequirements,
                        records: fence.coverageRecords,
                        scope: scope
                    ) && Self.timelineCandidateTrusted(primary, records: fence.coverageRecords, scope: scope)
                    let timelineTrusted: Bool
                    if timelineCoverageTrusted {
                        timelineTrusted = try Self.timelineCurrentPageTrusted(
                            primary,
                            scope: scope,
                            in: database
                        )
                    } else {
                        timelineTrusted = false
                    }
                    states.append(.init(
                        workItemID: workItem.id,
                        feature: .timelines,
                        availability: timelineTrusted ? .trusted : .excluded
                    ))
                    if timelineTrusted {
                        let events = try Self.timeline(
                            for: primary,
                            scope: scope,
                            in: database
                        )
                        timelines[workItem.id] = events
                        timelineEvidence[workItem.id] = try Self.timelineEvidence(
                            for: events,
                            primary: primary,
                            scope: scope
                        )
                    }
                }

                let isPullRequest = primary.kind == .pullRequest
                let reviewsCoverageTrusted = isPullRequest && itemTrusted && Self.featureTrusted(
                    .reviews,
                    repositoryID: nil,
                    requirements: fence.coverageRequirements,
                    records: fence.coverageRecords,
                    scope: scope
                )
                let reviewsReceiptTrusted = try Self.reviewCandidateTrusted(
                    primary,
                    feature: .reviews,
                    scope: scope,
                    in: database
                )
                let reviewsTrusted = reviewsCoverageTrusted && reviewsReceiptTrusted
                if isPullRequest {
                    states.append(.init(
                        workItemID: workItem.id,
                        feature: .reviews,
                        availability: reviewsTrusted ? .trusted : .excluded
                    ))
                    if reviewsTrusted {
                        reviews[workItem.id] = try Self.reviews(for: primary, scope: scope, in: database)
                    }
                }

                let statusCheckCoverageTrusted = isPullRequest && itemTrusted && Self.statusCheckCoverageCurrent(
                    primary,
                    records: fence.coverageRecords,
                    scope: scope
                )
                let statusChecksCurrent = try Self.statusChecksCurrent(
                    for: primary,
                    scope: scope,
                    in: database
                )
                let statusChecksTrusted = statusCheckCoverageTrusted && statusChecksCurrent
                if isPullRequest {
                    states.append(.init(
                        workItemID: workItem.id,
                        feature: .statusChecks,
                        availability: statusChecksTrusted ? .trusted : .excluded
                    ))
                    if statusChecksTrusted {
                        let statusSnapshot = try Self.statusChecks(for: primary, scope: scope, in: database)
                        statusChecks[workItem.id] = statusSnapshot.checks
                        mergeableStates[workItem.id] = statusSnapshot.mergeableState
                        statusCheckMarkerEvidence[workItem.id] = statusSnapshot.markerEvidence
                    }
                }

                let threadsCoverageTrusted = isPullRequest && itemTrusted && Self.featureTrusted(
                    .reviewThreads,
                    repositoryID: nil,
                    requirements: fence.coverageRequirements,
                    records: fence.coverageRecords,
                    scope: scope
                )
                let threadsReceiptTrusted = try Self.reviewCandidateTrusted(
                    primary,
                    feature: .reviewThreads,
                    scope: scope,
                    in: database
                )
                let threadsTrusted = threadsCoverageTrusted && threadsReceiptTrusted
                if isPullRequest {
                    states.append(.init(
                        workItemID: workItem.id,
                        feature: .reviewThreads,
                        availability: threadsTrusted ? .trusted : .excluded
                    ))
                    if threadsTrusted {
                        reviewThreads[workItem.id] = try Self.reviewThreads(for: primary, scope: scope, in: database)
                    }
                }

                documents[workItem.id] = try Self.document(
                    for: workItem,
                    primary: primary,
                    scope: scope,
                    includeProjectValues: itemTrusted && Self.featureTrusted(
                        .projects,
                        repositoryID: nil,
                        requirements: fence.coverageRequirements,
                        records: fence.coverageRecords,
                        scope: scope
                    ) && Self.featureTrusted(
                        .projectItems,
                        repositoryID: nil,
                        requirements: fence.coverageRequirements,
                        records: fence.coverageRecords,
                        scope: scope
                    ),
                    in: database
                )
            }
            return SupplementalData(
                timelines: timelines,
                timelineEvidence: timelineEvidence,
                reviews: reviews,
                reviewThreads: reviewThreads,
                statusChecks: statusChecks,
                mergeableStates: mergeableStates,
                statusCheckMarkerEvidence: statusCheckMarkerEvidence,
                documents: documents,
                sourceStates: states
            )
        }
    }

    private nonisolated static func timeline(
        for primary: PrimarySource,
        scope: SynchronizationScope,
        in database: Database
    ) throws -> [TimelineEventSummary] {
        let streamID = "timeline:\(primary.nodeID.rawValue)"
        return try Row.fetchAll(
            database,
            sql: """
                SELECT timeline_events.github_event_id, timeline_events.subject_node_id,
                       timeline_events.kind, timeline_events.occurred_at_ms,
                       actors.id AS actor_id, actors.github_node_id AS actor_node_id,
                       actors.login AS actor_login, actors.display_name AS actor_display_name,
                       actors.avatar_url AS actor_avatar_url
                FROM timeline_events
                LEFT JOIN actors ON actors.id = timeline_events.actor_id
                WHERE timeline_events.subject_node_id = ?
                  AND EXISTS (
                      SELECT 1
                      FROM timeline_current_pages
                      WHERE timeline_current_pages.account_id = ?
                        AND timeline_current_pages.organization_id = ?
                        AND timeline_current_pages.github_node_id = timeline_events.subject_node_id
                        AND timeline_current_pages.feature = ?
                        AND timeline_current_pages.stream_id = ?
                        AND timeline_current_pages.credential_revision = ?
                        AND timeline_current_pages.capability_revision = ?
                        AND timeline_current_pages.source_revision = ?
                        AND timeline_current_pages.source_revision = timeline_events.source_revision
                  )
                ORDER BY timeline_events.occurred_at_ms ASC, timeline_events.github_event_id ASC
                """,
            arguments: [
                primary.nodeID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue,
                CoverageFeature.timelines.rawValue, streamID,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                primary.sourceRevision
            ]
        ).map { row in
            guard let id = GitHubEventID(rawValue: row["github_event_id"]),
                  let subjectNodeID = GitHubNodeID(rawValue: row["subject_node_id"]),
                  let kind = TimelineEventKind(rawValue: row["kind"]),
                  let occurredAt = date(milliseconds: row["occurred_at_ms"])
            else {
                throw DerivedIntelligenceInputAdapterError.invalidPersistedData
            }
            return TimelineEventSummary(
                id: id,
                subjectNodeID: subjectNodeID,
                kind: kind,
                actor: try actor(from: row),
                occurredAt: occurredAt,
                url: nil,
                body: nil
            )
        }
    }

    private nonisolated static func primaryEvidence(
        for primary: PrimarySource,
        scope: SynchronizationScope
    ) -> EvidenceReference? {
        guard primary.isCurrent,
              let observedAt = primary.lastObservedAt,
              let streamID = hydrationStreamID(for: primary, scope: scope)
        else { return nil }
        return EvidenceReference(
            id: EvidenceID(rawValue: "hydration-\(primary.nodeID.rawValue)")!,
            source: .graphQL,
            locator: .query("graphql:TriageHydrateNodes/node=\(primary.nodeID.rawValue)"),
            authority: .github(
                scope: scope,
                feature: primaryFeature(for: primary.kind),
                streamID: streamID
            ),
            nodeID: primary.nodeID,
            sourceRevision: primary.sourceRevision,
            confidence: .confirmed,
            confirmation: .confirmed,
            observedAt: observedAt
        )
    }

    private nonisolated static func timelineEvidence(
        for events: [TimelineEventSummary],
        primary: PrimarySource,
        scope: SynchronizationScope
    ) throws -> [GitHubEventID: EvidenceReference] {
        guard primary.isCurrent,
              let streamID = SyncStreamID(rawValue: "timeline:\(primary.nodeID.rawValue)")
        else { return [:] }
        var result = [GitHubEventID: EvidenceReference]()
        for event in events {
            guard event.subjectNodeID == primary.nodeID,
                  result[event.id] == nil
            else { throw DerivedIntelligenceInputAdapterError.invalidPersistedData }
            result[event.id] = EvidenceReference(
                id: EvidenceID(rawValue: "timeline-\(event.id.rawValue)")!,
                source: .restTimeline,
                // A timeline source revision covers the complete page set, so
                // identify the exact durable stream rather than inventing an
                // event-to-page endpoint mapping that the schema does not
                // retain.
                locator: .query("timeline:\(primary.nodeID.rawValue)"),
                authority: .github(scope: scope, feature: .timelines, streamID: streamID),
                nodeID: event.subjectNodeID,
                eventID: event.id,
                sourceRevision: primary.sourceRevision,
                confidence: .confirmed,
                confirmation: .confirmed,
                observedAt: event.occurredAt,
                excerpt: event.body
            )
        }
        return result
    }

    private nonisolated static func hydrationStreamID(
        for primary: PrimarySource,
        scope: SynchronizationScope
    ) -> SyncStreamID? {
        let kindComponent: String
        switch primary.kind {
        case .issue:
            kindComponent = "issues"
        case .pullRequest:
            kindComponent = "pull-requests"
        default:
            return nil
        }
        return SyncStreamID(
            rawValue: "hydration-\(kindComponent)-\(scope.organizationID.rawValue)"
        )
    }

    private nonisolated static func reviews(
        for primary: PrimarySource,
        scope: SynchronizationScope,
        in database: Database
    ) throws -> [PullRequestReviewFeedback] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT reviews.github_node_id, reviews.author_id, reviews.state,
                       reviews.submitted_at_ms, review_nodes.source_revision,
                       review_nodes.last_observed_at_ms
                FROM reviews
                JOIN github_nodes AS pull_request_nodes
                  ON pull_request_nodes.github_node_id = reviews.pull_request_node_id
                JOIN github_nodes AS review_nodes
                  ON review_nodes.github_node_id = reviews.github_node_id
                WHERE reviews.pull_request_node_id = ?
                  AND pull_request_nodes.account_id = ? AND pull_request_nodes.organization_id = ?
                  AND review_nodes.account_id = ? AND review_nodes.organization_id = ?
                ORDER BY COALESCE(reviews.submitted_at_ms, reviews.updated_at_ms), reviews.github_node_id
                """,
            arguments: [
                primary.nodeID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue
            ]
        ).compactMap { row in
            guard let reviewID = GitHubNodeID(rawValue: row["github_node_id"]),
                  let state = ReviewState(rawValue: row["state"]),
                  let sourceRevision: String = row["source_revision"],
                  !sourceRevision.isEmpty,
                  let observedAt = date(milliseconds: row["last_observed_at_ms"])
            else {
                return nil
            }
            return PullRequestReviewFeedback(
                id: reviewID,
                authorNodeID: (row["author_id"] as String?).flatMap(GitHubNodeID.init(rawValue:)),
                state: state,
                submittedAt: date(milliseconds: row["submitted_at_ms"]),
                evidence: EvidenceReference(
                    id: EvidenceID(rawValue: "review-\(reviewID.rawValue)")!,
                    source: .restReview,
                    locator: .query("derived/reviews/\(primary.nodeID.rawValue)"),
                    authority: .github(
                        scope: scope,
                        feature: .reviews,
                        streamID: SyncStreamID(rawValue: "pull-request-reviews-\(scope.organizationID.rawValue)")!
                    ),
                    nodeID: reviewID,
                    sourceRevision: sourceRevision,
                    confidence: .confirmed,
                    confirmation: .confirmed,
                    observedAt: observedAt
                )
            )
        }
    }

    private nonisolated static func reviewThreads(
        for primary: PrimarySource,
        scope: SynchronizationScope,
        in database: Database
    ) throws -> [PullRequestReviewThread] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT review_threads.github_node_id, review_threads.is_resolved,
                       review_threads.requires_current_user_response,
                       thread_nodes.source_revision, thread_nodes.last_observed_at_ms
                FROM review_threads
                JOIN github_nodes AS pull_request_nodes
                  ON pull_request_nodes.github_node_id = review_threads.pull_request_node_id
                JOIN github_nodes AS thread_nodes
                  ON thread_nodes.github_node_id = review_threads.github_node_id
                WHERE review_threads.pull_request_node_id = ?
                  AND pull_request_nodes.account_id = ? AND pull_request_nodes.organization_id = ?
                  AND thread_nodes.account_id = ? AND thread_nodes.organization_id = ?
                ORDER BY review_threads.updated_at_ms, review_threads.github_node_id
                """,
            arguments: [
                primary.nodeID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue
            ]
        ).compactMap { row in
            guard let threadID = GitHubNodeID(rawValue: row["github_node_id"]),
                  let sourceRevision: String = row["source_revision"],
                  !sourceRevision.isEmpty,
                  let observedAt = date(milliseconds: row["last_observed_at_ms"])
            else {
                return nil
            }
            return PullRequestReviewThread(
                id: threadID,
                isResolved: row["is_resolved"],
                requiresCurrentUserResponse: row["requires_current_user_response"],
                evidence: EvidenceReference(
                    id: EvidenceID(rawValue: "review-thread-\(threadID.rawValue)")!,
                    source: .graphQL,
                    locator: .query("derived/review-threads/\(primary.nodeID.rawValue)"),
                    authority: .github(
                        scope: scope,
                        feature: .reviewThreads,
                        streamID: SyncStreamID(rawValue: "pull-request-review-threads-\(scope.organizationID.rawValue)")!
                    ),
                    nodeID: threadID,
                    sourceRevision: sourceRevision,
                    confidence: .confirmed,
                    confirmation: .confirmed,
                    observedAt: observedAt
                )
            )
        }
    }

    private nonisolated static func statusChecksCurrent(
        for primary: PrimarySource,
        scope: SynchronizationScope,
        in database: Database
    ) throws -> Bool {
        guard primary.kind == .pullRequest,
              let sourceRevision = primary.pullRequestHeadCommitSHA,
              isCommitSHA(sourceRevision)
        else { return false }
        // An authoritative empty rollup has no status_check rows. Coverage
        // plus the PR-scoped current-row marker proves that empty result; a
        // missing marker remains unknown rather than green.
        let markerCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM status_check_rollup_markers
                WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                  AND source_revision = ?
                """,
            arguments: [
                primary.nodeID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                sourceRevision
            ]
        ) ?? 0
        return markerCount == 1
    }

    private nonisolated static func statusCheckCoverageCurrent(
        _ primary: PrimarySource,
        records: [CoverageRecord],
        scope: SynchronizationScope
    ) -> Bool {
        guard let repositoryID = primary.repositoryID,
              let sourceRevision = primary.pullRequestHeadCommitSHA,
              isCommitSHA(sourceRevision)
        else { return false }
        let streamID = PullRequestStatusCheckRefreshService.sourceStreamID(
            organizationID: scope.organizationID,
            pullRequestNodeID: primary.nodeID,
            sourceRevision: sourceRevision
        )
        return records.contains {
            $0.accountID == scope.accountID && $0.organizationID == scope.organizationID
                && $0.repositoryID == repositoryID && $0.feature == .statusChecks
                && $0.streamID == streamID
                && $0.credentialRevision == scope.credentialRevision
                && $0.capabilityRevision == scope.capabilityRevision
                && $0.status == .complete && $0.lastSuccessfulAt != nil
        }
    }

    private nonisolated static func statusChecks(
        for primary: PrimarySource,
        scope: SynchronizationScope,
        in database: Database
    ) throws -> (checks: [PullRequestStatusCheck], mergeableState: String, markerEvidence: EvidenceReference) {
        guard let sourceRevision = primary.pullRequestHeadCommitSHA,
              isCommitSHA(sourceRevision)
        else { throw DerivedIntelligenceInputAdapterError.invalidPersistedData }
        let streamID = PullRequestStatusCheckRefreshService.sourceStreamID(
            organizationID: scope.organizationID,
            pullRequestNodeID: primary.nodeID,
            sourceRevision: sourceRevision
        )
        guard let marker = try Row.fetchOne(
            database,
            sql: """
                SELECT mergeable_state, observed_at_ms FROM status_check_rollup_markers
                WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                  AND source_revision = ?
                """,
            arguments: [
                primary.nodeID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                sourceRevision
            ]
        ), let mergeableState: String = marker["mergeable_state"],
           let markerObservedAt = date(milliseconds: marker["observed_at_ms"]),
           ["MERGEABLE", "CONFLICTING", "UNKNOWN"].contains(mergeableState) else {
            throw DerivedIntelligenceInputAdapterError.invalidPersistedData
        }
        let checks = try Row.fetchAll(
            database,
            sql: """
                SELECT context, state, is_required, completed_at_ms, observed_at_ms
                FROM status_checks
                WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                  AND source_revision = ?
                ORDER BY context
                """,
            arguments: [
                primary.nodeID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                sourceRevision
            ]
        ).map { row -> PullRequestStatusCheck in
            guard let context: String = row["context"],
                  let stateValue: String = row["state"],
                  let state = GitHubPullRequestStatusCheckState(rawValue: stateValue),
                  let required: Bool = row["is_required"],
                  let observedAt = date(milliseconds: row["observed_at_ms"])
            else { throw DerivedIntelligenceInputAdapterError.invalidPersistedData }
            return .init(
                context: context,
                state: state,
                isRequired: required,
                completedAt: date(milliseconds: row["completed_at_ms"]),
                evidence: EvidenceReference(
                    id: EvidenceID(rawValue: "status-check-\(primary.nodeID.rawValue)-\(context)")!,
                    source: .graphQL,
                    locator: .query("TriagePullRequestStatusChecks"),
                    authority: .github(
                        scope: scope,
                        feature: .statusChecks,
                        streamID: streamID
                    ),
                    nodeID: primary.nodeID,
                    sourceRevision: sourceRevision,
                    confidence: .confirmed,
                    confirmation: .confirmed,
                    observedAt: observedAt
                )
            )
        }
        guard Set(checks.map(\.context)).count == checks.count else {
            throw DerivedIntelligenceInputAdapterError.invalidPersistedData
        }
        return (
            checks,
            mergeableState,
            EvidenceReference(
                id: EvidenceID(rawValue: "status-check-rollup-\(primary.nodeID.rawValue)")!,
                source: .graphQL,
                locator: .query("TriagePullRequestStatusChecks"),
                authority: .github(scope: scope, feature: .statusChecks, streamID: streamID),
                nodeID: primary.nodeID,
                sourceRevision: sourceRevision,
                confidence: .confirmed,
                confirmation: .confirmed,
                observedAt: markerObservedAt
            )
        )
    }

    private nonisolated static func isCommitSHA(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.numericType != nil || (97...102).contains($0.value)) }
    }

    private nonisolated static func document(
        for workItem: WorkItem,
        primary: PrimarySource,
        scope: SynchronizationScope,
        includeProjectValues: Bool,
        in database: Database
    ) throws -> SearchDocument {
        let body = try String.fetchOne(
            database,
            sql: """
                SELECT COALESCE(body_markdown, '')
                FROM github_nodes
                WHERE github_node_id = ?
                """,
            arguments: [primary.nodeID.rawValue]
        ) ?? ""
        let projectValues: String
        if includeProjectValues {
            projectValues = try String.fetchAll(
                database,
                sql: """
                    SELECT project_field_values.field_name || ': ' || COALESCE(project_field_values.display_value, '')
                    FROM project_items
                    JOIN project_field_values
                      ON project_field_values.project_item_node_id = project_items.github_node_id
                    JOIN github_nodes AS project_item_nodes
                      ON project_item_nodes.github_node_id = project_items.github_node_id
                    JOIN projects
                      ON projects.github_node_id = project_items.project_node_id
                    JOIN github_nodes AS project_nodes
                      ON project_nodes.github_node_id = projects.github_node_id
                    WHERE project_items.content_node_id = ?
                      AND project_item_nodes.account_id = ?
                      AND project_item_nodes.organization_id = ?
                      AND project_nodes.account_id = ?
                      AND project_nodes.organization_id = ?
                    ORDER BY project_items.github_node_id, project_field_values.field_name
                    """,
                arguments: [
                    primary.nodeID.rawValue,
                    scope.accountID.rawValue, scope.organizationID.rawValue,
                    scope.accountID.rawValue, scope.organizationID.rawValue
                ]
            ).joined(separator: " ")
        } else {
            projectValues = ""
        }
        return SearchDocument(
            accountID: workItem.accountID,
            organizationID: workItem.organizationID,
            workItemID: workItem.id,
            nodeID: workItem.primaryNodeID,
            title: workItem.title,
            body: body,
            repository: workItem.repository?.fullName ?? "",
            labels: "",
            people: "",
            projectValues: projectValues,
            actionText: workItem.openActionItems.map(\.title).joined(separator: " "),
            localNote: workItem.workflow.localNote ?? ""
        )
    }

    private nonisolated static func document(for workItem: WorkItem) -> SearchDocument {
        SearchDocument(
            accountID: workItem.accountID,
            organizationID: workItem.organizationID,
            workItemID: workItem.id,
            nodeID: workItem.primaryNodeID,
            title: workItem.title,
            body: "",
            repository: workItem.repository?.fullName ?? "",
            labels: "",
            people: "",
            projectValues: "",
            actionText: workItem.openActionItems.map(\.title).joined(separator: " "),
            localNote: workItem.workflow.localNote ?? ""
        )
    }

    private nonisolated static func freshness(
        for workItem: WorkItem,
        coverage: CoverageEvaluation,
        fence: Fence
    ) -> FreshnessState {
        guard let source = fence.primarySources.first(where: { $0.workItemID == workItem.id }), source.isCurrent else {
            return FreshnessState(
                status: .stale,
                lastSuccessfulSyncAt: coverage.freshness.lastSuccessfulSyncAt,
                detail: "The work item source revision is not currently available."
            )
        }
        guard coverage.isComplete else {
            return FreshnessState(
                status: coverage.freshness.status,
                lastSuccessfulSyncAt: coverage.freshness.lastSuccessfulSyncAt,
                detail: coverage.freshness.detail
            )
        }
        return FreshnessState(status: .fresh, lastSuccessfulSyncAt: coverage.freshness.lastSuccessfulSyncAt)
    }

    private nonisolated static func replacing(_ workItem: WorkItem, freshness: FreshnessState) -> WorkItem {
        WorkItem(
            id: workItem.id,
            accountID: workItem.accountID,
            organizationID: workItem.organizationID,
            primaryNodeID: workItem.primaryNodeID,
            title: workItem.title,
            state: workItem.state,
            sourceKind: workItem.sourceKind,
            sourceURL: workItem.sourceURL,
            repository: workItem.repository,
            members: workItem.members,
            contextLinks: workItem.contextLinks,
            relations: workItem.relations,
            attentionReasons: workItem.attentionReasons,
            actionItems: workItem.actionItems,
            workflow: workItem.workflow,
            freshness: freshness,
            lastRelevantActivityAt: workItem.lastRelevantActivityAt,
            score: workItem.score
        )
    }

    private nonisolated static func featureTrusted(
        _ feature: CoverageFeature,
        repositoryID: RepositoryID?,
        requirements: [CoverageRequirement],
        records: [CoverageRecord],
        scope: SynchronizationScope
    ) -> Bool {
        let relevant = requirements.filter {
            $0.feature == feature && ($0.repositoryID == nil || $0.repositoryID == repositoryID)
        }
        guard !relevant.isEmpty else { return false }
        return relevant.allSatisfy { requirement in
            records.contains { record in
                record.accountID == scope.accountID
                    && record.organizationID == scope.organizationID
                    && record.credentialRevision == scope.credentialRevision
                    && record.capabilityRevision == scope.capabilityRevision
                    && record.feature == requirement.feature
                    && record.repositoryID == requirement.repositoryID
                    && record.streamID == requirement.streamID
                    && record.status == .complete
                    && record.lastSuccessfulAt != nil
                    && covers(record: record, requirement: requirement)
            }
        }
    }

    private nonisolated static func primaryFeature(for kind: GitHubContentKind) -> CoverageFeature {
        switch kind {
        case .pullRequest:
            .pullRequests
        case .discussion:
            .discussions
        case .project, .projectItem, .projectDraftIssue:
            .projects
        default:
            .issues
        }
    }

    /// Aggregate repository coverage cannot prove a particular timeline was
    /// traversed. Require the candidate's exact current stream as well, so an
    /// absent candidate result cannot masquerade as an authoritative empty
    /// timeline.
    private nonisolated static func timelineCandidateTrusted(
        _ primary: PrimarySource,
        records: [CoverageRecord],
        scope: SynchronizationScope
    ) -> Bool {
        let streamID = SyncStreamID(rawValue: "timeline:\(primary.nodeID.rawValue)")!
        return records.contains {
            $0.accountID == scope.accountID
                && $0.organizationID == scope.organizationID
                && $0.repositoryID == primary.repositoryID
                && $0.feature == .timelines
                && $0.streamID == streamID
                && $0.credentialRevision == scope.credentialRevision
                && $0.capabilityRevision == scope.capabilityRevision
                && $0.status == .complete
                && $0.lastSuccessfulAt != nil
        }
    }

    /// Organization-wide review coverage proves that the current batch reached
    /// an endpoint, not that this pull request's current revision was the one
    /// safely replaced. Require its immutable complete traversal receipt before
    /// exposing review-derived facts as trusted input.
    private nonisolated static func reviewCandidateTrusted(
        _ primary: PrimarySource,
        feature: CoverageFeature,
        scope: SynchronizationScope,
        in database: Database
    ) throws -> Bool {
        guard let repositoryID = primary.repositoryID,
              feature == .reviews || feature == .reviewThreads
        else { return false }
        let streamPrefix = feature == .reviews
            ? "pull-request-reviews-"
            : "pull-request-review-threads-"
        let streamID = "\(streamPrefix)\(scope.organizationID.rawValue)"
        return try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM review_candidate_complete_traversal_receipts
                    WHERE account_id = ? AND organization_id = ?
                      AND feature = ? AND stream_id = ?
                      AND candidate_node_id = ? AND repository_id = ?
                      AND candidate_source_revision = ?
                      AND credential_revision = ? AND capability_revision = ?
                )
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                feature.rawValue, streamID, primary.nodeID.rawValue,
                repositoryID.rawValue, primary.sourceRevision,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue
            ]
        ) ?? false
    }

    /// Coverage proves the candidate stream completed, while published page
    /// membership proves which normalized timeline revision it describes.
    /// Without membership for this exact primary revision, an absent timeline
    /// is unknown rather than a current empty result.
    private nonisolated static func timelineCurrentPageTrusted(
        _ primary: PrimarySource,
        scope: SynchronizationScope,
        in database: Database
    ) throws -> Bool {
        let streamID = "timeline:\(primary.nodeID.rawValue)"
        return try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM timeline_current_pages
                    WHERE account_id = ? AND organization_id = ?
                      AND github_node_id = ? AND feature = ? AND stream_id = ?
                      AND credential_revision = ? AND capability_revision = ?
                      AND source_revision = ?
                )
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                primary.nodeID.rawValue, CoverageFeature.timelines.rawValue, streamID,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                primary.sourceRevision
            ]
        ) ?? false
    }

    private nonisolated static func covers(record: CoverageRecord, requirement: CoverageRequirement) -> Bool {
        switch (record.intervalStart, record.intervalEnd, requirement.intervalStart, requirement.intervalEnd) {
        case (nil, nil, nil, nil): true
        case let (recordStart?, recordEnd?, requirementStart?, requirementEnd?):
            recordStart <= requirementStart && recordEnd >= requirementEnd
        default: false
        }
    }

    private nonisolated static func actor(from row: Row) throws -> ActorSummary? {
        guard let rawID: String = row["actor_id"] else { return nil }
        guard let id = ActorID(rawValue: rawID),
              let nodeID = GitHubNodeID(rawValue: row["actor_node_id"]),
              let login: String = row["actor_login"]
        else {
            throw DerivedIntelligenceInputAdapterError.invalidPersistedData
        }
        let avatarURL = (row["actor_avatar_url"] as String?).flatMap(URL.init(string:))
        guard row["actor_avatar_url"] == nil || avatarURL != nil else {
            throw DerivedIntelligenceInputAdapterError.invalidPersistedData
        }
        return ActorSummary(
            id: id,
            nodeID: nodeID,
            login: login,
            displayName: row["actor_display_name"],
            avatarURL: avatarURL
        )
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func date(milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }

}
