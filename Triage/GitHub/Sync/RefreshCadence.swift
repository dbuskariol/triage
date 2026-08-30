import Foundation

struct RefreshCadence: Sendable {
    let baseInterval: TimeInterval
    let maximumJitter: TimeInterval

    init(
        baseInterval: TimeInterval = 4 * 60,
        maximumJitter: TimeInterval = 60
    ) {
        precondition(baseInterval > 0, "A refresh interval must be positive.")
        precondition(maximumJitter >= 0, "Refresh jitter cannot be negative.")
        self.baseInterval = baseInterval
        self.maximumJitter = maximumJitter
    }

    static let inactiveAccount = RefreshCadence(
        baseInterval: 20 * 60,
        maximumJitter: 5 * 60
    )

    static let dailyCapabilityProbe = RefreshCadence(
        baseInterval: 24 * 60 * 60,
        maximumJitter: 60 * 60
    )

    static let dailyFullReconciliation = RefreshCadence(
        baseInterval: 24 * 60 * 60,
        maximumJitter: 60 * 60
    )

    func nextInterval(randomUnit: Double) -> TimeInterval {
        let boundedRandomUnit = min(max(randomUnit, 0), 1)
        return baseInterval + (boundedRandomUnit * maximumJitter)
    }
}

actor ActiveRefreshScheduler {
    private var task: Task<Void, Never>?

    func start(
        cadence: RefreshCadence = .init(),
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        operation: @escaping @Sendable () async -> Void
    ) {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                let nanoseconds = UInt64(cadence.nextInterval(randomUnit: randomUnit()) * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await operation()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
