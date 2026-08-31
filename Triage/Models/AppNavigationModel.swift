import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case inbox
    case myWork
    case reviews
    case waiting
    case snoozed
    case allWork

    var id: Self { self }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .myWork: "My Work"
        case .reviews: "Reviews"
        case .waiting: "Waiting"
        case .snoozed: "Snoozed"
        case .allWork: "All Work"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .myWork: "person.crop.circle"
        case .reviews: "text.badge.checkmark"
        case .waiting: "hourglass"
        case .snoozed: "clock"
        case .allWork: "rectangle.stack"
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case accounts
    case organizations
    case inbox
    case notifications
    case ai
    case general
    case updates
    case about

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .accounts: "person.crop.circle"
        case .organizations: "building.2"
        case .inbox: "tray"
        case .notifications: "bell"
        case .ai: "sparkles"
        case .general: "gearshape"
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle"
        }
    }
}

/// Presentation-only choices for the local work search. Keeping these values
/// outside `WorkListView` lets a window restore them without coupling the
/// persistence layer to a particular SwiftUI control.
enum WorkspaceSearchScope: String, CaseIterable, Identifiable {
    case currentView
    case organization

    var id: Self { self }
}

enum WorkspaceSearchSort: String, CaseIterable, Identifiable {
    case relevance
    case attention
    case recent

    var id: Self { self }
}

/// A durable local presentation filter. The work-list owner can add supported
/// cases as filters are introduced without changing restoration mechanics.
enum WorkspaceListFilter: String, CaseIterable, Identifiable {
    case all
    case pinned
    case highPriority
    case openActionItems

    var id: Self { self }
}

/// Bounds for native workspace split sizing. These are deliberately limited to
/// useful desktop sizes so corrupt preferences cannot collapse a column or make
/// the main window impractical to use.
enum WorkspaceSplitLayout {
    static let sidebarMinimumWidth = 200.0
    static let sidebarDefaultWidth = 218.0
    static let sidebarMaximumWidth = 260.0

    static let contentMinimumWidth = 320.0
    static let contentDefaultWidth = 390.0
    static let contentMaximumWidth = 520.0

    static let inspectorMinimumWidth = 280.0
    static let inspectorDefaultWidth = 340.0
    static let inspectorMaximumWidth = 520.0
}

/// The primary `Window` uses this stable, non-sensitive identifier. SwiftUI
/// associates it with the system-managed frame restoration record rather than
/// storing display geometry in application preferences.
enum WorkspaceWindowRestoration {
    static let mainWindowFrameIdentifier = "main"
}

private struct WorkspaceSelectionScope: Codable, Hashable {
    let accountID: AccountID
    let organizationID: OrganizationID
}

private struct WorkspaceStoredSelection: Codable, Equatable {
    let scope: WorkspaceSelectionScope
    let workItemID: WorkItemID
}

/// Ephemeral, scope-keyed selection history. It intentionally is not restored
/// across launches: a persisted selection is useful, whereas replaying old
/// navigation after coverage changes can be misleading.
private struct WorkspaceSelectionHistory: Equatable {
    static let maximumEntries = 20

    var back = [WorkItemID]()
    var forward = [WorkItemID]()

    mutating func appendBack(_ workItemID: WorkItemID) {
        back = appending(workItemID, to: back)
    }

    mutating func appendForward(_ workItemID: WorkItemID) {
        forward = appending(workItemID, to: forward)
    }

    mutating func prune(using validWorkItemIDs: Set<WorkItemID>) {
        back.removeAll { !validWorkItemIDs.contains($0) }
        forward.removeAll { !validWorkItemIDs.contains($0) }
    }

    private func appending(_ workItemID: WorkItemID, to entries: [WorkItemID]) -> [WorkItemID] {
        var entries = entries
        entries.removeAll { $0 == workItemID }
        entries.append(workItemID)
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
        return entries
    }
}

@MainActor
final class AppNavigationModel: ObservableObject {
    private enum PreferenceKey {
        static let section = "workspace.selected-section"
        static let settingsCategory = "settings.selected-category"
        static let searchScope = "workspace.search-scope"
        static let searchSort = "workspace.search-sort"
        static let listFilter = "workspace.list-filter"
        static let inspectorVisible = "workspace.inspector-visible"
        static let sidebarVisible = "workspace.sidebar-visible"
        static let sidebarWidth = "workspace.sidebar-width"
        static let contentWidth = "workspace.content-width"
        static let inspectorWidth = "workspace.inspector-width"
        static let timelineExpanded = "workspace.timeline-expanded"
        static let selectedWorkItems = "workspace.selected-work-items"
    }

    @Published var section: AppSection {
        didSet { defaults.set(section.rawValue, forKey: PreferenceKey.section) }
    }
    @Published var settingsCategory: SettingsCategory {
        didSet { defaults.set(settingsCategory.rawValue, forKey: PreferenceKey.settingsCategory) }
    }
    @Published var searchScope: WorkspaceSearchScope {
        didSet { defaults.set(searchScope.rawValue, forKey: PreferenceKey.searchScope) }
    }
    @Published var searchSort: WorkspaceSearchSort {
        didSet { defaults.set(searchSort.rawValue, forKey: PreferenceKey.searchSort) }
    }
    @Published var listFilter: WorkspaceListFilter {
        didSet { defaults.set(listFilter.rawValue, forKey: PreferenceKey.listFilter) }
    }
    @Published var isInspectorVisible: Bool {
        didSet { defaults.set(isInspectorVisible, forKey: PreferenceKey.inspectorVisible) }
    }
    @Published var isSidebarVisible: Bool {
        didSet { defaults.set(isSidebarVisible, forKey: PreferenceKey.sidebarVisible) }
    }
    /// Native column widths captured from the main window only. They contain
    /// no account, organization, or work-item identifiers.
    @Published private(set) var workspaceSidebarWidth: Double
    @Published private(set) var workspaceContentWidth: Double
    @Published private(set) var workspaceInspectorWidth: Double
    /// A practical, non-sensitive timeline disclosure preference for the main
    /// workspace window. Item-specific expansion would retain stale private
    /// work identifiers, so it is intentionally global to this window.
    @Published var isTimelineExpanded: Bool {
        didSet { defaults.set(isTimelineExpanded, forKey: PreferenceKey.timelineExpanded) }
    }

    private let defaults: UserDefaults
    private var selectedWorkItems: [WorkspaceSelectionScope: WorkItemID]
    private var selectionHistories = [WorkspaceSelectionScope: WorkspaceSelectionHistory]()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        section = defaults.string(forKey: PreferenceKey.section)
            .flatMap(AppSection.init(rawValue:)) ?? .inbox
        settingsCategory = defaults.string(forKey: PreferenceKey.settingsCategory)
            .flatMap(SettingsCategory.init(rawValue:)) ?? .general
        searchScope = defaults.string(forKey: PreferenceKey.searchScope)
            .flatMap(WorkspaceSearchScope.init(rawValue:)) ?? .currentView
        searchSort = defaults.string(forKey: PreferenceKey.searchSort)
            .flatMap(WorkspaceSearchSort.init(rawValue:)) ?? .relevance
        listFilter = defaults.string(forKey: PreferenceKey.listFilter)
            .flatMap(WorkspaceListFilter.init(rawValue:)) ?? .all
        isInspectorVisible = defaults.object(forKey: PreferenceKey.inspectorVisible) as? Bool ?? false
        isSidebarVisible = defaults.object(forKey: PreferenceKey.sidebarVisible) as? Bool ?? true
        workspaceSidebarWidth = Self.restoredWidth(
            from: defaults,
            key: PreferenceKey.sidebarWidth,
            defaultValue: WorkspaceSplitLayout.sidebarDefaultWidth,
            minimum: WorkspaceSplitLayout.sidebarMinimumWidth,
            maximum: WorkspaceSplitLayout.sidebarMaximumWidth
        )
        workspaceContentWidth = Self.restoredWidth(
            from: defaults,
            key: PreferenceKey.contentWidth,
            defaultValue: WorkspaceSplitLayout.contentDefaultWidth,
            minimum: WorkspaceSplitLayout.contentMinimumWidth,
            maximum: WorkspaceSplitLayout.contentMaximumWidth
        )
        workspaceInspectorWidth = Self.restoredWidth(
            from: defaults,
            key: PreferenceKey.inspectorWidth,
            defaultValue: WorkspaceSplitLayout.inspectorDefaultWidth,
            minimum: WorkspaceSplitLayout.inspectorMinimumWidth,
            maximum: WorkspaceSplitLayout.inspectorMaximumWidth
        )
        isTimelineExpanded = defaults.object(forKey: PreferenceKey.timelineExpanded) as? Bool ?? true
        selectedWorkItems = Self.decodeSelectedWorkItems(from: defaults)
    }

    func recordWorkspaceSidebarWidth(_ width: Double) {
        guard let width = Self.validatedWidth(
            width,
            minimum: WorkspaceSplitLayout.sidebarMinimumWidth,
            maximum: WorkspaceSplitLayout.sidebarMaximumWidth
        ), width != workspaceSidebarWidth
        else { return }
        workspaceSidebarWidth = width
        defaults.set(width, forKey: PreferenceKey.sidebarWidth)
    }

    func recordWorkspaceContentWidth(_ width: Double) {
        guard let width = Self.validatedWidth(
            width,
            minimum: WorkspaceSplitLayout.contentMinimumWidth,
            maximum: WorkspaceSplitLayout.contentMaximumWidth
        ), width != workspaceContentWidth
        else { return }
        workspaceContentWidth = width
        defaults.set(width, forKey: PreferenceKey.contentWidth)
    }

    func recordWorkspaceInspectorWidth(_ width: Double) {
        guard let width = Self.validatedWidth(
            width,
            minimum: WorkspaceSplitLayout.inspectorMinimumWidth,
            maximum: WorkspaceSplitLayout.inspectorMaximumWidth
        ), width != workspaceInspectorWidth
        else { return }
        workspaceInspectorWidth = width
        defaults.set(width, forKey: PreferenceKey.inspectorWidth)
    }

    func openSettings(_ category: SettingsCategory = .general) {
        settingsCategory = category
        section = .inbox
    }

    /// Stores the current work selection only for the supplied account and
    /// organization. Switching scope can therefore restore a different valid
    /// selection without exposing it in another organization's workspace.
    func setSelectedWorkItem(
        _ workItemID: WorkItemID?,
        accountID: AccountID,
        organizationID: OrganizationID
    ) {
        let scope = WorkspaceSelectionScope(accountID: accountID, organizationID: organizationID)
        let previousSelection = selectedWorkItems[scope]
        guard previousSelection != workItemID else { return }

        guard let workItemID else {
            selectedWorkItems[scope] = nil
            selectionHistories[scope] = nil
            persistSelectedWorkItems()
            return
        }

        if let previousSelection {
            var history = selectionHistories[scope] ?? WorkspaceSelectionHistory()
            history.appendBack(previousSelection)
            history.forward.removeAll()
            selectionHistories[scope] = history
        }
        selectedWorkItems[scope] = workItemID
        persistSelectedWorkItems()
    }

    /// Erases all presentation-only navigation state for a deleted account.
    /// This runs independently of workspace restoration so a later account
    /// cannot inherit selections or history from a removed opaque account ID.
    func purgeSelectionState(for accountID: AccountID) {
        let scopes = Set(selectedWorkItems.keys).union(selectionHistories.keys)
        purgeSelectionState(in: scopes.filter { $0.accountID == accountID })
    }

    /// Erases one deleted organization scope while preserving every other
    /// organization selection and its independent back/forward history.
    func purgeSelectionState(
        for accountID: AccountID,
        organizationID: OrganizationID
    ) {
        let scope = WorkspaceSelectionScope(accountID: accountID, organizationID: organizationID)
        purgeSelectionState(in: [scope])
    }

    /// Erases a deleted work item from exactly one workspace scope, including
    /// a current selection and every ephemeral back/forward history entry.
    func purgeSelectionState(
        for workItemID: WorkItemID,
        accountID: AccountID,
        organizationID: OrganizationID
    ) {
        let scope = WorkspaceSelectionScope(accountID: accountID, organizationID: organizationID)
        if selectedWorkItems[scope] == workItemID {
            selectedWorkItems[scope] = nil
        }
        if var history = selectionHistories[scope] {
            history.back.removeAll { $0 == workItemID }
            history.forward.removeAll { $0 == workItemID }
            selectionHistories[scope] = history
        }
        persistSelectedWorkItems()
    }

    func canNavigateSelectionBack(
        accountID: AccountID?,
        organizationID: OrganizationID?,
        validWorkItemIDs: Set<WorkItemID>
    ) -> Bool {
        guard let scope = selectionScope(accountID: accountID, organizationID: organizationID),
              selectedWorkItems[scope] != nil
        else {
            return false
        }
        return selectionHistories[scope]?.back.contains(where: validWorkItemIDs.contains) ?? false
    }

    func canNavigateSelectionForward(
        accountID: AccountID?,
        organizationID: OrganizationID?,
        validWorkItemIDs: Set<WorkItemID>
    ) -> Bool {
        guard let scope = selectionScope(accountID: accountID, organizationID: organizationID),
              selectedWorkItems[scope] != nil
        else {
            return false
        }
        return selectionHistories[scope]?.forward.contains(where: validWorkItemIDs.contains) ?? false
    }

    /// Moves within the active workspace scope only. Entries unavailable in
    /// the current cache are pruned before a target can be returned.
    func navigateSelectionBack(
        accountID: AccountID?,
        organizationID: OrganizationID?,
        validWorkItemIDs: Set<WorkItemID>
    ) -> WorkItemID? {
        navigateSelection(
            direction: .back,
            accountID: accountID,
            organizationID: organizationID,
            validWorkItemIDs: validWorkItemIDs
        )
    }

    func navigateSelectionForward(
        accountID: AccountID?,
        organizationID: OrganizationID?,
        validWorkItemIDs: Set<WorkItemID>
    ) -> WorkItemID? {
        navigateSelection(
            direction: .forward,
            accountID: accountID,
            organizationID: organizationID,
            validWorkItemIDs: validWorkItemIDs
        )
    }

    /// Returns the selection for exactly this scope. A stored selection that
    /// no longer exists is removed immediately so it cannot be resurrected on
    /// the next launch.
    func validatedSelectedWorkItem(
        accountID: AccountID,
        organizationID: OrganizationID,
        validWorkItemIDs: Set<WorkItemID>
    ) -> WorkItemID? {
        let scope = WorkspaceSelectionScope(accountID: accountID, organizationID: organizationID)
        pruneSelectionHistory(for: scope, validWorkItemIDs: validWorkItemIDs)
        guard let workItemID = selectedWorkItems[scope] else { return nil }
        guard validWorkItemIDs.contains(workItemID) else {
            selectedWorkItems[scope] = nil
            persistSelectedWorkItems()
            return nil
        }
        return workItemID
    }

    private enum SelectionHistoryDirection {
        case back
        case forward
    }

    private func navigateSelection(
        direction: SelectionHistoryDirection,
        accountID: AccountID?,
        organizationID: OrganizationID?,
        validWorkItemIDs: Set<WorkItemID>
    ) -> WorkItemID? {
        guard let scope = selectionScope(accountID: accountID, organizationID: organizationID),
              let currentSelection = selectedWorkItems[scope],
              validWorkItemIDs.contains(currentSelection)
        else {
            return nil
        }

        var history = selectionHistories[scope] ?? WorkspaceSelectionHistory()
        history.prune(using: validWorkItemIDs)
        let target: WorkItemID?
        switch direction {
        case .back:
            target = history.back.popLast()
            if let target {
                history.appendForward(currentSelection)
                selectedWorkItems[scope] = target
            }
        case .forward:
            target = history.forward.popLast()
            if let target {
                history.appendBack(currentSelection)
                selectedWorkItems[scope] = target
            }
        }
        selectionHistories[scope] = history
        if target != nil {
            persistSelectedWorkItems()
        }
        return target
    }

    private func selectionScope(
        accountID: AccountID?,
        organizationID: OrganizationID?
    ) -> WorkspaceSelectionScope? {
        guard let accountID, let organizationID else { return nil }
        return WorkspaceSelectionScope(accountID: accountID, organizationID: organizationID)
    }

    private func pruneSelectionHistory(
        for scope: WorkspaceSelectionScope,
        validWorkItemIDs: Set<WorkItemID>
    ) {
        guard var history = selectionHistories[scope] else { return }
        history.prune(using: validWorkItemIDs)
        selectionHistories[scope] = history
    }

    private static func decodeSelectedWorkItems(from defaults: UserDefaults) -> [WorkspaceSelectionScope: WorkItemID] {
        guard let data = defaults.data(forKey: PreferenceKey.selectedWorkItems),
              let storedSelections = try? JSONDecoder().decode([WorkspaceStoredSelection].self, from: data)
        else {
            return [:]
        }

        return Dictionary(
            storedSelections.map { ($0.scope, $0.workItemID) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    private func persistSelectedWorkItems() {
        let storedSelections = selectedWorkItems
            .map { WorkspaceStoredSelection(scope: $0.key, workItemID: $0.value) }
            .sorted {
                if $0.scope.accountID.rawValue != $1.scope.accountID.rawValue {
                    return $0.scope.accountID.rawValue < $1.scope.accountID.rawValue
                }
                return $0.scope.organizationID.rawValue < $1.scope.organizationID.rawValue
            }
        guard let data = try? JSONEncoder().encode(storedSelections) else { return }
        defaults.set(data, forKey: PreferenceKey.selectedWorkItems)
    }

    private func purgeSelectionState(in scopes: [WorkspaceSelectionScope]) {
        var didRemovePersistedSelection = false
        for scope in scopes {
            if selectedWorkItems.removeValue(forKey: scope) != nil {
                didRemovePersistedSelection = true
            }
            selectionHistories[scope] = nil
        }
        if didRemovePersistedSelection {
            persistSelectedWorkItems()
        }
    }

    private static func restoredWidth(
        from defaults: UserDefaults,
        key: String,
        defaultValue: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              let width = validatedWidth(number.doubleValue, minimum: minimum, maximum: maximum)
        else {
            defaults.removeObject(forKey: key)
            return defaultValue
        }
        return width
    }

    private static func validatedWidth(
        _ width: Double,
        minimum: Double,
        maximum: Double
    ) -> Double? {
        guard width.isFinite, width >= minimum, width <= maximum else { return nil }
        return width
    }
}
