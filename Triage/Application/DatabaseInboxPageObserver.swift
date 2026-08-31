import Foundation

/// The page-first production observer for the Inbox list. It deliberately
/// shares the vault's GRDB observation with the complete workspace observer,
/// but never waits for that observer's full graph decode before emitting the
/// initial persisted-rank page.
actor DatabaseInboxPageObserver: InboxPageObserving {
    typealias VaultResolver = @Sendable (AccountID) async throws -> AccountVault

    private let resolveVault: VaultResolver
    private let pageSize: Int

    init(
        resolveVault: @escaping VaultResolver,
        pageSize: Int = 50
    ) {
        self.resolveVault = resolveVault
        self.pageSize = pageSize
    }

    init(
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore,
        pageSize: Int = 50
    ) {
        self.init(
            resolveVault: { accountID in
                guard let vaultKey = try await secretStore.readVaultKey(for: accountID) else {
                    throw AccountCredentialReaderError.missingAccessToken
                }
                return try await vaultRegistry.open(accountID: accountID, vaultKey: vaultKey)
            },
            pageSize: pageSize
        )
    }

    func snapshots(
        for scope: SynchronizationScope
    ) async throws -> AsyncThrowingStream<InboxPagePresentationSnapshot, Error> {
        let vault = try await resolveVault(scope.accountID)
        guard vault.accountID == scope.accountID else {
            throw DatabaseWorkspaceObserverError.resolvedVaultAccountMismatch
        }
        let observation = WorkspaceDatabaseObservationService(
            bridge: await vault.workspaceObservationBridge()
        )
        let rawValues = observation.inboxPageValues(for: scope)

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await rawSnapshot in rawValues {
                        try Task.checkCancellation()
                        guard rawSnapshot.scope == scope else {
                            throw DatabaseWorkspaceObserverError.observedScopeMismatch
                        }
                        let evaluatedAt = Date()
                        let page = try await WorkItemRepository(vault: vault).fetchInboxPage(
                            scope: scope,
                            at: evaluatedAt,
                            freshness: rawSnapshot.freshness,
                            limit: self.pageSize,
                            after: nil
                        )
                        try Task.checkCancellation()
                        guard try await Self.isCurrent(
                            rawSnapshot.revision,
                            in: vault,
                            scope: scope
                        ) else {
                            continue
                        }
                        let snapshot = InboxPagePresentationSnapshot(
                            scope: scope,
                            items: page.items,
                            nextCursor: page.nextCursor,
                            hasMore: page.hasMore,
                            evaluatedAt: evaluatedAt,
                            freshness: rawSnapshot.freshness,
                            revision: rawSnapshot.revision
                        )
                        if case .terminated = continuation.yield(snapshot) {
                            return
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func loadNextPage(
        for snapshot: InboxPagePresentationSnapshot
    ) async throws -> InboxPage {
        guard let cursor = snapshot.nextCursor else {
            return InboxPage(items: [], nextCursor: nil, hasMore: false)
        }
        let vault = try await resolveVault(snapshot.scope.accountID)
        guard vault.accountID == snapshot.scope.accountID else {
            throw DatabaseWorkspaceObserverError.resolvedVaultAccountMismatch
        }
        let page = try await WorkItemRepository(vault: vault).fetchInboxPage(
            scope: snapshot.scope,
            at: snapshot.evaluatedAt,
            freshness: snapshot.freshness,
            limit: pageSize,
            after: cursor
        )
        guard try await Self.isCurrent(snapshot.revision, in: vault, scope: snapshot.scope) else {
            throw CancellationError()
        }
        return page
    }

    private nonisolated static func isCurrent(
        _ revision: WorkspaceObservationRevision,
        in vault: AccountVault,
        scope: SynchronizationScope
    ) async throws -> Bool {
        try await vault.read { database in
            try WorkspaceDatabaseObservationService.revision(in: database, scope: scope) == revision
        }
    }
}
