import Foundation
import GRDB

/// The terminal state of a derived projection requested after a normalized
/// source commit. A partial projection is durable, but is explicitly marked
/// as unsuitable for decisions that require complete coverage.
enum OrganizationDerivedIntelligenceProjectionOutcome: Equatable, Sendable {
    case published(OrganizationDerivedIntelligenceProjectionPublication)
    case partial(OrganizationDerivedIntelligenceProjectionPublication)
    case failed(OrganizationDerivedIntelligenceProjectionFailure)
}

struct OrganizationDerivedIntelligenceProjectionPublication: Equatable, Sendable {
    let scope: SynchronizationScope
    let sourceRevision: String
    let evaluatedAt: Date
    let coverageState: DerivedIntelligenceCoverageState
    let isProvisional: Bool
}

enum OrganizationDerivedIntelligenceProjectionFailure: Equatable, Sendable {
    case scopeValidationFailed
    case snapshotFailed
    case recomputeFailed
    case persistenceFailed
}

/// Bridges a fully committed normalized source snapshot to the durable derived
/// projection. The synchronization owner invokes its single public method
/// immediately after committing normalized data for `scope`.
///
/// Every suspension point is fenced by the current credential/capability
/// revision. A stale scope or task cancellation throws `CancellationError`, so
/// callers cannot publish a success outcome for data that has lost authority.
struct OrganizationDerivedIntelligenceProjectionService: Sendable {
    typealias ScopeValidation = @Sendable (SynchronizationScope) async throws -> Void
    typealias SnapshotLoading = @Sendable (
        SynchronizationScope,
        DerivedAIPolicy,
        Date,
        BusinessDayPolicy,
        Calendar
    ) async throws -> DerivedIntelligenceInputSnapshot
    typealias Recomputing = @Sendable (DerivedIntelligenceInput) throws -> DerivedIntelligenceOutput
    typealias Persistence = @Sendable (DerivedIntelligencePersistenceSnapshot) async throws -> Void

    private let validateScope: ScopeValidation
    private let loadSnapshot: SnapshotLoading
    private let recompute: Recomputing
    private let persist: Persistence

    init(vault: AccountVault, coordinator: DerivedIntelligenceCoordinator = .init()) {
        let adapter = DerivedIntelligenceInputAdapter(vault: vault)
        let repository = DerivedIntelligenceRepository(vault: vault)
        self.init(
            validateScope: { scope in
                try Task.checkCancellation()
                guard scope.accountID == vault.accountID else {
                    throw CancellationError()
                }
                do {
                    try await vault.read { database in
                        try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
                    }
                } catch let error as OrganizationSchedulerStateRepositoryError {
                    switch error {
                    case .accountScopeMismatch, .organizationScopeMismatch, .staleSynchronizationScope:
                        throw CancellationError()
                    default:
                        throw error
                    }
                }
                try Task.checkCancellation()
            },
            loadSnapshot: { scope, aiPolicy, evaluatedAt, businessDayPolicy, calendar in
                try await adapter.snapshot(
                    for: scope,
                    aiPolicy: aiPolicy,
                    evaluatedAt: evaluatedAt,
                    businessDayPolicy: businessDayPolicy,
                    calendar: calendar
                )
            },
            recompute: { input in
                try coordinator.recompute(input)
            },
            persist: { snapshot in
                try await repository.replace(snapshot)
            }
        )
    }

    init(
        validateScope: @escaping ScopeValidation,
        loadSnapshot: @escaping SnapshotLoading,
        recompute: @escaping Recomputing,
        persist: @escaping Persistence
    ) {
        self.validateScope = validateScope
        self.loadSnapshot = loadSnapshot
        self.recompute = recompute
        self.persist = persist
    }

    /// Recomputes and durably replaces the derived projection for a committed
    /// normalized source snapshot. Non-cancellation errors are surfaced as an
    /// explicit failed outcome; stale revision and task cancellation fail
    /// closed by throwing `CancellationError`.
    func recomputeAfterNormalizedCommit(
        for scope: SynchronizationScope,
        aiPolicy: DerivedAIPolicy,
        evaluatedAt: Date = .now,
        businessDayPolicy: BusinessDayPolicy = .init(),
        calendar: Calendar = .current
    ) async throws -> OrganizationDerivedIntelligenceProjectionOutcome {
        guard try await isScopeCurrent(scope) else {
            return .failed(.scopeValidationFailed)
        }

        let inputSnapshot: DerivedIntelligenceInputSnapshot
        do {
            inputSnapshot = try await loadSnapshot(scope, aiPolicy, evaluatedAt, businessDayPolicy, calendar)
        } catch {
            try rethrowCancellation(for: error)
            return .failed(.snapshotFailed)
        }

        guard try await isScopeCurrent(scope) else {
            return .failed(.scopeValidationFailed)
        }
        try Task.checkCancellation()

        let output: DerivedIntelligenceOutput
        do {
            output = try recompute(inputSnapshot.input)
        } catch {
            try rethrowCancellation(for: error)
            return .failed(.recomputeFailed)
        }
        try Task.checkCancellation()

        let durableSnapshot = DerivedIntelligencePersistenceSnapshot(
            scope: scope,
            sourceRevision: inputSnapshot.aggregateSourceRevision,
            evaluatedAt: evaluatedAt,
            coverage: output.coverage,
            coverageState: output.coverageState,
            isProvisional: inputSnapshot.isProvisional,
            items: output.items.map {
                DerivedIntelligencePersistenceItem(
                    workItemID: $0.workItemID,
                    attentionReasons: $0.attentionReasons,
                    score: $0.score,
                    searchDocument: $0.searchDocument
                )
            },
            aiCandidates: output.aiCandidates,
            aiCandidateExclusions: output.aiCandidateExclusions
        )

        guard try await isScopeCurrent(scope) else {
            return .failed(.scopeValidationFailed)
        }
        do {
            try await persist(durableSnapshot)
        } catch {
            try rethrowCancellation(for: error)
            return .failed(.persistenceFailed)
        }
        guard try await isScopeCurrent(scope) else {
            return .failed(.scopeValidationFailed)
        }

        let publication = OrganizationDerivedIntelligenceProjectionPublication(
            scope: scope,
            sourceRevision: inputSnapshot.aggregateSourceRevision,
            evaluatedAt: evaluatedAt,
            coverageState: output.coverageState,
            isProvisional: inputSnapshot.isProvisional
        )
        return inputSnapshot.isProvisional || output.coverageState != .trusted
            ? .partial(publication)
            : .published(publication)
    }

    private func isScopeCurrent(_ scope: SynchronizationScope) async throws -> Bool {
        do {
            try await validateScope(scope)
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    private func rethrowCancellation(for error: Error) throws {
        if error is CancellationError {
            throw CancellationError()
        }
        if let adapterError = error as? DerivedIntelligenceInputAdapterError,
           adapterError == .staleSynchronizationScope || adapterError == .accountScopeMismatch {
            throw CancellationError()
        }
        if let repositoryError = error as? DerivedIntelligenceRepositoryError,
           repositoryError == .staleSynchronizationScope || repositoryError == .accountScopeMismatch {
            throw CancellationError()
        }
    }
}
