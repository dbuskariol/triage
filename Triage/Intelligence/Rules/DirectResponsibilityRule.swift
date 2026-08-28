import Foundation

enum AttentionRuleID: String, Codable, Sendable {
    case assignedToCurrentUser
    case directReviewRequest
    case teamReviewRequest
    case projectAssignment
}

struct AttentionRuleContext: Sendable {
    let currentUserNodeID: GitHubNodeID
    let visibleTeamNodeIDs: Set<GitHubNodeID>
    let evaluatedAt: Date

    init(
        currentUserNodeID: GitHubNodeID,
        visibleTeamNodeIDs: Set<GitHubNodeID>,
        evaluatedAt: Date
    ) {
        self.currentUserNodeID = currentUserNodeID
        self.visibleTeamNodeIDs = visibleTeamNodeIDs
        self.evaluatedAt = evaluatedAt
    }
}

struct RuleEvaluation: Equatable, Sendable {
    let reasons: [AttentionReason]
}

struct DirectResponsibilityRule: Sendable {
    static let version = 1

    func evaluate(
        relations: [WorkRelation],
        context: AttentionRuleContext
    ) -> RuleEvaluation {
        let rules: [(AttentionRuleID, WorkRelationKind, Int, String, String)] = [
            (
                .directReviewRequest,
                .reviewRequestedDirectly,
                1_000,
                "Review requested",
                "You are currently requested to review this pull request."
            ),
            (
                .teamReviewRequest,
                .reviewRequestedFromTeam,
                950,
                "Team review requested",
                "A team you belong to is currently requested to review this pull request."
            ),
            (
                .assignedToCurrentUser,
                .assigned,
                850,
                "Assigned to you",
                "You are currently assigned to this work."
            ),
            (
                .projectAssignment,
                .projectWrapsContent,
                800,
                "Project work assigned to you",
                "A linked project item assigns this work to you."
            )
        ]

        let reasons: [AttentionReason] = rules.compactMap { rule in
            let matchingRelations = relations.filter {
                guard $0.kind == rule.1 else { return false }
                switch rule.0 {
                case .teamReviewRequest:
                    guard let teamNodeID = $0.objectNodeID else { return false }
                    return context.visibleTeamNodeIDs.contains(teamNodeID)
                case .assignedToCurrentUser, .directReviewRequest, .projectAssignment:
                    return $0.objectNodeID == context.currentUserNodeID
                }
            }

            guard !matchingRelations.isEmpty else { return nil }
            return AttentionReason(
                id: "\(rule.0.rawValue)-\(matchingRelations.map(\.subjectNodeID.rawValue).sorted().joined(separator: "-"))",
                category: .directResponsibility,
                ruleID: rule.0.rawValue,
                ruleVersion: Self.version,
                strength: rule.2,
                title: rule.3,
                explanation: rule.4,
                evidence: matchingRelations.flatMap(\.evidence),
                evaluatedAt: context.evaluatedAt
            )
        }

        return RuleEvaluation(reasons: reasons)
    }
}
