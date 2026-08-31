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

  func testTamperedPayloadCannotCreateALocalAction() throws {
    let payload = NotificationPayload(
      route: route,
      reason: .directReviewRequest,
      evidenceVersion: "revision-1"
    )
    let encoded = try NotificationPayloadCodec.encode(payload)
    let tampered = encoded.replacingOccurrences(of: "revision-1", with: "revision-2")

    XCTAssertNil(NotificationPayloadCodec.decode(
      userInfo: [NotificationPayloadCodec.userInfoKey: tampered]
    ))
  }

  func testStaleHighPriorityActionCannotMutateAnItemThatLeftTheInbox() {
    let eligibleItem = highPriorityItem(isPinned: true)
    let authorization = route.authorizingAction(
      reason: .highPriorityInboxItem,
      evidenceVersion: NotificationEvidenceVersion.version(
        for: eligibleItem,
        reason: .highPriorityInboxItem
      )
    )
    XCTAssertTrue(NotificationActionAuthorizationValidator.matches(
      route: authorization,
      workItem: eligibleItem
    ))

    let noLongerEligible = highPriorityItem(isPinned: false)
    XCTAssertFalse(NotificationActionAuthorizationValidator.matches(
      route: authorization,
      workItem: noLongerEligible
    ))
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

  private func highPriorityItem(isPinned: Bool) -> WorkItem {
    let date = Date(timeIntervalSinceReferenceDate: 10_000)
    return WorkItem(
      id: route.workItemID,
      accountID: route.accountID,
      organizationID: route.organizationID,
      primaryNodeID: GitHubNodeID(rawValue: "NOTIFICATION_ROUTE_NODE")!,
      title: "Private item",
      state: .active,
      sourceKind: .issue,
      sourceURL: nil,
      repository: nil,
      members: [],
      contextLinks: [],
      relations: [],
      attentionReasons: [],
      actionItems: [],
      workflow: .init(isPinned: isPinned, priority: .high, updatedAt: date),
      freshness: .init(status: .fresh, lastSuccessfulSyncAt: date),
      lastRelevantActivityAt: date,
      score: .init(value: 1, breakdown: [:])
    )
  }
}
