import Foundation

enum LocalWorkStatus: String, Codable, Sendable {
    case active
    case archived
    case waiting
}

enum WorkPriority: Int, CaseIterable, Codable, Comparable, Sendable {
    case low = 1
    case normal = 2
    case high = 3

    static func < (lhs: WorkPriority, rhs: WorkPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ActionItemOrigin: String, Codable, Sendable {
    case deterministicRule
    case copilot
    case manual
}

enum ActionItemState: String, Codable, Sendable {
    case open
    case completed
    case dismissed
    case superseded
    case invalidated
}

/// The deliberately small set of fields a person may change on an action
/// item. Provenance, evidence, origin, and completion state stay owned by
/// Triage's normalized/local workflow records and cannot be rewritten from
/// the inspector.
struct LocalActionItemEdit: Equatable, Sendable {
    let title: String
    let detail: String?
    let priority: WorkPriority
    let dueAt: Date?

    init?(
        title: String,
        detail: String?,
        priority: WorkPriority,
        dueAt: Date?
    ) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty, normalizedTitle.count <= 500 else { return nil }
        let normalizedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedDetail?.count ?? 0 <= 10_000 else { return nil }
        self.title = normalizedTitle
        self.detail = normalizedDetail?.isEmpty == true ? nil : normalizedDetail
        self.priority = priority
        self.dueAt = dueAt
    }
}

struct WorkflowState: Codable, Equatable, Sendable {
    let status: LocalWorkStatus
    let isPinned: Bool
    let priority: WorkPriority
    let snoozedUntil: Date?
    let followUpAt: Date?
    let localNote: String?
    let updatedAt: Date

    init(
        status: LocalWorkStatus = .active,
        isPinned: Bool = false,
        priority: WorkPriority = .normal,
        snoozedUntil: Date? = nil,
        followUpAt: Date? = nil,
        localNote: String? = nil,
        updatedAt: Date
    ) {
        self.status = status
        self.isPinned = isPinned
        self.priority = priority
        self.snoozedUntil = snoozedUntil
        self.followUpAt = followUpAt
        self.localNote = localNote
        self.updatedAt = updatedAt
    }

    func isSnoozed(at date: Date) -> Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > date
    }
}

struct ActionItem: Codable, Equatable, Sendable, Identifiable {
    let id: ActionItemID
    let workItemID: WorkItemID
    let title: String
    let detail: String?
    let origin: ActionItemOrigin
    let state: ActionItemState
    let priority: WorkPriority
    let dueAt: Date?
    let evidenceIDs: [EvidenceID]
    let sourceFingerprint: String?
    let createdAt: Date
    let updatedAt: Date
    let completedAt: Date?
    let dismissedAt: Date?

    init(
        id: ActionItemID,
        workItemID: WorkItemID,
        title: String,
        detail: String? = nil,
        origin: ActionItemOrigin,
        state: ActionItemState = .open,
        priority: WorkPriority = .normal,
        dueAt: Date? = nil,
        evidenceIDs: [EvidenceID] = [],
        sourceFingerprint: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil,
        dismissedAt: Date? = nil
    ) {
        self.id = id
        self.workItemID = workItemID
        self.title = title
        self.detail = detail
        self.origin = origin
        self.state = state
        self.priority = priority
        self.dueAt = dueAt
        self.evidenceIDs = evidenceIDs
        self.sourceFingerprint = sourceFingerprint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.dismissedAt = dismissedAt
    }

    func completing(at date: Date) -> ActionItem {
        ActionItem(
            id: id,
            workItemID: workItemID,
            title: title,
            detail: detail,
            origin: origin,
            state: .completed,
            priority: priority,
            dueAt: dueAt,
            evidenceIDs: evidenceIDs,
            sourceFingerprint: sourceFingerprint,
            createdAt: createdAt,
            updatedAt: date,
            completedAt: date,
            dismissedAt: dismissedAt
        )
    }

    func applying(_ edit: LocalActionItemEdit, at date: Date) -> ActionItem {
        ActionItem(
            id: id,
            workItemID: workItemID,
            title: edit.title,
            detail: edit.detail,
            origin: origin,
            state: state,
            priority: edit.priority,
            dueAt: edit.dueAt,
            evidenceIDs: evidenceIDs,
            sourceFingerprint: sourceFingerprint,
            createdAt: createdAt,
            updatedAt: date,
            completedAt: completedAt,
            dismissedAt: dismissedAt
        )
    }

    var localEdit: LocalActionItemEdit? {
        LocalActionItemEdit(title: title, detail: detail, priority: priority, dueAt: dueAt)
    }
}
