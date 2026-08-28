import XCTest

@testable import Triage

final class NotificationEligibilityTests: XCTestCase {
  private let now = Date(timeIntervalSinceReferenceDate: 10_000)
  private let route = NotificationRoute(
    accountID: AccountID(rawValue: "account")!,
    organizationID: OrganizationID(rawValue: "organization")!,
    workItemID: WorkItemID(rawValue: "work-item")!
  )

  func testEligibleReasonsAreAcceptedWhenTheirConditionsAreMet() {
    let policy = NotificationEligibilityPolicy()
    let candidates = [
      candidate(reason: .directAssignment),
      candidate(reason: .directReviewRequest),
      candidate(reason: .teamReviewRequest),
      candidate(reason: .highPriorityInboxItem, isHighPriority: true),
      candidate(reason: .waitingResponse, isWaiting: true),
      candidate(reason: .snoozeDue, dueAt: now),
      candidate(reason: .explicitDeadline, dueAt: now.addingTimeInterval(60)),
    ]

    for candidate in candidates {
      XCTAssertEqual(policy.decision(for: candidate, at: now), .eligible)
    }
  }

  func testHighPriorityRequiresANewInboxItemWithHighPriority() {
    let policy = NotificationEligibilityPolicy()

    XCTAssertEqual(
      policy.decision(
        for: candidate(reason: .highPriorityInboxItem, isInboxItem: false, isHighPriority: true),
        at: now
      ),
      .notInboxItem
    )
    XCTAssertEqual(
      policy.decision(for: candidate(reason: .highPriorityInboxItem), at: now),
      .notHighPriority
    )
    XCTAssertEqual(
      policy.decision(
        for: candidate(
          reason: .highPriorityInboxItem,
          isNewEvidence: false,
          isHighPriority: true
        ),
        at: now
      ),
      .unchangedEvidence
    )
  }

  func testSnoozeAndDeadlineHaveStrictTimeRequirements() {
    let policy = NotificationEligibilityPolicy()

    XCTAssertEqual(
      policy.decision(
        for: candidate(reason: .snoozeDue, dueAt: now.addingTimeInterval(1)), at: now),
      .notDue
    )
    XCTAssertEqual(
      policy.decision(
        for: candidate(
          reason: .explicitDeadline,
          dueAt: now.addingTimeInterval(4 * 86_400)
        ),
        at: now
      ),
      .deadlineNotApproaching
    )
  }

  func testWaitingResponseRequiresAnItemInWaitingState() {
    XCTAssertEqual(
      NotificationEligibilityPolicy().decision(
        for: candidate(reason: .waitingResponse),
        at: now
      ),
      .notWaitingItem
    )
  }

  private func candidate(
    reason: NotificationReason,
    isNewEvidence: Bool = true,
    isInboxItem: Bool = true,
    isHighPriority: Bool = false,
    isWaiting: Bool = false,
    dueAt: Date? = nil
  ) -> NotificationCandidate {
    NotificationCandidate(
      route: route,
      reason: reason,
      evidenceVersion: "revision-1",
      isNewEvidence: isNewEvidence,
      isInboxItem: isInboxItem,
      isHighPriority: isHighPriority,
      isWaiting: isWaiting,
      dueAt: dueAt
    )
  }
}
