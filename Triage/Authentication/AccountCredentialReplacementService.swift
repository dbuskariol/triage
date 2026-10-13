import Foundation

enum AccountCredentialReplacementError: Error, Equatable, Sendable {
    case invalidGitHubIdentity
    case immutableIdentityMismatch
    case authenticationKindMismatch
    case noAccessibleOrganizations
    case stagedCredentialCleanupFailed

    var recoveryDescription: String {
        switch self {
        case .invalidGitHubIdentity:
            "GitHub returned an unexpected account for this token. Try again."
        case .immutableIdentityMismatch:
            "This token belongs to a different GitHub account. Create the token while signed in as this account."
        case .authenticationKindMismatch:
            "This account signs in with GitHub. Use a personal access token only for accounts connected with one."
        case .noAccessibleOrganizations:
            "This token can't access any organization. Create it with your organization as the resource owner, and check whether the organization needs to approve it."
        case .stagedCredentialCleanupFailed:
            "Triage couldn't save the new token, and couldn't remove it from the Keychain. Try again."
        }
    }
}

/// The account a credential belongs to, when GitHub says it expires, and the
/// organizations it can access.
struct AuthenticatedGitHubCredential: Sendable {
    let user: GitHubUserDTO
    let expiresAt: Date?
    let organizations: [GitHubOrganizationDTO]
    /// Partial-results SSO evidence from the organization list, if any.
    var organizationSSOHeader: GitHubSSOHeader? = nil
}

private enum CredentialSecretRemovalError: Error, Sendable {
    case incomplete
}

struct AccountCredentialReplacementResult: Sendable {
    let account: GitHubAccount
    /// Exact durable authority written with the replacement credential. A
    /// post-replacement conditional replay must use this revision rather than
    /// deriving authority from a stale in-memory account snapshot.
    let credentialRevision: CredentialRevision
    let retiredCredentialCleanupFailed: Bool
}

enum CredentialReplacement {
    static func updatedAccount(
        _ account: GitHubAccount,
        authenticatedUser: GitHubUserDTO,
        credentialID: CredentialID,
        authenticationKind: AuthenticationKind,
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
            authenticationKind: authenticationKind,
            login: authenticatedUser.login,
            displayName: authenticatedUser.name,
            avatarURL: authenticatedUser.avatarURL,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            status: CredentialLifecycle.status(
                authenticationKind: authenticationKind,
                accessTokenExpiresAt: accessTokenExpiresAt,
                refreshTokenExpiresAt: refreshTokenExpiresAt,
                at: date
            ),
            validatedAt: date
        )
    }
}

actor AccountCredentialReplacementService {
    private let secretStore: any SecretStore
    private let vaultRegistry: VaultRegistry
    private let clock: @Sendable () -> Date
    private let loadAuthenticatedUser: @Sendable (SecretValue) async throws -> AuthenticatedGitHubCredential

    init(
        secretStore: any SecretStore,
        vaultRegistry: VaultRegistry,
        clock: @escaping @Sendable () -> Date = Date.init,
        loadAuthenticatedUser: @escaping @Sendable (SecretValue) async throws -> AuthenticatedGitHubCredential = { accessToken in
            let client = GitHubRESTClient(
                transport: try GitHubRESTTransport(),
                credential: accessToken
            )
            let identity = GitHubIdentityClient(client: client)
            let response = try await identity.authenticatedUser()
            let inventory = try await identity.allOrganizations()
            return AuthenticatedGitHubCredential(
                user: response.value,
                expiresAt: response.credentialExpiresAt,
                organizations: inventory.organizations,
                organizationSSOHeader: inventory.partialResultsSSOHeader
            )
        }
    ) {
        self.secretStore = secretStore
        self.vaultRegistry = vaultRegistry
        self.clock = clock
        self.loadAuthenticatedUser = loadAuthenticatedUser
    }

    /// Replaces a personal access token with a new one for the same GitHub
    /// account. Classic and fine-grained tokens can replace each other; the
    /// account's organizations and local data are kept.
    func replace(
        personalAccessToken: PersonalAccessToken,
        for account: GitHubAccount
    ) async throws -> AccountCredentialReplacementResult {
        guard account.authenticationKind != .oauth else {
            throw AccountCredentialReplacementError.authenticationKindMismatch
        }
        return try await replace(
            accessToken: personalAccessToken.value,
            refreshToken: nil,
            authenticationKind: personalAccessToken.kind.authenticationKind,
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
            authenticationKind: .oauth,
            accessTokenLifetime: oauthTokenResponse.expiresIn,
            refreshTokenLifetime: oauthTokenResponse.refreshTokenExpiresIn,
            for: account
        )
    }

    private func replace(
        accessToken: SecretValue,
        refreshToken: SecretValue?,
        authenticationKind: AuthenticationKind,
        accessTokenLifetime: TimeInterval?,
        refreshTokenLifetime: TimeInterval?,
        for account: GitHubAccount
    ) async throws -> AccountCredentialReplacementResult {
        let authenticated = try await loadAuthenticatedUser(accessToken)
        try Task.checkCancellation()
        // A fine-grained token sees only its resource owner; seeing none means
        // it was created for a personal account or is awaiting approval.
        if authenticationKind == .fineGrainedPersonalAccessToken, authenticated.organizations.isEmpty {
            throw AccountCredentialReplacementError.noAccessibleOrganizations
        }
        let organizations = try authenticated.organizations.map(OrganizationInventory.organization(from:))

        let date = clock()
        let accessTokenExpiresAt = accessTokenLifetime.map { date.addingTimeInterval($0) } ?? authenticated.expiresAt
        let refreshTokenExpiresAt = refreshTokenLifetime.map { date.addingTimeInterval($0) }
        let replacementCredentialID = CredentialID.make()
        let updatedAccount = try CredentialReplacement.updatedAccount(
            account,
            authenticatedUser: authenticated.user,
            credentialID: replacementCredentialID,
            authenticationKind: authenticationKind,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            at: date
        )
        guard let vaultKeyData = try await secretStore.read(
            kind: .vaultKey,
            accountID: account.id,
            credentialID: nil
        ) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        let vaultKey = try VaultKey(data: vaultKeyData)
        let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
        try Task.checkCancellation()
        let accessTokenKind: TriageSecretKind = account.authenticationKind == .oauth
            ? .oauthAccessToken
            : .personalAccessToken
        let credentialRevision = CredentialRevision(rawValue: UUID().uuidString.lowercased())!

        do {
            try await secretStore.write(
                Data(accessToken.rawValue.utf8),
                kind: accessTokenKind,
                accountID: account.id,
                credentialID: replacementCredentialID
            )
            try Task.checkCancellation()
            if account.authenticationKind == .oauth, let refreshToken {
                try await secretStore.write(
                    Data(refreshToken.rawValue.utf8),
                    kind: .oauthRefreshToken,
                    accountID: account.id,
                    credentialID: replacementCredentialID
                )
                try Task.checkCancellation()
            }
            let repository = AccountRepository(vault: vault)
            try await recordOrganizations(
                organizations, ssoHeader: authenticated.organizationSSOHeader,
                for: account.id, repository: repository, at: date
            )
            try await repository.save(
                updatedAccount,
                credentialRevision: credentialRevision
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
        return await finishReplacement(
            for: account,
            updatedAccount: updatedAccount,
            credentialRevision: credentialRevision
        )
    }

    /// Organizations the new credential can see become available; ones it
    /// can't are kept, with their local data, but marked inaccessible so they
    /// leave the organization list until a credential can see them again.
    private func recordOrganizations(
        _ organizations: [GitHubOrganization],
        ssoHeader: GitHubSSOHeader?,
        for accountID: AccountID,
        repository: AccountRepository,
        at date: Date
    ) async throws {
        let visible = Set(organizations.map(\.id))
        for organization in organizations {
            try await repository.save(organization, access: OrganizationInventory.access(
                accountID: accountID,
                organizationID: organization.id,
                state: OrganizationAccessEvaluator.state(
                    statusCode: 200, ssoHeader: ssoHeader?.scoped(to: organization.githubOrganizationID)
                ),
                at: date
            ))
        }
        for organization in try await repository.organizations(for: accountID) where !visible.contains(organization.id) {
            try await repository.save(organization, access: OrganizationInventory.access(
                accountID: accountID, organizationID: organization.id, state: .inaccessible, at: date
            ))
        }
    }

    private func finishReplacement(
        for account: GitHubAccount,
        updatedAccount: GitHubAccount,
        credentialRevision: CredentialRevision
    ) async -> AccountCredentialReplacementResult {
        let retiredCredentialCleanupFailed: Bool
        do {
            try await removeCredentials(for: account, credentialID: account.credentialID)
            retiredCredentialCleanupFailed = false
        } catch {
            retiredCredentialCleanupFailed = true
        }
        return AccountCredentialReplacementResult(
            account: updatedAccount,
            credentialRevision: credentialRevision,
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
