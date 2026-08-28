import Foundation

enum ConversationAttentionRuleID: String, Codable, Sendable {
    case directMentionAfterProgress
    case teamMentionAfterProgress
    case newActivityOnParticipatedWork
}

struct ConversationRuleContext: Sendable {
    let currentUserNodeID: GitHubNodeID
    let visibleTeamNodeIDs: Set<GitHubNodeID>
    let latestQualifyingProgressAt: Date?
    let evaluatedAt: Date
}

struct ConversationFollowUpRule: Sendable {
    static let version = 1

    func evaluate(
        relations: [WorkRelation],
        timeline: [TimelineEventSummary],
        context: ConversationRuleContext
    ) -> RuleEvaluation {
        var reasons: [AttentionReason] = []

        let directMentionEvidence = relations
            .filter {
                $0.kind == .mentioned
                    && $0.objectNodeID == context.currentUserNodeID
                    && occurredAfterLatestProgress($0.observedAt, context: context)
            }
            .flatMap(\.evidence)
        if !directMentionEvidence.isEmpty {
            reasons.append(reason(
                id: .directMentionAfterProgress,
                strength: 750,
                title: "Mentioned after your update",
                explanation: "You were directly mentioned after your latest qualifying progress update.",
                evidence: directMentionEvidence,
                context: context
            ))
        }

        let teamMentionEvidence = relations
            .filter {
                $0.kind == .teamMentioned
                    && $0.objectNodeID.map(context.visibleTeamNodeIDs.contains) == true
                    && occurredAfterLatestProgress($0.observedAt, context: context)
            }
            .flatMap(\.evidence)
        if !teamMentionEvidence.isEmpty {
            reasons.append(reason(
                id: .teamMentionAfterProgress,
                strength: 700,
                title: "Your team was mentioned",
                explanation: "A team you belong to was mentioned after your latest qualifying progress update.",
                evidence: teamMentionEvidence,
                context: context
            ))
        }

        let participates = relations.contains {
            $0.objectNodeID == context.currentUserNodeID
                && [.authored, .commented, .reviewed].contains($0.kind)
        }
        let newActivity = timeline.filter {
            $0.actor?.nodeID != context.currentUserNodeID
                && $0.occurredAt > (context.latestQualifyingProgressAt ?? .distantPast)
                && [.commented, .reviewed, .reviewThreadUnresolved].contains($0.kind)
        }
        if participates, !newActivity.isEmpty {
            reasons.append(reason(
                id: .newActivityOnParticipatedWork,
                strength: 500,
                title: "New activity on work you joined",
                explanation: "Someone else added relevant conversation activity after your latest qualifying progress update.",
                evidence: newActivity.map {
                    EvidenceReference(
                        id: EvidenceID(rawValue: "timeline-\($0.id.rawValue)")!,
                        source: .restTimeline,
                        nodeID: $0.subjectNodeID,
                        eventID: $0.id,
                        observedAt: $0.occurredAt,
                        excerpt: $0.body
                    )
                },
                context: context
            ))
        }

        return RuleEvaluation(reasons: reasons)
    }

    private func occurredAfterLatestProgress(
        _ observedAt: Date,
        context: ConversationRuleContext
    ) -> Bool {
        observedAt > (context.latestQualifyingProgressAt ?? .distantPast)
    }

    private func reason(
        id: ConversationAttentionRuleID,
        strength: Int,
        title: String,
        explanation: String,
        evidence: [EvidenceReference],
        context: ConversationRuleContext
    ) -> AttentionReason {
        AttentionReason(
            id: "\(id.rawValue)-\(evidence.map(\.id.rawValue).sorted().joined(separator: "-"))",
            category: .conversation,
            ruleID: id.rawValue,
            ruleVersion: Self.version,
            strength: strength,
            title: title,
            explanation: explanation,
            evidence: evidence,
            evaluatedAt: context.evaluatedAt
        )
    }
}
