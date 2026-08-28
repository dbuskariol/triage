import Foundation

enum WaitingAttentionRuleID: String, Codable, Sendable {
  case awaitedActorResponded
  case followUpDue
}

struct WaitingWorkflowEvidence: Sendable {
  let status: LocalWorkStatus
  let beganAt: Date?
  let followUpAt: Date?
  let evidence: EvidenceReference
}

struct AwaitedActorResponseEvidence: Sendable {
  let actorNodeID: GitHubNodeID
  let occurredAt: Date
  let evidence: EvidenceReference
}

struct WaitingRuleInput: Sendable {
  let workflow: WaitingWorkflowEvidence
  let awaitedActorNodeID: GitHubNodeID?
  let responses: [AwaitedActorResponseEvidence]
}

struct WaitingRuleContext: Sendable {
  let evaluatedAt: Date
}

struct WaitingAttentionRule: Sendable {
  static let version = 1

  func evaluate(
    input: WaitingRuleInput,
    context: WaitingRuleContext
  ) -> RuleEvaluation {
    guard input.workflow.status == .waiting else {
      return RuleEvaluation(reasons: [])
    }

    let responseEvidence = responsesAfterWaitingBegan(input: input)
    let followUpEvidence =
      input.workflow.followUpAt.map { followUpAt in
        followUpAt <= context.evaluatedAt ? [input.workflow.evidence] : []
      } ?? []
    let definitions: [(WaitingAttentionRuleID, Int, String, String, [EvidenceReference])] = [
      (
        .awaitedActorResponded,
        750,
        "Awaited response received",
        "The actor you were explicitly awaiting responded after Waiting began.",
        responseEvidence
      ),
      (
        .followUpDue,
        650,
        "Waiting follow-up due",
        "The explicit Waiting follow-up date has arrived.",
        followUpEvidence
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

  private func responsesAfterWaitingBegan(input: WaitingRuleInput) -> [EvidenceReference] {
    guard let awaitedActorNodeID = input.awaitedActorNodeID,
      let beganAt = input.workflow.beganAt
    else {
      return []
    }

    return input.responses.compactMap { response in
      guard response.actorNodeID == awaitedActorNodeID, response.occurredAt > beganAt else {
        return nil
      }
      return response.evidence
    }
  }

  private func reason(
    id: WaitingAttentionRuleID,
    strength: Int,
    title: String,
    explanation: String,
    evidence: [EvidenceReference],
    evaluatedAt: Date
  ) -> AttentionReason {
    let sortedEvidence = evidence.sorted { $0.id.rawValue < $1.id.rawValue }
    return AttentionReason(
      id: "\(id.rawValue)-\(sortedEvidence.map(\.id.rawValue).joined(separator: "-"))",
      category: .waiting,
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
