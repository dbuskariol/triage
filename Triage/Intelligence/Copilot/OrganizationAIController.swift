import Foundation

enum OrganizationAIControllerError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case policyUnavailable
    case staleOperation
    case staleSynchronizationScope
}

/// External runtime facts deliberately arrive through this small value. Phase
/// A supplies `.unavailable`; nothing here attempts an ambient CLI, PATH,
/// environment credential, download, or fallback connection.
struct OrganizationAIExternalState: Equatable, Sendable {
    let isRuntimeAvailable: Bool
    let isAuthenticatedIdentityMatch: Bool
    let isEntitled: Bool
    let supportsAutoModel: Bool
    let availableModelIDs: Set<String>
    let hasAvailableBudget: Bool

    static let unavailable = Self(
        isRuntimeAvailable: false,
        isAuthenticatedIdentityMatch: false,
        isEntitled: false,
        supportsAutoModel: false,
        availableModelIDs: [],
        hasAvailableBudget: false
    )
}

struct OrganizationAIExecutionPolicy: Equatable, Sendable {
    let consent: OrganizationAIConsent
    let selectedModelID: String?
    let derivedPolicy: DerivedAIPolicy
    let isModelSelectionValid: Bool

    var permitsAnalysis: Bool { derivedPolicy.permitsCandidates && isModelSelectionValid }
}

struct OrganizationAIAnalysisLease: Sendable {
    fileprivate let scope: SynchronizationScope
    fileprivate let accountID: AccountID
    fileprivate let organizationID: OrganizationID
    fileprivate let generation: UInt64
    let policy: OrganizationAIExecutionPolicy
}

actor OrganizationAIController {
    typealias ExternalStateLoading = @Sendable (SynchronizationScope, GitHubAccount) async -> OrganizationAIExternalState

    private struct Scope: Hashable, Sendable {
        let accountID: AccountID
        let organizationID: OrganizationID
    }

    private struct ActiveOperation: Sendable {
        let generation: UInt64
        let cancel: @Sendable () -> Void
        let waitForQuiescence: @Sendable () async -> Void
    }

    private let vault: AccountVault
    private let consentRepository: AIConsentRepository
    private let analysisRepository: AIAnalysisRepository
    private let loadExternalState: ExternalStateLoading
    private var generations: [Scope: UInt64] = [:]
    private var activeOperations: [Scope: ActiveOperation] = [:]

    init(
        vault: AccountVault,
        loadExternalState: @escaping ExternalStateLoading = { _, _ in .unavailable }
    ) {
        self.vault = vault
        consentRepository = AIConsentRepository(vault: vault)
        analysisRepository = AIAnalysisRepository(vault: vault)
        self.loadExternalState = loadExternalState
    }

    func consent(for accountID: AccountID, organizationID: OrganizationID) async throws -> OrganizationAIConsent {
        try validateVaultAccount(accountID)
        return try await consentRepository.consent(for: accountID, organizationID: organizationID)
    }

    func recordConsent(_ consent: OrganizationAIConsent, at date: Date = .now) async throws {
        try validateVaultAccount(consent.accountID)
        let scope = Scope(accountID: consent.accountID, organizationID: consent.organizationID)
        advanceGeneration(for: scope)
        await cancelAndWait(for: scope)
        if !consent.isEnabled {
            try await analysisRepository.eraseOrganizationAIData(
                for: consent.accountID,
                organizationID: consent.organizationID,
                at: date
            )
            return
        }
        try await analysisRepository.eraseOrganizationAIArtifacts(
            for: consent.accountID,
            organizationID: consent.organizationID,
            at: date
        )
        try await consentRepository.save(consent, at: date)
    }

    func policy(
        for scope: SynchronizationScope,
        account: GitHubAccount,
        at date: Date = .now
    ) async throws -> OrganizationAIExecutionPolicy {
        try validateScope(scope, account: account)
        try await validateCurrentScope(scope)
        let consent = try await consentRepository.consent(
            for: scope.accountID,
            organizationID: scope.organizationID
        )
        try await validateCurrentScope(scope)
        guard consent.isEnabled else {
            return OrganizationAIExecutionPolicy(
                consent: consent,
                selectedModelID: nil,
                derivedPolicy: DerivedAIPolicy(
                    isOrganizationConsentActive: false,
                    isAuthenticationValid: false,
                    isEntitled: false,
                    hasAvailableBudget: false,
                    selectedModelID: nil
                ),
                isModelSelectionValid: false
            )
        }
        let external = await loadExternalState(scope, account)
        try await validateCurrentScope(scope)
        let cachedModels = try await analysisRepository.cachedModels(
            for: scope.accountID,
            organizationID: scope.organizationID,
            at: date
        )
        try await validateCurrentScope(scope)
        let currentConsent = try await consentRepository.consent(
            for: scope.accountID,
            organizationID: scope.organizationID
        )
        guard currentConsent == consent else {
            throw OrganizationAIControllerError.staleOperation
        }
        let cachedModelIDs = Set(cachedModels.map(\.id))
        let locallyAuthenticated = account.credentialStatus == .active
            && CredentialLifecycle.status(for: account, at: date) == .active
        let modelIsValid: Bool
        if let selectedModelID = consent.selectedModelID {
            modelIsValid = cachedModelIDs.contains(selectedModelID)
                && external.availableModelIDs.contains(selectedModelID)
        } else {
            modelIsValid = external.supportsAutoModel
        }
        let derived = DerivedAIPolicy(
            isOrganizationConsentActive: consent.isEnabled,
            isAuthenticationValid: locallyAuthenticated
                && external.isRuntimeAvailable
                && external.isAuthenticatedIdentityMatch,
            isEntitled: external.isRuntimeAvailable && external.isEntitled,
            // Candidate derivation must not proceed when the persisted model
            // choice is no longer valid for the authorized runtime.
            hasAvailableBudget: external.isRuntimeAvailable
                && external.hasAvailableBudget
                && modelIsValid,
            selectedModelID: consent.selectedModelID
        )
        return OrganizationAIExecutionPolicy(
            consent: consent,
            selectedModelID: consent.selectedModelID,
            derivedPolicy: derived,
            isModelSelectionValid: modelIsValid
        )
    }

    /// The external operation returns an optional validated local analysis;
    /// only the controller-owned repository commit may persist it. The write
    /// transaction rechecks scope and consent, preventing stale results from
    /// resurrecting artifacts after disable or authority replacement.
    func performAuthorizedAnalysis(
        for scope: SynchronizationScope,
        account: GitHubAccount,
        at date: Date = .now,
        operation: @escaping @Sendable (OrganizationAIAnalysisLease) async throws -> StoredAIAnalysis?
    ) async throws {
        try validateScope(scope, account: account)
        try await validateCurrentScope(scope)
        let key = Scope(accountID: scope.accountID, organizationID: scope.organizationID)
        let generation = advanceGeneration(for: key)
        await cancelAndWait(for: key)
        // Claim the generation before awaiting the policy. A concurrent
        // disable/model change then invalidates this request before it can
        // start any external work, even if policy resolution is suspended.
        let policy = try await policy(for: scope, account: account, at: date)
        guard generations[key] == generation else {
            throw OrganizationAIControllerError.staleOperation
        }
        guard policy.permitsAnalysis else { throw OrganizationAIControllerError.policyUnavailable }
        let currentConsent = try await consentRepository.consent(
            for: scope.accountID,
            organizationID: scope.organizationID
        )
        guard generations[key] == generation,
              currentConsent.isEnabled,
              currentConsent.selectedModelID == policy.selectedModelID
        else {
            throw OrganizationAIControllerError.staleOperation
        }
        try await validateCurrentScope(scope)
        let lease = OrganizationAIAnalysisLease(
            scope: scope,
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            generation: generation,
            policy: policy
        )
        let task = Task { try await operation(lease) }
        activeOperations[key] = ActiveOperation(
            generation: generation,
            cancel: { task.cancel() },
            waitForQuiescence: { _ = await task.result }
        )
        defer {
            if activeOperations[key]?.generation == generation {
                activeOperations[key] = nil
            }
        }
        let result = try await task.value
        try await verifyCurrent(lease)
        if let result {
            try await analysisRepository.saveAuthorized(
                result,
                for: lease.scope,
                selectedModelID: lease.policy.selectedModelID
            )
        }
        try await verifyCurrent(lease)
    }

    func verifyCurrent(_ lease: OrganizationAIAnalysisLease) async throws {
        try validateVaultAccount(lease.accountID)
        let key = Scope(accountID: lease.accountID, organizationID: lease.organizationID)
        guard generations[key] == lease.generation,
              lease.policy.permitsAnalysis
        else { throw OrganizationAIControllerError.staleOperation }
        try await validateCurrentScope(lease.scope)
        guard generations[key] == lease.generation else {
            throw OrganizationAIControllerError.staleOperation
        }
        let consent = try await consentRepository.consent(
            for: lease.accountID,
            organizationID: lease.organizationID
        )
        guard consent.isEnabled, consent.selectedModelID == lease.policy.selectedModelID else {
            throw OrganizationAIControllerError.staleOperation
        }
        try await validateCurrentScope(lease.scope)
        guard generations[key] == lease.generation else {
            throw OrganizationAIControllerError.staleOperation
        }
    }

    func cancelAndDisable(for scope: SynchronizationScope, at date: Date = .now) async throws {
        try validateVaultAccount(scope.accountID)
        try await validateCurrentScope(scope)
        let key = Scope(accountID: scope.accountID, organizationID: scope.organizationID)
        advanceGeneration(for: key)
        await cancelAndWait(for: key)
        // The caller's authority can change while a non-cooperative external
        // operation is draining. Never let a stale scope erase data under a
        // replacement credential/capability revision.
        try await validateCurrentScope(scope)
        try await analysisRepository.eraseOrganizationAIData(
            for: scope.accountID,
            organizationID: scope.organizationID,
            at: date
        )
    }

    private func validateScope(_ scope: SynchronizationScope, account: GitHubAccount) throws {
        try validateVaultAccount(scope.accountID)
        guard account.id == scope.accountID else { throw OrganizationAIControllerError.accountScopeMismatch }
    }

    private func validateCurrentScope(_ scope: SynchronizationScope) async throws {
        do {
            try await vault.read { database in
                try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
            }
        } catch {
            throw OrganizationAIControllerError.staleSynchronizationScope
        }
    }

    private func cancelAndWait(for scope: Scope) async {
        guard let operation = activeOperations.removeValue(forKey: scope) else { return }
        operation.cancel()
        await operation.waitForQuiescence()
    }

    private func validateVaultAccount(_ accountID: AccountID) throws {
        guard accountID == vault.accountID else { throw OrganizationAIControllerError.accountScopeMismatch }
    }

    @discardableResult
    private func advanceGeneration(for scope: Scope) -> UInt64 {
        let next = (generations[scope] ?? 0) &+ 1
        generations[scope] = next
        return next
    }
}
