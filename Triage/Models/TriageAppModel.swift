import AppKit
import Foundation

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
    @Published private(set) var organizationsByAccount: [AccountID: [GitHubOrganization]] = [:]
    @Published private(set) var organizationAccessesByAccount: [AccountID: [OrganizationID: OrganizationAccess]] = [:]
    @Published private(set) var accountCapabilitiesByAccount: [AccountID: AccountCapabilitySnapshot] = [:]
    @Published private(set) var workItems: [WorkItem] = []
    @Published var selectedAccountID: AccountID? {
        didSet { defaults.set(selectedAccountID?.rawValue, forKey: PreferenceKey.selectedAccountID) }
    }
    @Published var selectedOrganizationID: OrganizationID? {
        didSet { defaults.set(selectedOrganizationID?.rawValue, forKey: PreferenceKey.selectedOrganizationID) }
    }
    @Published var selectedWorkItemID: WorkItemID?
    @Published private(set) var connectionError: String?
    @Published private(set) var credentialActionNotice: String?
    @Published private(set) var refreshError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isConnecting = false
    @Published private(set) var restorationError: String?
    /// Scoped to the currently selected workspace. Account-session recovery
    /// notices remain in `restorationError` and must not make a later,
    /// successfully loaded organization appear unavailable.
    @Published private(set) var workspaceRestorationError: String?
    @Published private(set) var ssoAuthorizationHeader: GitHubSSOHeader?
    @Published private(set) var selectedOrganizationFreshness: FreshnessState?
    @Published private(set) var selectedWorkspaceCoverage: CoverageEvaluation?

    private let oauthAuthorizer = GitHubOAuthAuthorizer()
    private let refreshScheduler = ActiveRefreshScheduler()
    private let inactiveRefreshScheduler = ActiveRefreshScheduler()
    private let capabilityRefreshScheduler = ActiveRefreshScheduler()
    private let defaults: UserDefaults
    private let dependencies: TriageApplicationDependencies
    private let vaultRegistry: VaultRegistry
    private let workspaceAccessibility: WorkspaceAccessibilityCoordinator?
    private var refreshGeneration = 0
    private var backgroundRefreshGeneration: UInt64 = 0
    private var accountsBeingRemoved: Set<AccountID> = []
    private var foregroundRefreshTask: Task<ForegroundRefreshResult, Never>?
    private var foregroundRefreshTaskID: UUID?
    private var foregroundRefreshTasksAwaitingCredentialMutation: [Task<ForegroundRefreshResult, Never>] = []
    private var foregroundRefreshTasksAwaitingAccountRemoval: [AccountID: [Task<ForegroundRefreshResult, Never>]] = [:]
    private var isCredentialMutationInProgress = false
    private var isShuttingDown = false
    private var cachedWorkItems = WorkspacePresentationCache<[WorkItem]>()
    /// The most recently installed revision-qualified scope for each cached
    /// workspace. This remains independent from the live observation scope:
    /// selection invalidates the latter before showing cached content, while
    /// this map keeps the cache lookup bound to its original authority.
    private var cachedWorkspaceScopes: [AccountID: [OrganizationID: SynchronizationScope]] = [:]
    private let workspaceActivation = WorkspaceActivationTaskController()
    private var workspaceObservationTask: Task<Void, Never>?
    private var workspaceSelectionGeneration: UInt64 = 0
    private var workspaceObservationScope: SynchronizationScope?

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

    init(
        dependencies: TriageApplicationDependencies,
        vaultRegistry: VaultRegistry,
        defaults: UserDefaults = .standard,
        workspaceAccessibility: WorkspaceAccessibilityCoordinator? = nil
    ) {
        self.dependencies = dependencies
        self.vaultRegistry = vaultRegistry
        self.defaults = defaults
        self.workspaceAccessibility = workspaceAccessibility
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

    private func install(session: AccountSessionSnapshot) async {
        await cancelForegroundRefresh()
        await workspaceActivation.cancelAndWait()
        await cancelWorkspaceObservationAndWait()
        cachedWorkItems = WorkspacePresentationCache()
        cachedWorkspaceScopes = [:]
        workspaceRestorationError = nil
        accounts = session.accounts
        organizationsByAccount = session.organizationsByAccount
        organizationAccessesByAccount = session.organizationAccessesByAccount
        accountCapabilitiesByAccount = session.accountCapabilitiesByAccount
        credentialActionNotice = session.credentialActionNotice
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
        cachedWorkItems[scope] = workItems
        cachedWorkspaceScopes[scope.accountID, default: [:]][scope.organizationID] = scope
        if selectedAccountID == scope.accountID, selectedOrganizationID == scope.organizationID {
            workspaceRestorationError = nil
        }
        present(workItems: workItems)
    }

    private func present(workItems: [WorkItem]) {
        self.workItems = workItems
        if !workItems.contains(where: { $0.id == selectedWorkItemID }) {
            selectedWorkItemID = workItems.first?.id
        }

    }

    private func replaceWorkspaceObservation(
        for scope: SynchronizationScope
    ) {
        workspaceSelectionGeneration &+= 1
        let generation = workspaceSelectionGeneration
        let previousTask = workspaceObservationTask
        previousTask?.cancel()
        workspaceObservationScope = scope
        workspaceObservationTask = Task { [weak self, dependencies] in
            if let previousTask {
                await previousTask.value
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

    private func invalidateWorkspaceObservation() {
        workspaceSelectionGeneration &+= 1
        workspaceObservationTask?.cancel()
        workspaceObservationTask = nil
        workspaceObservationScope = nil
        selectedWorkspaceCoverage = nil
    }

    private func cancelWorkspaceObservationAndWait() async {
        workspaceSelectionGeneration &+= 1
        let task = workspaceObservationTask
        workspaceObservationTask = nil
        workspaceObservationScope = nil
        task?.cancel()
        if let task {
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
        cachedWorkItems[scope] = snapshot.workItems
        cachedWorkspaceScopes[scope.accountID, default: [:]][scope.organizationID] = scope
        selectedOrganizationFreshness = snapshot.durableState.freshness
        selectedWorkspaceCoverage = snapshot.coverageEvaluation
        present(workItems: snapshot.workItems)
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
        let vault = try await requiredVaultRegistry().open(accountID: account.id, vaultKey: vaultKey)
        return try await SearchRepository(vault: vault).search(
            query,
            accountID: account.id,
            organizationID: organization.id
        )
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
        guard accounts.contains(where: { $0.id == accountID }) else { return }

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
        try await dependencies.accountSession.removeAccount(accountID)

        accounts.removeAll { $0.id == accountID }
        organizationsByAccount[accountID] = nil
        organizationAccessesByAccount[accountID] = nil
        accountCapabilitiesByAccount[accountID] = nil
        cachedWorkItems.removeAll(for: accountID)
        cachedWorkspaceScopes[accountID] = nil
        if isRemovingSelectedAccount {
            selectedAccountID = accounts.first?.id
            selectedOrganizationID = selectedAccountID
                .flatMap { organizationsByAccount[$0]?.first?.id }
            presentCachedWorkItems()
            activateSelectedOrganization()
        }
    }

    var selectedWorkItem: WorkItem? {
        workItems.first { $0.id == selectedWorkItemID }
    }

    func connectGitHub(presentationAnchor: NSWindow) async {
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
            }
        } catch is CancellationError {
            return
        } catch {
            connectionError = "GitHub sign-in could not be completed. Try again."
        }
    }

    func connectPersonalAccessToken(
        _ rawValue: String,
        resourceOwnerOrganization: String?
    ) async {
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
        } catch {
            connectionError = "Triage could not validate this personal access token. Check its access and try again."
        }
    }

    func reconnectGitHub(
        account: GitHubAccount,
        presentationAnchor: NSWindow
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
            await cancelForegroundRefresh()
            await cancelForegroundRefreshes(for: account.id)
            let configuration = try RuntimeOAuthConfiguration()
            let request = try await oauthAuthorizer.authorize(
                configuration: configuration.oauth,
                presentationAnchor: presentationAnchor
            )
            let snapshot = try await dependencies.accountSession.reconnectOAuth(request, replacing: account)
            await install(session: snapshot)
            isCredentialMutationInProgress = false
            await recheckSelectedOrganizationAccess()
        } catch let error as AccountCredentialReplacementError {
            connectionError = credentialReplacementMessage(for: error)
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
        } catch let error as RuntimeOAuthConfigurationError {
            switch error {
            case .missingClientID:
                connectionError = "GitHub sign-in is not configured in this build."
            case .invalidBrokerURL:
                connectionError = "The GitHub sign-in service is not configured securely."
            }
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
        } catch is CancellationError {
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
            return
        } catch {
            connectionError = "GitHub reconnect could not be completed. Try again."
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
            await cancelForegroundRefresh()
            await cancelForegroundRefreshes(for: account.id)
            let snapshot = try await dependencies.accountSession.replacePersonalAccessToken(
                try PersonalAccessToken(rawValue: rawValue),
                replacing: account
            )
            await install(session: snapshot)
            isCredentialMutationInProgress = false
            await recheckSelectedOrganizationAccess()
        } catch let error as PersonalAccessTokenError {
            switch error {
            case .unsupportedTokenFormat:
                connectionError = "Enter a supported personal access token for this account."
            }
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
        } catch let error as AccountCredentialReplacementError {
            connectionError = credentialReplacementMessage(for: error)
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
        } catch is CancellationError {
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
            return
        } catch {
            connectionError = "Triage could not replace this personal access token. Check its access and try again."
            isCredentialMutationInProgress = false
            await resumeSelectedOrganization()
        }
    }

    func recordConnectionWindowError() {
        connectionError = "Triage could not find its active window."
    }

    func startAutomaticRefreshes() async {
        guard !isShuttingDown else { return }
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
            let inventoryReplay = PostAccountOrganizationInventoryReplayService(
                client: identityClient,
                receipts: PostAccountIdentityReplayReceiptRepository(vault: vault)
            )
            let result = try await DailyActiveAccountIdentityRefreshService(
                vault: vault,
                loadAuthenticatedUser: {
                    try await identityClient.authenticatedUser().value
                },
                loadOrganizationInventory: { accountID, credentialRevision in
                    try await inventoryReplay.organizations(
                        accountID: accountID,
                        credentialRevision: credentialRevision
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
            case let .refreshed(snapshot), let .inventoryUnavailable(snapshot):
                replaceDailyIdentitySnapshot(snapshot)
            case let .credentialRevoked(revoked):
                if let index = accounts.firstIndex(where: { $0.id == revoked.id }) {
                    accounts[index] = revoked
                }
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
        let scopes = await lifecycleSynchronizationScopes()
        await dependencies.refreshLifecycle.launch(
            synchronizationScopes: scopes,
            activeAccountID: selectedAccountID
        )
    }

    func applicationDidBecomeActive() async {
        guard !isShuttingDown else { return }
        let scopes = await lifecycleSynchronizationScopes()
        await dependencies.refreshLifecycle.applicationDidBecomeActive(
            synchronizationScopes: scopes,
            activeAccountID: selectedAccountID
        )
    }

    func handleSystemWake() async {
        guard !isShuttingDown else { return }
        let scopes = await lifecycleSynchronizationScopes()
        await dependencies.refreshLifecycle.wake(
            synchronizationScopes: scopes,
            activeAccountID: selectedAccountID
        )
    }

    func scheduleOpportunisticBackgroundRefresh() async {
        guard !isShuttingDown else { return }
        let scopes = await lifecycleSynchronizationScopes()
        await dependencies.refreshLifecycle.scheduleOpportunisticBackgroundRefresh(
            synchronizationScopes: scopes,
            activeAccountID: selectedAccountID
        )
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
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

    func restoreAccounts() async {
        do {
            let result = try await dependencies.accountSession.restoreAccounts()
            await install(session: result)
            if !result.accounts.contains(where: { $0.id == selectedAccountID }) {
                selectedAccountID = result.accounts.first?.id
            }
            if !organizations.contains(where: { $0.id == selectedOrganizationID }) {
                selectedOrganizationID = organizations.first?.id
            }
            activateSelectedOrganization()
            if !result.unavailableAccountIDs.isEmpty {
                restorationError = "One or more connected accounts need to be reconnected."
            }
        } catch is CancellationError {
            return
        } catch {
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
            let workItems = try await WorkItemRepository(vault: vault).fetch(
                accountID: account.id,
                organizationID: organization.id
            )
            try await rebuildSearchIndex(in: vault, accountID: account.id, organizationID: organization.id)
            guard
                refreshGeneration == generation,
                selectedAccountID == account.id,
                selectedOrganizationID == organization.id
            else {
                return
            }
            selectedOrganizationFreshness = coordinatorState?.freshness
            install(
                workItems: workItems,
                scope: scope
            )
            replaceWorkspaceObservation(for: scope)
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
        case .invalidGitHubIdentity:
            "GitHub returned an invalid account identity. The connected profile was not changed."
        case .stagedCredentialCleanupFailed:
            "Triage could not safely clear a staged Keychain credential. The connected profile was not changed."
        }
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
            let workItems = try await WorkItemRepository(vault: vault).fetch(
                accountID: account.id,
                organizationID: organization.id
            )
            try Task.checkCancellation()
            guard workspaceActivation.isCurrent(activationGeneration) else { return }
            try await rebuildSearchIndex(in: vault, accountID: account.id, organizationID: organization.id)
            try Task.checkCancellation()
            guard
                refreshGeneration == generation,
                selectedAccountID == account.id,
                selectedOrganizationID == organization.id,
                workspaceActivation.isCurrent(activationGeneration)
            else {
                return
            }
            let scope = try await AccountRepository(vault: vault).synchronizationScope(
                for: account.id,
                organizationID: organization.id
            )
            try Task.checkCancellation()
            guard workspaceActivation.isCurrent(activationGeneration) else { return }
            install(workItems: workItems, scope: scope)
            replaceWorkspaceObservation(for: scope)
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
        guard !accountsBeingRemoved.contains(workItem.accountID) else { return }
        do {
            let scope = try await synchronizationScope(for: workItem)
            try await dependencies.workspaceMutator.apply(action, to: workItem.id, in: scope)
            workspaceAccessibility?.workflowCompleted(action)
        } catch {
            refreshError = "Triage could not save this local workflow change."
        }
    }

    func completeActionItem(_ actionItem: ActionItem, in workItem: WorkItem) async {
        guard !accountsBeingRemoved.contains(workItem.accountID) else { return }
        do {
            let scope = try await synchronizationScope(for: workItem)
            try await dependencies.workspaceMutator.completeActionItem(
                actionItem.id,
                in: workItem.id,
                scope: scope
            )
            workspaceAccessibility?.actionItemCompleted()
        } catch {
            refreshError = "Triage could not complete this local action item."
        }
    }

    /// Notification responses are scoped local-workflow commands. They first
    /// select the exact account and organization encoded by the signed local
    /// payload, then invoke the same encrypted-vault mutation boundary as the
    /// visible UI. No response makes a GitHub request or changes GitHub
    /// notification state.
    func handleNotificationLocalAction(_ action: NotificationLocalAction) async {
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

        do {
            let scope = try await synchronizationScope(
                accountID: route.accountID,
                organizationID: route.organizationID
            )
            guard try await containsWorkItem(route.workItemID, in: scope) else {
                return
            }
            if selectedAccountID != route.accountID {
                selectAccount(route.accountID, activatesOrganization: false)
            }
            if selectedOrganizationID != route.organizationID {
                selectOrganization(route.organizationID)
            } else {
                activateSelectedOrganization()
            }
            selectedWorkItemID = route.workItemID
            switch action {
            case .openTriage:
                return
            case let .snoozeOneHour(_, until):
                try await dependencies.workspaceMutator.apply(
                    .snooze(until: until),
                    to: route.workItemID,
                    in: scope
                )
            case .archiveInTriage:
                try await dependencies.workspaceMutator.apply(
                    .archive,
                    to: route.workItemID,
                    in: scope
                )
            }
        } catch is CancellationError {
            return
        } catch {
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
        present(workItems: cachedWorkItems)
    }

    /// A credential or capability revision rotation invalidates cached
    /// projections bound to the superseded authority. The currently visible
    /// projection remains until its replacement arrives, but cannot be reused
    /// by a later account or organization switch.
    private func invalidateCachedWorkspaceAuthority(for accountID: AccountID) {
        cachedWorkItems.removeAll(for: accountID)
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

    private func containsWorkItem(
        _ workItemID: WorkItemID,
        in scope: SynchronizationScope
    ) async throws -> Bool {
        let secretStore = KeychainSecretStore()
        guard let vaultKey = try await secretStore.readVaultKey(for: scope.accountID) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        let vault = try await vaultRegistry.open(accountID: scope.accountID, vaultKey: vaultKey)
        return try await WorkItemRepository(vault: vault).fetch(
            accountID: scope.accountID,
            organizationID: scope.organizationID
        ).contains { $0.id == workItemID }
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
