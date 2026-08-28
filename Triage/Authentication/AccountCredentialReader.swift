import Foundation

enum AccountCredentialReaderError: Error, Equatable, Sendable {
    case missingAccessToken
    case invalidAccessTokenEncoding
}

actor AccountCredentialReader {
    private let secretStore: KeychainSecretStore

    init(secretStore: KeychainSecretStore) {
        self.secretStore = secretStore
    }

    func accessToken(for account: GitHubAccount) async throws -> SecretValue {
        let kind: TriageSecretKind = account.authenticationKind == .oauth
            ? .oauthAccessToken
            : .personalAccessToken
        guard let data = try await secretStore.read(
            kind: kind,
            accountID: account.id,
            credentialID: account.credentialID
        ) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw AccountCredentialReaderError.invalidAccessTokenEncoding
        }
        return SecretValue(value)
    }
}
