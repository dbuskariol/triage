import XCTest

@testable import Triage

final class NotificationRouteAndActionTests: XCTestCase {
  private let route = NotificationRoute(
    accountID: AccountID(rawValue: "account")!,
    organizationID: OrganizationID(rawValue: "organization")!,
    workItemID: WorkItemID(rawValue: "work-item")!
  )

  func testRoutePayloadRoundTripsAndDedupeVersionChangesIdentifier() throws {
    let first = NotificationPayload(
      route: route,
      reason: .directReviewRequest,
      evidenceVersion: "revision-1"
    )
    let second = NotificationPayload(
      route: route,
      reason: .directReviewRequest,
      evidenceVersion: "revision-2"
    )
    let encoded = try NotificationPayloadCodec.encode(first)

    XCTAssertEqual(
      NotificationPayloadCodec.decode(
        userInfo: [NotificationPayloadCodec.userInfoKey: encoded]
      ),
      first
    )
    XCTAssertNotEqual(first.dedupeKey.requestIdentifier, second.dedupeKey.requestIdentifier)
  }

  func testLocalActionsRouteOnlyToLocalWorkflowCommands() {
    let now = Date(timeIntervalSinceReferenceDate: 10_000)

    XCTAssertEqual(
      NotificationLocalActionPolicy.action(
        identifier: NotificationActionIdentifier.openTriage,
        route: route,
        now: now
      ),
      .openTriage(route)
    )
    XCTAssertEqual(
      NotificationLocalActionPolicy.action(
        identifier: NotificationActionIdentifier.snoozeOneHour,
        route: route,
        now: now
      ),
      .snoozeOneHour(route, until: now.addingTimeInterval(3_600))
    )
    XCTAssertEqual(
      NotificationLocalActionPolicy.action(
        identifier: NotificationActionIdentifier.archiveInTriage,
        route: route,
        now: now
      ),
      .archiveInTriage(route)
    )
    XCTAssertNil(
      NotificationLocalActionPolicy.action(identifier: "unknown", route: route, now: now)
    )
  }
}
