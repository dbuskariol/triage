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
        credential: CopilotEphemeralCredential
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
    func authenticateWithEphemeralCredential(accountID _: AccountID, organizationID _: OrganizationID, credential _: CopilotEphemeralCredential) async throws -> CopilotRuntimeAuthenticationResult {
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

    /// A client identity is separate from the account generation.  A newer
    /// authentication for the same scope must never let an older completion
    /// tear down the newer client's helper process.
    private struct SessionClient: Sendable {
        let token: UUID
        let helper: any TriageCopilotHelping
    }

    private struct PendingAuthentication: Sendable {
        let scope: SessionScope
        let generation: UInt64
        let client: SessionClient
    }

    private let makeClient: @Sendable () -> any TriageCopilotHelping
    // Keep the XPC transport alive after successful authentication. The
    // helper owns the authenticated engine, and an incidental client
    // deallocation is an XPC invalidation fence rather than a safe way to
    // retain that engine.
    private var sessions: [SessionScope: SessionClient] = [:]
    /// Authentication starts before a client is safe to retain as a session.
    /// Keep that client addressable so disconnect/runtime mutation can stop it
    /// before it continues to hold the runtime's shared lock.
    private var pendingAuthentications: [UUID: PendingAuthentication] = [:]
    // An authenticate call can suspend while its connection is being removed.
    // This generation fence prevents the older completion from retaining a
    // session after disconnect has revoked that scope.
    private var authenticationGenerations: [SessionScope: UInt64] = [:]

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
        credential: CopilotEphemeralCredential
    ) async throws -> CopilotRuntimeAuthenticationResult {
        let scope = SessionScope(accountID: accountID, organizationID: organizationID)
        let generation = beginAuthentication(for: scope)
        let operationToken = UUID()
        // Do not multiplex a second authenticate exchange over a client with
        // an in-flight exchange.  This gives each operation a client token so
        // a stale completion can only tear down its own helper.
        let client: SessionClient
        if pendingAuthentications.values.contains(where: { $0.scope == scope }) {
            client = makeSessionClient()
        } else {
            client = sessions[scope] ?? makeSessionClient()
        }
        pendingAuthentications[operationToken] = .init(
            scope: scope,
            generation: generation,
            client: client
        )
        do {
            let response = try await client.helper.authenticate(
                CopilotAuthenticateRequest(
                    accountID: accountID,
                    organizationID: organizationID,
                    credential: credential
                )
            )
            guard isCurrent(generation, for: scope) else {
                await shutdownPendingAuthentication(operationToken)
                throw CancellationError()
            }
            guard response.authentication.isAuthenticated else {
                // Do not retain a transport whose helper explicitly rejected
                // the credential; clear every reference to this exact client
                // before awaiting its shutdown.
                let doomed = detach(client: client.token, in: scope)
                if let doomed { await shutdown(doomed, for: scope) }
                return .init(
                    isAuthenticated: false,
                    host: response.authentication.host,
                    login: response.authentication.login,
                    authenticationType: response.authentication.authenticationType
                )
            }
            pendingAuthentications[operationToken] = nil
            let displaced = sessions.updateValue(client, forKey: scope)
            if let displaced, displaced.token != client.token {
                let doomed = detach(client: displaced.token, in: scope)
                if let doomed { await shutdown(doomed, for: scope) }
            }
            guard isCurrent(generation, for: scope), sessions[scope]?.token == client.token else {
                let doomed = detach(client: client.token, in: scope)
                if let doomed { await shutdown(doomed, for: scope) }
                throw CancellationError()
            }
            return .init(
                isAuthenticated: response.authentication.isAuthenticated,
                host: response.authentication.host,
                login: response.authentication.login,
                authenticationType: response.authentication.authenticationType
            )
        } catch {
            guard isCurrent(generation, for: scope) else {
                await shutdownPendingAuthentication(operationToken)
                throw CancellationError()
            }
            let pending = pendingAuthentications.removeValue(forKey: operationToken)
            // A newly created client that failed before session adoption must
            // be explicitly stopped; otherwise it may retain the runtime lock.
            if let pending, sessions[scope]?.token != pending.client.token {
                await shutdown(pending.client, for: scope)
            }
            throw error
        }
    }

    func authenticateWithDeviceLogin(accountID _: AccountID, organizationID _: OrganizationID) async throws -> CopilotRuntimeAuthenticationResult {
        throw CopilotAuthenticationError.deviceLoginUnavailable
    }
    func models(accountID: AccountID, organizationID: OrganizationID) async throws -> [CopilotModel] {
        let scope = SessionScope(accountID: accountID, organizationID: organizationID)
        guard let client = sessions[scope], let generation = authenticationGenerations[scope] else {
            throw CopilotAuthenticationError.runtimeUnavailable
        }
        let response = try await client.helper.models(
            CopilotModelsRequest(accountID: accountID, organizationID: organizationID)
        )
        guard isCurrent(generation, for: scope), sessions[scope]?.token == client.token else {
            throw CancellationError()
        }
        return response.models
    }

    func removeSession(profileDirectory: URL) async {
        // The profile directory is app-owned and ends in the opaque account
        // namespace. Match only retained sessions; no pathname is passed to
        // XPC or the helper.
        let accountValue = profileDirectory.lastPathComponent
        let doomed = Set(sessions.keys)
            .union(authenticationGenerations.keys)
            .union(pendingAuthentications.values.map(\.scope))
            .filter { $0.accountID.rawValue == accountValue }
        for scope in doomed {
            invalidateAuthentication(for: scope)
            let clients = detachAllClients(in: scope)
            for client in clients {
                await shutdown(client, for: scope)
            }
        }
    }

    private func beginAuthentication(for scope: SessionScope) -> UInt64 {
        let generation = (authenticationGenerations[scope] ?? 0) &+ 1
        authenticationGenerations[scope] = generation
        return generation
    }

    private func invalidateAuthentication(for scope: SessionScope) {
        authenticationGenerations[scope] = (authenticationGenerations[scope] ?? 0) &+ 1
    }

    private func isCurrent(_ generation: UInt64, for scope: SessionScope) -> Bool {
        authenticationGenerations[scope] == generation
    }

    private func makeSessionClient() -> SessionClient {
        .init(token: UUID(), helper: makeClient())
    }

    /// Removes a client only by its immutable token.  It is safe to call after
    /// an await because a newer same-scope session has a different token.
    private func detach(client token: UUID, in scope: SessionScope) -> SessionClient? {
        var result: SessionClient?
        if let session = sessions[scope], session.token == token {
            result = sessions.removeValue(forKey: scope)
        }
        let operations: [UUID] = pendingAuthentications.compactMap { entry -> UUID? in
            let (operation, pending) = entry
            return pending.scope == scope && pending.client.token == token ? operation : nil
        }
        for operation in operations {
            guard let pending = pendingAuthentications.removeValue(forKey: operation) else { continue }
            result = result ?? pending.client
        }
        return result
    }

    private func detachAllClients(in scope: SessionScope) -> [SessionClient] {
        var clients: [UUID: SessionClient] = [:]
        if let session = sessions.removeValue(forKey: scope) {
            clients[session.token] = session
        }
        let operations: [UUID] = pendingAuthentications.compactMap { entry -> UUID? in
            let (operation, pending) = entry
            return pending.scope == scope ? operation : nil
        }
        for operation in operations {
            guard let pending = pendingAuthentications.removeValue(forKey: operation) else { continue }
            clients[pending.client.token] = pending.client
        }
        return Array(clients.values)
    }

    private func shutdownPendingAuthentication(_ operationToken: UUID) async {
        guard let pending = pendingAuthentications.removeValue(forKey: operationToken) else { return }
        // The operation may have been promoted to the retained session before
        // this continuation resumed. Detach by token so no newer session is
        // affected, then terminate the client exactly once.
        let doomed = detach(client: pending.client.token, in: pending.scope) ?? pending.client
        await shutdown(doomed, for: pending.scope)
    }

    private func shutdown(_ client: SessionClient, for scope: SessionScope) async {
        _ = try? await client.helper.shutdown(
            CopilotShutdownRequest(accountID: scope.accountID, organizationID: scope.organizationID)
        )
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
    private struct CopilotCredentialReference: Sendable {
        let authenticationGeneration: UInt64
        let credentialID: CredentialID
    }

    private let runtime: CopilotRuntimeAcquisitionService?
    private let runtimeInitializationError: String?
    private let secretStore: any SecretStore
    private let authenticator: any CopilotRuntimeAuthenticating
    private let loadAuthenticatedUser: @Sendable (SecretValue) async throws -> GitHubUserDTO
    private let runtimeStatusProvider: (@Sendable () async -> CopilotRuntimeStatus)?
    private let profileRoot: URL
    private var states: [AccountID: CopilotAccountAuthorizationState] = [:]
    private var modelIDs: [String: Set<String>] = [:]
    private var authenticationGenerations: [AccountID: UInt64] = [:]
    /// Only an authentication operation that is still current may adopt its
    /// own opaque Keychain reference. A unique key prevents stale cleanup from
    /// removing a newer authentication's reference.
    private var copilotCredentialReferences: [AccountID: CopilotCredentialReference] = [:]
    // Runtime replacement is an authority boundary: no authentication may
    // cross it and retain a helper tied to the previous executable.
    private var runtimeMutationGeneration: UInt64 = 0
    private var isRuntimeMutationInProgress = false

    init(
        applicationSupportDirectory: URL,
        secretStore: any SecretStore = KeychainSecretStore(),
        authenticator: any CopilotRuntimeAuthenticating = CopilotXPCAuthenticator(),
        loadAuthenticatedUser: @escaping @Sendable (SecretValue) async throws -> GitHubUserDTO = { credential in
            let client = GitHubRESTClient(transport: try GitHubRESTTransport(), credential: credential)
            return try await GitHubIdentityClient(client: client).authenticatedUser().value
        },
        runtime: CopilotRuntimeAcquisitionService? = nil,
        runtimeStatusProvider: (@Sendable () async -> CopilotRuntimeStatus)? = nil
    ) {
        self.secretStore = secretStore
        self.authenticator = authenticator
        self.loadAuthenticatedUser = loadAuthenticatedUser
        self.runtimeStatusProvider = runtimeStatusProvider
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
        let authenticationGeneration = authenticationGenerations[accountID] ?? 0
        let mutationGeneration = runtimeMutationGeneration
        var state = states[accountID] ?? .unavailable
        state = CopilotAccountAuthorizationState(
            runtime: await runtimeStatus(),
            authentication: state.authentication,
            isEntitled: state.isEntitled,
            hasOrganizationConsent: state.hasOrganizationConsent
        )
        guard isCurrent(
            authenticationGeneration,
            for: accountID,
            runtimeMutationGeneration: mutationGeneration
        ) else {
            return states[accountID] ?? .unavailable
        }
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
        let mutation = try beginRuntimeMutation()
        defer { finishRuntimeMutation(mutation) }
        await disconnectAllSessions()
        invalidateAllModelIDs()
        _ = try await runtime.acquireAtUserRequest()
        _ = try await runtime.runtimeForUse()
    }

    func repairRuntimeAtUserRequest() async throws {
        guard let runtime else { throw CopilotAuthenticationError.runtimeUnavailable }
        let mutation = try beginRuntimeMutation()
        defer { finishRuntimeMutation(mutation) }
        await disconnectAllSessions()
        invalidateAllModelIDs()
        _ = try await runtime.repairAtUserRequest()
        _ = try await runtime.runtimeForUse()
    }

    func removeRuntimeAtUserRequest() async throws {
        let mutation = try beginRuntimeMutation()
        defer { finishRuntimeMutation(mutation) }
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
        let mutationGeneration = runtimeMutationGeneration
        guard !isRuntimeMutationInProgress else {
            throw CopilotAuthenticationError.runtimeUnavailable
        }
        let generation = beginAuthentication(for: account.id)
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
            guard isCurrent(generation, for: account.id, runtimeMutationGeneration: mutationGeneration) else {
                throw CancellationError()
            }
            update(accountID: account.id, authentication: .signedOut, entitlement: isEntitled, consent: hasOrganizationConsent)
            throw CopilotAuthenticationError.runtimeUnavailable
        }
        guard isCurrent(generation, for: account.id, runtimeMutationGeneration: mutationGeneration) else {
            throw CancellationError()
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
                result = try await withEphemeralCredential(
                    for: account,
                    preflight: { credential in
                    guard await self.isCurrent(
                        generation,
                        for: account.id,
                        runtimeMutationGeneration: mutationGeneration
                    ) else {
                        throw CancellationError()
                    }
                    let githubUser = try await self.loadAuthenticatedUser(credential)
                    guard await self.isCurrent(
                        generation,
                        for: account.id,
                        runtimeMutationGeneration: mutationGeneration
                    ) else {
                        throw CancellationError()
                    }
                    return githubUser
                },
                    authenticate: { githubUser, credential in
                    guard await self.isCurrent(
                        generation,
                        for: account.id,
                        runtimeMutationGeneration: mutationGeneration
                    ) else {
                        throw CancellationError()
                    }
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
                    guard await self.isCurrent(
                        generation,
                        for: account.id,
                        runtimeMutationGeneration: mutationGeneration
                    ) else {
                        throw CancellationError()
                    }
                    return (githubUser, authenticated)
                })
            } catch let error as CopilotAuthenticationError {
                guard isCurrent(generation, for: account.id, runtimeMutationGeneration: mutationGeneration) else {
                    throw CancellationError()
                }
                if case let .identityMismatch(expected, actual) = error {
                    update(accountID: account.id, authentication: .identityMismatch(expected: expected, actual: actual), entitlement: isEntitled, consent: hasOrganizationConsent)
                }
                throw error
            }
            guard let result else { throw CopilotAuthenticationError.credentialUnavailable }
            guard isCurrent(generation, for: account.id, runtimeMutationGeneration: mutationGeneration) else {
                throw CancellationError()
            }
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
                authentication: .blocked("This classic personal access token is used only for read-only GitHub synchronization and is never sent to Copilot. A separate Copilot OAuth sign-in is not yet available in this build."),
                entitlement: isEntitled,
                consent: hasOrganizationConsent
            )
            throw CopilotAuthenticationError.deviceLoginUnavailable
        }
        // A random opaque reference is the only Copilot auth value Triage
        // persists. The credential itself remains ephemeral or in Keychain.
        // Its distinct Keychain identifier gives stale continuations a safe,
        // operation-local cleanup target.
        let reference = CopilotCredentialReference(
            authenticationGeneration: generation,
            credentialID: .make()
        )
        try await secretStore.write(
            Data(UUID().uuidString.utf8),
            kind: .copilotCredential,
            accountID: account.id,
            credentialID: reference.credentialID
        )
        guard reference.authenticationGeneration == generation,
              isCurrent(generation, for: account.id, runtimeMutationGeneration: mutationGeneration)
        else {
            try? await secretStore.remove(
                kind: .copilotCredential,
                accountID: account.id,
                credentialID: reference.credentialID
            )
            throw CancellationError()
        }
        // Replace the current reference only after the post-write fence. A
        // newer operation has a different Keychain identifier and remains
        // untouched by this operation's stale cleanup.
        copilotCredentialReferences[account.id] = reference
        update(accountID: account.id, authentication: .authenticated, entitlement: isEntitled, consent: hasOrganizationConsent)
        } catch {
            guard isCurrent(generation, for: account.id, runtimeMutationGeneration: mutationGeneration) else {
                throw error
            }
            if let error = error as? CopilotXPCError,
               error == .runtimeUnavailable || error == .runtimeCorrupt {
                update(accountID: account.id, authentication: .signedOut, entitlement: isEntitled, consent: hasOrganizationConsent)
                throw CopilotAuthenticationError.runtimeUnavailable
            }
            if case .verifyingIdentity = states[account.id]?.authentication {
                update(accountID: account.id, authentication: .failed("Copilot could not verify this account. Authenticate again after checking your GitHub connection."), entitlement: isEntitled, consent: hasOrganizationConsent)
            }
            throw error
        }
    }

    func disconnect(accountID: AccountID) async {
        let generation = invalidateAuthentication(for: accountID)
        let reference = copilotCredentialReferences.removeValue(forKey: accountID)
        await authenticator.removeSession(profileDirectory: profileDirectory(for: accountID))
        guard isCurrent(generation, for: accountID) else { return }
        if let reference {
            try? await secretStore.remove(
                kind: .copilotCredential,
                accountID: accountID,
                credentialID: reference.credentialID
            )
        }
        guard isCurrent(generation, for: accountID) else { return }
        invalidateModelIDs(for: accountID)
        states[accountID] = nil
    }

    func models(accountID: AccountID, organizationID: OrganizationID) async throws -> [CopilotModel] {
        let authenticationGeneration = authenticationGenerations[accountID] ?? 0
        let mutationGeneration = runtimeMutationGeneration
        guard !isRuntimeMutationInProgress,
              case .authenticated = states[accountID]?.authentication
        else { throw CopilotAuthenticationError.runtimeUnavailable }
        let values = try await authenticator.models(accountID: accountID, organizationID: organizationID)
        guard isCurrent(
            authenticationGeneration,
            for: accountID,
            runtimeMutationGeneration: mutationGeneration
        ) else {
            throw CancellationError()
        }
        modelIDs["\(accountID.rawValue)/\(organizationID.rawValue)"] = Set(values.map(\.id))
        return values
    }

    func externalState(for scope: SynchronizationScope, account: GitHubAccount) async -> OrganizationAIExternalState {
        let state = await state(for: account.id)
        let ids = modelIDs["\(scope.accountID.rawValue)/\(scope.organizationID.rawValue)"] ?? []
        let runtimeReady: Bool = if case .ready = state.runtime { true } else { false }
        return .init(isRuntimeAvailable: runtimeReady, isAuthenticatedIdentityMatch: state.authentication == .authenticated, isEntitled: state.isEntitled, supportsAutoModel: !ids.isEmpty, availableModelIDs: ids, hasAvailableBudget: false)
    }

    /// The mutable Data returned by Keychain is the only credential buffer this
    /// adapter owns. It is wiped after the supplied operation. A temporary
    /// `SecretValue` is unavoidable at the URLSession REST identity boundary;
    /// after that preflight, the same owned bytes are copied directly into the
    /// single-use XPC credential, never into another Swift `String`.
    private func withEphemeralCredential<T: Sendable>(
        for account: GitHubAccount,
        preflight: @Sendable (SecretValue) async throws -> GitHubUserDTO,
        authenticate: @Sendable (GitHubUserDTO, CopilotEphemeralCredential) async throws -> T
    ) async throws -> T? {
        let kind: TriageSecretKind = account.authenticationKind == .oauth ? .oauthAccessToken : .personalAccessToken
        guard var bytes = try await secretStore.read(kind: kind, accountID: account.id, credentialID: account.credentialID)
        else { return nil }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let githubUser: GitHubUserDTO
        do {
            // This String exists only for the URLSession identity request,
            // whose API currently requires `SecretValue`.
            guard let raw = String(data: bytes, encoding: .utf8), !raw.isEmpty else { return nil }
            githubUser = try await preflight(SecretValue(raw))
        }
        let credential = CopilotEphemeralCredential(copying: bytes)
        return try await authenticate(githubUser, credential)
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
        let accountIDs = Set(states.keys).union(authenticationGenerations.keys)
        for accountID in accountIDs {
            let generation = invalidateAuthentication(for: accountID)
            let reference = copilotCredentialReferences.removeValue(forKey: accountID)
            await authenticator.removeSession(profileDirectory: profileDirectory(for: accountID))
            if let reference {
                try? await secretStore.remove(
                    kind: .copilotCredential,
                    accountID: accountID,
                    credentialID: reference.credentialID
                )
            }
            guard isCurrent(generation, for: accountID) else { continue }
            let state = states[accountID] ?? .unavailable
            states[accountID] = .init(
                runtime: state.runtime,
                authentication: .signedOut,
                isEntitled: state.isEntitled,
                hasOrganizationConsent: state.hasOrganizationConsent
            )
        }
    }

    private func beginAuthentication(for accountID: AccountID) -> UInt64 {
        let generation = (authenticationGenerations[accountID] ?? 0) &+ 1
        authenticationGenerations[accountID] = generation
        return generation
    }

    private func invalidateAuthentication(for accountID: AccountID) -> UInt64 {
        let generation = (authenticationGenerations[accountID] ?? 0) &+ 1
        authenticationGenerations[accountID] = generation
        return generation
    }

    private func isCurrent(
        _ generation: UInt64,
        for accountID: AccountID,
        runtimeMutationGeneration: UInt64? = nil
    ) -> Bool {
        guard authenticationGenerations[accountID] == generation else { return false }
        guard let runtimeMutationGeneration else { return true }
        return !isRuntimeMutationInProgress && self.runtimeMutationGeneration == runtimeMutationGeneration
    }

    private func beginRuntimeMutation() throws -> UInt64 {
        guard !isRuntimeMutationInProgress else {
            throw CopilotAuthenticationError.runtimeUnavailable
        }
        isRuntimeMutationInProgress = true
        runtimeMutationGeneration &+= 1
        return runtimeMutationGeneration
    }

    private func finishRuntimeMutation(_ generation: UInt64) {
        guard runtimeMutationGeneration == generation else { return }
        isRuntimeMutationInProgress = false
    }

    private func runtimeStatus() async -> CopilotRuntimeStatus {
        if let runtimeStatusProvider { return await runtimeStatusProvider() }
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
