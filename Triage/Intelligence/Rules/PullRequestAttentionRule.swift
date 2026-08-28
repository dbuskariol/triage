import Foundation

enum PullRequestAttentionRuleID: String, Codable, Sendable {
  case changesRequested
  case unresolvedReviewThreads
  case newReviewFeedback
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

struct PullRequestRuleInput: Sendable {
  let isAuthoredByCurrentUser: Bool
  let latestCurrentUserResponseOrCommitAt: Date?
  let reviews: [PullRequestReviewFeedback]
  let reviewThreads: [PullRequestReviewThread]
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
        .newReviewFeedback,
        800,
        "New review feedback",
        "Your pull request has new review feedback after your latest response or commit.",
        newFeedbackEvidence
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
