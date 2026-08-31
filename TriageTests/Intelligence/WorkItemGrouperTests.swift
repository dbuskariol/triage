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

    func testAuthoritativeDuplicateAndDependencyRelationsRemainContextual() {
        let issue = node("issue")
        let duplicate = node("duplicate")
        let blocker = node("blocker")
        let blocked = node("blocked")
        let result = WorkItemGrouper().group(
            nodeIDs: [issue, duplicate, blocker, blocked],
            relations: [
                relation(.duplicateOf, issue, duplicate),
                relation(.blockedBy, issue, blocker),
                relation(.blocks, issue, blocked)
            ],
            decisions: []
        )

        XCTAssertEqual(result.memberGroups, [[blocked], [blocker], [duplicate], [issue]])
        XCTAssertEqual(
            Set(result.contextualRelations.map(\.kind)),
            Set([.duplicateOf, .blockedBy, .blocks])
        )
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

    func testContextualDecisionNeverMergesAndUnknownNodesAreIgnored() {
        let first = node("first")
        let second = node("second")
        let absent = node("absent")
        let result = WorkItemGrouper().group(
            nodeIDs: [second, first, first],
            relations: [relation(.closes, first, absent)],
            decisions: [
                WorkItemGroupingDecision(
                    sourceNodeID: first,
                    destinationNodeID: second,
                    relation: .crossReferences,
                    strength: .contextual,
                    evidence: [],
                    decidedAt: .now
                )
            ]
        )

        XCTAssertEqual(result.memberGroups, [[first], [second]])
        XCTAssertTrue(result.contextualRelations.isEmpty)
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
