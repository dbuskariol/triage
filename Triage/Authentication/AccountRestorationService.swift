import Foundation

struct AccountRestorationResult: Sendable {
    let accounts: [GitHubAccount]
    let organizationsByAccount: [AccountID: [GitHubOrganization]]
    let organizationAccessesByAccount: [AccountID: [OrganizationID: OrganizationAccess]]
    let accountCapabilitiesByAccount: [AccountID: AccountCapabilitySnapshot]
    let unavailableAccountIDs: [AccountID]
}

actor AccountRestorationService {
    private let secretStore: any SecretStore
    private let vaultRegistry: VaultRegistry

    init(secretStore: any SecretStore, vaultRegistry: VaultRegistry) {
        self.secretStore = secretStore
        self.vaultRegistry = vaultRegistry
    }

    func restore() async throws -> AccountRestorationResult {
        var accounts: [GitHubAccount] = []
        var organizationsByAccount: [AccountID: [GitHubOrganization]] = [:]
        var organizationAccessesByAccount: [AccountID: [OrganizationID: OrganizationAccess]] = [:]
        var accountCapabilitiesByAccount: [AccountID: AccountCapabilitySnapshot] = [:]
        var unavailableAccountIDs: [AccountID] = []

        for accountID in try await secretStore.accountIDs() {
            let vaultKey: VaultKey
            do {
                guard let vaultKeyData = try await secretStore.read(
                    kind: .vaultKey,
                    accountID: accountID,
                    credentialID: nil
                ) else {
                    unavailableAccountIDs.append(accountID)
                    continue
                }
                vaultKey = try VaultKey(data: vaultKeyData)
            } catch {
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
                let accessTokenKind: TriageSecretKind = account.authenticationKind == .oauth
                    ? .oauthAccessToken
                    : .personalAccessToken
                let accessToken = try await secretStore.read(
                    kind: accessTokenKind,
                    accountID: account.id,
                    credentialID: account.credentialID
                )
                let restoredStatus = CredentialLifecycle.restoredStatus(
                    for: account,
                    hasAccessToken: accessToken.map { !$0.isEmpty } ?? false,
                    at: Date()
                )
                let restoredAccount = account.replacingCredentialStatus(restoredStatus)
                if restoredAccount != account {
                    try await repository.save(
                        restoredAccount,
                        credentialRevision: CredentialRevision(rawValue: UUID().uuidString.lowercased())!
                    )
                }
                accounts.append(restoredAccount)
                organizationsByAccount[accountID] = try await repository.organizations(for: accountID)
                organizationAccessesByAccount[accountID] = try await repository.organizationAccesses(
                    for: accountID
                )
                if let accountCapabilities = try await repository.accountCapabilities(for: accountID) {
                    accountCapabilitiesByAccount[accountID] = accountCapabilities
                }
            } catch {
                unavailableAccountIDs.append(accountID)
            }
        }

        return AccountRestorationResult(
            accounts: accounts,
            organizationsByAccount: organizationsByAccount,
            organizationAccessesByAccount: organizationAccessesByAccount,
            accountCapabilitiesByAccount: accountCapabilitiesByAccount,
            unavailableAccountIDs: unavailableAccountIDs
        )
    }
}
