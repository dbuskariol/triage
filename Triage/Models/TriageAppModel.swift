import AppKit
import Foundation

@MainActor
final class TriageAppModel: ObservableObject {
    private enum PreferenceKey {
        static let selectedAccountID = "workspace.selected-account-id"
        static let selectedOrganizationID = "workspace.selected-organization-id"
    }

    @Published private(set) var accounts: [GitHubAccount] = []
    @Published private(set) var organizationsByAccount: [AccountID: [GitHubOrganization]] = [:]
    @Published private(set) var organizationAccessesByAccount: [AccountID: [OrganizationID: OrganizationAccess]] = [:]
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
    @Published private(set) var ssoAuthorizationHeader: GitHubSSOHeader?

    private let oauthAuthorizer = GitHubOAuthAuthorizer()
    private let refreshScheduler = ActiveRefreshScheduler()
    private let inactiveRefreshScheduler = ActiveRefreshScheduler()
    private let organizationSyncCoordinator = OrganizationSyncCoordinator()
    private let defaults: UserDefaults
    private let vaultRegistry: VaultRegistry?
    private let vaultRegistryInitializationError: Error?
    private var refreshGeneration = 0
    private var backgroundRefreshGeneration: UInt64 = 0
    private var accountsBeingRemoved: Set<AccountID> = []
    private var foregroundRefreshTask: Task<Void, Never>?
    private var foregroundRefreshTaskID: UUID?
    private var foregroundRefreshTasksAwaitingCredentialMutation: [Task<Void, Never>] = []
    private var foregroundRefreshTasksAwaitingAccountRemoval: [AccountID: [Task<Void, Never>]] = [:]
    private var isCredentialMutationInProgress = false
    private var cachedWorkItems = WorkspacePresentationCache<[WorkItem]>()

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        do {
            vaultRegistry = try VaultRegistry()
            vaultRegistryInitializationError = nil
        } catch {
            vaultRegistry = nil
            vaultRegistryInitializationError = error
        }
        selectedAccountID = defaults.string(forKey: PreferenceKey.selectedAccountID)
            .flatMap(AccountID.init(rawValue:))
        selectedOrganizationID = defaults.string(forKey: PreferenceKey.selectedOrganizationID)
            .flatMap(OrganizationID.init(rawValue:))
    }

    func install(
        accounts: [GitHubAccount],
        organizations: [GitHubOrganization],
        organizationAccesses: [OrganizationID: OrganizationAccess],
        for accountID: AccountID
    ) {
        self.accounts = accounts
        organizationsByAccount[accountID] = organizations
        organizationAccessesByAccount[accountID] = organizationAccesses
        selectedAccountID = accountID
        selectedOrganizationID = organizations.first?.id
    }

    func install(
        workItems: [WorkItem],
        accountID: AccountID,
        organizationID: OrganizationID
    ) {
        cachedWorkItems[accountID, organizationID] = workItems
        present(workItems: workItems)
    }

    private func present(workItems: [WorkItem]) {
        self.workItems = workItems
        if !workItems.contains(where: { $0.id == selectedWorkItemID }) {
            selectedWorkItemID = workItems.first?.id
        }

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
        }
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
            await cancelForegroundRefresh()
        }
        await cancelForegroundRefreshes(for: accountID)
        await cancelInactiveRefreshes(for: accountID)
        let fileManager = FileManager.default
        let applicationSupportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cachesDirectory = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try await AccountDataRemovalService(
            vaultRegistry: try requiredVaultRegistry(),
            secretStore: KeychainSecretStore(),
            applicationSupportDirectory: applicationSupportDirectory,
            cachesDirectory: cachesDirectory
        ).removeAllPrivateData(for: accountID)
        await GitHubRateLimitControllerRegistry.shared.removeController(for: accountID)

        accounts.removeAll { $0.id == accountID }
        organizationsByAccount[accountID] = nil
        organizationAccessesByAccount[accountID] = nil
        cachedWorkItems.removeAll(for: accountID)
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
            let result = try await AccountConnectionService(
                brokerURL: configuration.brokerURL,
                secretStore: KeychainSecretStore(),
                vaultRegistry: requiredVaultRegistry()
            ).connectOAuth(exchangeRequest: request)
            install(
                accounts: accounts + [result.account],
                organizations: result.organizations,
                organizationAccesses: result.organizationAccesses,
                for: result.account.id
            )
            await refreshSelectedOrganization()
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
            let result = try await AccountConnectionService(
                secretStore: KeychainSecretStore(),
                vaultRegistry: requiredVaultRegistry()
            ).connect(
                personalAccessToken: token,
                resourceOwnerOrganization: resourceOwnerOrganization
            )
            install(
                accounts: accounts + [result.account],
                organizations: result.organizations,
                organizationAccesses: result.organizationAccesses,
                for: result.account.id
            )
            await refreshSelectedOrganization()
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
            await cancelInactiveRefreshes(for: account.id)
            await cancelForegroundRefresh()
            await cancelForegroundRefreshes(for: account.id)
            let configuration = try RuntimeOAuthConfiguration()
            let request = try await oauthAuthorizer.authorize(
                configuration: configuration.oauth,
                presentationAnchor: presentationAnchor
            )
            let tokenResponse = try await AuthBrokerClient(baseURL: configuration.brokerURL).exchange(request)
            let replacement = try await AccountCredentialReplacementService(
                secretStore: KeychainSecretStore(),
                vaultRegistry: requiredVaultRegistry()
            ).replace(oauthTokenResponse: tokenResponse, for: account)
            installUpdatedAccount(replacement.account)
            if replacement.retiredCredentialCleanupFailed {
                credentialActionNotice = "The new credential is active, but Triage could not erase the retired Keychain entry."
            }
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
            await cancelInactiveRefreshes(for: account.id)
            await cancelForegroundRefresh()
            await cancelForegroundRefreshes(for: account.id)
            let replacement = try await AccountCredentialReplacementService(
                secretStore: KeychainSecretStore(),
                vaultRegistry: requiredVaultRegistry()
            ).replace(
                personalAccessToken: try PersonalAccessToken(rawValue: rawValue),
                for: account
            )
            installUpdatedAccount(replacement.account)
            if replacement.retiredCredentialCleanupFailed {
                credentialActionNotice = "The new credential is active, but Triage could not erase the retired Keychain entry."
            }
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
        await refreshScheduler.start { [weak self] in
            await self?.refreshSelectedOrganization()
        }
        await inactiveRefreshScheduler.start(cadence: .inactiveAccount) { [weak self] in
            await self?.refreshInactiveOrganizations()
        }
    }

    func resumeSelectedOrganization() async {
        if !foregroundRefreshTasksAwaitingCredentialMutation.isEmpty {
            await cancelForegroundRefresh()
        }
        await refreshSelectedOrganization()
    }

    func restoreAccounts() async {
        do {
            let result = try await AccountRestorationService(
                secretStore: KeychainSecretStore(),
                vaultRegistry: requiredVaultRegistry()
            ).restore()
            accounts = result.accounts
            organizationsByAccount = result.organizationsByAccount
            organizationAccessesByAccount = result.organizationAccessesByAccount
            if !result.accounts.contains(where: { $0.id == selectedAccountID }) {
                selectedAccountID = result.accounts.first?.id
            }
            if !organizations.contains(where: { $0.id == selectedOrganizationID }) {
                selectedOrganizationID = organizations.first?.id
            }
            await loadCachedSelectedOrganization()
            if !result.unavailableAccountIDs.isEmpty {
                restorationError = "One or more connected accounts need to be reconnected."
            }
        } catch {
            restorationError = "Triage could not open its encrypted account data."
        }
    }

    func refreshSelectedOrganization() async {
        guard !isCredentialMutationInProgress,
              let accountID = selectedAccountID,
              !accountsBeingRemoved.contains(accountID)
        else {
            return
        }
        await organizationSyncCoordinator.cancelAccount(accountID: accountID)
        if let existingTask = foregroundRefreshTask {
            existingTask.cancel()
            await existingTask.value
        }
        let taskID = UUID()
        refreshGeneration += 1
        let generation = refreshGeneration
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performRefreshSelectedOrganization(generation: generation)
        }
        foregroundRefreshTask = task
        foregroundRefreshTaskID = taskID
        await task.value
        if foregroundRefreshTaskID == taskID {
            foregroundRefreshTask = nil
            foregroundRefreshTaskID = nil
        }
    }

    func recheckSelectedOrganizationAccess() async {
        guard let initialAccount = accounts.first(where: { $0.id == selectedAccountID }),
              let organization = selectedOrganization,
              !accountsBeingRemoved.contains(initialAccount.id)
        else {
            return
        }

        if let existingTask = foregroundRefreshTask {
            existingTask.cancel()
            await existingTask.value
        }
        foregroundRefreshTask = nil
        foregroundRefreshTaskID = nil
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
            let result = try await GitHubCapabilityProbe(
                identityClient: GitHubIdentityClient(client: client)
            ).probe(organization: organization)
            guard
                refreshGeneration == generation,
                selectedAccountID == initialAccount.id,
                selectedOrganizationID == organization.id
            else {
                return
            }

            let access = OrganizationAccess(
                accountID: initialAccount.id,
                organizationID: organization.id,
                state: result.accessState,
                capabilityRevision: CapabilityRevision(rawValue: UUID().uuidString.lowercased())!,
                capabilities: result.capabilities,
                checkedAt: Date()
            )
            try await AccountRepository(vault: vault).save(organization, access: access)
            organizationAccessesByAccount[initialAccount.id, default: [:]][organization.id] = access
            guard result.accessState == .available else {
                ssoAuthorizationHeader = result.ssoHeader
                refreshError = accessMessage(for: result.accessState)
                return
            }

            ssoAuthorizationHeader = nil
            refreshError = nil
            await refreshSelectedOrganization()
        } catch is CancellationError {
            return
        } catch {
            guard refreshGeneration == generation else { return }
            refreshError = "Triage could not confirm organization access. Cached work remains available."
        }
    }

    private func refreshInactiveOrganizations() async {
        guard let vaultRegistry, !isCredentialMutationInProgress else { return }

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
            await organizationSyncCoordinator.startAccount(
                accountID: account.id,
                priority: .background
            ) { [weak self] in
                guard await self?.canRunInactiveRefresh(
                    for: account.id,
                    expectedGeneration: generation
                ) == true
                else {
                    throw CancellationError()
                }
                let refreshedAccount: GitHubAccount
                if account.authenticationKind == .oauth,
                   CredentialLifecycle.status(for: account, at: .now) == .expiring {
                    let configuration = try RuntimeOAuthConfiguration()
                    refreshedAccount = try await OAuthCredentialRefreshService(
                        brokerURL: configuration.brokerURL,
                        secretStore: secretStore,
                        vaultRegistry: vaultRegistry
                    ).refreshIfNeeded(account)
                    try Task.checkCancellation()
                    guard await self?.installInactiveRefreshedAccount(
                        refreshedAccount,
                        expectedGeneration: generation
                    ) == true else {
                        throw CancellationError()
                    }
                } else {
                    refreshedAccount = account
                }
                for organization in organizations {
                    guard await self?.canRunInactiveRefresh(
                        for: refreshedAccount.id,
                        expectedGeneration: generation
                    ) == true else {
                        throw CancellationError()
                    }
                    _ = try await OrganizationWorkRefreshService(
                        credentialReader: AccountCredentialReader(secretStore: secretStore),
                        vaultRegistry: vaultRegistry,
                        secretStore: secretStore,
                        requestPriority: .inactiveAccountRefresh
                    ).refresh(account: refreshedAccount, organization: organization)
                    try Task.checkCancellation()
                    guard let vaultKey = try await secretStore.readVaultKey(for: refreshedAccount.id) else {
                        throw AccountCredentialReaderError.missingAccessToken
                    }
                    let vault = try await vaultRegistry.open(accountID: refreshedAccount.id, vaultKey: vaultKey)
                    try await SearchRepository(vault: vault).rebuild(
                        accountID: refreshedAccount.id,
                        organizationID: organization.id
                    )
                }
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
            _ = try await OrganizationWorkRefreshService(
                credentialReader: AccountCredentialReader(secretStore: secretStore),
                vaultRegistry: vaultRegistry,
                secretStore: secretStore
            ).refresh(account: account, organization: organization)
            guard let vaultKey = try await secretStore.readVaultKey(for: account.id) else {
                throw AccountCredentialReaderError.missingAccessToken
            }
            let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
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
            install(
                workItems: workItems,
                accountID: account.id,
                organizationID: organization.id
            )
        } catch is CancellationError {
            return
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
        isRefreshing = false
    }

    private func invalidateBackgroundRefreshScheduling() {
        backgroundRefreshGeneration &+= 1
    }

    private func cancelInactiveRefreshes(for accountID: AccountID) async {
        await organizationSyncCoordinator.cancelAccount(accountID: accountID)
    }

    private func cancelForegroundRefreshes(for accountID: AccountID) async {
        let tasks = foregroundRefreshTasksAwaitingAccountRemoval.removeValue(forKey: accountID) ?? []
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
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
            await task.value
        }
        isRefreshing = false
        ssoAuthorizationHeader = nil
        refreshError = nil
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
        let updatedAccount = account.replacingCredentialExpiration(
            accessTokenExpiresAt: account.accessTokenExpiresAt,
            refreshTokenExpiresAt: account.refreshTokenExpiresAt,
            status: status,
            validatedAt: account.lastValidatedAt ?? account.createdAt
        )
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
            guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
            accounts[index] = updatedAccount
            refreshError = message ?? "Triage could not refresh this organization. Cached work remains available."
        } catch {
            refreshError = "Triage could not update credential state. Cached work remains available."
        }
    }

    private func loadCachedSelectedOrganization() async {
        guard let account = accounts.first(where: { $0.id == selectedAccountID }),
              let organization = selectedOrganization,
              !accountsBeingRemoved.contains(account.id)
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
            install(
                workItems: workItems,
                accountID: account.id,
                organizationID: organization.id
            )
        } catch {
            restorationError = "Triage could not load cached work for the selected organization."
        }
    }

    func applyWorkflowAction(_ action: WorkflowAction, to workItem: WorkItem) async {
        guard !accountsBeingRemoved.contains(workItem.accountID) else { return }
        do {
            let updated = try await WorkflowActionService(
                secretStore: KeychainSecretStore(),
                vaultRegistry: requiredVaultRegistry()
            ).apply(action, to: workItem)
            guard let index = workItems.firstIndex(where: { $0.id == updated.id }) else { return }
            workItems[index] = updated
            cachedWorkItems[updated.accountID, updated.organizationID] = workItems
            try await rebuildSearchIndex(for: updated)
        } catch {
            refreshError = "Triage could not save this local workflow change."
        }
    }

    func completeActionItem(_ actionItem: ActionItem, in workItem: WorkItem) async {
        guard !accountsBeingRemoved.contains(workItem.accountID) else { return }
        do {
            let completed = actionItem.completing(at: .now)
            let secretStore = KeychainSecretStore()
            guard let vaultKey = try await secretStore.readVaultKey(for: workItem.accountID) else {
                throw AccountCredentialReaderError.missingAccessToken
            }
            let vault = try await requiredVaultRegistry().open(accountID: workItem.accountID, vaultKey: vaultKey)
            try await WorkflowRepository(vault: vault).save(completed)
            guard let index = workItems.firstIndex(where: { $0.id == workItem.id }) else { return }
            workItems[index] = workItem.replacing(
                actionItems: workItem.actionItems.map { $0.id == completed.id ? completed : $0 }
            )
            cachedWorkItems[workItem.accountID, workItem.organizationID] = workItems
            try await rebuildSearchIndex(for: workItem)
        } catch {
            refreshError = "Triage could not complete this local action item."
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
        Task { [weak self] in
            guard let self else { return }
            await self.loadCachedSelectedOrganization()
            await self.refreshSelectedOrganization()
        }
    }

    private func presentCachedWorkItems() {
        guard let accountID = selectedAccountID,
              let organizationID = selectedOrganizationID,
              let cachedWorkItems = cachedWorkItems[accountID, organizationID]
        else {
            present(workItems: [])
            return
        }
        present(workItems: cachedWorkItems)
    }

    private func requiredVaultRegistry() throws -> VaultRegistry {
        if let vaultRegistry {
            return vaultRegistry
        }
        throw vaultRegistryInitializationError ?? VaultError.missingApplicationSupportDirectory
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
