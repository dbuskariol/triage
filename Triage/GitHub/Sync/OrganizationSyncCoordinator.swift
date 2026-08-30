import Foundation

enum SyncExecutionState: Equatable, Sendable {
    case idle(lastSuccessfulAt: Date?)
    case refreshing(startedAt: Date)
    case rateLimited(until: Date)
    case failed(lastSuccessfulAt: Date?, detail: String)
}

actor OrganizationSyncCoordinator {
    private struct Scope: Hashable, Sendable {
        let accountID: AccountID
        let organizationID: OrganizationID?
    }

    private var states: [Scope: SyncExecutionState] = [:]
    private var activeTasks: [Scope: Task<Void, Never>] = [:]
    private var successfulSyncs: [Scope: Date] = [:]
    private var generations: [Scope: UInt64] = [:]

    func state(accountID: AccountID, organizationID: OrganizationID) -> SyncExecutionState {
        let scope = Scope(accountID: accountID, organizationID: organizationID)
        return states[scope] ?? .idle(lastSuccessfulAt: successfulSyncs[scope])
    }

    func start(
        accountID: AccountID,
        organizationID: OrganizationID,
        priority: TaskPriority = .utility,
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        await start(
            scope: Scope(accountID: accountID, organizationID: organizationID),
            priority: priority,
            operation: operation
        )
    }

    func startAccount(
        accountID: AccountID,
        priority: TaskPriority = .utility,
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        await start(
            scope: Scope(accountID: accountID, organizationID: nil),
            priority: priority,
            operation: operation
        )
    }

    func cancel(accountID: AccountID, organizationID: OrganizationID) async {
        await cancel(scope: Scope(accountID: accountID, organizationID: organizationID))
    }

    func cancelAccount(accountID: AccountID) async {
        let keys = Set(activeTasks.keys.filter { $0.accountID == accountID })
            .union(generations.keys.filter { $0.accountID == accountID })
        for key in keys {
            await cancel(scope: key)
        }
    }

    private func start(
        scope key: Scope,
        priority: TaskPriority,
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        let generation = advanceGeneration(for: key)
        if let activeTask = activeTasks.removeValue(forKey: key) {
            activeTask.cancel()
            await activeTask.value
        }
        guard generations[key] == generation else { return }
        let startedAt = Date()
        states[key] = .refreshing(startedAt: startedAt)
        activeTasks[key] = Task(priority: priority) {
            do {
                try await operation()
                guard !Task.isCancelled else { return }
                self.complete(key: key, generation: generation, succeededAt: Date())
            } catch {
                guard !Task.isCancelled else { return }
                self.fail(
                    key: key,
                    generation: generation,
                    lastSuccessfulAt: self.lastSuccessfulAt(for: key),
                    detail: "Organization synchronization did not complete."
                )
            }
        }
    }

    private func cancel(scope key: Scope) async {
        let generation = advanceGeneration(for: key)
        if let activeTask = activeTasks.removeValue(forKey: key) {
            activeTask.cancel()
            await activeTask.value
        }
        guard generations[key] == generation else { return }
        states[key] = .idle(lastSuccessfulAt: lastSuccessfulAt(for: key))
    }

    private func complete(key: Scope, generation: UInt64, succeededAt: Date) {
        guard generations[key] == generation else { return }
        activeTasks[key] = nil
        successfulSyncs[key] = succeededAt
        states[key] = .idle(lastSuccessfulAt: succeededAt)
    }

    private func fail(key: Scope, generation: UInt64, lastSuccessfulAt: Date?, detail: String) {
        guard generations[key] == generation else { return }
        activeTasks[key] = nil
        states[key] = .failed(lastSuccessfulAt: successfulSyncs[key] ?? lastSuccessfulAt, detail: detail)
    }

    private func advanceGeneration(for key: Scope) -> UInt64 {
        let nextGeneration = (generations[key] ?? 0) &+ 1
        generations[key] = nextGeneration
        return nextGeneration
    }

    private func lastSuccessfulAt(for key: Scope) -> Date? {
        successfulSyncs[key]
    }

}
