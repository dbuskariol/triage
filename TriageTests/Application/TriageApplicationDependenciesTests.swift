import Foundation
import XCTest
@testable import Triage

final class TriageApplicationDependenciesTests: XCTestCase {
    func testWorkspaceConstructionFatalDiagnosticNeverIncludesUnderlyingErrorDetails() {
        let sensitiveText = "ghp_sensitive_token_and_private_path_must_not_escape"
        let error = NSError(
            domain: sensitiveText,
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: sensitiveText,
                NSFilePathErrorKey: "/Users/person/Library/Application Support/Triage/private.sqlite"
            ]
        )

        let diagnostic = TriageStartupDiagnostics.workspaceConstructionFatalDiagnostic(for: error)

        XCTAssertEqual(diagnostic, "Triage could not construct its local encrypted workspace.")
        XCTAssertFalse(diagnostic.contains(sensitiveText))
        XCTAssertFalse(diagnostic.contains("private.sqlite"))
    }

    func testProductionCompositionHasConcreteServicesForEveryBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-production-composition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let composition = TriageProductionComposition(
            vaultRegistry: try VaultRegistry(rootDirectory: root),
            secretStore: KeychainSecretStore(),
            applicationSupportDirectory: root.appendingPathComponent("Application Support", isDirectory: true),
            cachesDirectory: root.appendingPathComponent("Caches", isDirectory: true)
        )
        let dependencies = composition.dependencies()

        XCTAssertTrue(dependencies.accountSession is TriageAccountSessionService)
        XCTAssertTrue(dependencies.workspaceCoordinator is TriageWorkspaceCoordinator)
        XCTAssertTrue(dependencies.refreshLifecycle is TriageWorkspaceCoordinator)
        XCTAssertTrue(dependencies.workspaceObserver is DatabaseWorkspaceObserver)
        XCTAssertTrue(dependencies.workspaceMutator is TriageWorkspaceMutator)
    }

    func testPostCredentialReplayMapsOnlyValidOrganizationIdentities() throws {
        let mapped = try TriageAccountSessionService.organizationForInventoryReplay(
            GitHubOrganizationDTO(id: 1, nodeID: "O_1", login: "acme", avatarURL: nil)
        )
        XCTAssertEqual(mapped.id.rawValue, "O_1")
        XCTAssertEqual(mapped.nodeID.rawValue, "O_1")
        XCTAssertEqual(mapped.githubOrganizationID, 1)
        XCTAssertEqual(mapped.login, "acme")

        XCTAssertThrowsError(
            try TriageAccountSessionService.organizationForInventoryReplay(
                GitHubOrganizationDTO(id: 1, nodeID: "", login: "acme", avatarURL: nil)
            )
        ) { error in
            XCTAssertEqual(error as? AccountConnectionError, .invalidGitHubIdentity)
        }
    }

    func testDependenciesRequireExplicitServicesAndRouteCallsToThem() async throws {
        let session = SessionSpy()
        let coordinator = CoordinatorSpy()
        let lifecycle = LifecycleSpy()
        let observer = ObserverSpy()
        let mutator = MutatorSpy()
        let dependencies = TriageApplicationDependencies(
            accountSession: session,
            workspaceCoordinator: coordinator,
            refreshLifecycle: lifecycle,
            workspaceObserver: observer,
            workspaceMutator: mutator
        )
        let scope = fixtureScope()

        _ = try await dependencies.accountSession.restoreAccounts()
        _ = try await dependencies.workspaceCoordinator.select(scope)
        await dependencies.refreshLifecycle.launch(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )
        await dependencies.refreshLifecycle.applicationDidBecomeActive(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )
        await dependencies.refreshLifecycle.wake(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )
        await dependencies.refreshLifecycle.scheduleOpportunisticBackgroundRefresh(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )
        await dependencies.refreshLifecycle.stop()
        _ = try await dependencies.workspaceObserver.snapshots(for: scope)
        try await dependencies.workspaceMutator.apply(.archive, to: WorkItemID.make(), in: scope)

        let restoreCount = await session.restoreCallCount()
        let selectedScopes = await coordinator.selectedScopes()
        let observedScopes = await observer.observedScopes()
        let appliedScopes = await mutator.appliedScopes()
        let lifecycleEvents = await lifecycle.events()
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(selectedScopes, [scope])
        XCTAssertEqual(observedScopes, [scope])
        XCTAssertEqual(appliedScopes, [scope])
        XCTAssertEqual(lifecycleEvents, [.launch, .active, .wake, .background, .stop])
    }

    func testSnapshotRejectsMixedAuthorityCoverage() throws {
        let scope = fixtureScope()
        let record = CoverageRecord(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            repositoryID: nil,
            feature: .issues,
            streamID: SyncStreamID(rawValue: UUID().uuidString.lowercased())!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: CredentialRevision(rawValue: UUID().uuidString.lowercased())!,
            capabilityRevision: scope.capabilityRevision,
            status: .complete,
            lastSuccessfulAt: .now,
            failureDetail: nil
        )

        XCTAssertThrowsError(
            try WorkspacePresentationSnapshot(
                scope: scope,
                workItems: [],
                durableState: AccountOrganizationDurableState(cachedState: nil),
                coverageRequirements: [],
                coverageRecords: [record],
                menuCounts: nil,
                derivedEvaluatedAt: nil,
                origin: .observed
            )
        ) { error in
            XCTAssertEqual(error as? WorkspacePresentationSnapshotError, .coverageScopeMismatch)
        }
    }

    func testSnapshotCoverageEvaluationUsesItsExactScope() throws {
        let scope = fixtureScope()
        let requirement = CoverageRequirement(
            feature: .issues,
            repositoryID: nil,
            streamID: SyncStreamID(rawValue: UUID().uuidString.lowercased())!
        )
        let snapshot = try WorkspacePresentationSnapshot(
            scope: scope,
            workItems: [],
            durableState: AccountOrganizationDurableState(cachedState: nil),
            coverageRequirements: [requirement],
            coverageRecords: [],
            menuCounts: nil,
            derivedEvaluatedAt: .now,
            origin: .cached
        )

        XCTAssertFalse(snapshot.coverageEvaluation.isComplete)
        XCTAssertEqual(snapshot.coverageEvaluation.missing, [requirement])
        XCTAssertEqual(snapshot.coverageEvaluation.freshness.status, .partial)
    }

    private func fixtureScope() -> SynchronizationScope {
        SynchronizationScope(
            accountID: AccountID.make(),
            organizationID: OrganizationID(rawValue: UUID().uuidString.lowercased())!,
            credentialRevision: CredentialRevision(rawValue: UUID().uuidString.lowercased())!,
            capabilityRevision: CapabilityRevision(rawValue: UUID().uuidString.lowercased())!
        )
    }
}

private actor SessionSpy: AccountSessionServing {
    private var restores = 0

    func restoreAccounts() async throws -> AccountSessionSnapshot {
        restores += 1
        return try AccountSessionSnapshot(
            accounts: [],
            organizationsByAccount: [:],
            organizationAccessesByAccount: [:],
            accountCapabilitiesByAccount: [:]
        )
    }

    func connectOAuth(_: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot { try await restoreAccounts() }
    func connectPersonalAccessToken(_: PersonalAccessToken, resourceOwnerOrganization _: String?) async throws -> AccountSessionSnapshot { try await restoreAccounts() }
    func reconnectOAuth(_: AuthBrokerExchangeRequest, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try await restoreAccounts() }
    func replacePersonalAccessToken(_: PersonalAccessToken, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try await restoreAccounts() }
    func removeAccount(_: AccountID) async throws {}

    func restoreCallCount() -> Int { restores }
}

private actor CoordinatorSpy: WorkspaceCoordinating {
    private var selections: [SynchronizationScope] = []

    func select(_ scope: SynchronizationScope) async throws -> AccountOrganizationCoordinatorState? {
        selections.append(scope)
        return nil
    }

    func refresh(_: SynchronizationScope, priority _: AccountOrganizationRefreshPriority) async throws -> AccountOrganizationCoordinatorState? { nil }
    func cancel(_: SynchronizationScope) async throws {}
    func cancelAll(for _: AccountID) async throws {}
    func shutdown() async {}

    func selectedScopes() -> [SynchronizationScope] { selections }
}

private actor ObserverSpy: WorkspaceObserving {
    private var scopes: [SynchronizationScope] = []

    func snapshots(for scope: SynchronizationScope) async throws -> AsyncThrowingStream<WorkspacePresentationSnapshot, Error> {
        scopes.append(scope)
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func observedScopes() -> [SynchronizationScope] { scopes }
}

private actor LifecycleSpy: OrganizationRefreshLifecycleHandling {
    enum Event: Equatable, Sendable {
        case launch
        case active
        case wake
        case background
        case stop
    }

    private var storage = [Event]()

    func launch(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {
        storage.append(.launch)
    }

    func applicationDidBecomeActive(
        synchronizationScopes _: [SynchronizationScope],
        activeAccountID _: AccountID?
    ) async {
        storage.append(.active)
    }

    func wake(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {
        storage.append(.wake)
    }

    func scheduleOpportunisticBackgroundRefresh(
        synchronizationScopes _: [SynchronizationScope],
        activeAccountID _: AccountID?
    ) async {
        storage.append(.background)
    }

    func stop() async {
        storage.append(.stop)
    }

    func events() -> [Event] { storage }
}

private actor MutatorSpy: WorkspaceMutating {
    private var scopes: [SynchronizationScope] = []

    func apply(_: WorkflowAction, to _: WorkItemID, in scope: SynchronizationScope) async throws {
        scopes.append(scope)
    }

    func completeActionItem(_: ActionItemID, in _: WorkItemID, scope: SynchronizationScope) async throws {}

    func appliedScopes() -> [SynchronizationScope] { scopes }
}
