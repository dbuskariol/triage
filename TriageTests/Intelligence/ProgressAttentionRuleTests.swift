import XCTest

@testable import Triage

final class ProgressAttentionRuleTests: XCTestCase {
  private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

  func testOwnedWorkBecomesStaleAtBusinessDayBoundaryWithEvidence() {
    let policy = BusinessDayPolicy(staleAfterBusinessDays: 1)
    let progress = QualifyingProgressEvidence(
      occurredAt: date(year: 2026, month: 8, day: 28, hour: 14),
      evidence: evidence(id: "progress")
    )
    let due = date(year: 2026, month: 8, day: 31, hour: 14)

    XCTAssertTrue(
      ProgressAttentionRule().evaluate(
        input: input(latestProgress: progress),
        context: context(policy: policy, evaluatedAt: due.addingTimeInterval(-1))
      ).reasons.isEmpty
    )
    let result = ProgressAttentionRule().evaluate(
      input: input(latestProgress: progress),
      context: context(policy: policy, evaluatedAt: due)
    )
    XCTAssertEqual(
      result.reasons.map(\.ruleID),
      [ProgressAttentionRuleID.ownedWorkStale.rawValue]
    )
    XCTAssertEqual(result.reasons.first?.evidence.map(\.id.rawValue), ["progress"])
    XCTAssertTrue(
      ProgressAttentionRule().evaluate(
        input: input(isOwned: false, latestProgress: progress),
        context: context(policy: policy, evaluatedAt: due)
      ).reasons.isEmpty
    )
    let issueAtStart = now
    let linkedPullRequest = LinkedPullRequestProgressEvidence(
      startedAt: issueAtStart,
      evidence: evidence(id: "unproven-pull-request")
    )
    XCTAssertTrue(
      ProgressAttentionRule().evaluate(
        input: input(
          sourceIssueLastUpdatedAt: issueAtStart,
          sourceIssueEvidence: nil,
          linkedPullRequests: [linkedPullRequest]
        ),
        context: context()
      ).reasons.isEmpty,
      "A linked pull request cannot prove the current issue has not changed without current issue evidence."
    )
  }

  func testLinkedPullRequestRequiresNoLaterIssueUpdate() {
    let startedAt = now
    let pullRequest = LinkedPullRequestProgressEvidence(
      startedAt: startedAt,
      evidence: evidence(id: "pull-request")
    )
    let result = ProgressAttentionRule().evaluate(
      input: input(
        sourceIssueLastUpdatedAt: startedAt,
        sourceIssueEvidence: evidence(id: "issue"),
        linkedPullRequests: [pullRequest]
      ),
      context: context()
    )

    XCTAssertEqual(
      result.reasons.map(\.ruleID),
      [ProgressAttentionRuleID.linkedPullRequestNeedsIssueUpdate.rawValue]
    )
    XCTAssertEqual(result.reasons.first?.evidence.map(\.id.rawValue), ["issue", "pull-request"])
    XCTAssertTrue(
      ProgressAttentionRule().evaluate(
        input: input(
          sourceIssueLastUpdatedAt: startedAt.addingTimeInterval(1),
          sourceIssueEvidence: evidence(id: "issue"),
          linkedPullRequests: [pullRequest]
        ),
        context: context()
      ).reasons.isEmpty
    )
  }

  func testDueActionsUseStableOrderingAndOpenActionTimeBoundaries() {
    let overdue = action(id: "overdue", dueAt: now)
    let soon = action(id: "soon", dueAt: now.addingTimeInterval(3 * 86_400))
    let completed = action(id: "completed", dueAt: now.addingTimeInterval(-1), isOpen: false)
    let result = ProgressAttentionRule().evaluate(
      input: input(dueActions: [soon, completed, overdue]),
      context: context()
    )

    XCTAssertEqual(
      result.reasons.map(\.ruleID),
      [
        ProgressAttentionRuleID.overdueDueActions.rawValue,
        ProgressAttentionRuleID.dueActionsApproaching.rawValue,
      ]
    )
    XCTAssertEqual(result.reasons.map(\.strength), [800, 600])
    XCTAssertEqual(result.reasons[0].id, "overdueDueActions-overdue")
    XCTAssertEqual(result.reasons[1].id, "dueActionsApproaching-soon")
    XCTAssertEqual(result.reasons[0].evidence.map(\.id.rawValue), ["overdue"])
    XCTAssertEqual(result.reasons[1].evidence.map(\.id.rawValue), ["soon"])
    XCTAssertTrue(
      ProgressAttentionRule().evaluate(
        input: input(dueActions: [
          action(id: "later", dueAt: now.addingTimeInterval(3 * 86_400 + 1))
        ]),
        context: context()
      ).reasons.isEmpty
    )
  }

  private func context(
    policy: BusinessDayPolicy = BusinessDayPolicy(),
    evaluatedAt: Date? = nil
  ) -> ProgressRuleContext {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return ProgressRuleContext(
      businessDayPolicy: policy,
      calendar: calendar,
      evaluatedAt: evaluatedAt ?? now
    )
  }

  private func input(
    isOwned: Bool = true,
    latestProgress: QualifyingProgressEvidence? = nil,
    sourceIssueLastUpdatedAt: Date? = nil,
    sourceIssueEvidence: EvidenceReference? = nil,
    linkedPullRequests: [LinkedPullRequestProgressEvidence] = [],
    dueActions: [DueActionEvidence] = []
  ) -> ProgressRuleInput {
    ProgressRuleInput(
      isOwnedByCurrentUser: isOwned,
      latestQualifyingProgress: latestProgress,
      sourceIssueLastUpdatedAt: sourceIssueLastUpdatedAt,
      sourceIssueEvidence: sourceIssueEvidence,
      linkedPullRequests: linkedPullRequests,
      dueActions: dueActions
    )
  }

  private func action(
    id: String,
    dueAt: Date,
    isOpen: Bool = true
  ) -> DueActionEvidence {
    DueActionEvidence(
      id: ActionItemID(rawValue: id)!,
      isOpen: isOpen,
      dueAt: dueAt,
      evidence: evidence(id: id)
    )
  }

  private func evidence(id: String) -> EvidenceReference {
    EvidenceReference(
      id: EvidenceID(rawValue: id)!,
      source: .localWorkflow,
      locator: .localWorkflow("test-progress-state"),
      authority: .localWorkflow(
        accountID: AccountID(rawValue: "account-1")!,
        organizationID: OrganizationID(rawValue: "organization-1")!
      ),
      confidence: .confirmed,
      confirmation: .confirmed,
      observedAt: now
    )
  }

  private func date(year: Int, month: Int, day: Int, hour: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(
      from: DateComponents(year: year, month: month, day: day, hour: hour)
    )!
  }
}
