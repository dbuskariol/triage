import Foundation

enum DatabaseWorkspaceObserverError: Error, Equatable, Sendable {
    case resolvedVaultAccountMismatch
    case observedScopeMismatch
    case inconsistentMenuCounts
}

/// The production bridge from a vault-owned GRDB observation to the complete
/// value projection consumed by application presentation. The resolver is
/// injected so this type never reads credentials, opens a network client, or
/// exposes a vault handle to a view.
actor DatabaseWorkspaceObserver: WorkspaceObserving {
    typealias VaultResolver = @Sendable (AccountID) async throws -> AccountVault

    private let resolveVault: VaultResolver

    init(resolveVault: @escaping VaultResolver) {
        self.resolveVault = resolveVault
    }

    /// Standard production construction. The vault key remains inside the
    /// Keychain/vault boundary and is never captured by an observation value.
    init(vaultRegistry: VaultRegistry, secretStore: KeychainSecretStore) {
        resolveVault = { accountID in
            guard let vaultKey = try await secretStore.readVaultKey(for: accountID) else {
                throw AccountCredentialReaderError.missingAccessToken
            }
            return try await vaultRegistry.open(accountID: accountID, vaultKey: vaultKey)
        }
    }

    func snapshots(
        for scope: SynchronizationScope
    ) async throws -> AsyncThrowingStream<WorkspacePresentationSnapshot, Error> {
        let vault = try await resolveVault(scope.accountID)
        guard vault.accountID == scope.accountID else {
            throw DatabaseWorkspaceObserverError.resolvedVaultAccountMismatch
        }

        let observation = WorkspaceDatabaseObservationService(
            bridge: await vault.workspaceObservationBridge()
        )
        let rawValues = observation.values(for: scope, selectedWorkItemID: nil)

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // Cancellation first cancels this task. Its `for await` then drops
            // `rawValues`, whose termination handler cancels the GRDB
            // subscription before the caller can complete a vault shutdown.
            let task = Task {
                do {
                    for try await rawSnapshot in rawValues {
                        try Task.checkCancellation()
                        guard rawSnapshot.scope == scope else {
                            throw DatabaseWorkspaceObserverError.observedScopeMismatch
                        }
                        guard let presentation = try await self.presentation(
                            from: rawSnapshot,
                            scope: scope,
                            vault: vault
                        ) else {
                            // A local write landed while the full graph was
                            // loading. The GRDB observation will immediately
                            // produce the newer, coherent revision.
                            continue
                        }
                        try Task.checkCancellation()
                        if case .terminated = continuation.yield(presentation) {
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

    /// Returns nil when a second local read proves the observed revision is no
    /// longer current. This prevents a presentation snapshot from combining a
    /// work-item graph and coverage/durable state from different commits.
    private func presentation(
        from rawSnapshot: WorkspaceObservationSnapshot,
        scope: SynchronizationScope,
        vault: AccountVault
    ) async throws -> WorkspacePresentationSnapshot? {
        guard rawSnapshot.scope == scope else {
            throw DatabaseWorkspaceObserverError.observedScopeMismatch
        }
        try Task.checkCancellation()

        let workItems = try await WorkItemRepository(vault: vault).fetch(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            authorityScope: scope
        )
        let coverageRecords = try await vault.read { database in
            try CoverageRepository.currentRecords(for: scope, in: database)
        }
        let storedDurableState = try await AccountOrganizationDurableStateRepository(vault: vault)
            .loadState(for: scope)
        let cachedState = storedDurableState?.cachedState
            ?? AccountOrganizationCachedState(
                coverage: coverageRecords,
                coverageRequirements: nil,
                lastSuccessfulSyncAt: rawSnapshot.freshness.lastSuccessfulSyncAt
            )
        // The stream's freshness accounts for an active scheduler attempt,
        // whereas a durable row intentionally records the last terminal state.
        let durableState = AccountOrganizationDurableState(
            cachedState: cachedState,
            freshness: rawSnapshot.freshness
        )
        let menuCounts = try Self.menuCounts(
            observed: rawSnapshot.menuCounts,
            workItems: workItems,
            at: .now
        )

        try Task.checkCancellation()
        let revisionFence = try await vault.read { database in
            try WorkspaceDatabaseObservationService.revision(
                in: database,
                scope: scope
            )
        }
        guard revisionFence == rawSnapshot.revision else {
            return nil
        }

        return try WorkspacePresentationSnapshot(
            scope: scope,
            workItems: workItems,
            durableState: durableState,
            coverageRequirements: cachedState.coverageRequirements ?? [],
            coverageRecords: coverageRecords,
            organizationVisibilityFreshness: rawSnapshot.organizationVisibilityFreshness,
            menuCounts: menuCounts,
            derivedEvaluatedAt: rawSnapshot.revision.derivedEvaluatedAt,
            origin: .observed
        )
    }

    /// The observed database query is authoritative for the sections it
    /// covers directly. The remaining dispositions are computed with the same
    /// local inbox rule from the full graph. A total mismatch is treated as a
    /// transient consistency failure rather than publishing invented counts.
    nonisolated static func menuCounts(
        observed: WorkspaceMenuCounts,
        workItems: [WorkItem],
        at date: Date
    ) throws -> DerivedMenuCounts {
        let dispositions = workItems.map {
            InboxEligibilityRule().disposition(for: $0, at: date)
        }
        let archived = dispositions.filter { $0 == .archived }.count
        let resolved = dispositions.filter { $0 == .resolved }.count
        let informational = dispositions.filter { $0 == .informational }.count
        let inaccessible = dispositions.filter { $0 == .inaccessible }.count
        guard observed.allWork == workItems.count,
              observed.allWork == observed.inbox + observed.waiting + observed.snoozed
                + archived + resolved + informational + inaccessible
        else {
            throw DatabaseWorkspaceObserverError.inconsistentMenuCounts
        }
        return DerivedMenuCounts(
            inbox: observed.inbox,
            waiting: observed.waiting,
            snoozed: observed.snoozed,
            archived: archived,
            resolved: resolved,
            informational: informational,
            inaccessible: inaccessible,
            myWork: observed.myWork,
            reviews: observed.reviews,
            allWork: observed.allWork
        )
    }
}
