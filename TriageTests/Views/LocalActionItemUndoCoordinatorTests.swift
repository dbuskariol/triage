import Foundation
import XCTest
@testable import Triage

@MainActor
final class LocalActionItemUndoCoordinatorTests: XCTestCase {
    func testEditUndoRedoKeepsHistoryLocalToTriage() async throws {
        let action = makeAction()
        let item = makeItem(action: action)
        let model = try makeFixtureModel()
        let coordinator = LocalActionItemUndoCoordinator()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let edit = try XCTUnwrap(LocalActionItemEdit(title: "Edited", detail: "Edited detail", priority: .high, dueAt: nil))

        await coordinator.perform(edit, actionItem: action, in: item, appModel: model, undoManager: undoManager)

        XCTAssertEqual(undoManager.undoActionName, "Edit Local Action Item")
        XCTAssertTrue(coordinator.feedback?.contains("GitHub is unchanged") == true)
        undoManager.undo()
        await settleUndoTask()
        XCTAssertEqual(undoManager.redoActionName, "Edit Local Action Item")
        XCTAssertEqual(coordinator.feedback, "Local action-item reversal completed in Triage. GitHub was not modified.")
        undoManager.redo()
        await settleUndoTask()
        XCTAssertEqual(coordinator.feedback, "Local action-item reversal completed in Triage. GitHub was not modified.")
    }

    func testStaleExpectedTimestampIsRejected() throws {
        let action = makeAction()
        let edit = try XCTUnwrap(LocalActionItemEdit(title: "Edited", detail: nil, priority: .high, dueAt: nil))

        XCTAssertThrowsError(
            try TriageWorkspaceMutator.editedActionItem(
                existing: action,
                actionItemID: action.id,
                expectedUpdatedAt: action.updatedAt.addingTimeInterval(-1),
                edit: edit,
                now: action.updatedAt.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(error as? WorkflowRepositoryError, .workItemScopeMismatch)
        }
    }

    func testEditBoundaryPreservesEvidenceProvenanceAndDoesNotOfferGitHubFields() throws {
        let action = makeAction()
        let edit = try XCTUnwrap(LocalActionItemEdit(title: "Edited", detail: nil, priority: .low, dueAt: nil))

        let updated = try TriageWorkspaceMutator.editedActionItem(
            existing: action,
            actionItemID: action.id,
            expectedUpdatedAt: action.updatedAt,
            edit: edit,
            now: action.updatedAt.addingTimeInterval(1)
        )

        XCTAssertEqual(updated.origin, .deterministicRule)
        XCTAssertEqual(updated.evidenceIDs, action.evidenceIDs)
        XCTAssertEqual(updated.sourceFingerprint, action.sourceFingerprint)
        XCTAssertEqual(updated.state, .open)
        XCTAssertEqual(updated.title, "Edited")
        XCTAssertNil(updated.detail)
    }

    private func settleUndoTask() async {
        for _ in 0..<4 { await Task.yield() }
    }

    private func makeFixtureModel() throws -> TriageAppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-action-undo-\(UUID().uuidString)", isDirectory: true)
        return TriageAppModel(
            dependencies: TriageApplicationDependencies(
                accountSession: Session(),
                workspaceCoordinator: Coordinator(),
                refreshLifecycle: Lifecycle(),
                workspaceObserver: Observer(),
                workspaceMutator: Mutator()
            ),
            vaultRegistry: try VaultRegistry(rootDirectory: directory),
            defaults: UserDefaults(suiteName: "triage-action-undo-\(UUID().uuidString)")!,
            usesInMemoryUITestFixture: true
        )
    }

    private func makeAction() -> ActionItem {
        ActionItem(
            id: ActionItemID(rawValue: "action")!,
            workItemID: WorkItemID(rawValue: "work")!,
            title: "Original",
            detail: "Original detail",
            origin: .deterministicRule,
            state: .open,
            priority: .normal,
            dueAt: Date(timeIntervalSinceReferenceDate: 2_000),
            evidenceIDs: [EvidenceID(rawValue: "evidence")!],
            sourceFingerprint: "authoritative-source",
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 1_500)
        )
    }

    private func makeItem(action: ActionItem) -> WorkItem {
        WorkItem(
            id: action.workItemID,
            accountID: AccountID(rawValue: "account")!,
            organizationID: OrganizationID(rawValue: "organization")!,
            primaryNodeID: GitHubNodeID(rawValue: "node")!,
            title: "Work",
            state: .active,
            sourceKind: .issue,
            sourceURL: nil,
            repository: nil,
            members: [],
            contextLinks: [],
            relations: [],
            attentionReasons: [],
            actionItems: [action],
            workflow: WorkflowState(updatedAt: .now),
            freshness: FreshnessState(status: .fresh),
            lastRelevantActivityAt: .now,
            score: AttentionScore(value: 0, breakdown: [:])
        )
    }
}

private struct Session: AccountSessionServing {
    func restoreAccounts() async throws -> AccountSessionSnapshot { throw CancellationError() }
    func connectOAuth(_: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot { throw CancellationError() }
    func connectPersonalAccessToken(_: PersonalAccessToken, resourceOwnerOrganization _: String?) async throws -> AccountSessionSnapshot { throw CancellationError() }
    func reconnectOAuth(_: AuthBrokerExchangeRequest, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { throw CancellationError() }
    func replacePersonalAccessToken(_: PersonalAccessToken, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { throw CancellationError() }
    func removeAccount(_: AccountID) async throws {}
}

private struct Coordinator: WorkspaceCoordinating {
    func select(_: SynchronizationScope) async throws -> AccountOrganizationCoordinatorState? { nil }
    func refresh(_: SynchronizationScope, priority _: AccountOrganizationRefreshPriority) async throws -> AccountOrganizationCoordinatorState? { nil }
    func cancel(_: SynchronizationScope) async throws {}
    func cancelAll(for _: AccountID) async throws {}
    func shutdown() async {}
}

private struct Lifecycle: OrganizationRefreshLifecycleHandling {
    func launch(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func applicationDidBecomeActive(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func wake(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func scheduleOpportunisticBackgroundRefresh(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func stop() async {}
}

private struct Observer: WorkspaceObserving {
    func snapshots(for _: SynchronizationScope) async throws -> AsyncThrowingStream<WorkspacePresentationSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct Mutator: WorkspaceMutating {
    func apply(_: WorkflowAction, to _: WorkItemID, in _: SynchronizationScope) async throws {}
    func completeActionItem(_: ActionItemID, in _: WorkItemID, scope _: SynchronizationScope) async throws {}
    func editActionItem(_: LocalActionItemEdit, actionItemID _: ActionItemID, in _: WorkItemID, expectedUpdatedAt _: Date, scope _: SynchronizationScope) async throws -> ActionItem { throw CancellationError() }
}
