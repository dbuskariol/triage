import XCTest
@testable import Triage

final class WorkflowTransitionTests: XCTestCase {
    func testArchiveAndUnarchivePreserveIndependentWorkflowFields() {
        let now = Date(timeIntervalSince1970: 1_000)
        let state = WorkflowState(isPinned: true, priority: .high, updatedAt: now)
        let archived = WorkflowTransitionEngine.apply(.archive, to: state, at: now.addingTimeInterval(1)).next
        let active = WorkflowTransitionEngine.apply(.unarchive, to: archived, at: now.addingTimeInterval(2)).next

        XCTAssertEqual(archived.status, .archived)
        XCTAssertTrue(archived.isPinned)
        XCTAssertEqual(active.status, .active)
        XCTAssertEqual(active.priority, .high)
    }

    func testWaitingAndSnoozeRemainIndependent() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snooze = now.addingTimeInterval(3_600)
        let state = WorkflowTransitionEngine.apply(.snooze(until: snooze), to: WorkflowState(updatedAt: now), at: now).next
        let waiting = WorkflowTransitionEngine.apply(.markWaiting(followUpAt: now), to: state, at: now).next

        XCTAssertEqual(waiting.status, .waiting)
        XCTAssertEqual(waiting.snoozedUntil, snooze)
        XCTAssertEqual(waiting.followUpAt, now)
    }
}
