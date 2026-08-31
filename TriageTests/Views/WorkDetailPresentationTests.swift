import XCTest
@testable import Triage

final class WorkDetailPresentationTests: XCTestCase {
    func testPartialFreshnessNeverUsesCurrentLabel() {
        let freshness = FreshnessState(status: .partial)

        XCTAssertEqual(WorkDetailPresentation.freshnessTitle(freshness), "Partial coverage")
        XCTAssertNotEqual(WorkDetailPresentation.freshnessTitle(freshness), "Current")
        XCTAssertTrue(WorkDetailPresentation.freshnessDescription(freshness).contains("incomplete"))
    }

    func testEvidenceDeduplicatesAndOrdersNewestFirst() {
        let older = evidence(id: "older", observedAt: 1)
        let newer = evidence(id: "newer", observedAt: 2)
        let item = makeWorkItem(reasons: [reason(evidence: [older, newer])], relations: [relation(evidence: [older])])

        XCTAssertEqual(WorkDetailPresentation.allEvidence(for: item).map(\.id.rawValue), ["newer", "older"])
    }

    func testEmptyEvidenceIsExplicitlyUnavailable() {
        XCTAssertEqual(WorkDetailPresentation.availabilityTitle(for: makeWorkItem()), "No normalized evidence is available")
    }

    func testEveryNonFreshStateKeepsAvailableEvidenceExplicitlyIncomplete() {
        let sourceEvidence = evidence(id: "source", observedAt: 1)
        let nonFreshStates: [FreshnessStatus] = [
            .refreshing,
            .stale,
            .partial,
            .offline,
            .authenticationRequired,
            .ssoRequired,
            .approvalRequired,
            .rateLimited,
            .failed
        ]

        for status in nonFreshStates {
            let item = makeWorkItem(
                reasons: [reason(evidence: [sourceEvidence])],
                freshness: FreshnessState(status: status)
            )

            XCTAssertNotEqual(
                WorkDetailPresentation.freshnessTitle(item.freshness),
                "Current",
                "\(status.rawValue) must not be presented as current."
            )
            XCTAssertEqual(
                WorkDetailPresentation.availabilityTitle(for: item),
                "Evidence may be incomplete",
                "\(status.rawValue) must not turn locally available evidence into a completeness claim."
            )
        }
    }

    func testWaitingActionCarriesTheInspectorChosenFollowUpDate() {
        let chosenDate = Date(timeIntervalSinceReferenceDate: 5_000)

        let action = WorkDetailPresentation.waitingAction(
            for: WorkflowState(updatedAt: .now),
            followUpAt: chosenDate
        )

        guard case let .markWaiting(followUpAt) = action else {
            return XCTFail("An active item should transition to Waiting.")
        }
        XCTAssertEqual(followUpAt, chosenDate)
    }

    func testDefaultFollowUpDateIsOneCalendarDayLater() {
        let calendar = Calendar(identifier: .gregorian)
        let date = Date(timeIntervalSinceReferenceDate: 5_000)

        XCTAssertEqual(
            WorkDetailPresentation.defaultFollowUpDate(from: date, calendar: calendar),
            calendar.date(byAdding: .day, value: 1, to: date)
        )
    }

    func testTimelinePaginationAdvancesWithoutExceedingAvailableEvidence() {
        XCTAssertEqual(WorkDetailPresentation.nextTimelineVisibleCount(current: 20, total: 41), 40)
        XCTAssertEqual(WorkDetailPresentation.nextTimelineVisibleCount(current: 40, total: 41), 41)
        XCTAssertEqual(WorkDetailPresentation.nextTimelineVisibleCount(current: 41, total: 41), 41)
    }

    func testRelatedContentGroupsAndHeaderMetadataUseOnlyNormalizedMembers() {
        let primary = member(id: "node", role: .primary, title: "Primary", kind: .issue, actor: "author")
        let issue = member(id: "issue", role: .linkedIssue, title: "Related issue", kind: .issue, actor: "author")
        let review = member(id: "review", role: .review, title: "Review", kind: .pullRequestReview, actor: "reviewer")
        let label = member(id: "label", role: .comment, title: "needs-review", kind: .label, actor: nil)
        let item = makeWorkItem(members: [primary, issue, review, label])

        XCTAssertEqual(
            WorkDetailPresentation.relatedContentGroups(for: item).map(\.title),
            ["Linked issues", "Pull request reviews", "Comments"]
        )
        XCTAssertEqual(WorkDetailPresentation.actorNames(for: item), ["author", "reviewer"])
        XCTAssertEqual(WorkDetailPresentation.labelTitles(for: item), ["needs-review"])
    }

    func testReviewStateSummariesReflectOnlyRecordedRelationsAndMembers() {
        let item = makeWorkItem(
            relations: [relation(kind: .changesRequested), relation(kind: .reviewRequestedDirectly)],
            members: [member(id: "thread", role: .reviewThread, title: "Thread", kind: .pullRequestReviewThread, actor: nil)]
        )

        XCTAssertEqual(
            WorkDetailPresentation.reviewStateSummaries(for: item),
            ["Changes requested", "Your review requested", "Review threads available"]
        )
    }

    func testConciseSourceBodyTrimsAndMarksOnlyOversizedBodies() throws {
        XCTAssertEqual(
            WorkDetailPresentation.conciseSourceBody("\n  Local body  \n"),
            ConciseSourceBody(markdown: "Local body", isTruncated: false)
        )
        XCTAssertNil(WorkDetailPresentation.conciseSourceBody(" \n "))

        let source = String(repeating: "x", count: WorkDetailPresentation.maximumConciseSourceBodyCharacters + 20)
        let concise = try XCTUnwrap(WorkDetailPresentation.conciseSourceBody(source))
        XCTAssertTrue(concise.isTruncated)
        XCTAssertLessThanOrEqual(concise.markdown.count, WorkDetailPresentation.maximumConciseSourceBodyCharacters)
    }

    func testTimelineAccessibilityIncludesActorContentAndTimestamp() {
        let actor = ActorSummary(
            id: ActorID(rawValue: "actor")!,
            nodeID: GitHubNodeID(rawValue: "actor-node")!,
            login: "octo",
            displayName: "Octo Cat",
            avatarURL: nil
        )
        let event = TimelineEventSummary(
            id: GitHubEventID(rawValue: "event")!,
            subjectNodeID: GitHubNodeID(rawValue: "node")!,
            kind: .commented,
            actor: actor,
            occurredAt: Date(timeIntervalSinceReferenceDate: 1_000),
            url: nil,
            body: "Normalized comment"
        )

        let label = WorkDetailPresentation.timelineAccessibilityLabel(for: event)

        XCTAssertTrue(label.contains("Octo Cat"))
        XCTAssertTrue(label.contains("Normalized comment"))
    }

    private func makeWorkItem(
        reasons: [AttentionReason] = [],
        relations: [WorkRelation] = [],
        members: [WorkItemMember] = [],
        freshness: FreshnessState = FreshnessState(status: .fresh)
    ) -> WorkItem {
        let accountID = AccountID(rawValue: "account")!
        let organizationID = OrganizationID(rawValue: "organization")!
        return WorkItem(
            id: WorkItemID(rawValue: "work")!,
            accountID: accountID,
            organizationID: organizationID,
            primaryNodeID: GitHubNodeID(rawValue: "node")!,
            title: "Title",
            state: .active,
            sourceKind: .issue,
            sourceURL: nil,
            repository: nil,
            members: members,
            contextLinks: [],
            relations: relations,
            attentionReasons: reasons,
            actionItems: [],
            workflow: WorkflowState(updatedAt: .now),
            freshness: freshness,
            lastRelevantActivityAt: .now,
            score: AttentionScore(value: 0, breakdown: [:])
        )
    }

    private func member(
        id: String,
        role: WorkItemMemberRole,
        title: String,
        kind: GitHubContentKind,
        actor: String?
    ) -> WorkItemMember {
        let nodeID = GitHubNodeID(rawValue: id)!
        let actorSummary = actor.map {
            ActorSummary(
                id: ActorID(rawValue: "actor-\($0)")!,
                nodeID: GitHubNodeID(rawValue: "actor-node-\($0)")!,
                login: $0,
                displayName: nil,
                avatarURL: nil
            )
        }
        return WorkItemMember(
            id: nodeID,
            role: role,
            content: GitHubContentSummary(
                id: nodeID,
                kind: kind,
                repository: nil,
                number: kind == .issue ? 1 : nil,
                title: title,
                state: .open,
                author: actorSummary,
                url: URL(string: "https://github.com/example/\(id)")!,
                createdAt: .now,
                updatedAt: .now,
                closedAt: nil,
                mergedAt: nil
            ),
            evidence: []
        )
    }

    private func evidence(id: String, observedAt: TimeInterval) -> EvidenceReference {
        EvidenceReference(
            id: EvidenceID(rawValue: id)!,
            source: .restTimeline,
            locator: .endpoint("/timeline"),
            authority: .localWorkflow(
                accountID: AccountID(rawValue: "account")!,
                organizationID: OrganizationID(rawValue: "organization")!
            ),
            confidence: .confirmed,
            confirmation: .confirmed,
            observedAt: Date(timeIntervalSinceReferenceDate: observedAt)
        )
    }

    private func reason(evidence: [EvidenceReference]) -> AttentionReason {
        AttentionReason(
            id: "reason",
            category: .conversation,
            ruleID: "rule",
            ruleVersion: 1,
            strength: 1,
            title: "Reason",
            explanation: "Explanation",
            evidence: evidence,
            evaluatedAt: .now
        )
    }

    private func relation(evidence: [EvidenceReference]) -> WorkRelation {
        relation(kind: .mentioned, evidence: evidence)
    }

    private func relation(
        kind: WorkRelationKind,
        evidence: [EvidenceReference] = []
    ) -> WorkRelation {
        WorkRelation(
            kind: kind,
            subjectNodeID: GitHubNodeID(rawValue: "node")!,
            objectNodeID: nil,
            confidence: .confirmed,
            evidence: evidence,
            observedAt: .now
        )
    }
}
