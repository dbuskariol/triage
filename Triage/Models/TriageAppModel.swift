import AppKit
import Foundation

@MainActor
final class TriageAppModel: ObservableObject {
    @Published private(set) var accounts: [GitHubAccount] = []
    @Published private(set) var organizationsByAccount: [AccountID: [GitHubOrganization]] = [:]
    @Published private(set) var workItems: [WorkItem] = []
    @Published var selectedAccountID: AccountID?
    @Published var selectedOrganizationID: OrganizationID?
    @Published var selectedWorkItemID: WorkItemID?
    @Published private(set) var connectionError: String?
    @Published private(set) var refreshError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var restorationError: String?

    private let oauthAuthorizer = GitHubOAuthAuthorizer()
    private var refreshGeneration = 0

    var hasConnectedAccount: Bool { !accounts.isEmpty }
    var organizations: [GitHubOrganization] {
        guard let selectedAccountID else { return [] }
        return organizationsByAccount[selectedAccountID] ?? []
    }

    var selectedOrganization: GitHubOrganization? {
        organizations.first { $0.id == selectedOrganizationID }
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

    func restoreAccounts() async {
        do {
            let result = try await AccountRestorationService(
                secretStore: KeychainSecretStore(),
                vaultRegistry: VaultRegistry()
            ).restore()
            accounts = result.accounts
            organizationsByAccount = result.organizationsByAccount
            selectedAccountID = result.accounts.first?.id
            selectedOrganizationID = selectedAccountID.flatMap { organizationsByAccount[$0]?.first?.id }
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
        guard let account = accounts.first(where: { $0.id == selectedAccountID }),
              let organization = selectedOrganization
        else {
            return
        }

        refreshError = nil
        isRefreshing = true
        defer {
            if refreshGeneration == generation {
                isRefreshing = false
            }

        }
        do {
            let secretStore = KeychainSecretStore()
            let vaultRegistry = try VaultRegistry()
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
}
