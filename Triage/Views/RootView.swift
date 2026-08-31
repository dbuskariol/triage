import AppKit
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var appModel: TriageAppModel
    @EnvironmentObject private var workspaceAccessibility: WorkspaceAccessibilityCoordinator
    @AppStorage("interface.onboarding.completed") private var hasCompletedOnboarding = false

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
            NavigationSplitView(columnVisibility: sidebarVisibility) {
                WorkspaceSidebar(
                    accounts: appModel.accounts,
                    organizations: appModel.organizations,
                    presentation: presentation,
                    onSelectAccount: { appModel.selectAccount($0) },
                    onSelectOrganization: { appModel.selectOrganization($0) },
                    selection: $navigation.section
                )
                    .navigationSplitViewColumnWidth(min: 200, ideal: 218, max: 260)
            } content: {
                workspaceQueue
                    .navigationSplitViewColumnWidth(min: 320, ideal: 390, max: 520)
            } detail: {
                WorkDetailView(item: appModel.selectedWorkItem)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        navigation.isSidebarVisible.toggle()
                    } label: {
                        Label(
                            navigation.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                            systemImage: "sidebar.left"
                        )
                    }
                    .help(navigation.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                    .accessibilityLabel(navigation.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
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
                if !navigation.isSidebarVisible, let organization = appModel.selectedOrganization {
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
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { navigation.isSidebarVisible ? .all : .doubleColumn },
            set: { navigation.isSidebarVisible = $0 == .all }
        )
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
            WorkListView()
        }
    }

    private func refreshSelectedOrganization() {
        Task {
            await appModel.refreshSelectedOrganizationAfterAccessCheck()
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
            connectionError: appModel.connectionError,
            refreshError: appModel.refreshError,
            aiAccess: .unavailable(
                "Copilot analysis has not been enabled for this organization."
            )
        )
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
            recordAIConsent: { _ in }
        )
    }
}

private struct WorkspaceQueueUnavailableView: View {
    let title: String
    let systemImage: String
    let description: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Creates or updates the local work queue for this organization.")
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
            if let error {
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
