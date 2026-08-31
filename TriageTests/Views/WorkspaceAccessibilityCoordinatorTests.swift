import XCTest
@testable import Triage

@MainActor
final class WorkspaceAccessibilityCoordinatorTests: XCTestCase {
    func testRefreshStatusAndFailureUseGenericMessages() {
        let recorder = AnnouncementRecorder()
        let coordinator = WorkspaceAccessibilityCoordinator(poster: recorder)

        coordinator.synchronizationStatusChanged(to: .refreshing)
        coordinator.synchronizationStatusChanged(to: .offline)
        coordinator.refreshFailed(diagnostic: "Private issue body: do not announce this")

        XCTAssertEqual(
            recorder.announcements,
            [
                "Refreshing local Triage work.",
                "Triage is showing cached local work while offline.",
                "Triage could not refresh local work. Cached work remains available."
            ]
        )
        XCTAssertFalse(recorder.announcements.joined(separator: " ").contains("Private issue body"))
    }

    func testWorkflowCompletionAndActionCompletionRemainLocalOnly() {
        let recorder = AnnouncementRecorder()
        let coordinator = WorkspaceAccessibilityCoordinator(poster: recorder)

        coordinator.workflowCompleted(.setPriority(.high))
        coordinator.actionItemCompleted()

        XCTAssertEqual(
            recorder.announcements,
            [
                "Work item priority updated in Triage. GitHub was not changed.",
                "Local action item completed in Triage. GitHub was not changed."
            ]
        )
    }

    func testSidebarAndWorkSelectionDoNotExposeWorkContent() {
        let recorder = AnnouncementRecorder()
        let coordinator = WorkspaceAccessibilityCoordinator(poster: recorder)

        coordinator.sidebarSelectionChanged(to: .reviews)
        coordinator.workItemSelectionChanged()

        XCTAssertEqual(recorder.announcements, ["Showing Reviews work.", "Work item selected."])
    }

    func testFocusRequestsAreExplicitAndConsumedOnlyByTheirTarget() {
        let recorder = AnnouncementRecorder()
        let coordinator = WorkspaceAccessibilityCoordinator(poster: recorder)

        coordinator.requestFocus(.inspectorFirstWorkflowControl)
        coordinator.consumeFocusRequest(.search)

        XCTAssertEqual(coordinator.requestedFocus, .inspectorFirstWorkflowControl)

        coordinator.consumeFocusRequest(.inspectorFirstWorkflowControl)

        XCTAssertNil(coordinator.requestedFocus)
    }
}

@MainActor
private final class AnnouncementRecorder: WorkspaceAccessibilityAnnouncementPosting {
    private(set) var announcements: [String] = []

    func post(announcement: String) {
        announcements.append(announcement)
    }
}
