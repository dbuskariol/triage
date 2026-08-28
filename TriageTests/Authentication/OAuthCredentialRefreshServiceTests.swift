import XCTest
@testable import Triage

final class OAuthCredentialRefreshServiceTests: XCTestCase {
    func testPersonalAccessTokensNeverEnterTheOAuthRefreshPath() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = GitHubAccount(
            id: AccountID(rawValue: "account-1")!,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_kgDOExample")!,
            login: "octocat",
            authenticationKind: .fineGrainedPersonalAccessToken,
            credentialID: CredentialID(rawValue: "credential-1")!,
            credentialStatus: .active,
            accessTokenExpiresAt: now.addingTimeInterval(-1),
            refreshTokenExpiresAt: now.addingTimeInterval(-1),
            createdAt: now
        )
        let service = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: RejectingSecretStore(),
            vaultRegistry: try VaultRegistry(
                rootDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            clock: { now },
            broker: RejectingBroker()
        )

        XCTAssertEqual(try await service.refreshIfNeeded(account), account)
    }

    func testRefreshServiceValidatesBrokerURLEvenWithAnInjectedBroker() throws {
        XCTAssertThrowsError(
            try OAuthCredentialRefreshService(
                brokerURL: URL(string: "http://oauth.triage.example")!,
                secretStore: RejectingSecretStore(),
                vaultRegistry: try VaultRegistry(
                    rootDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                ),
                broker: RejectingBroker()
            )
        ) { error in
            XCTAssertEqual(error as? AuthBrokerClientError, .invalidBaseURL)
        }
    }
}

private actor RejectingSecretStore: SecretStore {
    func read(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws -> Data? {
        XCTFail("PAT refresh must not access secrets.")
        throw URLError(.badServerResponse)
    }

    func write(
        _ value: Data,
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws {
        XCTFail("PAT refresh must not write secrets.")
        throw URLError(.badServerResponse)
    }

    func remove(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws {
        XCTFail("PAT refresh must not remove secrets.")
        throw URLError(.badServerResponse)
    }
}

private actor RejectingBroker: OAuthTokenRefreshing {
    func refresh(
        _ request: AuthBrokerRefreshRequest
    ) async throws -> AuthBrokerTokenResponse {
        XCTFail("PAT refresh must not contact the OAuth broker.")
        throw URLError(.badServerResponse)
    }
}
