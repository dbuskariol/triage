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

    private func makeSnapshot() throws -> WorkspacePresentationSnapshot {
        let scope = SynchronizationScope(
            accountID: AccountID(rawValue: "notification-observer-account")!,
            organizationID: OrganizationID(rawValue: "notification-observer-organization")!,
            credentialRevision: CredentialRevision(rawValue: "notification-observer-credential")!,
            capabilityRevision: CapabilityRevision(rawValue: "notification-observer-capability")!
        )
        return try WorkspacePresentationSnapshot(
            scope: scope,
            workItems: [],
            durableState: AccountOrganizationDurableState(
                cachedState: nil,
                freshness: FreshnessState(status: .fresh)
            ),
            coverageRequirements: [],
            coverageRecords: [],
            menuCounts: nil,
            derivedEvaluatedAt: nil,
            origin: .observed
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
