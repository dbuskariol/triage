import XCTest
@testable import Triage

final class WorkflowTests: XCTestCase {
    func testWorkflowStateTreatsTheExactSnoozeDeadlineAsDue() {
        let deadline = Date(timeIntervalSinceReferenceDate: 1_000)
        let state = WorkflowState(snoozedUntil: deadline, updatedAt: deadline)

        XCTAssertTrue(state.isSnoozed(at: deadline.addingTimeInterval(-1)))
        XCTAssertFalse(state.isSnoozed(at: deadline))
        XCTAssertFalse(state.isSnoozed(at: deadline.addingTimeInterval(1)))
    }

    func testPriorityHasStableNaturalOrder() {
        XCTAssertLessThan(WorkPriority.low, .normal)
        XCTAssertLessThan(WorkPriority.normal, .high)
    }

    func testCompletingActionPreservesProvenanceAndRecordsCompletion() {
        let createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let completedAt = createdAt.addingTimeInterval(60)
        let action = ActionItem(
            id: ActionItemID(rawValue: "action-1")!,
            workItemID: WorkItemID(rawValue: "work-1")!,
            title: "Respond to review",
            detail: "Address the requested API change.",
            origin: .deterministicRule,
            priority: .high,
            dueAt: createdAt.addingTimeInterval(3_600),
            evidenceIDs: [EvidenceID(rawValue: "evidence-1")!],
            sourceFingerprint: "source-1",
            createdAt: createdAt,
            updatedAt: createdAt
        )

        let completed = action.completing(at: completedAt)

        XCTAssertEqual(completed.id, action.id)
        XCTAssertEqual(completed.workItemID, action.workItemID)
        XCTAssertEqual(completed.origin, .deterministicRule)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.completedAt, completedAt)
        XCTAssertEqual(completed.updatedAt, completedAt)
        XCTAssertNil(completed.dismissedAt)
    }
}
