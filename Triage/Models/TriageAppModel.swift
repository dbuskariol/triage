import AppKit
import Foundation

@MainActor
final class TriageAppModel: ObservableObject {
    @Published private(set) var accounts: [GitHubAccount] = []
    @Published private(set) var organizations: [GitHubOrganization] = []
    @Published private(set) var workItems: [WorkItem] = []
    @Published var selectedAccountID: AccountID?
    @Published var selectedOrganizationID: OrganizationID?
    @Published var selectedWorkItemID: WorkItemID?
    @Published private(set) var connectionError: String?

    private let oauthAuthorizer = GitHubOAuthAuthorizer()

    var hasConnectedAccount: Bool { !accounts.isEmpty }
    var selectedOrganization: GitHubOrganization? {
        organizations.first { $0.id == selectedOrganizationID }
    }

    func install(accounts: [GitHubAccount], organizations: [GitHubOrganization]) {
        self.accounts = accounts
        self.organizations = organizations
        selectedAccountID = selectedAccountID ?? accounts.first?.id
        selectedOrganizationID = selectedOrganizationID ?? organizations.first?.id
    }

    func install(workItems: [WorkItem]) {
        self.workItems = workItems
        if !workItems.contains(where: { $0.id == selectedWorkItemID }) {
            selectedWorkItemID = workItems.first?.id
        }
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
            install(
                accounts: accounts + [result.account],
                organizations: result.organizations
            )
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
}
