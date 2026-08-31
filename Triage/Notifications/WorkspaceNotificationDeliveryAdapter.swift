import Foundation

/// The only bridge allowed to hand an evaluated local event to macOS. It does
/// not inspect GitHub data, synthesize candidates, or use a fallback source:
/// callers must provide explicit evidence and the exact durable workspace
/// snapshot that authorized it.
enum WorkspaceNotificationDeliveryDisposition: Equatable, Sendable {
    case delivered(NotificationScheduleResult)
    case suppressedCachedSnapshot
    case suppressedWithoutDerivedProjection
    case suppressedStaleOrPartial(FreshnessStatus)
    case suppressedScopeMismatch
    case suppressedMissingWorkItem
}

actor WorkspaceNotificationDeliveryAdapter {
    private let scheduler: NotificationScheduler

    init(scheduler: NotificationScheduler) {
        self.scheduler = scheduler
    }

    func updatePreferences(_ preferences: NotificationPreferences) async {
        await scheduler.updatePreferences(preferences)
    }

    /// Delivers only from a committed observed projection whose authority is
    /// complete for the same credential/capability revisions as the route.
    /// Presentation text is passed to `NotificationContentFactory`, which
    /// redacts it unless the user explicitly opted into details.
    func deliver(
        candidate: NotificationCandidate,
        presentation: NotificationPresentation = .init(),
        from snapshot: WorkspacePresentationSnapshot,
        at date: Date = .now
    ) async throws -> WorkspaceNotificationDeliveryDisposition {
        guard snapshot.origin == .observed else {
            return .suppressedCachedSnapshot
        }
        guard snapshot.derivedEvaluatedAt != nil else {
            return .suppressedWithoutDerivedProjection
        }
        guard snapshot.durableState.freshness.status == .fresh else {
            return .suppressedStaleOrPartial(snapshot.durableState.freshness.status)
        }
        guard snapshot.coverageEvaluation.freshness.status == .fresh else {
            return .suppressedStaleOrPartial(snapshot.coverageEvaluation.freshness.status)
        }
        guard candidate.route.accountID == snapshot.scope.accountID,
              candidate.route.organizationID == snapshot.scope.organizationID
        else {
            return .suppressedScopeMismatch
        }
        guard snapshot.workItems.contains(where: { workItem in
            workItem.id == candidate.route.workItemID
                && workItem.accountID == snapshot.scope.accountID
                && workItem.organizationID == snapshot.scope.organizationID
        }) else {
            return .suppressedMissingWorkItem
        }
        return .delivered(
            try await scheduler.schedule(
                candidate: candidate,
                presentation: presentation,
                at: date
            )
        )
    }
}
