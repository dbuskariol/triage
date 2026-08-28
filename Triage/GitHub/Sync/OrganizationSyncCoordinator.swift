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

    func state(accountID: AccountID, organizationID: OrganizationID) -> SyncExecutionState {
        states[Scope(accountID: accountID, organizationID: organizationID)] ?? .idle(lastSuccessfulAt: nil)
    }

    func start(
        accountID: AccountID,
        organizationID: OrganizationID,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        let key = Scope(accountID: accountID, organizationID: organizationID)
        activeTasks[key]?.cancel()
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

    func cancel(accountID: AccountID, organizationID: OrganizationID) {
        let key = Scope(accountID: accountID, organizationID: organizationID)
        activeTasks.removeValue(forKey: key)?.cancel()
    }

    private func complete(key: Scope, succeededAt: Date) {
        activeTasks[key] = nil
        states[key] = .idle(lastSuccessfulAt: succeededAt)
    }

    private func fail(key: Scope, lastSuccessfulAt: Date?, detail: String) {
        activeTasks[key] = nil
        states[key] = .failed(lastSuccessfulAt: lastSuccessfulAt, detail: detail)
    }

    private func lastSuccessfulAt(for key: Scope) -> Date? {
        if case let .idle(lastSuccessfulAt) = states[key] { return lastSuccessfulAt }
        if case let .failed(lastSuccessfulAt, _) = states[key] { return lastSuccessfulAt }
        return nil
    }

}
