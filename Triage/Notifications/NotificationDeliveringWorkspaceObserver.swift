import CryptoKit
import Foundation

/// Wraps the durable workspace observation stream. Notification failures are
/// deliberately isolated from presentation: they never suppress, alter, or
/// retry a workspace snapshot through another source.
actor NotificationDeliveringWorkspaceObserver: WorkspaceObserving, WorkspaceObservationLifecycleHandling {
    private struct DeliveryTask {
        let accountID: AccountID
        let epoch: UInt64
        let subscriptionID: UUID
        /// Routes this task can submit to UserNotifications. A newer observed
        /// snapshot cancels matching tasks before purging a removed route.
        let routes: Set<NotificationRoute>
        let task: Task<Void, Never>
    }

    private struct SubscriptionTask {
        let accountID: AccountID
        let epoch: UInt64
        let task: Task<Void, Never>
    }

    private let source: any WorkspaceObserving
    private let vaultRegistry: VaultRegistry?
    private let secretStore: KeychainSecretStore?
    private let settings: (any NotificationDeliveryPreferencesProviding)?
    private let scheduling: UserNotificationCenterScheduler
    private let deliveryLeaseGate: NotificationDeliveryLeaseGate
    private let notificationRemover: any AccountNotificationRemoving
    /// Test-only injection covers the observer's authority read and final
    /// scheduling fence without opening a Keychain-backed vault.
    private let deliveryPreferencesOverride: (@Sendable (SynchronizationScope) async -> NotificationPreferences?)?
    private let deliveryAdapterOverride: WorkspaceNotificationDeliveryAdapter?
    private var adapters: [AccountID: WorkspaceNotificationDeliveryAdapter] = [:]
    private var deliveryTasks: [UUID: DeliveryTask] = [:]
    private var subscriptionTasks: [UUID: SubscriptionTask] = [:]
    private var accountEpochs: [AccountID: UInt64] = [:]
    private var observedWorkItemRoutes: [SynchronizationScope: Set<NotificationRoute>] = [:]
    private var observedEvidenceVersions: [NotificationEvidenceKey: String] = [:]
    private var isShutDown = false
    /// Test-only injection keeps stream-delivery isolation independently
    /// verifiable without depending on Keychain or UserNotifications.
    private let deliveryOverride: (@Sendable (WorkspacePresentationSnapshot) async throws -> Void)?

    init(
        source: any WorkspaceObserving,
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore,
        settings: any NotificationDeliveryPreferencesProviding,
        scheduling: UserNotificationCenterScheduler = .init(),
        deliveryLeaseGate: NotificationDeliveryLeaseGate = .init(),
        notificationRemover: any AccountNotificationRemoving = NativeNotificationAccountRemover()
    ) {
        self.source = source
        self.vaultRegistry = vaultRegistry
        self.secretStore = secretStore
        self.settings = settings
        self.scheduling = scheduling
        self.deliveryLeaseGate = deliveryLeaseGate
        self.notificationRemover = notificationRemover
        deliveryPreferencesOverride = nil
        deliveryAdapterOverride = nil
        deliveryOverride = nil
    }

    init(
        source: any WorkspaceObserving,
        deliveryOverride: @escaping @Sendable (WorkspacePresentationSnapshot) async throws -> Void,
        notificationRemover: any AccountNotificationRemoving = NoopAccountNotificationRemover()
    ) {
        self.source = source
        vaultRegistry = nil
        secretStore = nil
        settings = nil
        scheduling = .init()
        deliveryLeaseGate = .init()
        self.notificationRemover = notificationRemover
        deliveryPreferencesOverride = nil
        deliveryAdapterOverride = nil
        self.deliveryOverride = deliveryOverride
    }

    init(
        source: any WorkspaceObserving,
        deliveryPreferences: @escaping @Sendable (SynchronizationScope) async -> NotificationPreferences?,
        deliveryAdapter: WorkspaceNotificationDeliveryAdapter,
        notificationRemover: any AccountNotificationRemoving = NoopAccountNotificationRemover()
    ) {
        self.source = source
        vaultRegistry = nil
        secretStore = nil
        settings = nil
        scheduling = .init()
        deliveryLeaseGate = .init()
        self.notificationRemover = notificationRemover
        deliveryPreferencesOverride = deliveryPreferences
        deliveryAdapterOverride = deliveryAdapter
        deliveryOverride = nil
    }

    func snapshots(
        for scope: SynchronizationScope
    ) async throws -> AsyncThrowingStream<WorkspacePresentationSnapshot, Error> {
        guard !isShutDown else { throw CancellationError() }
        let accountID = scope.accountID
        let epoch = accountEpoch(for: accountID)
        let values = try await source.snapshots(for: scope)
        guard isActive(accountID: accountID, epoch: epoch) else {
            return finishedStream()
        }
        let subscriptionID = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                defer { Task { await self.finishSubscription(subscriptionID) } }
                do {
                    for try await snapshot in values {
                        try Task.checkCancellation()
                        guard snapshot.scope == scope else {
                            throw DatabaseWorkspaceObserverError.observedScopeMismatch
                        }
                        guard await self.isActive(accountID: accountID, epoch: epoch) else {
                            continuation.finish()
                            return
                        }
                        if case .terminated = continuation.yield(snapshot) { return }
                        // Rendering is authoritative and immediate. Delivery
                        // remains best-effort local integration; its Keychain,
                        // UserNotifications, or scheduler work cannot hold the
                        // observation loop or coalesce workspace snapshots.
                        await self.startDelivery(
                            for: snapshot,
                            accountEpoch: epoch,
                            subscriptionID: subscriptionID
                        )
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self.registerSubscription(
                task,
                id: subscriptionID,
                accountID: accountID,
                epoch: epoch
            )
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task {
                    await self.cancelSubscription(subscriptionID)
                    await self.cancelDeliveries(for: subscriptionID)
                }
            }
        }
    }

    /// Drops the only retained strong path to this account's scheduler and
    /// delivery ledger before `VaultRegistry` can close or delete its vault.
    /// A later account with the same opaque ID must construct a new adapter.
    func evictAccount(_ accountID: AccountID) async {
        advanceEpoch(for: accountID)
        adapters.removeValue(forKey: accountID)
        observedWorkItemRoutes = observedWorkItemRoutes.filter { $0.key.accountID != accountID }
        observedEvidenceVersions = observedEvidenceVersions.filter { $0.key.route.accountID != accountID }
        await cancelAndWaitForSubscriptions(for: accountID)
        await cancelAndWaitForDeliveries(for: accountID)
        await notificationRemover.removeNotifications(for: accountID)
    }

    func shutdown() async {
        isShutDown = true
        adapters.removeAll(keepingCapacity: false)
        observedWorkItemRoutes.removeAll(keepingCapacity: false)
        observedEvidenceVersions.removeAll(keepingCapacity: false)
        let subscriptions = subscriptionTasks.values.map(\.task)
        subscriptionTasks.removeAll(keepingCapacity: false)
        subscriptions.forEach { $0.cancel() }
        let tasks = deliveryTasks.values.map(\.task)
        deliveryTasks.removeAll(keepingCapacity: false)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
        for subscription in subscriptions {
            await subscription.value
        }
    }

    private func startDelivery(
        for snapshot: WorkspacePresentationSnapshot,
        accountEpoch: UInt64,
        subscriptionID: UUID
    ) {
        guard isActive(accountID: snapshot.scope.accountID, epoch: accountEpoch) else { return }
        let removedRoutes = updateObservedRoutes(for: snapshot)
        let candidates = candidates(for: snapshot)
        let deliveryID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.deliverIfAuthorized(
                    snapshot,
                    candidates: candidates,
                    removedRoutes: removedRoutes,
                    accountEpoch: accountEpoch,
                    deliveryID: deliveryID
                )
            } catch {
                // Delivery is best-effort macOS integration. It cannot alter
                // a workspace snapshot already delivered to the view.
            }
            await self.finishDelivery(deliveryID)
        }
        deliveryTasks[deliveryID] = DeliveryTask(
            accountID: snapshot.scope.accountID,
            epoch: accountEpoch,
            subscriptionID: subscriptionID,
            routes: Set(candidates.map(\.candidate.route)),
            task: task
        )
    }

    private func cancelDeliveries(for subscriptionID: UUID) {
        let ids = deliveryTasks.compactMap { id, value in
            value.subscriptionID == subscriptionID ? id : nil
        }
        for id in ids {
            deliveryTasks.removeValue(forKey: id)?.task.cancel()
        }
    }

    private func cancelDeliveries(for accountID: AccountID) {
        let ids = deliveryTasks.compactMap { id, value in
            value.accountID == accountID ? id : nil
        }
        for id in ids {
            deliveryTasks.removeValue(forKey: id)?.task.cancel()
        }
    }

    private func cancelAndWaitForDeliveries(for accountID: AccountID) async {
        let ids = deliveryTasks.compactMap { id, value in
            value.accountID == accountID ? id : nil
        }
        let tasks = ids.compactMap { deliveryTasks.removeValue(forKey: $0)?.task }
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
    }

    /// A disappearance in a later observed snapshot is a route revocation.
    /// Cancel every older delivery that can still add that route and wait for
    /// its scheduler cancellation fence before removing native requests. In
    /// particular, this closes the interval where `UNUserNotificationCenter`
    /// is still completing an add after the route has left the workspace.
    private func cancelAndWaitForDeliveries(
        for routes: Set<NotificationRoute>,
        excluding deliveryID: UUID
    ) async {
        guard !routes.isEmpty else { return }
        let ids = deliveryTasks.compactMap { id, value in
            id != deliveryID && !value.routes.isDisjoint(with: routes) ? id : nil
        }
        let tasks = ids.compactMap { deliveryTasks.removeValue(forKey: $0)?.task }
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
    }

    private func registerSubscription(
        _ task: Task<Void, Never>,
        id: UUID,
        accountID: AccountID,
        epoch: UInt64
    ) {
        guard isActive(accountID: accountID, epoch: epoch) else {
            task.cancel()
            return
        }
        subscriptionTasks[id] = SubscriptionTask(accountID: accountID, epoch: epoch, task: task)
    }

    private func finishSubscription(_ subscriptionID: UUID) {
        subscriptionTasks[subscriptionID] = nil
    }

    private func cancelSubscription(_ subscriptionID: UUID) {
        subscriptionTasks.removeValue(forKey: subscriptionID)?.task.cancel()
    }

    private func cancelAndWaitForSubscriptions(for accountID: AccountID) async {
        let ids = subscriptionTasks.compactMap { id, value in
            value.accountID == accountID ? id : nil
        }
        let tasks = ids.compactMap { subscriptionTasks.removeValue(forKey: $0)?.task }
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
    }

    private func accountEpoch(for accountID: AccountID) -> UInt64 {
        accountEpochs[accountID, default: 0]
    }

    private func advanceEpoch(for accountID: AccountID) {
        accountEpochs[accountID, default: 0] &+= 1
    }

    private func isActive(accountID: AccountID, epoch: UInt64) -> Bool {
        !isShutDown && accountEpoch(for: accountID) == epoch
    }

    private func finishedStream() -> AsyncThrowingStream<WorkspacePresentationSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private func finishDelivery(_ deliveryID: UUID) {
        deliveryTasks.removeValue(forKey: deliveryID)
    }

    private func deliverIfAuthorized(
        _ snapshot: WorkspacePresentationSnapshot,
        candidates: [NotificationCandidatePresentation],
        removedRoutes: [NotificationRoute],
        accountEpoch: UInt64,
        deliveryID: UUID
    ) async throws {
        guard isActive(accountID: snapshot.scope.accountID, epoch: accountEpoch) else { return }
        let removedRouteSet = Set(removedRoutes)
        await cancelAndWaitForDeliveries(for: removedRouteSet, excluding: deliveryID)
        for route in removedRoutes {
            guard !Task.isCancelled,
                  isActive(accountID: snapshot.scope.accountID, epoch: accountEpoch)
            else { return }
            await notificationRemover.removeNotifications(for: route)
        }
        if let deliveryOverride {
            try await deliveryOverride(snapshot)
            return
        }
        guard !Task.isCancelled,
              isActive(accountID: snapshot.scope.accountID, epoch: accountEpoch),
              let preferences = await deliveryPreferences(for: snapshot.scope)
        else { return }
        guard !Task.isCancelled,
              isActive(accountID: snapshot.scope.accountID, epoch: accountEpoch),
              let adapter = await adapter(
                for: snapshot.scope.accountID,
                accountEpoch: accountEpoch,
                preferences: preferences
              )
        else { return }
        for candidate in candidates {
            guard !Task.isCancelled,
                  isActive(accountID: snapshot.scope.accountID, epoch: accountEpoch)
            else { return }
            do {
                _ = try await adapter.deliver(
                    candidate: candidate.candidate,
                    presentation: candidate.presentation,
                    from: snapshot
                )
            } catch {
                // Delivery is a best-effort macOS integration. Durable source
                // authority and presentation remain unchanged on failure.
            }
        }
    }

    private func updateObservedRoutes(for snapshot: WorkspacePresentationSnapshot) -> [NotificationRoute] {
        let current = Set(snapshot.workItems.map {
            NotificationRoute(accountID: $0.accountID, organizationID: $0.organizationID, workItemID: $0.id)
        })
        let previous = observedWorkItemRoutes[snapshot.scope, default: []]
        observedWorkItemRoutes[snapshot.scope] = current
        return Array(previous.subtracting(current))
    }

    private func candidates(for snapshot: WorkspacePresentationSnapshot) -> [NotificationCandidatePresentation] {
        let drafts = NotificationCandidateFactory.drafts(from: snapshot)
        let scopeKeys = observedEvidenceVersions.keys.filter {
            $0.route.accountID == snapshot.scope.accountID && $0.route.organizationID == snapshot.scope.organizationID
        }
        let currentKeys = Set(drafts.map(\.key))
        for key in scopeKeys where !currentKeys.contains(key) {
            observedEvidenceVersions[key] = nil
        }
        return drafts.map { draft in
            let isNewEvidence = observedEvidenceVersions[draft.key] != draft.evidenceVersion
            observedEvidenceVersions[draft.key] = draft.evidenceVersion
            return .init(
                candidate: .init(
                    route: draft.route,
                    reason: draft.reason,
                    evidenceVersion: draft.evidenceVersion,
                    isNewEvidence: isNewEvidence,
                    isInboxItem: draft.isInboxItem,
                    isHighPriority: draft.isHighPriority,
                    isWaiting: draft.isWaiting,
                    dueAt: draft.dueAt
                ),
                presentation: draft.presentation
            )
        }
    }

    private func adapter(
        for accountID: AccountID,
        accountEpoch: UInt64,
        preferences: NotificationPreferences
    ) async -> WorkspaceNotificationDeliveryAdapter? {
        guard !Task.isCancelled,
              isActive(accountID: accountID, epoch: accountEpoch)
        else { return nil }
        if let deliveryAdapterOverride {
            await deliveryAdapterOverride.updatePreferences(preferences)
            return deliveryAdapterOverride
        }
        guard let secretStore, let vaultRegistry else { return nil }
        if let adapter = adapters[accountID] {
            // The scheduler is actor-isolated behind this adapter; updating it
            // is safe and immediately applies persisted Settings changes.
            await adapter.updatePreferences(preferences)
            return adapter
        }
        guard let vaultKey = try? await secretStore.readVaultKey(for: accountID),
              !Task.isCancelled,
              isActive(accountID: accountID, epoch: accountEpoch)
        else { return nil }
        guard let vault = try? await vaultRegistry.open(accountID: accountID, vaultKey: vaultKey) else {
            return nil
        }
        guard !Task.isCancelled,
              isActive(accountID: accountID, epoch: accountEpoch)
        else { return nil }
        let scheduler = NotificationScheduler(
            preferences: preferences,
            scheduling: scheduling,
            deliveryLedger: PersistentNotificationDeliveryLedger(vault: vault),
            deliveryLeaseGate: deliveryLeaseGate
        )
        let settings = settings
        let adapter = WorkspaceNotificationDeliveryAdapter(
            scheduler: scheduler,
            authorizingPreferences: { route in
                guard let settings else { return nil }
                return await settings.deliveryPreferences(
                    for: route.accountID,
                    organizationID: route.organizationID
                )
            }
        )
        adapters[accountID] = adapter
        return adapter
    }

    private func deliveryPreferences(
        for scope: SynchronizationScope
    ) async -> NotificationPreferences? {
        if let deliveryPreferencesOverride {
            return await deliveryPreferencesOverride(scope)
        }
        guard let settings else { return nil }
        return await settings.deliveryPreferences(for: scope)
    }
}

private struct NotificationCandidatePresentation: Sendable {
    let candidate: NotificationCandidate
    let presentation: NotificationPresentation
}

private struct NotificationEvidenceKey: Hashable, Sendable {
    let route: NotificationRoute
    let reason: NotificationReason
}

private struct NotificationCandidateDraft: Sendable {
    let route: NotificationRoute
    let reason: NotificationReason
    let evidenceVersion: String
    let isInboxItem: Bool
    let isHighPriority: Bool
    let isWaiting: Bool
    let dueAt: Date?
    let presentation: NotificationPresentation

    var key: NotificationEvidenceKey { .init(route: route, reason: reason) }
}

private enum NotificationCandidateFactory {
    static func drafts(from snapshot: WorkspacePresentationSnapshot) -> [NotificationCandidateDraft] {
        snapshot.workItems.flatMap { item in
            let reasons = notificationReasons(for: item)
            return reasons.map { reason in
                let version = NotificationEvidenceVersion.version(for: item, reason: reason)
                return NotificationCandidateDraft(
                    route: .init(
                        accountID: item.accountID,
                        organizationID: item.organizationID,
                        workItemID: item.id
                    ),
                    reason: reason,
                    evidenceVersion: version,
                    isInboxItem: item.isVisibleInInbox(at: .now),
                    isHighPriority: item.workflow.priority == .high,
                    isWaiting: item.workflow.status == .waiting,
                    dueAt: dueDate(for: item, reason: reason),
                    presentation: .init(title: reason.title, body: item.title)
                )
            }
        }
    }

    private static func notificationReasons(for item: WorkItem) -> [NotificationReason] {
        NotificationReason.allCases.filter {
            NotificationEvidenceVersion.isEligible($0, for: item)
        }
    }

    private static func dueDate(for item: WorkItem, reason: NotificationReason) -> Date? {
        switch reason {
        case .snoozeDue: item.workflow.snoozedUntil
        case .explicitDeadline: item.openActionItems.compactMap(\.dueAt).min()
        default: nil
        }
    }

}

/// Stable, condition-specific evidence fingerprints. They intentionally omit
/// reevaluation timestamps and unrelated workflow changes so a snapshot does
/// not manufacture new notification authority.
enum NotificationEvidenceVersion {
    static func isEligible(_ reason: NotificationReason, for item: WorkItem, at date: Date = .now) -> Bool {
        switch reason {
        case .directAssignment:
            item.attentionReasons.contains { $0.ruleID == AttentionRuleID.assignedToCurrentUser.rawValue }
        case .directReviewRequest:
            item.attentionReasons.contains { $0.ruleID == AttentionRuleID.directReviewRequest.rawValue }
        case .teamReviewRequest:
            item.attentionReasons.contains { $0.ruleID == AttentionRuleID.teamReviewRequest.rawValue }
        case .waitingResponse:
            item.attentionReasons.contains { $0.category == .waiting }
        case .highPriorityInboxItem:
            item.workflow.priority == .high && item.isVisibleInInbox(at: date)
        case .snoozeDue:
            item.workflow.snoozedUntil.map { $0 <= date } == true
        case .explicitDeadline:
            item.openActionItems.contains { $0.dueAt != nil }
        }
    }

    static func version(for item: WorkItem, reason: NotificationReason) -> String {
        let matchingReasons: [AttentionReason] = switch reason {
        case .directAssignment:
            item.attentionReasons.filter { $0.ruleID == AttentionRuleID.assignedToCurrentUser.rawValue }
        case .directReviewRequest:
            item.attentionReasons.filter { $0.ruleID == AttentionRuleID.directReviewRequest.rawValue }
        case .teamReviewRequest:
            item.attentionReasons.filter { $0.ruleID == AttentionRuleID.teamReviewRequest.rawValue }
        case .waitingResponse:
            item.attentionReasons.filter { $0.category == .waiting }
        case .highPriorityInboxItem, .snoozeDue, .explicitDeadline:
            []
        }
        let material: [String] = switch reason {
        case .directAssignment, .directReviewRequest, .teamReviewRequest, .waitingResponse:
            [item.id.rawValue, reason.rawValue, item.primaryNodeID.rawValue,
             matchingReasons.map { "\($0.id):\($0.ruleVersion)" }.sorted().joined(separator: "|")]
        case .highPriorityInboxItem:
            [item.id.rawValue, reason.rawValue, String(item.workflow.priority.rawValue),
             item.workflow.status.rawValue, item.workflow.snoozedUntil.map { String($0.timeIntervalSince1970) } ?? ""]
        case .snoozeDue:
            [item.id.rawValue, reason.rawValue, item.workflow.snoozedUntil.map { String($0.timeIntervalSince1970) } ?? ""]
        case .explicitDeadline:
            [item.id.rawValue, reason.rawValue,
             item.openActionItems.compactMap(\.dueAt).map { String($0.timeIntervalSince1970) }.sorted().joined(separator: "|")]
        }
        let joined = material.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum NotificationActionAuthorizationValidator {
    /// Mutating actions are authorized only while their signed response
    /// evidence still matches the current scoped work item. Opening Triage can
    /// remain available for an expired notification, but archive/snooze cannot
    /// act on stale state.
    static func matches(route: NotificationRoute, workItem: WorkItem) -> Bool {
        guard route.accountID == workItem.accountID,
              route.organizationID == workItem.organizationID,
              route.workItemID == workItem.id,
              let authorization = route.actionAuthorization,
              NotificationEvidenceVersion.isEligible(authorization.reason, for: workItem)
        else { return false }
        return authorization.evidenceVersion == NotificationEvidenceVersion.version(
            for: workItem,
            reason: authorization.reason
        )
    }
}

enum NotificationActionAuthorizationError: Error, Equatable, Sendable {
    case staleEvidence
}
