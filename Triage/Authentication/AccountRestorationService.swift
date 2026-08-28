import Foundation

struct AccountRestorationResult: Sendable {
    let accounts: [GitHubAccount]
    let organizationsByAccount: [AccountID: [GitHubOrganization]]
    let unavailableAccountIDs: [AccountID]
}

actor AccountRestorationService {
    private let secretStore: KeychainSecretStore
    private let vaultRegistry: VaultRegistry

    init(secretStore: KeychainSecretStore, vaultRegistry: VaultRegistry) {
        self.secretStore = secretStore
        self.vaultRegistry = vaultRegistry
    }

    func restore() async throws -> AccountRestorationResult {
        var accounts: [GitHubAccount] = []
        var organizationsByAccount: [AccountID: [GitHubOrganization]] = [:]
        var unavailableAccountIDs: [AccountID] = []

        for accountID in try await secretStore.accountIDs() {
            guard let vaultKey = try await secretStore.readVaultKey(for: accountID) else {
                unavailableAccountIDs.append(accountID)
                continue
            }
            do {
                let vault = try await vaultRegistry.open(accountID: accountID, vaultKey: vaultKey)
                let repository = AccountRepository(vault: vault)
                let restoredAccounts = try await repository.accounts()
                guard let account = restoredAccounts.first(where: { $0.id == accountID }) else {
                    unavailableAccountIDs.append(accountID)
                    continue
                }
                accounts.append(account)
                organizationsByAccount[accountID] = try await repository.organizations(for: accountID)
            } catch {
                unavailableAccountIDs.append(accountID)
            }
        }

        return AccountRestorationResult(
            accounts: accounts,
            organizationsByAccount: organizationsByAccount,
            unavailableAccountIDs: unavailableAccountIDs
        )
    }
}
