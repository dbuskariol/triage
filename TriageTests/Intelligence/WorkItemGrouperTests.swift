import XCTest
@testable import Triage

final class WorkItemGrouperTests: XCTestCase {
    func testOnlyStrongRelationshipsMergeWorkItems() {
        let issue = node("issue")
        let pullRequest = node("pull-request")
        let reference = node("reference")
        let result = WorkItemGrouper().group(
            nodeIDs: [issue, pullRequest, reference],
            relations: [
                relation(.closes, issue, pullRequest),
                relation(.crossReferences, issue, reference)
            ],
            decisions: []
        )

        XCTAssertEqual(result.memberGroups, [[issue, pullRequest], [reference]])
        XCTAssertEqual(result.contextualRelations.map(\.kind), [.crossReferences])
    }

    func testUserConfirmedDecisionMergesNodes() {
        let first = node("first")
        let second = node("second")
        let result = WorkItemGrouper().group(
            nodeIDs: [first, second],
            relations: [],
            decisions: [
                WorkItemGroupingDecision(
                    sourceNodeID: first,
                    destinationNodeID: second,
                    relation: .crossReferences,
                    strength: .userConfirmed,
                    evidence: [],
                    decidedAt: .now
                )
            ]
        )

        XCTAssertEqual(result.memberGroups, [[first, second]])
    }

    private func node(_ value: String) -> GitHubNodeID {
        GitHubNodeID(rawValue: value)!
    }

    private func relation(
        _ kind: WorkRelationKind,
        _ source: GitHubNodeID,
        _ target: GitHubNodeID
    ) -> WorkRelation {
        WorkRelation(
            kind: kind,
            subjectNodeID: source,
            objectNodeID: target,
            confidence: .confirmed,
            evidence: [],
            observedAt: .now
        )
    }
}
