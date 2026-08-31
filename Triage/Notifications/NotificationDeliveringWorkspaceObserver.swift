import CryptoKit
import Foundation

/// Wraps the durable workspace observation stream. Notification failures are
/// deliberately isolated from presentation: they never suppress, alter, or
/// retry a workspace snapshot through another source.
actor NotificationDeliveringWorkspaceObserver: WorkspaceObserving {
    private let source: any WorkspaceObserving
    private let vaultRegistry: VaultRegistry
    private let secretStore: KeychainSecretStore
    private let settings: any NotificationDeliveryPreferencesProviding
    private let scheduling: UserNotificationCenterScheduler
    private var adapters: [AccountID: WorkspaceNotificationDeliveryAdapter] = [:]

    init(
        source: any WorkspaceObserving,
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore,
        settings: any NotificationDeliveryPreferencesProviding,
        scheduling: UserNotificationCenterScheduler = .init()
    ) {
        self.source = source
        self.vaultRegistry = vaultRegistry
        self.secretStore = secretStore
        self.settings = settings
        self.scheduling = scheduling
    }

    func snapshots(
        for scope: SynchronizationScope
    ) async throws -> AsyncThrowingStream<WorkspacePresentationSnapshot, Error> {
        let values = try await source.snapshots(for: scope)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await snapshot in values {
                        try Task.checkCancellation()
                        guard snapshot.scope == scope else {
                            throw DatabaseWorkspaceObserverError.observedScopeMismatch
                        }
                        // Keep workspace rendering independent of permission,
                        // UserNotifications, or local delivery failures.
                        await self.deliverIfAuthorized(snapshot)
                        if case .terminated = continuation.yield(snapshot) { return }
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

    private func deliverIfAuthorized(_ snapshot: WorkspacePresentationSnapshot) async {
        guard let preferences = await settings.deliveryPreferences(for: snapshot.scope.organizationID),
              let adapter = await adapter(for: snapshot.scope.accountID, preferences: preferences)
        else { return }
        for candidate in NotificationCandidateFactory.candidates(from: snapshot) {
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

    private func adapter(
        for accountID: AccountID,
        preferences: NotificationPreferences
    ) async -> WorkspaceNotificationDeliveryAdapter? {
        if let adapter = adapters[accountID] {
            // The scheduler is actor-isolated behind this adapter; updating it
            // is safe and immediately applies persisted Settings changes.
            await adapter.updatePreferences(preferences)
            return adapter
        }
        guard let vaultKey = try? await secretStore.readVaultKey(for: accountID) else { return nil }
        guard let vault = try? await vaultRegistry.open(accountID: accountID, vaultKey: vaultKey) else {
            return nil
        }
        let scheduler = NotificationScheduler(
            preferences: preferences,
            scheduling: scheduling,
            deliveryLedger: PersistentNotificationDeliveryLedger(vault: vault)
        )
        let adapter = WorkspaceNotificationDeliveryAdapter(scheduler: scheduler)
        adapters[accountID] = adapter
        return adapter
    }
}

private struct NotificationCandidatePresentation: Sendable {
    let candidate: NotificationCandidate
    let presentation: NotificationPresentation
}

private enum NotificationCandidateFactory {
    static func candidates(from snapshot: WorkspacePresentationSnapshot) -> [NotificationCandidatePresentation] {
        snapshot.workItems.flatMap { item in
            let reasons = notificationReasons(for: item)
            return reasons.map { reason in
                let version = evidenceVersion(for: item, reason: reason)
                return NotificationCandidatePresentation(
                    candidate: NotificationCandidate(
                        route: .init(
                            accountID: item.accountID,
                            organizationID: item.organizationID,
                            workItemID: item.id
                        ),
                        reason: reason,
                        evidenceVersion: version,
                        isNewEvidence: true,
                        isInboxItem: item.isVisibleInInbox(at: .now),
                        isHighPriority: item.workflow.priority == .high,
                        isWaiting: item.workflow.status == .waiting,
                        dueAt: dueDate(for: item, reason: reason)
                    ),
                    presentation: .init(title: reason.title, body: item.title)
                )
            }
        }
    }

    private static func notificationReasons(for item: WorkItem) -> [NotificationReason] {
        var result: [NotificationReason] = []
        let ruleIDs = Set(item.attentionReasons.map(\.ruleID))
        if ruleIDs.contains(AttentionRuleID.assignedToCurrentUser.rawValue) { result.append(.directAssignment) }
        if ruleIDs.contains(AttentionRuleID.directReviewRequest.rawValue) { result.append(.directReviewRequest) }
        if ruleIDs.contains(AttentionRuleID.teamReviewRequest.rawValue) { result.append(.teamReviewRequest) }
        if item.attentionReasons.contains(where: { $0.category == .waiting }) { result.append(.waitingResponse) }
        if item.workflow.priority == .high && item.isVisibleInInbox(at: .now) { result.append(.highPriorityInboxItem) }
        if let snoozedUntil = item.workflow.snoozedUntil, snoozedUntil <= .now { result.append(.snoozeDue) }
        if item.openActionItems.contains(where: { $0.dueAt != nil }) { result.append(.explicitDeadline) }
        return result
    }

    private static func dueDate(for item: WorkItem, reason: NotificationReason) -> Date? {
        switch reason {
        case .snoozeDue: item.workflow.snoozedUntil
        case .explicitDeadline: item.openActionItems.compactMap(\.dueAt).min()
        default: nil
        }
    }

    private static func evidenceVersion(for item: WorkItem, reason: NotificationReason) -> String {
        let material = [
            item.id.rawValue, reason.rawValue, item.primaryNodeID.rawValue,
            String(item.lastRelevantActivityAt.timeIntervalSince1970),
            String(item.workflow.updatedAt.timeIntervalSince1970),
            item.attentionReasons.map { "\($0.id):\($0.ruleVersion):\($0.evaluatedAt.timeIntervalSince1970)" }.sorted().joined(separator: "|"),
            item.openActionItems.map { "\($0.id.rawValue):\($0.updatedAt.timeIntervalSince1970)" }.sorted().joined(separator: "|")
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
