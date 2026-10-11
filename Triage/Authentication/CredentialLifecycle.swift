import Foundation
import OSLog

enum CredentialLifecycle {
    /// OAuth access tokens are renewed this close to expiry.
    static let expirationWarningInterval: TimeInterval = 5 * 60
    /// Personal access tokens can't be renewed by Triage, so warn a week ahead.
    static let personalAccessTokenWarningInterval: TimeInterval = 7 * 24 * 60 * 60

    static func status(for account: GitHubAccount, at date: Date) -> CredentialStatus {
        status(
            authenticationKind: account.authenticationKind,
            accessTokenExpiresAt: account.accessTokenExpiresAt,
            refreshTokenExpiresAt: account.refreshTokenExpiresAt,
            at: date
        )
    }

    static func status(
        authenticationKind: AuthenticationKind,
        accessTokenExpiresAt: Date?,
        refreshTokenExpiresAt: Date?,
        at date: Date
    ) -> CredentialStatus {
        guard authenticationKind == .oauth else {
            guard let accessExpiration = accessTokenExpiresAt else { return .active }
            if accessExpiration <= date { return .expired }
            if accessExpiration <= date.addingTimeInterval(personalAccessTokenWarningInterval) { return .expiring }
            return .active
        }
        if let refreshExpiration = refreshTokenExpiresAt, refreshExpiration <= date {
            return .expired
        }
        if let accessExpiration = accessTokenExpiresAt,
           accessExpiration <= date.addingTimeInterval(expirationWarningInterval) {
            return .expiring
        }
        return .active
    }

    static func failureStatus(for error: Error) -> CredentialStatus? {
        switch error {
        case is AccountCredentialReaderError:
            return .missing
        case let error as OAuthCredentialRefreshError:
            switch error {
            case .vaultKeyUnavailable:
                return .missing
            case .refreshTokenUnavailable, .refreshTokenEncodingInvalid, .credentialRollbackFailed:
                return .expired
            case .staleAccountAuthority:
                // A newer credential authority superseded this refresh. It is
                // not evidence that the current credential is invalid.
                return nil
            }
        case let error as AuthBrokerClientError:
            guard case let .broker(failure) = error else { return nil }
            switch failure.code {
            case .invalidGrant, .authorizationDenied:
                return .revoked
            case .invalidRequest, .invalidClient, .temporarilyUnavailable, .unavailable:
                return nil
            }
        case let error as GitHubFailure where error.kind == .unauthorized:
            return .revoked
        default:
            return nil
        }
    }

    static func restoredStatus(
        for account: GitHubAccount,
        hasAccessToken: Bool,
        at date: Date
    ) -> CredentialStatus {
        guard hasAccessToken else {
            return .missing
        }
        switch account.credentialStatus {
        case .expired, .revoked, .missing, .capabilityLimited:
            return account.credentialStatus
        case .active, .expiring:
            return status(for: account, at: date)
        }
    }

    static func reconnectMessage(for status: CredentialStatus) -> String? {
        switch status {
        case .missing:
            return "GitHub credentials are unavailable. Reconnect this account to resume syncing."
        case .expired:
            return "GitHub credentials have expired. Reconnect this account to resume syncing."
        case .revoked:
            return "GitHub credentials were revoked. Reconnect this account to resume syncing."
        case .active, .expiring, .capabilityLimited:
            return nil
        }
    }
}

extension CredentialLifecycle {
    /// The account as GitHub's latest response describes its credential, or
    /// `nil` when nothing the user can see has changed.
    static func account(
        _ account: GitHubAccount,
        observing observation: GitHubCredentialObservation,
        at date: Date
    ) -> GitHubAccount? {
        let updated: GitHubAccount
        switch observation {
        case .accepted(let expiresAt):
            // OAuth expirations come from the token exchange, which also drives renewal.
            let accessTokenExpiresAt = account.authenticationKind == .oauth ? account.accessTokenExpiresAt : expiresAt
            updated = account.replacingCredentialExpiration(
                accessTokenExpiresAt: accessTokenExpiresAt,
                refreshTokenExpiresAt: account.refreshTokenExpiresAt,
                status: status(
                    authenticationKind: account.authenticationKind,
                    accessTokenExpiresAt: accessTokenExpiresAt,
                    refreshTokenExpiresAt: account.refreshTokenExpiresAt,
                    at: date
                ),
                validatedAt: date
            )
        case .rejected:
            let pastExpiration = account.accessTokenExpiresAt.map { $0 <= date } ?? false
            updated = account.replacingCredentialStatus(pastExpiration ? .expired : .revoked)
        }
        guard updated.credentialStatus != account.credentialStatus
            || updated.accessTokenExpiresAt != account.accessTokenExpiresAt
        else { return nil }
        return updated
    }
}

/// Saves what GitHub reports about an account's credential, so Settings and
/// the workspace show when a token is about to expire or has stopped working.
struct GitHubCredentialHealthRecorder: Sendable {
    private static let logger = Logger(subsystem: "com.triage.mac", category: "GitHub")

    let vault: AccountVault
    var now: @Sendable () -> Date = Date.init

    /// Returns the updated account when it changed. Observations about a
    /// credential that has since been replaced are ignored.
    func record(
        _ observation: GitHubCredentialObservation,
        accountID: AccountID,
        credentialID: CredentialID
    ) async -> GitHubAccount? {
        do {
            let repository = AccountRepository(vault: vault)
            guard let account = try await repository.accounts().first(where: { $0.id == accountID }),
                  account.credentialID == credentialID,
                  let updated = CredentialLifecycle.account(account, observing: observation, at: now())
            else { return nil }
            let revision = try await repository.credentialRevision(for: accountID)
            try await repository.save(updated, credentialRevision: revision, expectedCredentialRevision: revision)
            Self.logger.notice("credential status=\(updated.credentialStatus.rawValue, privacy: .public) expires=\(updated.accessTokenExpiresAt != nil, privacy: .public)")
            return updated
        } catch {
            Self.logger.error("credential-record outcome=failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            return nil
        }
    }
}
