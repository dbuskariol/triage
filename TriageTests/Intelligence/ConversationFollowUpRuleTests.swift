import XCTest
@testable import Triage

final class ConversationFollowUpRuleTests: XCTestCase {
    private let userNodeID = GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!
    private let teamNodeID = GitHubNodeID(rawValue: "MDQ6VGVhbTE=")!
    private let subjectNodeID = GitHubNodeID(rawValue: "I_kwDOExample")!
    private let progressDate = Date(timeIntervalSinceReferenceDate: 1_000)
    private let laterDate = Date(timeIntervalSinceReferenceDate: 1_001)

    func testDirectMentionsOnlyTriggerAfterQualifyingProgress() {
        let rule = ConversationFollowUpRule()
        let relation = mention(
            kind: .mentioned,
            objectNodeID: userNodeID,
            observedAt: laterDate
        )
        let result = rule.evaluate(
            relations: [relation],
            timeline: [],
            context: context()
        )

        XCTAssertEqual(
            result.reasons.map(\.ruleID),
            [ConversationAttentionRuleID.directMentionAfterProgress.rawValue]
        )
        XCTAssertTrue(
            rule.evaluate(
                relations: [mention(kind: .mentioned, objectNodeID: userNodeID, observedAt: progressDate)],
                timeline: [],
                context: context()
            ).reasons.isEmpty
        )
    }

    func testTeamMentionsRequireKnownVisibleMembership() {
        let relation = mention(
            kind: .teamMentioned,
            objectNodeID: teamNodeID,
            observedAt: laterDate
        )
        let rule = ConversationFollowUpRule()

        XCTAssertTrue(
            rule.evaluate(relations: [relation], timeline: [], context: context()).reasons.isEmpty
        )
        XCTAssertEqual(
            rule.evaluate(
                relations: [relation],
                timeline: [],
                context: context(teams: [teamNodeID])
            ).reasons.first?.ruleID,
            ConversationAttentionRuleID.teamMentionAfterProgress.rawValue
        )
    }

    func testNewConversationActivityRequiresParticipationAndLaterActivity() {
        let result = ConversationFollowUpRule().evaluate(
            relations: [mention(kind: .commented, objectNodeID: userNodeID, observedAt: progressDate)],
            timeline: [
                TimelineEventSummary(
                    id: GitHubEventID(rawValue: "event-1")!,
                    subjectNodeID: subjectNodeID,
                    kind: .commented,
                    actor: ActorSummary(
                        id: ActorID(rawValue: "actor-2")!,
                        nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjI=")!,
                        login: "other",
                        displayName: nil,
                        avatarURL: nil
                    ),
                    occurredAt: laterDate,
                    url: nil,
                    body: "A new reply"
                )
            ],
            context: context()
        )

        XCTAssertEqual(
            result.reasons.last?.ruleID,
            ConversationAttentionRuleID.newActivityOnParticipatedWork.rawValue
        )
    }

    private func context(teams: Set<GitHubNodeID> = []) -> ConversationRuleContext {
        ConversationRuleContext(
            currentUserNodeID: userNodeID,
            visibleTeamNodeIDs: teams,
            latestQualifyingProgressAt: progressDate,
            evaluatedAt: laterDate
        )
    }

    private func mention(
        kind: WorkRelationKind,
        objectNodeID: GitHubNodeID,
        observedAt: Date
    ) -> WorkRelation {
        WorkRelation(
            kind: kind,
            subjectNodeID: subjectNodeID,
            objectNodeID: objectNodeID,
            confidence: .confirmed,
            evidence: [
                EvidenceReference(
                    id: EvidenceID(rawValue: "\(kind.rawValue)-\(observedAt.timeIntervalSinceReferenceDate)")!,
                    source: .restTimeline,
                    observedAt: observedAt
                )
            ],
            observedAt: observedAt
        )
    }
}
