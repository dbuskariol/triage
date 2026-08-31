import Foundation

struct AccountVaultRecoveryIssue: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case databaseCorruption
        case migrationFailure
        case sqlCipherUnavailable
    }

    let accountID: AccountID
    let kind: Kind
    /// Only migration backups that opened with this account's vault key and
    /// passed SQLCipher integrity verification are exposed for recovery.
    let verifiedBackupMigrationIDs: [String]
}

struct AccountRestorationResult: Sendable {
    let accounts: [GitHubAccount]
    let organizationsByAccount: [AccountID: [GitHubOrganization]]
    let organizationAccessesByAccount: [AccountID: [OrganizationID: OrganizationAccess]]
    let accountCapabilitiesByAccount: [AccountID: AccountCapabilitySnapshot]
    let unavailableAccountIDs: [AccountID]
    let vaultRecoveryIssues: [AccountVaultRecoveryIssue]

    init(
        accounts: [GitHubAccount],
        organizationsByAccount: [AccountID: [GitHubOrganization]],
        organizationAccessesByAccount: [AccountID: [OrganizationID: OrganizationAccess]],
        accountCapabilitiesByAccount: [AccountID: AccountCapabilitySnapshot],
        unavailableAccountIDs: [AccountID],
        vaultRecoveryIssues: [AccountVaultRecoveryIssue] = []
    ) {
        self.accounts = accounts
        self.organizationsByAccount = organizationsByAccount
        self.organizationAccessesByAccount = organizationAccessesByAccount
        self.accountCapabilitiesByAccount = accountCapabilitiesByAccount
        self.unavailableAccountIDs = unavailableAccountIDs
        self.vaultRecoveryIssues = vaultRecoveryIssues
    }
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
        var vaultRecoveryIssues: [AccountVaultRecoveryIssue] = []

        for accountID in try await secretStore.accountIDs() {
            // Validate before inspecting key presence. An arbitrary persisted
            // identifier must not become a removable "missing key" account,
            // because the removal service deliberately refuses to construct a
            // filesystem namespace for it.
            guard Self.isCanonicalOpaqueAccountID(accountID) else {
                throw VaultError.unsafeAccountIDPath
            }
            let vaultKeyData: Data?
            do {
                vaultKeyData = try await secretStore.read(
                    kind: .vaultKey,
                    accountID: accountID,
                    credentialID: nil
                )
            } catch {
                // A Keychain read failure is not evidence that the key is
                // missing. Propagate it so the UI offers retry, never a
                // destructive keyless-vault recovery action.
                throw error
            }
            guard let vaultKeyData else {
                unavailableAccountIDs.append(accountID)
                continue
            }
            let vaultKey: VaultKey
            do {
                vaultKey = try VaultKey(data: vaultKeyData)
            } catch {
                // A present but malformed key cannot open a vault. It is an
                // explicit unavailable-key path and remains independently
                // removable without affecting other restored accounts.
                unavailableAccountIDs.append(accountID)
                continue
            }
            let vault: AccountVault
            do {
                vault = try await vaultRegistry.open(accountID: accountID, vaultKey: vaultKey)
            } catch VaultError.unsafeAccountIDPath {
                // An invalid persisted identifier has no safe vault namespace.
                // It must remain a non-destructive restoration failure: local
                // data removal rejects this same identifier by design.
                throw VaultError.unsafeAccountIDPath
            } catch let error as VaultError {
                guard let kind = Self.recoveryIssueKind(for: error) else { throw error }
                let backups = (try? await vaultRegistry.verifiedMigrationBackupIDs(
                    accountID: accountID,
                    vaultKey: vaultKey
                )) ?? []
                vaultRecoveryIssues.append(
                    AccountVaultRecoveryIssue(
                        accountID: accountID,
                        kind: kind,
                        verifiedBackupMigrationIDs: backups
                    )
                )
                continue
            } catch {
                // Opening failures not proven to be a damaged encrypted vault
                // remain retryable. Never present a destructive keyless-vault
                // recovery action for them.
                throw error
            }

            // Everything after the vault boundary can fail for reasons that
            // have nothing to do with its key: Keychain availability, a
            // repository read, or a status-write failure. Propagate those
            // errors instead of presenting a destructive "key unavailable"
            // recovery option for otherwise recoverable local data.
            let repository = AccountRepository(vault: vault)
            let restoredAccounts = try await repository.accounts()
            guard let account = restoredAccounts.first(where: { $0.id == accountID }) else {
                throw AccountRestorationError.accountRecordMissing
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
        }

        return AccountRestorationResult(
            accounts: accounts,
            organizationsByAccount: organizationsByAccount,
            organizationAccessesByAccount: organizationAccessesByAccount,
            accountCapabilitiesByAccount: accountCapabilitiesByAccount,
            unavailableAccountIDs: unavailableAccountIDs,
            vaultRecoveryIssues: vaultRecoveryIssues
        )
    }

    private static func isCanonicalOpaqueAccountID(_ accountID: AccountID) -> Bool {
        guard let value = UUID(uuidString: accountID.rawValue) else { return false }
        return value.uuidString.lowercased() == accountID.rawValue
    }

    /// Kept separate from the missing-key branch above so a vault-open error
    /// can never acquire the unavailable-account removal capability.
    static func recoveryIssueKind(for error: VaultError) -> AccountVaultRecoveryIssue.Kind? {
        switch error {
        case .invalidIntegrityCheck:
            .databaseCorruption
        case .unsupportedDestructiveMigration, .invalidMigrationBackup:
            .migrationFailure
        case .sqlCipherUnavailable:
            .sqlCipherUnavailable
        case .missingApplicationSupportDirectory, .accountBeingRemoved, .unsafeAccountIDPath:
            nil
        }
    }
}

private enum AccountRestorationError: Error, Sendable {
    case accountRecordMissing
}
