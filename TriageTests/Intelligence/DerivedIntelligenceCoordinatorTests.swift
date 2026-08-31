import XCTest
@testable import Triage

final class DerivedIntelligenceCoordinatorTests: XCTestCase {
    private let accountID = AccountID(rawValue: "account")!
    private let organizationID = OrganizationID(rawValue: "organization")!
    private let currentUserID = GitHubNodeID(rawValue: "current-user")!
    private let reviewerID = GitHubNodeID(rawValue: "reviewer")!
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)

    private var synchronizationScope: SynchronizationScope {
        SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability")!
        )
    }

    func testRecomputeIsDeterministicAndPreservesRuleEvidence() throws {
        let first = try DerivedIntelligenceCoordinator().recompute(input(items: [item(id: "z"), item(id: "a")]))
        let second = try DerivedIntelligenceCoordinator().recompute(input(items: [item(id: "a"), item(id: "z")]))

        XCTAssertEqual(first.items.map(\.workItemID.rawValue), ["a", "z"])
        XCTAssertEqual(
            first.items.map { $0.attentionReasons.map(\.id) },
            second.items.map { $0.attentionReasons.map(\.id) }
        )
        XCTAssertEqual(first.items.map(\.score), second.items.map(\.score))
        XCTAssertEqual(first.menuCounts, DerivedMenuCounts(
            inbox: 2, waiting: 0, snoozed: 0, archived: 0, resolved: 0,
            informational: 0, inaccessible: 0, myWork: 2, reviews: 0, allWork: 2
        ))
        XCTAssertEqual(first.aiCandidates.map(\.workItemID.rawValue), ["a", "z"])

        let reasons = try XCTUnwrap(first.items.first?.attentionReasons)
        let changesRequested = try XCTUnwrap(reasons.first { $0.ruleID == PullRequestAttentionRuleID.changesRequested.rawValue })
        XCTAssertEqual(changesRequested.evidence.map(\.id.rawValue), ["review-a"])
        let mention = try XCTUnwrap(reasons.first { $0.ruleID == ConversationAttentionRuleID.directMentionAfterProgress.rawValue })
        XCTAssertEqual(mention.evidence.map(\.id.rawValue), ["mention-a"])
    }

    func testUnknownCoverageExcludesAIWithoutRemovingActionableItem() throws {
        let output = try DerivedIntelligenceCoordinator().recompute(
            input(items: [item(id: "unknown")], requirements: [], records: [])
        )

        XCTAssertEqual(output.coverageState, .unknown)
        XCTAssertEqual(output.menuCounts.inbox, 1)
        XCTAssertTrue(output.aiCandidates.isEmpty)
        XCTAssertEqual(
            output.aiCandidateExclusions,
            [.init(workItemID: WorkItemID(rawValue: "unknown")!, reason: .incompleteCoverage)]
        )
    }

    func testPartialCoverageExcludesAIWithoutTreatingTheInboxAsEmpty() throws {
        let output = try DerivedIntelligenceCoordinator().recompute(
            input(items: [item(id: "partial")], records: [coverageRecord(status: .partial)])
        )

        XCTAssertEqual(output.coverageState, .incomplete)
        XCTAssertEqual(output.menuCounts.inbox, 1)
        XCTAssertEqual(output.aiCandidateExclusions.first?.reason, .incompleteCoverage)
    }

    func testProvisionalInputExcludesAIWhilePreservingTrustedCoverage() throws {
        let output = try DerivedIntelligenceCoordinator().recompute(
            input(items: [item(id: "provisional")], isProvisional: true)
        )

        XCTAssertEqual(output.coverageState, .trusted)
        XCTAssertEqual(output.menuCounts.inbox, 1)
        XCTAssertTrue(output.aiCandidates.isEmpty)
        XCTAssertEqual(
            output.aiCandidateExclusions,
            [.init(workItemID: WorkItemID(rawValue: "provisional")!, reason: .incompleteCoverage)]
        )
    }

    func testPersistedRepositoryPreferenceContributesToDerivedRanking() throws {
        let repositoryID = RepositoryID(rawValue: "repository-preference")!
        let output = try DerivedIntelligenceCoordinator().recompute(
            input(
                items: [item(id: "repository-preference", repositoryID: repositoryID)],
                repositoryPreferences: [repositoryID: 42]
            )
        )

        XCTAssertEqual(output.items.first?.score.breakdown["repositoryPreference"], 42)
    }

    func testSnapshotRecomputeReturnsTheExactSourceMarkerForPublicationGating() throws {
        let input = input(items: [item(id: "marker")])
        let marker = DerivedIntelligenceSourceRevisionMarker(
            scope: synchronizationScope,
            sourceRevision: "derived-source-r1"
        )
        let snapshot = DerivedIntelligenceInputSnapshot(
            input: input,
            sourceStates: [],
            sourceRevisions: [WorkItemID(rawValue: "marker")!: "primary-r1"],
            aggregateSourceRevision: marker.sourceRevision,
            publicationMarker: marker
        )

        let result = try DerivedIntelligenceCoordinator().recompute(snapshot: snapshot)

        XCTAssertEqual(result.sourceRevisionMarker, marker)
        XCTAssertEqual(result.output.items.map(\.workItemID.rawValue), ["marker"])
    }

    func testLegacyUnverifiedRelationsCannotDriveCurrentOwnershipOrConversationReasons() throws {
        let output = try DerivedIntelligenceCoordinator().recompute(
            input(items: [item(id: "legacy", trustRelations: false)])
        )

        XCTAssertFalse(output.items[0].isOwnedByCurrentUser)
        XCTAssertFalse(output.items[0].attentionReasons.contains {
            $0.ruleID == ConversationAttentionRuleID.directMentionAfterProgress.rawValue
                || $0.ruleID == ConversationAttentionRuleID.newActivityOnParticipatedWork.rawValue
                || $0.ruleID == PullRequestAttentionRuleID.changesRequested.rawValue
                || $0.ruleID == PullRequestAttentionRuleID.newReviewFeedback.rawValue
                || $0.ruleID == PullRequestAttentionRuleID.unresolvedReviewThreads.rawValue
        })
    }

    func testRevisionStaleGitHubRelationsCannotDriveCurrentReasons() throws {
        let staleScope = SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: CredentialRevision(rawValue: "stale-credential")!,
            capabilityRevision: synchronizationScope.capabilityRevision
        )
        let output = try DerivedIntelligenceCoordinator().recompute(
            input(items: [item(id: "stale", relationScope: staleScope)])
        )

        XCTAssertFalse(output.items[0].isOwnedByCurrentUser)
        XCTAssertFalse(output.items[0].attentionReasons.contains {
            $0.ruleID == ConversationAttentionRuleID.directMentionAfterProgress.rawValue
                || $0.ruleID == ConversationAttentionRuleID.newActivityOnParticipatedWork.rawValue
                || $0.ruleID == PullRequestAttentionRuleID.changesRequested.rawValue
                || $0.ruleID == PullRequestAttentionRuleID.newReviewFeedback.rawValue
                || $0.ruleID == PullRequestAttentionRuleID.unresolvedReviewThreads.rawValue
        })
    }

    func testStatusCheckReasonsRequireTheCurrentPullRequestRevisionMarker() throws {
        let base = item(id: "status-marker")
        let nodeID = base.workItem.primaryNodeID
        let primary = currentPrimaryEvidence(for: nodeID, feature: .pullRequests)
        let statusEvidence = EvidenceReference(
            id: EvidenceID(rawValue: "status-check-marker-test")!,
            source: .graphQL,
            locator: .query("TriagePullRequestStatusChecks"),
            authority: .github(
                scope: synchronizationScope,
                feature: .statusChecks,
                streamID: SyncStreamID(rawValue: "pull-request-status-checks-organization")!
            ),
            nodeID: nodeID,
            sourceRevision: primary.sourceRevision,
            confidence: .confirmed,
            confirmation: .confirmed,
            observedAt: now.addingTimeInterval(-1)
        )
        let check = PullRequestStatusCheck(
            context: "CheckRun:CHECK_1",
            state: .failure,
            isRequired: true,
            completedAt: now.addingTimeInterval(-1),
            evidence: statusEvidence
        )
        func derived(marker: EvidenceReference) -> DerivedIntelligenceItemInput {
            .init(
                workItem: base.workItem,
                primaryEvidence: primary,
                timeline: base.timeline,
                timelineEvidence: base.timelineEvidence,
                pullRequestReviews: [],
                pullRequestReviewThreads: [],
                pullRequestStatusChecks: [check],
                pullRequestMergeableState: "MERGEABLE",
                pullRequestStatusCheckMarkerEvidence: marker,
                searchDocument: base.searchDocument
            )
        }
        let currentOutput = try DerivedIntelligenceCoordinator().recompute(input(items: [derived(marker: statusEvidence)]))
        XCTAssertTrue(currentOutput.items[0].attentionReasons.contains {
            $0.ruleID == PullRequestAttentionRuleID.requiredCheckFailed.rawValue
        })

        let staleMarker = EvidenceReference(
            id: statusEvidence.id,
            source: statusEvidence.source,
            locator: statusEvidence.locator,
            authority: statusEvidence.authority,
            nodeID: nodeID,
            sourceRevision: "obsolete-revision",
            confidence: statusEvidence.confidence,
            confirmation: statusEvidence.confirmation,
            observedAt: statusEvidence.observedAt
        )
        let staleOutput = try DerivedIntelligenceCoordinator().recompute(input(items: [derived(marker: staleMarker)]))
        XCTAssertFalse(staleOutput.items[0].attentionReasons.contains {
            $0.ruleID == PullRequestAttentionRuleID.requiredCheckFailed.rawValue
                || $0.ruleID == PullRequestAttentionRuleID.mergeableWaitingOnUserAction.rawValue
        })
    }

    func testOnlyCurrentRevisionBoundTimelineEvidenceCanPublishWaitingReasonOrAICandidate() throws {
        let current = waitingItem(id: "evidence", followUpAt: nil, snoozedUntil: nil)
        let event = try XCTUnwrap(current.timeline.first)
        let staleScope = SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: CredentialRevision(rawValue: "stale-credential")!,
            capabilityRevision: synchronizationScope.capabilityRevision
        )
        let rejectedEvidence = [
            EvidenceReference(
                id: EvidenceID(rawValue: "legacy-timeline")!,
                source: .legacyUnverified,
                locator: .legacyUnverified,
                authority: .legacyUnverified,
                nodeID: event.subjectNodeID,
                eventID: event.id,
                confidence: .provisional,
                confirmation: .provisional,
                observedAt: event.occurredAt
            ),
            EvidenceReference(
                id: EvidenceID(rawValue: "stale-timeline")!,
                source: .restTimeline,
                locator: .endpoint("/repos/example/repository/issues/1/timeline"),
                authority: .github(
                    scope: staleScope,
                    feature: .timelines,
                    streamID: SyncStreamID(rawValue: "timeline:\(event.subjectNodeID.rawValue)")!
                ),
                nodeID: event.subjectNodeID,
                eventID: event.id,
                sourceRevision: "old-revision",
                confidence: .confirmed,
                confirmation: .confirmed,
                observedAt: event.occurredAt
            ),
            EvidenceReference(
                id: EvidenceID(rawValue: "revisionless-timeline")!,
                source: .restTimeline,
                locator: .endpoint("/repos/example/repository/issues/1/timeline"),
                authority: .github(
                    scope: synchronizationScope,
                    feature: .timelines,
                    streamID: SyncStreamID(rawValue: "timeline:\(event.subjectNodeID.rawValue)")!
                ),
                nodeID: event.subjectNodeID,
                eventID: event.id,
                confidence: .confirmed,
                confirmation: .confirmed,
                observedAt: event.occurredAt
            ),
            EvidenceReference(
                id: EvidenceID(rawValue: "stale-revision-timeline")!,
                source: .restTimeline,
                locator: .endpoint("/repos/example/repository/issues/1/timeline"),
                authority: .github(
                    scope: synchronizationScope,
                    feature: .timelines,
                    streamID: SyncStreamID(rawValue: "timeline:\(event.subjectNodeID.rawValue)")!
                ),
                nodeID: event.subjectNodeID,
                eventID: event.id,
                sourceRevision: "superseded-revision",
                confidence: .confirmed,
                confirmation: .confirmed,
                observedAt: event.occurredAt
            )
        ]

        for evidence in rejectedEvidence {
            let candidate = DerivedIntelligenceItemInput(
                workItem: current.workItem,
                primaryEvidence: current.primaryEvidence,
                timeline: current.timeline,
                timelineEvidence: [event.id: evidence],
                searchDocument: current.searchDocument
            )
            let output = try DerivedIntelligenceCoordinator().recompute(input(items: [candidate]))
            XCTAssertTrue(output.items[0].attentionReasons.isEmpty)
            XCTAssertTrue(output.aiCandidates.isEmpty)
        }

        let accepted = try DerivedIntelligenceCoordinator().recompute(input(items: [current]))
        XCTAssertEqual(
            accepted.items[0].attentionReasons.map(\.ruleID),
            [WaitingAttentionRuleID.awaitedActorResponded.rawValue]
        )
        XCTAssertEqual(accepted.aiCandidates.map(\.workItemID), [current.workItem.id])
    }

    func testRecomputeBoundsUTF8SearchFieldsWithoutBreakingCharacters() throws {
        let source = item(id: "bounded")
        let document = SearchDocument(
            accountID: accountID,
            organizationID: organizationID,
            workItemID: source.workItem.id,
            nodeID: source.workItem.primaryNodeID,
            title: "Title",
            body: String(repeating: "é", count: 20_000),
            repository: "",
            labels: "",
            people: "",
            projectValues: "",
            actionText: "",
            localNote: ""
        )
        let bounded = DerivedIntelligenceItemInput(
            workItem: source.workItem,
            timeline: source.timeline,
            pullRequestReviews: source.pullRequestReviews,
            searchDocument: document
        )

        let output = try DerivedIntelligenceCoordinator().recompute(input(items: [bounded]))

        XCTAssertLessThanOrEqual(output.items[0].searchDocument.body.utf8.count, 16 * 1_024)
        XCTAssertFalse(output.items[0].searchDocument.body.contains("\u{FFFD}"))
    }

    func testAwaitedActorResponseWakesWaitingItemIntoInboxWithoutRewritingWorkflow() throws {
        let waiting = waitingItem(id: "response", followUpAt: nil, snoozedUntil: nil)

        let output = try DerivedIntelligenceCoordinator().recompute(input(items: [waiting]))

        XCTAssertEqual(output.items[0].disposition, .inbox)
        XCTAssertEqual(
            output.items[0].attentionReasons.map(\.ruleID),
            [WaitingAttentionRuleID.awaitedActorResponded.rawValue]
        )
        XCTAssertEqual(waiting.workItem.workflow.status, .waiting)
    }

    func testStaleSameScopeRelationsCannotDriveDirectConversationOrWaitingRules() throws {
        let base = item(id: "removed-relation")
        let nodeID = base.workItem.primaryNodeID
        let staleEvidence = EvidenceReference(
            id: EvidenceID(rawValue: "removed-relation-evidence")!,
            source: .graphQL,
            locator: .query("graphql:TriageHydrateNodes/node=\(nodeID.rawValue)"),
            authority: .github(
                scope: synchronizationScope,
                feature: .pullRequests,
                streamID: SyncStreamID(rawValue: "pull-requests")!
            ),
            nodeID: nodeID,
            sourceRevision: "revision-before-removal",
            confidence: .confirmed,
            confirmation: .confirmed,
            observedAt: now.addingTimeInterval(-10)
        )
        let staleRelations: [WorkRelation] = [
            .init(kind: .assigned, subjectNodeID: nodeID, objectNodeID: currentUserID, confidence: .confirmed, evidence: [staleEvidence], observedAt: now.addingTimeInterval(-10)),
            .init(kind: .reviewRequestedDirectly, subjectNodeID: nodeID, objectNodeID: currentUserID, confidence: .confirmed, evidence: [staleEvidence], observedAt: now.addingTimeInterval(-10)),
            .init(kind: .mentioned, subjectNodeID: nodeID, objectNodeID: currentUserID, confidence: .confirmed, evidence: [staleEvidence], observedAt: now.addingTimeInterval(-10)),
            .init(kind: .awaitingResponse, subjectNodeID: nodeID, objectNodeID: reviewerID, confidence: .confirmed, evidence: [staleEvidence], observedAt: now.addingTimeInterval(-10))
        ]
        let staleWorkItem = workItem(
            from: base.workItem,
            relations: staleRelations,
            workflow: WorkflowState(status: .waiting, updatedAt: now.addingTimeInterval(-20))
        )
        let candidate = DerivedIntelligenceItemInput(
            workItem: staleWorkItem,
            primaryEvidence: base.primaryEvidence,
            timeline: base.timeline,
            timelineEvidence: base.timelineEvidence,
            searchDocument: base.searchDocument
        )

        let output = try DerivedIntelligenceCoordinator().recompute(input(items: [candidate]))
        let ruleIDs = Set(output.items[0].attentionReasons.map(\.ruleID))
        XCTAssertFalse(ruleIDs.contains(AttentionRuleID.assignedToCurrentUser.rawValue))
        XCTAssertFalse(ruleIDs.contains(AttentionRuleID.directReviewRequest.rawValue))
        XCTAssertFalse(ruleIDs.contains(ConversationAttentionRuleID.directMentionAfterProgress.rawValue))
        XCTAssertFalse(ruleIDs.contains(WaitingAttentionRuleID.awaitedActorResponded.rawValue))
    }

    func testNonResponseActorEventDoesNotWakeWaiting() throws {
        let waiting = waitingItem(
            id: "non-response",
            followUpAt: nil,
            snoozedUntil: nil,
            responseKind: .assigned
        )

        let output = try DerivedIntelligenceCoordinator().recompute(input(items: [waiting]))
        XCTAssertEqual(output.items[0].disposition, .waiting)
        XCTAssertFalse(output.items[0].attentionReasons.contains {
            $0.ruleID == WaitingAttentionRuleID.awaitedActorResponded.rawValue
        })
    }

    func testDueWaitingFollowUpWakesItemIntoInbox() throws {
        let waiting = waitingItem(id: "due", followUpAt: now, snoozedUntil: nil, includeResponse: false)

        let output = try DerivedIntelligenceCoordinator().recompute(input(items: [waiting]))

        XCTAssertEqual(output.items[0].disposition, .inbox)
        XCTAssertEqual(
            output.items[0].attentionReasons.map(\.ruleID),
            [WaitingAttentionRuleID.followUpDue.rawValue]
        )
        XCTAssertEqual(waiting.workItem.workflow.status, .waiting)
    }

    func testSnoozeAndArchiveTakePrecedenceOverWaitingWakeUp() throws {
        let snoozed = waitingItem(
            id: "snoozed",
            followUpAt: now,
            snoozedUntil: now.addingTimeInterval(60),
            includeResponse: false
        )
        let output = try DerivedIntelligenceCoordinator().recompute(input(items: [snoozed]))
        XCTAssertEqual(output.items[0].disposition, .snoozed)

        let archived = WorkItem(
            id: WorkItemID(rawValue: "archived")!,
            accountID: accountID,
            organizationID: organizationID,
            primaryNodeID: GitHubNodeID(rawValue: "archived-node")!,
            title: "Archived",
            state: .active,
            sourceKind: .issue,
            sourceURL: nil,
            repository: nil,
            members: [],
            contextLinks: [],
            relations: [],
            attentionReasons: [],
            actionItems: [],
            workflow: WorkflowState(status: .archived, updatedAt: now),
            freshness: FreshnessState(status: .fresh),
            lastRelevantActivityAt: now,
            score: AttentionScore(value: 0, breakdown: [:])
        )
        XCTAssertEqual(
            DerivedIntelligenceCoordinator().effectiveDisposition(
                for: archived,
                at: now,
                hasWaitingWakeUp: true
            ),
            .archived
        )
    }

    private func input(
        items: [DerivedIntelligenceItemInput],
        requirements: [CoverageRequirement]? = nil,
        records: [CoverageRecord]? = nil,
        isProvisional: Bool = false,
        repositoryPreferences: [RepositoryID: Int] = [:]
    ) -> DerivedIntelligenceInput {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return DerivedIntelligenceInput(
            scope: synchronizationScope,
            currentUserNodeID: currentUserID,
            visibleTeamNodeIDs: [],
            coverageRequirements: requirements ?? [
                CoverageRequirement(
                    feature: .reviews,
                    repositoryID: nil,
                    streamID: SyncStreamID(rawValue: "reviews")!
                )
            ],
            coverageRecords: records ?? [coverageRecord(status: .complete)],
            calendar: calendar,
            aiPolicy: DerivedAIPolicy(
                isOrganizationConsentActive: true,
                isAuthenticationValid: true,
                isEntitled: true,
                hasAvailableBudget: true
            ),
            repositoryPreferences: repositoryPreferences,
            isProvisional: isProvisional,
            evaluatedAt: now,
            items: items
        )
    }

    private func item(
        id: String,
        trustRelations: Bool = true,
        relationScope: SynchronizationScope? = nil,
        repositoryID: RepositoryID? = nil
    ) -> DerivedIntelligenceItemInput {
        let workItemID = WorkItemID(rawValue: id)!
        let nodeID = GitHubNodeID(rawValue: "node-\(id)")!
        let evidenceScope = relationScope ?? synchronizationScope
        let evidence = EvidenceReference(
            id: EvidenceID(rawValue: "authored-\(id)")!,
            source: .graphQL,
            locator: trustRelations ? .query("TriageHydrateNodes") : .legacyUnverified,
            authority: trustRelations
                ? .github(
                    scope: evidenceScope,
                    feature: .pullRequests,
                    streamID: SyncStreamID(rawValue: "pull-requests")!
                )
                : .legacyUnverified,
            nodeID: nodeID,
            sourceRevision: "revision-\(id)",
            confidence: trustRelations ? .confirmed : .provisional,
            confirmation: trustRelations ? .confirmed : .provisional,
            observedAt: now
        )
        let workItem = WorkItem(
            id: workItemID,
            accountID: accountID,
            organizationID: organizationID,
            primaryNodeID: nodeID,
            title: "Work \(id)",
            state: .active,
            sourceKind: .pullRequest,
            sourceURL: nil,
            repository: repositoryID.map {
                RepositorySummary(
                    id: $0,
                    nodeID: GitHubNodeID(rawValue: "repository-node-\($0.rawValue)")!,
                    ownerLogin: "octocat",
                    name: "triage",
                    isPrivate: false,
                    isArchived: false,
                    hasDiscussions: false,
                    url: URL(string: "https://github.com/octocat/triage")!
                )
            },
            members: [],
            contextLinks: [],
            relations: [
                WorkRelation(
                    kind: .authored,
                    subjectNodeID: nodeID,
                    objectNodeID: currentUserID,
                    confidence: .confirmed,
                    evidence: [evidence],
                    observedAt: now.addingTimeInterval(-20)
                ),
                WorkRelation(
                    kind: .mentioned,
                    subjectNodeID: nodeID,
                    objectNodeID: currentUserID,
                    confidence: .confirmed,
                    evidence: [
                        EvidenceReference(
                            id: EvidenceID(rawValue: "mention-\(id)")!,
                            source: .restTimeline,
                            locator: trustRelations
                                ? .endpoint("/repos/example/repository/issues/1/timeline")
                                : .legacyUnverified,
                            authority: trustRelations
                                ? .github(
                                    scope: evidenceScope,
                                    feature: .timelines,
                                    streamID: SyncStreamID(rawValue: "timeline:\(nodeID.rawValue)")!
                                )
                                : .legacyUnverified,
                            nodeID: nodeID,
                            sourceRevision: "revision-\(id)",
                            confidence: trustRelations ? .confirmed : .provisional,
                            confirmation: trustRelations ? .confirmed : .provisional,
                            observedAt: now.addingTimeInterval(-1)
                        )
                    ],
                    observedAt: now.addingTimeInterval(-1)
                )
            ],
            attentionReasons: [],
            actionItems: [],
            workflow: WorkflowState(updatedAt: now.addingTimeInterval(-30)),
            freshness: FreshnessState(status: .fresh),
            lastRelevantActivityAt: now,
            score: AttentionScore(value: 0, breakdown: [:])
        )
        let timeline = [
            timelineEvent(id: "progress-\(id)", nodeID: nodeID, actor: currentUserID, at: now.addingTimeInterval(-10)),
            timelineEvent(id: "other-\(id)", nodeID: nodeID, actor: reviewerID, at: now.addingTimeInterval(-5))
        ]
        let timelineEvidence = Dictionary(uniqueKeysWithValues: timeline.map {
            ($0.id, currentTimelineEvidence(for: $0, nodeID: nodeID))
        })
        return DerivedIntelligenceItemInput(
            workItem: workItem,
            primaryEvidence: evidence,
            timeline: timeline,
            timelineEvidence: timelineEvidence,
            pullRequestReviews: [
                PullRequestReviewFeedback(
                    id: GitHubNodeID(rawValue: "review-\(id)")!,
                    authorNodeID: reviewerID,
                    state: .changesRequested,
                    submittedAt: now.addingTimeInterval(-2),
                    evidence: EvidenceReference(
                        id: EvidenceID(rawValue: "review-\(id)")!,
                        source: .restReview,
                        locator: .endpoint("/repos/example/repository/pulls/1/reviews"),
                        authority: .github(
                            scope: synchronizationScope,
                            feature: .reviews,
                            streamID: SyncStreamID(rawValue: "reviews")!
                        ),
                        nodeID: nodeID,
                        sourceRevision: "revision-\(id)",
                        confidence: .confirmed,
                        confirmation: .confirmed,
                        observedAt: now.addingTimeInterval(-2)
                    )
                )
            ],
            searchDocument: SearchDocument(
                accountID: accountID,
                organizationID: organizationID,
                workItemID: workItemID,
                nodeID: nodeID,
                title: "Work \(id)",
                body: "",
                repository: "",
                labels: "",
                people: "",
                projectValues: "",
                actionText: "",
                localNote: ""
            )
        )
    }

    private func waitingItem(
        id: String,
        followUpAt: Date?,
        snoozedUntil: Date?,
        includeResponse: Bool = true,
        responseKind: TimelineEventKind = .commented
    ) -> DerivedIntelligenceItemInput {
        let workItemID = WorkItemID(rawValue: "waiting-\(id)")!
        let nodeID = GitHubNodeID(rawValue: "waiting-node-\(id)")!
        let workflow = WorkflowState(
            status: .waiting,
            snoozedUntil: snoozedUntil,
            followUpAt: followUpAt,
            updatedAt: now.addingTimeInterval(-10)
        )
        let workItem = WorkItem(
            id: workItemID,
            accountID: accountID,
            organizationID: organizationID,
            primaryNodeID: nodeID,
            title: "Waiting \(id)",
            state: .active,
            sourceKind: .issue,
            sourceURL: nil,
            repository: nil,
            members: [],
            contextLinks: [],
            relations: [
                WorkRelation(
                    kind: .awaitingResponse,
                    subjectNodeID: nodeID,
                    objectNodeID: reviewerID,
                    confidence: .confirmed,
                    evidence: [
                        EvidenceReference(
                            id: EvidenceID(rawValue: "awaiting-\(id)")!,
                            source: .localWorkflow,
                            locator: .localWorkflow("waiting-state"),
                            authority: .localWorkflow(
                                accountID: accountID,
                                organizationID: organizationID
                            ),
                            nodeID: nodeID,
                            confidence: .confirmed,
                            confirmation: .confirmed,
                            observedAt: now.addingTimeInterval(-10)
                        )
                    ],
                    observedAt: now.addingTimeInterval(-10)
                )
            ],
            attentionReasons: [],
            actionItems: [],
            workflow: workflow,
            freshness: FreshnessState(status: .fresh),
            lastRelevantActivityAt: now,
            score: AttentionScore(value: 0, breakdown: [:])
        )
        return DerivedIntelligenceItemInput(
            workItem: workItem,
            primaryEvidence: currentPrimaryEvidence(for: nodeID, feature: .issues),
            timeline: includeResponse
                ? [timelineEvent(id: "response-\(id)", nodeID: nodeID, actor: reviewerID, at: now, kind: responseKind)]
                : [],
            timelineEvidence: includeResponse
                ? [
                    GitHubEventID(rawValue: "response-\(id)")!: currentTimelineEvidence(
                        for: timelineEvent(id: "response-\(id)", nodeID: nodeID, actor: reviewerID, at: now, kind: responseKind),
                        nodeID: nodeID
                    )
                ]
                : [:],
            searchDocument: SearchDocument(
                accountID: accountID,
                organizationID: organizationID,
                workItemID: workItemID,
                nodeID: nodeID,
                title: workItem.title,
                body: "",
                repository: "",
                labels: "",
                people: "",
                projectValues: "",
                actionText: "",
                localNote: ""
            )
        )
    }

    private func workItem(
        from source: WorkItem,
        relations: [WorkRelation],
        workflow: WorkflowState
    ) -> WorkItem {
        WorkItem(
            id: source.id,
            accountID: source.accountID,
            organizationID: source.organizationID,
            primaryNodeID: source.primaryNodeID,
            title: source.title,
            state: source.state,
            sourceKind: source.sourceKind,
            sourceURL: source.sourceURL,
            repository: source.repository,
            members: source.members,
            contextLinks: source.contextLinks,
            relations: relations,
            attentionReasons: source.attentionReasons,
            actionItems: source.actionItems,
            workflow: workflow,
            freshness: source.freshness,
            lastRelevantActivityAt: source.lastRelevantActivityAt,
            score: source.score
        )
    }

    private func coverageRecord(status: CoverageStatus) -> CoverageRecord {
        CoverageRecord(
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: nil,
            feature: .reviews,
            streamID: SyncStreamID(rawValue: "reviews")!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: CredentialRevision(rawValue: "credential")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability")!,
            status: status,
            lastSuccessfulAt: now,
            failureDetail: nil
        )
    }

    private func timelineEvent(
        id: String,
        nodeID: GitHubNodeID,
        actor: GitHubNodeID,
        at: Date,
        kind: TimelineEventKind = .commented
    ) -> TimelineEventSummary {
        TimelineEventSummary(
            id: GitHubEventID(rawValue: id)!,
            subjectNodeID: nodeID,
            kind: kind,
            actor: ActorSummary(
                id: ActorID(rawValue: "actor-\(actor.rawValue)")!,
                nodeID: actor,
                login: actor.rawValue,
                displayName: nil,
                avatarURL: nil
            ),
            occurredAt: at,
            url: nil,
            body: nil
        )
    }

    private func currentTimelineEvidence(
        for event: TimelineEventSummary,
        nodeID: GitHubNodeID
    ) -> EvidenceReference {
        EvidenceReference(
            id: EvidenceID(rawValue: "timeline-\(event.id.rawValue)")!,
            source: .restTimeline,
            locator: .endpoint("/repos/example/repository/issues/1/timeline"),
            authority: .github(
                scope: synchronizationScope,
                feature: .timelines,
                streamID: SyncStreamID(rawValue: "timeline:\(nodeID.rawValue)")!
            ),
            nodeID: nodeID,
            eventID: event.id,
            sourceRevision: "revision-\(nodeID.rawValue)",
            confidence: .confirmed,
            confirmation: .confirmed,
            observedAt: event.occurredAt
        )
    }

    private func currentPrimaryEvidence(
        for nodeID: GitHubNodeID,
        feature: CoverageFeature
    ) -> EvidenceReference {
        EvidenceReference(
            id: EvidenceID(rawValue: "hydration-\(nodeID.rawValue)")!,
            source: .graphQL,
            locator: .query("graphql:TriageHydrateNodes/node=\(nodeID.rawValue)"),
            authority: .github(
                scope: synchronizationScope,
                feature: feature,
                streamID: SyncStreamID(rawValue: "hydration-\(feature.rawValue)-\(organizationID.rawValue)")!
            ),
            nodeID: nodeID,
            sourceRevision: "revision-\(nodeID.rawValue)",
            confidence: .confirmed,
            confirmation: .confirmed,
            observedAt: now
        )
    }
}
