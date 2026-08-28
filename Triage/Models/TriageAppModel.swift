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
    @Published private(set) var workItems: [WorkItem] = []
    @Published var selectedAccountID: AccountID? {
        didSet { defaults.set(selectedAccountID?.rawValue, forKey: PreferenceKey.selectedAccountID) }
    }
    @Published var selectedOrganizationID: OrganizationID? {
        didSet { defaults.set(selectedOrganizationID?.rawValue, forKey: PreferenceKey.selectedOrganizationID) }
    }
    @Published var selectedWorkItemID: WorkItemID?
    @Published private(set) var connectionError: String?
    @Published private(set) var refreshError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isConnecting = false
    @Published private(set) var restorationError: String?
    @Published private(set) var ssoAuthorizationHeader: GitHubSSOHeader?

    private let oauthAuthorizer = GitHubOAuthAuthorizer()
    private let refreshScheduler = ActiveRefreshScheduler()
    private let defaults: UserDefaults
    private let vaultRegistry: VaultRegistry?
    private let vaultRegistryInitializationError: Error?
    private var refreshGeneration = 0
    private var foregroundRefreshTask: Task<Void, Never>?
    private var foregroundRefreshTaskID: UUID?

    var hasConnectedAccount: Bool { !accounts.isEmpty }
    var organizations: [GitHubOrganization] {
        guard let selectedAccountID else { return [] }
        return organizationsByAccount[selectedAccountID] ?? []
    }

    var selectedOrganization: GitHubOrganization? {
        organizations.first { $0.id == selectedOrganizationID }
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
        for accountID: AccountID
    ) {
        self.accounts = accounts
        organizationsByAccount[accountID] = organizations
        selectedAccountID = accountID
        selectedOrganizationID = organizations.first?.id
    }

    func install(workItems: [WorkItem]) {
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

    func selectAccount(_ accountID: AccountID) {
        guard accounts.contains(where: { $0.id == accountID }) else { return }
        invalidateRefreshState()
        selectedAccountID = accountID
        selectedOrganizationID = organizationsByAccount[accountID]?.first?.id
        self.workItems = []
        selectedWorkItemID = nil
        activateSelectedOrganization()
    }

    func selectOrganization(_ organizationID: OrganizationID) {
        guard organizations.contains(where: { $0.id == organizationID }) else { return }
        invalidateRefreshState()
        selectedOrganizationID = organizationID
        activateSelectedOrganization()
    }

    func removeAccount(_ accountID: AccountID) async throws {
        guard accounts.contains(where: { $0.id == accountID }) else { return }

        invalidateRefreshState()
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
        if selectedAccountID == accountID {
            selectedAccountID = accounts.first?.id
            selectedOrganizationID = selectedAccountID
                .flatMap { organizationsByAccount[$0]?.first?.id }
        }
        workItems = []
        selectedWorkItemID = nil
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
            install(accounts: accounts + [result.account], organizations: result.organizations, for: result.account.id)
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
            install(accounts: accounts + [result.account], organizations: result.organizations, for: result.account.id)
            await refreshSelectedOrganization()
        } catch is PersonalAccessTokenError {
            connectionError = "Enter a supported fine-grained or classic GitHub personal access token."
        } catch {
            connectionError = "Triage could not validate this personal access token. Check its access and try again."
        }
    }

    func recordConnectionWindowError() {
        connectionError = "Triage could not find its active window."
    }

    func startAutomaticRefreshes() async {
        await refreshScheduler.start { [weak self] in
            await self?.refreshSelectedOrganization()
        }
    }

    func restoreAccounts() async {
        do {
            let result = try await AccountRestorationService(
                secretStore: KeychainSecretStore(),
                vaultRegistry: requiredVaultRegistry()
            ).restore()
            accounts = result.accounts
            organizationsByAccount = result.organizationsByAccount
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
        foregroundRefreshTask?.cancel()
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
            install(workItems: workItems)
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
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        foregroundRefreshTaskID = nil
        ssoAuthorizationHeader = nil
        refreshError = nil
        isRefreshing = false
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
              let organization = selectedOrganization
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
            install(workItems: workItems)
        } catch {
            restorationError = "Triage could not load cached work for the selected organization."
        }
    }

    func applyWorkflowAction(_ action: WorkflowAction, to workItem: WorkItem) async {
        do {
            let updated = try await WorkflowActionService(
                secretStore: KeychainSecretStore(),
                vaultRegistry: requiredVaultRegistry()
            ).apply(action, to: workItem)
            guard let index = workItems.firstIndex(where: { $0.id == updated.id }) else { return }
            workItems[index] = updated
            try await rebuildSearchIndex(for: updated)
        } catch {
            refreshError = "Triage could not save this local workflow change."
        }
    }

    func completeActionItem(_ actionItem: ActionItem, in workItem: WorkItem) async {
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

    private func requiredVaultRegistry() throws -> VaultRegistry {
        if let vaultRegistry {
            return vaultRegistry
        }
        throw vaultRegistryInitializationError ?? VaultError.missingApplicationSupportDirectory
    }
}
