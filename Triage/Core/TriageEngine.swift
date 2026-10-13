import Foundation
import OSLog

/// Errors a `TriageDeciding` implementation throws when Copilot cannot be
/// used at all (as opposed to one batch failing). The engine pauses analysis
/// and surfaces the message instead of marking every item failed.
protocol TriageAvailabilityError: Error {
    /// `true` when Copilot cannot be used at all (consent, sign-in, runtime).
    var pausesAnalysis: Bool { get }
    /// `true` when only reopening Triage can fix it.
    var requiresRelaunch: Bool { get }
    var userMessage: String { get }
}

extension TriageAvailabilityError {
    var requiresRelaunch: Bool { false }

    /// How the problem is shown.
    var problem: TriageStatus.Problem {
        requiresRelaunch ? .relaunchRequired(userMessage) : .copilotUnavailable(userMessage)
    }
}

/// Runs the whole AI-first loop for one workspace:
/// search GitHub → save → Copilot decides changed items (most urgent first) → repeat.
actor TriageEngine {
    typealias DiscoveryFactory = @Sendable (WorkspaceScope) async throws -> any PersonalWorkDiscovering

    private static let logger = Logger(subsystem: "com.triage.mac", category: "Engine")

    private let store: any TriageStore
    private let makeDiscovery: DiscoveryFactory
    private let decider: any TriageDeciding
    /// `nil` means refresh only when asked (manual mode).
    private var refreshInterval: Duration?
    private let maximumConcurrentBatches: Int
    private let maximumBatchBytes: Int
    private let retryDelay: TimeInterval
    private let autoMarkHandled: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    private var scope: WorkspaceScope?
    private var loop: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var idleWaiter: CheckedContinuation<Void, Never>?
    private var cycleFinishedAt = ContinuousClock.now
    private var refreshRequested = false
    /// Set when only due retries need analysis; skips the GitHub search.
    private var analysisOnlyRequested = false
    /// When items whose analysis failed are next due.
    private var retryDeadline: ContinuousClock.Instant?
    private var status = TriageStatus.initial
    private var observers: [UUID: AsyncStream<TriageStatus>.Continuation] = [:]

    init(
        store: any TriageStore,
        makeDiscovery: @escaping DiscoveryFactory,
        decider: any TriageDeciding,
        refreshInterval: Duration? = .seconds(300),
        // The Copilot helper serves one request at a time; extra concurrency only queues.
        maximumConcurrentBatches: Int = 1,
        maximumBatchBytes: Int = 90_000,
        retryDelay: TimeInterval = 120,
        autoMarkHandled: @escaping @Sendable () -> Bool = { true },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.autoMarkHandled = autoMarkHandled
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
        timer?.cancel()
        timer = nil
        wake()
        await running?.value
        scope = nil
        status = .initial
        publish()
    }

    /// Runs a refresh immediately (or as soon as the current cycle finishes).
    func refreshNow() {
        guard loop != nil else { return }
        refreshRequested = true
        wake()
    }

    /// Changes the automatic refresh interval (`nil` = manual only). Takes
    /// effect immediately, measured from the end of the last cycle.
    func setRefreshInterval(_ interval: Duration?) {
        guard interval != refreshInterval else { return }
        refreshInterval = interval
        Self.logger.notice("refresh interval seconds=\(interval.map { Int($0.components.seconds) } ?? 0, privacy: .public)")
        if idleWaiter != nil { scheduleTimer() }
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
            let analysisOnly = analysisOnlyRequested && !refreshRequested
            refreshRequested = false
            analysisOnlyRequested = false
            retryDeadline = nil
            if analysisOnly {
                Self.logger.notice("retry pass started")
            } else {
                await refresh(scope)
            }
            await analyze(scope)
            guard !Task.isCancelled else { return }
            status.phase = .idle
            cycleFinishedAt = .now
            scheduleTimer()
            // Wait for the timer, `refreshNow()`, or `stop()`.
            // Actor isolation: no suspension between this check and the wait,
            // so `stop()` / `refreshNow()` cannot slip in and be missed.
            guard !refreshRequested, !analysisOnlyRequested, !Task.isCancelled else { continue }
            await withCheckedContinuation { idleWaiter = $0 }
            timer?.cancel()
            timer = nil
        }
    }

    /// Wakes for the next refresh or, if sooner, the next due retry (which
    /// re-analyzes without searching GitHub again).
    private func scheduleTimer() {
        timer?.cancel()
        timer = nil
        // A rejected token fails every time; wait for the user to refresh or replace it.
        let refreshDeadline = status.problem?.isCredentialRejected == true
            ? nil
            : refreshInterval.map { cycleFinishedAt.advanced(by: $0) }
        status.nextRefreshAt = refreshDeadline.map {
            now().addingTimeInterval(ContinuousClock.now.duration(to: $0).timeInterval)
        }
        publish()
        let retryFirst = retryDeadline.map { retry in refreshDeadline.map { retry < $0 } ?? true } ?? false
        guard let deadline = retryFirst ? retryDeadline : refreshDeadline else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.timerFired(analysisOnly: retryFirst)
        }
    }

    private func timerFired(analysisOnly: Bool) {
        if analysisOnly { analysisOnlyRequested = true } else { refreshRequested = true }
        wake()
    }

    private func wake() {
        idleWaiter?.resume()
        idleWaiter = nil
    }

    private func refresh(_ scope: WorkspaceScope) async {
        let started = ContinuousClock.now
        Self.logger.notice("refresh started")
        if status.problem?.isGitHubProblem == true { status.problem = nil }
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
            if status.problem?.isGitHubProblem == true { status.problem = nil }
            Self.logger.notice("refresh outcome=success items=\(items.count, privacy: .public) duration=\(String(describing: started.duration(to: .now)), privacy: .public)")
        } catch is CancellationError {
            return
        } catch PersonalWorkDiscoveryError.singleSignOnRequired(let organization, let url) {
            status.problem = .gitHubSingleSignOnRequired(organization: organization, authorizationURL: url)
            Self.logger.error("refresh outcome=failed reason=singleSignOnRequired")
        } catch GitHubGraphQLError.requestFailed(let failure) where failure.kind == .unauthorized {
            status.problem = .gitHubCredentialRejected
            Self.logger.error("refresh outcome=failed reason=credentialRejected")
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
        let contexts: [GitHubNodeID: TriageHandledContext]
        do {
            rules = try await store.rules(scope: scope)
            // Muted work is never sent to Copilot.
            let candidates = try await store.itemsNeedingAnalysis(
                scope: scope, rulesDigest: rules.digest, at: now(), limit: 1_000
            ).filter { !rules.isMuted($0, viewer: scope.viewerLogin) }
            contexts = try await handledContexts(for: candidates, scope: scope)
            // Work you just acted on goes first, so it leaves the Inbox quickly.
            pending = candidates.filter { contexts[$0.id] != nil } + candidates.filter { contexts[$0.id] == nil }
        } catch {
            Self.logger.error("analysis-selection outcome=failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            return
        }
        guard !pending.isEmpty, !Task.isCancelled else {
            Self.logger.notice("analysis skipped pending=0")
            return
        }
        Self.logger.notice("analysis started items=\(pending.count, privacy: .public) withYourActivity=\(contexts.count, privacy: .public)")
        var completed = 0
        var failedItems = 0
        var handledCount = 0
        var skippedOnce = Set<GitHubNodeID>()
        var rounds = batches(of: pending)
        status.phase = .analyzing(completed: 0, total: pending.count)
        publish()

        // Later rounds retry, right away, items Copilot skipped and the halves of
        // any batch that failed, so one bad item never holds back the others.
        while !rounds.isEmpty, !Task.isCancelled {
            var next = rounds.makeIterator()
            rounds = []
            var skipped: [PersonalWorkItem] = []
            await withTaskGroup(of: BatchOutcome.self) { group in
                func submit() -> Bool {
                    guard let batch = next.next() else { return false }
                    let batchContexts = contexts.filter { id, _ in batch.contains { $0.id == id } }
                    group.addTask { [decider] in
                        await Self.run(batch, decider: decider, scope: scope, rules: rules, contexts: batchContexts)
                    }
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
                            handledCount += try await markHandled(decisions, batch: batch, contexts: contexts, scope: scope)
                            let decidedIDs = Set(decisions.map(\.itemID))
                            for item in batch where !decidedIDs.contains(item.id) {
                                if skippedOnce.insert(item.id).inserted {
                                    skipped.append(item)
                                } else {
                                    // Skipped twice: benign, retried on a later cycle without alarming the user.
                                    try await store.recordAnalysisFailure(
                                        itemIDs: [item.id], reason: "Copilot skipped this item; it will be retried.",
                                        retryAt: now().addingTimeInterval(retryDelay), scope: scope
                                    )
                                    scheduleRetry()
                                }
                            }
                            if status.problem?.blocksAnalysis == true { status.problem = nil }
                        } catch {
                            Self.logger.error("decision-save outcome=failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
                        }
                        Self.logger.notice("batch outcome=decided items=\(decisions.count, privacy: .public) duration=\(String(describing: duration), privacy: .public)")
                    case .unavailable(let problem):
                        // Copilot itself is unusable: stop submitting, keep items
                        // pending, and check again shortly rather than waiting
                        // for the next refresh.
                        status.problem = problem
                        scheduleRetry()
                        group.cancelAll()
                        rounds = []
                        skipped = []
                        publish()
                        Self.logger.error("batch outcome=copilot-unavailable")
                        continue
                    case .failed(let items, let message) where items.count > 1:
                        // Bisect: retry each half now to isolate whatever Copilot couldn't handle.
                        let middle = items.count / 2
                        rounds.append(Array(items[..<middle]))
                        rounds.append(Array(items[middle...]))
                        Self.logger.error("batch outcome=failed items=\(items.count, privacy: .public) action=split reason=\(message, privacy: .public)")
                    case .failed(let items, let message):
                        failedItems += items.count
                        try? await store.recordAnalysisFailure(
                            itemIDs: items.map(\.id), reason: message,
                            retryAt: now().addingTimeInterval(retryDelay), scope: scope
                        )
                        scheduleRetry()
                        Self.logger.error("batch outcome=failed items=\(items.count, privacy: .public) reason=\(message, privacy: .public)")
                    case .cancelled:
                        continue
                    }
                    status.phase = .analyzing(completed: min(completed, pending.count), total: pending.count)
                    publish()
                    if status.problem?.blocksAnalysis != true { _ = submit() }
                }
            }
            if !skipped.isEmpty { rounds += batches(of: skipped) }
        }
        status.recentlyHandled = handledCount
        if handledCount > 0 { Self.logger.notice("handled-by-viewer items=\(handledCount, privacy: .public)") }
        if failedItems > 0, status.problem == nil {
            status.problem = .analysisFailed("\(failedItems) item\(failedItems == 1 ? "" : "s") couldn’t be analyzed and will retry in \(Int(retryDelay / 60)) minutes")
        } else if failedItems == 0, case .analysisFailed = status.problem {
            status.problem = nil
        }
        publish()
    }

    private func scheduleRetry() {
        let due = ContinuousClock.now.advanced(by: .seconds(retryDelay))
        if retryDeadline.map({ due < $0 }) ?? true { retryDeadline = due }
    }

    /// For Inbox items with a next step and your activity since that decision,
    /// the context Copilot needs to judge whether you handled it.
    private func handledContexts(
        for items: [PersonalWorkItem], scope: WorkspaceScope
    ) async throws -> [GitHubNodeID: TriageHandledContext] {
        let previous = try await store.decisions(for: items.map(\.id), scope: scope)
        var contexts: [GitHubNodeID: TriageHandledContext] = [:]
        for item in items {
            guard let decision = previous[item.id], decision.disposition.isInbox,
                  let nextAction = decision.nextAction
            else { continue }
            let activity = item.viewerActivity(since: decision.decidedAt, viewer: scope.viewerLogin)
            guard !activity.isEmpty else { continue }
            contexts[item.id] = TriageHandledContext(previousNextAction: nextAction, viewerActivity: activity)
        }
        return contexts
    }

    /// Marks work done when Copilot confirms you handled its previous next step.
    private func markHandled(
        _ decisions: [TriageDecision], batch: [PersonalWorkItem],
        contexts: [GitHubNodeID: TriageHandledContext], scope: WorkspaceScope
    ) async throws -> Int {
        guard autoMarkHandled() else { return 0 }
        var count = 0
        for decision in decisions where decision.handled == .yes && contexts[decision.itemID] != nil {
            guard let item = batch.first(where: { $0.id == decision.itemID }) else { continue }
            let evidence = decision.handledEvidence ?? "You completed the suggested next step."
            if try await store.markHandled(item, viewer: scope.viewerLogin, evidence: evidence, at: now(), scope: scope) {
                count += 1
            }
        }
        return count
    }

    private enum BatchOutcome: Sendable {
        case decided([PersonalWorkItem], [TriageDecision], Duration)
        case failed([PersonalWorkItem], String)
        case unavailable(TriageStatus.Problem)
        case cancelled
    }

    private static func run(
        _ batch: [PersonalWorkItem], decider: any TriageDeciding, scope: WorkspaceScope, rules: TriageRules,
        contexts: [GitHubNodeID: TriageHandledContext]
    ) async -> BatchOutcome {
        let started = ContinuousClock.now
        do {
            let decisions = try await decider.decide(batch, scope: scope, rules: rules, contexts: contexts)
            return .decided(batch, decisions, started.duration(to: .now))
        } catch is CancellationError {
            return .cancelled
        } catch let error as any TriageAvailabilityError where error.pausesAnalysis {
            return .unavailable(error.problem)
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
                case .unauthorized: return "GitHub no longer accepts this account's token. Replace it in Settings ▸ Accounts."
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
