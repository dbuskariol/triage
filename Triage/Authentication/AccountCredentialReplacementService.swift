import Foundation

enum AccountCredentialReplacementError: Error, Equatable, Sendable {
    case invalidGitHubIdentity
    case immutableIdentityMismatch
    case authenticationKindMismatch
    case stagedCredentialCleanupFailed
}

private enum CredentialSecretRemovalError: Error, Sendable {
    case incomplete
}

struct AccountCredentialReplacementResult: Sendable {
    let account: GitHubAccount
    let retiredCredentialCleanupFailed: Bool
}

enum CredentialReplacement {
    static func updatedAccount(
        _ account: GitHubAccount,
        authenticatedUser: GitHubUserDTO,
        credentialID: CredentialID,
        accessTokenExpiresAt: Date?,
        refreshTokenExpiresAt: Date?,
        at date: Date
    ) throws -> GitHubAccount {
        guard let nodeID = GitHubNodeID(rawValue: authenticatedUser.nodeID) else {
            throw AccountCredentialReplacementError.invalidGitHubIdentity
        }
        guard account.githubUserID == authenticatedUser.id, account.nodeID == nodeID else {
            throw AccountCredentialReplacementError.immutableIdentityMismatch
        }
        return account.replacingCredential(
            credentialID: credentialID,
            login: authenticatedUser.login,
            displayName: authenticatedUser.name,
            avatarURL: authenticatedUser.avatarURL,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            status: CredentialLifecycle.status(
                authenticationKind: account.authenticationKind,
                accessTokenExpiresAt: accessTokenExpiresAt,
                refreshTokenExpiresAt: refreshTokenExpiresAt,
                at: date
            ),
            validatedAt: date
        )
    }
}

actor AccountCredentialReplacementService {
    private let secretStore: KeychainSecretStore
    private let vaultRegistry: VaultRegistry
    private let clock: @Sendable () -> Date

    init(
        secretStore: KeychainSecretStore,
        vaultRegistry: VaultRegistry,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.secretStore = secretStore
        self.vaultRegistry = vaultRegistry
        self.clock = clock
    }

    func replace(
        personalAccessToken: PersonalAccessToken,
        for account: GitHubAccount
    ) async throws -> AccountCredentialReplacementResult {
        guard account.authenticationKind == personalAccessToken.kind.authenticationKind else {
            throw AccountCredentialReplacementError.authenticationKindMismatch
        }
        return try await replace(
            accessToken: personalAccessToken.value,
            refreshToken: nil,
            accessTokenLifetime: nil,
            refreshTokenLifetime: nil,
            for: account
        )
    }

    func replace(
        oauthTokenResponse: AuthBrokerTokenResponse,
        for account: GitHubAccount
    ) async throws -> AccountCredentialReplacementResult {
        guard account.authenticationKind == .oauth else {
            throw AccountCredentialReplacementError.authenticationKindMismatch
        }
        return try await replace(
            accessToken: oauthTokenResponse.accessToken.value,
            refreshToken: oauthTokenResponse.refreshToken?.value,
            accessTokenLifetime: oauthTokenResponse.expiresIn,
            refreshTokenLifetime: oauthTokenResponse.refreshTokenExpiresIn,
            for: account
        )
    }

    private func replace(
        accessToken: SecretValue,
        refreshToken: SecretValue?,
        accessTokenLifetime: TimeInterval?,
        refreshTokenLifetime: TimeInterval?,
        for account: GitHubAccount
    ) async throws -> AccountCredentialReplacementResult {
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(),
            credential: accessToken
        )
        let authenticatedUser = try await GitHubIdentityClient(client: client).authenticatedUser().value
        try Task.checkCancellation()

        let date = clock()
        let accessTokenExpiresAt = accessTokenLifetime.map { date.addingTimeInterval($0) }
        let refreshTokenExpiresAt = refreshTokenLifetime.map { date.addingTimeInterval($0) }
        let replacementCredentialID = CredentialID.make()
        let updatedAccount = try CredentialReplacement.updatedAccount(
            account,
            authenticatedUser: authenticatedUser,
            credentialID: replacementCredentialID,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            at: date
        )
        guard let vaultKey = try await secretStore.readVaultKey(for: account.id) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
        let accessTokenKind: TriageSecretKind = account.authenticationKind == .oauth
            ? .oauthAccessToken
            : .personalAccessToken

        do {
            try await secretStore.write(
                Data(accessToken.rawValue.utf8),
                kind: accessTokenKind,
                accountID: account.id,
                credentialID: replacementCredentialID
            )
            if account.authenticationKind == .oauth, let refreshToken {
                try await secretStore.write(
                    Data(refreshToken.rawValue.utf8),
                    kind: .oauthRefreshToken,
                    accountID: account.id,
                    credentialID: replacementCredentialID
                )
            }
            try Task.checkCancellation()
            try await AccountRepository(vault: vault).save(
                updatedAccount,
                credentialRevision: CredentialRevision(rawValue: UUID().uuidString.lowercased())!
            )
        } catch {
            do {
                try await removeCredentials(
                    for: account,
                    credentialID: replacementCredentialID
                )
            } catch {
                throw AccountCredentialReplacementError.stagedCredentialCleanupFailed
            }
            throw error
        }
        let retiredCredentialCleanupFailed: Bool
        do {
            try await removeCredentials(for: account, credentialID: account.credentialID)
            retiredCredentialCleanupFailed = false
        } catch {
            retiredCredentialCleanupFailed = true
        }
        return AccountCredentialReplacementResult(
            account: updatedAccount,
            retiredCredentialCleanupFailed: retiredCredentialCleanupFailed
        )
    }

    private func removeCredentials(
        for account: GitHubAccount,
        credentialID: CredentialID
    ) async throws {
        let accessTokenKind: TriageSecretKind = account.authenticationKind == .oauth
            ? .oauthAccessToken
            : .personalAccessToken
        var removalFailed = false
        do {
            try await secretStore.remove(
                kind: accessTokenKind,
                accountID: account.id,
                credentialID: credentialID
            )
        } catch {
            removalFailed = true
        }
        if account.authenticationKind == .oauth {
            do {
                try await secretStore.remove(
                    kind: .oauthRefreshToken,
                    accountID: account.id,
                    credentialID: credentialID
                )
            } catch {
                removalFailed = true
            }
        }
        if removalFailed {
            throw CredentialSecretRemovalError.incomplete
        }
    }
}
