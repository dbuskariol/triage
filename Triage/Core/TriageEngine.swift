import Foundation
import OSLog

/// Errors a `TriageDeciding` implementation throws when Copilot cannot be
/// used at all (as opposed to one batch failing). The engine pauses analysis
/// and surfaces the message instead of marking every item failed.
protocol TriageAvailabilityError: Error {
    /// `true` when Copilot cannot be used at all (consent, sign-in, runtime).
    var pausesAnalysis: Bool { get }
    var userMessage: String { get }
}

/// Runs the whole AI-first loop for one workspace:
/// search GitHub → save → Copilot decides changed items (most urgent first) → repeat.
actor TriageEngine {
    typealias DiscoveryFactory = @Sendable (WorkspaceScope) async throws -> any PersonalWorkDiscovering

    private static let logger = Logger(subsystem: "com.triage.mac", category: "Engine")

    private let store: any TriageStore
    private let makeDiscovery: DiscoveryFactory
    private let decider: any TriageDeciding
    private let refreshInterval: Duration
    private let maximumConcurrentBatches: Int
    private let maximumBatchBytes: Int
    private let retryDelay: TimeInterval
    private let now: @Sendable () -> Date

    private var scope: WorkspaceScope?
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var refreshRequested = false
    private var status = TriageStatus.initial
    private var observers: [UUID: AsyncStream<TriageStatus>.Continuation] = [:]

    init(
        store: any TriageStore,
        makeDiscovery: @escaping DiscoveryFactory,
        decider: any TriageDeciding,
        refreshInterval: Duration = .seconds(300),
        // The Copilot helper serves one request at a time; extra concurrency only queues.
        maximumConcurrentBatches: Int = 1,
        maximumBatchBytes: Int = 90_000,
        retryDelay: TimeInterval = 120,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.makeDiscovery = makeDiscovery
        self.decider = decider
        self.refreshInterval = refreshInterval
        self.maximumConcurrentBatches = max(1, maximumConcurrentBatches)
        self.maximumBatchBytes = maximumBatchBytes
        self.retryDelay = retryDelay
        self.now = now
    }

    // MARK: Lifecycle

    /// Starts (or switches to) `scope`. Any previous workspace loop is cancelled.
    func start(_ scope: WorkspaceScope) async {
        guard scope != self.scope || loop == nil else { return }
        await stop()
        self.scope = scope
        status = TriageStatus(lastRefreshAt: try? await store.lastRefreshAt(scope: scope))
        publish()
        Self.logger.notice("engine started")
        loop = Task { [weak self] in await self?.run(scope) }
    }

    func stop() async {
        let running = loop
        loop = nil
        running?.cancel()
        sleeper?.cancel()
        await running?.value
        scope = nil
        status = .initial
        publish()
    }

    /// Runs a refresh immediately (or as soon as the current cycle finishes).
    func refreshNow() {
        guard loop != nil else { return }
        refreshRequested = true
        sleeper?.cancel()
    }

    func statusUpdates() -> AsyncStream<TriageStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TriageStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    // MARK: Loop

    private func run(_ scope: WorkspaceScope) async {
        while !Task.isCancelled {
            refreshRequested = false
            await refresh(scope)
            await analyze(scope)
            guard !Task.isCancelled else { return }
            status.phase = .idle
            status.nextRefreshAt = now().addingTimeInterval(refreshInterval.timeInterval)
            publish()
            // Sleep until the interval elapses or `refreshNow()` cancels the sleep.
            guard !refreshRequested else { continue }
            let interval = refreshInterval
            let sleep = Task { _ = try? await Task.sleep(for: interval) }
            sleeper = sleep
            await sleep.value
            sleeper = nil
        }
    }

    private func refresh(_ scope: WorkspaceScope) async {
        let started = ContinuousClock.now
        Self.logger.notice("refresh started")
        if case .gitHubUnavailable = status.problem { status.problem = nil }
        status.phase = .searching(found: 0)
        publish()
        do {
            let discovery = try await makeDiscovery(scope)
            let items = try await discovery.discover(scope: scope) { [weak self] progress in
                await self?.updateSearchProgress(progress.found)
            }
            try Task.checkCancellation()
            try await store.replaceItems(items, scope: scope, at: now())
            status.lastRefreshAt = now()
            if case .gitHubUnavailable = status.problem { status.problem = nil }
            Self.logger.notice("refresh outcome=success items=\(items.count, privacy: .public) duration=\(String(describing: started.duration(to: .now)), privacy: .public)")
        } catch is CancellationError {
            return
        } catch {
            status.problem = .gitHubUnavailable(Self.message(for: error))
            Self.logger.error("refresh outcome=failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
        }
        publish()
    }

    private func updateSearchProgress(_ found: Int) {
        guard case .searching = status.phase else { return }
        status.phase = .searching(found: found)
        publish()
    }

    private func analyze(_ scope: WorkspaceScope) async {
        let pending: [PersonalWorkItem]
        let rules: TriageRules
        do {
            rules = try await store.rules(scope: scope)
            // Muted work is never sent to Copilot.
            pending = try await store.itemsNeedingAnalysis(
                scope: scope, rulesDigest: rules.digest, at: now(), limit: 1_000
            ).filter { !rules.isMuted($0) }
        } catch {
            Self.logger.error("analysis-selection outcome=failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            return
        }
        guard !pending.isEmpty, !Task.isCancelled else {
            Self.logger.notice("analysis skipped pending=0")
            return
        }
        let batches = batches(of: pending)
        Self.logger.notice("analysis started items=\(pending.count, privacy: .public) batches=\(batches.count, privacy: .public)")
        var completed = 0
        var failedItems = 0
        status.phase = .analyzing(completed: 0, total: pending.count)
        publish()

        var next = batches.makeIterator()
        await withTaskGroup(of: BatchOutcome.self) { group in
            func submit() -> Bool {
                guard let batch = next.next() else { return false }
                group.addTask { [decider] in await Self.run(batch, decider: decider, scope: scope, rules: rules) }
                return true
            }
            for _ in 0..<maximumConcurrentBatches {
                guard submit() else { break }
            }
            while let outcome = await group.next() {
                switch outcome {
                case .decided(let batch, let decisions, let duration):
                    do {
                        try await store.saveDecisions(decisions, scope: scope)
                        completed += decisions.count
                        let decidedIDs = Set(decisions.map(\.itemID))
                        let missing = batch.filter { !decidedIDs.contains($0.id) }
                        if !missing.isEmpty {
                            failedItems += missing.count
                            try await store.recordAnalysisFailure(
                                itemIDs: missing.map(\.id), reason: "Copilot skipped this item; it will be retried.",
                                retryAt: now().addingTimeInterval(retryDelay), scope: scope
                            )
                        }
                        if case .copilotUnavailable = status.problem { status.problem = nil }
                    } catch {
                        Self.logger.error("decision-save outcome=failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
                    }
                    Self.logger.notice("batch outcome=decided items=\(decisions.count, privacy: .public) duration=\(String(describing: duration), privacy: .public)")
                case .unavailable(let message):
                    // Copilot itself is unusable: stop submitting, keep items pending.
                    status.problem = .copilotUnavailable(message)
                    group.cancelAll()
                    publish()
                    Self.logger.error("batch outcome=copilot-unavailable")
                    continue
                case .failed(let items, let message):
                    failedItems += items.count
                    try? await store.recordAnalysisFailure(
                        itemIDs: items.map(\.id), reason: message,
                        retryAt: now().addingTimeInterval(retryDelay), scope: scope
                    )
                    Self.logger.error("batch outcome=failed items=\(items.count, privacy: .public) reason=\(message, privacy: .public)")
                case .cancelled:
                    continue
                }
                status.phase = .analyzing(completed: completed, total: pending.count)
                publish()
                if case .copilotUnavailable = status.problem {} else { _ = submit() }
            }
        }
        if failedItems > 0, status.problem == nil {
            status.problem = .analysisFailed("\(failedItems) item\(failedItems == 1 ? "" : "s") will be retried in \(Int(retryDelay / 60)) minutes · see Analyzing")
        } else if failedItems == 0, case .analysisFailed = status.problem {
            status.problem = nil
        }
        publish()
    }

    private enum BatchOutcome: Sendable {
        case decided([PersonalWorkItem], [TriageDecision], Duration)
        case failed([PersonalWorkItem], String)
        case unavailable(String)
        case cancelled
    }

    private static func run(
        _ batch: [PersonalWorkItem], decider: any TriageDeciding, scope: WorkspaceScope, rules: TriageRules
    ) async -> BatchOutcome {
        let started = ContinuousClock.now
        do {
            let decisions = try await decider.decide(batch, scope: scope, rules: rules)
            return .decided(batch, decisions, started.duration(to: .now))
        } catch is CancellationError {
            return .cancelled
        } catch let error as any TriageAvailabilityError where error.pausesAnalysis {
            return .unavailable(error.userMessage)
        } catch {
            return .failed(batch, message(for: error))
        }
    }

    /// Splits items (already most-urgent first) into batches bounded by count
    /// and by encoded size, so one oversized item never blocks the rest.
    private func batches(of items: [PersonalWorkItem]) -> [[PersonalWorkItem]] {
        let encoder = JSONEncoder()
        var result: [[PersonalWorkItem]] = []
        var current: [PersonalWorkItem] = []
        var bytes = 0
        for item in items {
            let size = (try? encoder.encode(item).count) ?? maximumBatchBytes
            if !current.isEmpty, current.count >= decider.maximumBatchSize || bytes + size > maximumBatchBytes {
                result.append(current)
                current = []
                bytes = 0
            }
            current.append(item)
            bytes += size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: Status

    private func publish() {
        for continuation in observers.values { continuation.yield(status) }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        if error is URLError { return "GitHub couldn't be reached. Showing saved work." }
        if let error = error as? GitHubGraphQLError {
            switch error {
            case .requestFailed(let failure):
                switch failure.kind {
                case .unauthorized: return "GitHub sign-in expired. Reconnect the account in Settings."
                case .forbidden: return "GitHub denied access to this organization. Check SSO authorization in Settings."
                case .rateLimited, .secondaryRateLimited: return "GitHub rate limit reached. Triage will resume automatically."
                case .serverFailure: return "GitHub is having problems. Showing saved work; Triage will try again."
                case .notFound, .unexpectedResponse: break
                }
            case .invalidResponse, .partialResponse, .missingData:
                return "GitHub returned an incomplete response. Showing saved work; Triage will try again."
            default: break
            }
        }
        return "Something went wrong. Triage will try again automatically."
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
