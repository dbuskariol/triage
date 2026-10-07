import Foundation

/// Builds the production object graph: Keychain + encrypted vaults for
/// accounts, the Copilot helper for AI, and one `TriageEngine` per workspace.
struct TriageProductionComposition: Sendable {
    let vaultRegistry: VaultRegistry
    let secretStore: KeychainSecretStore
    let applicationSupportDirectory: URL
    let cachesDirectory: URL

    func dependencies(
        purgeAccountNavigationState: @escaping AccountNavigationStatePurging = { _ in }
    ) -> TriageApplicationDependencies {
        let copilotRuntimeAuthorization = CopilotRuntimeAuthenticationService(
            applicationSupportDirectory: applicationSupportDirectory,
            secretStore: secretStore
        )
        let vaultRegistry = vaultRegistry
        let secretStore = secretStore
        let openVault: @Sendable (AccountID) async throws -> AccountVault = { accountID in
            guard let key = try await secretStore.readVaultKey(for: accountID) else {
                throw AccountCredentialReaderError.missingAccessToken
            }
            return try await vaultRegistry.open(accountID: accountID, vaultKey: key)
        }
        return TriageApplicationDependencies(
            accountSession: TriageAccountSessionService(
                vaultRegistry: vaultRegistry,
                secretStore: secretStore,
                applicationSupportDirectory: applicationSupportDirectory,
                cachesDirectory: cachesDirectory,
                copilotRuntimeAuthorization: copilotRuntimeAuthorization,
                deletionRecoveryStatePurger: AccountDeletionRecoveryStatePurger(
                    purgeAccountNavigationState: purgeAccountNavigationState
                )
            ),
            copilotRuntimeAuthorization: copilotRuntimeAuthorization,
            consent: { scope in
                try await AIConsentRepository(vault: openVault(scope.accountID))
                    .consent(for: scope.accountID, organizationID: scope.organizationID)
            },
            saveConsent: { scope, isEnabled, modelID in
                try await AIConsentRepository(vault: openVault(scope.accountID)).save(.init(
                    accountID: scope.accountID,
                    organizationID: scope.organizationID,
                    isEnabled: isEnabled,
                    selectedModelID: modelID,
                    automaticActionConfidenceThreshold: OrganizationAIConsent.minimumAutomaticActionConfidenceThreshold,
                    updatedAt: .now
                ))
            },
            makeWorkspace: { scope in
                let vault = try await openVault(scope.accountID)
                let store = GRDBTriageStore(vault: vault)
                let engine = TriageEngine(
                    store: store,
                    makeDiscovery: { scope in
                        let vault = try await openVault(scope.accountID)
                        let account = try await AccountRepository(vault: vault).accounts()
                            .first { $0.id == scope.accountID }
                        guard let account else { throw AccountCredentialReaderError.missingAccessToken }
                        let token = try await AccountCredentialReader(secretStore: secretStore).accessToken(for: account)
                        let rateLimit = try await GitHubRateLimitControllerRegistry.shared.controller(
                            for: scope.accountID, vault: vault
                        )
                        let client = GitHubGraphQLClient(
                            credential: token, rateLimitController: rateLimit, personalWorkOnly: true
                        )
                        return GitHubPersonalWorkDiscovery(executor: GitHubPersonalWorkSearchExecutor(client: client))
                    },
                    decider: CopilotTriageDecider(resolveVault: openVault)
                )
                return WorkspaceRuntime(store: store, engine: engine)
            }
        )
    }
}

actor TriageAccountSessionService: AccountSessionServing {
    typealias InterruptedRemovalRecovering = @Sendable (
        @escaping @Sendable (AccountID) async -> Void
    ) async throws -> [AccountID]

    private let vaultRegistry: VaultRegistry
    private let secretStore: KeychainSecretStore
    private let applicationSupportDirectory: URL
    private let cachesDirectory: URL
    private let restoreAccountState: @Sendable () async throws -> AccountRestorationResult
    private let recoverInterruptedRemovals: InterruptedRemovalRecovering
    private let drainAccountBeforeCryptoErasure: @Sendable (AccountID) async -> Void
    private let deletionRecoveryStatePurger: any AccountDeletionRecoveryStatePurging
    private let copilotRuntimeAuthorization: any CopilotRuntimeAuthorizationProviding

    init(
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore,
        applicationSupportDirectory: URL,
        cachesDirectory: URL,
        restoreAccountState: (@Sendable () async throws -> AccountRestorationResult)? = nil,
        recoverInterruptedRemovals: InterruptedRemovalRecovering? = nil,
        copilotRuntimeAuthorization: any CopilotRuntimeAuthorizationProviding = NoopCopilotRuntimeAuthorizationProvider(),
        deletionRecoveryStatePurger: any AccountDeletionRecoveryStatePurging = NoopAccountDeletionRecoveryStatePurger()
    ) {
        self.vaultRegistry = vaultRegistry
        self.secretStore = secretStore
        self.applicationSupportDirectory = applicationSupportDirectory
        self.cachesDirectory = cachesDirectory
        let drainAccountBeforeCryptoErasure: @Sendable (AccountID) async -> Void = { accountID in
            // Stop any helper process that could recreate account-scoped
            // artifacts before the vault key is erased.
            await copilotRuntimeAuthorization.disconnect(accountID: accountID)
        }
        self.drainAccountBeforeCryptoErasure = drainAccountBeforeCryptoErasure
        self.restoreAccountState = restoreAccountState ?? {
            try await AccountRestorationService(
                secretStore: secretStore,
                vaultRegistry: vaultRegistry
            ).restore()
        }
        self.recoverInterruptedRemovals = recoverInterruptedRemovals ?? { beforeCryptoErasure in
            try await AccountDataRemovalService(
                vaultRegistry: vaultRegistry,
                secretStore: secretStore,
                applicationSupportDirectory: applicationSupportDirectory,
                cachesDirectory: cachesDirectory,
                willBeginCryptoErasureForAccount: beforeCryptoErasure
            ).recoverInterruptedRemovals()
        }
        self.copilotRuntimeAuthorization = copilotRuntimeAuthorization
        self.deletionRecoveryStatePurger = deletionRecoveryStatePurger
    }

    func restoreAccounts() async throws -> AccountSessionSnapshot {
        // A journal is the sole durable authorization for recovery. Complete it
        // before restoration so a keyless vault can never reappear as usable.
        let recoveredAccountIDs = try await recoverInterruptedRemovals(drainAccountBeforeCryptoErasure)
        for accountID in recoveredAccountIDs {
            await deletionRecoveryStatePurger.purgeRecoveredDeletedAccountState(for: accountID)
        }
        return try await restoredSnapshot()
    }

    func connectOAuth(_ request: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot {
        let configuration = try RuntimeOAuthConfiguration()
        _ = try await AccountConnectionService(
            brokerURL: configuration.brokerURL,
            applicationVersion: configuration.applicationVersion,
            secretStore: secretStore,
            vaultRegistry: vaultRegistry
        ).connectOAuth(exchangeRequest: request)
        return try await restoredSnapshot()
    }

    func connectPersonalAccessToken(
        _ token: PersonalAccessToken,
        resourceOwnerOrganization: String?
    ) async throws -> AccountSessionSnapshot {
        _ = try await AccountConnectionService(
            secretStore: secretStore,
            vaultRegistry: vaultRegistry
        ).connect(personalAccessToken: token, resourceOwnerOrganization: resourceOwnerOrganization)
        return try await restoredSnapshot()
    }

    func reconnectOAuth(
        _ request: AuthBrokerExchangeRequest,
        replacing account: GitHubAccount
    ) async throws -> AccountSessionSnapshot {
        let configuration = try RuntimeOAuthConfiguration()
        let response = try await AuthBrokerClient(
            baseURL: configuration.brokerURL,
            applicationVersion: configuration.applicationVersion
        ).exchange(request)
        let replacement = try await AccountCredentialReplacementService(
            secretStore: secretStore,
            vaultRegistry: vaultRegistry
        ).replace(oauthTokenResponse: response, for: account)
        return try await restoredSnapshot(
            credentialActionNotice: replacement.retiredCredentialCleanupFailed
                ? "The new credential is active, but Triage could not erase the retired Keychain entry."
                : nil
        )
    }

    func replacePersonalAccessToken(
        _ token: PersonalAccessToken,
        replacing account: GitHubAccount
    ) async throws -> AccountSessionSnapshot {
        let replacement = try await AccountCredentialReplacementService(
            secretStore: secretStore,
            vaultRegistry: vaultRegistry
        ).replace(personalAccessToken: token, for: account)
        return try await restoredSnapshot(
            credentialActionNotice: replacement.retiredCredentialCleanupFailed
                ? "The new credential is active, but Triage could not erase the retired Keychain entry."
                : nil
        )
    }

    func removeAccount(_ accountID: AccountID) async throws {
        try await AccountDataRemovalService(
            vaultRegistry: vaultRegistry,
            secretStore: secretStore,
            applicationSupportDirectory: applicationSupportDirectory,
            cachesDirectory: cachesDirectory,
            willBeginCryptoErasureForAccount: drainAccountBeforeCryptoErasure
        ).removeAllPrivateData(for: accountID)
        await GitHubRateLimitControllerRegistry.shared.removeController(for: accountID)
    }

    func restoreVerifiedMigrationBackup(
        for accountID: AccountID,
        migrationID: String
    ) async throws -> AccountSessionSnapshot {
        guard let keyData = try await secretStore.read(
            kind: .vaultKey,
            accountID: accountID,
            credentialID: nil
        ) else {
            throw VaultError.invalidMigrationBackup
        }
        let vaultKey = try VaultKey(data: keyData)
        // The registry repeats verification immediately before installing the
        // copy, so the UI's earlier recovery snapshot cannot authorize a
        // stale or replaced backup.
        try await vaultRegistry.restoreVerifiedMigrationBackup(
            accountID: accountID,
            vaultKey: vaultKey,
            migrationID: migrationID
        )
        return try await restoredSnapshot()
    }

    private func restoredSnapshot(credentialActionNotice: String? = nil) async throws -> AccountSessionSnapshot {
        let result = try await restoreAccountState()
        return try AccountSessionSnapshot(
            accounts: result.accounts,
            organizationsByAccount: result.organizationsByAccount,
            organizationAccessesByAccount: result.organizationAccessesByAccount,
            accountCapabilitiesByAccount: result.accountCapabilitiesByAccount,
            unavailableAccountIDs: Set(result.unavailableAccountIDs),
            vaultRecoveryIssues: result.vaultRecoveryIssues,
            credentialActionNotice: credentialActionNotice
        )
    }

    static func organizationForInventoryReplay(
        _ value: GitHubOrganizationDTO
    ) throws -> GitHubOrganization {
        guard let nodeID = GitHubNodeID(rawValue: value.nodeID),
              let organizationID = OrganizationID(rawValue: value.nodeID)
        else {
            throw AccountConnectionError.invalidGitHubIdentity
        }
        return GitHubOrganization(
            id: organizationID,
            githubOrganizationID: value.id,
            nodeID: nodeID,
            login: value.login,
            avatarURL: value.avatarURL
        )
    }

}
