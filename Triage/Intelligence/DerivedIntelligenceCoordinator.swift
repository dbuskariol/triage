import Foundation

enum DerivedIntelligenceCoverageState: Equatable, Sendable {
    case trusted
    case incomplete
    case unknown
}

enum DerivedAICandidateExclusionReason: Equatable, Sendable {
    case incompleteCoverage
    case policyUnavailable
    case unchangedFingerprint
    case cachedAnalysis
}

struct DerivedAIPolicy: Equatable, Sendable {
    let isOrganizationConsentActive: Bool
    let isAuthenticationValid: Bool
    let isEntitled: Bool
    let hasAvailableBudget: Bool
    /// The exact persisted selection authorized for this derived run. `nil`
    /// means Auto and remains distinct from any explicit runtime model.
    let selectedModelID: String?

    init(
        isOrganizationConsentActive: Bool,
        isAuthenticationValid: Bool,
        isEntitled: Bool,
        hasAvailableBudget: Bool,
        selectedModelID: String? = nil
    ) {
        self.isOrganizationConsentActive = isOrganizationConsentActive
        self.isAuthenticationValid = isAuthenticationValid
        self.isEntitled = isEntitled
        self.hasAvailableBudget = hasAvailableBudget
        self.selectedModelID = selectedModelID
    }

    var permitsCandidates: Bool {
        isOrganizationConsentActive && isAuthenticationValid && isEntitled && hasAvailableBudget
    }
}

struct DerivedIntelligenceItemInput: Sendable {
    let workItem: WorkItem
    let timeline: [TimelineEventSummary]
    let pullRequestReviews: [PullRequestReviewFeedback]
    let pullRequestReviewThreads: [PullRequestReviewThread]
    let searchDocument: SearchDocument
    let hasChangedAIFingerprint: Bool
    let hasValidCachedAIAnalysis: Bool

    init(
        workItem: WorkItem,
        timeline: [TimelineEventSummary] = [],
        pullRequestReviews: [PullRequestReviewFeedback] = [],
        pullRequestReviewThreads: [PullRequestReviewThread] = [],
        searchDocument: SearchDocument,
        hasChangedAIFingerprint: Bool = true,
        hasValidCachedAIAnalysis: Bool = false
    ) {
        self.workItem = workItem
        self.timeline = timeline
        self.pullRequestReviews = pullRequestReviews
        self.pullRequestReviewThreads = pullRequestReviewThreads
        self.searchDocument = searchDocument
        self.hasChangedAIFingerprint = hasChangedAIFingerprint
        self.hasValidCachedAIAnalysis = hasValidCachedAIAnalysis
    }
}

struct DerivedIntelligenceInput: Sendable {
    let scope: SynchronizationScope
    let currentUserNodeID: GitHubNodeID
    let visibleTeamNodeIDs: Set<GitHubNodeID>
    let coverageRequirements: [CoverageRequirement]
    let coverageRecords: [CoverageRecord]
    let businessDayPolicy: BusinessDayPolicy
    let calendar: Calendar
    let aiPolicy: DerivedAIPolicy
    /// Callers provide persisted local repository preferences; an absent
    /// repository deliberately has the neutral score contribution.
    let repositoryPreferences: [RepositoryID: Int]
    /// Indicates that one or more scoped source inputs were unavailable or
    /// excluded. Rule results remain useful, but AI work must not be queued
    /// from an incomplete source snapshot.
    let isProvisional: Bool
    let evaluatedAt: Date
    let items: [DerivedIntelligenceItemInput]

    init(
        scope: SynchronizationScope,
        currentUserNodeID: GitHubNodeID,
        visibleTeamNodeIDs: Set<GitHubNodeID>,
        coverageRequirements: [CoverageRequirement],
        coverageRecords: [CoverageRecord],
        businessDayPolicy: BusinessDayPolicy = .init(),
        calendar: Calendar,
        aiPolicy: DerivedAIPolicy,
        repositoryPreferences: [RepositoryID: Int] = [:],
        isProvisional: Bool = false,
        evaluatedAt: Date,
        items: [DerivedIntelligenceItemInput]
    ) {
        self.scope = scope
        self.currentUserNodeID = currentUserNodeID
        self.visibleTeamNodeIDs = visibleTeamNodeIDs
        self.coverageRequirements = coverageRequirements
        self.coverageRecords = coverageRecords
        self.businessDayPolicy = businessDayPolicy
        self.calendar = calendar
        self.aiPolicy = aiPolicy
        self.repositoryPreferences = repositoryPreferences
        self.isProvisional = isProvisional
        self.evaluatedAt = evaluatedAt
        self.items = items
    }
}

struct DerivedMenuCounts: Equatable, Sendable {
    let inbox: Int
    let waiting: Int
    let snoozed: Int
    let archived: Int
    let resolved: Int
    let informational: Int
    let inaccessible: Int
    let myWork: Int
    let reviews: Int
    let allWork: Int
}

struct DerivedAICandidate: Equatable, Sendable {
    let id: String
    let workItemID: WorkItemID
    let score: AttentionScore
    let triggerReasonIDs: [String]
}

struct DerivedAICandidateExclusion: Equatable, Sendable {
    let workItemID: WorkItemID
    let reason: DerivedAICandidateExclusionReason
}

struct DerivedIntelligenceItemResult: Sendable {
    let workItemID: WorkItemID
    let attentionReasons: [AttentionReason]
    let score: AttentionScore
    let disposition: InboxDisposition
    let isOwnedByCurrentUser: Bool
    let searchDocument: SearchDocument
}

struct DerivedIntelligenceOutput: Sendable {
    let coverage: CoverageEvaluation
    let coverageState: DerivedIntelligenceCoverageState
    let items: [DerivedIntelligenceItemResult]
    let menuCounts: DerivedMenuCounts
    let aiCandidates: [DerivedAICandidate]
    let aiCandidateExclusions: [DerivedAICandidateExclusion]

    func persistenceSnapshot(scope: SynchronizationScope, evaluatedAt: Date) -> DerivedIntelligencePersistenceSnapshot {
        DerivedIntelligencePersistenceSnapshot(
            scope: scope,
            evaluatedAt: evaluatedAt,
            items: items.map {
                DerivedIntelligencePersistenceItem(
                    workItemID: $0.workItemID,
                    attentionReasons: $0.attentionReasons,
                    score: $0.score,
                    searchDocument: $0.searchDocument
                )
            }
        )
    }
}

/// Couples a deterministic output to the exact source marker that authorized
/// it. Consumers which observe durable projections can use the marker as a
/// publication gate instead of deriving a second, time-dependent result.
struct DerivedIntelligencePublicationResult: Sendable {
    let output: DerivedIntelligenceOutput
    let sourceRevisionMarker: DerivedIntelligenceSourceRevisionMarker
}

enum DerivedIntelligenceCoordinatorError: Error, Equatable, Sendable {
    case invalidScope
    case duplicateWorkItem
    case itemScopeMismatch
    case searchDocumentScopeMismatch
    case invalidEvaluationDate
}

struct DerivedIntelligenceCoordinator: Sendable {
    private let ranker = AttentionRanker()
    private let coverageEvaluator = CoverageEvaluator()

    func recompute(_ input: DerivedIntelligenceInput) throws -> DerivedIntelligenceOutput {
        try validate(input)
        let coverage = coverageEvaluator.evaluate(
            requirements: input.coverageRequirements,
            records: input.coverageRecords,
            accountID: input.scope.accountID,
            organizationID: input.scope.organizationID,
            credentialRevision: input.scope.credentialRevision,
            capabilityRevision: input.scope.capabilityRevision
        )
        let coverageState: DerivedIntelligenceCoverageState = input.coverageRequirements.isEmpty
            ? .unknown
            : coverage.isComplete ? .trusted : .incomplete
        let results = try input.items.map { try result(for: $0, input: input) }
            .sorted { $0.workItemID.rawValue < $1.workItemID.rawValue }
        let counts = menuCounts(for: results)
        let candidates = aiCandidates(
            for: results,
            coverageState: coverageState,
            isProvisional: input.isProvisional,
            policy: input.aiPolicy,
            inputsByID: Dictionary(uniqueKeysWithValues: input.items.map { ($0.workItem.id, $0) })
        )
        return DerivedIntelligenceOutput(
            coverage: coverage,
            coverageState: coverageState,
            items: results,
            menuCounts: counts,
            aiCandidates: candidates.candidates,
            aiCandidateExclusions: candidates.exclusions
        )
    }

    func recompute(
        snapshot: DerivedIntelligenceInputSnapshot
    ) throws -> DerivedIntelligencePublicationResult {
        DerivedIntelligencePublicationResult(
            output: try recompute(snapshot.input),
            sourceRevisionMarker: snapshot.publicationMarker
        )
    }

    private func validate(_ input: DerivedIntelligenceInput) throws {
        guard input.evaluatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DerivedIntelligenceCoordinatorError.invalidEvaluationDate
        }
        guard Set(input.items.map(\.workItem.id)).count == input.items.count else {
            throw DerivedIntelligenceCoordinatorError.duplicateWorkItem
        }
        for item in input.items {
            guard item.workItem.accountID == input.scope.accountID,
                  item.workItem.organizationID == input.scope.organizationID
            else {
                throw DerivedIntelligenceCoordinatorError.itemScopeMismatch
            }
            guard item.searchDocument.accountID == input.scope.accountID,
                  item.searchDocument.organizationID == input.scope.organizationID,
                  item.searchDocument.workItemID == item.workItem.id,
                  item.searchDocument.nodeID == item.workItem.primaryNodeID
            else {
                throw DerivedIntelligenceCoordinatorError.searchDocumentScopeMismatch
            }
        }
        guard input.coverageRecords.allSatisfy({
            $0.accountID == input.scope.accountID && $0.organizationID == input.scope.organizationID
        }) else {
            throw DerivedIntelligenceCoordinatorError.invalidScope
        }
    }

    private func result(
        for itemInput: DerivedIntelligenceItemInput,
        input: DerivedIntelligenceInput
    ) throws -> DerivedIntelligenceItemResult {
        let workItem = itemInput.workItem
        let confirmedRelations = trustedRelations(workItem.relations, scope: input.scope)
        let isOwned = confirmedRelations.contains {
            $0.objectNodeID == input.currentUserNodeID
                && [.authored, .assigned, .projectWrapsContent].contains($0.kind)
        }
        let latestProgress = latestProgress(
            timeline: itemInput.timeline,
            currentUserNodeID: input.currentUserNodeID
        )
        let waitingEvidence = EvidenceReference(
            id: EvidenceID(rawValue: "workflow-\(workItem.id.rawValue)")!,
            source: .localWorkflow,
            locator: .localWorkflow("workflow-state"),
            authority: .localWorkflow(
                accountID: input.scope.accountID,
                organizationID: input.scope.organizationID
            ),
            nodeID: workItem.primaryNodeID,
            confidence: .confirmed,
            confirmation: .confirmed,
            observedAt: workItem.workflow.updatedAt
        )
        let reasons = [
            DirectResponsibilityRule().evaluate(
                relations: confirmedRelations,
                context: AttentionRuleContext(
                    currentUserNodeID: input.currentUserNodeID,
                    visibleTeamNodeIDs: input.visibleTeamNodeIDs,
                    evaluatedAt: input.evaluatedAt
                )
            ),
            ConversationFollowUpRule().evaluate(
                relations: confirmedRelations,
                timeline: itemInput.timeline,
                context: ConversationRuleContext(
                    currentUserNodeID: input.currentUserNodeID,
                    visibleTeamNodeIDs: input.visibleTeamNodeIDs,
                    latestQualifyingProgressAt: latestProgress?.occurredAt,
                    evaluatedAt: input.evaluatedAt
                )
            ),
            pullRequestReasons(for: itemInput, currentUserNodeID: input.currentUserNodeID, evaluatedAt: input.evaluatedAt),
            ProgressAttentionRule().evaluate(
                input: ProgressRuleInput(
                    isOwnedByCurrentUser: isOwned,
                    latestQualifyingProgress: latestProgress,
                    sourceIssueLastUpdatedAt: workItem.sourceKind == .issue ? workItem.lastRelevantActivityAt : nil,
                    sourceIssueEvidence: workItem.sourceKind == .issue
                        ? EvidenceReference(
                            id: EvidenceID(rawValue: "work-item-\(workItem.primaryNodeID.rawValue)")!,
                            source: .graphQL,
                            locator: .legacyUnverified,
                            authority: .legacyUnverified,
                            nodeID: workItem.primaryNodeID,
                            confidence: .provisional,
                            confirmation: .provisional,
                            observedAt: workItem.lastRelevantActivityAt
                        )
                        : nil,
                    linkedPullRequests: linkedPullRequests(from: confirmedRelations),
                    dueActions: workItem.openActionItems.map {
                        DueActionEvidence(
                            id: $0.id,
                            isOpen: true,
                            dueAt: $0.dueAt,
                            evidence: EvidenceReference(
                                id: EvidenceID(rawValue: "action-\($0.id.rawValue)")!,
                                source: .localWorkflow,
                                locator: .localWorkflow("action-state"),
                                authority: .localWorkflow(
                                    accountID: input.scope.accountID,
                                    organizationID: input.scope.organizationID
                                ),
                                nodeID: workItem.primaryNodeID,
                                confidence: .confirmed,
                                confirmation: .confirmed,
                                observedAt: $0.updatedAt
                            )
                        )
                    }
                ),
                context: ProgressRuleContext(
                    businessDayPolicy: input.businessDayPolicy,
                    calendar: input.calendar,
                    evaluatedAt: input.evaluatedAt
                )
            ),
            WaitingAttentionRule().evaluate(
                input: WaitingRuleInput(
                    workflow: WaitingWorkflowEvidence(
                        status: workItem.workflow.status,
                        beganAt: workItem.workflow.updatedAt,
                        followUpAt: workItem.workflow.followUpAt,
                        evidence: waitingEvidence
                    ),
                    awaitedActorNodeID: awaitedActor(from: confirmedRelations),
                    responses: itemInput.timeline.compactMap {
                        guard let actorNodeID = $0.actor?.nodeID else { return nil }
                        return AwaitedActorResponseEvidence(
                            actorNodeID: actorNodeID,
                            occurredAt: $0.occurredAt,
                            evidence: timelineEvidence(for: $0)
                        )
                    }
                ),
                context: WaitingRuleContext(evaluatedAt: input.evaluatedAt)
            )
        ].flatMap(\.reasons)
        var reasonsByID: [String: AttentionReason] = [:]
        for reason in reasons {
            reasonsByID[reason.id] = reason
        }
        let orderedReasons: [AttentionReason] = reasonsByID.values.sorted {
            $0.strength == $1.strength ? $0.id < $1.id : $0.strength > $1.strength
        }
        let rankedWorkItem = replacing(workItem, reasons: orderedReasons)
        let hasNewRelevantActivity = orderedReasons.contains { reason in
            reason.category == AttentionCategory.conversation
        }
        let score = ranker.score(
            for: rankedWorkItem,
            at: input.evaluatedAt,
            repositoryPreference: workItem.repository.map {
                input.repositoryPreferences[$0.id] ?? 0
            } ?? 0,
            hasNewRelevantActivity: hasNewRelevantActivity
        )
        let finalWorkItem = replacing(rankedWorkItem, score: score)
        let hasWaitingWakeUp = orderedReasons.contains {
            $0.ruleID == WaitingAttentionRuleID.awaitedActorResponded.rawValue
                || $0.ruleID == WaitingAttentionRuleID.followUpDue.rawValue
        }
        return DerivedIntelligenceItemResult(
            workItemID: workItem.id,
            attentionReasons: orderedReasons,
            score: score,
            disposition: effectiveDisposition(
                for: finalWorkItem,
                at: input.evaluatedAt,
                hasWaitingWakeUp: hasWaitingWakeUp
            ),
            isOwnedByCurrentUser: isOwned,
            searchDocument: bounded(itemInput.searchDocument)
        )
    }

    /// A wake-up is an effective Inbox disposition only. The persisted Waiting
    /// state remains intact so users can keep their explicit workflow context.
    func effectiveDisposition(
        for workItem: WorkItem,
        at date: Date,
        hasWaitingWakeUp: Bool
    ) -> InboxDisposition {
        if workItem.state == .inaccessible {
            return .inaccessible
        }
        if workItem.workflow.isSnoozed(at: date) {
            return .snoozed
        }
        if workItem.workflow.status == .archived {
            return .archived
        }
        if workItem.workflow.status == .waiting && hasWaitingWakeUp {
            return .inbox
        }
        return InboxEligibilityRule().disposition(for: workItem, at: date)
    }

    private func pullRequestReasons(
        for item: DerivedIntelligenceItemInput,
        currentUserNodeID: GitHubNodeID,
        evaluatedAt: Date
    ) -> RuleEvaluation {
        guard item.workItem.sourceKind == .pullRequest else {
            return RuleEvaluation(reasons: [])
        }
        let authored = item.workItem.members.contains {
            $0.role == .primary && $0.content.author?.nodeID == currentUserNodeID
        } || item.workItem.relations.contains {
            $0.kind == .authored && $0.objectNodeID == currentUserNodeID && $0.confidence == .confirmed
        }
        let latestResponseOrCommit = item.timeline
            .filter {
                $0.actor?.nodeID == currentUserNodeID
                    && [.commented, .reviewed, .committed].contains($0.kind)
            }
            .map(\.occurredAt)
            .max()
        return PullRequestAttentionRule().evaluate(
            input: PullRequestRuleInput(
                isAuthoredByCurrentUser: authored,
                latestCurrentUserResponseOrCommitAt: latestResponseOrCommit,
                reviews: item.pullRequestReviews,
                reviewThreads: item.pullRequestReviewThreads
            ),
            context: PullRequestRuleContext(currentUserNodeID: currentUserNodeID, evaluatedAt: evaluatedAt)
        )
    }

    private func latestProgress(
        timeline: [TimelineEventSummary],
        currentUserNodeID: GitHubNodeID
    ) -> QualifyingProgressEvidence? {
        timeline
            .filter {
                $0.actor?.nodeID == currentUserNodeID
                    && [.commented, .reviewed, .committed].contains($0.kind)
            }
            .max {
                ($0.occurredAt, $0.id.rawValue) < ($1.occurredAt, $1.id.rawValue)
            }
            .map { QualifyingProgressEvidence(occurredAt: $0.occurredAt, evidence: timelineEvidence(for: $0)) }
    }

    private func linkedPullRequests(from relations: [WorkRelation]) -> [LinkedPullRequestProgressEvidence] {
        relations
            .filter { $0.kind == .linkedPullRequest }
            .flatMap { relation in
                relation.evidence.map {
                    LinkedPullRequestProgressEvidence(startedAt: relation.observedAt, evidence: $0)
                }
            }
    }

    /// Legacy or revision-stale evidence can remain in the encrypted vault for
    /// explainability, but it must never drive current deterministic reasons.
    private func trustedRelations(
        _ relations: [WorkRelation],
        scope: SynchronizationScope
    ) -> [WorkRelation] {
        relations.compactMap { relation in
            guard relation.confidence == .confirmed else { return nil }
            let evidence = relation.evidence.filter { evidence in
                guard evidence.confidence == .confirmed,
                      evidence.confirmation == .confirmed
                else { return false }
                switch evidence.authority {
                case let .github(evidenceScope, _, _):
                    return evidenceScope == scope
                case let .localWorkflow(accountID, organizationID):
                    return accountID == scope.accountID
                        && organizationID == scope.organizationID
                case .legacyUnverified:
                    return false
                }
            }
            guard !evidence.isEmpty else { return nil }
            return WorkRelation(
                kind: relation.kind,
                subjectNodeID: relation.subjectNodeID,
                objectNodeID: relation.objectNodeID,
                confidence: relation.confidence,
                evidence: evidence,
                observedAt: relation.observedAt
            )
        }
    }

    private func awaitedActor(from relations: [WorkRelation]) -> GitHubNodeID? {
        relations
            .filter { $0.kind == .awaitingResponse }
            .compactMap(\.objectNodeID)
            .sorted { $0.rawValue < $1.rawValue }
            .first
    }

    private func timelineEvidence(for event: TimelineEventSummary) -> EvidenceReference {
        EvidenceReference(
            id: EvidenceID(rawValue: "timeline-\(event.id.rawValue)")!,
            source: .restTimeline,
            locator: .legacyUnverified,
            authority: .legacyUnverified,
            nodeID: event.subjectNodeID,
            eventID: event.id,
            confidence: .provisional,
            confirmation: .provisional,
            observedAt: event.occurredAt,
            excerpt: event.body
        )
    }

    private func bounded(_ document: SearchDocument) -> SearchDocument {
        let maximumFieldBytes = 16 * 1_024
        func limit(_ value: String) -> String {
            guard value.utf8.count > maximumFieldBytes else { return value }
            var end = value.startIndex
            var usedBytes = 0
            while end < value.endIndex {
                let next = value.index(after: end)
                let byteCount = value[end..<next].utf8.count
                guard usedBytes + byteCount <= maximumFieldBytes else { break }
                usedBytes += byteCount
                end = next
            }
            return String(value[..<end])
        }
        return SearchDocument(
            accountID: document.accountID,
            organizationID: document.organizationID,
            workItemID: document.workItemID,
            nodeID: document.nodeID,
            title: limit(document.title),
            body: limit(document.body),
            repository: limit(document.repository),
            labels: limit(document.labels),
            people: limit(document.people),
            projectValues: limit(document.projectValues),
            actionText: limit(document.actionText),
            localNote: limit(document.localNote)
        )
    }

    private func replacing(_ item: WorkItem, reasons: [AttentionReason]? = nil, score: AttentionScore? = nil) -> WorkItem {
        WorkItem(
            id: item.id,
            accountID: item.accountID,
            organizationID: item.organizationID,
            primaryNodeID: item.primaryNodeID,
            title: item.title,
            state: item.state,
            sourceKind: item.sourceKind,
            sourceURL: item.sourceURL,
            repository: item.repository,
            members: item.members,
            contextLinks: item.contextLinks,
            relations: item.relations,
            attentionReasons: reasons ?? item.attentionReasons,
            actionItems: item.actionItems,
            workflow: item.workflow,
            freshness: item.freshness,
            lastRelevantActivityAt: item.lastRelevantActivityAt,
            score: score ?? item.score
        )
    }

    private func menuCounts(for items: [DerivedIntelligenceItemResult]) -> DerivedMenuCounts {
        DerivedMenuCounts(
            inbox: items.filter { $0.disposition == .inbox }.count,
            waiting: items.filter { $0.disposition == .waiting }.count,
            snoozed: items.filter { $0.disposition == .snoozed }.count,
            archived: items.filter { $0.disposition == .archived }.count,
            resolved: items.filter { $0.disposition == .resolved }.count,
            informational: items.filter { $0.disposition == .informational }.count,
            inaccessible: items.filter { $0.disposition == .inaccessible }.count,
            myWork: items.filter(\.isOwnedByCurrentUser).count,
            reviews: items.filter {
                $0.attentionReasons.contains {
                    $0.ruleID == AttentionRuleID.directReviewRequest.rawValue
                        || $0.ruleID == AttentionRuleID.teamReviewRequest.rawValue
                }
            }.count,
            allWork: items.count
        )
    }

    private func aiCandidates(
        for items: [DerivedIntelligenceItemResult],
        coverageState: DerivedIntelligenceCoverageState,
        isProvisional: Bool,
        policy: DerivedAIPolicy,
        inputsByID: [WorkItemID: DerivedIntelligenceItemInput]
    ) -> (candidates: [DerivedAICandidate], exclusions: [DerivedAICandidateExclusion]) {
        var candidates: [DerivedAICandidate] = []
        var exclusions: [DerivedAICandidateExclusion] = []
        for item in items where item.disposition == .inbox && !item.attentionReasons.isEmpty {
            if coverageState != .trusted || isProvisional {
                exclusions.append(.init(workItemID: item.workItemID, reason: .incompleteCoverage))
            } else if !policy.permitsCandidates {
                exclusions.append(.init(workItemID: item.workItemID, reason: .policyUnavailable))
            } else if inputsByID[item.workItemID]?.hasChangedAIFingerprint == false {
                exclusions.append(.init(workItemID: item.workItemID, reason: .unchangedFingerprint))
            } else if inputsByID[item.workItemID]?.hasValidCachedAIAnalysis == true {
                exclusions.append(.init(workItemID: item.workItemID, reason: .cachedAnalysis))
            } else {
                let reasons = item.attentionReasons.map(\.id).sorted()
                candidates.append(
                    DerivedAICandidate(
                        id: "\(item.workItemID.rawValue):\(reasons.joined(separator: ","))",
                        workItemID: item.workItemID,
                        score: item.score,
                        triggerReasonIDs: reasons
                    )
                )
            }
        }
        return (
            candidates.sorted {
                $0.score == $1.score ? $0.workItemID.rawValue < $1.workItemID.rawValue : $0.score > $1.score
            },
            exclusions.sorted { $0.workItemID.rawValue < $1.workItemID.rawValue }
        )
    }
}
