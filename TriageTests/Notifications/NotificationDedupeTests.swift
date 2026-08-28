import XCTest

@testable import Triage

final class NotificationDedupeTests: XCTestCase {
  func testUnchangedEvidenceIsDeduplicatedAndNewEvidenceCoalesces() async throws {
    let center = RecordingNotificationScheduler()
    let scheduler = NotificationScheduler(
      preferences: .init(isEnabled: true),
      scheduling: center,
      deliveryLedger: InMemoryNotificationDeliveryLedger()
    )
    let route = NotificationRoute(
      accountID: AccountID(rawValue: "account")!,
      organizationID: OrganizationID(rawValue: "organization")!,
      workItemID: WorkItemID(rawValue: "work-item")!
    )
    let first = candidate(route: route, version: "revision-1")

    let initialResult = try await scheduler.schedule(candidate: first)
    XCTAssertEqual(initialResult, .scheduled(replacing: 0))

    let duplicateResult = try await scheduler.schedule(candidate: first)
    XCTAssertEqual(duplicateResult, .suppressedDuplicate)

    let replacementResult = try await scheduler.schedule(
      candidate: candidate(route: route, version: "revision-2")
    )
    XCTAssertEqual(
      replacementResult,
      .scheduled(replacing: 1)
    )

    let requests = await center.requests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.payload.evidenceVersion, "revision-2")
  }

  func testDisabledNotificationsDoNotSchedule() async throws {
    let center = RecordingNotificationScheduler()
    let scheduler = NotificationScheduler(
      scheduling: center,
      deliveryLedger: InMemoryNotificationDeliveryLedger()
    )

    let result = try await scheduler.schedule(
      candidate: candidate(route: makeRoute(), version: "revision-1")
    )
    XCTAssertEqual(result, .suppressedDisabled)

    let requests = await center.requests()
    XCTAssertTrue(requests.isEmpty)
  }

  private func makeRoute() -> NotificationRoute {
    NotificationRoute(
      accountID: AccountID(rawValue: "account")!,
      organizationID: OrganizationID(rawValue: "organization")!,
      workItemID: WorkItemID(rawValue: "work-item")!
    )
  }

  private func candidate(route: NotificationRoute, version: String) -> NotificationCandidate {
    NotificationCandidate(
      route: route,
      reason: .directAssignment,
      evidenceVersion: version
    )
  }
}

private actor RecordingNotificationScheduler: NotificationScheduling {
  private var scheduled: [NotificationRequest] = []

  func pendingNotifications() -> [PendingNotification] {
    scheduled.map {
      PendingNotification(identifier: $0.identifier, dedupeKey: $0.payload.dedupeKey)
    }
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
