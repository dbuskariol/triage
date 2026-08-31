import Foundation
import XCTest
@testable import Triage

final class NotificationDeliveringWorkspaceObserverTests: XCTestCase {
    func testBlockedDeliveryDoesNotDelaySnapshotAndAccountEvictionCancelsIt() async throws {
        let snapshot = try makeSnapshot()
        let source = SnapshotSource(snapshot: snapshot, finishes: false)
        let delivery = BlockingDelivery()
        let remover = AccountNotificationRemoverSpy()
        let observer = NotificationDeliveringWorkspaceObserver(
            source: source,
            deliveryOverride: { receivedSnapshot in
                await delivery.deliver(receivedSnapshot)
            },
            notificationRemover: remover
        )

        let values = try await observer.snapshots(for: snapshot.scope)
        var iterator = values.makeAsyncIterator()

        let receivedSnapshot = try await iterator.next()
        XCTAssertEqual(receivedSnapshot, snapshot)
        await delivery.waitForStart()

        await observer.evictAccount(snapshot.scope.accountID)
        await delivery.waitForCancellation()
        let removedAccountIDs = await remover.removedAccountIDs()
        XCTAssertEqual(removedAccountIDs, [snapshot.scope.accountID])
        await observer.shutdown()
    }

    func testEvictionWaitsForPausedNativeAddThenPurgesItsExactRequest() async throws {
        let snapshot = try makeSnapshot(containsEligibleWorkItem: true)
        let source = SnapshotSource(snapshot: snapshot, finishes: false)
        let center = PausingAddNotificationScheduler()
        let remover = AccountNotificationRemoverSpy()
        let adapter = WorkspaceNotificationDeliveryAdapter(
            scheduler: NotificationScheduler(
                preferences: .init(isEnabled: true),
                scheduling: center,
                deliveryLedger: InMemoryNotificationDeliveryLedger()
            ),
            authorizingPreferences: { _ in .init(isEnabled: true) }
        )
        let observer = NotificationDeliveringWorkspaceObserver(
            source: source,
            deliveryPreferences: { _ in .init(isEnabled: true) },
            deliveryAdapter: adapter,
            notificationRemover: remover
        )

        let values = try await observer.snapshots(for: snapshot.scope)
        var iterator = values.makeAsyncIterator()
        let deliveredSnapshot = try await iterator.next()
        XCTAssertEqual(deliveredSnapshot, snapshot)
        await center.waitUntilAddStarted()

        let completion = EvictionCompletion()
        let eviction = Task {
            await observer.evictAccount(snapshot.scope.accountID)
            await completion.markComplete()
        }
        await Task.yield()
        let didFinishBeforeAddReturned = await completion.isComplete()
        XCTAssertFalse(didFinishBeforeAddReturned)

        await center.resumeAdd()
        await eviction.value

        let requests = await center.requests()
        XCTAssertTrue(requests.isEmpty)
        let removedAccounts = await remover.removedAccountIDs()
        XCTAssertEqual(removedAccounts, [snapshot.scope.accountID])
        await observer.shutdown()
    }

    func testFailingDeliveryDoesNotFailWorkspaceStream() async throws {
        let snapshot = try makeSnapshot()
        let source = SnapshotSource(snapshot: snapshot)
        let observer = NotificationDeliveringWorkspaceObserver(
            source: source,
            deliveryOverride: { _ in throw DeliveryError.failed }
        )

        let values = try await observer.snapshots(for: snapshot.scope)
        var iterator = values.makeAsyncIterator()

        let receivedSnapshot = try await iterator.next()
        XCTAssertEqual(receivedSnapshot, snapshot)
        let terminalSnapshot = try await iterator.next()
        XCTAssertNil(terminalSnapshot)
    }

    func testEvictionFencesASubscriptionThatReturnsAfterItsSourceAwait() async throws {
        let snapshot = try makeSnapshot()
        let source = BlockingSnapshotSource(snapshot: snapshot)
        let delivery = DeliveryRecorder()
        let observer = NotificationDeliveringWorkspaceObserver(
            source: source,
            deliveryOverride: { receivedSnapshot in
                await delivery.record(receivedSnapshot)
            }
        )
        let streamTask = Task { try await observer.snapshots(for: snapshot.scope) }

        await source.waitForRequest()
        await observer.evictAccount(snapshot.scope.accountID)
        await source.resume()

        let values = try await streamTask.value
        var iterator = values.makeAsyncIterator()
        let nextSnapshot = try await iterator.next()
        let deliveryCount = await delivery.count()
        XCTAssertNil(nextSnapshot)
        XCTAssertEqual(deliveryCount, 0)
    }

    func testShutdownFencesASubscriptionThatReturnsAfterItsSourceAwait() async throws {
        let snapshot = try makeSnapshot()
        let source = BlockingSnapshotSource(snapshot: snapshot)
        let delivery = DeliveryRecorder()
        let observer = NotificationDeliveringWorkspaceObserver(
            source: source,
            deliveryOverride: { receivedSnapshot in
                await delivery.record(receivedSnapshot)
            }
        )
        let streamTask = Task { try await observer.snapshots(for: snapshot.scope) }

        await source.waitForRequest()
        await observer.shutdown()
        await source.resume()

        let values = try await streamTask.value
        var iterator = values.makeAsyncIterator()
        let nextSnapshot = try await iterator.next()
        let deliveryCount = await delivery.count()
        XCTAssertNil(nextSnapshot)
        XCTAssertEqual(deliveryCount, 0)
    }

    func testEvictionWaitsForAnActiveSubscriptionToQuiesce() async throws {
        let snapshot = try makeSnapshot()
        let source = SubscriptionQuiescenceSource(snapshot: snapshot)
        let observer = NotificationDeliveringWorkspaceObserver(
            source: source,
            deliveryOverride: { _ in }
        )

        let values = try await observer.snapshots(for: snapshot.scope)
        var iterator = values.makeAsyncIterator()
        await source.emitSnapshot()
        let deliveredSnapshot = try await iterator.next()
        XCTAssertEqual(deliveredSnapshot, snapshot)

        await observer.evictAccount(snapshot.scope.accountID)

        await source.waitForTermination()
    }

    func testGlobalNotificationRevocationAfterInitialReadSuppressesInFlightDelivery() async throws {
        let snapshot = try makeSnapshot(containsEligibleWorkItem: true)
        let source = SnapshotSource(snapshot: snapshot, finishes: false)
        let authority = RevocableNotificationAuthority()
        let center = PausingNotificationScheduler()
        let adapter = WorkspaceNotificationDeliveryAdapter(
            scheduler: NotificationScheduler(
                preferences: .init(isEnabled: true),
                scheduling: center,
                deliveryLedger: InMemoryNotificationDeliveryLedger()
            ),
            authorizingPreferences: { route in
                await authority.preferences(
                    accountID: route.accountID,
                    organizationID: route.organizationID
                )
            }
        )
        let observer = NotificationDeliveringWorkspaceObserver(
            source: source,
            deliveryPreferences: { scope in
                await authority.preferences(
                    accountID: scope.accountID,
                    organizationID: scope.organizationID
                )
            },
            deliveryAdapter: adapter
        )

        let values = try await observer.snapshots(for: snapshot.scope)
        var iterator = values.makeAsyncIterator()
        let deliveredSnapshot = try await iterator.next()
        XCTAssertEqual(deliveredSnapshot, snapshot)
        await center.waitForPendingRead()

        await authority.revokeGlobally()
        await center.resumePendingRead()
        await authority.waitForReadCount(2)

        let requestsAfterGlobalRevocation = await center.requests()
        XCTAssertTrue(requestsAfterGlobalRevocation.isEmpty)
        await observer.shutdown()
    }

    func testOrganizationConsentRevocationAfterInitialReadSuppressesInFlightDelivery() async throws {
        let snapshot = try makeSnapshot(containsEligibleWorkItem: true)
        let source = SnapshotSource(snapshot: snapshot, finishes: false)
        let authority = RevocableNotificationAuthority()
        let center = PausingNotificationScheduler()
        let adapter = WorkspaceNotificationDeliveryAdapter(
            scheduler: NotificationScheduler(
                preferences: .init(isEnabled: true),
                scheduling: center,
                deliveryLedger: InMemoryNotificationDeliveryLedger()
            ),
            authorizingPreferences: { route in
                await authority.preferences(
                    accountID: route.accountID,
                    organizationID: route.organizationID
                )
            }
        )
        let observer = NotificationDeliveringWorkspaceObserver(
            source: source,
            deliveryPreferences: { scope in
                await authority.preferences(
                    accountID: scope.accountID,
                    organizationID: scope.organizationID
                )
            },
            deliveryAdapter: adapter
        )

        let values = try await observer.snapshots(for: snapshot.scope)
        var iterator = values.makeAsyncIterator()
        let deliveredSnapshot = try await iterator.next()
        XCTAssertEqual(deliveredSnapshot, snapshot)
        await center.waitForPendingRead()

        await authority.revokeOrganization(
            accountID: snapshot.scope.accountID,
            organizationID: snapshot.scope.organizationID
        )
        await center.resumePendingRead()
        await authority.waitForReadCount(2)

        let requestsAfterOrganizationRevocation = await center.requests()
        XCTAssertTrue(requestsAfterOrganizationRevocation.isEmpty)
        await observer.shutdown()
    }

    private func makeSnapshot(containsEligibleWorkItem: Bool = false) throws -> WorkspacePresentationSnapshot {
        let scope = SynchronizationScope(
            accountID: AccountID(rawValue: "notification-observer-account")!,
            organizationID: OrganizationID(rawValue: "notification-observer-organization")!,
            credentialRevision: CredentialRevision(rawValue: "notification-observer-credential")!,
            capabilityRevision: CapabilityRevision(rawValue: "notification-observer-capability")!
        )
        return try WorkspacePresentationSnapshot(
            scope: scope,
            workItems: containsEligibleWorkItem ? [notificationEligibleWorkItem(scope: scope)] : [],
            durableState: AccountOrganizationDurableState(
                cachedState: nil,
                freshness: FreshnessState(status: .fresh)
            ),
            coverageRequirements: [],
            coverageRecords: [],
            menuCounts: nil,
            derivedEvaluatedAt: containsEligibleWorkItem ? Date(timeIntervalSinceReferenceDate: 1_000) : nil,
            origin: .observed
        )
    }

    private func notificationEligibleWorkItem(scope: SynchronizationScope) -> WorkItem {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        return WorkItem(
            id: WorkItemID(rawValue: "notification-observer-work-item")!,
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            primaryNodeID: GitHubNodeID(rawValue: "NOTIFICATION_OBSERVER_NODE")!,
            title: "Private notification candidate",
            state: .active,
            sourceKind: .issue,
            sourceURL: URL(string: "https://github.com/acme/private/issues/1"),
            repository: nil,
            members: [],
            contextLinks: [],
            relations: [],
            attentionReasons: [
                .init(
                    id: "notification-observer-assignment",
                    category: .directResponsibility,
                    ruleID: AttentionRuleID.assignedToCurrentUser.rawValue,
                    ruleVersion: 1,
                    strength: 100,
                    title: "Assigned to you",
                    explanation: "Test notification candidate.",
                    evidence: [],
                    evaluatedAt: date
                ),
            ],
            actionItems: [],
            workflow: WorkflowState(updatedAt: date),
            freshness: FreshnessState(status: .fresh, lastSuccessfulSyncAt: date),
            lastRelevantActivityAt: date,
            score: AttentionScore(value: 1_000, breakdown: [:])
        )
    }
}

private enum DeliveryError: Error {
    case failed
}

private actor SnapshotSource: WorkspaceObserving {
    private let snapshot: WorkspacePresentationSnapshot
    private let finishes: Bool

    init(snapshot: WorkspacePresentationSnapshot, finishes: Bool = true) {
        self.snapshot = snapshot
        self.finishes = finishes
    }

    func snapshots(
        for _: SynchronizationScope
    ) async throws -> AsyncThrowingStream<WorkspacePresentationSnapshot, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(snapshot)
            if finishes {
                continuation.finish()
            }
        }
    }
}

private actor BlockingDelivery {
    private var hasStarted = false
    private var hasBeenCancelled = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    private var blocker: CheckedContinuation<Void, Never>?

    func deliver(_: WorkspacePresentationSnapshot) async {
        hasStarted = true
        startWaiter?.resume()
        startWaiter = nil
        await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume()
                    } else {
                        blocker = continuation
                    }
                }
            },
            onCancel: {
                Task { await self.recordCancellation() }
            }
        )
    }

    func waitForStart() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func waitForCancellation() async {
        guard !hasBeenCancelled else { return }
        await withCheckedContinuation { cancellationWaiter = $0 }
    }

    private func recordCancellation() {
        hasBeenCancelled = true
        cancellationWaiter?.resume()
        cancellationWaiter = nil
        blocker?.resume()
        blocker = nil
    }
}

private actor BlockingSnapshotSource: WorkspaceObserving {
    private let snapshot: WorkspacePresentationSnapshot
    private var requested = false
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    init(snapshot: WorkspacePresentationSnapshot) {
        self.snapshot = snapshot
    }

    func snapshots(
        for _: SynchronizationScope
    ) async throws -> AsyncThrowingStream<WorkspacePresentationSnapshot, Error> {
        requested = true
        requestWaiter?.resume()
        requestWaiter = nil
        await withCheckedContinuation { resumeWaiter = $0 }
        return AsyncThrowingStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }

    func waitForRequest() async {
        guard !requested else { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}

/// Keeps the upstream stream open after delivering a snapshot. The test can
/// therefore prove that eviction does not return while its registered
/// subscription task still owns the upstream iterator.
private actor SubscriptionQuiescenceSource: WorkspaceObserving {
    private let snapshot: WorkspacePresentationSnapshot
    private var continuation: AsyncThrowingStream<WorkspacePresentationSnapshot, Error>.Continuation?
    private var terminated = false
    private var terminationWaiter: CheckedContinuation<Void, Never>?

    init(snapshot: WorkspacePresentationSnapshot) {
        self.snapshot = snapshot
    }

    func snapshots(
        for _: SynchronizationScope
    ) async throws -> AsyncThrowingStream<WorkspacePresentationSnapshot, Error> {
        let pair = AsyncThrowingStream<WorkspacePresentationSnapshot, Error>.makeStream()
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.recordTermination() }
        }
        continuation = pair.continuation
        return pair.stream
    }

    func emitSnapshot() {
        continuation?.yield(snapshot)
    }

    func waitForTermination() async {
        guard !terminated else { return }
        await withCheckedContinuation { terminationWaiter = $0 }
    }

    private func recordTermination() {
        terminated = true
        terminationWaiter?.resume()
        terminationWaiter = nil
        continuation = nil
    }
}

private actor DeliveryRecorder {
    private var deliveries = [WorkspacePresentationSnapshot]()

    func record(_ snapshot: WorkspacePresentationSnapshot) {
        deliveries.append(snapshot)
    }

    func count() -> Int { deliveries.count }
}

private actor AccountNotificationRemoverSpy: AccountNotificationRemoving {
    private var accountIDs = [AccountID]()

    func removeNotifications(for accountID: AccountID) {
        accountIDs.append(accountID)
    }

    func removedAccountIDs() -> [AccountID] { accountIDs }
}

private actor RevocableNotificationAuthority {
    private var isGloballyEnabled = true
    private var revokedScopes = Set<NotificationScope>()
    private var readCount = 0
    private var readWaiters = [(count: Int, continuation: CheckedContinuation<Void, Never>)]()

    func preferences(accountID: AccountID, organizationID: OrganizationID) -> NotificationPreferences? {
        readCount += 1
        let ready = readWaiters.filter { $0.count <= readCount }
        readWaiters.removeAll { $0.count <= readCount }
        ready.forEach { $0.continuation.resume() }
        guard isGloballyEnabled,
              !revokedScopes.contains(.init(accountID: accountID, organizationID: organizationID))
        else { return nil }
        return .init(isEnabled: true)
    }

    func revokeGlobally() {
        isGloballyEnabled = false
    }

    func revokeOrganization(accountID: AccountID, organizationID: OrganizationID) {
        revokedScopes.insert(.init(accountID: accountID, organizationID: organizationID))
    }

    func waitForReadCount(_ count: Int) async {
        guard readCount < count else { return }
        await withCheckedContinuation { readWaiters.append((count, $0)) }
    }
}

private actor PausingNotificationScheduler: NotificationScheduling {
    private var pendingReadStarted = false
    private var pendingReadWaiter: CheckedContinuation<Void, Never>?
    private var pendingReadResume: CheckedContinuation<Void, Never>?
    private var scheduled = [NotificationRequest]()

    func pendingNotifications() async -> [PendingNotification] {
        pendingReadStarted = true
        pendingReadWaiter?.resume()
        pendingReadWaiter = nil
        await withCheckedContinuation { pendingReadResume = $0 }
        return scheduled.map { .init(identifier: $0.identifier, dedupeKey: $0.payload.dedupeKey) }
    }

    func schedule(_ request: NotificationRequest) {
        scheduled.append(request)
    }

    func removePendingNotifications(identifiedBy identifiers: [String]) {
        scheduled.removeAll { identifiers.contains($0.identifier) }
    }

    func waitForPendingRead() async {
        guard !pendingReadStarted else { return }
        await withCheckedContinuation { pendingReadWaiter = $0 }
    }

    func resumePendingRead() {
        pendingReadResume?.resume()
        pendingReadResume = nil
    }

    func requests() -> [NotificationRequest] { scheduled }
}

private actor PausingAddNotificationScheduler: NotificationScheduling {
    private var scheduled = [NotificationRequest]()
    private var addStarted = false
    private var addStartedWaiter: CheckedContinuation<Void, Never>?
    private var addResume: CheckedContinuation<Void, Never>?

    func pendingNotifications() -> [PendingNotification] { [] }

    func schedule(_ request: NotificationRequest) async {
        scheduled.append(request)
        addStarted = true
        addStartedWaiter?.resume()
        addStartedWaiter = nil
        await withCheckedContinuation { addResume = $0 }
    }

    func removePendingNotifications(identifiedBy identifiers: [String]) {
        scheduled.removeAll { identifiers.contains($0.identifier) }
    }

    func waitUntilAddStarted() async {
        guard !addStarted else { return }
        await withCheckedContinuation { addStartedWaiter = $0 }
    }

    func resumeAdd() {
        addResume?.resume()
        addResume = nil
    }

    func requests() -> [NotificationRequest] { scheduled }
}

private actor EvictionCompletion {
    private var complete = false

    func markComplete() { complete = true }
    func isComplete() -> Bool { complete }
}
