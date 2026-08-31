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

private struct WorkspaceSelectionScope: Codable, Hashable {
    let accountID: AccountID
    let organizationID: OrganizationID
}

private struct WorkspaceStoredSelection: Codable, Equatable {
    let scope: WorkspaceSelectionScope
    let workItemID: WorkItemID
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

    private let defaults: UserDefaults
    private var selectedWorkItems: [WorkspaceSelectionScope: WorkItemID]

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
        selectedWorkItems = Self.decodeSelectedWorkItems(from: defaults)
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
        selectedWorkItems[scope] = workItemID
        persistSelectedWorkItems()
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
        guard let workItemID = selectedWorkItems[scope] else { return nil }
        guard validWorkItemIDs.contains(workItemID) else {
            selectedWorkItems[scope] = nil
            persistSelectedWorkItems()
            return nil
        }
        return workItemID
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
}
