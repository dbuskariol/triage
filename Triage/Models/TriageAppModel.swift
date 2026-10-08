import AppKit
import Foundation
import OSLog

/// Settings-facing AI state for the selected organization.
struct OrganizationAISettingsState: Equatable {
    let consent: OrganizationAIConsent
    let isEffectivelyAvailable: Bool
    let status: String
    let availableModels: [CopilotModel]
    let modelSelectionNotice: String?

    init(
        consent: OrganizationAIConsent,
        isEffectivelyAvailable: Bool,
        status: String,
        availableModels: [CopilotModel] = [],
        modelSelectionNotice: String? = nil
    ) {
        self.consent = consent
        self.isEffectivelyAvailable = isEffectivelyAvailable
        self.status = status
        self.availableModels = availableModels
        self.modelSelectionNotice = modelSelectionNotice
    }

}

/// The running workspace for one account + organization.
struct WorkspaceRuntime: Sendable {
    let store: any TriageStore
    let engine: TriageEngine
}

/// Application state: accounts, the selected workspace, and Copilot setup.
/// All GitHub/AI work happens in `TriageEngine`; this type only coordinates
/// lifecycle and publishes presentation values.
@MainActor
final class TriageAppModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.triage.mac", category: "App")

    private enum PreferenceKey {
        static let selectedAccountID = "workspace.selected-account-id"
        static let selectedOrganizationID = "workspace.selected-organization-id"
    }

    // MARK: Accounts

    @Published private(set) var accounts: [GitHubAccount] = []
    /// Accounts whose vault key is unavailable; removable from Settings only.
    @Published private(set) var unavailableAccountIDs: Set<AccountID> = []
    @Published private(set) var vaultRecoveryIssues: [AccountVaultRecoveryIssue] = []
    @Published private(set) var organizationsByAccount: [AccountID: [GitHubOrganization]] = [:]
    @Published private(set) var organizationAccessesByAccount: [AccountID: [OrganizationID: OrganizationAccess]] = [:]
    @Published private(set) var selectedAccountID: AccountID? {
        didSet { defaults.set(selectedAccountID?.rawValue, forKey: PreferenceKey.selectedAccountID) }
    }
    @Published private(set) var selectedOrganizationID: OrganizationID? {
        didSet {
            defaults.set(selectedOrganizationID?.rawValue, forKey: PreferenceKey.selectedOrganizationID)
            savedSearches = selectedOrganizationID.map { SavedSearchStore(organizationID: $0).load(defaults: defaults) } ?? []
            if case .savedSearch = destination { destination = .section(.inbox) }
        }
    }
    @Published private(set) var connectionError: String?
    @Published private(set) var credentialActionNotice: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var isRestoringAccounts = false
    @Published private(set) var hasRestoredAccounts = false
    @Published private(set) var restorationError: String?
    @Published private(set) var accountsBeingRemoved: Set<AccountID> = []

    // MARK: Workspace

    @Published private(set) var presentation = WorkspacePresentation.empty
    /// The selected organization's triage rules and instructions.
    @Published private(set) var rules = TriageRules.empty
    @Published private(set) var rulesError: String?
    /// The rule editor started from an item, if open.
    @Published var ruleDraft: RuleDraft?
    /// Local status changes shown immediately, before the store confirms them.
    private var optimisticLocal: [GitHubNodeID: LocalStatus] = [:]
    @Published var destination = WorkspaceDestination.section(.inbox) {
        didSet {
            defaults.set(destination.storageValue, forKey: TriagePreferenceKeys.lastDestination)
            guard destination != oldValue, !isTraversingHistory else { return }
            backHistory.append(.init(destination: oldValue, selectedEntryID: selectedEntryID))
            if backHistory.count > 50 { backHistory.removeFirst() }
            forwardHistory.removeAll()
        }
    }
    /// Finder-style Back and Forward through destinations.
    @Published private(set) var backHistory: [NavigationPoint] = []
    @Published private(set) var forwardHistory: [NavigationPoint] = []
    private var isTraversingHistory = false
    /// The item whose reply is being drafted, if the drafter is open.
    @Published var draftEntry: TriageEntry?
    /// Items being worked through in Focus, if Focus is on.
    @Published var focusQueue: [GitHubNodeID]?
    /// The selected organization's saved searches, shown in the sidebar.
    @Published private(set) var savedSearches: [SavedSearch] = []
    @Published var selectedEntryID: GitHubNodeID?
    /// Toolbar search; filters the list in place.
    @Published var search = WorkspaceSearch()
    @Published var doneFilter = DoneFilter.all
    /// Incremented by Edit ▸ Find (⌘F) to focus the search field.
    @Published var searchFocusRequest = 0

    // MARK: Copilot

    @Published private(set) var organizationAISettingsByAccount: [AccountID: [OrganizationID: OrganizationAISettingsState]] = [:]
    @Published private(set) var selectedCopilotAuthorizationState: CopilotAccountAuthorizationState = .unavailable
    @Published private(set) var copilotAuthenticationError: String?
    @Published private(set) var copilotRuntimeOperationError: String?
    @Published private(set) var isCopilotRuntimeOperationInProgress = false
    @Published private(set) var isCopilotAuthenticationInProgress = false

    /// Opens Settings at a category; installed by the window scene.
    var openSettings: ((SettingsCategory) -> Void)?
    /// Brings the main window forward; installed by the window scene.
    var openMainWindow: (() -> Void)?
    /// Receives each new presentation (notifications and the Dock badge);
    /// installed by the application delegate, never in tests.
    var onPresentationChange: ((WorkspacePresentation, OrganizationID?) -> Void)?

    private let dependencies: TriageApplicationDependencies
    private let defaults: UserDefaults
    private let oauthAuthorizer = GitHubOAuthAuthorizer()
    private var runtime: (scope: WorkspaceScope, value: WorkspaceRuntime)?
    private var workspaceTask: Task<Void, Never>?
    private var observationTasks: [Task<Void, Never>] = []
    private var entries: [TriageEntry] = []
    private var status = TriageStatus.initial
    private var modelsByScope: [WorkspaceScope: [CopilotModel]] = [:]
    private var copilotRestoreAttempted: Set<WorkspaceScope> = []
    private var copilotRuntimeOperationTask: Task<Void, Never>?
    private var copilotRuntimeStateTask: Task<Void, Never>?
    private var copilotAuthenticationTask: Task<Void, Never>?
    private var isShuttingDown = false

    init(dependencies: TriageApplicationDependencies, defaults: UserDefaults = .standard) {
        self.dependencies = dependencies
        self.defaults = defaults
        selectedAccountID = defaults.string(forKey: PreferenceKey.selectedAccountID).flatMap(AccountID.init(rawValue:))
        selectedOrganizationID = defaults.string(forKey: PreferenceKey.selectedOrganizationID)
            .flatMap(OrganizationID.init(rawValue:))
        savedSearches = selectedOrganizationID.map { SavedSearchStore(organizationID: $0).load(defaults: defaults) } ?? []
        let launch = defaults.string(forKey: TriagePreferenceKeys.launchDestination).flatMap(LaunchDestination.init) ?? .inbox
        destination = launch.resolve(
            lastViewed: defaults.string(forKey: TriagePreferenceKeys.lastDestination), savedSearches: savedSearches
        )
    }

    var hasConnectedAccount: Bool { !accounts.isEmpty }

    var selectedAccount: GitHubAccount? { accounts.first { $0.id == selectedAccountID } }

    var organizations: [GitHubOrganization] {
        selectedAccountID.flatMap { organizationsByAccount[$0] } ?? []
    }

    var selectedOrganization: GitHubOrganization? {
        organizations.first { $0.id == selectedOrganizationID }
    }

    var selectedOrganizationAISettings: OrganizationAISettingsState? {
        guard let selectedAccountID, let selectedOrganizationID else { return nil }
        return organizationAISettingsByAccount[selectedAccountID]?[selectedOrganizationID]
    }

    var selectedEntry: TriageEntry? {
        guard let selectedEntryID else { return nil }
        // The presented entry carries rule effects and optimistic changes.
        return presentation.allEntries.first { $0.id == selectedEntryID }
    }

    var selectedScope: WorkspaceScope? {
        guard let account = selectedAccount, let organization = selectedOrganization else { return nil }
        return WorkspaceScope(
            accountID: account.id, organizationID: organization.id,
            organizationLogin: organization.login, viewerLogin: account.login
        )
    }

    // MARK: Lifecycle

    func restoreAccounts() async {
        guard !isShuttingDown, !isRestoringAccounts else { return }
        isRestoringAccounts = true
        defer {
            isRestoringAccounts = false
            hasRestoredAccounts = true
        }
        restorationError = nil
        do {
            install(try await dependencies.accountSession.restoreAccounts())
            activateWorkspace()
        } catch is CancellationError {
            return
        } catch {
            restorationError = "Triage could not open its encrypted account data."
        }
    }

    func restoreVerifiedMigrationBackup(for accountID: AccountID, migrationID: String) async {
        guard !isShuttingDown else { return }
        restorationError = nil
        do {
            install(try await dependencies.accountSession.restoreVerifiedMigrationBackup(
                for: accountID, migrationID: migrationID
            ))
            activateWorkspace()
        } catch {
            restorationError = "Triage could not restore the verified encrypted backup."
        }
    }

    func applicationDidBecomeActive() {
        refreshIfStale()
    }

    func handleSystemWake() {
        refreshIfStale()
    }

    /// Activation and wake only refresh when saved work is more than a minute
    /// old and nothing is running; explicit Refresh always runs.
    private func refreshIfStale() {
        guard UserDefaults.standard.object(forKey: TriagePreferenceKeys.refreshWhenActive) as? Bool ?? true,
              case .idle = status.phase,
              let last = status.lastRefreshAt, Date.now.timeIntervalSince(last) > 60
        else { return }
        refreshNow()
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        copilotRuntimeOperationTask?.cancel()
        copilotRuntimeStateTask?.cancel()
        copilotAuthenticationTask?.cancel()
        await deactivateWorkspace()
    }

    // MARK: Selection

    func selectAccount(_ accountID: AccountID) {
        guard accounts.contains(where: { $0.id == accountID }), accountID != selectedAccountID else { return }
        selectedAccountID = accountID
        selectedOrganizationID = organizationsByAccount[accountID]?.first?.id
        activateWorkspace()
    }

    func selectOrganization(_ organizationID: OrganizationID) {
        guard organizations.contains(where: { $0.id == organizationID }),
              organizationID != selectedOrganizationID
        else { return }
        selectedOrganizationID = organizationID
        activateWorkspace()
    }

    /// Starts the engine for the selected account and organization, replacing
    /// any previous workspace. Saved entries appear as soon as the store emits.
    private func activateWorkspace() {
        guard !isShuttingDown else { return }
        let scope = selectedScope
        guard scope != runtime?.scope || runtime == nil else { return }
        let previous = workspaceTask
        workspaceTask = Task { [weak self] in
            previous?.cancel()
            await previous?.value
            guard let self else { return }
            await self.deactivateWorkspace()
            guard let scope, !Task.isCancelled else { return }
            do {
                let runtime = try await self.dependencies.makeWorkspace(scope)
                guard !Task.isCancelled, self.selectedScope == scope else { return }
                self.runtime = (scope, runtime)
                self.rules = (try? await runtime.store.rules(scope: scope)) ?? .empty
                self.observe(runtime, scope: scope)
                // GitHub discovery must never wait on Copilot sign-in or model listing.
                Self.logger.notice("workspace activated; starting engine")
                await runtime.engine.start(scope)
                let wasAuthenticated = self.selectedCopilotAuthorizationState.authentication == .authenticated
                await self.restoreCopilotIfNeeded(scope: scope)
                if !wasAuthenticated, self.selectedCopilotAuthorizationState.authentication == .authenticated,
                   self.runtime?.scope == scope, case .copilotUnavailable = self.status.problem {
                    Self.logger.notice("Copilot restored; resuming analysis")
                    await runtime.engine.refreshNow()
                }
            } catch {
                Self.logger.error("workspace activation failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
                self.status.problem = .gitHubUnavailable("Triage could not open this workspace's saved data.")
                self.publishPresentation()
            }
        }
    }

    private func deactivateWorkspace() async {
        observationTasks.forEach { $0.cancel() }
        observationTasks = []
        if let engine = runtime?.value.engine { await engine.stop() }
        runtime = nil
        rules = .empty
        optimisticLocal = [:]
        entries = []
        status = .initial
        selectedEntryID = nil
        publishPresentation()
    }

    private func observe(_ runtime: WorkspaceRuntime, scope: WorkspaceScope) {
        observationTasks.append(Task { [weak self] in
            do {
                for try await entries in try await runtime.store.entries(scope: scope) {
                    guard let self, self.runtime?.scope == scope else { return }
                    self.entries = entries
                    // Drop optimistic changes the store has now confirmed.
                    self.optimisticLocal = self.optimisticLocal.filter { id, local in
                        entries.first { $0.id == id }?.local != local
                    }
                    self.publishPresentation()
                }
            } catch {
                Self.logger.error("entries stream failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            }
        })
        observationTasks.append(Task { [weak self] in
            for await status in await runtime.engine.statusUpdates() {
                guard let self, self.runtime?.scope == scope else { return }
                self.status = status
                self.publishPresentation()
            }
        })
    }

    private func publishPresentation() {
        let shown = optimisticLocal.isEmpty ? entries : entries.map { entry in
            var entry = entry
            if let local = optimisticLocal[entry.id] { entry.local = local }
            return entry
        }
        let next = WorkspacePresentation(
            entries: shown, status: status, now: .now, rules: rules, viewer: runtime?.scope.viewerLogin ?? ""
        )
        guard next != presentation else { return }
        presentation = next
        onPresentationChange?(next, runtime?.scope.organizationID)
        if let selectedEntryID, !entries.contains(where: { $0.id == selectedEntryID }) {
            self.selectedEntryID = nil
        }
    }

    // MARK: Accounts

    private func install(_ session: AccountSessionSnapshot) {
        accounts = session.accounts
        unavailableAccountIDs = session.unavailableAccountIDs
        vaultRecoveryIssues = session.vaultRecoveryIssues
        organizationsByAccount = session.organizationsByAccount
        organizationAccessesByAccount = session.organizationAccessesByAccount
        credentialActionNotice = session.credentialActionNotice
        if session.unavailableAccountIDs.isEmpty, session.vaultRecoveryIssues.isEmpty {
            restorationError = nil
        } else if !session.vaultRecoveryIssues.isEmpty {
            restorationError = "An encrypted local account needs repair. Restore a verified backup, or reconnect GitHub."
        } else {
            restorationError = "An account's encrypted local data cannot be opened. Remove it in Settings, then reconnect."
        }
        if !accounts.contains(where: { $0.id == selectedAccountID }) {
            selectedAccountID = accounts.first?.id
        }
        if !organizations.contains(where: { $0.id == selectedOrganizationID }) {
            selectedOrganizationID = organizations.first?.id
        }
    }

    func connectGitHub(presentationAnchor: NSWindow) async {
        await connect {
            let configuration = try RuntimeOAuthConfiguration()
            let request = try await self.oauthAuthorizer.authorize(
                configuration: configuration.oauth, presentationAnchor: presentationAnchor
            )
            return try await self.dependencies.accountSession.connectOAuth(request)
        }
    }

    func connectPersonalAccessToken(_ rawValue: String, resourceOwnerOrganization: String?) async {
        await connect {
            let token = try PersonalAccessToken(rawValue: rawValue)
            return try await self.dependencies.accountSession.connectPersonalAccessToken(
                token, resourceOwnerOrganization: resourceOwnerOrganization
            )
        }
    }

    func replacePersonalAccessToken(_ rawValue: String, for account: GitHubAccount) async {
        await connect {
            let token = try PersonalAccessToken(rawValue: rawValue)
            await self.dependencies.copilotRuntimeAuthorization.disconnect(accountID: account.id)
            return try await self.dependencies.accountSession.replacePersonalAccessToken(token, replacing: account)
        }
    }

    private func connect(_ operation: @escaping () async throws -> AccountSessionSnapshot) async {
        guard !isConnecting, !isShuttingDown else { return }
        connectionError = nil
        credentialActionNotice = nil
        isConnecting = true
        defer { isConnecting = false }
        do {
            install(try await operation())
            await deactivateWorkspace()
            activateWorkspace()
        } catch is CancellationError {
            return
        } catch {
            connectionError = Self.connectionMessage(for: error)
        }
    }

    func recordConnectionWindowError() {
        connectionError = "Triage could not find its active window."
    }

    func removeAccount(_ accountID: AccountID) async throws {
        guard !accountsBeingRemoved.contains(accountID) else { return }
        accountsBeingRemoved.insert(accountID)
        defer { accountsBeingRemoved.remove(accountID) }
        if selectedAccountID == accountID { await deactivateWorkspace() }
        await dependencies.copilotRuntimeAuthorization.disconnect(accountID: accountID)
        try await dependencies.accountSession.removeAccount(accountID)
        dependencies.purgeAccountNavigationState(accountID)
        accounts.removeAll { $0.id == accountID }
        unavailableAccountIDs.remove(accountID)
        vaultRecoveryIssues.removeAll { $0.accountID == accountID }
        organizationsByAccount[accountID] = nil
        organizationAccessesByAccount[accountID] = nil
        organizationAISettingsByAccount[accountID] = nil
        if selectedAccountID == accountID {
            selectedAccountID = accounts.first?.id
            selectedOrganizationID = organizations.first?.id
            activateWorkspace()
        }
    }

    func isRemovingAccount(_ accountID: AccountID) -> Bool {
        accountsBeingRemoved.contains(accountID)
    }

    // MARK: Copilot

    /// Reads Copilot availability for the selected organization and, when AI
    /// is enabled, silently restores a saved Copilot login. Never opens a browser.
    func refreshSelectedOrganizationAIStatus() async {
        guard let scope = selectedScope, let account = selectedAccount else { return }
        await restoreCopilotIfNeeded(scope: scope, force: true)
        await publishAISettings(scope: scope, account: account)
    }

    private func restoreCopilotIfNeeded(scope: WorkspaceScope, force: Bool = false) async {
        guard let account = accounts.first(where: { $0.id == scope.accountID }) else { return }
        let authorization = dependencies.copilotRuntimeAuthorization
        let consent = (try? await dependencies.consent(scope)) ?? .disabled(
            accountID: scope.accountID, organizationID: scope.organizationID
        )
        var state = await authorization.state(for: account.id)
        if consent.isEnabled, state.runtime == .missing,
           (try? await authorization.upgradeRuntimeIfPreviouslyInstalled()) == true {
            Self.logger.notice("Copilot runtime upgraded after app update")
            state = await authorization.state(for: account.id)
        }
        if consent.isEnabled, state.runtime == .ready, state.authentication == .signedOut,
           force || copilotRestoreAttempted.insert(scope).inserted {
            do {
                if try await authorization.restore(
                    account: account, organizationID: scope.organizationID,
                    hasOrganizationConsent: true, isEntitled: true
                ) {
                    modelsByScope[scope] = try await authorization.models(
                        accountID: account.id, organizationID: scope.organizationID
                    )
                    copilotAuthenticationError = nil
                }
            } catch {
                copilotAuthenticationError = "Saved Copilot sign-in could not be restored. Use Connect Copilot to reconnect."
            }
            state = await authorization.state(for: account.id)
        }
        guard selectedScope == scope else { return }
        selectedCopilotAuthorizationState = state
        await publishAISettings(scope: scope, account: account)
    }

    private func publishAISettings(scope: WorkspaceScope, account: GitHubAccount) async {
        let consent = (try? await dependencies.consent(scope)) ?? .disabled(
            accountID: scope.accountID, organizationID: scope.organizationID
        )
        let state = selectedCopilotAuthorizationState
        let isAvailable = consent.isEnabled && state.runtime == .ready && state.authentication == .authenticated
        let status: String = if !consent.isEnabled {
            "Turn on AI analysis to let Copilot prioritize your work."
        } else if state.runtime != .ready {
            "Download the Copilot runtime to continue."
        } else if state.authentication != .authenticated {
            "Connect Copilot to continue."
        } else {
            "Copilot is prioritizing your work."
        }
        guard selectedScope == scope else { return }
        organizationAISettingsByAccount[account.id, default: [:]][scope.organizationID] = OrganizationAISettingsState(
            consent: consent, isEffectivelyAvailable: isAvailable, status: status,
            availableModels: modelsByScope[scope] ?? []
        )
    }

    func recordSelectedOrganizationAIConsent(_ isEnabled: Bool) async {
        guard let scope = selectedScope else { return }
        do {
            try await dependencies.saveConsent(scope, isEnabled, .auto, nil)
            if !isEnabled { await runtime?.value.engine.stop() }
            await refreshSelectedOrganizationAIStatus()
            if isEnabled, let runtime, runtime.scope == scope {
                await runtime.value.engine.start(scope)
                await runtime.value.engine.refreshNow()
            }
        } catch {
            copilotAuthenticationError = "Triage could not save AI settings for this organization."
        }
    }

    /// Saves the model, reasoning effort, and context tier the selected
    /// organization uses for prioritizing or for Draft Reply (`nil` = same as prioritizing).
    func saveSelectedOrganizationCopilotChoice(_ choice: CopilotModelChoice?, for purpose: CopilotPurpose = .triage) async {
        guard let scope = selectedScope else { return }
        let consent = selectedOrganizationAISettings?.consent
        let triage = purpose == .triage ? (choice ?? .auto) : (consent?.triageChoice ?? .auto)
        let reply = purpose == .reply ? choice : consent?.replyChoice
        do {
            try await dependencies.saveConsent(scope, true, triage, reply)
            await refreshSelectedOrganizationAIStatus()
        } catch {
            copilotAuthenticationError = "The Copilot model selection could not be saved."
        }
    }

    func startSelectedCopilotAuthenticationAtUserRequest() {
        guard !isCopilotAuthenticationInProgress, let scope = selectedScope, let account = selectedAccount else { return }
        isCopilotAuthenticationInProgress = true
        copilotAuthenticationError = nil
        copilotAuthenticationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isCopilotAuthenticationInProgress = false }
            let consent = (try? await self.dependencies.consent(scope))?.isEnabled ?? false
            do {
                try await self.dependencies.copilotRuntimeAuthorization.authenticate(
                    account: account, organizationID: scope.organizationID,
                    hasOrganizationConsent: consent, isEntitled: true
                )
                self.modelsByScope[scope] = try await self.dependencies.copilotRuntimeAuthorization.models(
                    accountID: account.id, organizationID: scope.organizationID
                )
                self.selectedCopilotAuthorizationState = await self.dependencies.copilotRuntimeAuthorization
                    .state(for: account.id)
                await self.publishAISettings(scope: scope, account: account)
                await self.runtime?.value.engine.refreshNow()
            } catch is CancellationError {
                return
            } catch {
                self.copilotAuthenticationError = Self.copilotAuthenticationMessage(for: error)
                await self.refreshSelectedOrganizationAIStatus()
            }
        }
    }

    func cancelSelectedCopilotAuthentication() {
        copilotAuthenticationTask?.cancel()
    }

    func startCopilotRuntimeAcquisitionAtUserRequest() {
        runRuntimeOperation(failure: "The Copilot runtime download didn't finish. Check your connection and try again.") {
            try await $0.acquireRuntimeAtUserRequest()
        }
    }

    func startCopilotRuntimeRepairAtUserRequest() {
        runRuntimeOperation(failure: "The Copilot runtime repair didn't finish. Try again.") {
            try await $0.repairRuntimeAtUserRequest()
        }
    }

    func removeCopilotRuntimeAtUserRequest() async {
        guard !isCopilotRuntimeOperationInProgress else { return }
        do {
            try await dependencies.copilotRuntimeAuthorization.removeRuntimeAtUserRequest()
        } catch {
            copilotRuntimeOperationError = "The Copilot runtime couldn't be removed. Try again."
        }
        await refreshSelectedOrganizationAIStatus()
    }

    func cancelCopilotRuntimeOperation() {
        copilotRuntimeOperationTask?.cancel()
        let authorization = dependencies.copilotRuntimeAuthorization
        Task { await authorization.cancelRuntimeOperationAtUserRequest() }
    }

    private func runRuntimeOperation(
        failure: String,
        _ operation: @escaping @Sendable (any CopilotRuntimeAuthorizationProviding) async throws -> Void
    ) {
        guard !isCopilotRuntimeOperationInProgress else { return }
        isCopilotRuntimeOperationInProgress = true
        copilotRuntimeOperationError = nil
        let authorization = dependencies.copilotRuntimeAuthorization
        let accountID = selectedAccountID
        copilotRuntimeStateTask = Task { [weak self] in
            guard let updates = await authorization.runtimeStateUpdates() else { return }
            for await runtime in updates {
                guard let self, self.isCopilotRuntimeOperationInProgress, self.selectedAccountID == accountID else { return }
                let current = self.selectedCopilotAuthorizationState
                self.selectedCopilotAuthorizationState = .init(
                    runtime: runtime, authentication: current.authentication,
                    isEntitled: current.isEntitled, hasOrganizationConsent: current.hasOrganizationConsent
                )
            }
        }
        copilotRuntimeOperationTask = Task { [weak self] in
            do {
                try await operation(authorization)
            } catch is CancellationError {
            } catch {
                self?.copilotRuntimeOperationError = failure
            }
            guard let self else { return }
            self.copilotRuntimeStateTask?.cancel()
            self.isCopilotRuntimeOperationInProgress = false
            self.copilotRuntimeOperationTask = nil
            await self.refreshSelectedOrganizationAIStatus()
        }
    }

    // MARK: Messages

    private static func connectionMessage(for error: Error) -> String {
        switch error {
        case is PersonalAccessTokenError:
            "Enter a supported fine-grained or classic GitHub personal access token."
        case let error as AccountConnectionError:
            error.recoveryDescription ?? "Triage couldn't validate this GitHub account. Check its access and try again."
        case let error as AccountCredentialReplacementError:
            error.localizedDescription
        case GitHubOAuthError.authorizationTimedOut:
            "GitHub sign-in timed out. Try again."
        case is RuntimeOAuthConfigurationError:
            "GitHub sign-in isn't configured in this build."
        default:
            "GitHub sign-in couldn't be completed. Try again."
        }
    }

    private static func copilotAuthenticationMessage(for error: Error) -> String {
        switch error {
        case CopilotAuthenticationError.identityMismatch, CopilotAuthenticationError.copilotIdentityMismatch:
            "Copilot signed in to a different GitHub account. Sign in with the account selected in Triage."
        case CopilotAuthenticationError.runtimeUnavailable:
            "The Copilot runtime is missing or damaged. Download or repair it, then connect again."
        case CopilotAuthenticationError.consentRequired:
            "Turn on AI analysis for this organization first."
        case CopilotXPCError.operationTimedOut:
            "Copilot sign-in timed out. Finish authorization in your browser within five minutes."
        case CopilotXPCError.helperFailure(let failure):
            failure.message
        default:
            "Copilot sign-in didn't complete. Try Connect Copilot again."
        }
    }
}

// MARK: - Workspace actions

// MARK: Refresh

extension TriageAppModel {
    func setRefreshInterval(minutes: Int) {
        guard let engine = runtime?.value.engine else { return }
        Task { await engine.setRefreshInterval(AppPreferences.refreshInterval(minutes: minutes)) }
    }

    /// Re-analyzes all work for the selected organization with Copilot while
    /// keeping current decisions visible until each is replaced.
    func reanalyzeAll() {
        var updated = rules
        updated.reanalysisToken = UUID().uuidString
        saveRules(updated)
    }
}

// MARK: Selection

extension TriageAppModel {
    /// The list section shown for the current destination (saved searches
    /// span all work; the Briefing and Review aren't lists).
    var selectedSection: WorkspacePresentation.Section {
        if case .section(let section) = destination { section } else { .inbox }
    }

    var selectedSavedSearch: SavedSearch? {
        guard case .savedSearch(let id) = destination else { return nil }
        return savedSearches.first { $0.id == id }
    }

    /// The search applied to the list: a saved search refined by the field, or the field alone.
    var effectiveSearch: WorkspaceSearch {
        selectedSavedSearch.map { $0.search.refined(by: search) } ?? search
    }

    /// The rows in display order for the current destination, for keyboard navigation.
    var visibleEntries: [TriageEntry] {
        let viewer = selectedAccount?.login ?? ""
        switch destination {
        case .briefing:
            return WorkspaceBriefing(presentation: presentation, viewer: viewer,
                                     followUpDays: followUpDays, now: .now).orderedEntries
        case .review:
            return WorkspaceReview(presentation: presentation, viewer: viewer, now: .now).orderedEntries
        case .section, .savedSearch:
            break
        }
        let defaults = UserDefaults.standard
        return presentation.visibleEntries(
            section: selectedSection, search: effectiveSearch, doneFilter: doneFilter,
            sortedBy: defaults.string(forKey: TriagePreferenceKeys.sortField).flatMap(WorkspaceSortField.init) ?? .recommended,
            ascending: defaults.bool(forKey: TriagePreferenceKeys.sortAscending),
            grouping: defaults.string(forKey: TriagePreferenceKeys.grouping).flatMap(WorkspaceGrouping.init) ?? .none,
            viewer: selectedAccount?.login ?? ""
        )
    }

    /// Keeps the selection when it is still on screen; otherwise selects the first row.
    func selectFirstEntry() {
        let visible = visibleEntries
        guard !visible.contains(where: { $0.id == selectedEntryID }) else { return }
        selectedEntryID = visible.first?.id
    }

    func goBack() { traverse(from: \.backHistory, to: \.forwardHistory) }
    func goForward() { traverse(from: \.forwardHistory, to: \.backHistory) }

    private func traverse(
        from source: ReferenceWritableKeyPath<TriageAppModel, [NavigationPoint]>,
        to target: ReferenceWritableKeyPath<TriageAppModel, [NavigationPoint]>
    ) {
        guard let point = self[keyPath: source].popLast() else { return }
        self[keyPath: target].append(.init(destination: destination, selectedEntryID: selectedEntryID))
        isTraversingHistory = true
        destination = point.destination
        isTraversingHistory = false
        selectedEntryID = point.selectedEntryID
    }

    /// Opens a list, optionally filtered, e.g. a Briefing card's Show All.
    func open(_ destination: WorkspaceDestination, search: WorkspaceSearch) {
        self.search = search
        self.destination = destination
        selectFirstEntry()
    }

    /// Moves selection by `offset` within the visible list (j/k navigation).
    func moveSelection(by offset: Int) {
        let order = visibleEntries.map(\.id)
        guard !order.isEmpty else { return }
        guard let current = selectedEntryID, let index = order.firstIndex(of: current) else {
            selectedEntryID = offset >= 0 ? order.first : order.last
            return
        }
        selectedEntryID = order[min(max(index + offset, 0), order.count - 1)]
    }
}

// MARK: Saved searches

extension TriageAppModel {
    /// Saves the current search as a sidebar smart folder and selects it.
    func saveSearch(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard effectiveSearch.isActive, !trimmed.isEmpty else { return }
        let saved = SavedSearch(name: trimmed, search: effectiveSearch)
        updateSavedSearches(savedSearches + [saved])
        search = WorkspaceSearch()
        destination = .savedSearch(saved.id)
    }

    func renameSavedSearch(_ id: SavedSearch.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        updateSavedSearches(savedSearches.map { $0.id == id ? SavedSearch(id: id, name: trimmed, search: $0.search) : $0 })
    }

    func deleteSavedSearch(_ id: SavedSearch.ID) {
        if destination == .savedSearch(id) { destination = .section(.inbox) }
        updateSavedSearches(savedSearches.filter { $0.id != id })
    }

    private func updateSavedSearches(_ searches: [SavedSearch]) {
        guard let organizationID = selectedOrganizationID else { return }
        savedSearches = searches
        SavedSearchStore(organizationID: organizationID).save(searches, defaults: defaults)
    }
}

// MARK: Rules

extension TriageAppModel {
    /// Saves rules for the selected organization. Hard rules apply immediately;
    /// changed preferences make Copilot re-analyze affected work in the background.
    func saveRules(_ updated: TriageRules) {
        guard let runtime else { return }
        let previousDigest = rules.digest
        do {
            rules = try updated.validated()
            rulesError = nil
        } catch {
            rulesError = error.localizedDescription
            return
        }
        publishPresentation()
        let saved = rules
        Task {
            do {
                try await runtime.value.store.saveRules(saved, scope: runtime.scope)
                if saved.digest != previousDigest { await runtime.value.engine.refreshNow() }
            } catch {
                Self.logger.error("rules save failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
                self.rulesError = "Triage could not save your rules."
            }
        }
    }
}

extension TriageAppModel: WorkspaceActions {
    func refreshNow() {
        guard let engine = runtime?.value.engine else { return }
        Task { await engine.refreshNow() }
    }

    func markDone(_ entry: TriageEntry) {
        setLocalStatus(.done(fingerprint: entry.item.fingerprint, at: .now), for: entry)
    }

    func snooze(_ entry: TriageEntry, until date: Date) {
        setLocalStatus(.snoozed(until: date), for: entry)
    }

    func restore(_ entry: TriageEntry) {
        setLocalStatus(.active, for: entry)
    }

    func openOnGitHub(_ entry: TriageEntry) {
        guard entry.item.url.scheme == "https", entry.item.url.host() == "github.com" else { return }
        NSWorkspace.shared.open(entry.item.url)
    }

    func openCopilotSettings() {
        openSettings?(.ai)
    }

    func show(_ entry: TriageEntry) {
        let isListed: Bool
        switch destination {
        case .section, .savedSearch: isListed = visibleEntries.contains { $0.id == entry.id }
        case .briefing, .review: isListed = false
        }
        if !isListed {
            search = WorkspaceSearch(scope: search.scope)
            if let section = presentation.section(containing: entry) { destination = .section(section) }
        }
        selectedEntryID = entry.id
    }

    var followUpDays: Int { AttentionNotifier.followUpDays(.standard) }

    func beginDraft(for entry: TriageEntry) {
        draftEntry = entry
    }

    /// Asks Copilot for a reply to `entry` in the user's writing style.
    func draftReply(for entry: TriageEntry) async throws -> String {
        guard let scope = runtime?.scope else { throw TriageDecisionError.runtimeUnavailable }
        return try await dependencies.draftReply(
            scope, entry.item, entry.decision?.nextAction,
            defaults.string(forKey: TriagePreferenceKeys.writingStyle)
        )
    }

    func startFocus(_ entries: [TriageEntry]) {
        guard !entries.isEmpty else { return }
        focusQueue = entries.map(\.id)
    }

    /// Re-applies notification and Dock badge preferences after they change.
    func refreshAttention() {
        onPresentationChange?(presentation, runtime?.scope.organizationID)
    }

    /// Shows an item by ID, e.g. from a notification.
    func show(itemID: GitHubNodeID) {
        openMainWindow?()
        if let entry = presentation.allEntries.first(where: { $0.id == itemID }) { show(entry) }
    }

    func openRulesSettings() {
        openSettings?(.rules)
    }

    func beginRule(from entry: TriageEntry, correcting: Bool) {
        let viewer = selectedAccount?.login ?? ""
        let suggestions = TriageRule.suggestedConditions(for: entry.item, viewer: viewer)
        let teamOnly = entry.item.reviewRequestKind(viewer: viewer) == .team
        let effect: TriageRuleEffect = if correcting {
            entry.decision?.disposition.isInbox == true ? .noAction : .alwaysInbox
        } else {
            teamOnly ? .lowerPriority : .alwaysInbox
        }
        ruleDraft = RuleDraft(
            rule: TriageRule(name: "", conditions: Array(suggestions.prefix(1)), effect: effect),
            suggestions: suggestions,
            context: "From \(entry.item.reference): \(entry.item.title)"
        )
    }

    func addRule(_ rule: TriageRule) {
        var updated = rules
        updated.rules.insert(rule, at: 0)
        saveRules(updated)
    }

    /// Applies the change instantly, moves selection to the next item in the
    /// list (or the previous one at the end), then saves in the background.
    private func setLocalStatus(_ status: LocalStatus, for entry: TriageEntry) {
        guard let runtime else { return }
        let order = visibleEntries.map(\.id)
        var nextSelection = selectedEntryID
        if selectedEntryID == entry.id, let index = order.firstIndex(of: entry.id) {
            nextSelection = order.indices.contains(index + 1) ? order[index + 1] : index > 0 ? order[index - 1] : nil
        }
        optimisticLocal[entry.id] = status
        publishPresentation()
        selectedEntryID = nextSelection
        Task {
            do {
                try await runtime.value.store.setLocalStatus(status, itemID: entry.id, scope: runtime.scope)
            } catch {
                Self.logger.error("local status save failed")
                self.optimisticLocal[entry.id] = nil
                self.publishPresentation()
            }
        }
    }
}
