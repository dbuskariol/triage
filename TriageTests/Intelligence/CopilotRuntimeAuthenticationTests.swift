import Foundation
import XCTest

@testable import Triage

final class CopilotRuntimeAuthenticationTests: XCTestCase {
    func testAIStaysBlockedUntilEveryIndependentGateIsTrue() {
        let base = CopilotAccountAuthorizationState(
            runtime: .ready,
            authentication: .authenticated,
            isEntitled: true,
            hasOrganizationConsent: true
        )
        XCTAssertTrue(base.permitsAI)
        XCTAssertFalse(CopilotAccountAuthorizationState(runtime: .missing, authentication: .authenticated, isEntitled: true, hasOrganizationConsent: true).permitsAI)
        XCTAssertFalse(CopilotAccountAuthorizationState(runtime: .ready, authentication: .signedOut, isEntitled: true, hasOrganizationConsent: true).permitsAI)
        XCTAssertFalse(CopilotAccountAuthorizationState(runtime: .ready, authentication: .authenticated, isEntitled: false, hasOrganizationConsent: true).permitsAI)
        XCTAssertFalse(CopilotAccountAuthorizationState(runtime: .ready, authentication: .authenticated, isEntitled: true, hasOrganizationConsent: false).permitsAI)
    }

    func testConsentAndEntitlementRejectBeforeRuntimeOrCredentialAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "triage-copilot-auth-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = SecretStoreSpy()
        let service = CopilotRuntimeAuthenticationService(applicationSupportDirectory: root, secretStore: secrets)
        let account = makeAccount()
        let organizationID = self.organizationID

        await assertAsyncThrows {
            try await service.authenticate(account: account, organizationID: organizationID, hasOrganizationConsent: false, isEntitled: true)
        } verify: { XCTAssertEqual($0 as? CopilotAuthenticationError, .consentRequired) }
        await assertAsyncThrows {
            try await service.authenticate(account: account, organizationID: organizationID, hasOrganizationConsent: true, isEntitled: false)
        } verify: { XCTAssertEqual($0 as? CopilotAuthenticationError, .entitlementRequired) }
        let readCount = await secrets.readCount
        XCTAssertEqual(readCount, 0)
    }

    func testIdentityMismatchIsExplicitAndCannotPermitAI() {
        let state = CopilotAccountAuthorizationState(
            runtime: .ready,
            authentication: .identityMismatch(expected: 10, actual: 11),
            isEntitled: true,
            hasOrganizationConsent: true
        )
        XCTAssertFalse(state.permitsAI)
    }

    func testXPCAuthenticatorUsesOnlyBoundFrameRequestAndDoesNotExposeCredentialInDescription() async throws {
        let spy = CopilotAuthenticationClientSpy()
        let authenticator = CopilotXPCAuthenticator(makeClient: { spy })
        let accountID = AccountID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let organizationID = self.organizationID
        let credential = SecretValue("test-token-must-not-appear-in-diagnostics")

        let result = try await authenticator.authenticateWithEphemeralCredential(
            accountID: accountID,
            organizationID: organizationID,
            credential: credential
        )

        XCTAssertTrue(result.isAuthenticated)
        XCTAssertEqual(result.host, "github.com")
        let requestDescription = await spy.requestDescription
        XCTAssertFalse(requestDescription.contains(credential.rawValue))
        XCTAssertTrue(requestDescription.contains("<redacted>"))
    }

    func testXPCAuthenticatorRetainsEachScopeAndShutsItDownOnDisconnect() async throws {
        let spy = CopilotAuthenticationClientSpy()
        let factory = CopilotAuthenticationClientFactory(client: spy)
        let authenticator = CopilotXPCAuthenticator(makeClient: { factory.makeClient() })
        let accountID = AccountID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let organizationID = self.organizationID
        let credential = SecretValue("test-token-must-not-persist")

        _ = try await authenticator.authenticateWithEphemeralCredential(
            accountID: accountID,
            organizationID: organizationID,
            credential: credential
        )
        _ = try await authenticator.authenticateWithEphemeralCredential(
            accountID: accountID,
            organizationID: organizationID,
            credential: credential
        )

        XCTAssertEqual(factory.makeCount, 1)
        await authenticator.removeSession(
            profileDirectory: URL(fileURLWithPath: "/private/test-profiles/\(accountID.rawValue)")
        )
        let shutdownCount = await spy.shutdownCount
        XCTAssertEqual(shutdownCount, 1)
    }

    func testXPCAuthenticatorListsModelsThroughItsRetainedAuthenticatedScope() async throws {
        let spy = CopilotAuthenticationClientSpy()
        let factory = CopilotAuthenticationClientFactory(client: spy)
        let authenticator = CopilotXPCAuthenticator(makeClient: { factory.makeClient() })
        let accountID = AccountID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let organizationID = self.organizationID

        _ = try await authenticator.authenticateWithEphemeralCredential(
            accountID: accountID,
            organizationID: organizationID,
            credential: SecretValue("test-token-must-not-persist")
        )
        let models = try await authenticator.models(accountID: accountID, organizationID: organizationID)

        XCTAssertEqual(models.map(\.id), ["model-a"])
        XCTAssertEqual(factory.makeCount, 1)
        let modelRequestCount = await spy.modelRequestCount
        XCTAssertEqual(modelRequestCount, 1)
    }

    func testClassicPersonalAccessTokensCannotStartAnUnavailableDeviceLogin() async {
        let authenticator = CopilotXPCAuthenticator()
        await assertAsyncThrows {
            try await authenticator.authenticateWithDeviceLogin(
                accountID: AccountID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
                organizationID: self.organizationID
            )
        } verify: {
            XCTAssertEqual($0 as? CopilotAuthenticationError, .deviceLoginUnavailable)
        }
    }

    private func makeAccount() -> GitHubAccount {
        GitHubAccount(
            id: AccountID(rawValue: "copilot-auth-test")!,
            githubUserID: 10,
            nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjEw")!,
            login: "test",
            authenticationKind: .oauth,
            credentialID: CredentialID(rawValue: "copilot-auth-credential")!,
            credentialStatus: .active,
            createdAt: .now
        )
    }

    private var organizationID: OrganizationID {
        OrganizationID(rawValue: "copilot-auth-organization")!
    }
}

private actor CopilotAuthenticationClientSpy: TriageCopilotHelping {
    private(set) var requestDescription = ""
    private(set) var shutdownCount = 0
    private(set) var modelRequestCount = 0

    func health(_: CopilotHealthRequest) async throws -> CopilotHealthResponse { throw CancellationError() }

    func authenticate(_ request: CopilotAuthenticateRequest) async throws -> CopilotAuthenticationResponse {
        requestDescription = String(describing: request)
        return CopilotAuthenticationResponse(
            header: .init(
                requestID: request.header.requestID,
                accountID: request.header.accountID,
                organizationID: request.header.organizationID,
                status: .authentication
            ),
            authentication: .init(host: "github.com", login: "test", authenticationType: "token", isAuthenticated: true)
        )
    }

    func models(_ request: CopilotModelsRequest) async throws -> CopilotModelsResponse {
        modelRequestCount += 1
        return CopilotModelsResponse(
            header: .init(
                requestID: request.header.requestID,
                accountID: request.header.accountID,
                organizationID: request.header.organizationID,
                status: .models
            ),
            models: [.init(id: "model-a", displayName: "Model A", isDefault: false)]
        )
    }
    func analyze(_: CopilotAnalyzeRequest) async throws -> CopilotAnalysisResponse { throw CancellationError() }
    func cancel(_: CopilotCancelRequest) async throws -> CopilotCancelResponse { throw CancellationError() }
    func shutdown(_ request: CopilotShutdownRequest) async throws -> CopilotShutdownResponse {
        shutdownCount += 1
        return CopilotShutdownResponse(
            header: .init(
                requestID: request.header.requestID,
                accountID: request.header.accountID,
                organizationID: request.header.organizationID,
                status: .shutdown
            )
        )
    }
}

private final class CopilotAuthenticationClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let client: any TriageCopilotHelping
    private var count = 0

    init(client: any TriageCopilotHelping) {
        self.client = client
    }

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func makeClient() -> any TriageCopilotHelping {
        lock.lock()
        count += 1
        lock.unlock()
        return client
    }
}

private actor SecretStoreSpy: SecretStore {
    private(set) var readCount = 0

    func read(kind _: TriageSecretKind, accountID _: AccountID, credentialID _: CredentialID?) -> Data? {
        readCount += 1
        return nil
    }

    func write(_ value: Data, kind: TriageSecretKind, accountID: AccountID, credentialID: CredentialID?) {}
    func remove(kind: TriageSecretKind, accountID: AccountID, credentialID: CredentialID?) {}
    func accountIDs() -> [AccountID] { [] }
}

private func assertAsyncThrows<T>(
    _ expression: @escaping () async throws -> T,
    verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
