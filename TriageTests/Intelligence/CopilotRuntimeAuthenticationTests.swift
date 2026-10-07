import Foundation
import XCTest

@testable import Triage

final class CopilotRuntimeAuthenticationTests: XCTestCase {
    func testRequestIDsUseTheCanonicalLowercaseXPCRepresentation() throws {
        let id = UUID(uuidString: "ABCDEFAB-ABCD-4ABC-8ABC-ABCDEFABCDEF")!
        let accountID = AccountID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let wire = CopilotWireRequest(
            protocolVersion: CopilotIPC.version, requestID: id,
            accountID: accountID, organizationID: organizationID, operation: .authenticate
        )
        let health = CopilotHealthRequest(
            accountID: accountID, organizationID: organizationID, requestID: id
        )
        for data in [try JSONEncoder().encode(wire), try JSONEncoder().encode(health)] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["request_id"] as? String, id.uuidString.lowercased())
        }
    }

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

    func testAvailabilityPresentationDoesNotCallEveryIncompleteGateBlocked() {
        let base = CopilotAccountAuthorizationState(
            runtime: .ready,
            authentication: .authenticated,
            isEntitled: true,
            hasOrganizationConsent: true
        )

        XCTAssertEqual(
            CopilotAvailabilityPresentation(
                authorization: base,
                isEffectivelyAvailable: true,
                authenticationKind: .oauth
            ),
            .available
        )
        XCTAssertEqual(
            CopilotAvailabilityPresentation(
                authorization: .init(
                    runtime: .ready,
                    authentication: .signedOut,
                    isEntitled: true,
                    hasOrganizationConsent: true
                ),
                isEffectivelyAvailable: false,
                authenticationKind: .oauth
            ),
            .signInRequired
        )
        XCTAssertEqual(
            CopilotAvailabilityPresentation(
                authorization: .init(
                    runtime: .ready,
                    authentication: .authenticated,
                    isEntitled: true,
                    hasOrganizationConsent: false
                ),
                isEffectivelyAvailable: false,
                authenticationKind: .oauth
            ),
            .consentRequired
        )
        XCTAssertEqual(
            CopilotAvailabilityPresentation(
                authorization: .init(
                    runtime: .ready,
                    authentication: .identityMismatch(expected: 10, actual: 11),
                    isEntitled: true,
                    hasOrganizationConsent: true
                ),
                isEffectivelyAvailable: false,
                authenticationKind: .oauth
            ),
            .blocked
        )
        XCTAssertEqual(
            CopilotAvailabilityPresentation(
                authorization: base,
                isEffectivelyAvailable: false,
                authenticationKind: .oauth
            ),
            .unavailable
        )
        XCTAssertEqual(
            CopilotAvailabilityPresentation(
                authorization: .init(
                    runtime: .ready,
                    authentication: .signedOut,
                    isEntitled: true,
                    hasOrganizationConsent: true
                ),
                isEffectivelyAvailable: false,
                authenticationKind: .classicPersonalAccessToken
            ),
            .signInRequired
        )
    }

    func testSignInRemainsActionableBeforeEntitlementIsKnown() {
        for kind in [AuthenticationKind.oauth, .classicPersonalAccessToken, .fineGrainedPersonalAccessToken] {
            XCTAssertEqual(
                CopilotAvailabilityPresentation(
                    authorization: .init(
                        runtime: .ready,
                        authentication: .signedOut,
                        isEntitled: false,
                        hasOrganizationConsent: true
                    ),
                    isEffectivelyAvailable: false,
                    authenticationKind: kind
                ),
                .signInRequired
            )
        }
    }

    func testStateQueryCannotRestoreAuthenticationAfterDisconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "triage-copilot-state-fence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeStatus = RuntimeStatusGate()
        let service = CopilotRuntimeAuthenticationService(
            applicationSupportDirectory: root,
            secretStore: SecretStoreSpy(),
            runtimeStatusProvider: { await runtimeStatus.wait() }
        )
        let account = makeAccount()

        await assertAsyncThrows {
            try await service.authenticate(
                account: account,
                organizationID: self.organizationID,
                hasOrganizationConsent: false,
                isEntitled: true
            )
        } verify: { XCTAssertEqual($0 as? CopilotAuthenticationError, .consentRequired) }

        let staleState = Task { await service.state(for: account.id) }
        await runtimeStatus.waitUntilQueried()
        await service.disconnect(accountID: account.id)
        await runtimeStatus.release(.ready)

        let staleValue = await staleState.value
        XCTAssertEqual(staleValue, .unavailable)
        let currentState = await service.state(for: account.id)
        XCTAssertEqual(currentState.authentication, .signedOut)
    }

    func testFirstStateQueryPublishesVerifiedRuntimeAtInitialGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "triage-copilot-initial-state-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let service = CopilotRuntimeAuthenticationService(
            applicationSupportDirectory: root,
            secretStore: SecretStoreSpy(),
            runtimeStatusProvider: { .ready }
        )

        let state = await service.state(for: makeAccount().id)

        XCTAssertEqual(state.runtime, .ready)
        XCTAssertEqual(state.authentication, .signedOut)
        XCTAssertFalse(state.permitsAI)
    }

    func testAuthenticationIsRejectedForEntireRuntimeAcquisitionMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "triage-copilot-mutation-fence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = SuspendedRuntimeDownloader()
        let runtime = try CopilotRuntimeAcquisitionService(
            applicationSupportDirectory: root,
            architecture: .arm64,
            downloader: downloader
        )
        let secrets = SecretStoreSpy()
        let service = CopilotRuntimeAuthenticationService(
            applicationSupportDirectory: root,
            secretStore: secrets,
            runtime: runtime
        )
        let mutation = Task { try? await service.acquireRuntimeAtUserRequest() }
        await downloader.waitUntilStarted()

        await assertAsyncThrows {
            try await service.authenticate(
                account: self.makeAccount(),
                organizationID: self.organizationID,
                hasOrganizationConsent: true,
                isEntitled: true
            )
        } verify: { XCTAssertEqual($0 as? CopilotAuthenticationError, .runtimeUnavailable) }
        let readCount = await secrets.readCount
        XCTAssertEqual(readCount, 0)

        await downloader.release()
        _ = await mutation.value
    }

    func testXPCAuthenticatorUsesOnlyBoundFrameRequestAndDoesNotExposeCredentialInDescription() async throws {
        let spy = CopilotAuthenticationClientSpy()
        let authenticator = CopilotXPCAuthenticator(makeClient: { spy })
        let accountID = AccountID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let organizationID = self.organizationID
        let credential = CopilotEphemeralCredential(copying: Data("test-token-must-not-appear-in-diagnostics".utf8))

        let result = try await authenticator.authenticateWithEphemeralCredential(
            accountID: accountID,
            organizationID: organizationID,
            credential: credential
        )

        XCTAssertTrue(result.isAuthenticated)
        XCTAssertEqual(result.host, "github.com")
        let requestDescription = await spy.requestDescription
        XCTAssertFalse(requestDescription.contains("test-token-must-not-appear-in-diagnostics"))
        XCTAssertTrue(requestDescription.contains("<redacted>"))
    }

    func testXPCAuthenticatorRetainsEachScopeAndShutsItDownOnDisconnect() async throws {
        let spy = CopilotAuthenticationClientSpy()
        let factory = CopilotAuthenticationClientFactory(client: spy)
        let authenticator = CopilotXPCAuthenticator(makeClient: { factory.makeClient() })
        let accountID = AccountID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let organizationID = self.organizationID
        _ = try await authenticator.authenticateWithEphemeralCredential(
            accountID: accountID,
            organizationID: organizationID,
            credential: CopilotEphemeralCredential(copying: Data("test-token-must-not-persist".utf8))
        )
        _ = try await authenticator.authenticateWithEphemeralCredential(
            accountID: accountID,
            organizationID: organizationID,
            credential: CopilotEphemeralCredential(copying: Data("test-token-must-not-persist".utf8))
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
            credential: CopilotEphemeralCredential(copying: Data("test-token-must-not-persist".utf8))
        )
        let models = try await authenticator.models(accountID: accountID, organizationID: organizationID)

        XCTAssertEqual(models.map(\.id), ["model-a"])
        XCTAssertEqual(factory.makeCount, 1)
        let modelRequestCount = await spy.modelRequestCount
        XCTAssertEqual(modelRequestCount, 1)
    }

    func testXPCAuthenticatorKeepsTwoOrganizationScopesOnSeparateClients() async throws {
        let factory = DistinctCopilotAuthenticationClientFactory()
        let authenticator = CopilotXPCAuthenticator(makeClient: { factory.makeClient() })
        let accountID = AccountID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let firstOrganization = OrganizationID(rawValue: "org-1")!
        let secondOrganization = OrganizationID(rawValue: "org-2")!

        _ = try await authenticator.authenticateWithEphemeralCredential(
            accountID: accountID, organizationID: firstOrganization, credential: CopilotEphemeralCredential(copying: Data("test-token".utf8))
        )
        _ = try await authenticator.authenticateWithEphemeralCredential(
            accountID: accountID, organizationID: secondOrganization, credential: CopilotEphemeralCredential(copying: Data("test-token".utf8))
        )
        _ = try await authenticator.models(accountID: accountID, organizationID: firstOrganization)
        _ = try await authenticator.models(accountID: accountID, organizationID: secondOrganization)

        XCTAssertEqual(factory.makeCount, 2)
        let firstModelRequestCount = await factory.client(at: 0).modelRequestCount
        let secondModelRequestCount = await factory.client(at: 1).modelRequestCount
        XCTAssertEqual(firstModelRequestCount, 1)
        XCTAssertEqual(secondModelRequestCount, 1)
    }

    func testDisconnectFencesSuspendedAuthenticationBeforeItCanRetainSession() async throws {
        let client = SuspendedAuthenticationClient()
        let accountID = AccountID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let organizationID = self.organizationID
        let authenticator = CopilotXPCAuthenticator(makeClient: { client })
        let authentication = Task {
            try await authenticator.authenticateWithEphemeralCredential(
                accountID: accountID,
                organizationID: organizationID,
                credential: CopilotEphemeralCredential(copying: Data("test-token".utf8))
            )
        }

        await client.waitUntilAuthenticateStarted()
        await authenticator.removeSession(
            profileDirectory: URL(fileURLWithPath: "/private/test-profiles/\(accountID.rawValue)")
        )
        // Disconnect must stop an authentication helper before waiting for its
        // response; otherwise a runtime mutation can block on its shared lock.
        let shutdownCountBeforeRelease = await client.shutdownCount
        XCTAssertEqual(shutdownCountBeforeRelease, 1)
        await client.releaseAuthentication()

        let result = await authentication.result
        guard case let .failure(error) = result else {
            return XCTFail("Expected disconnected authentication to be fenced.")
        }
        XCTAssertTrue(error is CancellationError)
        await assertAsyncThrows {
            _ = try await authenticator.models(accountID: accountID, organizationID: organizationID)
        } verify: {
            XCTAssertEqual($0 as? CopilotAuthenticationError, .runtimeUnavailable)
        }
        let shutdownCount = await client.shutdownCount
        XCTAssertEqual(shutdownCount, 1)
    }


    func testStaleCredentialReferenceWriteCannotSurviveDisconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "triage-copilot-reference-disconnect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = makeAccount()
        let secrets = SuspendedReferenceSecretStore()
        let service = try await authenticatedService(
            root: root,
            account: account,
            secrets: secrets
        )
        let authentication = Task { [service, account, organizationID = organizationID] in
            try await service.authenticate(
                account: account,
                organizationID: organizationID,
                hasOrganizationConsent: true,
                isEntitled: true
            )
        }
        await secrets.waitUntilWrites(1)
        await service.disconnect(accountID: account.id)
        await secrets.releaseNextWrite()

        let result = await authentication.result
        guard case let .failure(error) = result else {
            return XCTFail("Expected stale authentication to be cancelled.")
        }
        XCTAssertTrue(error is CancellationError)
        let referenceCount = await secrets.referenceCount
        XCTAssertEqual(referenceCount, 0)
    }

    func testStaleCredentialReferenceCleanupCannotDeleteNewerAuthenticationReference() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "triage-copilot-reference-generation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = makeAccount()
        let secrets = SuspendedReferenceSecretStore()
        let service = try await authenticatedService(
            root: root,
            account: account,
            secrets: secrets
        )
        let first = Task { [service, account, organizationID = organizationID] in
            try await service.authenticate(
                account: account,
                organizationID: organizationID,
                hasOrganizationConsent: true,
                isEntitled: true
            )
        }
        await secrets.waitUntilWrites(1)
        let second = Task { [service, account, organizationID = organizationID] in
            try await service.authenticate(
                account: account,
                organizationID: organizationID,
                hasOrganizationConsent: true,
                isEntitled: true
            )
        }
        await secrets.waitUntilWrites(2)

        await secrets.releaseWrite(at: 1)
        _ = try await second.value
        await secrets.releaseWrite(at: 0)
        let firstResult = await first.result
        guard case let .failure(error) = firstResult else {
            return XCTFail("Expected the older authentication to be fenced.")
        }
        XCTAssertTrue(error is CancellationError)
        let referenceCount = await secrets.referenceCount
        XCTAssertEqual(referenceCount, 1)
    }

    func testStandardLoginUsesXPCWithoutForwardingAGitHubCredential() async throws {
        let spy = CopilotAuthenticationClientSpy()
        let authenticator = CopilotXPCAuthenticator(makeClient: { spy })

        let result = try await authenticator.authenticateWithDeviceLogin(
            accountID: AccountID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            organizationID: self.organizationID
        )
        XCTAssertTrue(result.isAuthenticated)
        let requestDescription = await spy.requestDescription
        XCTAssertFalse(requestDescription.isEmpty)
        let receivedCredential = await spy.receivedCredential
        XCTAssertFalse(receivedCredential)
        let allowsBrowser = await spy.allowsBrowser
        XCTAssertEqual(allowsBrowser, true)
    }

    func testRestorationNeverRequestsBrowserAuthorizationOrAGitHubToken() async throws {
        let spy = CopilotAuthenticationClientSpy()
        let authenticator = CopilotXPCAuthenticator(makeClient: { spy })
        let result = try await authenticator.restoreSession(
            accountID: AccountID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            organizationID: organizationID
        )
        XCTAssertTrue(result.isAuthenticated)
        let allowsBrowser = await spy.allowsBrowser
        let receivedCredential = await spy.receivedCredential
        XCTAssertEqual(allowsBrowser, false)
        XCTAssertFalse(receivedCredential)
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

    private func readyRuntime(at root: URL) throws -> CopilotRuntimeAcquisitionService {
        try CopilotRuntimeAcquisitionService(
            applicationSupportDirectory: root,
            architecture: .arm64,
            validator: ReadyRuntimeValidator(),
            files: ReadyRuntimeFiles()
        )
    }

    private func authenticatedService(
        root: URL,
        account: GitHubAccount,
        secrets: any SecretStore
    ) async throws -> CopilotRuntimeAuthenticationService {
        CopilotRuntimeAuthenticationService(
            applicationSupportDirectory: root,
            secretStore: secrets,
            authenticator: ImmediateRuntimeAuthenticator(),
            loadAuthenticatedUser: { _ in
                GitHubUserDTO(
                    id: account.githubUserID,
                    nodeID: account.nodeID.rawValue,
                    login: account.login,
                    name: nil,
                    avatarURL: nil
                )
            },
            runtime: try readyRuntime(at: root)
        )
    }
}

private actor CopilotAuthenticationClientSpy: TriageCopilotHelping {
    private(set) var requestDescription = ""
    private(set) var receivedCredential = false
    private(set) var allowsBrowser: Bool?
    private(set) var shutdownCount = 0
    private(set) var modelRequestCount = 0

    func health(_: CopilotHealthRequest) async throws -> CopilotHealthResponse { throw CancellationError() }

    func authenticate(_ request: CopilotAuthenticateRequest) async throws -> CopilotAuthenticationResponse {
        requestDescription = String(describing: request)
        receivedCredential = request.credential != nil
        allowsBrowser = request.allowsBrowser
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

private final class DistinctCopilotAuthenticationClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [CopilotAuthenticationClientSpy] = []

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.count
    }

    func makeClient() -> any TriageCopilotHelping {
        let client = CopilotAuthenticationClientSpy()
        lock.lock()
        clients.append(client)
        lock.unlock()
        return client
    }

    func client(at index: Int) -> CopilotAuthenticationClientSpy {
        lock.lock()
        defer { lock.unlock() }
        return clients[index]
    }
}

private actor SuspendedAuthenticationClient: TriageCopilotHelping {
    private var didStartAuthentication = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var shutdownCount = 0

    func health(_: CopilotHealthRequest) async throws -> CopilotHealthResponse { throw CancellationError() }

    func authenticate(_ request: CopilotAuthenticateRequest) async throws -> CopilotAuthenticationResponse {
        didStartAuthentication = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !isReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
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

    func models(_: CopilotModelsRequest) async throws -> CopilotModelsResponse {
        throw CopilotAuthenticationError.runtimeUnavailable
    }
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

    func waitUntilAuthenticateStarted() async {
        guard !didStartAuthentication else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseAuthentication() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor RuntimeStatusGate {
    private var queried = false
    private var status: CopilotRuntimeStatus?
    private var queryWaiters: [CheckedContinuation<Void, Never>] = []
    private var statusWaiters: [CheckedContinuation<CopilotRuntimeStatus, Never>] = []

    func wait() async -> CopilotRuntimeStatus {
        queried = true
        queryWaiters.forEach { $0.resume() }
        queryWaiters.removeAll()
        if let status { return status }
        return await withCheckedContinuation { statusWaiters.append($0) }
    }

    func waitUntilQueried() async {
        guard !queried else { return }
        await withCheckedContinuation { queryWaiters.append($0) }
    }

    func release(_ status: CopilotRuntimeStatus) {
        self.status = status
        statusWaiters.forEach { $0.resume(returning: status) }
        statusWaiters.removeAll()
    }
}

private actor SuspendedRuntimeDownloader: CopilotRuntimeDownloading {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func download(
        _: CopilotRuntimeArchive,
        to _: URL,
        maximumBytes _: Int64,
        progress _: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> String {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return "not-a-pinned-runtime"
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
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

private struct ReadyRuntimeValidator: CopilotRuntimeValidating {
    func validate(_: URL, architecture _: CopilotRuntimeArchitecture) throws {}
}

private struct ReadyRuntimeFiles: CopilotRuntimeFileManaging {
    func makeTemporaryDirectory() throws -> URL { throw CopilotRuntimeAcquisitionError.fileSystem }
    func removeIfPresent(_: URL) {}
    func installedExecutable(root: URL, release: CopilotRuntimeRelease, architecture: CopilotRuntimeArchitecture) -> URL {
        root.appending(path: release.version).appending(path: architecture.rawValue).appending(path: "copilot")
    }
    func install(_: URL, root _: URL, release _: CopilotRuntimeRelease, architecture _: CopilotRuntimeArchitecture) throws -> URL {
        throw CopilotRuntimeAcquisitionError.fileSystem
    }
    func removeInstalled(root _: URL, release _: CopilotRuntimeRelease, architecture _: CopilotRuntimeArchitecture) throws {}
    func scavengeStaleStages(root _: URL, release _: CopilotRuntimeRelease, architecture _: CopilotRuntimeArchitecture) throws {}
    func exists(_: URL) -> Bool { true }
}

private actor TokenSecretStore: SecretStore {
    func read(kind _: TriageSecretKind, accountID _: AccountID, credentialID _: CredentialID?) -> Data? {
        Data("test-token".utf8)
    }
    func write(_: Data, kind _: TriageSecretKind, accountID _: AccountID, credentialID _: CredentialID?) {}
    func remove(kind _: TriageSecretKind, accountID _: AccountID, credentialID _: CredentialID?) {}
    func accountIDs() -> [AccountID] { [] }
}

private actor SuspendedReferenceSecretStore: SecretStore {
    private var writes: [(credentialID: CredentialID, value: Data)] = []
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var references: [CredentialID: Data] = [:]

    var referenceCount: Int { references.count }

    func read(kind _: TriageSecretKind, accountID _: AccountID, credentialID _: CredentialID?) -> Data? {
        Data("test-token".utf8)
    }

    func write(_ value: Data, kind _: TriageSecretKind, accountID _: AccountID, credentialID: CredentialID?) async {
        guard let credentialID else { return }
        writes.append((credentialID, value))
        resumeWriteCountWaiters()
        await withCheckedContinuation { writeWaiters.append($0) }
        references[credentialID] = value
    }

    func remove(kind _: TriageSecretKind, accountID _: AccountID, credentialID: CredentialID?) {
        guard let credentialID else { return }
        references[credentialID] = nil
    }

    func accountIDs() -> [AccountID] { [] }

    func waitUntilWrites(_ count: Int) async {
        guard writes.count < count else { return }
        await withCheckedContinuation { writeCountWaiters.append((count, $0)) }
    }

    func releaseNextWrite() {
        guard !writeWaiters.isEmpty else { return }
        writeWaiters.removeFirst().resume()
    }

    func releaseWrite(at index: Int) {
        guard writeWaiters.indices.contains(index) else { return }
        writeWaiters.remove(at: index).resume()
    }

    private func resumeWriteCountWaiters() {
        let ready = writeCountWaiters.filter { writes.count >= $0.0 }
        writeCountWaiters.removeAll { writes.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private actor ImmediateRuntimeAuthenticator: CopilotRuntimeAuthenticating {
    func authenticateWithEphemeralCredential(
        accountID _: AccountID,
        organizationID _: OrganizationID,
        credential _: CopilotEphemeralCredential
    ) async throws -> CopilotRuntimeAuthenticationResult {
        .init(isAuthenticated: true, host: "github.com", login: "test", authenticationType: "token")
    }
    func authenticateWithDeviceLogin(accountID _: AccountID, organizationID _: OrganizationID) async throws -> CopilotRuntimeAuthenticationResult {
        .init(isAuthenticated: true, host: "github.com", login: "test", authenticationType: "device_code")
    }
    func models(accountID _: AccountID, organizationID _: OrganizationID) async throws -> [CopilotModel] { [] }
    func removeSession(profileDirectory _: URL) async {}
}

private actor SuspendedModelsAuthenticator: CopilotRuntimeAuthenticating {
    private var modelsStarted = false
    private var removeStarted = false
    private var modelsReleased = false
    private var removeReleased = false
    private var modelsStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var removeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var modelsWaiters: [CheckedContinuation<Void, Never>] = []
    private var removeWaiters: [CheckedContinuation<Void, Never>] = []

    func authenticateWithEphemeralCredential(
        accountID _: AccountID,
        organizationID _: OrganizationID,
        credential _: CopilotEphemeralCredential
    ) async throws -> CopilotRuntimeAuthenticationResult {
        .init(isAuthenticated: true, host: "github.com", login: "test", authenticationType: "token")
    }
    func authenticateWithDeviceLogin(accountID _: AccountID, organizationID _: OrganizationID) async throws -> CopilotRuntimeAuthenticationResult {
        .init(isAuthenticated: true, host: "github.com", login: "test", authenticationType: "device_code")
    }
    func models(accountID _: AccountID, organizationID _: OrganizationID) async throws -> [CopilotModel] {
        modelsStarted = true
        modelsStartWaiters.forEach { $0.resume() }
        modelsStartWaiters.removeAll()
        if !modelsReleased {
            await withCheckedContinuation { modelsWaiters.append($0) }
        }
        return [.init(id: "stale-model", displayName: "Stale Model", isDefault: false)]
    }
    func removeSession(profileDirectory _: URL) async {
        removeStarted = true
        removeStartWaiters.forEach { $0.resume() }
        removeStartWaiters.removeAll()
        if !removeReleased {
            await withCheckedContinuation { removeWaiters.append($0) }
        }
    }

    func waitUntilModelsStarted() async {
        guard !modelsStarted else { return }
        await withCheckedContinuation { modelsStartWaiters.append($0) }
    }
    func waitUntilRemoveSessionStarted() async {
        guard !removeStarted else { return }
        await withCheckedContinuation { removeStartWaiters.append($0) }
    }
    func releaseModels() {
        modelsReleased = true
        modelsWaiters.forEach { $0.resume() }
        modelsWaiters.removeAll()
    }
    func releaseRemoveSession() {
        removeReleased = true
        removeWaiters.forEach { $0.resume() }
        removeWaiters.removeAll()
    }
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
