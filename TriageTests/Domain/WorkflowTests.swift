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

    func testLocalActionItemEditChangesOnlyExplicitlyEditableFields() throws {
        let createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let action = ActionItem(
            id: ActionItemID(rawValue: "action-1")!,
            workItemID: WorkItemID(rawValue: "work-1")!,
            title: "Respond",
            detail: "Original",
            origin: .deterministicRule,
            priority: .normal,
            dueAt: createdAt,
            evidenceIDs: [EvidenceID(rawValue: "evidence-1")!],
            sourceFingerprint: "source-1",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let edit = try XCTUnwrap(LocalActionItemEdit(
            title: "  Revised response  ",
            detail: "  New local detail  ",
            priority: .high,
            dueAt: nil
        ))

        let updated = action.applying(edit, at: createdAt.addingTimeInterval(60))

        XCTAssertEqual(updated.title, "Revised response")
        XCTAssertEqual(updated.detail, "New local detail")
        XCTAssertEqual(updated.priority, .high)
        XCTAssertNil(updated.dueAt)
        XCTAssertEqual(updated.origin, action.origin)
        XCTAssertEqual(updated.evidenceIDs, action.evidenceIDs)
        XCTAssertEqual(updated.sourceFingerprint, action.sourceFingerprint)
        XCTAssertEqual(updated.state, action.state)
        XCTAssertEqual(updated.updatedAt, createdAt.addingTimeInterval(60))
    }

    func testLocalActionItemEditRejectsBlankOrOversizedContent() {
        XCTAssertNil(LocalActionItemEdit(title: " \n", detail: nil, priority: .normal, dueAt: nil))
        XCTAssertNil(LocalActionItemEdit(
            title: "Valid",
            detail: String(repeating: "x", count: 10_001),
            priority: .normal,
            dueAt: nil
        ))
    }
}
