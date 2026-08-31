import XCTest
@testable import Triage

@MainActor
final class WorkspaceAccessibilityCoordinatorTests: XCTestCase {
    func testRefreshStatusAndCachedWorkFailureUseGenericMessages() {
        let recorder = AnnouncementRecorder()
        let coordinator = WorkspaceAccessibilityCoordinator(poster: recorder)

        coordinator.synchronizationStatusChanged(to: .refreshing)
        coordinator.synchronizationStatusChanged(to: .offline)
        coordinator.workspaceContentAvailabilityChanged(hasCachedWork: true)
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

    func testRefreshFailureWithNoCachedRowsDoesNotClaimContentIsAvailable() {
        let recorder = AnnouncementRecorder()
        let coordinator = WorkspaceAccessibilityCoordinator(poster: recorder)

        coordinator.workspaceContentAvailabilityChanged(hasCachedWork: false)
        coordinator.refreshFailed()

        XCTAssertEqual(
            recorder.announcements,
            ["Triage could not refresh local work. No local work is available yet."]
        )
    }

    func testActionItemInsertionAnnouncementContainsOnlyACount() {
        let recorder = AnnouncementRecorder()
        let coordinator = WorkspaceAccessibilityCoordinator(poster: recorder)

        coordinator.actionItemsInserted(count: 1)
        coordinator.actionItemsInserted(count: 2)
        coordinator.actionItemsInserted(count: 0)

        XCTAssertEqual(
            recorder.announcements,
            [
                "A new local action item is available in Triage.",
                "2 new local action items are available in Triage."
            ]
        )
    }

    func testWorkspaceRestorationAnnouncementsAreActionableAndPrivate() {
        let recorder = AnnouncementRecorder()
        let coordinator = WorkspaceAccessibilityCoordinator(poster: recorder)

        coordinator.workspaceRestorationUnavailable()
        coordinator.workspaceRestorationRetryStarted()
        coordinator.workspaceRestorationRetrySucceeded()
        coordinator.workspaceRestorationRetryFailed()

        XCTAssertEqual(
            recorder.announcements,
            [
                "Triage could not load local work. Try Again is available.",
                "Retrying local work.",
                "Local work is available again.",
                "Triage could not load local work. Try Again remains available."
            ]
        )
    }

    func testAccountRestorationRetryAnnouncementsAreActionableAndPrivate() {
        let recorder = AnnouncementRecorder()
        let coordinator = WorkspaceAccessibilityCoordinator(poster: recorder)

        coordinator.accountRestorationRetryStarted()
        coordinator.accountRestorationRetrySucceeded()
        coordinator.accountRestorationRetryFailed()

        XCTAssertEqual(
            recorder.announcements,
            [
                "Retrying encrypted local account data.",
                "Encrypted local account restoration finished.",
                "Triage could not restore encrypted local account data. Try Again remains available."
            ]
        )
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

    func testEveryNativeFocusDestinationIsIndependentlyConsumable() {
        let recorder = AnnouncementRecorder()
        let coordinator = WorkspaceAccessibilityCoordinator(poster: recorder)

        for target in [
            WorkspaceAccessibilityFocusTarget.search,
            .inspectorToggle,
            .inspectorFirstWorkflowControl
        ] {
            coordinator.requestFocus(target)
            coordinator.consumeFocusRequest(target)
            XCTAssertNil(coordinator.requestedFocus)
        }

        XCTAssertTrue(recorder.announcements.isEmpty)
    }
}

@MainActor
private final class AnnouncementRecorder: WorkspaceAccessibilityAnnouncementPosting {
    private(set) var announcements: [String] = []

    func post(announcement: String) {
        announcements.append(announcement)
    }
}
