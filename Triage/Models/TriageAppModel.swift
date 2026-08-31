import AppKit
import Foundation

struct OrganizationAISettingsState: Equatable {
    let consent: OrganizationAIConsent
    let isEffectivelyAvailable: Bool
    let status: String
    let availableModels: [CopilotModel]
    let modelSelectionNotice: String?

    init(
        consent: OrganizationAIConsent,
        isEffectivelyAvailable: Bool,
        status: String,
        availableModels: [CopilotModel] = [],
        modelSelectionNotice: String? = nil
    ) {
        self.consent = consent
        self.isEffectivelyAvailable = isEffectivelyAvailable
        self.status = status
        self.availableModels = availableModels
        self.modelSelectionNotice = modelSelectionNotice
    }

    var selectedModelTitle: String {
        guard let selectedModelID = consent.selectedModelID else { return "Auto" }
        guard !availableModels.isEmpty else { return selectedModelID }
        return availableModels.first(where: { $0.id == selectedModelID })?.displayName ?? "Auto"
    }

    var automaticActionConfidenceTitle: String {
        "\(Int((consent.automaticActionConfidenceThreshold * 100).rounded()))% minimum"
    }
}

/// Serializes workspace activation. Replacement cancels the predecessor and
/// waits for it to quiesce before beginning the next vault/read path, so an
/// A→B→A interaction cannot let the first A publish after the final A wins.
@MainActor
final class WorkspaceActivationTaskController {
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    func replace(
        _ operation: @escaping @MainActor @Sendable (UInt64) async -> Void
    ) {
        generation &+= 1
        let currentGeneration = generation
        let previousTask = task
        previousTask?.cancel()
        task = Task { [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled,
                  self?.generation == currentGeneration
            else { return }
            await operation(currentGeneration)
        }
    }

    func cancelAndWait() async {
        generation &+= 1
        let previousTask = task
        task = nil
        previousTask?.cancel()
        if let previousTask {
            await previousTask.value
        }
    }

    /// Invalidates immediately for synchronous state changes. The retained
    /// task is still awaited by the next replacement or lifecycle shutdown.
    func cancel() {
        generation &+= 1
        task?.cancel()
    }

    func waitForCurrentTask() async {
        if let task {
            await task.value
        }
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        generation == candidate && !Task.isCancelled
    }
}

@MainActor
final class TriageAppModel: ObservableObject, WorkspacePresentationAdapting, NotificationLocalRouteHandling {
    private enum ForegroundRefreshResult: Equatable, Sendable {
        case completed
        case accessAvailable
    }

    var selectedAccountCapabilities: AccountCapabilitySnapshot? {
        guard let selectedAccountID else { return nil }
        return accountCapabilitiesByAccount[selectedAccountID]
    }

    private enum PreferenceKey {
        static let selectedAccountID = "workspace.selected-account-id"
        static let selectedOrganizationID = "workspace.selected-organization-id"
    }

    @Published private(set) var accounts: [GitHubAccount] = []
    /// Opaque local account identities whose vault key is unavailable. They
    /// cannot be selected or refreshed, but remain removable from Settings.
    @Published private(set) var unavailableAccountIDs: Set<AccountID> = []
    /// Vault-repair candidates retain a valid encryption key and are never
    /// eligible for the unavailable-key deletion path.
    @Published private(set) var vaultRecoveryIssues: [AccountVaultRecoveryIssue] = []
    @Published private(set) var organizationsByAccount: [AccountID: [GitHubOrganization]] = [:]
    @Published private(set) var organizationAccessesByAccount: [AccountID: [OrganizationID: OrganizationAccess]] = [:]
    @Published private(set) var accountCapabilitiesByAccount: [AccountID: AccountCapabilitySnapshot] = [:]
    @Published private(set) var workItems: [WorkItem] = []
    /// The revision-fenced, persisted-rank first Inbox page. This is optional
    /// while a cached workspace is restoring; callers then retain the complete
    /// local graph instead of showing an empty Inbox.
    @Published private(set) var inboxPage: [WorkItem]?
    @Published private(set) var inboxPageHasMore = false
    @Published private(set) var inboxPageEvaluatedAt: Date?
    @Published private(set) var isLoadingMoreInboxPage = false
    @Published var selectedAccountID: AccountID? {
        didSet { defaults.set(selectedAccountID?.rawValue, forKey: PreferenceKey.selectedAccountID) }
    }
    @Published var selectedOrganizationID: OrganizationID? {
        didSet { defaults.set(selectedOrganizationID?.rawValue, forKey: PreferenceKey.selectedOrganizationID) }
    }
    @Published var selectedWorkItemID: WorkItemID?
    @Published private(set) var selectedWorkItemIDs = Set<WorkItemID>()
    @Published private(set) var connectionError: String?
    @Published private(set) var credentialActionNotice: String?
    @Published private(set) var refreshError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isConnecting = false
    /// Serializes explicit encrypted-account restoration so recovery controls
    /// can remain visible and accurately disabled while storage is in use.
    @Published private(set) var isRestoringAccounts = false
    @Published private(set) var restorationError: String?
    /// Scoped to the currently selected workspace. Account-session recovery
    /// notices remain in `restorationError` and must not make a later,
    /// successfully loaded organization appear unavailable.
    @Published private(set) var workspaceRestorationError: String?
    @Published private(set) var ssoAuthorizationHeader: GitHubSSOHeader?
    @Published private(set) var selectedOrganizationFreshness: FreshnessState?
    @Published private(set) var selectedWorkspaceCoverage: CoverageEvaluation?
    /// Account-scoped `/user/orgs` completeness is separate from a selected
    /// workspace's repository coverage. It stays visible when a daily
    /// inventory attempt fails but cached organization rows are retained.
    @Published private(set) var organizationVisibilityFreshnessByAccount: [AccountID: FreshnessState] = [:]
    @Published private(set) var organizationAISettingsByAccount: [AccountID: [OrganizationID: OrganizationAISettingsState]] = [:]
    @Published private(set) var selectedCopilotAuthorizationState: CopilotAccountAuthorizationState = .unavailable
    @Published private(set) var copilotAuthenticationError: String?
    @Published private(set) var copilotRuntimeOperationError: String?
    /// A user-requested runtime operation is active. The companion published
    /// authorization state carries its real downloading/verifying progress.
    @Published private(set) var isCopilotRuntimeOperationInProgress = false
    /// Account-local deletion remains fenced until the complete removal task
    /// finishes. Settings observes this state to prevent a second confirmation
    /// from starting another destructive operation for the same account.
    @Published private(set) var accountsBeingRemoved: Set<AccountID> = []

    private let oauthAuthorizer = GitHubOAuthAuthorizer()
    private let refreshScheduler = ActiveRefreshScheduler()
    private let inactiveRefreshScheduler = ActiveRefreshScheduler()
    private let capabilityRefreshScheduler = ActiveRefreshScheduler()
    private let defaults: UserDefaults
    private let dependencies: TriageApplicationDependencies
    private let vaultRegistry: VaultRegistry
    private let workspaceAccessibility: WorkspaceAccessibilityCoordinator?
    /// This is set only by the DEBUG-gated UI fixture composition. It keeps
    /// fixture navigation entirely in memory instead of touching Keychain,
    /// a production vault, or any GitHub transport.
    private let usesInMemoryUITestFixture: Bool
    private var refreshGeneration = 0
    private var backgroundRefreshGeneration: UInt64 = 0
    private var foregroundRefreshTask: Task<ForegroundRefreshResult, Never>?
    private var foregroundRefreshTaskID: UUID?
    private var foregroundRefreshTasksAwaitingCredentialMutation: [Task<ForegroundRefreshResult, Never>] = []
    private var foregroundRefreshTasksAwaitingAccountRemoval: [AccountID: [Task<ForegroundRefreshResult, Never>]] = [:]
    private var isCredentialMutationInProgress = false
    private var isShuttingDown = false
    /// Read once from the persisted General preference during construction.
    /// Manual mode suppresses lifecycle and cadence-triggered refreshes while
    /// leaving every user-invoked Refresh path available.
    private let automaticRefreshEnabled: Bool
    private var cachedWorkItems = WorkspacePresentationCache<[WorkItem]>()
    private var cachedInboxPages = WorkspacePresentationCache<[WorkItem]>()
    private var cachedInboxPageSnapshots = WorkspacePresentationCache<InboxPagePresentationSnapshot>()
    /// The most recently installed revision-qualified scope for each cached
    /// workspace. This remains independent from the live observation scope:
    /// selection invalidates the latter before showing cached content, while
    /// this map keeps the cache lookup bound to its original authority.
    private var cachedWorkspaceScopes: [AccountID: [OrganizationID: SynchronizationScope]] = [:]
    private let workspaceActivation = WorkspaceActivationTaskController()
    private var workspaceObservationTask: Task<Void, Never>?
    /// A replacement waits for this cancelled predecessor before it opens its
    /// own complete-graph stream, so vault shutdown and scope switches do not
    /// leave an old graph reader behind.
    private var workspaceObservationPredecessor: Task<Void, Never>?
    /// Records the scope whose expensive complete graph has been started. The
    /// first bounded Inbox page is the admission gate for this observer.
    private var workspaceFullGraphObservationScope: SynchronizationScope?
    private var inboxPageObservationTask: Task<Void, Never>?
    private var inboxPageTimeRefreshTask: Task<Void, Never>?
    private var inboxPageSnapshot: InboxPagePresentationSnapshot?
    private var workspaceSelectionGeneration: UInt64 = 0
    private var workspaceObservationScope: SynchronizationScope?
    private var copilotRuntimeStateObservationTask: Task<Void, Never>?
    /// The model, rather than a transient Settings view, owns the explicit
    /// runtime operation so its cancel action survives Settings recreation.
    private var copilotRuntimeOperationTask: Task<Void, Never>?

    var hasConnectedAccount: Bool { !accounts.isEmpty }
    var organizations: [GitHubOrganization] {
        guard let selectedAccountID else { return [] }
        return organizationsByAccount[selectedAccountID] ?? []
    }

    var selectedOrganization: GitHubOrganization? {
        organizations.first { $0.id == selectedOrganizationID }
    }

    var selectedOrganizationAccess: OrganizationAccess? {
        guard let selectedAccountID, let selectedOrganizationID else { return nil }
        return organizationAccessesByAccount[selectedAccountID]?[selectedOrganizationID]
    }

    var selectedOrganizationVisibilityFreshness: FreshnessState? {
        guard let selectedAccountID else { return nil }
        return organizationVisibilityFreshnessByAccount[selectedAccountID]
    }

    var selectedOrganizationAISettings: OrganizationAISettingsState? {
        guard let selectedAccountID, let selectedOrganizationID else { return nil }
        return organizationAISettingsByAccount[selectedAccountID]?[selectedOrganizationID]
    }

    init(
        dependencies: TriageApplicationDependencies,
        vaultRegistry: VaultRegistry,
        defaults: UserDefaults = .standard,
        workspaceAccessibility: WorkspaceAccessibilityCoordinator? = nil,
        usesInMemoryUITestFixture: Bool = false,
        automaticRefreshEnabled: Bool = true
    ) {
        self.dependencies = dependencies
        self.vaultRegistry = vaultRegistry
        self.defaults = defaults
        self.workspaceAccessibility = workspaceAccessibility
        self.usesInMemoryUITestFixture = usesInMemoryUITestFixture
        self.automaticRefreshEnabled = automaticRefreshEnabled
        selectedAccountID = defaults.string(forKey: PreferenceKey.selectedAccountID)
            .flatMap(AccountID.init(rawValue:))
        selectedOrganizationID = defaults.string(forKey: PreferenceKey.selectedOrganizationID)
            .flatMap(OrganizationID.init(rawValue:))
    }

    func install(
        accounts: [GitHubAccount],
        organizations: [GitHubOrganization],
        organizationAccesses: [OrganizationID: OrganizationAccess],
        accountCapabilities: AccountCapabilitySnapshot? = nil,
        for accountID: AccountID
    ) {
        self.accounts = accounts
        organizationsByAccount[accountID] = organizations
        organizationAccessesByAccount[accountID] = organizationAccesses
        if let accountCapabilities {
            accountCapabilitiesByAccount[accountID] = accountCapabilities
        }
        selectedAccountID = accountID
        selectedOrganizationID = organizations.first?.id
    }

    private func install(
        session: AccountSessionSnapshot,
        requiringActiveAccountID: AccountID? = nil
    ) async {
        await cancelForegroundRefresh()
        await workspaceActivation.cancelAndWait()
        await cancelWorkspaceObservationAndWait()
        guard !isShuttingDown,
              requiringActiveAccountID.map({ accountID in
                  accounts.contains(where: { $0.id == accountID })
                      && !accountsBeingRemoved.contains(accountID)
              }) ?? true
        else {
            return
        }
        cachedWorkItems = WorkspacePresentationCache()
        cachedInboxPages = WorkspacePresentationCache()
        cachedInboxPageSnapshots = WorkspacePresentationCache()
        cachedWorkspaceScopes = [:]
        workspaceRestorationError = nil
        accounts = session.accounts
        unavailableAccountIDs = session.unavailableAccountIDs
        vaultRecoveryIssues = session.vaultRecoveryIssues
        organizationsByAccount = session.organizationsByAccount
        organizationAccessesByAccount = session.organizationAccessesByAccount
        accountCapabilitiesByAccount = session.accountCapabilitiesByAccount
        organizationVisibilityFreshnessByAccount = [:]
        organizationAISettingsByAccount = [:]
        credentialActionNotice = session.credentialActionNotice
        if session.unavailableAccountIDs.isEmpty, session.vaultRecoveryIssues.isEmpty {
            restorationError = nil
        }
        if !accounts.contains(where: { $0.id == selectedAccountID }) {
            selectedAccountID = accounts.first?.id
        }
        if !organizations.contains(where: { $0.id == selectedOrganizationID }) {
            selectedOrganizationID = organizations.first?.id
        }
    }

    func install(
        workItems: [WorkItem],
        scope: SynchronizationScope
    ) {
        let insertedActionItemCount = Self.insertedActionItemCount(
            in: workItems,
            comparedWith: cachedWorkItems[scope] ?? []
        )
        cachedWorkItems[scope] = workItems
        cachedWorkspaceScopes[scope.accountID, default: [:]][scope.organizationID] = scope
        let isSelectedWorkspace = selectedAccountID == scope.accountID
            && selectedOrganizationID == scope.organizationID
        if isSelectedWorkspace {
            workspaceRestorationError = nil
            workspaceAccessibility?.actionItemsInserted(count: insertedActionItemCount)
        }
        present(workItems: workItems)
    }

    private func present(workItems: [WorkItem]) {
        self.workItems = workItems
        workspaceAccessibility?.workspaceContentAvailabilityChanged(
            hasCachedWork: !workItems.isEmpty
        )
        if !workItems.contains(where: { $0.id == selectedWorkItemID }) {
            selectedWorkItemID = workItems.first?.id
        }

    }

    private func replaceWorkspaceObservation(
        for scope: SynchronizationScope
    ) {
        workspaceSelectionGeneration &+= 1
        if let task = workspaceObservationTask {
            task.cancel()
            workspaceObservationTask = nil
            workspaceObservationPredecessor = task
        }
        workspaceFullGraphObservationScope = nil
        workspaceObservationScope = scope
        // The bounded projection is the admission gate for the independent
        // full graph. A 10k-item decode must not even contend for the vault
        // before the Inbox has one interactive persisted-rank page.
        replaceInboxPageObservation(for: scope)
    }

    private func startWorkspaceObservationAfterFirstInboxPage(
        for scope: SynchronizationScope
    ) {
        guard inboxPageSnapshot?.scope == scope,
              workspaceObservationScope == scope,
              workspaceFullGraphObservationScope != scope
        else { return }
        workspaceFullGraphObservationScope = scope
        let generation = workspaceSelectionGeneration
        let predecessor = workspaceObservationPredecessor
        workspaceObservationPredecessor = nil
        workspaceObservationTask = Task { [weak self, dependencies] in
            if let predecessor {
                await predecessor.value
            }
            guard !Task.isCancelled else { return }
            do {
                let snapshots = try await dependencies.workspaceObserver.snapshots(for: scope)
                for try await snapshot in snapshots {
                    guard !Task.isCancelled else { return }
                    self?.install(snapshot, for: generation)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.present(
                    error,
                    for: scope,
                    selectionGeneration: generation
                )
            }
        }
    }

    private func replaceInboxPageObservation(for scope: SynchronizationScope) {
        inboxPageObservationTask?.cancel()
        inboxPageSnapshot = nil
        inboxPageObservationTask = Task { [weak self, dependencies] in
            do {
                let snapshots = try await dependencies.inboxPageObserver.snapshots(for: scope)
                for try await snapshot in snapshots {
                    guard !Task.isCancelled else { return }
                    self?.installInboxPage(snapshot)
                }
            } catch is CancellationError {
                return
            } catch {
                // A full cached graph remains usable if the bounded page read
                // fails. Do not turn a local cache problem into an empty Inbox.
                return
            }
        }
    }

    private func installInboxPage(_ snapshot: InboxPagePresentationSnapshot) {
        guard workspaceObservationScope == snapshot.scope,
              selectedAccountID == snapshot.scope.accountID,
              selectedOrganizationID == snapshot.scope.organizationID
        else { return }
        inboxPageSnapshot = snapshot
        inboxPage = snapshot.items
        inboxPageHasMore = snapshot.hasMore
        inboxPageEvaluatedAt = snapshot.evaluatedAt
        cachedInboxPages[snapshot.scope] = snapshot.items
        cachedInboxPageSnapshots[snapshot.scope] = snapshot
        scheduleInboxPageTimeRefresh(for: snapshot)
        repairSelectionAfterInboxPublication(
            page: snapshot.items,
            fullGraph: workItems,
            evaluatedAt: snapshot.evaluatedAt
        )
        if selectedWorkItem == nil {
            selectedWorkItemID = snapshot.items.first?.id
        }
        startWorkspaceObservationAfterFirstInboxPage(for: snapshot.scope)
    }

    private func scheduleInboxPageTimeRefresh(for snapshot: InboxPagePresentationSnapshot) {
        inboxPageTimeRefreshTask?.cancel()
        let deadline = Self.inboxPageRefreshDeadline(
            evaluatedAt: snapshot.evaluatedAt,
            workItems: workItems
        )
        // A first page can arrive before the independent full graph, so no
        // local boundary may be known yet. Reopen the lightweight observation
        // periodically in that case rather than re-evaluating its rows with a
        // fresh Date and creating a hole at a snooze boundary.
        let delay = max(0, deadline.timeIntervalSinceNow)
        inboxPageTimeRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled,
                      let self,
                      self.workspaceObservationScope == snapshot.scope,
                      self.inboxPageSnapshot == snapshot
                else { return }
                self.replaceInboxPageObservation(for: snapshot.scope)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    nonisolated static func inboxPageRefreshDeadline(
        evaluatedAt: Date,
        workItems: [WorkItem]
    ) -> Date {
        let nextKnownBoundary = workItems
            .flatMap { [$0.workflow.snoozedUntil, $0.workflow.followUpAt] }
            .compactMap { $0 }
            .filter { $0 > evaluatedAt }
            .min()
        return nextKnownBoundary ?? evaluatedAt.addingTimeInterval(30)
    }

    func loadMoreInboxPage() async {
        guard !isLoadingMoreInboxPage,
              let snapshot = inboxPageSnapshot,
              snapshot.hasMore,
              workspaceObservationScope == snapshot.scope
        else { return }
        isLoadingMoreInboxPage = true
        defer { isLoadingMoreInboxPage = false }
        do {
            let next = try await dependencies.inboxPageObserver.loadNextPage(for: snapshot)
            guard workspaceObservationScope == snapshot.scope,
                  inboxPageSnapshot == snapshot
            else { return }
            let merged = Self.mergeInboxPages(inboxPage ?? [], next.items)
            let updated = InboxPagePresentationSnapshot(
                scope: snapshot.scope,
                items: merged,
                nextCursor: next.nextCursor,
                hasMore: next.hasMore,
                evaluatedAt: snapshot.evaluatedAt,
                freshness: snapshot.freshness,
                revision: snapshot.revision
            )
            inboxPageSnapshot = updated
            inboxPage = merged
            inboxPageHasMore = next.hasMore
            inboxPageEvaluatedAt = snapshot.evaluatedAt
            cachedInboxPages[snapshot.scope] = merged
            cachedInboxPageSnapshots[snapshot.scope] = updated
        } catch is CancellationError {
            return
        } catch {
            refreshError = "Triage could not load more cached Inbox work."
        }
    }

    private static func mergeInboxPages(_ current: [WorkItem], _ next: [WorkItem]) -> [WorkItem] {
        var known = Set(current.map(\.id))
        return current + next.filter { known.insert($0.id).inserted }
    }

    private func invalidateWorkspaceObservation() {
        workspaceSelectionGeneration &+= 1
        workspaceObservationTask?.cancel()
        workspaceObservationTask = nil
        workspaceObservationPredecessor?.cancel()
        workspaceObservationPredecessor = nil
        workspaceFullGraphObservationScope = nil
        inboxPageObservationTask?.cancel()
        inboxPageObservationTask = nil
        inboxPageTimeRefreshTask?.cancel()
        inboxPageTimeRefreshTask = nil
        inboxPageSnapshot = nil
        inboxPage = nil
        inboxPageHasMore = false
        inboxPageEvaluatedAt = nil
        workspaceObservationScope = nil
        selectedWorkspaceCoverage = nil
    }

    private func cancelWorkspaceObservationAndWait() async {
        workspaceSelectionGeneration &+= 1
        let tasks = [workspaceObservationTask, workspaceObservationPredecessor].compactMap { $0 }
        workspaceObservationTask = nil
        workspaceObservationPredecessor = nil
        workspaceFullGraphObservationScope = nil
        inboxPageObservationTask?.cancel()
        inboxPageObservationTask = nil
        inboxPageTimeRefreshTask?.cancel()
        inboxPageTimeRefreshTask = nil
        inboxPageSnapshot = nil
        inboxPage = nil
        inboxPageHasMore = false
        inboxPageEvaluatedAt = nil
        workspaceObservationScope = nil
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
        selectedWorkspaceCoverage = nil
    }

    func install(
        _ snapshot: WorkspacePresentationSnapshot,
        for selectionGeneration: UInt64
    ) {
        let scope = snapshot.scope
        guard workspaceSelectionGeneration == selectionGeneration,
              workspaceObservationScope == scope,
              selectedAccountID == scope.accountID,
              selectedOrganizationID == scope.organizationID
        else { return }
        let insertedActionItemCount = Self.insertedActionItemCount(
            in: snapshot.workItems,
            comparedWith: cachedWorkItems[scope] ?? []
        )
        cachedWorkItems[scope] = snapshot.workItems
        cachedWorkspaceScopes[scope.accountID, default: [:]][scope.organizationID] = scope
        selectedOrganizationFreshness = snapshot.durableState.freshness
        selectedWorkspaceCoverage = snapshot.coverageEvaluation
        workspaceAccessibility?.actionItemsInserted(count: insertedActionItemCount)
        present(workItems: snapshot.workItems)
        if let inboxPageSnapshot, inboxPageSnapshot.scope == scope {
            // The first page is intentionally allowed to arrive before this
            // full graph. Re-arm its lightweight observation once the graph
            // supplies exact local snooze/follow-up boundaries.
            scheduleInboxPageTimeRefresh(for: inboxPageSnapshot)
            repairSelectionAfterInboxPublication(
                page: inboxPageSnapshot.items,
                fullGraph: snapshot.workItems,
                evaluatedAt: inboxPageSnapshot.evaluatedAt
            )
        }
    }

    private static func insertedActionItemCount(
        in workItems: [WorkItem],
        comparedWith previousWorkItems: [WorkItem]
    ) -> Int {
        let existingActionItemIDs = Set(previousWorkItems.flatMap { item in
            item.openActionItems.map(\.id)
        })
        let updatedActionItemIDs = Set(workItems.flatMap { item in
            item.openActionItems.map(\.id)
        })
        return updatedActionItemIDs.subtracting(existingActionItemIDs).count
    }

    func present(
        _: any Error,
        for scope: SynchronizationScope,
        selectionGeneration: UInt64
    ) {
        guard workspaceSelectionGeneration == selectionGeneration,
              workspaceObservationScope == scope,
              selectedAccountID == scope.accountID,
              selectedOrganizationID == scope.organizationID
        else { return }
        refreshError = "Triage could not update this workspace. Cached work remains available."
    }

    func searchCachedWork(_ query: String) async throws -> [SearchResult] {
        guard !isShuttingDown else { throw CancellationError() }
        guard !usesInMemoryUITestFixture else {
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !normalizedQuery.isEmpty else { return [] }
            return workItems.enumerated().compactMap { index, workItem in
                let searchableText = [
                    workItem.title,
                    workItem.repository?.fullName ?? "",
                    workItem.workflow.localNote ?? "",
                    workItem.actionItems.map(\.title).joined(separator: " ")
                ].joined(separator: " ")
                let normalizedText = searchableText.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                guard normalizedText.contains(normalizedQuery) else { return nil }
                return SearchResult(
                    documentID: Int64(index + 1),
                    workItemID: workItem.id,
                    nodeID: workItem.primaryNodeID,
                    rank: Double(index)
                )
            }
        }
        guard let account = accounts.first(where: { $0.id == selectedAccountID }),
              let organization = selectedOrganization
        else {
            return []
        }
        guard !accountsBeingRemoved.contains(account.id) else {
            throw CancellationError()
        }
        let secretStore = KeychainSecretStore()
        guard let vaultKey = try await secretStore.readVaultKey(for: account.id) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        guard !isShuttingDown, !accountsBeingRemoved.contains(account.id) else {
            throw CancellationError()
        }
        let vault = try await requiredVaultRegistry().open(accountID: account.id, vaultKey: vaultKey)
        let results = try await SearchRepository(vault: vault).search(
            query,
            accountID: account.id,
            organizationID: organization.id
        )
        guard !isShuttingDown, !accountsBeingRemoved.contains(account.id) else {
            throw CancellationError()
        }
        return results
    }

    func selectAccount(_ accountID: AccountID, activatesOrganization: Bool = true) {
        guard accounts.contains(where: { $0.id == accountID }) else { return }
        invalidateBackgroundRefreshScheduling()
        if activatesOrganization {
            invalidateRefreshState()
        } else {
            pauseForegroundRefreshForCredentialMutation()
            workspaceActivation.cancel()
        }
        invalidateWorkspaceObservation()
        workspaceRestorationError = nil
        selectedAccountID = accountID
        selectedOrganizationID = organizationsByAccount[accountID]?.first?.id
        presentCachedWorkItems()
        if activatesOrganization {
            activateSelectedOrganization()
        }
    }

    func selectOrganization(_ organizationID: OrganizationID) {
        guard organizations.contains(where: { $0.id == organizationID }) else { return }
        invalidateBackgroundRefreshScheduling()
        invalidateRefreshState()
        invalidateWorkspaceObservation()
        workspaceRestorationError = nil
        selectedOrganizationID = organizationID
        presentCachedWorkItems()
        activateSelectedOrganization()
    }

    func removeAccount(_ accountID: AccountID) async throws {
        guard accounts.contains(where: { $0.id == accountID })
                || unavailableAccountIDs.contains(accountID),
              !accountsBeingRemoved.contains(accountID)
        else { return }

        let isRemovingSelectedAccount = selectedAccountID == accountID
        accountsBeingRemoved.insert(accountID)
        defer { accountsBeingRemoved.remove(accountID) }
        invalidateBackgroundRefreshScheduling()
        if isRemovingSelectedAccount {
            await workspaceActivation.cancelAndWait()
            await cancelWorkspaceObservationAndWait()
            await cancelForegroundRefresh()
        }
        await cancelForegroundRefreshes(for: accountID)
        try await cancelInactiveRefreshes(for: accountID)
        // Account-session removal closes and deletes the encrypted vault. Drop
        // any notification delivery ledger reference first so a later account
        // reusing this opaque ID cannot retain a closed vault handle.
        await dependencies.workspaceObservationLifecycle.evictAccount(accountID)
        await dependencies.purgeAccountNotificationPreferences(accountID)
        await dependencies.copilotRuntimeAuthorization.disconnect(accountID: accountID)
        try await dependencies.accountSession.removeAccount(accountID)

        dependencies.purgeAccountNavigationState(accountID)
        accounts.removeAll { $0.id == accountID }
        unavailableAccountIDs.remove(accountID)
        vaultRecoveryIssues.removeAll { $0.accountID == accountID }
        if unavailableAccountIDs.isEmpty, vaultRecoveryIssues.isEmpty {
            restorationError = nil
        }
        workspaceRestorationError = nil
        organizationsByAccount[accountID] = nil
        organizationAccessesByAccount[accountID] = nil
        accountCapabilitiesByAccount[accountID] = nil
        organizationVisibilityFreshnessByAccount[accountID] = nil
        organizationAISettingsByAccount[accountID] = nil
        cachedWorkItems.removeAll(for: accountID)
        cachedInboxPages.removeAll(for: accountID)
        cachedInboxPageSnapshots.removeAll(for: accountID)
        cachedWorkspaceScopes[accountID] = nil
        if isRemovingSelectedAccount {
            selectedAccountID = accounts.first?.id
            selectedOrganizationID = selectedAccountID
                .flatMap { organizationsByAccount[$0]?.first?.id }
            presentCachedWorkItems()
            activateSelectedOrganization()
        }
    }

    func isRemovingAccount(_ accountID: AccountID) -> Bool {
        accountsBeingRemoved.contains(accountID)
    }

    /// The Inbox page is an authoritative, complete graph for its bounded
    /// roots. Resolve selection from it while the independent complete graph
    /// is still loading, then prefer the latter's richer copy once available.
    var selectedWorkItem: WorkItem? {
        selectionWorkItems.first { $0.id == selectedWorkItemID }
    }

    func setSelectedWorkItemIDs(_ ids: Set<WorkItemID>) {
        selectedWorkItemIDs = ids.intersection(selectableWorkItemIDs)
    }

    var selectedWorkItems: [WorkItem] {
        selectionWorkItems.filter { selectedWorkItemIDs.contains($0.id) }
    }

    var selectableWorkItemIDs: Set<WorkItemID> {
        Set(selectionWorkItems.map(\.id))
    }

    private var selectionWorkItems: [WorkItem] {
        Self.selectionWorkItems(inboxPage: inboxPage, fullGraph: workItems)
    }

    private func repairSelectionAfterInboxPublication(
        page: [WorkItem],
        fullGraph: [WorkItem],
        evaluatedAt: Date
    ) {
        let repair = Self.repairedInboxSelection(
            selectedWorkItemID: selectedWorkItemID,
            selectedWorkItemIDs: selectedWorkItemIDs,
            inboxPage: page,
            fullGraph: fullGraph,
            evaluatedAt: evaluatedAt
        )
        guard repair.primaryWorkItemID != selectedWorkItemID
                || repair.selectedWorkItemIDs != selectedWorkItemIDs
        else { return }
        selectedWorkItemID = repair.primaryWorkItemID
        selectedWorkItemIDs = repair.selectedWorkItemIDs
    }

    nonisolated static func selectionWorkItems(
        inboxPage: [WorkItem]?,
        fullGraph: [WorkItem]
    ) -> [WorkItem] {
        let fullGraphByID = Dictionary(uniqueKeysWithValues: fullGraph.map { ($0.id, $0) })
        let page = inboxPage ?? []
        let pageIDs = Set(page.map(\.id))
        return page.map { fullGraphByID[$0.id] ?? $0 }
            + fullGraph.filter { !pageIDs.contains($0.id) }
    }

    struct InboxSelectionRepair: Equatable, Sendable {
        let primaryWorkItemID: WorkItemID?
        let selectedWorkItemIDs: Set<WorkItemID>
    }

    /// Repairs only a selection which the current full graph proves has left
    /// Inbox and which is absent from the authoritative current page. An Inbox
    /// item beyond the loaded page remains selected, preserving restored and
    /// multi-selection semantics while pagination catches up.
    nonisolated static func repairedInboxSelection(
        selectedWorkItemID: WorkItemID?,
        selectedWorkItemIDs: Set<WorkItemID>,
        inboxPage: [WorkItem],
        fullGraph: [WorkItem],
        evaluatedAt: Date
    ) -> InboxSelectionRepair {
        guard let selectedWorkItemID,
              !inboxPage.contains(where: { $0.id == selectedWorkItemID }),
              let selected = fullGraph.first(where: { $0.id == selectedWorkItemID }),
              InboxEligibilityRule().disposition(for: selected, at: evaluatedAt) != .inbox
        else {
            return .init(
                primaryWorkItemID: selectedWorkItemID,
                selectedWorkItemIDs: selectedWorkItemIDs
            )
        }

        var repairedIDs = selectedWorkItemIDs
        repairedIDs.remove(selectedWorkItemID)
        let replacement = inboxPage.first(where: { repairedIDs.contains($0.id) })?.id
            ?? inboxPage.first?.id
        if let replacement {
            repairedIDs.insert(replacement)
        }
        return .init(primaryWorkItemID: replacement, selectedWorkItemIDs: repairedIDs)
    }

    func connectGitHub(presentationAnchor: NSWindow) async {
        guard !usesInMemoryUITestFixture else {
            connectionError = "GitHub sign-in is unavailable in the local UI fixture."
            return
        }
        connectionError = nil
        isConnecting = true
        defer { isConnecting = false }
        do {
            let configuration = try RuntimeOAuthConfiguration()
            let request = try await oauthAuthorizer.authorize(
                configuration: configuration.oauth,
                presentationAnchor: presentationAnchor
            )
            let snapshot = try await dependencies.accountSession.connectOAuth(request)
            await install(session: snapshot)
            await recheckSelectedOrganizationAccess()
        } catch let error as RuntimeOAuthConfigurationError {
            switch error {
            case .missingClientID:
                connectionError = "GitHub sign-in is not configured in this build."
            case .invalidBrokerURL:
                connectionError = "The GitHub sign-in service is not configured securely."
            case .invalidApplicationVersion:
                connectionError = "GitHub sign-in is not configured in this build."
            }
        } catch is CancellationError {
            return
        } catch let error as GitHubOAuthError {
            switch error {
            case .authorizationTimedOut:
                connectionError = "GitHub sign-in timed out. Try again to continue."
            default:
                connectionError = "GitHub sign-in could not be completed. Try again."
            }
        } catch {
            connectionError = Self.oauthFailureMessage(
                for: error,
                fallback: "GitHub sign-in could not be completed. Try again."
            )
        }
    }

    func connectPersonalAccessToken(
        _ rawValue: String,
        resourceOwnerOrganization: String?
    ) async {
        // This is the authority boundary for both onboarding and Settings Add
        // Account. The sheet can receive two input events before SwiftUI has
        // rendered its disabled state; admit only one credential connection.
        guard !isConnecting else { return }
        connectionError = nil
        isConnecting = true
        defer { isConnecting = false }
        do {
            let token = try PersonalAccessToken(rawValue: rawValue)
            let snapshot = try await dependencies.accountSession.connectPersonalAccessToken(
                token,
                resourceOwnerOrganization: resourceOwnerOrganization
            )
            await install(session: snapshot)
            await recheckSelectedOrganizationAccess()
        } catch is PersonalAccessTokenError {
            connectionError = "Enter a supported fine-grained or classic GitHub personal access token."
        } catch let error as AccountConnectionError {
            switch error {
            case .missingFineGrainedResourceOwnerOrganization:
                connectionError = error.recoveryDescription
            case .invalidGitHubIdentity, .missingOAuthBroker:
                connectionError = "Triage could not validate this personal access token. Check its access and try again."
            }
        } catch {
            connectionError = "Triage could not validate this personal access token. Check its access and try again."
        }
    }

    func reconnectGitHub(
        account: GitHubAccount,
        presentationAnchor: NSWindow
    ) async {
        guard !usesInMemoryUITestFixture else {
            connectionError = "GitHub sign-in is unavailable in the local UI fixture."
            return
        }
        connectionError = nil
        credentialActionNotice = nil
        isConnecting = true
        defer {
            isConnecting = false
            isCredentialMutationInProgress = false
        }
        do {
            guard accounts.contains(where: { $0.id == account.id }),
                  !accountsBeingRemoved.contains(account.id)
            else {
                return
            }
            isCredentialMutationInProgress = true
            invalidateBackgroundRefreshScheduling()
            try await cancelInactiveRefreshes(for: account.id)
            guard canContinueCredentialMutation(for: account.id) else { return }
            await cancelForegroundRefresh()
            guard canContinueCredentialMutation(for: account.id) else { return }
            await cancelForegroundRefreshes(for: account.id)
            guard canContinueCredentialMutation(for: account.id) else { return }
            let configuration = try RuntimeOAuthConfiguration()
            let request = try await oauthAuthorizer.authorize(
                configuration: configuration.oauth,
                presentationAnchor: presentationAnchor
            )
            guard canContinueCredentialMutation(for: account.id) else { return }
            await invalidateCopilotAuthority(for: account)
            guard canContinueCredentialMutation(for: account.id) else { return }
            let snapshot = try await dependencies.accountSession.reconnectOAuth(request, replacing: account)
            guard canContinueCredentialMutation(for: account.id) else { return }
            await install(session: snapshot, requiringActiveAccountID: account.id)
            guard canContinueCredentialMutation(for: account.id) else { return }
            isCredentialMutationInProgress = false
            await recheckSelectedOrganizationAccess()
        } catch let error as AccountCredentialReplacementError {
            guard canContinueCredentialMutation(for: account.id) else { return }
            connectionError = credentialReplacementMessage(for: error)
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
        } catch let error as RuntimeOAuthConfigurationError {
            guard canContinueCredentialMutation(for: account.id) else { return }
            switch error {
            case .missingClientID:
                connectionError = "GitHub sign-in is not configured in this build."
            case .invalidBrokerURL:
                connectionError = "The GitHub sign-in service is not configured securely."
            case .invalidApplicationVersion:
                connectionError = "GitHub sign-in is not configured in this build."
            }
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
        } catch is CancellationError {
            guard canContinueCredentialMutation(for: account.id) else { return }
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
            return
        } catch let error as GitHubOAuthError {
            guard canContinueCredentialMutation(for: account.id) else { return }
            switch error {
            case .authorizationTimedOut:
                connectionError = "GitHub reconnect timed out. Try again to continue."
            default:
                connectionError = "GitHub reconnect could not be completed. Try again."
            }
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
        } catch {
            guard canContinueCredentialMutation(for: account.id) else { return }
            connectionError = Self.oauthFailureMessage(
                for: error,
                fallback: "GitHub reconnect could not be completed. Try again."
            )
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
        }
    }

    func replacePersonalAccessToken(
        _ rawValue: String,
        for account: GitHubAccount
    ) async {
        connectionError = nil
        credentialActionNotice = nil
        isConnecting = true
        defer {
            isConnecting = false
            isCredentialMutationInProgress = false
        }
        do {
            guard accounts.contains(where: { $0.id == account.id }),
                  !accountsBeingRemoved.contains(account.id)
            else {
                return
            }
            isCredentialMutationInProgress = true
            invalidateBackgroundRefreshScheduling()
            try await cancelInactiveRefreshes(for: account.id)
            guard canContinueCredentialMutation(for: account.id) else { return }
            await cancelForegroundRefresh()
            guard canContinueCredentialMutation(for: account.id) else { return }
            await cancelForegroundRefreshes(for: account.id)
            guard canContinueCredentialMutation(for: account.id) else { return }
            await invalidateCopilotAuthority(for: account)
            guard canContinueCredentialMutation(for: account.id) else { return }
            let snapshot = try await dependencies.accountSession.replacePersonalAccessToken(
                try PersonalAccessToken(rawValue: rawValue),
                replacing: account
            )
            guard canContinueCredentialMutation(for: account.id) else { return }
            await install(session: snapshot, requiringActiveAccountID: account.id)
            guard canContinueCredentialMutation(for: account.id) else { return }
            isCredentialMutationInProgress = false
            await recheckSelectedOrganizationAccess()
        } catch let error as PersonalAccessTokenError {
            guard canContinueCredentialMutation(for: account.id) else { return }
            switch error {
            case .unsupportedTokenFormat:
                connectionError = "Enter a supported personal access token for this account."
            }
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
        } catch let error as AccountCredentialReplacementError {
            guard canContinueCredentialMutation(for: account.id) else { return }
            connectionError = credentialReplacementMessage(for: error)
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
        } catch is CancellationError {
            guard canContinueCredentialMutation(for: account.id) else { return }
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
            return
        } catch {
            guard canContinueCredentialMutation(for: account.id) else { return }
            connectionError = "Triage could not replace this personal access token. Check its access and try again."
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
        }
    }

    func recordConnectionWindowError() {
        connectionError = "Triage could not find its active window."
    }

    private func canContinueCredentialMutation(for accountID: AccountID) -> Bool {
        !isShuttingDown
            && accounts.contains(where: { $0.id == accountID })
            && !accountsBeingRemoved.contains(accountID)
    }

    func startAutomaticRefreshes() async {
        guard automaticRefreshEnabled, !isShuttingDown, !usesInMemoryUITestFixture else { return }
        await refreshScheduler.start { [weak self] in
            await self?.refreshSelectedOrganizationAfterAccessCheck()
        }
        await inactiveRefreshScheduler.start(cadence: .inactiveAccount) { [weak self] in
            await self?.refreshInactiveOrganizations()
        }
        await capabilityRefreshScheduler.start(cadence: .dailyCapabilityProbe) { [weak self] in
            await self?.refreshDailyActiveAccountIdentityAndInventory()
            await self?.refreshSelectedOrganizationAfterAccessCheck()
        }
    }

    /// The daily active-account check owns `/user` and post-account
    /// `/user/orgs` validation. It runs before the existing selected-org
    /// capability check, so `/orgs/{org}` continues to receive its exact
    /// persisted synchronization scope. First connection stays on its
    /// unconditional AccountConnectionService path.
    private func refreshDailyActiveAccountIdentityAndInventory() async {
        guard !isShuttingDown,
              !isCredentialMutationInProgress,
              let account = accounts.first(where: { $0.id == selectedAccountID }),
              account.credentialStatus == .active,
              !accountsBeingRemoved.contains(account.id)
        else {
            return
        }
        do {
            let secretStore = KeychainSecretStore()
            let vaultRegistry = try requiredVaultRegistry()
            let vaultKey = try await requiredVaultKey(for: account, secretStore: secretStore)
            let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
            let rateLimitController = try await GitHubRateLimitControllerRegistry.shared.controller(
                for: account.id,
                vault: vault
            )
            let client = GitHubRESTClient(
                transport: try GitHubRESTTransport(),
                credential: try await AccountCredentialReader(secretStore: secretStore)
                    .accessToken(for: account),
                rateLimitController: rateLimitController,
                requestPriority: .selectedOrganizationRefresh
            )
            let identityClient = GitHubIdentityClient(client: client)
            let authenticatedUserReplay = PostAccountAuthenticatedUserReplayService(
                client: identityClient,
                receipts: AuthenticatedUserReplayReceiptRepository(vault: vault)
            )
            let inventoryReplay = PostAccountOrganizationInventoryReplayService(
                client: identityClient,
                receipts: PostAccountIdentityReplayReceiptRepository(vault: vault),
                rawSnapshots: RawAPISnapshotRepository(vault: vault)
            )
            let inventoryReceipts = PostAccountIdentityReplayReceiptRepository(vault: vault)
            let result = try await DailyActiveAccountIdentityRefreshService(
                vault: vault,
                loadAuthenticatedUser: {
                    let credentialRevision = try await AccountRepository(vault: vault)
                        .credentialRevision(for: account.id)
                    return try await authenticatedUserReplay.user(
                        accountID: account.id,
                        credentialRevision: credentialRevision
                    )
                },
                loadOrganizationInventory: { accountID, credentialRevision in
                    try await inventoryReplay.organizations(
                        accountID: accountID,
                        credentialRevision: credentialRevision
                    )
                },
                loadOrganizationInventoryValidatedAt: { accountID, credentialRevision in
                    try await inventoryReceipts.inventoryValidatedAt(
                        for: AccountOrganizationInventoryReplayIdentity(
                            accountID: accountID,
                            credentialRevision: credentialRevision
                        )
                    )
                }
            ).refreshIfDue(for: account)
            guard selectedAccountID == account.id,
                  !accountsBeingRemoved.contains(account.id)
            else {
                return
            }
            switch result {
            case .notDue:
                return
            case let .refreshed(snapshot):
                replaceDailyIdentitySnapshot(snapshot)
                organizationVisibilityFreshnessByAccount[account.id] = FreshnessState(
                    status: .fresh,
                    lastSuccessfulSyncAt: snapshot.account.lastValidatedAt
                )
            case let .inventoryUnavailable(snapshot):
                replaceDailyIdentitySnapshot(snapshot)
                organizationVisibilityFreshnessByAccount[account.id] = FreshnessState(
                    status: .partial,
                    lastSuccessfulSyncAt: organizationVisibilityFreshnessByAccount[account.id]?.lastSuccessfulSyncAt,
                    detail: "Organization visibility could not be refreshed. Showing saved organizations."
                )
            case let .credentialRevoked(revoked):
                if let index = accounts.firstIndex(where: { $0.id == revoked.id }) {
                    accounts[index] = revoked
                }
                organizationVisibilityFreshnessByAccount[account.id] = nil
                refreshError = "GitHub credentials need to be reconnected. Cached work remains available."
            }
        } catch is CancellationError {
            return
        } catch {
            // A transport, receipt, or vault failure must leave the current
            // account and organization presentation unchanged. The subsequent
            // scoped refresh will retain its own incomplete freshness state.
            return
        }
    }

    private func replaceDailyIdentitySnapshot(
        _ snapshot: DailyActiveAccountIdentityRefreshSnapshot
    ) {
        guard let accountIndex = accounts.firstIndex(where: { $0.id == snapshot.account.id }) else {
            return
        }
        accounts[accountIndex] = snapshot.account
        organizationsByAccount[snapshot.account.id] = snapshot.organizations
        organizationAccessesByAccount[snapshot.account.id] = snapshot.organizationAccesses
    }

    /// Enters the durable due-refresh path after the ordinary selected-workspace
    /// activation has settled, avoiding a second foreground refresh owner.
    func launchOrganizationRefreshLifecycle() async {
        guard automaticRefreshEnabled, !isShuttingDown, !usesInMemoryUITestFixture else { return }
        let scopes = await lifecycleSynchronizationScopes()
        guard !isShuttingDown else { return }
        await dependencies.refreshLifecycle.launch(
            synchronizationScopes: scopes,
            activeAccountID: selectedAccountID
        )
    }

    func applicationDidBecomeActive() async {
        guard automaticRefreshEnabled, !isShuttingDown, !usesInMemoryUITestFixture else { return }
        let scopes = await lifecycleSynchronizationScopes()
        await dependencies.refreshLifecycle.applicationDidBecomeActive(
            synchronizationScopes: scopes,
            activeAccountID: selectedAccountID
        )
    }

    func handleSystemWake() async {
        guard automaticRefreshEnabled, !isShuttingDown, !usesInMemoryUITestFixture else { return }
        let scopes = await lifecycleSynchronizationScopes()
        await dependencies.refreshLifecycle.wake(
            synchronizationScopes: scopes,
            activeAccountID: selectedAccountID
        )
    }

    func scheduleOpportunisticBackgroundRefresh() async {
        guard automaticRefreshEnabled, !isShuttingDown, !usesInMemoryUITestFixture else { return }
        let scopes = await lifecycleSynchronizationScopes()
        await dependencies.refreshLifecycle.scheduleOpportunisticBackgroundRefresh(
            synchronizationScopes: scopes,
            activeAccountID: selectedAccountID
        )
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        copilotRuntimeOperationTask?.cancel()
        copilotRuntimeOperationTask = nil
        copilotRuntimeStateObservationTask?.cancel()
        copilotRuntimeStateObservationTask = nil
        invalidateBackgroundRefreshScheduling()
        await dependencies.refreshLifecycle.stop()
        await refreshScheduler.stop()
        await inactiveRefreshScheduler.stop()
        await capabilityRefreshScheduler.stop()
        await cancelForegroundRefresh()
        await workspaceActivation.cancelAndWait()
        await cancelWorkspaceObservationAndWait()

        let accountIDs = Set(accounts.map(\.id))
            .union(foregroundRefreshTasksAwaitingAccountRemoval.keys)
            .sorted { $0.rawValue < $1.rawValue }
        for accountID in accountIDs {
            await cancelForegroundRefreshes(for: accountID)
            do {
                try await cancelInactiveRefreshes(for: accountID)
            } catch {
                // Process termination remains authoritative even if a damaged
                // vault cannot retain the final interruption projection.
            }
        }
        await dependencies.workspaceObservationLifecycle.shutdown()
        await dependencies.workspaceCoordinator.shutdown()
    }

    func resumeSelectedOrganization() async {
        if !foregroundRefreshTasksAwaitingCredentialMutation.isEmpty {
            await cancelForegroundRefresh()
        }
        await refreshSelectedOrganizationAfterAccessCheck()
    }

    func restoreVerifiedMigrationBackup(
        for accountID: AccountID,
        migrationID: String
    ) async {
        guard !isShuttingDown,
              vaultRecoveryIssues.contains(where: {
                  $0.accountID == accountID
                      && $0.verifiedBackupMigrationIDs.contains(migrationID)
              })
        else {
            return
        }
        restorationError = nil
        do {
            let result = try await dependencies.accountSession.restoreVerifiedMigrationBackup(
                for: accountID,
                migrationID: migrationID
            )
            guard !isShuttingDown else { return }
            await install(session: result)
            guard !isShuttingDown else { return }
            activateSelectedOrganization()
            if !result.vaultRecoveryIssues.isEmpty {
                restorationError = "The encrypted local account still needs repair. Its original encrypted data has been preserved."
            } else if !result.unavailableAccountIDs.isEmpty {
                restorationError = "An account's encrypted local data cannot be opened. Remove its local data in Settings, then reconnect to resync."
            }
        } catch is CancellationError {
            return
        } catch {
            guard !isShuttingDown else { return }
            restorationError = "Triage could not restore the verified encrypted backup. The original encrypted data has been preserved."
        }
    }

    func restoreAccounts() async {
        guard !isShuttingDown, !isRestoringAccounts else { return }
        isRestoringAccounts = true
        defer { isRestoringAccounts = false }
        restorationError = nil
        do {
            let result = try await dependencies.accountSession.restoreAccounts()
            guard !isShuttingDown else { return }
            await install(session: result)
            guard !isShuttingDown else { return }
            if !result.accounts.contains(where: { $0.id == selectedAccountID }) {
                selectedAccountID = result.accounts.first?.id
            }
            if !organizations.contains(where: { $0.id == selectedOrganizationID }) {
                selectedOrganizationID = organizations.first?.id
            }
            guard !isShuttingDown else { return }
            activateSelectedOrganization()
            guard !isShuttingDown else { return }
            if !result.vaultRecoveryIssues.isEmpty {
                restorationError = "An encrypted local account needs repair. Restore a verified migration backup when available, or reconnect to GitHub to resync."
            } else if !result.unavailableAccountIDs.isEmpty {
                restorationError = "An account's encrypted local data cannot be opened. Remove its local data in Settings, then reconnect to resync."
            }
        } catch is CancellationError {
            return
        } catch {
            guard !isShuttingDown else { return }
            restorationError = "Triage could not open its encrypted account data."
        }
    }

    private func refreshSelectedOrganization() async {
        guard !isCredentialMutationInProgress,
              let accountID = selectedAccountID,
              !accountsBeingRemoved.contains(accountID)
        else {
            return
        }
        if let existingTask = foregroundRefreshTask {
            existingTask.cancel()
            _ = await existingTask.value
        }
        let taskID = UUID()
        refreshGeneration += 1
        let generation = refreshGeneration
        let task: Task<ForegroundRefreshResult, Never> = Task { [weak self] in
            guard let self else { return .completed }
            await self.performRefreshSelectedOrganization(generation: generation)
            return .completed
        }
        foregroundRefreshTask = task
        foregroundRefreshTaskID = taskID
        _ = await task.value
        if foregroundRefreshTaskID == taskID {
            foregroundRefreshTask = nil
            foregroundRefreshTaskID = nil
        }
    }

    func recheckSelectedOrganizationAccess() async {
        guard let initialAccount = accounts.first(where: { $0.id == selectedAccountID }),
              !accountsBeingRemoved.contains(initialAccount.id)
        else {
            return
        }
        guard let organization = selectedOrganization else {
            await recheckAccountCapabilities(for: initialAccount)
            return
        }

        do {
            try await cancelInactiveRefreshes(for: initialAccount.id)
        } catch {
            refreshError = "Triage could not safely stop the previous organization refresh. Try again."
            return
        }
        if let existingTask = foregroundRefreshTask {
            existingTask.cancel()
            _ = await existingTask.value
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        let taskID = UUID()
        let task: Task<ForegroundRefreshResult, Never> = Task { [weak self] in
            guard let self else { return .completed }
            return await self.performRecheckSelectedOrganizationAccess(
                account: initialAccount,
                organization: organization,
                generation: generation
            )
        }
        foregroundRefreshTask = task
        foregroundRefreshTaskID = taskID
        let result = await task.value
        guard foregroundRefreshTaskID == taskID else { return }
        foregroundRefreshTask = nil
        foregroundRefreshTaskID = nil
        guard result == .accessAvailable,
              refreshGeneration == generation,
              selectedAccountID == initialAccount.id,
              selectedOrganizationID == organization.id
        else {
            return
        }
        await refreshSelectedOrganization()
    }

    private func recheckAccountCapabilities(for initialAccount: GitHubAccount) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        defer {
            if refreshGeneration == generation {
                isRefreshing = false
            }
        }
        do {
            let secretStore = KeychainSecretStore()
            let vaultRegistry = try requiredVaultRegistry()
            let vaultKey = try await requiredVaultKey(for: initialAccount, secretStore: secretStore)
            let vault = try await vaultRegistry.open(accountID: initialAccount.id, vaultKey: vaultKey)
            let rateLimitController = try await GitHubRateLimitControllerRegistry.shared.controller(
                for: initialAccount.id,
                vault: vault
            )
            let client = GitHubRESTClient(
                transport: try GitHubRESTTransport(),
                credential: try await AccountCredentialReader(secretStore: secretStore)
                    .accessToken(for: initialAccount),
                rateLimitController: rateLimitController
            )
            let probe = GitHubCapabilityProbe(
                identityClient: GitHubIdentityClient(client: client),
                restClient: client
            )
            let capabilities = try await probe.probeAccountCapabilities()
            let snapshot = AccountCapabilitySnapshot(
                accountID: initialAccount.id,
                capabilities: capabilities,
                checkedAt: capabilities.map(\.checkedAt).max() ?? Date()
            )
            try Task.checkCancellation()
            guard refreshGeneration == generation,
                  selectedAccountID == initialAccount.id,
                  selectedOrganizationID == nil,
                  !accountsBeingRemoved.contains(initialAccount.id)
            else {
                return
            }
            try await AccountRepository(vault: vault).save(snapshot)
            guard refreshGeneration == generation,
                  selectedAccountID == initialAccount.id,
                  selectedOrganizationID == nil,
                  !accountsBeingRemoved.contains(initialAccount.id)
            else {
                return
            }
            accountCapabilitiesByAccount[initialAccount.id] = snapshot
            refreshError = nil
        } catch is CancellationError {
            return
        } catch {
            guard refreshGeneration == generation else { return }
            refreshError = "Triage could not confirm notification access. Cached work remains available."
        }
    }

    private func performRecheckSelectedOrganizationAccess(
        account initialAccount: GitHubAccount,
        organization: GitHubOrganization,
        generation: Int
    ) async -> ForegroundRefreshResult {
        isRefreshing = true
        defer {
            if refreshGeneration == generation {
                isRefreshing = false
            }
        }

        do {
            let secretStore = KeychainSecretStore()
            let vaultRegistry = try requiredVaultRegistry()
            let vaultKey = try await requiredVaultKey(for: initialAccount, secretStore: secretStore)
            let vault = try await vaultRegistry.open(accountID: initialAccount.id, vaultKey: vaultKey)
            let scope = try await AccountRepository(vault: vault).synchronizationScope(
                for: initialAccount.id,
                organizationID: organization.id
            )
            try Task.checkCancellation()
            guard refreshGeneration == generation,
                  selectedAccountID == initialAccount.id,
                  selectedOrganizationID == organization.id
            else {
                return .completed
            }
            let rateLimitController = try await GitHubRateLimitControllerRegistry.shared.controller(
                for: initialAccount.id,
                vault: vault
            )
            let client = GitHubRESTClient(
                transport: try GitHubRESTTransport(),
                credential: try await AccountCredentialReader(secretStore: secretStore)
                    .accessToken(for: initialAccount),
                rateLimitController: rateLimitController
            )
            let probe = GitHubCapabilityProbe(
                identityClient: GitHubIdentityClient(client: client),
                restClient: client,
                metadataReplayService: PostAccountOrganizationMetadataReplayService(
                    client: GitHubIdentityClient(client: client),
                    receipts: PostAccountIdentityReplayReceiptRepository(vault: vault)
                )
            )
            let probedAccountCapabilities = try await probe.probeAccountCapabilities()
            let accountCapabilities = AccountCapabilitySnapshot(
                accountID: initialAccount.id,
                capabilities: probedAccountCapabilities,
                checkedAt: probedAccountCapabilities.map(\.checkedAt).max() ?? Date()
            )
            let result = try await probe.probe(
                organization: organization,
                accountLogin: initialAccount.login,
                synchronizationScope: scope
            )
            try Task.checkCancellation()
            let confirmedScope = try await AccountRepository(vault: vault).synchronizationScope(
                for: initialAccount.id,
                organizationID: organization.id
            )
            guard
                refreshGeneration == generation,
                selectedAccountID == initialAccount.id,
                selectedOrganizationID == organization.id,
                confirmedScope == scope
            else {
                return .completed
            }

            let access = OrganizationAccess(
                accountID: initialAccount.id,
                organizationID: organization.id,
                state: result.accessState,
                capabilityRevision: CapabilityRevision(rawValue: UUID().uuidString.lowercased())!,
                capabilities: result.capabilities,
                checkedAt: Date()
            )
            try await AccountRepository(vault: vault).save(
                organization,
                access: access,
                accountCapabilities: accountCapabilities
            )
            guard
                refreshGeneration == generation,
                selectedAccountID == initialAccount.id,
                selectedOrganizationID == organization.id
            else {
                return .completed
            }
            let previousAccess = organizationAccessesByAccount[initialAccount.id]?[organization.id]
            organizationAccessesByAccount[initialAccount.id, default: [:]][organization.id] = access
            accountCapabilitiesByAccount[initialAccount.id] = accountCapabilities
            if previousAccess?.capabilityRevision != access.capabilityRevision {
                invalidateCachedWorkspaceAuthority(
                    for: initialAccount.id,
                    organizationID: organization.id
                )
            }
            guard result.accessState == .available else {
                ssoAuthorizationHeader = result.ssoHeader
                refreshError = accessMessage(for: result.accessState)
                return .completed
            }

            ssoAuthorizationHeader = nil
            refreshError = nil
            return .accessAvailable
        } catch is CancellationError {
            return .completed
        } catch {
            guard refreshGeneration == generation else { return .completed }
            refreshError = "Triage could not confirm organization access. Cached work remains available."
            return .completed
        }
    }

    private func refreshInactiveOrganizations() async {
        guard !isCredentialMutationInProgress else { return }

        let generation = backgroundRefreshGeneration
        let eligibleAccounts = accounts.compactMap { account -> (GitHubAccount, [GitHubOrganization])? in
            guard account.credentialStatus == .active,
                  isEligibleForInactiveRefresh(account),
                  !accountsBeingRemoved.contains(account.id)
            else {
                return nil
            }
            let organizations = (organizationsByAccount[account.id] ?? []).filter { organization in
                guard organizationAccessesByAccount[account.id]?[organization.id]?.state == .available,
                      selectedAccountID != account.id
                else {
                    return false
                }
                return true
            }
            return organizations.isEmpty ? nil : (account, organizations)
        }

        for (account, organizations) in eligibleAccounts {
            guard backgroundRefreshGeneration == generation,
                  accounts.contains(where: { $0.id == account.id }),
                  !accountsBeingRemoved.contains(account.id),
                  !isCredentialMutationInProgress,
                  selectedAccountID != account.id
            else {
                return
            }
            let secretStore = KeychainSecretStore()
            do {
                guard canRunInactiveRefresh(
                    for: account.id,
                    expectedGeneration: generation
                )
                else {
                    throw CancellationError()
                }
                let refreshedAccount: GitHubAccount
                if account.authenticationKind == .oauth,
                   CredentialLifecycle.status(for: account, at: .now) == .expiring {
                    try await cancelInactiveRefreshes(for: account.id)
                    let configuration = try RuntimeOAuthConfiguration()
                    refreshedAccount = try await OAuthCredentialRefreshService(
                        brokerURL: configuration.brokerURL,
                        applicationVersion: configuration.applicationVersion,
                        secretStore: secretStore,
                        vaultRegistry: vaultRegistry
                    ).refreshIfNeeded(account)
                    try Task.checkCancellation()
                    guard installInactiveRefreshedAccount(
                        refreshedAccount,
                        expectedGeneration: generation
                    ) else {
                        throw CancellationError()
                    }
                } else {
                    refreshedAccount = account
                }
                for organization in organizations {
                    guard canRunInactiveRefresh(
                        for: refreshedAccount.id,
                        expectedGeneration: generation
                    ) else {
                        throw CancellationError()
                    }
                    do {
                        guard let vaultKey = try await secretStore.readVaultKey(for: refreshedAccount.id) else {
                            throw AccountCredentialReaderError.missingAccessToken
                        }
                        let vault = try await vaultRegistry.open(accountID: refreshedAccount.id, vaultKey: vaultKey)
                        let scope = try await AccountRepository(vault: vault).synchronizationScope(
                            for: refreshedAccount.id,
                            organizationID: organization.id
                        )
                        _ = try await dependencies.workspaceCoordinator.refresh(
                            scope,
                            priority: .inactiveAccount
                        )
                        try Task.checkCancellation()
                        try await SearchRepository(vault: vault).rebuild(
                            accountID: refreshedAccount.id,
                            organizationID: organization.id
                        )
                    } catch let error as OrganizationRefreshError {
                        await recordOrganizationRefreshFailure(
                            error,
                            for: refreshedAccount,
                            organization: organization
                        )
                        continue
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // The coordinator retains the exact account/organization failure
                // and freshness state in the encrypted vault. Inactive work never
                // replaces the selected workspace's user-facing error.
            }
        }
    }

    private func performRefreshSelectedOrganization(generation: Int) async {
        guard refreshGeneration == generation else { return }
        guard let initialAccount = accounts.first(where: { $0.id == selectedAccountID }),
              let organization = selectedOrganization
        else {
            return
        }

        ssoAuthorizationHeader = nil
        isRefreshing = true
        defer {
            if refreshGeneration == generation {
                isRefreshing = false
            }

        }
        do {
            let secretStore = KeychainSecretStore()
            let vaultRegistry = try requiredVaultRegistry()
            let account: GitHubAccount
            let lifecycleStatus = CredentialLifecycle.status(for: initialAccount, at: Date())
            if let reconnectMessage = CredentialLifecycle.reconnectMessage(
                for: lifecycleStatus
            ) {
                await persistCredentialStatus(
                    lifecycleStatus,
                    for: initialAccount,
                    message: reconnectMessage
                )
                return
            } else if let reconnectMessage = CredentialLifecycle.reconnectMessage(
                for: initialAccount.credentialStatus
            ) {
                refreshError = reconnectMessage
                return
            } else if initialAccount.authenticationKind == .oauth,
                      lifecycleStatus == .expiring {
                try await cancelInactiveRefreshes(for: initialAccount.id)
                let runtimeConfiguration = try RuntimeOAuthConfiguration()
                account = try await OAuthCredentialRefreshService(
                    brokerURL: runtimeConfiguration.brokerURL,
                    applicationVersion: runtimeConfiguration.applicationVersion,
                    secretStore: secretStore,
                    vaultRegistry: vaultRegistry
                ).refreshIfNeeded(initialAccount)
                if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                    accounts[index] = account
                }
            } else {
                account = initialAccount
            }
            guard let vaultKey = try await secretStore.readVaultKey(for: account.id) else {
                throw AccountCredentialReaderError.missingAccessToken
            }
            let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
            let scope = try await AccountRepository(vault: vault).synchronizationScope(
                for: account.id,
                organizationID: organization.id
            )
            let coordinatorState = try await dependencies.workspaceCoordinator.select(scope)
            guard
                refreshGeneration == generation,
                selectedAccountID == account.id,
                selectedOrganizationID == organization.id
            else {
                return
            }
            selectedOrganizationFreshness = coordinatorState?.freshness
            replaceWorkspaceObservation(for: scope)
            // Search indexing is independent from first Inbox presentation.
            // The page observer above can render while it catches up.
            try await rebuildSearchIndex(in: vault, accountID: account.id, organizationID: organization.id)
        } catch is CancellationError {
            return
        } catch let error as OrganizationRefreshError {
            guard refreshGeneration == generation else { return }
            await recordOrganizationRefreshFailure(
                error,
                for: initialAccount,
                organization: organization
            )
        } catch let error as GitHubFailure {
            guard refreshGeneration == generation else { return }
            if let credentialStatus = CredentialLifecycle.failureStatus(for: error) {
                await persistCredentialStatus(
                    credentialStatus,
                    for: initialAccount,
                    message: CredentialLifecycle.reconnectMessage(for: credentialStatus)
                )
                return
            }
            ssoAuthorizationHeader = error.ssoHeader
            if case .authorizationRequired? = error.ssoHeader {
                refreshError = "GitHub requires SSO authorization for this organization."
            } else {
                refreshError = "Triage could not refresh this organization. Cached work remains available."
            }
        } catch {
            guard refreshGeneration == generation else { return }
            if let credentialStatus = CredentialLifecycle.failureStatus(for: error) {
                await persistCredentialStatus(
                    credentialStatus,
                    for: initialAccount,
                    message: CredentialLifecycle.reconnectMessage(for: credentialStatus)
                )
                return
            }
            refreshError = "Triage could not refresh this organization. Cached work remains available."
        }
    }

    private func invalidateRefreshState() {
        refreshGeneration += 1
        if let accountID = selectedAccountID, let foregroundRefreshTask {
            foregroundRefreshTask.cancel()
            foregroundRefreshTasksAwaitingAccountRemoval[accountID, default: []].append(
                foregroundRefreshTask
            )
        }
        foregroundRefreshTask = nil
        foregroundRefreshTaskID = nil
        ssoAuthorizationHeader = nil
        refreshError = nil
        selectedOrganizationFreshness = nil
        isRefreshing = false
    }

    private func invalidateBackgroundRefreshScheduling() {
        backgroundRefreshGeneration &+= 1
    }

    private func cancelInactiveRefreshes(for accountID: AccountID) async throws {
        try await dependencies.workspaceCoordinator.cancelAll(for: accountID)
    }

    private func cancelForegroundRefreshes(for accountID: AccountID) async {
        let tasks = foregroundRefreshTasksAwaitingAccountRemoval.removeValue(forKey: accountID) ?? []
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            _ = await task.value
        }
    }

    private func isEligibleForInactiveRefresh(_ account: GitHubAccount) -> Bool {
        switch CredentialLifecycle.status(for: account, at: .now) {
        case .active:
            true
        case .expiring:
            account.authenticationKind == .oauth
        case .expired, .revoked, .missing, .capabilityLimited:
            false
        }
    }

    private func canRunInactiveRefresh(
        for accountID: AccountID,
        expectedGeneration: UInt64
    ) -> Bool {
        backgroundRefreshGeneration == expectedGeneration &&
            !isCredentialMutationInProgress &&
            !accountsBeingRemoved.contains(accountID) &&
            selectedAccountID != accountID &&
            accounts.contains(where: { $0.id == accountID })
    }

    private func installInactiveRefreshedAccount(
        _ account: GitHubAccount,
        expectedGeneration: UInt64
    ) -> Bool {
        guard canRunInactiveRefresh(for: account.id, expectedGeneration: expectedGeneration),
              let index = accounts.firstIndex(where: { $0.id == account.id }),
              accounts[index].credentialID == account.credentialID
        else {
            return false
        }
        accounts[index] = account
        return true
    }

    private func cancelForegroundRefresh() async {
        refreshGeneration += 1
        let tasks = foregroundRefreshTasksAwaitingCredentialMutation
            + [foregroundRefreshTask].compactMap { $0 }
        foregroundRefreshTasksAwaitingCredentialMutation = []
        foregroundRefreshTask = nil
        foregroundRefreshTaskID = nil
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            _ = await task.value
        }
        isRefreshing = false
        ssoAuthorizationHeader = nil
        refreshError = nil
        selectedOrganizationFreshness = nil
    }

    private func pauseForegroundRefreshForCredentialMutation() {
        refreshGeneration += 1
        if let task = foregroundRefreshTask {
            task.cancel()
            foregroundRefreshTasksAwaitingCredentialMutation.append(task)
        }
        foregroundRefreshTask = nil
        foregroundRefreshTaskID = nil
        isRefreshing = false
        ssoAuthorizationHeader = nil
        refreshError = nil
        selectedOrganizationFreshness = nil
    }

    private func installUpdatedAccount(_ updatedAccount: GitHubAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == updatedAccount.id }) else { return }
        accounts[index] = updatedAccount
    }

    private func credentialReplacementMessage(for error: AccountCredentialReplacementError) -> String {
        switch error {
        case .immutableIdentityMismatch:
            "This credential belongs to a different GitHub account. The connected profile was not changed."
        case .authenticationKindMismatch:
            "Replace a credential with the same authentication kind, or connect a separate profile."
        case .fineGrainedResourceOwnerOrganizationRequired:
            "Fine-grained personal access tokens need a resource-owner organization. Connect it as a new account instead of replacing this credential."
        case .invalidGitHubIdentity:
            "GitHub returned an invalid account identity. The connected profile was not changed."
        case .stagedCredentialCleanupFailed:
            "Triage could not safely clear a staged Keychain credential. The connected profile was not changed."
        }
    }

    /// Broker failures are untrusted transport data. Only the stable,
    /// protocol-defined obsolete-client response may reach the UI; every
    /// other broker detail deliberately uses the caller's generic message.
    static func oauthFailureMessage(for error: Error, fallback: String) -> String {
        guard let clientError = error as? AuthBrokerClientError,
              case let .broker(failure) = clientError,
              failure.code == .invalidRequest,
              failure.recoveryDescription == "This version of Triage is not supported by the OAuth service."
        else {
            return fallback
        }
        return "\(failure.recoveryDescription) Update Triage to continue."
    }

    private func persistCredentialStatus(
        _ status: CredentialStatus,
        for account: GitHubAccount,
        message: String?
    ) async {
        guard let index = accounts.firstIndex(where: {
            $0.id == account.id && $0.credentialID == account.credentialID
        }) else {
            return
        }
        let updatedAccount = account.replacingCredentialExpiration(
            accessTokenExpiresAt: account.accessTokenExpiresAt,
            refreshTokenExpiresAt: account.refreshTokenExpiresAt,
            status: status,
            validatedAt: account.lastValidatedAt ?? account.createdAt
        )
        accounts[index] = updatedAccount
        invalidateCachedWorkspaceAuthority(for: account.id)
        if selectedAccountID == account.id {
            workspaceActivation.cancel()
        }
        refreshError = message ?? "Triage could not refresh this organization. Cached work remains available."
        do {
            let secretStore = KeychainSecretStore()
            guard let vaultKey = try await secretStore.readVaultKey(for: account.id) else {
                throw AccountCredentialReaderError.missingAccessToken
            }
            let vault = try await requiredVaultRegistry().open(accountID: account.id, vaultKey: vaultKey)
            try await AccountRepository(vault: vault).save(
                updatedAccount,
                credentialRevision: CredentialRevision(rawValue: UUID().uuidString.lowercased())!
            )
        } catch {
            // The status is still accurate even when the unavailable vault cannot retain it.
        }
    }

    private func loadCachedSelectedOrganization(
        accountID: AccountID,
        organizationID: OrganizationID,
        activationGeneration: UInt64
    ) async {
        guard let account = accounts.first(where: { $0.id == accountID }),
              let organization = organizationsByAccount[accountID]?.first(where: { $0.id == organizationID }),
              !accountsBeingRemoved.contains(account.id),
              workspaceActivation.isCurrent(activationGeneration)
        else {
            return
        }
        let generation = refreshGeneration
        do {
            let secretStore = KeychainSecretStore()
            guard let vaultKey = try await secretStore.readVaultKey(for: account.id) else {
                throw AccountCredentialReaderError.missingAccessToken
            }
            let vault = try await requiredVaultRegistry().open(accountID: account.id, vaultKey: vaultKey)
            try Task.checkCancellation()
            guard workspaceActivation.isCurrent(activationGeneration) else { return }
            let scope = try await AccountRepository(vault: vault).synchronizationScope(
                for: account.id,
                organizationID: organization.id
            )
            try Task.checkCancellation()
            guard workspaceActivation.isCurrent(activationGeneration) else { return }
            replaceWorkspaceObservation(for: scope)
            try await rebuildSearchIndex(in: vault, accountID: account.id, organizationID: organization.id)
        } catch is CancellationError {
            return
        } catch {
            guard workspaceActivation.isCurrent(activationGeneration),
                  selectedAccountID == accountID,
                  selectedOrganizationID == organizationID
            else { return }
            workspaceRestorationError = "Triage could not load cached work for the selected organization."
        }
    }

    func applyWorkflowAction(_ action: WorkflowAction, to workItem: WorkItem) async {
        guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return }
        guard !usesInMemoryUITestFixture else {
            workspaceAccessibility?.workflowCompleted(action)
            return
        }
        do {
            let scope = try await synchronizationScope(for: workItem)
            guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return }
            _ = try await dependencies.workspaceMutator.applyWorkflowHistory(action, to: [workItem.id], in: scope)
            guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return }
            workspaceAccessibility?.workflowCompleted(action)
        } catch {
            guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return }
            refreshError = "Triage could not save this local workflow change."
        }
    }

    /// Saves an explicit local grouping choice and rebuilds only this
    /// account/organization projection. This does not perform a GitHub write.
    func applyGroupingMutation(
        _ mutation: WorkItemGroupingMutation,
        to workItem: WorkItem
    ) async -> WorkItemGroupingMutationHistory? {
        guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return nil }
        if usesInMemoryUITestFixture {
            let decision = WorkItemGroupingDecision(
                sourceNodeID: mutation.sourceNodeID,
                destinationNodeID: mutation.destinationNodeID,
                relation: mutation.relation,
                strength: mutation.strength,
                evidence: [],
                decidedAt: .now
            )
            return WorkItemGroupingMutationHistory(before: [], after: [decision])
        }
        do {
            let scope = try await synchronizationScope(for: workItem)
            guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return nil }
            return try await dependencies.workspaceMutator.applyGroupingMutation(mutation, in: scope)
        } catch {
            guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return nil }
            refreshError = (error as? WorkItemGroupingDecisionServiceError) == .staleRollbackPreserved
                ? "Triage kept a newer local grouping decision. Review the current grouping before trying again."
                : "Triage could not save this local grouping decision."
            return nil
        }
    }

    func restoreGroupingDecisions(
        _ decisions: [WorkItemGroupingDecision],
        expectedCurrent: [WorkItemGroupingDecision],
        for workItem: WorkItem
    ) async -> Bool {
        guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return false }
        if usesInMemoryUITestFixture { return true }
        do {
            let scope = try await synchronizationScope(for: workItem)
            guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return false }
            try await dependencies.workspaceMutator.restoreGroupingDecisions(
                decisions,
                expectedCurrent: expectedCurrent,
                in: scope
            )
            return true
        } catch {
            guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return false }
            refreshError = (error as? WorkItemGroupingDecisionServiceError) == .staleRollbackPreserved
                ? "Triage kept a newer local grouping decision. Review the current grouping before trying again."
                : "Triage could not reverse this local grouping decision because it changed again."
            return false
        }
    }

    /// Assigns a local action item to one member of the currently merged item
    /// before a manual split. The encrypted mutation is validated by the
    /// production boundary against the live group membership.
    func assignActionItem(
        _ actionItem: ActionItem,
        toMemberNodeID destinationNodeID: GitHubNodeID,
        in workItem: WorkItem
    ) async -> Bool {
        guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return false }
        if usesInMemoryUITestFixture { return true }
        do {
            let scope = try await synchronizationScope(for: workItem)
            guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return false }
            try await dependencies.workspaceMutator.assignActionItem(
                actionItem.id,
                expectedOwnerWorkItemID: actionItem.workItemID,
                visibleWorkItemID: workItem.id,
                destinationNodeID: destinationNodeID,
                in: scope
            )
            return true
        } catch {
            guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return false }
            refreshError = "Triage could not assign this local action item to the selected split owner."
            return false
        }
    }

    /// Applies the same local-only transition to a selected set in one vault
    /// transaction. The production mutator creates one durable undo group;
    /// no GitHub transport is involved.
    func applyWorkflowAction(_ action: WorkflowAction, to workItems: [WorkItem]) async {
        _ = await applyWorkflowActionWithHistory(action, to: workItems)
    }

    /// Delivers the committed transaction to native undo registration. This
    /// avoids racing the asynchronous workspace observer/cache after a write.
    func applyWorkflowActionWithHistory(
        _ action: WorkflowAction,
        to workItems: [WorkItem]
    ) async -> WorkflowHistoryTransaction? {
        guard let first = workItems.first,
              !isShuttingDown,
              !accountsBeingRemoved.contains(first.accountID),
              workItems.allSatisfy({ $0.accountID == first.accountID && $0.organizationID == first.organizationID })
        else { return nil }
        guard !usesInMemoryUITestFixture else {
            workspaceAccessibility?.workflowCompleted(action)
            return .init(id: UUID().uuidString.lowercased(), accountID: first.accountID, organizationID: first.organizationID, changes: [])
        }
        do {
            let scope = try await synchronizationScope(for: first)
            try Task.checkCancellation()
            let transaction = try await dependencies.workspaceMutator.applyWorkflowHistory(
                action,
                to: workItems.map(\.id),
                in: scope
            )
            guard !isShuttingDown, !accountsBeingRemoved.contains(first.accountID) else { return nil }
            workspaceAccessibility?.workflowCompleted(action)
            return transaction
        } catch is CancellationError {
            return nil
        } catch {
            guard !isShuttingDown, !accountsBeingRemoved.contains(first.accountID) else { return nil }
            refreshError = "Triage could not save these local workflow changes."
            return nil
        }
    }

    /// Uses encrypted workflow history, so undo remains available after a
    /// relaunch instead of relying solely on the window's UndoManager stack.
    func undoLatestWorkflowAction(for workItem: WorkItem) async -> Bool {
        guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID), !usesInMemoryUITestFixture else {
            return false
        }
        do {
            let scope = try await synchronizationScope(for: workItem)
            _ = try await dependencies.workspaceMutator.undoLatestWorkflow(in: scope)
            return true
        } catch is CancellationError {
            return false
        } catch {
            refreshError = "Triage could not reverse this local workflow change."
            return false
        }
    }

    func redoLatestWorkflowAction(for workItem: WorkItem) async -> Bool {
        guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID), !usesInMemoryUITestFixture else {
            return false
        }
        do {
            let scope = try await synchronizationScope(for: workItem)
            _ = try await dependencies.workspaceMutator.redoLatestWorkflow(in: scope)
            return true
        } catch is CancellationError {
            return false
        } catch {
            refreshError = "Triage could not reapply this local workflow change."
            return false
        }
    }

    func undoWorkflowAction(transactionID: String, for workItem: WorkItem) async -> Bool {
        guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID), !usesInMemoryUITestFixture else {
            return false
        }
        do {
            let scope = try await synchronizationScope(for: workItem)
            _ = try await dependencies.workspaceMutator.undoWorkflow(transactionID: transactionID, in: scope)
            return true
        } catch is CancellationError {
            return false
        } catch {
            refreshError = "Triage cannot reverse this local workflow change because newer local work exists."
            return false
        }
    }

    func redoWorkflowAction(transactionID: String, for workItem: WorkItem) async -> Bool {
        guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID), !usesInMemoryUITestFixture else {
            return false
        }
        do {
            let scope = try await synchronizationScope(for: workItem)
            _ = try await dependencies.workspaceMutator.redoWorkflow(transactionID: transactionID, in: scope)
            return true
        } catch is CancellationError {
            return false
        } catch {
            refreshError = "Triage cannot reapply this local workflow change because its undo branch is no longer current."
            return false
        }
    }

    func completeActionItem(_ actionItem: ActionItem, in workItem: WorkItem) async {
        guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return }
        guard !usesInMemoryUITestFixture else {
            workspaceAccessibility?.actionItemCompleted()
            return
        }
        do {
            let scope = try await synchronizationScope(for: workItem)
            guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return }
            try await dependencies.workspaceMutator.completeActionItem(
                actionItem.id,
                in: workItem.id,
                scope: scope
            )
            guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return }
            workspaceAccessibility?.actionItemCompleted()
        } catch {
            guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return }
            refreshError = "Triage could not complete this local action item."
        }
    }

    /// Updates only the explicitly local editable fields. This method has no
    /// GitHub transport and returns the committed local record for undo.
    func editActionItem(
        _ edit: LocalActionItemEdit,
        actionItem: ActionItem,
        in workItem: WorkItem
    ) async -> ActionItem? {
        guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return nil }
        guard !usesInMemoryUITestFixture else {
            return actionItem.applying(edit, at: .now)
        }
        do {
            let scope = try await synchronizationScope(for: workItem)
            guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return nil }
            let updated = try await dependencies.workspaceMutator.editActionItem(
                edit,
                actionItemID: actionItem.id,
                in: workItem.id,
                expectedUpdatedAt: actionItem.updatedAt,
                scope: scope
            )
            guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return nil }
            return updated
        } catch {
            guard !isShuttingDown, !accountsBeingRemoved.contains(workItem.accountID) else { return nil }
            refreshError = "Triage could not save this local action-item edit."
            return nil
        }
    }

    /// Reads the already-normalized local source record. Detail presentation
    /// never turns an absent body into a network fetch.
    func localDetailSource(for workItem: WorkItem) async -> WorkDetailSource? {
        guard !isShuttingDown,
              !accountsBeingRemoved.contains(workItem.accountID),
              !usesInMemoryUITestFixture,
              !Task.isCancelled
        else { return nil }
        do {
            let secretStore = KeychainSecretStore()
            guard let vaultKey = try await secretStore.readVaultKey(for: workItem.accountID) else {
                return nil
            }
            guard !isShuttingDown,
                  !accountsBeingRemoved.contains(workItem.accountID),
                  !Task.isCancelled
            else { return nil }
            let vault = try await vaultRegistry.open(accountID: workItem.accountID, vaultKey: vaultKey)
            let source = try await WorkDetailRepository(vault: vault).source(for: workItem)
            guard !isShuttingDown,
                  !accountsBeingRemoved.contains(workItem.accountID),
                  !Task.isCancelled
            else { return nil }
            return source
        } catch {
            return nil
        }
    }

    /// Returns one bounded page from the encrypted normalized timeline. The
    /// caller owns cancellation; no refresh or GitHub request occurs here.
    func localTimelinePage(
        for workItem: WorkItem,
        after cursor: WorkDetailTimelineCursor?,
        limit: Int
    ) async -> WorkDetailTimelinePage? {
        guard !isShuttingDown,
              !accountsBeingRemoved.contains(workItem.accountID),
              !usesInMemoryUITestFixture,
              !Task.isCancelled
        else { return nil }
        do {
            let secretStore = KeychainSecretStore()
            guard let vaultKey = try await secretStore.readVaultKey(for: workItem.accountID) else {
                return nil
            }
            guard !isShuttingDown,
                  !accountsBeingRemoved.contains(workItem.accountID),
                  !Task.isCancelled
            else { return nil }
            let vault = try await vaultRegistry.open(accountID: workItem.accountID, vaultKey: vaultKey)
            let page = try await WorkDetailRepository(vault: vault).timelinePage(
                for: workItem,
                after: cursor,
                limit: limit
            )
            guard !isShuttingDown,
                  !accountsBeingRemoved.contains(workItem.accountID),
                  !Task.isCancelled
            else { return nil }
            return page
        } catch {
            return nil
        }
    }

    /// Reloads the persisted consent and its current fail-closed effective
    /// state for the selected organization. The unavailable production
    /// Copilot boundary deliberately produces an explicit unavailable state.
    func refreshSelectedOrganizationAIStatus() async {
        guard !isShuttingDown else { return }
        guard !usesInMemoryUITestFixture else {
            guard let accountID = selectedAccountID,
                  let organizationID = selectedOrganizationID
            else { return }
            organizationAISettingsByAccount[accountID, default: [:]][organizationID] = .init(
                consent: .disabled(accountID: accountID, organizationID: organizationID),
                isEffectivelyAvailable: false,
                status: "AI analysis is blocked in the deterministic local UI fixture."
            )
            return
        }
        guard let account = accounts.first(where: { $0.id == selectedAccountID }),
              let organization = selectedOrganization,
              !accountsBeingRemoved.contains(account.id)
        else { return }
        selectedCopilotAuthorizationState = await dependencies.copilotRuntimeAuthorization.state(for: account.id)
        do {
            let context = try await aiContext(for: account, organization: organization)
            guard !isShuttingDown,
                  selectedAccountID == account.id,
                  selectedOrganizationID == organization.id
            else { return }
            var policy = try await context.controller.policy(
                for: context.scope,
                account: account
            )
            let models = try await context.controller.cachedModels(for: context.scope)
            var modelSelectionNotice: String?
            if let selectedModelID = policy.selectedModelID,
               selectedCopilotAuthorizationState.authentication == .authenticated,
               !models.contains(where: { $0.id == selectedModelID }) {
                try await context.controller.selectModel(nil, for: context.scope)
                policy = try await context.controller.policy(
                    for: context.scope,
                    account: account
                )
                modelSelectionNotice = "\(selectedModelID) is no longer available. Triage switched this organization to Auto."
            }
            guard !isShuttingDown,
                  selectedAccountID == account.id,
                  selectedOrganizationID == organization.id
            else { return }
            organizationAISettingsByAccount[account.id, default: [:]][organization.id] = Self.aiSettingsState(
                policy: policy,
                availableModels: models,
                modelSelectionNotice: modelSelectionNotice
            )
        } catch is CancellationError {
        } catch {
            guard !isShuttingDown,
                  selectedAccountID == account.id,
                  selectedOrganizationID == organization.id
            else { return }
            organizationAISettingsByAccount[account.id, default: [:]][organization.id] = .init(
                consent: .disabled(accountID: account.id, organizationID: organization.id),
                isEffectivelyAvailable: false,
                status: "AI analysis is unavailable until Triage can verify this organization's local authorization."
            )
        }
    }

    /// Persists one selected organization's explicit choice. Disabling uses
    /// the controller's cancellation-and-purge path, which cannot affect
    /// source content, deterministic/manual work, or another organization.
    func recordSelectedOrganizationAIConsent(_ isEnabled: Bool) async {
        guard !isShuttingDown else { return }
        guard !usesInMemoryUITestFixture else {
            guard let accountID = selectedAccountID,
                  let organizationID = selectedOrganizationID
            else { return }
            organizationAISettingsByAccount[accountID, default: [:]][organizationID] = .init(
                consent: .init(
                    accountID: accountID,
                    organizationID: organizationID,
                    isEnabled: isEnabled,
                    selectedModelID: nil,
                    automaticActionConfidenceThreshold: organizationAISettingsByAccount[accountID]?[organizationID]?.consent.automaticActionConfidenceThreshold
                        ?? OrganizationAIConsent.minimumAutomaticActionConfidenceThreshold,
                    updatedAt: .now
                ),
                isEffectivelyAvailable: false,
                status: "AI analysis is blocked in the deterministic local UI fixture."
            )
            return
        }
        guard let account = accounts.first(where: { $0.id == selectedAccountID }),
              let organization = selectedOrganization,
              !accountsBeingRemoved.contains(account.id)
        else { return }
        do {
            let context = try await aiContext(for: account, organization: organization)
            guard !isShuttingDown,
                  selectedAccountID == account.id,
                  selectedOrganizationID == organization.id,
                  !accountsBeingRemoved.contains(account.id)
            else { return }
            if isEnabled {
                let existingConsent = try await context.controller.consent(
                    for: account.id,
                    organizationID: organization.id
                )
                try await context.controller.recordConsent(.init(
                    accountID: account.id,
                    organizationID: organization.id,
                    isEnabled: true,
                    selectedModelID: nil,
                    automaticActionConfidenceThreshold: existingConsent.automaticActionConfidenceThreshold,
                    updatedAt: .now
                ))
            } else {
                try await context.controller.cancelAndDisable(for: context.scope)
            }
            guard !isShuttingDown else { return }
            await refreshSelectedOrganizationAIStatus()
        } catch {
            guard !isShuttingDown else { return }
            refreshError = isEnabled
                ? "Triage could not save AI consent for this organization."
                : "Triage could not disable and erase AI data for this organization."
        }
    }

    func selectSelectedOrganizationCopilotModel(_ selectedModelID: String?) async {
        guard !isShuttingDown,
              !usesInMemoryUITestFixture,
              let account = accounts.first(where: { $0.id == selectedAccountID }),
              let organization = selectedOrganization,
              !accountsBeingRemoved.contains(account.id)
        else { return }
        do {
            let context = try await aiContext(for: account, organization: organization)
            guard !isShuttingDown,
                  selectedAccountID == account.id,
                  selectedOrganizationID == organization.id,
                  !accountsBeingRemoved.contains(account.id)
            else { return }
            try await context.controller.selectModel(selectedModelID, for: context.scope)
            await refreshSelectedOrganizationAIStatus()
        } catch is CancellationError {
        } catch {
            guard !isShuttingDown else { return }
            refreshError = "Copilot model selection could not be saved. Authenticate Copilot again, then choose an available model."
        }
    }

    func setSelectedOrganizationAutomaticActionConfidenceThreshold(_ threshold: Double) async {
        guard !isShuttingDown,
              !usesInMemoryUITestFixture,
              AIConsentRepository.isValidAutomaticActionConfidenceThreshold(threshold),
              let account = accounts.first(where: { $0.id == selectedAccountID }),
              let organization = selectedOrganization,
              !accountsBeingRemoved.contains(account.id)
        else { return }
        do {
            let context = try await aiContext(for: account, organization: organization)
            guard !isShuttingDown,
                  selectedAccountID == account.id,
                  selectedOrganizationID == organization.id,
                  !accountsBeingRemoved.contains(account.id)
            else { return }
            try await context.controller.setAutomaticActionConfidenceThreshold(
                threshold,
                for: context.scope
            )
            await refreshSelectedOrganizationAIStatus()
        } catch is CancellationError {
        } catch {
            guard !isShuttingDown else { return }
            refreshError = "Triage could not save this organization's automatic action confidence threshold."
        }
    }

    /// Runtime acquisition is explicit and is never started during account
    /// restore, selection, or a background refresh.
    func acquireCopilotRuntimeAtUserRequest() async {
        await performCopilotRuntimeOperation(
            failureMessage: "Copilot runtime download did not complete. Check your connection and try Download or Repair again."
        ) { authorization in
            try await authorization.acquireRuntimeAtUserRequest()
        }
    }

    func startCopilotRuntimeAcquisitionAtUserRequest() {
        guard copilotRuntimeOperationTask == nil else { return }
        copilotRuntimeOperationTask = Task { [weak self] in
            guard let self else { return }
            await self.acquireCopilotRuntimeAtUserRequest()
            self.copilotRuntimeOperationTask = nil
        }
    }

    func repairCopilotRuntimeAtUserRequest() async {
        await performCopilotRuntimeOperation(
            failureMessage: "Copilot runtime repair did not complete. Try Repair again after checking local storage."
        ) { authorization in
            try await authorization.repairRuntimeAtUserRequest()
        }
    }

    func startCopilotRuntimeRepairAtUserRequest() {
        guard copilotRuntimeOperationTask == nil else { return }
        copilotRuntimeOperationTask = Task { [weak self] in
            guard let self else { return }
            await self.repairCopilotRuntimeAtUserRequest()
            self.copilotRuntimeOperationTask = nil
        }
    }

    func cancelCopilotRuntimeOperation() {
        copilotRuntimeOperationTask?.cancel()
    }

    func removeCopilotRuntimeAtUserRequest() async {
        guard !isCopilotRuntimeOperationInProgress else { return }
        do {
            try await dependencies.copilotRuntimeAuthorization.removeRuntimeAtUserRequest()
            await invalidateCopilotAuthorityForAllAccounts()
            await refreshSelectedOrganizationAIStatus()
        } catch {
            refreshError = "Copilot runtime could not be removed safely. Close any Copilot action and try Remove again."
            await refreshSelectedOrganizationAIStatus()
        }
    }

    private func performCopilotRuntimeOperation(
        failureMessage: String,
        operation: @escaping @Sendable (any CopilotRuntimeAuthorizationProviding) async throws -> Void
    ) async {
        guard !isCopilotRuntimeOperationInProgress else { return }
        copilotRuntimeOperationError = nil
        isCopilotRuntimeOperationInProgress = true
        let accountID = selectedAccountID
        let authorization = dependencies.copilotRuntimeAuthorization
        startCopilotRuntimeStateObservation(
            authorization: authorization,
            accountID: accountID
        )
        defer {
            copilotRuntimeStateObservationTask?.cancel()
            copilotRuntimeStateObservationTask = nil
            isCopilotRuntimeOperationInProgress = false
        }
        do {
            try await operation(authorization)
            await invalidateCopilotAuthorityForAllAccounts()
            await refreshSelectedOrganizationAIStatus()
        } catch is CancellationError {
            await refreshSelectedOrganizationAIStatus()
        } catch where Task.isCancelled {
            await refreshSelectedOrganizationAIStatus()
        } catch {
            copilotRuntimeOperationError = Self.copilotRuntimeOperationFailureMessage(
                for: error,
                fallback: failureMessage
            )
            await refreshSelectedOrganizationAIStatus()
        }
    }

    private static func copilotRuntimeOperationFailureMessage(
        for error: Error,
        fallback: String
    ) -> String {
        guard let error = error as? CopilotRuntimeAcquisitionError else { return fallback }
        return switch error {
        case .redirectRejected:
            "GitHub returned an unexpected runtime download location. Nothing was installed."
        case .invalidResponse:
            "GitHub did not return a valid runtime download. Nothing was installed."
        case .archiveTooLarge:
            "The runtime download exceeded Triage’s safety limit. Nothing was installed."
        case .checksumMismatch, .executableChecksumMismatch:
            "The downloaded runtime did not match Triage’s pinned checksum. Nothing was installed."
        case .invalidArchive, .executableMissing, .invalidExecutableArchitecture, .invalidCodeSignature:
            "The downloaded runtime failed verification. Nothing was installed."
        case .fileSystem:
            "Triage could not safely store the verified runtime. Check local storage and try again."
        case .unsupportedArchitecture:
            "This Mac’s processor is not supported by the approved Copilot runtime."
        case .invalidSource:
            "The pinned Copilot runtime source is invalid. Nothing was downloaded."
        case .cancellation:
            "The runtime download was cancelled. Nothing was installed."
        }
    }

    private func startCopilotRuntimeStateObservation(
        authorization: any CopilotRuntimeAuthorizationProviding,
        accountID: AccountID?
    ) {
        copilotRuntimeStateObservationTask?.cancel()
        copilotRuntimeStateObservationTask = Task { [weak self] in
            guard let states = await authorization.runtimeStateUpdates() else { return }
            for await runtime in states {
                guard !Task.isCancelled,
                      let self,
                      self.isCopilotRuntimeOperationInProgress,
                      self.selectedAccountID == accountID
                else { return }
                self.selectedCopilotAuthorizationState = .init(
                    runtime: runtime,
                    authentication: self.selectedCopilotAuthorizationState.authentication,
                    isEntitled: self.selectedCopilotAuthorizationState.isEntitled,
                    hasOrganizationConsent: self.selectedCopilotAuthorizationState.hasOrganizationConsent
                )
            }
        }
    }

    func authenticateSelectedCopilotAccountAtUserRequest() async {
        guard let account = accounts.first(where: { $0.id == selectedAccountID }),
              let organization = selectedOrganization
        else { return }
        let organizationID = organization.id
        let consent = organizationAISettingsByAccount[account.id]?[organizationID]?.consent.isEnabled ?? false
        let entitled = selectedAccountCapabilities?.status(for: .copilot) == .available
        copilotAuthenticationError = nil
        do {
            try await dependencies.copilotRuntimeAuthorization.authenticate(
                account: account,
                organizationID: organizationID,
                hasOrganizationConsent: consent,
                isEntitled: entitled
            )
            let models = try await dependencies.copilotRuntimeAuthorization.models(
                accountID: account.id,
                organizationID: organizationID
            )
            guard !isShuttingDown,
                  selectedAccountID == account.id,
                  selectedOrganizationID == organizationID,
                  !accountsBeingRemoved.contains(account.id)
            else { return }
            let context = try await aiContext(for: account, organization: organization)
            guard !isShuttingDown,
                  selectedAccountID == account.id,
                  selectedOrganizationID == organizationID,
                  !accountsBeingRemoved.contains(account.id)
            else { return }
            try await context.controller.replaceModels(
                models,
                for: context.scope,
                expiresAt: Date.now.addingTimeInterval(AIAnalysisRepository.maximumModelCacheLifetime)
            )
            guard !isShuttingDown,
                  selectedAccountID == account.id,
                  selectedOrganizationID == organizationID,
                  !accountsBeingRemoved.contains(account.id)
            else { return }
            await refreshSelectedOrganizationAIStatus()
        } catch CopilotAuthenticationError.identityMismatch {
            copilotAuthenticationError = "Copilot signed in to a different GitHub account. Re-authenticate the selected Triage account."
            await refreshSelectedOrganizationAIStatus()
        } catch CopilotAuthenticationError.copilotIdentityMismatch {
            copilotAuthenticationError = "Copilot did not verify the selected github.com account. Re-authenticate Copilot for this Triage account."
            await refreshSelectedOrganizationAIStatus()
        } catch CopilotAuthenticationError.runtimeUnavailable {
            copilotAuthenticationError = "The approved Copilot runtime is missing or failed validation. Download or Repair the runtime, then authenticate again."
            await refreshSelectedOrganizationAIStatus()
        } catch CopilotAuthenticationError.consentRequired {
            copilotAuthenticationError = "Allow AI analysis for this organization before authenticating Copilot."
        } catch CopilotAuthenticationError.entitlementRequired {
            copilotAuthenticationError = "Copilot entitlement is not verified for this organization."
        } catch CopilotAuthenticationError.deviceLoginUnavailable {
            copilotAuthenticationError = "This classic personal access token remains limited to read-only GitHub synchronization and is never sent to Copilot. A separate Copilot OAuth sign-in is not yet available in this build."
            await refreshSelectedOrganizationAIStatus()
        } catch {
            copilotAuthenticationError = "Copilot authentication could not be completed. Re-authenticate the selected GitHub account, then try again."
            await refreshSelectedOrganizationAIStatus()
        }
    }

    /// Notification responses are scoped local-workflow commands. They first
    /// select the exact account and organization encoded by the signed local
    /// payload, then invoke the same encrypted-vault mutation boundary as the
    /// visible UI. No response makes a GitHub request or changes GitHub
    /// notification state.
    func handleNotificationLocalAction(_ action: NotificationLocalAction) async {
        guard !isShuttingDown else { return }
        let route: NotificationRoute
        switch action {
        case let .openTriage(value), let .snoozeOneHour(value, _), let .archiveInTriage(value):
            route = value
        }
        guard accounts.contains(where: { $0.id == route.accountID }),
              organizationsByAccount[route.accountID]?.contains(where: { $0.id == route.organizationID }) == true,
              !accountsBeingRemoved.contains(route.accountID)
        else {
            return
        }

        if usesInMemoryUITestFixture {
            if selectedAccountID != route.accountID {
                selectAccount(route.accountID, activatesOrganization: false)
            }
            if selectedOrganizationID != route.organizationID {
                selectOrganization(route.organizationID)
            }
            guard workItems.contains(where: { $0.id == route.workItemID }) else { return }
            selectedWorkItemID = route.workItemID
            return
        }

        do {
            let scope = try await synchronizationScope(
                accountID: route.accountID,
                organizationID: route.organizationID
            )
            guard !isShuttingDown, !accountsBeingRemoved.contains(route.accountID) else { return }
            guard let workItem = try await workItem(route.workItemID, in: scope) else {
                return
            }
            guard !isShuttingDown, !accountsBeingRemoved.contains(route.accountID) else { return }
            switch action {
            case .openTriage:
                break
            case .snoozeOneHour, .archiveInTriage:
                guard NotificationActionAuthorizationValidator.matches(route: route, workItem: workItem) else {
                    return
                }
            }
            guard !isShuttingDown, !accountsBeingRemoved.contains(route.accountID) else { return }
            if selectedAccountID != route.accountID {
                selectAccount(route.accountID, activatesOrganization: false)
            }
            guard !isShuttingDown, !accountsBeingRemoved.contains(route.accountID) else { return }
            if selectedOrganizationID != route.organizationID {
                selectOrganization(route.organizationID)
            } else {
                activateSelectedOrganization()
            }
            guard !isShuttingDown, !accountsBeingRemoved.contains(route.accountID) else { return }
            selectedWorkItemID = route.workItemID
            switch action {
            case .openTriage:
                return
            case let .snoozeOneHour(_, until):
                guard !isShuttingDown, !accountsBeingRemoved.contains(route.accountID) else { return }
                guard let authorization = route.actionAuthorization else { return }
                try await dependencies.workspaceMutator.applyNotificationAction(
                    .snooze(until: until),
                    to: route.workItemID,
                    in: scope,
                    expectedAuthorization: authorization
                )
                guard !isShuttingDown, !accountsBeingRemoved.contains(route.accountID) else { return }
            case .archiveInTriage:
                guard !isShuttingDown, !accountsBeingRemoved.contains(route.accountID) else { return }
                guard let authorization = route.actionAuthorization else { return }
                try await dependencies.workspaceMutator.applyNotificationAction(
                    .archive,
                    to: route.workItemID,
                    in: scope,
                    expectedAuthorization: authorization
                )
                guard !isShuttingDown, !accountsBeingRemoved.contains(route.accountID) else { return }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !isShuttingDown, !accountsBeingRemoved.contains(route.accountID) else { return }
            refreshError = "Triage could not apply this local notification action."
        }
    }

    private func rebuildSearchIndex(for workItem: WorkItem) async throws {
        let secretStore = KeychainSecretStore()
        guard let vaultKey = try await secretStore.readVaultKey(for: workItem.accountID) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        let vault = try await requiredVaultRegistry().open(accountID: workItem.accountID, vaultKey: vaultKey)
        try await rebuildSearchIndex(
            in: vault,
            accountID: workItem.accountID,
            organizationID: workItem.organizationID
        )
    }

    private func rebuildSearchIndex(
        in vault: AccountVault,
        accountID: AccountID,
        organizationID: OrganizationID
    ) async throws {
        try await SearchRepository(vault: vault).rebuild(
            accountID: accountID,
            organizationID: organizationID
        )
    }

    private func activateSelectedOrganization() {
        guard !isShuttingDown else { return }
        guard !usesInMemoryUITestFixture else {
            presentCachedWorkItems()
            return
        }
        guard let accountID = selectedAccountID,
              let organizationID = selectedOrganizationID
        else { return }
        workspaceActivation.replace { [weak self] generation in
            guard let self,
                  self.workspaceActivation.isCurrent(generation),
                  self.selectedAccountID == accountID,
                  self.selectedOrganizationID == organizationID
            else { return }
            await self.loadCachedSelectedOrganization(
                accountID: accountID,
                organizationID: organizationID,
                activationGeneration: generation
            )
            guard self.workspaceActivation.isCurrent(generation),
                  self.selectedAccountID == accountID,
                  self.selectedOrganizationID == organizationID
            else { return }
            await self.recheckSelectedOrganizationAccess()
        }
    }

    func refreshSelectedOrganizationAfterAccessCheck() async {
        guard !usesInMemoryUITestFixture else { return }
        guard let access = selectedOrganizationAccess else {
            await recheckSelectedOrganizationAccess()
            return
        }
        switch access.state {
        case .ssoAuthorizationRequired, .partialSSOAuthorization:
            await recheckSelectedOrganizationAccess()
        default:
            if Date().timeIntervalSince(access.checkedAt) >= RefreshCadence.dailyCapabilityProbe.baseInterval {
                await recheckSelectedOrganizationAccess()
            } else {
                await refreshSelectedOrganization()
            }
        }
    }

    private func recordOrganizationRefreshFailure(
        _ error: OrganizationRefreshError,
        for account: GitHubAccount,
        organization: GitHubOrganization
    ) async {
        let header: GitHubSSOHeader
        switch error {
        case let .ssoRequirement(value):
            header = value
        }
        let state = OrganizationAccessEvaluator.state(statusCode: 200, ssoHeader: header)
        let checkedAt = Date()
        let capabilities = GitHubCapability.allCases
            .filter { $0.scope == .organization }
            .map { capability in
            CapabilityAvailability(
                capability: capability,
                status: state == .ssoAuthorizationRequired || state == .partialSSOAuthorization
                    ? .requiresSSO
                    : .unknown,
                checkedAt: checkedAt
            )
            }
        let access = OrganizationAccess(
            accountID: account.id,
            organizationID: organization.id,
            state: state,
            capabilityRevision: CapabilityRevision(rawValue: UUID().uuidString.lowercased())!,
            capabilities: capabilities,
            checkedAt: checkedAt
        )
        do {
            let secretStore = KeychainSecretStore()
            let vaultKey = try await requiredVaultKey(for: account, secretStore: secretStore)
            let vault = try await requiredVaultRegistry().open(accountID: account.id, vaultKey: vaultKey)
            try await AccountRepository(vault: vault).save(organization, access: access)
            guard accounts.contains(where: { $0.id == account.id }),
                  !accountsBeingRemoved.contains(account.id)
            else {
                return
            }
            let previousAccess = organizationAccessesByAccount[account.id]?[organization.id]
            organizationAccessesByAccount[account.id, default: [:]][organization.id] = access
            if previousAccess?.capabilityRevision != access.capabilityRevision {
                invalidateCachedWorkspaceAuthority(for: account.id, organizationID: organization.id)
            }
            guard selectedAccountID == account.id, selectedOrganizationID == organization.id else {
                return
            }
            ssoAuthorizationHeader = header
            refreshError = accessMessage(for: state)
        } catch is CancellationError {
            return
        } catch {
            guard selectedAccountID == account.id, selectedOrganizationID == organization.id else {
                return
            }
            refreshError = "Triage could not record organization access. Cached work remains available."
        }
    }

    private func presentCachedWorkItems() {
        guard let accountID = selectedAccountID,
              let organizationID = selectedOrganizationID,
              let scope = cachedWorkspaceScopes[accountID]?[organizationID],
              let cachedWorkItems = cachedWorkItems[scope]
        else {
            present(workItems: [])
            return
        }
        inboxPageSnapshot = cachedInboxPageSnapshots[scope]
        inboxPage = cachedInboxPages[scope]
        inboxPageHasMore = inboxPageSnapshot?.hasMore ?? false
        inboxPageEvaluatedAt = inboxPageSnapshot?.evaluatedAt
        present(workItems: cachedWorkItems)
    }

    /// A credential or capability revision rotation invalidates cached
    /// projections bound to the superseded authority. The currently visible
    /// projection remains until its replacement arrives, but cannot be reused
    /// by a later account or organization switch.
    private func invalidateCachedWorkspaceAuthority(for accountID: AccountID) {
        cachedWorkItems.removeAll(for: accountID)
        cachedInboxPages.removeAll(for: accountID)
        cachedInboxPageSnapshots.removeAll(for: accountID)
        cachedWorkspaceScopes[accountID] = nil
        if workspaceObservationScope?.accountID == accountID {
            invalidateWorkspaceObservation()
        }
    }

    private func invalidateCachedWorkspaceAuthority(
        for accountID: AccountID,
        organizationID: OrganizationID
    ) {
        cachedWorkItems.removeAll(for: accountID, organizationID: organizationID)
        cachedInboxPages.removeAll(for: accountID, organizationID: organizationID)
        cachedInboxPageSnapshots.removeAll(for: accountID, organizationID: organizationID)
        cachedWorkspaceScopes[accountID]?[organizationID] = nil
        if cachedWorkspaceScopes[accountID]?.isEmpty == true {
            cachedWorkspaceScopes[accountID] = nil
        }
        if workspaceObservationScope?.accountID == accountID,
           workspaceObservationScope?.organizationID == organizationID {
            invalidateWorkspaceObservation()
        }
    }

    private func lifecycleSynchronizationScopes() async -> [SynchronizationScope] {
        guard !isShuttingDown, !isCredentialMutationInProgress else { return [] }
        var candidates: [(AccountID, OrganizationID)] = []
        for account in accounts where account.credentialStatus == .active
            && !accountsBeingRemoved.contains(account.id)
        {
            for organization in organizationsByAccount[account.id] ?? [] {
                guard organizationAccessesByAccount[account.id]?[organization.id]?.state == .available else {
                    continue
                }
                candidates.append((account.id, organization.id))
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.0.rawValue != rhs.0.rawValue {
                return lhs.0.rawValue < rhs.0.rawValue
            }
            return lhs.1.rawValue < rhs.1.rawValue
        }
        var scopes = [SynchronizationScope]()
        for (accountID, organizationID) in candidates {
            guard !Task.isCancelled,
                  accounts.contains(where: { $0.id == accountID }),
                  !accountsBeingRemoved.contains(accountID)
            else {
                return []
            }
            do {
                let scope = try await synchronizationScope(
                    accountID: accountID,
                    organizationID: organizationID
                )
                guard !Task.isCancelled,
                      !accountsBeingRemoved.contains(accountID)
                else {
                    return []
                }
                scopes.append(scope)
            } catch is CancellationError {
                return []
            } catch {
                // A scope without a current vault revision is intentionally
                // omitted; lifecycle refresh never guesses authority.
                continue
            }
        }
        return scopes
    }

    private func requiredVaultRegistry() throws -> VaultRegistry {
        vaultRegistry
    }

    private func synchronizationScope(for workItem: WorkItem) async throws -> SynchronizationScope {
        try await synchronizationScope(
            accountID: workItem.accountID,
            organizationID: workItem.organizationID
        )
    }

    private func synchronizationScope(
        accountID: AccountID,
        organizationID: OrganizationID
    ) async throws -> SynchronizationScope {
        let secretStore = KeychainSecretStore()
        guard let vaultKey = try await secretStore.readVaultKey(for: accountID) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        let vault = try await vaultRegistry.open(accountID: accountID, vaultKey: vaultKey)
        return try await AccountRepository(vault: vault).synchronizationScope(
            for: accountID,
            organizationID: organizationID
        )
    }

    private func aiContext(
        for account: GitHubAccount,
        organization: GitHubOrganization
    ) async throws -> (scope: SynchronizationScope, controller: OrganizationAIController) {
        let secretStore = KeychainSecretStore()
        let vaultKey = try await requiredVaultKey(for: account, secretStore: secretStore)
        let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
        let scope = try await AccountRepository(vault: vault).synchronizationScope(
            for: account.id,
            organizationID: organization.id
        )
        return (scope, await dependencies.organizationAIControllers.controller(for: vault))
    }

    /// Replacing a GitHub credential or runtime makes every retained helper
    /// session and cached model capability for that account stale.  Teardown
    /// proceeds even if the vault is no longer readable; retaining a Copilot
    /// session is never a fallback for unavailable local storage.
    private func invalidateCopilotAuthority(for account: GitHubAccount) async {
        await dependencies.copilotRuntimeAuthorization.disconnect(accountID: account.id)
        await dependencies.organizationAIControllers.evict(accountID: account.id)
        organizationAISettingsByAccount[account.id] = nil
        do {
            let secretStore = KeychainSecretStore()
            let vaultKey = try await requiredVaultKey(for: account, secretStore: secretStore)
            let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
            let controller = await dependencies.organizationAIControllers.controller(for: vault)
            try await controller.invalidateModelCaches(for: account.id)
        } catch {
            // The retained session is already gone.  A missing or unreadable
            // vault cannot be used as authority for cached Copilot models.
        }
    }

    private func invalidateCopilotAuthorityForAllAccounts() async {
        for account in accounts where !accountsBeingRemoved.contains(account.id) {
            await invalidateCopilotAuthority(for: account)
        }
    }

    private static func aiSettingsState(
        policy: OrganizationAIExecutionPolicy,
        availableModels: [CopilotModel] = [],
        modelSelectionNotice: String? = nil
    ) -> OrganizationAISettingsState {
        let status: String
        if !policy.consent.isEnabled {
            status = "Consent is disabled. Triage will not send organization content for AI analysis."
        } else if !policy.permitsAnalysis {
            status = "Copilot runtime, identity, entitlement, budget, or model availability is not verified. AI analysis is blocked."
        } else {
            status = "AI analysis is authorized for this organization."
        }
        return .init(
            consent: policy.consent,
            isEffectivelyAvailable: policy.permitsAnalysis,
            status: status,
            availableModels: availableModels,
            modelSelectionNotice: modelSelectionNotice
        )
    }

    private func workItem(
        _ workItemID: WorkItemID,
        in scope: SynchronizationScope
    ) async throws -> WorkItem? {
        let secretStore = KeychainSecretStore()
        guard let vaultKey = try await secretStore.readVaultKey(for: scope.accountID) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        let vault = try await vaultRegistry.open(accountID: scope.accountID, vaultKey: vaultKey)
        return try await WorkItemRepository(vault: vault).fetch(
            accountID: scope.accountID,
            organizationID: scope.organizationID
        ).first { $0.id == workItemID }
    }

    private func requiredVaultKey(
        for account: GitHubAccount,
        secretStore: KeychainSecretStore
    ) async throws -> VaultKey {
        guard let vaultKey = try await secretStore.readVaultKey(for: account.id) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        return vaultKey
    }

    private func accessMessage(for state: OrganizationAccessState) -> String {
        switch state {
        case .ssoAuthorizationRequired:
            "GitHub requires SSO authorization for this organization."
        case .partialSSOAuthorization:
            "GitHub returned partial organization access. Cached work remains available."
        case .organizationApprovalRequired, .oauthApplicationApprovalRequired:
            "GitHub requires organization approval for this account."
        case .organizationPolicyBlocked:
            "This organization blocks access for the current credential."
        case .insufficientPermission:
            "This credential does not have enough access for this organization."
        case .inaccessible:
            "This organization is no longer accessible with the current credential."
        case .credentialExpired:
            "This credential has expired. Reconnect the account to continue."
        case .available, .unknown:
            "Triage could not confirm organization access. Cached work remains available."
        }
    }
}
