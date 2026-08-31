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

/// Releases observation-side state before an account vault is removed or the
/// process closes every vault. This is deliberately separate from observing so
/// read-only observers without retained vault state need no lifecycle logic.
protocol WorkspaceObservationLifecycleHandling: Sendable {
    func evictAccount(_ accountID: AccountID) async
    func shutdown() async
}

/// Main-actor presentation cleanup performed only after durable account
/// deletion succeeds and before the app model releases its account state.
/// Keeping it injected makes the persistence boundary explicit without a
/// process-global navigation dependency.
typealias AccountNavigationStatePurging = @MainActor @Sendable (AccountID) -> Void
typealias AccountNotificationPreferencePurging = @MainActor @Sendable (AccountID) async -> Void

/// Removes presentation state that must not survive an interrupted account
/// deletion. Account-session recovery invokes this only after the deletion
/// journal has completed crypto-erasure and before it returns a restoration
/// snapshot to the UI.
protocol AccountDeletionRecoveryStatePurging: Sendable {
    func purgeRecoveredDeletedAccountState(for accountID: AccountID) async
}

struct NoopAccountDeletionRecoveryStatePurger: AccountDeletionRecoveryStatePurging {
    func purgeRecoveredDeletedAccountState(for _: AccountID) async {}
}

/// Production cleanup for state stored outside an encrypted account vault.
/// The account and organization defaults form one selection, so clearing the
/// deleted account also clears its paired organization. Work-item selection
/// and history remain owned by `AppNavigationModel` and are removed through
/// its injected account-scoped purge operation.
struct AccountDeletionRecoveryStatePurger: AccountDeletionRecoveryStatePurging {
    private enum PreferenceKey {
        static let selectedAccountID = "workspace.selected-account-id"
        static let selectedOrganizationID = "workspace.selected-organization-id"
    }

    private let purgeAccountNavigationState: AccountNavigationStatePurging

    init(purgeAccountNavigationState: @escaping AccountNavigationStatePurging) {
        self.purgeAccountNavigationState = purgeAccountNavigationState
    }

    func purgeRecoveredDeletedAccountState(for accountID: AccountID) async {
        await MainActor.run {
            Self.purgeSelectedAccountAndOrganization(for: accountID)
            purgeAccountNavigationState(accountID)
        }
    }

    @MainActor
    static func purgeSelectedAccountAndOrganization(
        for accountID: AccountID,
        defaults: UserDefaults = .standard
    ) {
        guard defaults.string(forKey: PreferenceKey.selectedAccountID) == accountID.rawValue else {
            return
        }
        defaults.removeObject(forKey: PreferenceKey.selectedAccountID)
        defaults.removeObject(forKey: PreferenceKey.selectedOrganizationID)
    }
}

struct NoopWorkspaceObservationLifecycle: WorkspaceObservationLifecycleHandling {
    func evictAccount(_: AccountID) async {}
    func shutdown() async {}
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
    func editActionItem(
        _ edit: LocalActionItemEdit,
        actionItemID: ActionItemID,
        in workItemID: WorkItemID,
        expectedUpdatedAt: Date,
        scope: SynchronizationScope
    ) async throws -> ActionItem
    /// Revalidates a signed local-notification authorization against the
    /// transaction-fetched work item before committing its workflow mutation.
    func applyNotificationAction(
        _ action: WorkflowAction,
        to workItemID: WorkItemID,
        in scope: SynchronizationScope,
        expectedAuthorization: NotificationActionAuthorization
    ) async throws
}

extension WorkspaceMutating {
    /// Non-production fixtures have no durable work-item transaction to
    /// revalidate. The production mutator overrides this boundary.
    func applyNotificationAction(
        _ action: WorkflowAction,
        to workItemID: WorkItemID,
        in scope: SynchronizationScope,
        expectedAuthorization _: NotificationActionAuthorization
    ) async throws {
        try await apply(action, to: workItemID, in: scope)
    }
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
    let workspaceObservationLifecycle: any WorkspaceObservationLifecycleHandling
    let workspaceMutator: any WorkspaceMutating
    let organizationAIControllers: any OrganizationAIControllerProviding
    let purgeAccountNavigationState: AccountNavigationStatePurging
    let purgeAccountNotificationPreferences: AccountNotificationPreferencePurging

    init(
        accountSession: any AccountSessionServing,
        workspaceCoordinator: any WorkspaceCoordinating,
        refreshLifecycle: any OrganizationRefreshLifecycleHandling,
        workspaceObserver: any WorkspaceObserving,
        workspaceObservationLifecycle: any WorkspaceObservationLifecycleHandling = NoopWorkspaceObservationLifecycle(),
        workspaceMutator: any WorkspaceMutating,
        organizationAIControllers: any OrganizationAIControllerProviding = OrganizationAIControllerRegistry(),
        purgeAccountNavigationState: @escaping AccountNavigationStatePurging = { _ in },
        purgeAccountNotificationPreferences: @escaping AccountNotificationPreferencePurging = { _ in }
    ) {
        self.accountSession = accountSession
        self.workspaceCoordinator = workspaceCoordinator
        self.refreshLifecycle = refreshLifecycle
        self.workspaceObserver = workspaceObserver
        self.workspaceObservationLifecycle = workspaceObservationLifecycle
        self.workspaceMutator = workspaceMutator
        self.organizationAIControllers = organizationAIControllers
        self.purgeAccountNavigationState = purgeAccountNavigationState
        self.purgeAccountNotificationPreferences = purgeAccountNotificationPreferences
    }
}
