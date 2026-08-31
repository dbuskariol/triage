import Foundation

enum CredentialLifecycle {
    static let expirationWarningInterval: TimeInterval = 5 * 60

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
