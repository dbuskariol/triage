import AppKit
import SwiftUI

/// Separates a persisted user preference from the system-managed adaptive
/// split-view state. In particular, `.detailOnly` is a temporary layout state,
/// not a request to persistently hide the sidebar.
struct WorkspaceSplitViewVisibilityState {
    private(set) var visibility: NavigationSplitViewVisibility

    /// The standard sidebar command must describe what is on screen, rather
    /// than the separately persisted preference. macOS may temporarily
    /// collapse an otherwise preferred sidebar during resize.
    var isSidebarPresented: Bool {
        visibility == .all
    }

    /// Keep the toolbar context in sync with the system's current adaptive
    /// split-view layout rather than the separately persisted intent.
    var shouldShowPrincipalOrganizationTitle: Bool {
        !isSidebarPresented
    }

    init(isSidebarVisible: Bool = true) {
        visibility = isSidebarVisible ? .all : .doubleColumn
    }

    mutating func restoreExplicitSidebarPreference(_ isSidebarVisible: Bool) {
        applyExplicitSidebarPreference(isSidebarVisible)
    }

    mutating func applyExplicitSidebarPreference(_ isSidebarVisible: Bool) {
        visibility = isSidebarVisible ? .all : .doubleColumn
    }

    mutating func receiveSystemVisibility(_ visibility: NavigationSplitViewVisibility) {
        self.visibility = visibility
    }
}

private struct WorkspaceSidebarWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

private struct WorkspaceContentWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var appModel: TriageAppModel
    @EnvironmentObject private var workspaceAccessibility: WorkspaceAccessibilityCoordinator
    @AppStorage("interface.onboarding.completed") private var hasCompletedOnboarding = false
    @State private var isRetryingUnavailableWorkspace = false
    @State private var accountRecoveryBeingRetried: LocalAccountRecoveryPresentation?
    // Keep the complete system visibility value local to this window. The
    // persisted preference records only a deliberate sidebar toggle; it must
    // not overwrite `.detailOnly` when macOS temporarily collapses columns.
    @State private var splitViewVisibility = WorkspaceSplitViewVisibilityState()

    init(defaults: UserDefaults = .standard) {
        _hasCompletedOnboarding = AppStorage(
            wrappedValue: false,
            "interface.onboarding.completed",
            store: defaults
        )
    }

    var body: some View {
        Group {
            if !appModel.hasConnectedAccount || !hasCompletedOnboarding {
                OnboardingFlowView(
                    state: onboardingState,
                    actions: onboardingActions,
                    onComplete: { hasCompletedOnboarding = true }
                )
            } else {
                workspace
            }
        }
        .onChange(of: appModel.hasConnectedAccount) { _, hasConnectedAccount in
            if !hasConnectedAccount {
                hasCompletedOnboarding = false
            }
        }
        .onAppear {
            splitViewVisibility.restoreExplicitSidebarPreference(
                navigation.isSidebarVisible
            )
        }
        .onChange(of: navigation.section) { _, section in
            workspaceAccessibility.sidebarSelectionChanged(to: section)
        }
        .onChange(of: appModel.selectedWorkItemID) { previousID, workItemID in
            guard workItemID != nil, workItemID != previousID else { return }
            workspaceAccessibility.workItemSelectionChanged()
        }
        .onChange(of: presentation.synchronizationStatus) { previousStatus, status in
            guard status != previousStatus else { return }
            workspaceAccessibility.synchronizationStatusChanged(to: status)
        }
        .onChange(of: appModel.refreshError) { previousError, error in
            guard error != nil, error != previousError else { return }
            workspaceAccessibility.refreshFailed()
        }
        .onChange(of: appModel.workspaceRestorationError) { previousError, error in
            guard error != nil, error != previousError else { return }
            workspaceAccessibility.workspaceRestorationUnavailable()
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                switch phase {
                case .active:
                    await appModel.applicationDidBecomeActive()
                    if appModel.ssoAuthorizationHeader != nil {
                        await appModel.recheckSelectedOrganizationAccess()
                    }
                case .background:
                    await appModel.scheduleOpportunisticBackgroundRefresh()
                default:
                    break
                }
            }
        }
    }

    private var workspace: some View {
            NavigationSplitView(columnVisibility: splitViewColumnVisibility) {
                WorkspaceSidebar(
                    accounts: appModel.accounts,
                    organizations: appModel.organizations,
                    presentation: presentation,
                    onSelectAccount: { appModel.selectAccount($0) },
                    onSelectOrganization: { appModel.selectOrganization($0) },
                    selection: $navigation.section
                )
                    .navigationSplitViewColumnWidth(
                        min: CGFloat(WorkspaceSplitLayout.sidebarMinimumWidth),
                        ideal: CGFloat(navigation.workspaceSidebarWidth),
                        max: CGFloat(WorkspaceSplitLayout.sidebarMaximumWidth)
                    )
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: WorkspaceSidebarWidthPreferenceKey.self,
                                value: proxy.size.width
                            )
                        }
                    }
            } content: {
                workspaceQueue
                    .navigationSplitViewColumnWidth(
                        min: CGFloat(WorkspaceSplitLayout.contentMinimumWidth),
                        ideal: CGFloat(navigation.workspaceContentWidth),
                        max: CGFloat(WorkspaceSplitLayout.contentMaximumWidth)
                    )
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: WorkspaceContentWidthPreferenceKey.self,
                                value: proxy.size.width
                            )
                        }
                    }
            } detail: {
                WorkDetailView(item: appModel.selectedWorkItem)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationSplitViewStyle(.balanced)
            .onPreferenceChange(WorkspaceSidebarWidthPreferenceKey.self) { width in
                navigation.recordWorkspaceSidebarWidth(Double(width))
            }
            .onPreferenceChange(WorkspaceContentWidthPreferenceKey.self) { width in
                navigation.recordWorkspaceContentWidth(Double(width))
            }
            .focusedSceneValue(\.triageSidebarVisibility, sidebarVisibilityBinding)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        setSidebarVisibility(!splitViewVisibility.isSidebarPresented)
                    } label: {
                        Label(
                            splitViewVisibility.isSidebarPresented ? "Hide Sidebar" : "Show Sidebar",
                            systemImage: "sidebar.left"
                        )
                    }
                    .help(splitViewVisibility.isSidebarPresented ? "Hide Sidebar" : "Show Sidebar")
                    .accessibilityLabel(splitViewVisibility.isSidebarPresented ? "Hide Sidebar" : "Show Sidebar")
                    .accessibilityHint("Shows or hides the navigation sidebar in this window.")
                }
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        navigateSelectionBack()
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .disabled(!canNavigateSelectionBack)
                    .help("Previous work item")
                    .accessibilityHint("Moves to the previous work item in this organization.")

                    Button {
                        navigateSelectionForward()
                    } label: {
                        Label("Forward", systemImage: "chevron.forward")
                    }
                    .disabled(!canNavigateSelectionForward)
                    .help("Next work item")
                    .accessibilityHint("Moves to the next work item in this organization.")
                }
                if splitViewVisibility.shouldShowPrincipalOrganizationTitle,
                   let organization = appModel.selectedOrganization {
                    ToolbarItem(placement: .principal) {
                        Text(organization.displayName ?? organization.login)
                            .lineLimit(1)
                            .accessibilityLabel("Selected organization \(organization.displayName ?? organization.login)")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await appModel.refreshSelectedOrganizationAfterAccessCheck()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(appModel.selectedOrganization == nil || appModel.isRefreshing)
                    .help("Refresh GitHub Work")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let localAccountRecovery = localAccountRecovery ?? accountRecoveryBeingRetried {
                    LocalAccountRecoveryNotice(
                        recovery: localAccountRecovery,
                        isRetrying: appModel.isRestoringAccounts,
                        onOpenAccountSettings: openAccountSettings,
                        onRetry: { recovery in
                            Task {
                                await retryLocalAccountRestoration(recovery)
                            }
                        }
                    )
                }
            }
    }

    private var splitViewColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { splitViewVisibility.visibility },
            set: { visibility in
                splitViewVisibility.receiveSystemVisibility(visibility)
            }
        )
    }

    private var sidebarVisibilityBinding: Binding<Bool> {
        Binding(
            get: { splitViewVisibility.isSidebarPresented },
            set: { setSidebarVisibility($0) }
        )
    }

    private func setSidebarVisibility(_ isVisible: Bool) {
        navigation.isSidebarVisible = isVisible
        splitViewVisibility.applyExplicitSidebarPreference(isVisible)
    }

    private var validWorkItemIDs: Set<WorkItemID> {
        Set(appModel.workItems.map(\.id))
    }

    private var canNavigateSelectionBack: Bool {
        navigation.canNavigateSelectionBack(
            accountID: appModel.selectedAccountID,
            organizationID: appModel.selectedOrganizationID,
            validWorkItemIDs: validWorkItemIDs
        )
    }

    private var canNavigateSelectionForward: Bool {
        navigation.canNavigateSelectionForward(
            accountID: appModel.selectedAccountID,
            organizationID: appModel.selectedOrganizationID,
            validWorkItemIDs: validWorkItemIDs
        )
    }

    private func navigateSelectionBack() {
        guard let workItemID = navigation.navigateSelectionBack(
            accountID: appModel.selectedAccountID,
            organizationID: appModel.selectedOrganizationID,
            validWorkItemIDs: validWorkItemIDs
        ) else { return }
        appModel.selectedWorkItemID = workItemID
    }

    private func navigateSelectionForward() {
        guard let workItemID = navigation.navigateSelectionForward(
            accountID: appModel.selectedAccountID,
            organizationID: appModel.selectedOrganizationID,
            validWorkItemIDs: validWorkItemIDs
        ) else { return }
        appModel.selectedWorkItemID = workItemID
    }

    @ViewBuilder
    private var workspaceQueue: some View {
        if presentation.shouldPresentUnavailableQueue {
            WorkspaceQueueUnavailableView(
                title: "Local work is unavailable",
                systemImage: "externaldrive.badge.exclamationmark",
                description: "Triage could not load local work for this organization. Try synchronizing again.",
                actionTitle: "Try Again",
                isPerformingAction: isRetryingUnavailableWorkspace || appModel.isRefreshing,
                action: retryUnavailableWorkspace
            )
        } else {
        switch presentation.synchronizationStatus {
        case .noOrganization:
            WorkspaceQueueUnavailableView(
                title: "Choose an organization",
                systemImage: "building.2",
                description: "Select an organization in the sidebar to view its local work queue."
            )
        case .initialSynchronization:
            WorkspaceQueueUnavailableView(
                title: "Synchronize your work",
                systemImage: "arrow.triangle.2.circlepath",
                description: "Triage has not created a local work queue for this organization yet.",
                actionTitle: "Synchronize Now",
                action: refreshSelectedOrganization
            )
        default:
            WorkListView(
                workspaceStatus: presentation.synchronizationStatus,
                workspaceStatusDetail: presentation.synchronizationDetail
            )
        }
        }
    }

    private func refreshSelectedOrganization() {
        Task {
            await appModel.refreshSelectedOrganizationAfterAccessCheck()
        }
    }

    private func retryUnavailableWorkspace() {
        guard !isRetryingUnavailableWorkspace, !appModel.isRefreshing else { return }
        let accountID = appModel.selectedAccountID
        let organizationID = appModel.selectedOrganizationID
        isRetryingUnavailableWorkspace = true
        workspaceAccessibility.workspaceRestorationRetryStarted()
        Task {
            await appModel.refreshSelectedOrganizationAfterAccessCheck()
            guard appModel.selectedAccountID == accountID,
                  appModel.selectedOrganizationID == organizationID
            else {
                isRetryingUnavailableWorkspace = false
                return
            }
            if appModel.workspaceRestorationError == nil {
                workspaceAccessibility.workspaceRestorationRetrySucceeded()
            } else {
                workspaceAccessibility.workspaceRestorationRetryFailed()
            }
            isRetryingUnavailableWorkspace = false
        }
    }

    private var presentation: WorkspacePresentationState {
        WorkspacePresentationState(
            workItems: appModel.workItems,
            selectedAccountID: appModel.selectedAccountID,
            selectedOrganizationID: appModel.selectedOrganizationID,
            organizationAccess: appModel.selectedOrganizationAccess,
            hasSSOAuthorizationHeader: appModel.ssoAuthorizationHeader != nil,
            isRefreshing: appModel.isRefreshing,
            refreshError: appModel.refreshError,
            workspaceFreshness: appModel.selectedOrganizationFreshness,
            workspaceCoverage: appModel.selectedWorkspaceCoverage,
            organizationVisibilityFreshness: appModel.selectedOrganizationVisibilityFreshness,
            restorationError: appModel.workspaceRestorationError,
            now: Date()
        )
    }

    private var onboardingState: OnboardingPresentationState {
        OnboardingPresentationState(
            accounts: appModel.accounts,
            selectedAccountID: appModel.selectedAccountID,
            organizations: appModel.organizations,
            selectedOrganizationID: appModel.selectedOrganizationID,
            organizationAccess: appModel.selectedOrganizationAccess,
            isConnecting: appModel.isConnecting,
            isSynchronizing: appModel.isRefreshing,
            isRestoringAccounts: appModel.isRestoringAccounts,
            connectionError: appModel.connectionError,
            refreshError: appModel.refreshError,
            aiAccess: .unavailable(
                "Copilot analysis has not been enabled for this organization."
            ),
            localAccountRecovery: localAccountRecovery ?? accountRecoveryBeingRetried,
            hasSSOAuthorizationURL: {
                guard let ssoAuthorizationHeader = appModel.ssoAuthorizationHeader else {
                    return false
                }
                if case .authorizationRequired = ssoAuthorizationHeader {
                    return true
                }
                return false
            }()
        )
    }

    /// Converts model state to fixed UI copy so no Keychain, vault, or local
    /// filesystem error text can reach a visible recovery surface.
    private var localAccountRecovery: LocalAccountRecoveryPresentation? {
        guard appModel.restorationError != nil else { return nil }
        if !appModel.vaultRecoveryIssues.isEmpty {
            return .encryptedVaultNeedsRepair
        }
        return appModel.unavailableAccountIDs.isEmpty
            ? .encryptedLocalDataUnavailable
            : .unavailableVaultKey
    }

    private func retryLocalAccountRestoration(
        _ recovery: LocalAccountRecoveryPresentation
    ) async {
        guard !appModel.isRestoringAccounts else { return }
        accountRecoveryBeingRetried = recovery
        workspaceAccessibility.accountRestorationRetryStarted()
        await appModel.restoreAccounts()
        if appModel.restorationError == nil {
            workspaceAccessibility.accountRestorationRetrySucceeded()
        } else {
            workspaceAccessibility.accountRestorationRetryFailed()
        }
        accountRecoveryBeingRetried = nil
    }

    private func openAccountSettings() {
        navigation.openSettings(.accounts)
        openSettings()
    }

    private var onboardingActions: OnboardingActions {
        OnboardingActions(
            beginOAuth: {
                guard let window = NSApp.keyWindow else {
                    appModel.recordConnectionWindowError()
                    return
                }
                await appModel.connectGitHub(presentationAnchor: window)
            },
            submitPersonalAccessToken: { token, organization in
                await appModel.connectPersonalAccessToken(
                    token,
                    resourceOwnerOrganization: organization
                )
                return appModel.connectionError == nil
            },
            selectOrganization: { appModel.selectOrganization($0) },
            authorizeSSO: {
                guard let header = appModel.ssoAuthorizationHeader else { return }
                _ = SSOAuthorizationCoordinator().authorizeInBrowser(header)
            },
            retryAccessCheck: {
                await appModel.recheckSelectedOrganizationAccess()
            },
            beginInitialSynchronization: {
                await appModel.refreshSelectedOrganizationAfterAccessCheck()
            },
            openNotificationSettings: {
                navigation.openSettings(.notifications)
                openSettings()
            },
            recordAIConsent: { isEnabled in
                Task { await appModel.recordSelectedOrganizationAIConsent(isEnabled) }
            },
            openAccountSettings: {
                openAccountSettings()
            },
            retryLocalAccountRestoration: {
                guard let recovery = localAccountRecovery ?? accountRecoveryBeingRetried else { return }
                await retryLocalAccountRestoration(recovery)
            }
        )
    }
}

private struct LocalAccountRecoveryNotice: View {
    let recovery: LocalAccountRecoveryPresentation
    let isRetrying: Bool
    let onOpenAccountSettings: () -> Void
    let onRetry: (LocalAccountRecoveryPresentation) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Label(recovery.title, systemImage: recovery.systemImage)
                .font(.headline)
                .foregroundStyle(.orange)
            Text(recovery.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if recovery.canOpenAccountSettings {
                Button("Open Account Settings…", action: onOpenAccountSettings)
            }
            if isRetrying {
                ProgressView("Retrying encrypted local account data…")
                    .controlSize(.small)
                    .accessibilityLabel("Retrying encrypted local account data")
            } else {
                Button("Try Again") { onRetry(recovery) }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(recovery.accessibilityLabel)
        .accessibilityHint(
            isRetrying
                ? "Encrypted local account restoration is in progress."
                : "Try restoring encrypted local account data again."
        )
    }
}

private struct WorkspaceQueueUnavailableView: View {
    let title: String
    let systemImage: String
    let description: String
    var actionTitle: String?
    var isPerformingAction = false
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            if let actionTitle, let action {
                if isPerformingAction {
                    ProgressView("Retrying local work…")
                        .controlSize(.small)
                        .accessibilityLabel("Retrying local work")
                } else {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Creates or updates the local work queue for this organization.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

struct PersonalAccessTokenSheet: View {
    @Environment(\.dismiss) private var dismiss
    let account: GitHubAccount?
    let isSubmitting: Bool
    let error: String?
    let onSubmit: @MainActor (_ token: String, _ resourceOwnerOrganization: String?) async -> Bool
    let onCancel: @MainActor () -> Void
    @State private var tokenInput = ""
    @State private var resourceOwnerOrganization = ""
    @State private var hasSubmitted = false

    init(
        account: GitHubAccount? = nil,
        isSubmitting: Bool,
        error: String?,
        onSubmit: @escaping @MainActor (_ token: String, _ resourceOwnerOrganization: String?) async -> Bool,
        onCancel: @escaping @MainActor () -> Void = {}
    ) {
        self.account = account
        self.isSubmitting = isSubmitting
        self.error = error
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    private var tokenKind: PersonalAccessTokenKind? {
        try? PersonalAccessToken(rawValue: tokenInput).kind
    }

    private var needsResourceOwner: Bool {
        account == nil && tokenKind == .fineGrained
    }

    private var canConnect: Bool {
        tokenKind != nil && (!needsResourceOwner || !resourceOwnerOrganization.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(account == nil ? "Connect a Personal Access Token" : "Replace Personal Access Token")
                .font(.title2.weight(.semibold))
            Text(
                account == nil
                    ? "Triage stores the token only in your macOS Keychain and uses GitHub read APIs."
                    : "Triage validates that the new token belongs to this GitHub account before replacing the Keychain credential."
            )
                .foregroundStyle(.secondary)
            SecureField("GitHub personal access token", text: $tokenInput)
                .textFieldStyle(.roundedBorder)
            if needsResourceOwner {
                TextField("Resource owner organization", text: $resourceOwnerOrganization)
                    .textFieldStyle(.roundedBorder)
                Text("Fine-grained tokens may not appear in your organization list. Enter the organization selected when you created this token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Use a fine-grained token when possible. Classic tokens should include `repo` and `read:org`; Copilot requires a separate sign-in for classic tokens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Do not surface a prior OAuth/reconnect error in this independent
            // PAT flow. Once submitted, the shared model error belongs here.
            if hasSubmitted, let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    tokenInput = ""
                    dismiss()
                    onCancel()
                }
                Button(account == nil ? "Connect" : "Replace") {
                    let token = tokenInput
                    let organization = needsResourceOwner ? resourceOwnerOrganization : nil
                    hasSubmitted = true
                    tokenInput = ""
                    Task {
                        if await onSubmit(token, organization) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canConnect || isSubmitting)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
