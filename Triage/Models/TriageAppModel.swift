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
    @Published private(set) var restorationError: String?
    @Published private(set) var ssoAuthorizationHeader: GitHubSSOHeader?

    private let oauthAuthorizer = GitHubOAuthAuthorizer()
    private let refreshScheduler = ActiveRefreshScheduler()
    private let defaults: UserDefaults
    private var refreshGeneration = 0

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

    func selectAccount(_ accountID: AccountID) {
        guard accounts.contains(where: { $0.id == accountID }) else { return }
        selectedAccountID = accountID
        selectedOrganizationID = organizationsByAccount[accountID]?.first?.id
        self.workItems = []
        selectedWorkItemID = nil
    }

    var selectedWorkItem: WorkItem? {
        workItems.first { $0.id == selectedWorkItemID }
    }

    func connectGitHub(presentationAnchor: NSWindow) async {
        connectionError = nil
        do {
            let configuration = try RuntimeOAuthConfiguration()
            let request = try await oauthAuthorizer.authorize(
                configuration: configuration.oauth,
                presentationAnchor: presentationAnchor
            )
            let result = try await AccountConnectionService(
                brokerURL: configuration.brokerURL,
                secretStore: KeychainSecretStore(),
                vaultRegistry: VaultRegistry()
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
                vaultRegistry: VaultRegistry()
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
        refreshGeneration += 1
        let generation = refreshGeneration
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
            let vaultRegistry = try VaultRegistry()
            let account: GitHubAccount
            if initialAccount.authenticationKind == .oauth,
               initialAccount.accessTokenExpiresAt.map({ $0 <= Date().addingTimeInterval(5 * 60) }) ?? false
            {
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
            ssoAuthorizationHeader = error.ssoHeader
            if case .authorizationRequired? = error.ssoHeader {
                refreshError = "GitHub requires SSO authorization for this organization."
            } else {
                refreshError = "Triage could not refresh this organization. Cached work remains available."
            }
        } catch {
            guard refreshGeneration == generation else { return }
            refreshError = "Triage could not refresh this organization. Cached work remains available."
        }
    }

    private func loadCachedSelectedOrganization() async {
        guard let account = accounts.first(where: { $0.id == selectedAccountID }),
              let organization = selectedOrganization
        else {
            return
        }
        do {
            let secretStore = KeychainSecretStore()
            guard let vaultKey = try await secretStore.readVaultKey(for: account.id) else {
                throw AccountCredentialReaderError.missingAccessToken
            }
            let vault = try await VaultRegistry().open(accountID: account.id, vaultKey: vaultKey)
            install(workItems: try await WorkItemRepository(vault: vault).fetch(
                accountID: account.id,
                organizationID: organization.id
            ))
        } catch {
            restorationError = "Triage could not load cached work for the selected organization."
        }
    }

    func applyWorkflowAction(_ action: WorkflowAction, to workItem: WorkItem) async {
        do {
            let updated = try await WorkflowActionService(
                secretStore: KeychainSecretStore(),
                vaultRegistry: VaultRegistry()
            ).apply(action, to: workItem)
            guard let index = workItems.firstIndex(where: { $0.id == updated.id }) else { return }
            workItems[index] = updated
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
            let vault = try await VaultRegistry().open(accountID: workItem.accountID, vaultKey: vaultKey)
            try await WorkflowRepository(vault: vault).save(completed)
            guard let index = workItems.firstIndex(where: { $0.id == workItem.id }) else { return }
            workItems[index] = workItem.replacing(
                actionItems: workItem.actionItems.map { $0.id == completed.id ? completed : $0 }
            )
        } catch {
            refreshError = "Triage could not complete this local action item."
        }
    }
}
