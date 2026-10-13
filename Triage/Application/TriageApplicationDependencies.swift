import Foundation

/// The account/session boundary used by the main-actor application model.
///
/// Implementations own credentials, vault opening, and account persistence.
/// They are deliberately Sendable so no Keychain, vault, or network work is
/// performed by SwiftUI views or the application model.
protocol AccountSessionServing: Sendable {
    func restoreAccounts() async throws -> AccountSessionSnapshot
    func connectOAuth(_ request: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot
    func connectPersonalAccessToken(
        _ token: PersonalAccessToken,
        resourceOwnerOrganization: String?
    ) async throws -> AccountSessionSnapshot
    func replacePersonalAccessToken(
        _ token: PersonalAccessToken,
        replacing account: GitHubAccount
    ) async throws -> AccountSessionSnapshot
    func restoreVerifiedMigrationBackup(
        for accountID: AccountID,
        migrationID: String
    ) async throws -> AccountSessionSnapshot
    func removeAccount(_ accountID: AccountID) async throws
}

extension AccountSessionServing {
    /// Test doubles that do not model vault files remain fail-closed for a
    /// repair request instead of fabricating a restored account session.
    func restoreVerifiedMigrationBackup(
        for _: AccountID,
        migrationID _: String
    ) async throws -> AccountSessionSnapshot {
        throw CancellationError()
    }
}

typealias AccountNavigationStatePurging = @MainActor @Sendable (AccountID) -> Void

/// Removes presentation state that must not survive an interrupted account
/// deletion. Account-session recovery invokes this only after the deletion
/// journal has completed crypto-erasure and before it returns a restoration
/// snapshot to the UI.
protocol AccountDeletionRecoveryStatePurging: Sendable {
    func purgeRecoveredDeletedAccountState(for accountID: AccountID) async
}

struct NoopAccountDeletionRecoveryStatePurger: AccountDeletionRecoveryStatePurging {
    func purgeRecoveredDeletedAccountState(for _: AccountID) async {}
}

/// Production cleanup for state stored outside an encrypted account vault.
/// The account and organization defaults form one selection, so clearing the
/// deleted account also clears its paired organization. Work-item selection
/// and history remain owned by `AppNavigationModel` and are removed through
/// its injected account-scoped purge operation.
struct AccountDeletionRecoveryStatePurger: AccountDeletionRecoveryStatePurging {
    private enum PreferenceKey {
        static let selectedAccountID = "workspace.selected-account-id"
        static let selectedOrganizationID = "workspace.selected-organization-id"
    }

    private let purgeAccountNavigationState: AccountNavigationStatePurging

    init(purgeAccountNavigationState: @escaping AccountNavigationStatePurging) {
        self.purgeAccountNavigationState = purgeAccountNavigationState
    }

    func purgeRecoveredDeletedAccountState(for accountID: AccountID) async {
        await MainActor.run {
            Self.purgeSelectedAccountAndOrganization(for: accountID)
            purgeAccountNavigationState(accountID)
        }
    }

    @MainActor
    static func purgeSelectedAccountAndOrganization(
        for accountID: AccountID,
        defaults: UserDefaults = .triage
    ) {
        guard defaults.string(forKey: PreferenceKey.selectedAccountID) == accountID.rawValue else {
            return
        }
        defaults.removeObject(forKey: PreferenceKey.selectedAccountID)
        defaults.removeObject(forKey: PreferenceKey.selectedOrganizationID)
    }
}

/// Everything the app model needs from the outside world.
struct TriageApplicationDependencies: Sendable {
    let accountSession: any AccountSessionServing
    let copilotRuntimeAuthorization: any CopilotRuntimeAuthorizationProviding
    let consent: @Sendable (WorkspaceScope) async throws -> OrganizationAIConsent
    /// Saves consent with the triage model and the reply model (`nil` = same as triage).
    let saveConsent: @Sendable (WorkspaceScope, _ isEnabled: Bool, _ triage: CopilotModelChoice, _ reply: CopilotModelChoice?) async throws -> Void
    let makeWorkspace: @Sendable (WorkspaceScope) async throws -> WorkspaceRuntime
    var purgeAccountNavigationState: AccountNavigationStatePurging = { _ in }
    /// Drafts a reply for an item: (scope, item, goal, writing style).
    var draftReply: @Sendable (WorkspaceScope, PersonalWorkItem, String?, String?) async throws -> String = { _, _, _, _ in
        throw TriageDecisionError.runtimeUnavailable
    }
    /// The GitHub sign-in configuration, read from the signed app bundle.
    var oauthConfiguration: @Sendable () throws -> RuntimeOAuthConfiguration = { try RuntimeOAuthConfiguration() }
}

enum AccountSessionSnapshotError: Error, Equatable, Sendable {
    case duplicateAccount
    case duplicateOrganization
    case unknownAccountReference
    case mismatchedAccessAccount
    case mismatchedCapabilityAccount
}
struct AccountSessionSnapshot: Equatable, Sendable {
    let accounts: [GitHubAccount]
    let organizationsByAccount: [AccountID: [GitHubOrganization]]
    let organizationAccessesByAccount: [AccountID: [OrganizationID: OrganizationAccess]]
    let accountCapabilitiesByAccount: [AccountID: AccountCapabilitySnapshot]
    /// Opaque account identities whose vault cannot be opened. They are kept
    /// separate from usable accounts so the UI can offer local crypto-erasure
    /// without manufacturing GitHub profile data from a missing vault.
    let unavailableAccountIDs: Set<AccountID>
    /// Account-local encrypted vault failures with an intact Keychain key.
    /// These remain distinct from unavailable keys so presentation never
    /// offers destructive keyless-vault removal for corruption or migration
    /// repair.
    let vaultRecoveryIssues: [AccountVaultRecoveryIssue]
    /// Non-secret remediation notice produced after a successful credential
    /// replacement whose retired Keychain entry could not be erased.
    let credentialActionNotice: String?

    init(
        accounts: [GitHubAccount],
        organizationsByAccount: [AccountID: [GitHubOrganization]],
        organizationAccessesByAccount: [AccountID: [OrganizationID: OrganizationAccess]],
        accountCapabilitiesByAccount: [AccountID: AccountCapabilitySnapshot],
        unavailableAccountIDs: Set<AccountID> = [],
        vaultRecoveryIssues: [AccountVaultRecoveryIssue] = [],
        credentialActionNotice: String? = nil
    ) throws {
        let accountIDs = Set(accounts.map(\.id))
        guard accountIDs.count == accounts.count else {
            throw AccountSessionSnapshotError.duplicateAccount
        }
        guard Set(organizationsByAccount.keys).isSubset(of: accountIDs),
              Set(organizationAccessesByAccount.keys).isSubset(of: accountIDs),
              Set(accountCapabilitiesByAccount.keys).isSubset(of: accountIDs),
              unavailableAccountIDs.isDisjoint(with: accountIDs),
              Set(vaultRecoveryIssues.map(\.accountID)).isDisjoint(with: accountIDs),
              unavailableAccountIDs.isDisjoint(with: Set(vaultRecoveryIssues.map(\.accountID))),
              Set(vaultRecoveryIssues.map(\.accountID)).count == vaultRecoveryIssues.count
        else {
            throw AccountSessionSnapshotError.unknownAccountReference
        }
        guard organizationsByAccount.values.allSatisfy({ organizations in
            Set(organizations.map(\.id)).count == organizations.count
        }) else {
            throw AccountSessionSnapshotError.duplicateOrganization
        }
        for (accountID, accesses) in organizationAccessesByAccount {
            guard accesses.allSatisfy({ organizationID, access in
                access.accountID == accountID && access.organizationID == organizationID
            }) else {
                throw AccountSessionSnapshotError.mismatchedAccessAccount
            }
        }
        for (accountID, capabilities) in accountCapabilitiesByAccount {
            guard capabilities.accountID == accountID else {
                throw AccountSessionSnapshotError.mismatchedCapabilityAccount
            }
        }
        self.accounts = accounts
        self.organizationsByAccount = organizationsByAccount
        self.organizationAccessesByAccount = organizationAccessesByAccount
        self.accountCapabilitiesByAccount = accountCapabilitiesByAccount
        self.unavailableAccountIDs = unavailableAccountIDs
        self.vaultRecoveryIssues = vaultRecoveryIssues
        self.credentialActionNotice = credentialActionNotice
    }
}
