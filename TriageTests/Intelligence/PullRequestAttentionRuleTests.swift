import XCTest

@testable import Triage

final class PullRequestAttentionRuleTests: XCTestCase {
  private let currentUser = GitHubNodeID(rawValue: "user-current")!
  private let reviewer = GitHubNodeID(rawValue: "user-reviewer")!
  private let evaluatedAt = Date(timeIntervalSinceReferenceDate: 10_000)

  func testChangesRequestedRequireNewerResponseOrCommitAndPreserveEvidenceOrder() {
    let first = review(id: "review-b", state: .changesRequested, submittedAt: evaluatedAt)
    let second = review(id: "review-a", state: .changesRequested, submittedAt: evaluatedAt)
    let result = PullRequestAttentionRule().evaluate(
      input: input(reviews: [first, second]),
      context: context()
    )

    XCTAssertEqual(
      result.reasons.map(\.ruleID),
      [
        PullRequestAttentionRuleID.changesRequested.rawValue,
        PullRequestAttentionRuleID.newReviewFeedback.rawValue,
      ]
    )
    XCTAssertEqual(result.reasons.first?.strength, 900)
    XCTAssertEqual(result.reasons.first?.evidence.map(\.id.rawValue), ["review-a", "review-b"])
    XCTAssertEqual(result.reasons.first?.id, "changesRequested-review-a-review-b")

    XCTAssertTrue(
      PullRequestAttentionRule().evaluate(
        input: input(
          latestResponseOrCommit: evaluatedAt.addingTimeInterval(1),
          reviews: [first]
        ),
        context: context()
      ).reasons.isEmpty
    )
    XCTAssertTrue(
      PullRequestAttentionRule().evaluate(
        input: input(
          reviews: [
            PullRequestReviewFeedback(
              id: GitHubNodeID(rawValue: "unknown-reviewer")!,
              authorNodeID: nil,
              state: .commented,
              submittedAt: evaluatedAt.addingTimeInterval(1),
              evidence: evidence(id: "unknown-reviewer")
            )
          ]
        ),
        context: context()
      ).reasons.isEmpty
    )
  }

  func testUnresolvedThreadsMustExplicitlyRequireCurrentUserResponse() {
    let actionable = thread(id: "thread-actionable", resolved: false, requiresResponse: true)
    let resolved = thread(id: "thread-resolved", resolved: true, requiresResponse: true)
    let informational = thread(id: "thread-information", resolved: false, requiresResponse: false)
    let result = PullRequestAttentionRule().evaluate(
      input: input(reviewThreads: [resolved, informational, actionable]),
      context: context()
    )

    XCTAssertEqual(
      result.reasons.map(\.ruleID),
      [PullRequestAttentionRuleID.unresolvedReviewThreads.rawValue]
    )
    XCTAssertEqual(result.reasons.first?.evidence.map(\.id.rawValue), ["thread-actionable"])
  }

  func testNewReviewFeedbackRequiresAuthoredPullRequestExternalReviewerAndNewTimestamp() {
    let newComment = review(id: "comment", state: .commented, submittedAt: evaluatedAt)
    XCTAssertEqual(
      PullRequestAttentionRule().evaluate(
        input: input(reviews: [newComment]),
        context: context()
      ).reasons.map(\.ruleID),
      [PullRequestAttentionRuleID.newReviewFeedback.rawValue]
    )

    XCTAssertTrue(
      PullRequestAttentionRule().evaluate(
        input: input(
          authoredByCurrentUser: false,
          reviews: [newComment]
        ),
        context: context()
      ).reasons.isEmpty
    )
    XCTAssertTrue(
      PullRequestAttentionRule().evaluate(
        input: input(
          latestResponseOrCommit: evaluatedAt,
          reviews: [newComment]
        ),
        context: context()
      ).reasons.isEmpty
    )
    XCTAssertTrue(
      PullRequestAttentionRule().evaluate(
        input: input(
          reviews: [
            PullRequestReviewFeedback(
              id: GitHubNodeID(rawValue: "self-review")!,
              authorNodeID: currentUser,
              state: .commented,
              submittedAt: evaluatedAt.addingTimeInterval(1),
              evidence: evidence(id: "self-review")
            )
          ]
        ),
        context: context()
      ).reasons.isEmpty
    )
  }

  private func context() -> PullRequestRuleContext {
    PullRequestRuleContext(currentUserNodeID: currentUser, evaluatedAt: evaluatedAt)
  }

  private func input(
    authoredByCurrentUser: Bool = true,
    latestResponseOrCommit: Date? = nil,
    reviews: [PullRequestReviewFeedback] = [],
    reviewThreads: [PullRequestReviewThread] = []
  ) -> PullRequestRuleInput {
    PullRequestRuleInput(
      isAuthoredByCurrentUser: authoredByCurrentUser,
      latestCurrentUserResponseOrCommitAt: latestResponseOrCommit,
      reviews: reviews,
      reviewThreads: reviewThreads
    )
  }

  private func review(
    id: String,
    state: ReviewState,
    submittedAt: Date?
  ) -> PullRequestReviewFeedback {
    PullRequestReviewFeedback(
      id: GitHubNodeID(rawValue: id)!,
      authorNodeID: reviewer,
      state: state,
      submittedAt: submittedAt,
      evidence: evidence(id: id)
    )
  }

  private func thread(
    id: String,
    resolved: Bool,
    requiresResponse: Bool
  ) -> PullRequestReviewThread {
    PullRequestReviewThread(
      id: GitHubNodeID(rawValue: id)!,
      isResolved: resolved,
      requiresCurrentUserResponse: requiresResponse,
      evidence: evidence(id: id)
    )
  }

  private func evidence(id: String) -> EvidenceReference {
    EvidenceReference(
      id: EvidenceID(rawValue: id)!,
      source: .restReview,
      locator: .legacyUnverified,
      authority: .legacyUnverified,
      confidence: .provisional,
      confirmation: .provisional,
      observedAt: evaluatedAt
    )
  }
}
