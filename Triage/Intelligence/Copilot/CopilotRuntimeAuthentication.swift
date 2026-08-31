import Foundation

/// UI-facing runtime state. This deliberately does not expose a filesystem
/// location: only the acquisition boundary may hold an executable path.
enum CopilotRuntimeStatus: Equatable, Sendable {
    case missing
    case downloading(receivedBytes: Int64, expectedBytes: Int64?)
    case verifying
    case ready
    case corrupt(String)
    case unsupported(String)
}

enum CopilotAuthenticationStatus: Equatable, Sendable {
    case signedOut
    case deviceLoginRequired
    case verifyingIdentity
    case authenticated
    case identityMismatch(expected: UInt64, actual: UInt64)
    case blocked(String)
    case failed(String)
}

struct CopilotAccountAuthorizationState: Equatable, Sendable {
    let runtime: CopilotRuntimeStatus
    let authentication: CopilotAuthenticationStatus
    let isEntitled: Bool
    let hasOrganizationConsent: Bool

    var permitsAI: Bool {
        guard case .ready = runtime,
              case .authenticated = authentication
        else { return false }
        return isEntitled && hasOrganizationConsent
    }

    static let unavailable = Self(
        runtime: .missing,
        authentication: .signedOut,
        isEntitled: false,
        hasOrganizationConsent: false
    )
}

enum CopilotAuthenticationError: Error, Equatable, Sendable {
    case consentRequired
    case entitlementRequired
    case runtimeUnavailable
    case identityMismatch(expected: UInt64, actual: UInt64)
    case deviceLoginUnavailable
    case credentialUnavailable
    case invalidGitHubIdentity
    case copilotIdentityMismatch
}

struct CopilotRuntimeAuthenticationResult: Equatable, Sendable {
    let isAuthenticated: Bool
    let host: String
    let login: String
    let authenticationType: String
}

/// The sole launch boundary for the approved runtime. Implementations receive
/// an already validated executable and an app-owned profile directory; they
/// must never consult PATH, a user profile, or ambient Copilot configuration.
protocol CopilotRuntimeAuthenticating: Sendable {
    func authenticateWithEphemeralCredential(
        accountID: AccountID,
        organizationID: OrganizationID,
        credential: SecretValue
    ) async throws -> CopilotRuntimeAuthenticationResult

    func authenticateWithDeviceLogin(
        accountID: AccountID,
        organizationID: OrganizationID
    ) async throws -> CopilotRuntimeAuthenticationResult
    func models(accountID: AccountID, organizationID: OrganizationID) async throws -> [CopilotModel]

    func removeSession(profileDirectory: URL) async
}

/// Explicit fallback used only by tests or configurations without the signed
/// XPC service. Production uses `CopilotXPCAuthenticator` and never falls
/// back to PATH or a token-bearing CLI config file.
struct UnavailableCopilotRuntimeAuthenticator: CopilotRuntimeAuthenticating {
    func authenticateWithEphemeralCredential(accountID _: AccountID, organizationID _: OrganizationID, credential _: SecretValue) async throws -> CopilotRuntimeAuthenticationResult {
        throw CopilotAuthenticationError.deviceLoginUnavailable
    }

    func authenticateWithDeviceLogin(accountID _: AccountID, organizationID _: OrganizationID) async throws -> CopilotRuntimeAuthenticationResult {
        throw CopilotAuthenticationError.deviceLoginUnavailable
    }
    func models(accountID _: AccountID, organizationID _: OrganizationID) async throws -> [CopilotModel] { throw CopilotAuthenticationError.runtimeUnavailable }

    func removeSession(profileDirectory _: URL) async {}
}

/// Authenticates only through the app-owned XPC service. The credential is
/// encoded into its one request frame and the response exposes only public
/// identity metadata. No CLI executable, environment, argument, or config
/// path is accepted here.
actor CopilotXPCAuthenticator: CopilotRuntimeAuthenticating {
    private struct SessionScope: Hashable, Sendable {
        let accountID: AccountID
        let organizationID: OrganizationID
    }

    private let makeClient: @Sendable () -> any TriageCopilotHelping
    // Keep the XPC transport alive after successful authentication. The
    // helper owns the authenticated engine, and an incidental client
    // deallocation is an XPC invalidation fence rather than a safe way to
    // retain that engine.
    private var sessions: [SessionScope: any TriageCopilotHelping] = [:]

    init(makeClient: @escaping @Sendable () -> any TriageCopilotHelping = {
        CopilotHelperClient(
            transport: CopilotXPCFrameTransport(service: CopilotXPCServiceClient())
        )
    }) {
        self.makeClient = makeClient
    }

    func authenticateWithEphemeralCredential(
        accountID: AccountID,
        organizationID: OrganizationID,
        credential: SecretValue
    ) async throws -> CopilotRuntimeAuthenticationResult {
        let scope = SessionScope(accountID: accountID, organizationID: organizationID)
        let helper = sessions[scope] ?? makeClient()
        let response = try await helper.authenticate(
            CopilotAuthenticateRequest(
                accountID: accountID,
                organizationID: organizationID,
                credential: credential
            )
        )
        guard response.authentication.isAuthenticated else {
            // Do not retain a transport whose helper explicitly rejected the
            // credential; that client must not keep a stale session alive.
            sessions.removeValue(forKey: scope)
            return .init(
                isAuthenticated: false,
                host: response.authentication.host,
                login: response.authentication.login,
                authenticationType: response.authentication.authenticationType
            )
        }
        sessions[scope] = helper
        return .init(
            isAuthenticated: response.authentication.isAuthenticated,
            host: response.authentication.host,
            login: response.authentication.login,
            authenticationType: response.authentication.authenticationType
        )
    }

    func authenticateWithDeviceLogin(accountID _: AccountID, organizationID _: OrganizationID) async throws -> CopilotRuntimeAuthenticationResult {
        throw CopilotAuthenticationError.deviceLoginUnavailable
    }
    func models(accountID: AccountID, organizationID: OrganizationID) async throws -> [CopilotModel] {
        let scope = SessionScope(accountID: accountID, organizationID: organizationID)
        guard let helper = sessions[scope] else {
            throw CopilotAuthenticationError.runtimeUnavailable
        }
        return try await helper.models(
            CopilotModelsRequest(accountID: accountID, organizationID: organizationID)
        ).models
    }

    func removeSession(profileDirectory: URL) async {
        // The profile directory is app-owned and ends in the opaque account
        // namespace. Match only retained sessions; no pathname is passed to
        // XPC or the helper.
        let accountValue = profileDirectory.lastPathComponent
        let doomed = sessions.keys.filter { $0.accountID.rawValue == accountValue }
        for scope in doomed {
            guard let helper = sessions.removeValue(forKey: scope) else { continue }
            try? await helper.shutdown(
                CopilotShutdownRequest(
                    accountID: scope.accountID,
                    organizationID: scope.organizationID
                )
            )
        }
    }
}

protocol CopilotRuntimeAuthorizationProviding: Sendable {
    func state(for accountID: AccountID) async -> CopilotAccountAuthorizationState
    /// An operation-scoped stream of real acquisition state. Implementations
    /// return `nil` when no approved runtime exists on this Mac.
    func runtimeStateUpdates() async -> AsyncStream<CopilotRuntimeStatus>?
    func acquireRuntimeAtUserRequest() async throws
    func repairRuntimeAtUserRequest() async throws
    func removeRuntimeAtUserRequest() async throws
    func authenticate(
        account: GitHubAccount,
        organizationID: OrganizationID,
        hasOrganizationConsent: Bool,
        isEntitled: Bool
    ) async throws
    func models(accountID: AccountID, organizationID: OrganizationID) async throws -> [CopilotModel]
    func externalState(for scope: SynchronizationScope, account: GitHubAccount) async -> OrganizationAIExternalState
    func disconnect(accountID: AccountID) async
}

extension CopilotRuntimeAuthorizationProviding {
    func runtimeStateUpdates() async -> AsyncStream<CopilotRuntimeStatus>? { nil }
}

/// Account-scoped authentication adapter. OAuth and fine-grained PAT values
/// are read only after consent and entitlement are true, passed once to the
/// runtime boundary, and never stored outside Keychain. Classic PAT accounts
/// remain explicitly unavailable until an independently verified device flow
/// can meet the same storage and identity guarantees.
actor CopilotRuntimeAuthenticationService: CopilotRuntimeAuthorizationProviding {
    private let runtime: CopilotRuntimeAcquisitionService?
    private let runtimeInitializationError: String?
    private let secretStore: any SecretStore
    private let authenticator: any CopilotRuntimeAuthenticating
    private let loadAuthenticatedUser: @Sendable (SecretValue) async throws -> GitHubUserDTO
    private let profileRoot: URL
    private var states: [AccountID: CopilotAccountAuthorizationState] = [:]
    private var modelIDs: [String: Set<String>] = [:]

    init(
        applicationSupportDirectory: URL,
        secretStore: any SecretStore = KeychainSecretStore(),
        authenticator: any CopilotRuntimeAuthenticating = CopilotXPCAuthenticator(),
        loadAuthenticatedUser: @escaping @Sendable (SecretValue) async throws -> GitHubUserDTO = { credential in
            let client = GitHubRESTClient(transport: try GitHubRESTTransport(), credential: credential)
            return try await GitHubIdentityClient(client: client).authenticatedUser().value
        },
        runtime: CopilotRuntimeAcquisitionService? = nil
    ) {
        self.secretStore = secretStore
        self.authenticator = authenticator
        self.loadAuthenticatedUser = loadAuthenticatedUser
        profileRoot = applicationSupportDirectory.appending(path: "Triage/Copilot", directoryHint: .isDirectory)
        if let runtime {
            self.runtime = runtime
            runtimeInitializationError = nil
        } else {
            do {
                self.runtime = try CopilotRuntimeAcquisitionService(applicationSupportDirectory: applicationSupportDirectory)
                runtimeInitializationError = nil
            } catch {
                self.runtime = nil
                runtimeInitializationError = "This Mac's processor is not supported by the approved Copilot runtime."
            }
        }
    }

    func state(for accountID: AccountID) async -> CopilotAccountAuthorizationState {
        var state = states[accountID] ?? .unavailable
        state = CopilotAccountAuthorizationState(
            runtime: await runtimeStatus(),
            authentication: state.authentication,
            isEntitled: state.isEntitled,
            hasOrganizationConsent: state.hasOrganizationConsent
        )
        states[accountID] = state
        return state
    }

    func runtimeStateUpdates() async -> AsyncStream<CopilotRuntimeStatus>? {
        guard let runtime else { return nil }
        let acquisitionStates = await runtime.stateUpdates()
        return AsyncStream { continuation in
            let forwardingTask = Task {
                for await acquisitionState in acquisitionStates {
                    continuation.yield(Self.runtimeStatus(for: acquisitionState))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                forwardingTask.cancel()
            }
        }
    }

    func acquireRuntimeAtUserRequest() async throws {
        guard let runtime else { throw CopilotAuthenticationError.runtimeUnavailable }
        await disconnectAllSessions()
        invalidateAllModelIDs()
        _ = try await runtime.acquireAtUserRequest()
        _ = try await runtime.runtimeForUse()
    }

    func repairRuntimeAtUserRequest() async throws {
        guard let runtime else { throw CopilotAuthenticationError.runtimeUnavailable }
        await disconnectAllSessions()
        invalidateAllModelIDs()
        _ = try await runtime.repairAtUserRequest()
        _ = try await runtime.runtimeForUse()
    }

    func removeRuntimeAtUserRequest() async throws {
        await disconnectAllSessions()
        invalidateAllModelIDs()
        if let runtime { try await runtime.removeAtUserRequest() }
        for (accountID, state) in states {
            states[accountID] = .init(
                runtime: .missing,
                authentication: state.authentication,
                isEntitled: state.isEntitled,
                hasOrganizationConsent: state.hasOrganizationConsent
            )
        }
    }

    func authenticate(
        account: GitHubAccount,
        organizationID: OrganizationID,
        hasOrganizationConsent: Bool,
        isEntitled: Bool
    ) async throws {
        // A newly presented credential, organization consent, or entitlement
        // result invalidates the in-memory model authority before it can be
        // used by another request. The encrypted database cache remains
        // bounded to 24 hours but cannot authorize without these fresh IDs.
        invalidateModelIDs(for: account.id)
        guard hasOrganizationConsent else {
            update(accountID: account.id, authentication: .signedOut, entitlement: isEntitled, consent: false)
            throw CopilotAuthenticationError.consentRequired
        }
        guard isEntitled else {
            update(accountID: account.id, authentication: .signedOut, entitlement: false, consent: true)
            throw CopilotAuthenticationError.entitlementRequired
        }
        guard let runtime else { throw CopilotAuthenticationError.runtimeUnavailable }
        do {
            _ = try await runtime.runtimeForUse()
        } catch {
            update(accountID: account.id, authentication: .signedOut, entitlement: isEntitled, consent: hasOrganizationConsent)
            throw CopilotAuthenticationError.runtimeUnavailable
        }
        update(accountID: account.id, authentication: .verifyingIdentity, entitlement: isEntitled, consent: hasOrganizationConsent)
        do {
        switch account.authenticationKind {
        case .oauth, .fineGrainedPersonalAccessToken:
            // This read happens only after both policy gates above succeed.
            // The Keychain data buffer is zeroed after the identity probe and
            // one XPC authentication exchange finish.
            let result: (GitHubUserDTO, CopilotRuntimeAuthenticationResult)?
            do {
                result = try await withEphemeralCredential(for: account) { credential in
                    let githubUser = try await self.loadAuthenticatedUser(credential)
                    guard githubUser.id == account.githubUserID,
                          githubUser.login.caseInsensitiveCompare(account.login) == .orderedSame
                    else {
                        throw CopilotAuthenticationError.identityMismatch(
                            expected: account.githubUserID,
                            actual: githubUser.id
                        )
                    }
                    let authenticated = try await self.authenticator.authenticateWithEphemeralCredential(
                        accountID: account.id,
                        organizationID: organizationID,
                        credential: credential
                    )
                    return (githubUser, authenticated)
                }
            } catch let error as CopilotAuthenticationError {
                if case let .identityMismatch(expected, actual) = error {
                    update(accountID: account.id, authentication: .identityMismatch(expected: expected, actual: actual), entitlement: isEntitled, consent: hasOrganizationConsent)
                }
                throw error
            }
            guard let result else { throw CopilotAuthenticationError.credentialUnavailable }
            let (_, authenticated) = result
            guard authenticated.isAuthenticated,
                  authenticated.host.caseInsensitiveCompare("github.com") == .orderedSame,
                  authenticated.login.caseInsensitiveCompare(account.login) == .orderedSame
            else {
                update(accountID: account.id, authentication: .blocked("Copilot did not verify the selected github.com identity."), entitlement: isEntitled, consent: hasOrganizationConsent)
                throw CopilotAuthenticationError.copilotIdentityMismatch
            }
        case .classicPersonalAccessToken:
            // The approved runtime does not currently implement a verifiable,
            // Keychain-only isolated device flow.  Never offer a classic PAT
            // to the helper or imply that a sign-in can complete.
            update(
                accountID: account.id,
                authentication: .blocked("Copilot is unavailable for classic personal access tokens on this Mac. Triage will not send this token to Copilot."),
                entitlement: isEntitled,
                consent: hasOrganizationConsent
            )
            throw CopilotAuthenticationError.deviceLoginUnavailable
        }
        // A random opaque reference is the only Copilot auth value Triage
        // persists. The credential itself remains ephemeral or in Keychain.
        try await secretStore.write(
            Data(UUID().uuidString.utf8),
            kind: .copilotCredential,
            accountID: account.id,
            credentialID: nil
        )
        update(accountID: account.id, authentication: .authenticated, entitlement: isEntitled, consent: hasOrganizationConsent)
        } catch {
            if case .verifyingIdentity = states[account.id]?.authentication {
                update(accountID: account.id, authentication: .failed("Copilot could not verify this account. Authenticate again after checking your GitHub connection."), entitlement: isEntitled, consent: hasOrganizationConsent)
            }
            throw error
        }
    }

    func disconnect(accountID: AccountID) async {
        await authenticator.removeSession(profileDirectory: profileDirectory(for: accountID))
        try? await secretStore.remove(kind: .copilotCredential, accountID: accountID, credentialID: nil)
        invalidateModelIDs(for: accountID)
        states[accountID] = nil
    }

    func models(accountID: AccountID, organizationID: OrganizationID) async throws -> [CopilotModel] {
        guard case .authenticated = states[accountID]?.authentication else { throw CopilotAuthenticationError.runtimeUnavailable }
        let values = try await authenticator.models(accountID: accountID, organizationID: organizationID)
        modelIDs["\(accountID.rawValue)/\(organizationID.rawValue)"] = Set(values.map(\.id))
        return values
    }

    func externalState(for scope: SynchronizationScope, account: GitHubAccount) async -> OrganizationAIExternalState {
        let state = await state(for: account.id)
        let ids = modelIDs["\(scope.accountID.rawValue)/\(scope.organizationID.rawValue)"] ?? []
        let runtimeReady: Bool = if case .ready = state.runtime { true } else { false }
        return .init(isRuntimeAvailable: runtimeReady, isAuthenticatedIdentityMatch: state.authentication == .authenticated, isEntitled: state.isEntitled, supportsAutoModel: !ids.isEmpty, availableModelIDs: ids, hasAvailableBudget: false)
    }

    /// The mutable Data returned by Keychain is the only buffer this adapter
    /// owns. It is wiped after the supplied operation; downstream framework
    /// copies are bounded to the active request and are never persisted.
    private func withEphemeralCredential<T: Sendable>(
        for account: GitHubAccount,
        operation: @Sendable (SecretValue) async throws -> T
    ) async throws -> T? {
        let kind: TriageSecretKind = account.authenticationKind == .oauth ? .oauthAccessToken : .personalAccessToken
        guard var bytes = try await secretStore.read(kind: kind, accountID: account.id, credentialID: account.credentialID)
        else { return nil }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        guard let raw = String(data: bytes, encoding: .utf8), !raw.isEmpty else { return nil }
        return try await operation(SecretValue(raw))
    }

    private func profileDirectory(for accountID: AccountID) -> URL {
        profileRoot.appending(path: accountID.rawValue, directoryHint: .isDirectory)
    }

    private func invalidateModelIDs(for accountID: AccountID) {
        let prefix = "\(accountID.rawValue)/"
        modelIDs = modelIDs.filter { !$0.key.hasPrefix(prefix) }
    }

    private func invalidateAllModelIDs() {
        modelIDs.removeAll(keepingCapacity: false)
    }

    /// Runtime replacement is never allowed to race an authenticated helper.
    /// `removeSession` drains its bounded XPC shutdown path; a failed shutdown
    /// still discards the retained client, so the next use must authenticate
    /// afresh rather than retaining a stale authority.
    private func disconnectAllSessions() async {
        let accountIDs = Set(states.keys)
        for accountID in accountIDs {
            await authenticator.removeSession(profileDirectory: profileDirectory(for: accountID))
            let state = states[accountID] ?? .unavailable
            states[accountID] = .init(
                runtime: state.runtime,
                authentication: .signedOut,
                isEntitled: state.isEntitled,
                hasOrganizationConsent: state.hasOrganizationConsent
            )
        }
    }

    private func runtimeStatus() async -> CopilotRuntimeStatus {
        if let runtimeInitializationError { return .unsupported(runtimeInitializationError) }
        guard let runtime else { return .unsupported("The approved Copilot runtime is unavailable.") }
        return Self.runtimeStatus(for: await runtime.state())
    }

    private static func runtimeStatus(
        for state: CopilotRuntimeAcquisitionState
    ) -> CopilotRuntimeStatus {
        switch state {
        case .absent: return .missing
        case let .downloading(receivedBytes, expectedBytes):
            return .downloading(receivedBytes: receivedBytes, expectedBytes: expectedBytes)
        case .verifying: return .verifying
        case .ready: return .ready
        case let .corrupt(message): return .corrupt(message)
        }
    }

    private func update(accountID: AccountID, authentication: CopilotAuthenticationStatus, entitlement: Bool, consent: Bool) {
        states[accountID] = .init(
            runtime: states[accountID]?.runtime ?? .missing,
            authentication: authentication,
            isEntitled: entitlement,
            hasOrganizationConsent: consent
        )
    }
}

struct NoopCopilotRuntimeAuthorizationProvider: CopilotRuntimeAuthorizationProviding {
    func state(for _: AccountID) async -> CopilotAccountAuthorizationState { .unavailable }
    func runtimeStateUpdates() async -> AsyncStream<CopilotRuntimeStatus>? { nil }
    func acquireRuntimeAtUserRequest() async throws { throw CopilotAuthenticationError.runtimeUnavailable }
    func repairRuntimeAtUserRequest() async throws { throw CopilotAuthenticationError.runtimeUnavailable }
    func removeRuntimeAtUserRequest() async throws {}
    func authenticate(account _: GitHubAccount, organizationID _: OrganizationID, hasOrganizationConsent _: Bool, isEntitled _: Bool) async throws { throw CopilotAuthenticationError.runtimeUnavailable }
    func models(accountID _: AccountID, organizationID _: OrganizationID) async throws -> [CopilotModel] { throw CopilotAuthenticationError.runtimeUnavailable }
    func externalState(for _: SynchronizationScope, account _: GitHubAccount) async -> OrganizationAIExternalState { .unavailable }
    func disconnect(accountID _: AccountID) async {}
}
