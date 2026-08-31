import Foundation
import GRDB

/// The single dependency boundary between durable normalized sources and the
/// derived projection. Source refreshers must finish their own committed
/// transactions before calling this coordinator; a derived failure never asks
/// a source refresher to roll back or replace its authoritative data.
struct OrganizationRefreshCompletionCoordinator: Sendable {
    typealias ScopeValidation = @Sendable (SynchronizationScope) async throws -> Void
    typealias Projection = @Sendable (
        SynchronizationScope,
        DerivedAIPolicy,
        Date
    ) async throws -> OrganizationDerivedIntelligenceProjectionOutcome
    typealias AIPolicyResolution = @Sendable (SynchronizationScope, GitHubAccount, Date) async throws -> DerivedAIPolicy

    private let validateScope: ScopeValidation
    private let project: Projection
    private let resolveAIPolicy: AIPolicyResolution

    init(
        vault: AccountVault,
        businessDayPolicy: BusinessDayPolicy = .init(),
        resolveAIPolicy: @escaping AIPolicyResolution = { _, _, _ in
            DerivedAIPolicy(
                isOrganizationConsentActive: false,
                isAuthenticationValid: false,
                isEntitled: false,
                hasAvailableBudget: false
            )
        }
    ) {
        let projectionService = OrganizationDerivedIntelligenceProjectionService(vault: vault)
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
            project: { scope, aiPolicy, evaluatedAt in
                try await projectionService.recomputeAfterNormalizedCommit(
                    for: scope,
                    aiPolicy: aiPolicy,
                    evaluatedAt: evaluatedAt,
                    businessDayPolicy: businessDayPolicy
                )
            },
            resolveAIPolicy: resolveAIPolicy
        )
    }

    init(
        validateScope: @escaping ScopeValidation,
        project: @escaping Projection,
        resolveAIPolicy: @escaping AIPolicyResolution = { _, _, _ in
            DerivedAIPolicy(isOrganizationConsentActive: false, isAuthenticationValid: false, isEntitled: false, hasAvailableBudget: false)
        }
    ) {
        self.validateScope = validateScope
        self.project = project
        self.resolveAIPolicy = resolveAIPolicy
    }

    /// Builds the durable projection only after the caller has committed all
    /// normalized source work for this refresh. The app has no authorized AI
    /// policy owner on this path yet, so this explicitly performs core-only
    /// derivation; it never creates AI candidates by implication.
    func finalizeAfterNormalizedCommit(
        for scope: SynchronizationScope,
        account: GitHubAccount? = nil,
        evaluatedAt: Date,
        aiPolicy: DerivedAIPolicy? = nil
    ) async throws -> OrganizationDerivedIntelligenceProjectionOutcome {
        try await validateScope(scope)
        try Task.checkCancellation()
        let resolvedPolicy: DerivedAIPolicy
        if let aiPolicy {
            resolvedPolicy = aiPolicy
        } else if let account {
            resolvedPolicy = try await resolveAIPolicy(scope, account, evaluatedAt)
        } else {
            resolvedPolicy = Self.coreOnlyAIPolicy
        }
        let outcome = try await project(scope, resolvedPolicy, evaluatedAt)
        try Task.checkCancellation()
        try await validateScope(scope)
        try Task.checkCancellation()

        if case let .failed(failure) = outcome {
            throw OrganizationRefreshCompletionCoordinatorError.derivedProjectionFailed(failure)
        }
        return outcome
    }

    private static let coreOnlyAIPolicy = DerivedAIPolicy(
        isOrganizationConsentActive: false,
        isAuthenticationValid: false,
        isEntitled: false,
        hasAvailableBudget: false
    )
}

enum OrganizationRefreshCompletionCoordinatorError: Error, Equatable, Sendable {
    case derivedProjectionFailed(OrganizationDerivedIntelligenceProjectionFailure)
}
