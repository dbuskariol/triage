import Foundation

@MainActor
final class TriageAppModel: ObservableObject {
    @Published private(set) var accounts: [GitHubAccount] = []
    @Published private(set) var organizations: [GitHubOrganization] = []
    @Published private(set) var workItems: [WorkItem] = []
    @Published var selectedAccountID: AccountID?
    @Published var selectedOrganizationID: OrganizationID?
    @Published var selectedWorkItemID: WorkItemID?

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
}
