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
        let organizationID: OrganizationID
    }

    private var states: [Scope: SyncExecutionState] = [:]
    private var activeTasks: [Scope: Task<Void, Never>] = [:]
    private var successfulSyncs: [Scope: Date] = [:]

    func state(accountID: AccountID, organizationID: OrganizationID) -> SyncExecutionState {
        let scope = Scope(accountID: accountID, organizationID: organizationID)
        return states[scope] ?? .idle(lastSuccessfulAt: successfulSyncs[scope])
    }

    func start(
        accountID: AccountID,
        organizationID: OrganizationID,
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        let key = Scope(accountID: accountID, organizationID: organizationID)
        if let activeTask = activeTasks.removeValue(forKey: key) {
            activeTask.cancel()
            await activeTask.value
        }
        let startedAt = Date()
        states[key] = .refreshing(startedAt: startedAt)
        activeTasks[key] = Task {
            do {
                try await operation()
                guard !Task.isCancelled else { return }
                self.complete(key: key, succeededAt: Date())
            } catch {
                guard !Task.isCancelled else { return }
                self.fail(
                    key: key,
                    lastSuccessfulAt: self.lastSuccessfulAt(for: key),
                    detail: String(describing: type(of: error))
                )
            }
        }
    }

    func cancel(accountID: AccountID, organizationID: OrganizationID) async {
        let key = Scope(accountID: accountID, organizationID: organizationID)
        guard let activeTask = activeTasks.removeValue(forKey: key) else { return }
        activeTask.cancel()
        await activeTask.value
        states[key] = .idle(lastSuccessfulAt: lastSuccessfulAt(for: key))
    }

    private func complete(key: Scope, succeededAt: Date) {
        activeTasks[key] = nil
        successfulSyncs[key] = succeededAt
        states[key] = .idle(lastSuccessfulAt: succeededAt)
    }

    private func fail(key: Scope, lastSuccessfulAt: Date?, detail: String) {
        activeTasks[key] = nil
        states[key] = .failed(lastSuccessfulAt: successfulSyncs[key] ?? lastSuccessfulAt, detail: detail)
    }

    private func lastSuccessfulAt(for key: Scope) -> Date? {
        successfulSyncs[key]
    }

}
