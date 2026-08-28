import Foundation

enum WorkItemState: String, Codable, Sendable {
    case active
    case resolved
    case inaccessible
}

enum WorkItemMemberRole: String, Codable, Sendable {
    case primary
    case closingPullRequest
    case linkedIssue
    case review
    case reviewThread
    case comment
    case projectItem
    case discussion
}

struct WorkItemMember: Codable, Equatable, Sendable, Identifiable {
    let id: GitHubNodeID
    let role: WorkItemMemberRole
    let content: GitHubContentSummary
    let evidence: [EvidenceReference]
}

struct WorkItemContextLink: Codable, Equatable, Sendable, Identifiable {
    let id: GitHubNodeID
    let relation: WorkRelationKind
    let content: GitHubContentSummary
    let evidence: [EvidenceReference]
}

struct WorkItem: Codable, Equatable, Sendable, Identifiable {
    let id: WorkItemID
    let accountID: AccountID
    let organizationID: OrganizationID
    let primaryNodeID: GitHubNodeID
    let title: String
    let state: WorkItemState
    let sourceKind: GitHubContentKind
    let repository: RepositorySummary?
    let members: [WorkItemMember]
    let contextLinks: [WorkItemContextLink]
    let relations: [WorkRelation]
    let attentionReasons: [AttentionReason]
    let actionItems: [ActionItem]
    let workflow: WorkflowState
    let freshness: FreshnessState
    let lastRelevantActivityAt: Date
    let score: AttentionScore

    var openActionItems: [ActionItem] {
        actionItems.filter { $0.state == .open }
    }

    func isVisibleInInbox(at date: Date) -> Bool {
        workflow.status != .archived
            && !workflow.isSnoozed(at: date)
            && (workflow.isPinned || !attentionReasons.isEmpty || !openActionItems.isEmpty)
    }
}

enum GroupingStrength: String, Codable, Comparable, Sendable {
    case contextual
    case strong
    case userConfirmed

    static func < (lhs: GroupingStrength, rhs: GroupingStrength) -> Bool {
        switch (lhs, rhs) {
        case (.contextual, .strong), (.contextual, .userConfirmed), (.strong, .userConfirmed):
            true
        default:
            false
        }
    }
}

struct WorkItemGroupingDecision: Codable, Equatable, Sendable {
    let sourceNodeID: GitHubNodeID
    let destinationNodeID: GitHubNodeID
    let relation: WorkRelationKind
    let strength: GroupingStrength
    let evidence: [EvidenceReference]
    let decidedAt: Date
}
