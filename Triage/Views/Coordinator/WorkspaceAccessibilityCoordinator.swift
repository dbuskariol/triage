import AppKit
import Combine

/// The small, privacy-safe set of destinations a SwiftUI surface can focus
/// after a state transition. Views remain the source of truth for focus; they
/// consume a request only when their control is currently present.
enum WorkspaceAccessibilityFocusTarget: Equatable, Sendable {
    case search
    case inspectorToggle
    case inspectorFirstWorkflowControl
}

@MainActor
protocol WorkspaceAccessibilityAnnouncementPosting: AnyObject {
    func post(announcement: String)
}

/// Posts a native VoiceOver announcement without retaining any view, window,
/// account, or work-item content.
@MainActor
final class AppKitWorkspaceAccessibilityAnnouncementPoster: WorkspaceAccessibilityAnnouncementPosting {
    func post(announcement: String) {
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high
            ]
        )
    }
}

/// Coordinates announcements and optional focus handoffs at the UI boundary.
///
/// Messages are intentionally generic: they never include a GitHub title,
/// body, comment, repository, account, error detail, or any other cached
/// private content. It is a local accessibility aid, not telemetry.
@MainActor
final class WorkspaceAccessibilityCoordinator: ObservableObject {
    @Published private(set) var requestedFocus: WorkspaceAccessibilityFocusTarget?

    private let poster: any WorkspaceAccessibilityAnnouncementPosting
    private var hasCachedWork = false

    init(poster: any WorkspaceAccessibilityAnnouncementPosting = AppKitWorkspaceAccessibilityAnnouncementPoster()) {
        self.poster = poster
    }

    func synchronizationStatusChanged(to status: WorkspacePresentationState.SynchronizationStatus) {
        post(Self.synchronizationAnnouncement(for: status))
    }

    /// `diagnostic` is accepted only to make a future UI hook straightforward.
    /// It is deliberately ignored to keep private failure details out of the
    /// VoiceOver announcement queue.
    func refreshFailed(diagnostic _: String? = nil) {
        if hasCachedWork {
            post("Triage could not refresh local work. Cached work remains available.")
        } else {
            post("Triage could not refresh local work. No local work is available yet.")
        }
    }

    /// Records only whether the current workspace has local rows. It never
    /// retains or announces their titles, identifiers, or source content.
    func workspaceContentAvailabilityChanged(hasCachedWork: Bool) {
        self.hasCachedWork = hasCachedWork
    }

    func actionItemsInserted(count: Int) {
        guard count > 0 else { return }
        if count == 1 {
            post("A new local action item is available in Triage.")
        } else {
            post("\(count) new local action items are available in Triage.")
        }
    }

    func workspaceRestorationUnavailable() {
        post("Triage could not load local work. Try Again is available.")
    }

    func workspaceRestorationRetryStarted() {
        post("Retrying local work.")
    }

    func workspaceRestorationRetrySucceeded() {
        post("Local work is available again.")
    }

    func workspaceRestorationRetryFailed() {
        post("Triage could not load local work. Try Again remains available.")
    }

    func workflowCompleted(_ action: WorkflowAction) {
        post(Self.workflowAnnouncement(for: action))
    }

    func actionItemCompleted() {
        post("Local action item completed in Triage. GitHub was not changed.")
    }

    func sidebarSelectionChanged(to section: AppSection) {
        post("Showing \(section.title) work.")
    }

    func workItemSelectionChanged() {
        post("Work item selected.")
    }

    func requestFocus(_ target: WorkspaceAccessibilityFocusTarget) {
        requestedFocus = target
    }

    func consumeFocusRequest(_ target: WorkspaceAccessibilityFocusTarget) {
        guard requestedFocus == target else { return }
        requestedFocus = nil
    }

    private func post(_ announcement: String) {
        poster.post(announcement: announcement)
    }

    private static func synchronizationAnnouncement(
        for status: WorkspacePresentationState.SynchronizationStatus
    ) -> String {
        switch status {
        case .noAccount:
            "No GitHub account is connected."
        case .noOrganization:
            "Choose an organization to view local work."
        case .initialSynchronization:
            "Triage is ready to synchronize local work."
        case .upToDate:
            "Triage work is up to date."
        case .refreshing:
            "Refreshing local Triage work."
        case .partial:
            "Triage work is partially available."
        case .ssoRequired:
            "Triage needs SSO authorization before it can refresh work."
        case .approvalRequired:
            "Triage needs organization approval before it can refresh work."
        case .offline:
            "Triage is showing cached local work while offline."
        case .signInRequired:
            "Triage needs account sign-in before it can refresh work."
        case .unavailable:
            "Triage synchronization status is unavailable."
        }
    }

    private static func workflowAnnouncement(for action: WorkflowAction) -> String {
        switch action {
        case .archive:
            "Work item archived in Triage. GitHub was not changed."
        case .unarchive:
            "Work item restored in Triage. GitHub was not changed."
        case .setPinned(true):
            "Work item pinned in Triage. GitHub was not changed."
        case .setPinned(false):
            "Work item unpinned in Triage. GitHub was not changed."
        case .setPriority:
            "Work item priority updated in Triage. GitHub was not changed."
        case .snooze:
            "Work item snoozed in Triage. GitHub was not changed."
        case .clearSnooze:
            "Work item snooze ended in Triage. GitHub was not changed."
        case .markWaiting:
            "Work item marked Waiting in Triage. GitHub was not changed."
        case .clearWaiting:
            "Work item is no longer Waiting in Triage. GitHub was not changed."
        }
    }
}
