import XCTest
@testable import Triage

final class LocalWorkflowUndoPolicyTests: XCTestCase {
    private let date = Date(timeIntervalSinceReferenceDate: 2_000)

    func testArchiveFromWaitingRestoresWaitingAndFollowUp() {
        let previous = state(status: .waiting, followUpAt: date)

        XCTAssertEqual(
            actionDescription(LocalWorkflowUndoPolicy.inverse(for: .archive, previous: previous)),
            "waiting:2000"
        )
    }

    func testChosenFollowUpDateRoundTripsThroughWaitingUndo() {
        let chosenDate = date
        let initial = state()
        let action = WorkflowAction.markWaiting(followUpAt: chosenDate)
        let updated = WorkflowTransitionEngine.apply(action, to: initial, at: date).next

        XCTAssertEqual(updated.status, .waiting)
        XCTAssertEqual(updated.followUpAt, chosenDate)
        guard case .clearWaiting? = LocalWorkflowUndoPolicy.inverse(for: action, previous: initial) else {
            return XCTFail("Waiting with a chosen follow-up date must undo to active work.")
        }
    }

    func testReversibleActionsRestorePriorLocalValues() {
        let previous = state(isPinned: true, priority: .high, snoozedUntil: date)

        XCTAssertEqual(actionDescription(LocalWorkflowUndoPolicy.inverse(for: .setPinned(false), previous: previous)), "pinned:true")
        XCTAssertEqual(actionDescription(LocalWorkflowUndoPolicy.inverse(for: .setPriority(.low), previous: previous)), "priority:3")
        XCTAssertEqual(actionDescription(LocalWorkflowUndoPolicy.inverse(for: .clearSnooze, previous: previous)), "snooze:2000")
        XCTAssertEqual(actionDescription(LocalWorkflowUndoPolicy.inverse(for: .clearWaiting, previous: state(status: .waiting, followUpAt: date))), "waiting:2000")
    }

    func testNoOpOrIrreversibleTransitionsDoNotCreateUndoEntries() {
        XCTAssertNil(LocalWorkflowUndoPolicy.inverse(for: .archive, previous: state(status: .archived)))
        XCTAssertNil(LocalWorkflowUndoPolicy.inverse(for: .setPinned(false), previous: state(isPinned: false)))
        XCTAssertNil(LocalWorkflowUndoPolicy.inverse(for: .setPriority(.normal), previous: state(priority: .normal)))
        XCTAssertNil(LocalWorkflowUndoPolicy.inverse(for: .markWaiting(followUpAt: nil), previous: state(status: .archived)))
    }

    func testUndoActionNamesDescribeOnlyLocalTriageHistory() {
        let names = [
            LocalWorkflowUndoPolicy.actionName(for: .archive),
            LocalWorkflowUndoPolicy.actionName(for: .unarchive),
            LocalWorkflowUndoPolicy.actionName(for: .setPinned(true)),
            LocalWorkflowUndoPolicy.actionName(for: .setPriority(.high)),
            LocalWorkflowUndoPolicy.actionName(for: .snooze(until: date)),
            LocalWorkflowUndoPolicy.actionName(for: .clearWaiting)
        ]

        XCTAssertTrue(names.allSatisfy { $0.contains("Triage") })
        XCTAssertTrue(names.allSatisfy { !$0.localizedCaseInsensitiveContains("github") })
    }

    func testPersistentStateComparisonIgnoresSaveTimestampButProtectsAllWorkflowFields() {
        let initial = state(isPinned: true, priority: .high, snoozedUntil: date, followUpAt: date, localNote: "local")
        let same = state(isPinned: true, priority: .high, snoozedUntil: date, followUpAt: date, localNote: "local", updatedAt: date.addingTimeInterval(1))
        let changed = state(isPinned: true, priority: .high, snoozedUntil: date, followUpAt: date, localNote: "different")

        XCTAssertTrue(LocalWorkflowUndoPolicy.hasSamePersistentState(initial, same))
        XCTAssertFalse(LocalWorkflowUndoPolicy.hasSamePersistentState(initial, changed))
    }

    private func state(
        status: LocalWorkStatus = .active,
        isPinned: Bool = false,
        priority: WorkPriority = .normal,
        snoozedUntil: Date? = nil,
        followUpAt: Date? = nil,
        localNote: String? = nil,
        updatedAt: Date? = nil
    ) -> WorkflowState {
        WorkflowState(
            status: status,
            isPinned: isPinned,
            priority: priority,
            snoozedUntil: snoozedUntil,
            followUpAt: followUpAt,
            localNote: localNote,
            updatedAt: updatedAt ?? date
        )
    }

    private func actionDescription(_ action: WorkflowAction?) -> String? {
        switch action {
        case .none: nil
        case .archive: "archive"
        case .unarchive: "unarchive"
        case let .setPinned(value): "pinned:\(value)"
        case let .setPriority(value): "priority:\(value.rawValue)"
        case let .snooze(until): "snooze:\(Int(until.timeIntervalSinceReferenceDate))"
        case .clearSnooze: "clear-snooze"
        case let .markWaiting(followUpAt): "waiting:\(Int(followUpAt?.timeIntervalSinceReferenceDate ?? 0))"
        case .clearWaiting: "clear-waiting"
        }
    }
}
