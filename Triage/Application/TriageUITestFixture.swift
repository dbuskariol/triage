#if DEBUG
import Foundation

/// A deliberately narrow launch-only fixture for XCUITest. It exists only in
/// Debug builds and requires both the explicit argument and test environment;
/// ordinary launches, including Release builds, cannot enter this composition.
@MainActor
final class TriageUITestFixture {
    enum Scenario: String {
        case workspace
        case performanceWorkspace = "performance-workspace"
        case onboarding
        case notificationRoute = "notification-route"
    }

    let defaults: UserDefaults
    let vaultRegistry: VaultRegistry
    let scenario: Scenario
    private let snapshot: AccountSessionSnapshot
    private let workByScope: [SynchronizationScope: [WorkItem]]

    private init(
        defaults: UserDefaults,
        vaultRegistry: VaultRegistry,
        scenario: Scenario,
        snapshot: AccountSessionSnapshot,
        workByScope: [SynchronizationScope: [WorkItem]]
    ) {
        self.defaults = defaults
        self.vaultRegistry = vaultRegistry
        self.scenario = scenario
        self.snapshot = snapshot
        self.workByScope = workByScope
    }

    /// Keep the launch gate in one place so the app delegate and SwiftUI
    /// composition cannot disagree about whether this process is a fixture.
    /// Both values are required: a DEBUG launch argument alone is never enough.
    static var isRequested: Bool {
        let process = ProcessInfo.processInfo
        return process.arguments.contains("-triage-ui-fixture")
            && process.environment["TRIAGE_UI_TEST_MODE"] == "1"
    }

    static func makeIfRequested() throws -> TriageUITestFixture? {
        let process = ProcessInfo.processInfo
        guard isRequested else { return nil }

        let scenario = Scenario(rawValue: process.environment["TRIAGE_UI_TEST_SCENARIO"] ?? "") ?? .workspace
        let session = process.environment["TRIAGE_UI_TEST_SESSION"] ?? UUID().uuidString.lowercased()
        let suiteName = "com.triage.mac.uitests.\(session)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw FixtureError.invalidPreferencesSuite
        }
        if process.environment["TRIAGE_UI_TEST_RESET"] == "1" {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(scenario != .onboarding, forKey: "interface.onboarding.completed")

        let vaultRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TriageUITestVaults", isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        let vaultRegistry = try VaultRegistry(rootDirectory: vaultRoot)

        if scenario == .onboarding {
            return TriageUITestFixture(
                defaults: defaults,
                vaultRegistry: vaultRegistry,
                scenario: scenario,
                snapshot: try AccountSessionSnapshot(
                    accounts: [],
                    organizationsByAccount: [:],
                    organizationAccessesByAccount: [:],
                    accountCapabilitiesByAccount: [:]
                ),
                workByScope: [:]
            )
        }

        let data = try FixtureData.make(scenario: scenario)
        return TriageUITestFixture(
            defaults: defaults,
            vaultRegistry: vaultRegistry,
            scenario: scenario,
            snapshot: data.snapshot,
            workByScope: data.workByScope
        )
    }

    func makeAppModel(workspaceAccessibility: WorkspaceAccessibilityCoordinator) -> TriageAppModel {
        TriageAppModel(
            dependencies: .init(
                accountSession: FixtureAccountSession(snapshot: snapshot),
                workspaceCoordinator: FixtureWorkspaceCoordinator(),
                refreshLifecycle: FixtureRefreshLifecycle(),
                workspaceObserver: FixtureWorkspaceObserver(),
                workspaceMutator: FixtureWorkspaceMutator(),
                organizationAIControllers: FixtureOrganizationAIControllers()
            ),
            vaultRegistry: vaultRegistry,
            defaults: defaults,
            workspaceAccessibility: workspaceAccessibility,
            usesInMemoryUITestFixture: true
        )
    }

    /// Fixture settings retain their local controls, but must never inspect or
    /// remove requests from the real user notification center.
    func makeNotificationSettings() -> NativeNotificationSettings {
        NativeNotificationSettings(
            defaults: defaults,
            notificationRemover: NoopAccountNotificationRemover()
        )
    }

    func makeNotificationAuthorization() -> NotificationSystemAuthorization {
        NotificationSystemAuthorization(
            provider: InMemoryNotificationSystemAuthorizationProvider()
        )
    }

    func bootstrap(_ appModel: TriageAppModel) async {
        await appModel.restoreAccounts()
        for (scope, items) in workByScope {
            appModel.install(workItems: items, scope: scope)
        }
        if let accountID = appModel.selectedAccountID,
           let organizationID = appModel.selectedOrganizationID {
            appModel.selectAccount(accountID, activatesOrganization: false)
            appModel.selectOrganization(organizationID)
        } else if let firstScope = workByScope.keys.sorted(by: FixtureData.scopeOrder).first {
            appModel.selectAccount(firstScope.accountID, activatesOrganization: false)
            appModel.selectOrganization(firstScope.organizationID)
        }

        if scenario == .notificationRoute,
           let route = FixtureData.notificationRoute(in: workByScope) {
            await appModel.handleNotificationLocalAction(.openTriage(route))
        }
    }

    private enum FixtureError: Error {
        case invalidPreferencesSuite
    }
}

private struct FixtureAccountSession: AccountSessionServing {
    let snapshot: AccountSessionSnapshot

    func restoreAccounts() async throws -> AccountSessionSnapshot { snapshot }
    func connectOAuth(_: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot { throw CancellationError() }
    func connectPersonalAccessToken(_: PersonalAccessToken, resourceOwnerOrganization _: String?) async throws -> AccountSessionSnapshot { throw CancellationError() }
    func reconnectOAuth(_: AuthBrokerExchangeRequest, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { throw CancellationError() }
    func replacePersonalAccessToken(_: PersonalAccessToken, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { throw CancellationError() }
    func removeAccount(_: AccountID) async throws {}
}

private struct FixtureWorkspaceCoordinator: WorkspaceCoordinating {
    func select(_: SynchronizationScope) async throws -> AccountOrganizationCoordinatorState? { nil }
    func refresh(_: SynchronizationScope, priority _: AccountOrganizationRefreshPriority) async throws -> AccountOrganizationCoordinatorState? { nil }
    func cancel(_: SynchronizationScope) async throws {}
    func cancelAll(for _: AccountID) async throws {}
    func shutdown() async {}
}

private struct FixtureRefreshLifecycle: OrganizationRefreshLifecycleHandling {
    func launch(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func applicationDidBecomeActive(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func wake(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func scheduleOpportunisticBackgroundRefresh(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func stop() async {}
}

private struct FixtureWorkspaceObserver: WorkspaceObserving {
    func snapshots(for _: SynchronizationScope) async throws -> AsyncThrowingStream<WorkspacePresentationSnapshot, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

private struct FixtureWorkspaceMutator: WorkspaceMutating {
    func apply(_: WorkflowAction, to _: WorkItemID, in _: SynchronizationScope) async throws {}
    func completeActionItem(_: ActionItemID, in _: WorkItemID, scope _: SynchronizationScope) async throws {}
    func editActionItem(_: LocalActionItemEdit, actionItemID _: ActionItemID, in _: WorkItemID, expectedUpdatedAt _: Date, scope _: SynchronizationScope) async throws -> ActionItem { throw CancellationError() }
}

/// Fixture AI entry points are handled in-memory by `TriageAppModel` before a
/// controller can be requested. Trap if that boundary ever regresses instead
/// of constructing a Copilot/XPC-backed controller in a UI test process.
private actor FixtureOrganizationAIControllers: OrganizationAIControllerProviding {
    func controller(for _: AccountVault) async -> OrganizationAIController {
        fatalError("The local UI fixture must not construct a Copilot controller.")
    }

    func evict(accountID _: AccountID) async {}

    func evictAll() async {}
}

private enum FixtureData {
    static let date = Date(timeIntervalSince1970: 1_735_689_600)
    static let performanceWorkspaceItemCount = 10_000

    static func make(
        scenario: TriageUITestFixture.Scenario
    ) throws -> (snapshot: AccountSessionSnapshot, workByScope: [SynchronizationScope: [WorkItem]]) {
        let primaryAccount = account("00000000-0000-4000-8000-000000000001", login: "fixture-primary", name: "Fixture Primary")
        let secondaryAccount = account("00000000-0000-4000-8000-000000000002", login: "fixture-secondary", name: "Fixture Secondary")
        let acme = organization("fixture-org-acme", login: "fixture-acme", name: "Fixture Acme")
        let beta = organization("fixture-org-beta", login: "fixture-beta", name: "Fixture Beta")
        let studio = organization("fixture-org-studio", login: "fixture-studio", name: "Fixture Studio")
        let primaryCapability = capabilities(for: primaryAccount.id)
        let secondaryCapability = capabilities(for: secondaryAccount.id)
        let acmeScope = scope(account: primaryAccount.id, organization: acme.id)
        let betaScope = scope(account: primaryAccount.id, organization: beta.id)
        let studioScope = scope(account: secondaryAccount.id, organization: studio.id)
        let snapshot = try AccountSessionSnapshot(
            accounts: [primaryAccount, secondaryAccount],
            organizationsByAccount: [primaryAccount.id: [acme, beta], secondaryAccount.id: [studio]],
            organizationAccessesByAccount: [
                primaryAccount.id: [acme.id: access(for: acmeScope), beta.id: access(for: betaScope)],
                secondaryAccount.id: [studio.id: access(for: studioScope)]
            ],
            accountCapabilitiesByAccount: [primaryAccount.id: primaryCapability, secondaryAccount.id: secondaryCapability]
        )
        let acmeWork: [WorkItem]
        if scenario == .performanceWorkspace {
            acmeWork = performanceWorkItems(scope: acmeScope)
        } else {
            acmeWork = [
                workItem(
                    scope: acmeScope,
                    key: "acme-1",
                    title: "Fixture Acme keyboard accessibility smoke"
                )
            ]
        }
        return (
            snapshot,
            [
                acmeScope: acmeWork,
                betaScope: [workItem(scope: betaScope, key: "beta-1", title: "Fixture Beta notification route work")],
                studioScope: [workItem(scope: studioScope, key: "studio-1", title: "Fixture Studio account switch work")]
            ]
        )
    }

    static func notificationRoute(in workByScope: [SynchronizationScope: [WorkItem]]) -> NotificationRoute? {
        guard let scope = workByScope.keys.first(where: { $0.organizationID.rawValue == "fixture-org-beta" }),
              let item = workByScope[scope]?.first
        else { return nil }
        return NotificationRoute(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            workItemID: item.id
        )
    }

    static func scopeOrder(_ lhs: SynchronizationScope, _ rhs: SynchronizationScope) -> Bool {
        if lhs.accountID.rawValue != rhs.accountID.rawValue { return lhs.accountID.rawValue < rhs.accountID.rawValue }
        return lhs.organizationID.rawValue < rhs.organizationID.rawValue
    }

    private static func account(_ rawID: String, login: String, name: String) -> GitHubAccount {
        .init(
            id: AccountID(rawValue: rawID)!,
            githubUserID: rawID.hasSuffix("1") ? 1 : 2,
            nodeID: GitHubNodeID(rawValue: "node-\(login)")!,
            login: login,
            displayName: name,
            authenticationKind: .oauth,
            credentialID: CredentialID(rawValue: "credential-\(login)")!,
            credentialStatus: .active,
            createdAt: date,
            lastValidatedAt: date
        )
    }

    private static func organization(_ rawID: String, login: String, name: String) -> GitHubOrganization {
        .init(
            id: OrganizationID(rawValue: rawID)!,
            githubOrganizationID: rawID.hasSuffix("acme") ? 101 : rawID.hasSuffix("beta") ? 102 : 103,
            nodeID: GitHubNodeID(rawValue: "node-\(login)")!,
            login: login,
            displayName: name
        )
    }

    private static func scope(account: AccountID, organization: OrganizationID) -> SynchronizationScope {
        .init(
            accountID: account,
            organizationID: organization,
            credentialRevision: CredentialRevision(rawValue: "fixture-credential-\(account.rawValue)")!,
            capabilityRevision: CapabilityRevision(rawValue: "fixture-capability-\(organization.rawValue)")!
        )
    }

    private static func capabilities(for accountID: AccountID) -> AccountCapabilitySnapshot {
        .init(
            accountID: accountID,
            capabilities: GitHubCapability.allCases.map { .init(capability: $0, status: .available, checkedAt: date) },
            checkedAt: date
        )
    }

    private static func access(for scope: SynchronizationScope) -> OrganizationAccess {
        .init(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            state: .available,
            capabilityRevision: scope.capabilityRevision,
            capabilities: GitHubCapability.allCases.filter { $0.scope == .organization }.map {
                .init(capability: $0, status: .available, checkedAt: date)
            },
            checkedAt: date
        )
    }

    private static func workItem(scope: SynchronizationScope, key: String, title: String) -> WorkItem {
        let workItemID = WorkItemID(rawValue: "fixture-work-\(key)")!
        let repository = RepositorySummary(
            id: RepositoryID(rawValue: "fixture-repository-\(key)")!,
            nodeID: GitHubNodeID(rawValue: "fixture-repository-node-\(key)")!,
            ownerLogin: "fixture",
            name: "workspace",
            isPrivate: true,
            isArchived: false,
            hasDiscussions: true,
            url: URL(string: "https://github.example.invalid/fixture/workspace")!
        )
        return WorkItem(
            id: workItemID,
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            primaryNodeID: GitHubNodeID(rawValue: "fixture-primary-node-\(key)")!,
            title: title,
            state: .active,
            sourceKind: .pullRequest,
            sourceURL: URL(string: "https://github.example.invalid/fixture/workspace/pull/1")!,
            repository: repository,
            members: [],
            contextLinks: [],
            relations: [],
            attentionReasons: [
                .init(
                    id: "fixture-attention-\(key)",
                    category: .directResponsibility,
                    ruleID: "fixture.rule",
                    ruleVersion: 1,
                    strength: 100,
                    title: "Fixture attention",
                    explanation: "Deterministic local fixture evidence.",
                    evidence: [],
                    evaluatedAt: date
                )
            ],
            actionItems: [
                .init(
                    id: ActionItemID(rawValue: "fixture-action-\(key)")!,
                    workItemID: workItemID,
                    title: "Review fixture action",
                    origin: .deterministicRule,
                    createdAt: date,
                    updatedAt: date
                )
            ],
            workflow: .init(isPinned: true, priority: .high, localNote: "Local fixture note", updatedAt: date),
            freshness: .init(status: .fresh, lastSuccessfulSyncAt: date),
            lastRelevantActivityAt: date,
            score: .init(value: 100, breakdown: ["fixture": 100])
        )
    }

    /// A DEBUG-only in-memory workload for UI scrolling acceptance. Its titles,
    /// identifiers, and scores are deterministic fixture values rather than
    /// user content; it creates no network, Keychain, or production-vault data.
    private static func performanceWorkItems(scope: SynchronizationScope) -> [WorkItem] {
        let repository = RepositorySummary(
            id: RepositoryID(rawValue: "fixture-performance-repository")!,
            nodeID: GitHubNodeID(rawValue: "fixture-performance-repository-node")!,
            ownerLogin: "fixture",
            name: "performance",
            isPrivate: true,
            isArchived: false,
            hasDiscussions: false,
            url: URL(string: "https://github.example.invalid/fixture/performance")!
        )
        return (0..<performanceWorkspaceItemCount).map { index in
            let ordinal = String(format: "%05d", index + 1)
            let workItemID = WorkItemID(rawValue: "fixture-performance-work-\(ordinal)")!
            return WorkItem(
                id: workItemID,
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                primaryNodeID: GitHubNodeID(rawValue: "fixture-performance-node-\(ordinal)")!,
                title: "Performance fixture work \(ordinal)",
                state: .active,
                sourceKind: .issue,
                sourceURL: nil,
                repository: repository,
                members: [],
                contextLinks: [],
                relations: [],
                attentionReasons: [
                    .init(
                        id: "fixture-performance-attention-\(ordinal)",
                        category: .directResponsibility,
                        ruleID: "fixture.performance",
                        ruleVersion: 1,
                        strength: 100,
                        title: "Fixture performance attention",
                        explanation: "Deterministic local performance fixture evidence.",
                        evidence: [],
                        evaluatedAt: date
                    )
                ],
                actionItems: [],
                workflow: .init(updatedAt: date),
                freshness: .init(status: .fresh, lastSuccessfulSyncAt: date),
                lastRelevantActivityAt: date.addingTimeInterval(TimeInterval(-index)),
                score: .init(value: performanceWorkspaceItemCount - index, breakdown: ["fixture": 100])
            )
        }
    }
}
#endif
