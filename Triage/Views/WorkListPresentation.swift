import Foundation

extension WorkspaceSearchScope {
    var title: String {
        switch self {
        case .currentView: "Current View"
        case .organization: "Selected Organization"
        }
    }
}

extension WorkspaceSearchSort {
    var title: String {
        switch self {
        case .relevance: "Relevance"
        case .attention: "Attention"
        case .recent: "Recent Activity"
        }
    }
}

extension WorkspaceListFilter {
    var title: String {
        switch self {
        case .all: "All Work"
        case .pinned: "Pinned"
        case .highPriority: "High Priority"
        case .openActionItems: "Open Action Items"
        }
    }
}

/// Pure queue-row and request-identity decisions. These stay out of the
/// SwiftUI hierarchy so accessibility semantics and stale-search protection
/// are deterministic and testable.
enum WorkListPresentation {
    /// Uses the persisted attention reasons and workflow state that were
    /// committed by derived intelligence. The only clock-dependent fields are
    /// explicit local snooze/follow-up deadlines; this never re-runs ranking
    /// rules in the view layer.
    static func effectiveDisposition(for item: WorkItem, at now: Date) -> InboxDisposition {
        InboxEligibilityRule().disposition(for: item, at: now)
    }

    static func items(
        from workItems: [WorkItem],
        section: AppSection,
        at now: Date
    ) -> [WorkItem] {
        let matching = workItems.filter { item in
            switch section {
            case .inbox:
                effectiveDisposition(for: item, at: now) == .inbox
            case .waiting:
                effectiveDisposition(for: item, at: now) == .waiting
            case .snoozed:
                effectiveDisposition(for: item, at: now) == .snoozed
            case .myWork:
                item.relations.contains { $0.kind == .assigned || $0.kind == .authored }
            case .reviews:
                item.relations.contains {
                    $0.kind == .reviewRequestedDirectly || $0.kind == .reviewRequestedFromTeam
                }
            case .allWork:
                true
            }
        }
        return rankedPersisted(matching)
    }

    static func rankedPersisted(_ workItems: [WorkItem]) -> [WorkItem] {
        AttentionRanker().sortPersisted(workItems)
    }

    /// Short, model-backed row metadata. The list deliberately omits a field
    /// rather than inventing a placeholder when the cached item has no value.
    static func visibleMetadata(for item: WorkItem, at now: Date) -> [String] {
        var components = [String]()

        if let responsibility = responsibilityTitle(for: item) {
            components.append(responsibility)
        }
        if let author = item.members.first(where: { $0.role == .primary })?.content.author {
            components.append("by \(author.displayName ?? author.login)")
        }
        if item.workflow.priority != .normal {
            components.append("\(priorityTitle(item.workflow.priority)) priority")
        }
        if item.workflow.status == .waiting {
            components.append("Waiting")
        }
        if item.workflow.isSnoozed(at: now), let snoozedUntil = item.workflow.snoozedUntil {
            components.append("Snoozed until \(snoozedUntil.formatted(date: .abbreviated, time: .shortened))")
        }
        if item.freshness.status != .fresh {
            components.append(freshnessTitle(item.freshness.status))
        }
        components.append("Activity \(item.lastRelevantActivityAt.formatted(date: .abbreviated, time: .omitted))")
        return components
    }

    static func accessibilityLabel(for item: WorkItem, at now: Date) -> String {
        var components = ["\(sourceTitle(item.sourceKind)), \(item.title)"]

        if let repository = item.repository {
            components.append("Repository \(repository.fullName)")
        }

        if item.state != .active {
            components.append("Source \(item.state.rawValue)")
        }

        if let reason = item.attentionReasons.max(by: { $0.strength < $1.strength }) {
            components.append("Attention: \(reason.title)")
        }

        if item.workflow.isPinned {
            components.append("Pinned in Triage")
        }

        switch item.workflow.status {
        case .active:
            break
        case .archived:
            components.append("Archived in Triage")
        case .waiting:
            components.append("Waiting in Triage")
        }

        if item.workflow.priority != .normal {
            components.append("\(priorityTitle(item.workflow.priority)) priority in Triage")
        }

        if item.workflow.isSnoozed(at: now), let snoozedUntil = item.workflow.snoozedUntil {
            components.append("Snoozed until \(snoozedUntil.formatted(date: .abbreviated, time: .shortened))")
        }

        if let followUpAt = item.workflow.followUpAt {
            components.append("Follow up \(followUpAt.formatted(date: .abbreviated, time: .shortened))")
        }

        let actionCount = item.openActionItems.count
        if actionCount > 0 {
            components.append("\(actionCount) open action \(actionCount == 1 ? "item" : "items")")
        }

        components.append("Freshness: \(freshnessTitle(item.freshness.status))")
        return components.joined(separator: ". ")
    }

    static func shouldApplySearchResult(
        for request: WorkListSearchRequest,
        currentRequest: WorkListSearchRequest,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && request == currentRequest
    }

    static func shouldUseSearchResults(
        producedFor request: WorkListSearchRequest?,
        currentRequest: WorkListSearchRequest
    ) -> Bool {
        request == currentRequest
    }

    /// `Inbox zero` is an affirmative synchronization claim. Reserve it for
    /// current workspace coverage, and present the explicit workspace status
    /// whenever the queue is degraded or still refreshing.
    static func canPresentSuccessfulEmptyQueue(
        query: String,
        isSearching: Bool,
        searchError: String?,
        workspaceStatus: WorkspacePresentationState.SynchronizationStatus
    ) -> Bool {
        !isSearching
            && searchError == nil
            && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && WorkspacePresentationState.emptyQueueCanUseSuccessCopy(for: workspaceStatus)
    }

    /// Selects the empty-queue surface without letting a failed cache search
    /// fall through to the benign "no matching work" message.
    static func emptyQueuePresentation(
        query: String,
        isSearching: Bool,
        searchError: String?,
        workspaceStatus: WorkspacePresentationState.SynchronizationStatus
    ) -> WorkListEmptyQueuePresentation? {
        if searchError != nil {
            return .searchUnavailable
        }
        guard !isSearching else { return nil }
        if canPresentSuccessfulEmptyQueue(
            query: query,
            isSearching: isSearching,
            searchError: searchError,
            workspaceStatus: workspaceStatus
        ) {
            return .successfulEmptyQueue
        }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .noMatchingWork
        }
        return .workspaceStatus
    }

    /// Disclosure is read-only presentation of action-item titles. The list
    /// deliberately omits details, evidence, and completion controls so it
    /// cannot expose more content than requested or introduce bulk actions.
    static func actionDisclosure(for item: WorkItem) -> WorkListActionDisclosure? {
        let openActionItems = item.openActionItems
        guard !openActionItems.isEmpty else { return nil }
        let count = openActionItems.count
        let title = "\(count) open action \(count == 1 ? "item" : "items")"
        return WorkListActionDisclosure(
            title: title,
            accessibilityLabel: "\(title), stored locally in Triage"
        )
    }

    private static func sourceTitle(_ kind: GitHubContentKind) -> String {
        switch kind {
        case .issue: "Issue"
        case .pullRequest: "Pull Request"
        case .discussion: "Discussion"
        default: kind.rawValue
        }
    }

    private static func priorityTitle(_ priority: WorkPriority) -> String {
        switch priority {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }

    private static func responsibilityTitle(for item: WorkItem) -> String? {
        if item.relations.contains(where: { $0.kind == .assigned }) {
            return "Assigned to you"
        }
        if item.relations.contains(where: { $0.kind == .authored }) {
            return "Authored by you"
        }
        if item.relations.contains(where: { $0.kind == .reviewRequestedDirectly }) {
            return "Your review requested"
        }
        if item.relations.contains(where: { $0.kind == .reviewRequestedFromTeam }) {
            return "Team review requested"
        }
        return nil
    }

    private static func freshnessTitle(_ status: FreshnessStatus) -> String {
        switch status {
        case .fresh: "Current"
        case .refreshing: "Refreshing"
        case .stale: "Stale cache"
        case .partial: "Partial coverage"
        case .offline: "Offline cache"
        case .authenticationRequired: "Sign-in required"
        case .ssoRequired: "SSO authorization required"
        case .approvalRequired: "Organization approval required"
        case .rateLimited: "Rate limited"
        case .failed: "Refresh failed"
        }
    }
}

struct WorkListActionDisclosure: Equatable {
    let title: String
    let accessibilityLabel: String
}

enum WorkListEmptyQueuePresentation: Equatable {
    case searchUnavailable
    case successfulEmptyQueue
    case noMatchingWork
    case workspaceStatus
}

struct WorkListSearchRequest: Equatable, Hashable {
    let accountID: AccountID?
    let organizationID: OrganizationID?
    let query: String

    init(accountID: AccountID?, organizationID: OrganizationID?, query: String) {
        self.accountID = accountID
        self.organizationID = organizationID
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The observation identity for restoring a scoped selection. It changes when
/// the active account, organization, or locally available work changes, so a
/// stale stored selection is cleared before it can reach the detail view.
struct WorkListSelectionRestorationRequest: Equatable, Hashable {
    let accountID: AccountID?
    let organizationID: OrganizationID?
    let validWorkItemIDs: Set<WorkItemID>
}

/// Coordinates the native list's possibly-many selected rows with the one
/// work item that drives the detail column, local workflow commands, and
/// selection history. It intentionally owns no persistence: only the primary
/// item is a durable workspace choice.
struct WorkListSelection: Equatable {
    private(set) var selectedWorkItemIDs = Set<WorkItemID>()
    private(set) var primaryWorkItemID: WorkItemID?
    private var accountID: AccountID?
    private var organizationID: OrganizationID?

    /// Applies the selection emitted by SwiftUI's native `List`. Additive
    /// selection retains the current primary detail item while it remains
    /// selected. When it does not, choose a deterministic visible row so the
    /// detail column, commands, and history always have one clear target.
    mutating func applyNativeSelection(
        _ workItemIDs: Set<WorkItemID>,
        orderedWorkItemIDs: [WorkItemID]
    ) -> WorkItemID? {
        let newlySelectedIDs = workItemIDs.subtracting(selectedWorkItemIDs)
        selectedWorkItemIDs = workItemIDs

        if let primaryWorkItemID, workItemIDs.contains(primaryWorkItemID) {
            return primaryWorkItemID
        }

        let primaryWorkItemID = firstID(
            in: newlySelectedIDs,
            orderedWorkItemIDs: orderedWorkItemIDs
        ) ?? firstID(in: workItemIDs, orderedWorkItemIDs: orderedWorkItemIDs)
        self.primaryWorkItemID = primaryWorkItemID
        return primaryWorkItemID
    }

    /// Mirrors an externally selected primary item, such as selection history
    /// navigation. An existing multi-selection remains intact when it already
    /// includes that item; otherwise the external single selection becomes the
    /// native list selection.
    mutating func synchronizePrimarySelection(_ workItemID: WorkItemID?) {
        primaryWorkItemID = workItemID
        guard let workItemID else {
            selectedWorkItemIDs = []
            return
        }
        guard !selectedWorkItemIDs.contains(workItemID) else { return }
        selectedWorkItemIDs = [workItemID]
    }

    /// Restores the persisted primary selection only in its exact workspace.
    /// A workspace transition must never carry a multiple selection into a
    /// different account or organization, even if opaque IDs overlap.
    mutating func restore(
        primaryWorkItemID: WorkItemID?,
        request: WorkListSelectionRestorationRequest
    ) {
        let didChangeWorkspace = accountID != request.accountID
            || organizationID != request.organizationID
        accountID = request.accountID
        organizationID = request.organizationID

        if didChangeWorkspace {
            selectedWorkItemIDs = []
        } else {
            selectedWorkItemIDs.formIntersection(request.validWorkItemIDs)
        }

        guard let primaryWorkItemID,
              request.validWorkItemIDs.contains(primaryWorkItemID)
        else {
            self.primaryWorkItemID = nil
            selectedWorkItemIDs = []
            return
        }

        self.primaryWorkItemID = primaryWorkItemID
        if !selectedWorkItemIDs.contains(primaryWorkItemID) {
            selectedWorkItemIDs = [primaryWorkItemID]
        }
    }

    /// Contextual commands deliberately target one row. This maintains the
    /// existing action contract and avoids introducing implicit bulk actions.
    mutating func selectContextualWorkItem(_ workItemID: WorkItemID) {
        selectedWorkItemIDs = [workItemID]
        primaryWorkItemID = workItemID
    }

    private func firstID(
        in candidates: Set<WorkItemID>,
        orderedWorkItemIDs: [WorkItemID]
    ) -> WorkItemID? {
        if let visibleID = orderedWorkItemIDs.first(where: candidates.contains) {
            return visibleID
        }
        return candidates.min { $0.rawValue < $1.rawValue }
    }
}

enum WorkItemContextMenuOperation: Equatable {
    case archive
    case unarchive
    case setPinned(Bool)
    case setPriority(WorkPriority)
    case snooze(SnoozePreset)
    case clearSnooze
    case markWaiting
    case clearWaiting

    enum SnoozePreset: Equatable {
        case oneHour
        case tomorrow
        case nextWeek

        func action(now: Date) -> WorkflowAction {
            let interval: TimeInterval
            switch self {
            case .oneHour: interval = 3_600
            case .tomorrow: interval = 86_400
            case .nextWeek: interval = 7 * 86_400
            }
            return .snooze(until: now.addingTimeInterval(interval))
        }
    }

    func workflowAction(now: Date) -> WorkflowAction {
        switch self {
        case .archive: .archive
        case .unarchive: .unarchive
        case let .setPinned(isPinned): .setPinned(isPinned)
        case let .setPriority(priority): .setPriority(priority)
        case let .snooze(preset): preset.action(now: now)
        case .clearSnooze: .clearSnooze
        case .markWaiting: .markWaiting(followUpAt: nil)
        case .clearWaiting: .clearWaiting
        }
    }
}

/// A pure projection of command availability for one native list-row context
/// menu. Keeping this policy shared with the list presentation lets its menu
/// stay deterministic while all mutations still route to the app model.
struct WorkItemContextMenuPolicy: Equatable {
    static let localOnlyAccessibilityHint =
        "Changes only Triage’s local workflow state; it does not modify GitHub."

    let archiveOperation: WorkItemContextMenuOperation?
    let pinOperation: WorkItemContextMenuOperation
    let priorityOperations: [WorkItemContextMenuOperation]
    let snoozeOperations: [WorkItemContextMenuOperation]
    let clearSnoozeOperation: WorkItemContextMenuOperation?
    let waitingOperation: WorkItemContextMenuOperation?

    init(item: WorkItem) {
        let availability = TriageWorkflowCommandAvailability(item: item)
        archiveOperation = availability.canArchive
            ? .archive
            : (availability.canUnarchive ? .unarchive : nil)
        pinOperation = .setPinned(!item.workflow.isPinned)
        priorityOperations = WorkPriority.allCases.map(WorkItemContextMenuOperation.setPriority)
        snoozeOperations = availability.canSnooze
            ? [.snooze(.oneHour), .snooze(.tomorrow), .snooze(.nextWeek)]
            : []
        clearSnoozeOperation = availability.canClearSnooze ? .clearSnooze : nil
        waitingOperation = availability.canMarkWaiting
            ? .markWaiting
            : (availability.canClearWaiting ? .clearWaiting : nil)
    }
}
