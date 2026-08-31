import Foundation
import XCTest
@testable import Triage

final class WorkspaceNotificationDeliveryAdapterTests: XCTestCase {
    func testFreshObservedScopedCandidateSchedulesGenericContent() async throws {
        let center = RecordingWorkspaceNotificationScheduler()
        let scheduler = NotificationScheduler(
            preferences: .init(isEnabled: true, privacy: .generic),
            scheduling: center,
            deliveryLedger: InMemoryNotificationDeliveryLedger()
        )
        let fixture = NotificationDeliveryFixture()
        let result = try await WorkspaceNotificationDeliveryAdapter(scheduler: scheduler).deliver(
            candidate: fixture.candidate,
            presentation: .init(title: "Private repository issue", body: "Private action text"),
            from: fixture.snapshot(origin: .observed),
            at: fixture.date
        )

        XCTAssertEqual(result, .delivered(.scheduled(replacing: 0)))
        let request = await center.requests().single
        XCTAssertEqual(request?.payload.route, fixture.route)
        XCTAssertEqual(request?.content.title, "New Triage item")
        XCTAssertEqual(request?.content.body, "Open Triage to view it.")
    }

    func testCachedPartialAndCrossScopeSnapshotsNeverSchedule() async throws {
        let center = RecordingWorkspaceNotificationScheduler()
        let scheduler = NotificationScheduler(
            preferences: .init(isEnabled: true),
            scheduling: center,
            deliveryLedger: InMemoryNotificationDeliveryLedger()
        )
        let adapter = WorkspaceNotificationDeliveryAdapter(scheduler: scheduler)
        let fixture = NotificationDeliveryFixture()

        let cached = try await adapter.deliver(
            candidate: fixture.candidate,
            from: fixture.snapshot(origin: .cached),
            at: fixture.date
        )
        XCTAssertEqual(cached, .suppressedCachedSnapshot)

        let partial = try await adapter.deliver(
            candidate: fixture.candidate,
            from: fixture.snapshot(origin: .observed, isComplete: false),
            at: fixture.date
        )
        XCTAssertEqual(partial, .suppressedStaleOrPartial(.partial))

        let stale = try await adapter.deliver(
            candidate: fixture.candidate,
            from: fixture.snapshot(origin: .observed, durableFreshness: .stale),
            at: fixture.date
        )
        XCTAssertEqual(stale, .suppressedStaleOrPartial(.stale))

        let mismatchedRoute = NotificationCandidate(
            route: NotificationRoute(
                accountID: AccountID(rawValue: "another-account")!,
                organizationID: fixture.scope.organizationID,
                workItemID: fixture.workItem.id
            ),
            reason: .directAssignment,
            evidenceVersion: "revision-1"
        )
        let mismatched = try await adapter.deliver(
            candidate: mismatchedRoute,
            from: fixture.snapshot(origin: .observed),
            at: fixture.date
        )
        XCTAssertEqual(mismatched, .suppressedScopeMismatch)
        let requests = await center.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testResponseAdapterForwardsOnlyLocalActionToRouteHandler() async {
        let fixture = NotificationDeliveryFixture()
        let handler = NotificationRouteHandlerSpy()
        let adapter = NotificationResponseApplicationAdapter(routeHandler: handler)
        let action = NotificationLocalAction.archiveInTriage(fixture.route)

        await adapter.handle(action)

        XCTAssertEqual(handler.actions, [action])
    }
}

private struct NotificationDeliveryFixture {
    let date = Date(timeIntervalSinceReferenceDate: 12_000)
    let scope = SynchronizationScope(
        accountID: AccountID(rawValue: "notification-delivery-account")!,
        organizationID: OrganizationID(rawValue: "notification-delivery-organization")!,
        credentialRevision: CredentialRevision(rawValue: "notification-delivery-credential")!,
        capabilityRevision: CapabilityRevision(rawValue: "notification-delivery-capability")!
    )
    let route = NotificationRoute(
        accountID: AccountID(rawValue: "notification-delivery-account")!,
        organizationID: OrganizationID(rawValue: "notification-delivery-organization")!,
        workItemID: WorkItemID(rawValue: "notification-delivery-work-item")!
    )

    var workItem: WorkItem {
        WorkItem(
            id: route.workItemID,
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            primaryNodeID: GitHubNodeID(rawValue: "NOTIFICATION_DELIVERY_NODE")!,
            title: "Private issue title",
            state: .active,
            sourceKind: .issue,
            sourceURL: URL(string: "https://github.com/acme/private/issues/1"),
            repository: nil,
            members: [],
            contextLinks: [],
            relations: [],
            attentionReasons: [],
            actionItems: [],
            workflow: WorkflowState(updatedAt: date),
            freshness: FreshnessState(status: .fresh, lastSuccessfulSyncAt: date),
            lastRelevantActivityAt: date,
            score: AttentionScore(value: 1_000, breakdown: [:])
        )
    }

    var candidate: NotificationCandidate {
        NotificationCandidate(
            route: route,
            reason: .directAssignment,
            evidenceVersion: "revision-1"
        )
    }

    func snapshot(
        origin: WorkspacePresentationSnapshot.Origin,
        isComplete: Bool = true,
        durableFreshness: FreshnessStatus = .fresh
    ) throws -> WorkspacePresentationSnapshot {
        let requirements = isComplete
            ? []
            : [CoverageRequirement(
                feature: .issues,
                repositoryID: nil,
                streamID: SyncStreamID(rawValue: "notification-delivery-issues")!
            )]
        return try WorkspacePresentationSnapshot(
            scope: scope,
            workItems: [workItem],
            durableState: AccountOrganizationDurableState(
                cachedState: nil,
                freshness: FreshnessState(status: durableFreshness, lastSuccessfulSyncAt: date)
            ),
            coverageRequirements: requirements,
            coverageRecords: [],
            menuCounts: nil,
            derivedEvaluatedAt: date,
            origin: origin
        )
    }
}

@MainActor
private final class NotificationRouteHandlerSpy: NotificationLocalRouteHandling {
    private(set) var actions: [NotificationLocalAction] = []

    func handleNotificationLocalAction(_ action: NotificationLocalAction) async {
        actions.append(action)
    }
}

private actor RecordingWorkspaceNotificationScheduler: NotificationScheduling {
    private var scheduled: [NotificationRequest] = []

    func pendingNotifications() -> [PendingNotification] {
        scheduled.map { .init(identifier: $0.identifier, dedupeKey: $0.payload.dedupeKey) }
    }

    func schedule(_ request: NotificationRequest) {
        scheduled.append(request)
    }

    func removePendingNotifications(identifiedBy identifiers: [String]) {
        scheduled.removeAll { identifiers.contains($0.identifier) }
    }

    func requests() -> [NotificationRequest] {
        scheduled
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
