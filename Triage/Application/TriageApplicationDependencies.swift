import Foundation

/// The account/session boundary used by the main-actor application model.
///
/// Implementations own credentials, vault opening, and account persistence.
/// They are deliberately Sendable so no Keychain, vault, or network work is
/// performed by SwiftUI views or the application model.
protocol AccountSessionServing: Sendable {
    func restoreAccounts() async throws -> AccountSessionSnapshot
    func connectOAuth(_ request: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot
    func connectPersonalAccessToken(
        _ token: PersonalAccessToken,
        resourceOwnerOrganization: String?
    ) async throws -> AccountSessionSnapshot
    func reconnectOAuth(
        _ request: AuthBrokerExchangeRequest,
        replacing account: GitHubAccount
    ) async throws -> AccountSessionSnapshot
    func replacePersonalAccessToken(
        _ token: PersonalAccessToken,
        replacing account: GitHubAccount
    ) async throws -> AccountSessionSnapshot
    func removeAccount(_ accountID: AccountID) async throws
}

/// Owns revision-safe runtime selection, synchronization, and shutdown. A
/// production implementation owns one runtime per account vault. UI cadence is
/// deliberately owned by the main-actor application model, which knows the
/// active window selection and may schedule inactive-account work separately.
protocol WorkspaceCoordinating: Sendable {
    func select(_ scope: SynchronizationScope) async throws -> AccountOrganizationCoordinatorState?
    func refresh(
        _ scope: SynchronizationScope,
        priority: AccountOrganizationRefreshPriority
    ) async throws -> AccountOrganizationCoordinatorState?
    func cancel(_ scope: SynchronizationScope) async throws
    func cancelAll(for accountID: AccountID) async throws
    func shutdown() async
}

/// Routes process lifecycle events to the account/organization scheduler.
/// Callers supply only current, revision-qualified scopes; implementations
/// must treat an obsolete scope as cancellation rather than refreshing it.
protocol OrganizationRefreshLifecycleHandling: Sendable {
    func launch(synchronizationScopes: [SynchronizationScope], activeAccountID: AccountID?) async
    func applicationDidBecomeActive(synchronizationScopes: [SynchronizationScope], activeAccountID: AccountID?) async
    func wake(synchronizationScopes: [SynchronizationScope], activeAccountID: AccountID?) async
    func scheduleOpportunisticBackgroundRefresh(
        synchronizationScopes: [SynchronizationScope],
        activeAccountID: AccountID?
    ) async
    func stop() async
}

/// Produces complete, revision-qualified durable workspace projections. The
/// stream must finish when its consumer task is cancelled and must never emit a
/// projection for another synchronization scope.
protocol WorkspaceObserving: Sendable {
    func snapshots(
        for scope: SynchronizationScope
    ) async throws -> AsyncThrowingStream<WorkspacePresentationSnapshot, Error>
}

/// Performs local workflow mutations. Implementations commit the mutation and
/// its derived/search consequences before the observation stream publishes the
/// replacement projection.
protocol WorkspaceMutating: Sendable {
    func apply(
        _ action: WorkflowAction,
        to workItemID: WorkItemID,
        in scope: SynchronizationScope
    ) async throws
    func completeActionItem(
        _ actionItemID: ActionItemID,
        in workItemID: WorkItemID,
        scope: SynchronizationScope
    ) async throws
}

/// A main-actor sink is intentionally separate from the Sendable services.
/// The future `TriageAppModel` adapter should verify its selection generation
/// before installing each snapshot or presentation failure.
@MainActor
protocol WorkspacePresentationAdapting: AnyObject {
    func install(
        _ snapshot: WorkspacePresentationSnapshot,
        for selectionGeneration: UInt64
    )
    func present(
        _ error: any Error,
        for scope: SynchronizationScope,
        selectionGeneration: UInt64
    )
}

/// Explicit application composition. This type intentionally has no default
/// initializer or convenience production fallback: `TriageApp` must supply
/// every concrete service at its composition root.
struct TriageApplicationDependencies: Sendable {
    let accountSession: any AccountSessionServing
    let workspaceCoordinator: any WorkspaceCoordinating
    let refreshLifecycle: any OrganizationRefreshLifecycleHandling
    let workspaceObserver: any WorkspaceObserving
    let workspaceMutator: any WorkspaceMutating

    init(
        accountSession: any AccountSessionServing,
        workspaceCoordinator: any WorkspaceCoordinating,
        refreshLifecycle: any OrganizationRefreshLifecycleHandling,
        workspaceObserver: any WorkspaceObserving,
        workspaceMutator: any WorkspaceMutating
    ) {
        self.accountSession = accountSession
        self.workspaceCoordinator = workspaceCoordinator
        self.refreshLifecycle = refreshLifecycle
        self.workspaceObserver = workspaceObserver
        self.workspaceMutator = workspaceMutator
    }
}
