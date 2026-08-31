import Foundation

/// Fixed, local-only limits.  They are deliberately conservative: a source
/// revision can launch at most 12 candidates, and an account/organization can
/// launch at most 24 distinct candidate revisions per UTC day.
struct OrganizationCopilotCandidateBudgetPolicy: Equatable, Sendable {
    let maximumCandidatesPerUTCDate: Int
    let maximumCandidatesPerSourceFingerprint: Int
    let minimumStartInterval: TimeInterval
    let maximumConcurrentCandidates: Int
    let maximumLeaseDuration: TimeInterval

    static let production = Self(
        maximumCandidatesPerUTCDate: 24,
        maximumCandidatesPerSourceFingerprint: 12,
        minimumStartInterval: 60,
        maximumConcurrentCandidates: 1,
        maximumLeaseDuration: 60
    )

    var isValid: Bool {
        maximumCandidatesPerUTCDate > 0
            && maximumCandidatesPerSourceFingerprint > 0
            && minimumStartInterval >= 0 && minimumStartInterval.isFinite
            && maximumConcurrentCandidates > 0
            && maximumLeaseDuration > 0 && maximumLeaseDuration.isFinite
    }
}

/// All external preconditions are explicit values.  The scheduler never
/// probes the network, credentials, model runtime, or consent store itself.
/// That keeps the candidate boundary local and prevents an ambient fallback.
struct OrganizationCopilotCandidateBudgetEligibility: Equatable, Sendable {
    let isOnline: Bool
    let isRemoteRateLimited: Bool
    let hasOrganizationConsent: Bool
    let isAuthenticated: Bool
    let isEntitled: Bool

    static let unavailable = Self(
        isOnline: false,
        isRemoteRateLimited: true,
        hasOrganizationConsent: false,
        isAuthenticated: false,
        isEntitled: false
    )

    static let permitted = Self(
        isOnline: true,
        isRemoteRateLimited: false,
        hasOrganizationConsent: true,
        isAuthenticated: true,
        isEntitled: true
    )

    var permitsScheduling: Bool {
        isOnline && !isRemoteRateLimited && hasOrganizationConsent && isAuthenticated && isEntitled
    }
}

/// Connectivity and remote-throttle facts come from the current refresh
/// pipeline. They are separate from consent/auth/entitlement because those
/// are re-read from the controller immediately before a reservation.
struct OrganizationCopilotCandidateBudgetEnvironment: Equatable, Sendable {
    let isOnline: Bool
    let isRemoteRateLimited: Bool

    static let unavailable = Self(isOnline: false, isRemoteRateLimited: true)
}

struct OrganizationCopilotBudgetCandidate: Equatable, Sendable {
    let id: AIRequestID
    let priority: Int
}

struct OrganizationCopilotCandidateBudgetReservation: Equatable, Sendable {
    let scope: SynchronizationScope
    let utcDay: String
    let candidate: OrganizationCopilotBudgetCandidate
    let sourceFingerprint: String
    /// Opaque process-local lease identity. It is visible to the encrypted
    /// repository only so completion can match the exact reservation.
    let leaseID: String
}

enum OrganizationCopilotCandidateBudgetCompletion: Equatable, Sendable {
    case completed
    case cancelled

    var persistedState: String {
        switch self {
        case .completed: "completed"
        case .cancelled: "cancelled"
        }
    }
}

struct OrganizationCopilotCandidateBudgetAvailability: Equatable, Sendable {
    let dailyRemaining: Int
    let sourceRemaining: Int
    let concurrentRemaining: Int
    let isRateLimited: Bool

    var isAvailable: Bool {
        dailyRemaining > 0 && sourceRemaining > 0 && concurrentRemaining > 0 && !isRateLimited
    }
}

protocol CandidateBudgetScheduling: Sendable {
    func nextReservation(
        from candidates: [OrganizationCopilotBudgetCandidate],
        sourceFingerprint: String,
        for scope: SynchronizationScope,
        eligibility: OrganizationCopilotCandidateBudgetEligibility,
        at date: Date
    ) async throws -> OrganizationCopilotCandidateBudgetReservation?

    func finish(
        _ reservation: OrganizationCopilotCandidateBudgetReservation,
        disposition: OrganizationCopilotCandidateBudgetCompletion,
        at date: Date
    ) async throws
}

/// Account-vault scheduler for bounded Copilot work.  It serializes the
/// scheduling decision, while its database transaction makes the limits hold
/// across service instances and app relaunches.
actor OrganizationCopilotCandidateBudgetScheduler: CandidateBudgetScheduling {
    private let repository: OrganizationCopilotCandidateBudgetRepository
    private let policy: OrganizationCopilotCandidateBudgetPolicy
    private let now: @Sendable () -> Date

    init(
        vault: AccountVault,
        policy: OrganizationCopilotCandidateBudgetPolicy = .production,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        repository = OrganizationCopilotCandidateBudgetRepository(vault: vault)
        self.policy = policy
        self.now = now
    }

    func hasAvailableBudget(
        for scope: SynchronizationScope,
        at date: Date? = nil
    ) async throws -> Bool {
        let availability = try await repository.availability(for: scope, policy: policy, at: date ?? now())
        return availability.isAvailable
    }

    func nextReservation(
        from candidates: [OrganizationCopilotBudgetCandidate],
        sourceFingerprint: String,
        for scope: SynchronizationScope,
        eligibility: OrganizationCopilotCandidateBudgetEligibility,
        at date: Date
    ) async throws -> OrganizationCopilotCandidateBudgetReservation? {
        try Task.checkCancellation()
        guard eligibility.permitsScheduling else { return nil }
        for candidate in candidates.sorted(by: Self.precedes) {
            try Task.checkCancellation()
            if let reservation = try await repository.reserve(
                candidate,
                sourceFingerprint: sourceFingerprint,
                for: scope,
                policy: policy,
                at: date
            ) {
                return reservation
            }
        }
        return nil
    }

    func nextReservation(
        from candidates: [OrganizationCopilotBudgetCandidate],
        sourceFingerprint: String,
        for scope: SynchronizationScope,
        eligibility: OrganizationCopilotCandidateBudgetEligibility
    ) async throws -> OrganizationCopilotCandidateBudgetReservation? {
        try await nextReservation(
            from: candidates,
            sourceFingerprint: sourceFingerprint,
            for: scope,
            eligibility: eligibility,
            at: now()
        )
    }

    func finish(
        _ reservation: OrganizationCopilotCandidateBudgetReservation,
        disposition: OrganizationCopilotCandidateBudgetCompletion,
        at date: Date
    ) async throws {
        // Completion is intentionally cancellation-tolerant: callers invoke
        // it from their cancellation handler so a cancelled helper cannot
        // strand a live concurrency lease until timeout.
        try await repository.finish(reservation, disposition: disposition, at: date)
    }

    func finish(
        _ reservation: OrganizationCopilotCandidateBudgetReservation,
        disposition: OrganizationCopilotCandidateBudgetCompletion
    ) async throws {
        try await finish(reservation, disposition: disposition, at: now())
    }

    private nonisolated static func precedes(
        _ left: OrganizationCopilotBudgetCandidate,
        _ right: OrganizationCopilotBudgetCandidate
    ) -> Bool {
        left.priority == right.priority
            ? left.id.rawValue < right.id.rawValue
            : left.priority > right.priority
    }
}

/// Production composition uses this provider only for the coarse policy bit.
/// A later per-candidate lease always rechecks the durable limit immediately
/// before helper work, so a `true` here cannot authorize an over-budget call.
actor OrganizationCopilotCandidateBudgetAvailabilityProvider {
    private let vaultRegistry: VaultRegistry
    private let secretStore: KeychainSecretStore

    init(vaultRegistry: VaultRegistry, secretStore: KeychainSecretStore) {
        self.vaultRegistry = vaultRegistry
        self.secretStore = secretStore
    }

    func hasAvailableBudget(for scope: SynchronizationScope, at date: Date = .now) async -> Bool {
        do {
            guard let vaultKey = try await secretStore.readVaultKey(for: scope.accountID) else { return false }
            let vault = try await vaultRegistry.open(accountID: scope.accountID, vaultKey: vaultKey)
            // Do not retain a scheduler beyond a vault lifecycle. Account
            // removal/reconnect can close and replace the vault instance;
            // recreating this tiny value prevents a stale closed handle from
            // becoming a permanent false-negative for the replacement.
            let scheduler = OrganizationCopilotCandidateBudgetScheduler(vault: vault)
            return try await scheduler.hasAvailableBudget(for: scope, at: date)
        } catch {
            return false
        }
    }
}
