import Foundation

enum ProgressAttentionRuleID: String, Codable, Sendable {
  case overdueDueActions
  case linkedPullRequestNeedsIssueUpdate
  case ownedWorkStale
  case dueActionsApproaching
}

struct ProgressRuleContext: Sendable {
  let businessDayPolicy: BusinessDayPolicy
  let calendar: Calendar
  let evaluatedAt: Date
  let dueSoonInterval: TimeInterval

  init(
    businessDayPolicy: BusinessDayPolicy,
    calendar: Calendar,
    evaluatedAt: Date,
    dueSoonInterval: TimeInterval = 3 * 86_400
  ) {
    precondition(dueSoonInterval > 0, "A due-soon interval must be positive.")
    self.businessDayPolicy = businessDayPolicy
    self.calendar = calendar
    self.evaluatedAt = evaluatedAt
    self.dueSoonInterval = dueSoonInterval
  }
}

struct QualifyingProgressEvidence: Sendable {
  let occurredAt: Date
  let evidence: EvidenceReference
}

struct LinkedPullRequestProgressEvidence: Sendable {
  let startedAt: Date
  let evidence: EvidenceReference
}

struct DueActionEvidence: Sendable {
  let id: ActionItemID
  let isOpen: Bool
  let dueAt: Date?
  let evidence: EvidenceReference
}

struct ProgressRuleInput: Sendable {
  let isOwnedByCurrentUser: Bool
  let latestQualifyingProgress: QualifyingProgressEvidence?
  let sourceIssueLastUpdatedAt: Date?
  let sourceIssueEvidence: EvidenceReference?
  let linkedPullRequests: [LinkedPullRequestProgressEvidence]
  let dueActions: [DueActionEvidence]
}

struct ProgressAttentionRule: Sendable {
  static let version = 1

  func evaluate(
    input: ProgressRuleInput,
    context: ProgressRuleContext
  ) -> RuleEvaluation {
    let overdueEvidence = input.dueActions.compactMap { action -> EvidenceReference? in
      guard action.isOpen, let dueAt = action.dueAt, dueAt <= context.evaluatedAt else {
        return nil
      }
      return action.evidence
    }
    let linkedPullRequestEvidence = input.linkedPullRequests.compactMap {
      pullRequest -> EvidenceReference? in
      guard input.sourceIssueLastUpdatedAt.map({ $0 <= pullRequest.startedAt }) ?? true else {
        return nil
      }
      return pullRequest.evidence
    }
    let staleEvidence: [EvidenceReference]
    if input.isOwnedByCurrentUser,
      let progress = input.latestQualifyingProgress,
      context.businessDayPolicy.isStale(
        latestProgressAt: progress.occurredAt,
        at: context.evaluatedAt,
        calendar: context.calendar
      )
    {
      staleEvidence = [progress.evidence]
    } else {
      staleEvidence = []
    }
    let dueSoonEvidence = input.dueActions.compactMap { action -> EvidenceReference? in
      guard action.isOpen,
        let dueAt = action.dueAt,
        dueAt > context.evaluatedAt,
        dueAt <= context.evaluatedAt.addingTimeInterval(context.dueSoonInterval)
      else {
        return nil
      }
      return action.evidence
    }

    let sourceIssueEvidence = input.sourceIssueEvidence.map { [$0] } ?? []
    let definitions: [(ProgressAttentionRuleID, Int, String, String, [EvidenceReference])] = [
      (
        .overdueDueActions,
        800,
        "Due actions overdue",
        "One or more explicit open actions are overdue.",
        overdueEvidence
      ),
      (
        .linkedPullRequestNeedsIssueUpdate,
        700,
        "Issue needs an update",
        "A linked pull request started without a later source issue update.",
        linkedPullRequestEvidence + sourceIssueEvidence
      ),
      (
        .ownedWorkStale,
        650,
        "Owned work is stale",
        "Your owned work has no qualifying progress within the configured business-day threshold.",
        staleEvidence
      ),
      (
        .dueActionsApproaching,
        600,
        "Due actions approaching",
        "One or more explicit open actions are due within the configured interval.",
        dueSoonEvidence
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

  private func reason(
    id: ProgressAttentionRuleID,
    strength: Int,
    title: String,
    explanation: String,
    evidence: [EvidenceReference],
    evaluatedAt: Date
  ) -> AttentionReason {
    let sortedEvidence = evidence.sorted { $0.id.rawValue < $1.id.rawValue }
    return AttentionReason(
      id: "\(id.rawValue)-\(sortedEvidence.map(\.id.rawValue).joined(separator: "-"))",
      category: .progress,
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
