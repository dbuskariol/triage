import Foundation

enum PullRequestAttentionRuleID: String, Codable, Sendable {
  case changesRequested
  case unresolvedReviewThreads
  case newReviewFeedback
  case requiredCheckFailed
  case mergeableWaitingOnUserAction
}

struct PullRequestRuleContext: Sendable {
  let currentUserNodeID: GitHubNodeID
  let evaluatedAt: Date
}

struct PullRequestReviewFeedback: Sendable {
  let id: GitHubNodeID
  let authorNodeID: GitHubNodeID?
  let state: ReviewState
  let submittedAt: Date?
  let evidence: EvidenceReference
}

struct PullRequestReviewThread: Sendable {
  let id: GitHubNodeID
  let isResolved: Bool
  let requiresCurrentUserResponse: Bool
  let evidence: EvidenceReference
}

struct PullRequestStatusCheck: Sendable {
  let context: String
  let state: GitHubPullRequestStatusCheckState
  let isRequired: Bool
  let completedAt: Date?
  let evidence: EvidenceReference
}

struct PullRequestRuleInput: Sendable {
  let isAuthoredByCurrentUser: Bool
  let latestCurrentUserResponseOrCommitAt: Date?
  let reviews: [PullRequestReviewFeedback]
  let reviewThreads: [PullRequestReviewThread]
  let mergeableState: String?
  let statusChecks: [PullRequestStatusCheck]
  /// Local open actions are necessarily owned by the selected local user.
  /// They never imply a GitHub mutation or an external actor assignment.
  let openUserOwnedActionEvidence: [EvidenceReference]

  init(
    isAuthoredByCurrentUser: Bool,
    latestCurrentUserResponseOrCommitAt: Date?,
    reviews: [PullRequestReviewFeedback],
    reviewThreads: [PullRequestReviewThread],
    mergeableState: String? = nil,
    statusChecks: [PullRequestStatusCheck] = [],
    openUserOwnedActionEvidence: [EvidenceReference] = []
  ) {
    self.isAuthoredByCurrentUser = isAuthoredByCurrentUser
    self.latestCurrentUserResponseOrCommitAt = latestCurrentUserResponseOrCommitAt
    self.reviews = reviews
    self.reviewThreads = reviewThreads
    self.mergeableState = mergeableState
    self.statusChecks = statusChecks
    self.openUserOwnedActionEvidence = openUserOwnedActionEvidence
  }
}

struct PullRequestAttentionRule: Sendable {
  static let version = 1

  func evaluate(
    input: PullRequestRuleInput,
    context: PullRequestRuleContext
  ) -> RuleEvaluation {
    guard input.isAuthoredByCurrentUser else {
      return RuleEvaluation(reasons: [])
    }

    let actionableReviews: [PullRequestReviewFeedback] = input.reviews.filter { review in
      guard let authorNodeID = review.authorNodeID,
        authorNodeID != context.currentUserNodeID,
        let submittedAt = review.submittedAt
      else {
        return false
      }
      return isAfterLatestResponseOrCommit(submittedAt, input: input)
    }
    let changesRequestedEvidence =
      actionableReviews
      .filter { $0.state == .changesRequested }
      .map(\.evidence)
    let unresolvedThreadEvidence = input.reviewThreads
      .filter { !$0.isResolved && $0.requiresCurrentUserResponse }
      .map(\.evidence)
    let newFeedbackEvidence =
      actionableReviews
      .filter { $0.state == .changesRequested || $0.state == .commented }
      .map(\.evidence)
    let requiredFailureEvidence = input.statusChecks
      .filter {
        guard $0.isRequired, $0.state == .failure else { return false }
        return $0.completedAt.map { isAfterLatestResponseOrCommit($0, input: input) } ?? false
      }
      .map(\.evidence)
    let mergeableUserActionEvidence: [EvidenceReference] =
      input.mergeableState == "MERGEABLE" ? input.openUserOwnedActionEvidence : []

    let definitions: [(PullRequestAttentionRuleID, Int, String, String, [EvidenceReference])] = [
      (
        .changesRequested,
        900,
        "Changes requested",
        "A reviewer requested changes and you have not responded with a newer reply or commit.",
        changesRequestedEvidence
      ),
      (
        .unresolvedReviewThreads,
        850,
        "Unresolved review threads",
        "Review threads explicitly requiring your response remain unresolved.",
        unresolvedThreadEvidence
      ),
      (
        .requiredCheckFailed,
        825,
        "Required check failed",
        "A required status check failed after your latest response or commit.",
        requiredFailureEvidence
      ),
      (
        .newReviewFeedback,
        800,
        "New review feedback",
        "Your pull request has new review feedback after your latest response or commit.",
        newFeedbackEvidence
      ),
      (
        .mergeableWaitingOnUserAction,
        775,
        "Mergeable pull request needs your action",
        "This pull request is mergeable, but an open action owned by you remains.",
        mergeableUserActionEvidence
      ),
    ]

    return RuleEvaluation(
      reasons: definitions.compactMap { definition in
        guard !definition.4.isEmpty else { return nil }
        return reason(
          id: definition.0,
          strength: definition.1,
          title: definition.2,
          explanation: definition.3,
          evidence: definition.4,
          evaluatedAt: context.evaluatedAt
        )
      }
    )
  }

  private func isAfterLatestResponseOrCommit(
    _ date: Date,
    input: PullRequestRuleInput
  ) -> Bool {
    date > (input.latestCurrentUserResponseOrCommitAt ?? .distantPast)
  }

  private func reason(
    id: PullRequestAttentionRuleID,
    strength: Int,
    title: String,
    explanation: String,
    evidence: [EvidenceReference],
    evaluatedAt: Date
  ) -> AttentionReason {
    let sortedEvidence = evidence.sorted { $0.id.rawValue < $1.id.rawValue }
    return AttentionReason(
      id: "\(id.rawValue)-\(sortedEvidence.map(\.id.rawValue).joined(separator: "-"))",
      category: .pullRequest,
      ruleID: id.rawValue,
      ruleVersion: Self.version,
      strength: strength,
      title: title,
      explanation: explanation,
      evidence: sortedEvidence,
      evaluatedAt: evaluatedAt
    )
  }
}
