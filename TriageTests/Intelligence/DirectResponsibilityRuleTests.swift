import XCTest
@testable import Triage

final class DirectResponsibilityRuleTests: XCTestCase {
    private let userNodeID = GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!
    private let teamNodeID = GitHubNodeID(rawValue: "MDQ6VGVhbTE=")!
    private let date = Date(timeIntervalSinceReferenceDate: 1_000)

    func testDirectReviewRequestOutranksAssignment() {
        let result = DirectResponsibilityRule().evaluate(
            relations: [
                relation(kind: .assigned, objectNodeID: userNodeID),
                relation(kind: .reviewRequestedDirectly, objectNodeID: userNodeID)
            ],
            context: context()
        )

        XCTAssertEqual(
            result.reasons.map(\.ruleID),
            [AttentionRuleID.directReviewRequest.rawValue, AttentionRuleID.assignedToCurrentUser.rawValue]
        )
        XCTAssertEqual(result.reasons.map(\.strength), [1_000, 850])
    }

    func testTeamReviewRequestRequiresVisibleMembershipEvidence() {
        let relation = relation(kind: .reviewRequestedFromTeam, objectNodeID: teamNodeID)

        XCTAssertTrue(
            DirectResponsibilityRule()
                .evaluate(relations: [relation], context: context(visibleTeams: []))
                .reasons
                .isEmpty
        )
        XCTAssertEqual(
            DirectResponsibilityRule()
                .evaluate(relations: [relation], context: context(visibleTeams: [teamNodeID]))
                .reasons
                .map(\.ruleID),
            [AttentionRuleID.teamReviewRequest.rawValue]
        )
    }

    private func context(visibleTeams: Set<GitHubNodeID> = []) -> AttentionRuleContext {
        AttentionRuleContext(
            currentUserNodeID: userNodeID,
            visibleTeamNodeIDs: visibleTeams,
            evaluatedAt: date
        )
    }

    private func relation(
        kind: WorkRelationKind,
        objectNodeID: GitHubNodeID
    ) -> WorkRelation {
        WorkRelation(
            kind: kind,
            subjectNodeID: GitHubNodeID(rawValue: "I_kwDOExample")!,
            objectNodeID: objectNodeID,
            confidence: .confirmed,
            evidence: [
                EvidenceReference(
                    id: EvidenceID(rawValue: "evidence-\(kind.rawValue)")!,
                    source: .graphQL,
                    observedAt: date
                )
            ],
            observedAt: date
        )
    }
}
