import Foundation
import XCTest
@testable import Triage

@MainActor
final class LocalGroupingUndoCoordinatorTests: XCTestCase {
    func testFixtureAppModelPresentsLocalGroupingUndoWithoutGitHubMutation() async throws {
        let item = makeItem()
        let model = try makeFixtureModel()
        let coordinator = LocalGroupingUndoCoordinator()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        await coordinator.perform(
            .confirmMerge(
                sourceNodeID: item.primaryNodeID,
                destinationNodeID: GitHubNodeID(rawValue: "related")!,
                relation: .crossReferences
            ),
            to: item,
            appModel: model,
            undoManager: undoManager
        )

        XCTAssertEqual(undoManager.undoActionName, "Change Grouping in Triage")
        XCTAssertTrue(coordinator.feedback?.contains("GitHub is unchanged") == true)
        undoManager.undo()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(coordinator.feedback, "Local grouping reversal completed in Triage. GitHub was not modified.")
    }

    private func makeFixtureModel() throws -> TriageAppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-grouping-undo-\(UUID().uuidString)", isDirectory: true)
        return TriageAppModel(
            dependencies: TriageApplicationDependencies(
                accountSession: GroupingSession(),
                workspaceCoordinator: GroupingCoordinator(),
                refreshLifecycle: GroupingLifecycle(),
                workspaceObserver: GroupingObserver(),
                workspaceMutator: GroupingMutator()
            ),
            vaultRegistry: try VaultRegistry(rootDirectory: directory),
            defaults: UserDefaults(suiteName: "triage-grouping-undo-\(UUID().uuidString)")!,
            usesInMemoryUITestFixture: true
        )
    }

    private func makeItem() -> WorkItem {
        WorkItem(
            id: WorkItemID(rawValue: "work")!,
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
            actionItems: [],
            workflow: WorkflowState(updatedAt: .now),
            freshness: FreshnessState(status: .fresh),
            lastRelevantActivityAt: .now,
            score: AttentionScore(value: 0, breakdown: [:])
        )
    }
}

private struct GroupingSession: AccountSessionServing {
    func restoreAccounts() async throws -> AccountSessionSnapshot { throw CancellationError() }
    func connectOAuth(_: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot { throw CancellationError() }
    func connectPersonalAccessToken(_: PersonalAccessToken, resourceOwnerOrganization _: String?) async throws -> AccountSessionSnapshot { throw CancellationError() }
    func reconnectOAuth(_: AuthBrokerExchangeRequest, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { throw CancellationError() }
    func replacePersonalAccessToken(_: PersonalAccessToken, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { throw CancellationError() }
    func removeAccount(_: AccountID) async throws {}
}

private struct GroupingCoordinator: WorkspaceCoordinating {
    func select(_: SynchronizationScope) async throws -> AccountOrganizationCoordinatorState? { nil }
    func refresh(_: SynchronizationScope, priority _: AccountOrganizationRefreshPriority) async throws -> AccountOrganizationCoordinatorState? { nil }
    func cancel(_: SynchronizationScope) async throws {}
    func cancelAll(for _: AccountID) async throws {}
    func shutdown() async {}
}

private struct GroupingLifecycle: OrganizationRefreshLifecycleHandling {
    func launch(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func applicationDidBecomeActive(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func wake(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func scheduleOpportunisticBackgroundRefresh(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func stop() async {}
}

private struct GroupingObserver: WorkspaceObserving {
    func snapshots(for _: SynchronizationScope) async throws -> AsyncThrowingStream<WorkspacePresentationSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct GroupingMutator: WorkspaceMutating {
    func apply(_: WorkflowAction, to _: WorkItemID, in _: SynchronizationScope) async throws {}
    func completeActionItem(_: ActionItemID, in _: WorkItemID, scope _: SynchronizationScope) async throws {}
    func editActionItem(_: LocalActionItemEdit, actionItemID _: ActionItemID, in _: WorkItemID, expectedUpdatedAt _: Date, scope _: SynchronizationScope) async throws -> ActionItem { throw CancellationError() }
}
