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
    /// The user's persisted choice. `nil` remains the Auto preference.
    let selectedModelID: String?
    /// The exact model authenticated for this lease. Auto resolves to the one
    /// current, authenticated default rather than delegating model choice to
    /// the helper at execution time.
    let effectiveModelID: String?
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

/// The only result shape that may create automatic Copilot actions. The
/// controller commits the analysis and actions in one authorization-checked
/// transaction, so a consent or authority change cannot leave an orphaned
/// action behind.
struct AuthorizedAIAnalysisResult: Sendable {
    let analysis: StoredAIAnalysis
    let actionItems: [ActionItem]
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
    /// Consent and model changes may suspend while a prior analysis drains.
    /// Serialize those mutations so an older operation cannot commit after a
    /// newer user choice simply because its cancellation wait completed later.
    private let consentMutationGate = OrganizationAIConsentMutationGate()
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
        await consentMutationGate.acquire()
        do {
            let generation = advanceGeneration(for: scope)
            await cancelAndWait(for: scope)
            try requireCurrentMutation(scope, generation: generation)
            let previousConsent = try await consentRepository.consent(
                for: consent.accountID,
                organizationID: consent.organizationID
            )
            if !consent.isEnabled {
                try await analysisRepository.eraseOrganizationAIData(
                    for: consent.accountID,
                    organizationID: consent.organizationID,
                    at: date
                )
                try requireCurrentMutation(scope, generation: generation)
                await consentMutationGate.release()
                return
            }
            if previousConsent.isEnabled {
                try await analysisRepository.eraseOrganizationAIOutputs(
                    for: consent.accountID,
                    organizationID: consent.organizationID,
                    at: date
                )
            } else {
                try await analysisRepository.eraseOrganizationAIArtifacts(
                    for: consent.accountID,
                    organizationID: consent.organizationID,
                    at: date
                )
            }
            try requireCurrentMutation(scope, generation: generation)
            try await consentRepository.save(consent, at: date)
            try requireCurrentMutation(scope, generation: generation)
            await consentMutationGate.release()
        } catch {
            await consentMutationGate.release()
            throw error
        }
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
                effectiveModelID: nil,
                derivedPolicy: DerivedAIPolicy(
                    isOrganizationConsentActive: false,
                    isAuthenticationValid: false,
                    isEntitled: false,
                    hasAvailableBudget: false,
                    selectedModelID: nil,
                    automaticActionConfidenceThreshold: consent.automaticActionConfidenceThreshold
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
        let effectiveModelID: String?
        if let selectedModelID = consent.selectedModelID {
            effectiveModelID = cachedModelIDs.contains(selectedModelID)
                && external.availableModelIDs.contains(selectedModelID)
                ? selectedModelID
                : nil
        } else {
            // A runtime default is authority, not a presentation hint. It
            // must be present in the bounded authenticated inventory and be
            // exactly one currently available default before Auto can run.
            let defaults = cachedModels.filter {
                $0.isDefault && external.availableModelIDs.contains($0.id)
            }
            effectiveModelID = external.supportsAutoModel && defaults.count == 1
                ? defaults[0].id
                : nil
        }
        let modelIsValid = effectiveModelID != nil
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
            selectedModelID: consent.selectedModelID,
            effectiveModelID: effectiveModelID,
            automaticActionConfidenceThreshold: consent.automaticActionConfidenceThreshold
        )
        return OrganizationAIExecutionPolicy(
            consent: consent,
            selectedModelID: consent.selectedModelID,
            effectiveModelID: effectiveModelID,
            derivedPolicy: derived,
            isModelSelectionValid: modelIsValid
        )
    }

    func replaceModels(
        _ models: [CopilotModel],
        for scope: SynchronizationScope,
        expiresAt: Date,
        at date: Date = .now
    ) async throws {
        try await validateCurrentScope(scope)
        try await analysisRepository.replaceModels(
            models,
            for: scope.accountID,
            organizationID: scope.organizationID,
            expiresAt: expiresAt,
            at: date
        )
    }

    func cachedModels(
        for scope: SynchronizationScope,
        at date: Date = .now
    ) async throws -> [CopilotModel] {
        try await validateCurrentScope(scope)
        return try await analysisRepository.cachedModels(
            for: scope.accountID,
            organizationID: scope.organizationID,
            at: date
        )
    }

    func selectModel(
        _ selectedModelID: String?,
        for scope: SynchronizationScope,
        at date: Date = .now
    ) async throws {
        try await validateCurrentScope(scope)
        let consent = try await consentRepository.consent(
            for: scope.accountID,
            organizationID: scope.organizationID
        )
        guard consent.isEnabled else { throw OrganizationAIControllerError.policyUnavailable }
        if let selectedModelID {
            let cached = try await cachedModels(for: scope, at: date)
            let availableIDs = cached.map(\.id)
            guard availableIDs.contains(selectedModelID) else {
                throw OrganizationAIControllerError.policyUnavailable
            }
        }
        guard consent.selectedModelID != selectedModelID else { return }
        try await recordConsent(.init(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            isEnabled: true,
            selectedModelID: selectedModelID,
            automaticActionConfidenceThreshold: consent.automaticActionConfidenceThreshold,
            updatedAt: date
        ), at: date)
    }

    func setAutomaticActionConfidenceThreshold(
        _ threshold: Double,
        for scope: SynchronizationScope,
        at date: Date = .now
    ) async throws {
        guard AIConsentRepository.isValidAutomaticActionConfidenceThreshold(threshold) else {
            throw AIConsentRepositoryError.invalidAutomaticActionConfidenceThreshold
        }
        try await validateCurrentScope(scope)
        let consent = try await consentRepository.consent(
            for: scope.accountID,
            organizationID: scope.organizationID
        )
        guard consent.isEnabled else { throw OrganizationAIControllerError.policyUnavailable }
        guard consent.automaticActionConfidenceThreshold != threshold else { return }
        try await recordConsent(.init(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            isEnabled: true,
            selectedModelID: consent.selectedModelID,
            automaticActionConfidenceThreshold: threshold,
            updatedAt: date
        ), at: date)
    }

    func invalidateModelCache(for scope: SynchronizationScope) async throws {
        try await validateCurrentScope(scope)
        try await analysisRepository.invalidateModelCache(
            for: scope.accountID,
            organizationID: scope.organizationID
        )
    }

    /// A credential or runtime change invalidates model authority for every
    /// organization in this account vault, not only the currently selected
    /// organization.
    func invalidateModelCaches(for accountID: AccountID) async throws {
        try validateVaultAccount(accountID)
        try await analysisRepository.invalidateModelCaches(for: accountID)
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
        guard let effectiveModelID = policy.effectiveModelID else {
            throw OrganizationAIControllerError.policyUnavailable
        }
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
                selectedModelID: lease.policy.selectedModelID,
                effectiveModelID: effectiveModelID
            )
        }
        try await verifyCurrent(lease)
    }

    /// Variant for the production execution path. It preserves the same
    /// policy, generation, cancellation, and current-scope fences as a plain
    /// analysis while atomically writing only independently validated actions.
    func performAuthorizedActionAnalysis(
        for scope: SynchronizationScope,
        account: GitHubAccount,
        at date: Date = .now,
        operation: @escaping @Sendable (OrganizationAIAnalysisLease) async throws -> AuthorizedAIAnalysisResult?
    ) async throws {
        try validateScope(scope, account: account)
        try await validateCurrentScope(scope)
        let key = Scope(accountID: scope.accountID, organizationID: scope.organizationID)
        let generation = advanceGeneration(for: key)
        await cancelAndWait(for: key)
        let policy = try await policy(for: scope, account: account, at: date)
        guard generations[key] == generation else {
            throw OrganizationAIControllerError.staleOperation
        }
        guard policy.permitsAnalysis else { throw OrganizationAIControllerError.policyUnavailable }
        guard let effectiveModelID = policy.effectiveModelID else {
            throw OrganizationAIControllerError.policyUnavailable
        }
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
                result.analysis,
                for: lease.scope,
                selectedModelID: lease.policy.selectedModelID,
                effectiveModelID: effectiveModelID,
                actionItems: result.actionItems
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
        guard consent.isEnabled,
              consent.selectedModelID == lease.policy.selectedModelID,
              consent.automaticActionConfidenceThreshold == lease.policy.consent.automaticActionConfidenceThreshold
        else {
            throw OrganizationAIControllerError.staleOperation
        }
        try await validateCurrentScope(lease.scope)
        guard generations[key] == lease.generation else {
            throw OrganizationAIControllerError.staleOperation
        }
    }

    func cancelAndDisable(for scope: SynchronizationScope, at date: Date = .now) async throws {
        try validateVaultAccount(scope.accountID)
        let key = Scope(accountID: scope.accountID, organizationID: scope.organizationID)
        await consentMutationGate.acquire()
        do {
            try await validateCurrentScope(scope)
            let generation = advanceGeneration(for: key)
            await cancelAndWait(for: key)
            try requireCurrentMutation(key, generation: generation)
            // The caller's authority can change while a non-cooperative external
            // operation is draining. Never let a stale scope erase data under a
            // replacement credential/capability revision.
            try await validateCurrentScope(scope)
            try requireCurrentMutation(key, generation: generation)
            try await analysisRepository.eraseOrganizationAIData(
                for: scope.accountID,
                organizationID: scope.organizationID,
                at: date
            )
            try requireCurrentMutation(key, generation: generation)
            await consentMutationGate.release()
        } catch {
            await consentMutationGate.release()
            throw error
        }
    }

    /// Account teardown must not merely drop the registry reference: a
    /// non-cooperative external operation can retain this controller and keep
    /// running. Invalidate every lease, cancel all operations, and wait for
    /// their bounded operation tasks to quiesce before the vault lifetime is
    /// released.
    func cancelAll() async {
        let scopes = Set(generations.keys).union(activeOperations.keys)
        for scope in scopes {
            advanceGeneration(for: scope)
        }
        let operations = Array(activeOperations.values)
        activeOperations.removeAll()
        for operation in operations {
            operation.cancel()
        }
        for operation in operations {
            await operation.waitForQuiescence()
        }
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

    private func requireCurrentMutation(_ scope: Scope, generation: UInt64) throws {
        guard generations[scope] == generation else {
            throw OrganizationAIControllerError.staleOperation
        }
    }

    @discardableResult
    private func advanceGeneration(for scope: Scope) -> UInt64 {
        let next = (generations[scope] ?? 0) &+ 1
        generations[scope] = next
        return next
    }
}

/// An actor-local gate deliberately spans suspension points. `OrganizationAIController`
/// itself is reentrant, so generation checks alone cannot preserve request order for
/// durable consent mutations that await a non-cooperative analysis drain.
private actor OrganizationAIConsentMutationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum OrganizationCopilotExecutionError: Error, Equatable, Sendable {
    case staleDerivedProjection
    case invalidCandidate
    case invalidEvidence
    case invalidResponse
}

/// Constructs the deliberately small, source-bounded request admitted to the
/// helper. It lives outside views and XPC so both the cache key and the
/// production request use byte-for-byte equivalent normalized input.
enum CopilotCandidateInputBuilder {
    static func make(
        candidateID: AIRequestID,
        triggerReasonIDs: [String],
        workItem: WorkItem,
        document: SearchDocument,
        timeline: [TimelineEventSummary] = [],
        scope: SynchronizationScope
    ) throws -> CopilotAnalysisInput {
        let reasons = Array(Set(triggerReasonIDs)).sorted()
        guard !reasons.isEmpty,
              document.accountID == scope.accountID,
              document.organizationID == scope.organizationID,
              document.workItemID == workItem.id,
              document.nodeID == workItem.primaryNodeID,
              Set(reasons).isSubset(of: Set(workItem.attentionReasons.map(\.id)))
        else {
            throw OrganizationCopilotExecutionError.invalidCandidate
        }
        let evidence = workItem.attentionReasons
            .filter { reasons.contains($0.id) }
            .flatMap(\.evidence)
            .filter { isCurrent($0, scope: scope) }
        let evidenceByID = Dictionary(
            evidence.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let evidenceIDs = evidenceByID.keys.sorted { $0.rawValue < $1.rawValue }
        guard !evidenceIDs.isEmpty else {
            throw OrganizationCopilotExecutionError.invalidEvidence
        }
        let eventsByID = Dictionary(uniqueKeysWithValues: timeline.map { ($0.id, $0) })
        let evidenceTable = evidenceIDs.compactMap { id -> CopilotEvidenceExcerpt? in
            guard let reference = evidenceByID[id] else { return nil }
            let event = reference.eventID.flatMap { eventsByID[$0] }
            let actorRole: String
            if let actor = event?.actor {
                actorRole = "actor:\(actor.nodeID.rawValue)"
            } else {
                actorRole = "source:unknown"
            }
            return CopilotEvidenceExcerpt(
                id: id,
                // Event actor aliases are source-backed. Other evidence is
                // explicitly unknown rather than guessed from display text.
                actorRole: actorRole,
                text: bounded(reference.excerpt ?? "", maximumUTF8Bytes: 8_192),
                timestamp: event?.occurredAt ?? reference.observedAt,
                explicitDeadline: nil
            )
        }
        guard evidenceTable.count == evidenceIDs.count else {
            throw OrganizationCopilotExecutionError.invalidEvidence
        }
        let input = CopilotAnalysisInput(
            candidateID: candidateID,
            workItemTitle: document.title,
            workItemState: workItem.state.rawValue,
            deterministicReasons: reasons,
            // `SearchDocument` is already derived from normalized content and
            // bounded at 64 KiB. Do not add local notes, paths, or arbitrary
            // database fields to the helper boundary.
            body: document.body,
            labels: boundedTerms(document.labels, maximumCount: 64, maximumUTF8Bytes: 256),
            projectFields: document.projectValues.isEmpty
                ? [:]
                : ["normalized": bounded(document.projectValues, maximumUTF8Bytes: 2_048)],
            conversation: evidenceTable
                .filter { !$0.text.isEmpty }
                .prefix(24)
                .map {
                    CopilotConversationExcerpt(
                        evidenceID: $0.id,
                        authorRole: $0.actorRole,
                        text: $0.text,
                        timestamp: $0.timestamp
                    )
                },
            evidence: evidenceTable,
            evidenceIDs: evidenceIDs
        )
        try input.validate()
        return input
    }

    static func derivedCandidateID(
        workItemID: WorkItemID,
        triggerReasonIDs: [String]
    ) throws -> AIRequestID {
        let reasons = Array(Set(triggerReasonIDs)).sorted()
        guard !reasons.isEmpty,
              let id = AIRequestID(rawValue: "\(workItemID.rawValue):\(reasons.joined(separator: ","))")
        else {
            throw OrganizationCopilotExecutionError.invalidCandidate
        }
        return id
    }

    static func isCurrent(_ evidence: EvidenceReference, scope: SynchronizationScope) -> Bool {
        switch (evidence.source, evidence.locator, evidence.authority) {
        case let (source, locator, .github(evidenceScope, _, _))
            where source != .localWorkflow
                && source != .legacyUnverified
                && evidenceScope == scope
                && evidence.confidence == .confirmed
                && evidence.confirmation == .confirmed
                && !(evidence.sourceRevision?.isEmpty ?? true):
            if case .endpoint = locator { return true }
            if case .query = locator { return true }
            return false
        case let (.localWorkflow, .localWorkflow(locator), .localWorkflow(accountID, organizationID)):
            return !locator.isEmpty
                && accountID == scope.accountID
                && organizationID == scope.organizationID
                && evidence.confidence == .confirmed
                && evidence.confirmation == .confirmed
        default:
            return false
        }
    }

    private static func boundedTerms(
        _ value: String,
        maximumCount: Int,
        maximumUTF8Bytes: Int
    ) -> [String] {
        var values: [String] = []
        var seen = Set<String>()
        for term in value.split(whereSeparator: { $0.isWhitespace }) {
            let bounded = bounded(String(term), maximumUTF8Bytes: maximumUTF8Bytes)
            guard !bounded.isEmpty, seen.insert(bounded).inserted else { continue }
            values.append(bounded)
            if values.count == maximumCount { break }
        }
        return values
    }

    private static func bounded(_ value: String, maximumUTF8Bytes: Int) -> String {
        guard value.utf8.count > maximumUTF8Bytes else { return value }
        var index = value.startIndex
        var count = 0
        while index < value.endIndex {
            let next = value.index(after: index)
            let nextCount = value[index..<next].utf8.count
            guard count + nextCount <= maximumUTF8Bytes else { break }
            count += nextCount
            index = next
        }
        return String(value[..<index])
    }
}

/// Executes only durable, trusted candidates. It intentionally does not know
/// about GitHub clients or source mutation: its complete input is a fenced
/// normalized projection, and its only external dependency is the signed XPC
/// helper protocol.
actor OrganizationCopilotExecutionService {
    static let promptVersion = 1
    static let outputSchemaVersion = 1
    static let automaticActionConfidenceFloor = 0.92
    static let maximumAnalysisDuration: TimeInterval = 45
    static let promptProvenance = "triage-copilot-v2"

    private let derivedRepository: DerivedIntelligenceRepository
    private let inputAdapter: DerivedIntelligenceInputAdapter
    private let analysisRepository: AIAnalysisRepository
    private let controller: OrganizationAIController
    private let makeHelper: @Sendable () -> any TriageCopilotHelping
    // Preserve the XPC connection between candidate runs. The service fences
    // the actual authenticated session by account, organization, and runtime
    // revision; retaining this client prevents connection teardown from
    // needlessly invalidating a valid scoped session.
    private var helper: (any TriageCopilotHelping)?
    private let candidateBudgetScheduler: any CandidateBudgetScheduling

    init(
        vault: AccountVault,
        controller: OrganizationAIController,
        candidateBudgetScheduler: (any CandidateBudgetScheduling)? = nil,
        makeHelper: @escaping @Sendable () -> any TriageCopilotHelping = {
            CopilotHelperClient(
                transport: CopilotXPCFrameTransport(service: CopilotXPCServiceClient())
            )
        }
    ) {
        derivedRepository = DerivedIntelligenceRepository(vault: vault)
        inputAdapter = DerivedIntelligenceInputAdapter(vault: vault)
        analysisRepository = AIAnalysisRepository(vault: vault)
        self.controller = controller
        self.candidateBudgetScheduler = candidateBudgetScheduler
            ?? OrganizationCopilotCandidateBudgetScheduler(vault: vault)
        self.makeHelper = makeHelper
    }

    /// Runs persisted candidates serially through the organization controller.
    /// Deterministic refresh callers should treat a helper failure as optional;
    /// this method never writes GitHub and never changes deterministic state.
    func executePersistedCandidates(
        for scope: SynchronizationScope,
        account: GitHubAccount,
        environment: OrganizationCopilotCandidateBudgetEnvironment,
        at date: Date = .now,
        deadline: Date? = nil
    ) async throws {
        let projection = try await derivedRepository.projection(for: scope)
        guard let projection,
              projection.run.coverageState == .trusted,
              !projection.run.isProvisional
        else { return }
        // The refresh pipeline reaches this path only after a successful
        // online normalized commit.  The other prerequisites are resolved
        // before acquiring a durable counter, so a disabled/revoked Copilot
        // state cannot consume a candidate attempt merely to be rejected by
        // the controller one line later.
        let currentPolicy = try await controller.policy(for: scope, account: account, at: date)
        guard currentPolicy.permitsAnalysis else { return }
        let schedulingEligibility = OrganizationCopilotCandidateBudgetEligibility(
            isOnline: environment.isOnline,
            isRemoteRateLimited: environment.isRemoteRateLimited,
            hasOrganizationConsent: currentPolicy.consent.isEnabled,
            isAuthenticated: currentPolicy.derivedPolicy.isAuthenticationValid,
            isEntitled: currentPolicy.derivedPolicy.isEntitled
        )
        let candidates = projection.candidates.compactMap(\.candidate)
        let candidatePairs = try candidates.map { candidate -> (AIRequestID, DerivedAICandidate) in
            let requestID = try CopilotCandidateInputBuilder.derivedCandidateID(
                workItemID: candidate.workItemID,
                triggerReasonIDs: candidate.triggerReasonIDs
            )
            return (requestID, candidate)
        }
        guard Set(candidatePairs.map { $0.0 }).count == candidatePairs.count else {
            throw OrganizationCopilotExecutionError.invalidCandidate
        }
        let candidatesByRequestID = Dictionary(uniqueKeysWithValues: candidatePairs)
        let budgetCandidates = candidatePairs.map { requestID, candidate in
            OrganizationCopilotBudgetCandidate(
                id: requestID,
                priority: candidate.score.value
            )
        }
        let operationDeadline = deadline ?? date.addingTimeInterval(Self.maximumAnalysisDuration)
        guard operationDeadline > date else { return }
        while let reservation = try await candidateBudgetScheduler.nextReservation(
            from: budgetCandidates,
            sourceFingerprint: projection.run.sourceRevision,
            for: scope,
            eligibility: schedulingEligibility,
            at: date
        ) {
            do {
                // The reservation exists before this check. Keep the entire
                // path in the cancellation handler so a task cancelled at
                // this exact point releases durable concurrency immediately.
                try Task.checkCancellation()
                guard let candidate = candidatesByRequestID[reservation.candidate.id] else {
                    throw OrganizationCopilotExecutionError.invalidCandidate
                }
                let helper = helperForCurrentService()
                try await controller.performAuthorizedActionAnalysis(
                    for: scope,
                    account: account,
                    at: date
                ) { [self] lease in
                    try await self.execute(
                        candidate: candidate,
                        expectedProjectionRevision: projection.run.sourceRevision,
                        scope: scope,
                        lease: lease,
                        deadline: operationDeadline,
                        at: date,
                        helper: helper
                    )
                }
                try await candidateBudgetScheduler.finish(reservation, disposition: .completed, at: date)
            } catch {
                try? await candidateBudgetScheduler.finish(reservation, disposition: .cancelled, at: date)
                throw error
            }
        }
    }

    private func helperForCurrentService() -> any TriageCopilotHelping {
        if let helper { return helper }
        let helper = makeHelper()
        self.helper = helper
        return helper
    }

    private func execute(
        candidate: DerivedAICandidate,
        expectedProjectionRevision: String,
        scope: SynchronizationScope,
        lease: OrganizationAIAnalysisLease,
        deadline: Date,
        at date: Date,
        helper: any TriageCopilotHelping
    ) async throws -> AuthorizedAIAnalysisResult? {
        try await controller.verifyCurrent(lease)
        let projection = try await derivedRepository.projection(for: scope)
        guard let projection,
              projection.run.coverageState == .trusted,
              !projection.run.isProvisional,
              projection.run.sourceRevision == expectedProjectionRevision,
              projection.candidates.contains(where: { $0.candidate == candidate })
        else {
            throw OrganizationCopilotExecutionError.staleDerivedProjection
        }
        let snapshot = try await inputAdapter.snapshot(
            for: scope,
            aiPolicy: lease.policy.derivedPolicy,
            evaluatedAt: date
        )
        guard !snapshot.isProvisional,
              snapshot.aggregateSourceRevision == projection.run.sourceRevision,
              let item = snapshot.input.items.first(where: { $0.workItem.id == candidate.workItemID })
        else {
            throw OrganizationCopilotExecutionError.staleDerivedProjection
        }
        let candidateID = try CopilotCandidateInputBuilder.derivedCandidateID(
            workItemID: candidate.workItemID,
            triggerReasonIDs: candidate.triggerReasonIDs
        )
        let input = try CopilotCandidateInputBuilder.make(
            candidateID: candidateID,
            triggerReasonIDs: candidate.triggerReasonIDs,
            workItem: item.workItem,
            document: item.searchDocument,
            timeline: item.timeline,
            scope: scope
        )
        let effectiveModelID = try requireEffectiveModelID(from: lease.policy)
        let fingerprint = try AIFingerprint.make(
            scope: scope,
            input: input,
            sourceRevision: projection.run.sourceRevision,
            selectedModelID: lease.policy.selectedModelID,
            effectiveModelID: effectiveModelID,
            automaticActionConfidenceThreshold: lease.policy.consent.automaticActionConfidenceThreshold,
            promptVersion: Self.promptVersion,
            outputSchemaVersion: Self.outputSchemaVersion
        )
        let key = AIAnalysisCacheKey(
            workItemID: candidate.workItemID,
            fingerprint: fingerprint,
            selectedModelID: lease.policy.selectedModelID,
            effectiveModelID: effectiveModelID,
            promptVersion: Self.promptVersion,
            outputSchemaVersion: Self.outputSchemaVersion
        )
        guard try await analysisRepository.validAnalysis(for: scope, key: key, at: date) == nil,
              !(try await analysisRepository.hasDismissedCopilotAction(
                for: scope,
                workItemID: candidate.workItemID,
                sourceFingerprint: fingerprint
              ))
        else { return nil }
        try await controller.verifyCurrent(lease)
        let response = try await helper.analyze(CopilotAnalyzeRequest(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            input: input,
            modelID: effectiveModelID,
            deadline: deadline
        ))
        try response.validate(against: input)
        guard response.promptProvenance == Self.promptProvenance,
              response.modelID == effectiveModelID
        else {
            throw OrganizationCopilotExecutionError.invalidResponse
        }
        let encodedResponse = try JSONEncoder.triageSorted.encode(response)
        let analysis = StoredAIAnalysis(
            id: "analysis-\(fingerprint)",
            key: key,
            modelID: response.modelID,
            resultJSON: encodedResponse,
            createdAt: date
        )
        let actions = Self.automaticActions(
            response: response,
            input: input,
            workItemID: candidate.workItemID,
            fingerprint: fingerprint,
            confidenceThreshold: lease.policy.consent.automaticActionConfidenceThreshold,
            at: date
        )
        return AuthorizedAIAnalysisResult(analysis: analysis, actionItems: actions)
    }

    private func requireEffectiveModelID(
        from policy: OrganizationAIExecutionPolicy
    ) throws -> String {
        guard let effectiveModelID = policy.effectiveModelID,
              AIConsentRepository.isValidModelID(effectiveModelID)
        else { throw OrganizationCopilotExecutionError.invalidResponse }
        return effectiveModelID
    }

    /// This is intentionally a second, local validator rather than relying on
    /// the helper's schema validation above.  An analysis can be preserved for
    /// review with no claims, but no automatic local action is admitted until
    /// every claim is still an exact match for this current normalized input.
    nonisolated static func automaticActions(
        response: CopilotAnalysisResponse,
        input: CopilotAnalysisInput,
        workItemID: WorkItemID,
        fingerprint: String,
        confidenceThreshold: Double = OrganizationAIConsent.minimumAutomaticActionConfidenceThreshold,
        at date: Date
    ) -> [ActionItem] {
        // An AI state may still be useful review-only output, but automatic
        // Inbox actions may not contradict the current normalized state.
        guard (try? input.validate()) != nil,
              AIConsentRepository.isValidAutomaticActionConfidenceThreshold(confidenceThreshold),
              response.confidence >= confidenceThreshold,
              response.state == input.workItemState
        else { return [] }
        let evidenceByID = Dictionary(uniqueKeysWithValues: input.evidence.map { ($0.id, $0) })
        let currentEvidenceIDs = Set(input.evidenceIDs)
        let currentReasons = Set(input.deterministicReasons)
        return response.actionItems.enumerated().compactMap { index, suggestion in
            let evidence = Array(Set(suggestion.evidenceIDs)).sorted { $0.rawValue < $1.rawValue }
            let claimedEvidence = Set(suggestion.claims.map(\.evidenceID))
            guard !evidence.isEmpty,
                  !suggestion.claims.isEmpty,
                  suggestion.confidence >= confidenceThreshold,
                  Set(evidence).isSubset(of: currentEvidenceIDs),
                  claimedEvidence == Set(evidence),
                  suggestion.claims.allSatisfy({ claim in
                      guard let source = evidenceByID[claim.evidenceID] else { return false }
                      return claim.actorRole == source.actorRole
                        && claim.timestamp == source.timestamp
                        && !claim.quotedSpan.isEmpty
                        && source.text.contains(claim.quotedSpan)
                        && currentReasons.contains(claim.deterministicReasonID)
                  }),
                  evidence.allSatisfy({ evidenceByID[$0]?.text.isEmpty == false }),
                  (suggestion.deadline == nil || evidence.contains { evidenceID in
                      evidenceByID[evidenceID]?.explicitDeadline == suggestion.deadline
                  }),
                  suggestion.text.utf8.count <= 500,
                  !containsUnsafeInstruction(suggestion.text),
                  suggestion.claims.allSatisfy({ !containsUnsafeInstruction($0.quotedSpan) }),
                  hasLexicalEvidenceSupport(for: suggestion.text, claims: suggestion.claims),
                  let id = ActionItemID(rawValue: "copilot-\(fingerprint)-\(index)")
            else { return nil }
            return ActionItem(
                id: id,
                workItemID: workItemID,
                title: suggestion.text,
                origin: .copilot,
                priority: .normal,
                dueAt: suggestion.deadline,
                evidenceIDs: evidence,
                sourceFingerprint: fingerprint,
                createdAt: date,
                updatedAt: date
            )
        }
    }

    private nonisolated static func containsUnsafeInstruction(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return [
            "```",
            "ignore previous",
            "ignore all instructions",
            "system prompt",
            "developer message",
            "prompt injection",
            "jailbreak"
        ].contains(where: normalized.contains)
    }

    /// Require a conservative lexical connection between an automatic action
    /// and at least one exact source quote.  This deliberately leaves a
    /// semantically plausible but ungrounded suggestion in review-only state.
    private nonisolated static func hasLexicalEvidenceSupport(
        for action: String,
        claims: [CopilotActionClaim]
    ) -> Bool {
        let actionTerms = meaningfulTerms(in: action)
        guard !actionTerms.isEmpty else { return false }
        return claims.contains { !actionTerms.isDisjoint(with: meaningfulTerms(in: $0.quotedSpan)) }
    }

    private nonisolated static func meaningfulTerms(in value: String) -> Set<String> {
        Set(
            value.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 4 }
        )
    }
}

private extension JSONEncoder {
    static var triageSorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
