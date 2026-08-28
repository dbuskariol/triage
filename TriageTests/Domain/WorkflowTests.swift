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
}
