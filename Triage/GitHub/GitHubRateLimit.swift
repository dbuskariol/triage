import Foundation

enum GitHubRateLimitResource: String, CaseIterable, Sendable {
    case core
    case search
    case graphql
}

enum GitHubRequestPriority: Int, CaseIterable, Comparable, Sendable {
    case selectedWorkItemDetail
    case selectedOrganizationRefresh
    case inboxCandidateHydration
    case incrementalDiscovery
    case contextEnrichment
    case inactiveAccountRefresh
    case fullReconciliation

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct GitHubRateLimit: Equatable, Sendable {
    let resource: GitHubRateLimitResource
    let limit: Int?
    let remaining: Int?
    let resetAt: Date?
    let retryAfter: TimeInterval?
    let observedAt: Date

    init(
        resource: GitHubRateLimitResource,
        limit: Int?,
        remaining: Int?,
        resetAt: Date?,
        retryAfter: TimeInterval?,
        observedAt: Date
    ) {
        self.resource = resource
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
        self.retryAfter = retryAfter
        self.observedAt = observedAt
    }

    init?(headers: [String: String], now: Date = .now) {
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        guard let resource = header("X-RateLimit-Resource").flatMap(GitHubRateLimitResource.init(rawValue:)) else {
            return nil
        }
        self.resource = resource
        limit = header("X-RateLimit-Limit").flatMap(Int.init)
        remaining = header("X-RateLimit-Remaining").flatMap(Int.init)
        resetAt = header("X-RateLimit-Reset")
            .flatMap(TimeInterval.init)
            .map { Date(timeIntervalSince1970: $0) }
        retryAfter = header("Retry-After").flatMap(TimeInterval.init)
        if retryAfter == nil, remaining == 0, resetAt == nil {
            return nil
        }
        observedAt = now
    }

    var pauseUntil: Date? {
        if let retryAfter {
            return observedAt.addingTimeInterval(retryAfter)
        }
        guard remaining == 0 else { return nil }
        return resetAt
    }
}

protocol GitHubRateLimitPersisting: Sendable {
    func rateLimits(for accountID: AccountID) async throws -> [GitHubRateLimit]
    func save(_ rateLimit: GitHubRateLimit, for accountID: AccountID) async throws
    func secondaryPause(for accountID: AccountID) async throws -> Date?
    func saveSecondaryPause(until: Date, for accountID: AccountID) async throws
}

actor GitHubRateLimitController {
    private struct Waiter: Sendable {
        let id: UUID
        let priority: GitHubRequestPriority
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, Error>
        var bypassCount = 0
    }

    private let accountID: AccountID?
    private let persistence: (any GitHubRateLimitPersisting)?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let jitter: @Sendable (TimeInterval) -> TimeInterval
    private let maximumConcurrency: Int
    private var limits: [GitHubRateLimitResource: GitHubRateLimit] = [:]
    private var retryPauses: [GitHubRateLimitResource: Date] = [:]
    private var secondaryPauseUntil: Date?
    private var consecutiveSecondaryLimitCount = 0
    private var adaptiveConcurrency: Int
    private var activeRequests = 0
    private var waiters: [Waiter] = []
    private var nextSequence: UInt64 = 0
    private let maximumPriorityBypasses = 8

    init(
        accountID: AccountID? = nil,
        persistence: (any GitHubRateLimitPersisting)? = nil,
        maximumConcurrency: Int = 2,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { duration in
            duration * Double.random(in: 1...1.1)
        }
    ) {
        precondition(maximumConcurrency > 0)
        precondition((accountID == nil) == (persistence == nil))
        self.accountID = accountID
        self.persistence = persistence
        self.maximumConcurrency = maximumConcurrency
        self.now = now
        self.sleep = sleep
        self.jitter = jitter
        adaptiveConcurrency = maximumConcurrency
    }

    func restore() async throws {
        guard let accountID, let persistence else { return }
        for limit in try await persistence.rateLimits(for: accountID) {
            limits[limit.resource] = limit
            if let retryAfter = limit.retryAfter {
                retryPauses[limit.resource] = limit.observedAt.addingTimeInterval(retryAfter)
            }
        }
        if let secondaryPause = try await persistence.secondaryPause(for: accountID),
           secondaryPause > now() {
            secondaryPauseUntil = secondaryPause
            adaptiveConcurrency = 1
        }
    }

    func record(
        response: GitHubRESTResponse,
        fallbackResource: GitHubRateLimitResource? = nil
    ) async throws {
        let observedAt = now()
        guard let limit = GitHubRateLimit(headers: response.headers, now: observedAt) else {
            if let fallbackResource,
               let retryAfter = response.header(named: "Retry-After").flatMap(TimeInterval.init),
               retryAfter > 0 {
                let fallbackLimit = GitHubRateLimit(
                    resource: fallbackResource,
                    limit: nil,
                    remaining: nil,
                    resetAt: nil,
                    retryAfter: retryAfter,
                    observedAt: observedAt
                )
                limits[fallbackResource] = fallbackLimit
                retryPauses[fallbackResource] = observedAt.addingTimeInterval(jitter(retryAfter))
                if let accountID, let persistence {
                    try await persistence.save(fallbackLimit, for: accountID)
                }
            }
            try await recordSecondaryLimitIfNeeded(response, observedAt: observedAt)
            return
        }
        limits[limit.resource] = limit
        if let retryAfter = limit.retryAfter, retryAfter > 0 {
            retryPauses[limit.resource] = observedAt.addingTimeInterval(jitter(retryAfter))
        }
        if let accountID, let persistence {
            try await persistence.save(limit, for: accountID)
        }
        try await recordSecondaryLimitIfNeeded(response, observedAt: observedAt)
    }

    func pauseUntil(for resource: GitHubRateLimitResource) -> Date? {
        let now = now()
        let resourcePause = limits[resource]?.pauseUntil
        let retryPause = retryPauses[resource]
        let pauses = [resourcePause, retryPause, secondaryPauseUntil]
            .compactMap { $0 }
            .filter { $0 > now }
        guard let pauseUntil = pauses.max() else { return nil }
        return pauseUntil
    }

    func queuedRequestCount() -> Int {
        waiters.count
    }

    func execute<Value: Sendable>(
        resource: GitHubRateLimitResource,
        priority: GitHubRequestPriority,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire(resource: resource, priority: priority)
        defer { releaseOne() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(
        resource: GitHubRateLimitResource,
        priority: GitHubRequestPriority
    ) async throws {
        while true {
            if let pauseUntil = pauseUntil(for: resource) {
                try Task.checkCancellation()
                try await sleep(pauseUntil.timeIntervalSince(now()))
                continue
            }

            try await acquirePermit(priority: priority)
            if pauseUntil(for: resource) == nil {
                return
            }
            releaseOne()
        }
    }

    private func acquirePermit(priority: GitHubRequestPriority) async throws {
        try Task.checkCancellation()
        if activeRequests < adaptiveConcurrency, waiters.isEmpty {
            activeRequests += 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                nextSequence &+= 1
                waiters.append(
                    Waiter(
                        id: id,
                        priority: priority,
                        sequence: nextSequence,
                        continuation: continuation
                    )
                )
            }

        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func releaseOne() {
        guard !waiters.isEmpty else {
            activeRequests -= 1
            return
        }
        guard activeRequests <= adaptiveConcurrency else {
            activeRequests -= 1
            return
        }
        let nextIndex = nextWaiterIndex()
        for index in waiters.indices where index != nextIndex {
            waiters[index].bypassCount += 1
        }
        let next = waiters.remove(at: nextIndex)
        next.continuation.resume()
    }

    private func nextWaiterIndex() -> Int {
        if let starvedIndex = waiters.indices
            .filter({ waiters[$0].bypassCount >= maximumPriorityBypasses })
            .min(by: { waiters[$0].sequence < waiters[$1].sequence }) {
            return starvedIndex
        }
        return waiters.indices.min {
            let lhs = waiters[$0]
            let rhs = waiters[$1]
            return lhs.priority == rhs.priority
                ? lhs.sequence < rhs.sequence
                : lhs.priority < rhs.priority
        }!
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func recordSecondaryLimitIfNeeded(
        _ response: GitHubRESTResponse,
        observedAt: Date
    ) async throws {
        guard GitHubFailureClassifier.isSecondaryRateLimited(response) else {
            consecutiveSecondaryLimitCount = 0
            return
        }
        consecutiveSecondaryLimitCount += 1
        let retryAfter = response.header(named: "Retry-After").flatMap(TimeInterval.init)
        let minimumDelay = retryAfter.map { max($0, 60) } ?? 60
        let remainingPause = (secondaryPauseUntil ?? observedAt).timeIntervalSince(observedAt)
        let delay = min(900, max(minimumDelay, remainingPause * 2))
        let candidate = observedAt.addingTimeInterval(jitter(delay))
        secondaryPauseUntil = max(secondaryPauseUntil ?? .distantPast, candidate)
        adaptiveConcurrency = 1
        if let accountID, let persistence, let secondaryPauseUntil {
            try await persistence.saveSecondaryPause(until: secondaryPauseUntil, for: accountID)
        }
    }
}

actor GitHubRateLimitControllerRegistry {
    static let shared = GitHubRateLimitControllerRegistry()

    private var controllers: [AccountID: GitHubRateLimitController] = [:]

    func controller(
        for accountID: AccountID,
        vault: AccountVault
    ) async throws -> GitHubRateLimitController {
        if let controller = controllers[accountID] {
            return controller
        }
        let controller = GitHubRateLimitController(
            accountID: accountID,
            persistence: RateLimitRepository(vault: vault)
        )
        try await controller.restore()
        controllers[accountID] = controller
        return controller
    }

    func removeController(for accountID: AccountID) {
        controllers[accountID] = nil
    }
}
