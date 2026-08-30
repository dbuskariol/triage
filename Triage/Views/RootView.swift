import AppKit
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var appModel: TriageAppModel
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
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, appModel.ssoAuthorizationHeader != nil else { return }
            Task {
                await appModel.recheckSelectedOrganizationAccess()
            }
        }
    }

    private var workspace: some View {
            NavigationSplitView {
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
                WorkListView()
                    .navigationSplitViewColumnWidth(min: 320, ideal: 390, max: 520)
            } detail: {
                WorkDetailView(item: appModel.selectedWorkItem)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar {
                ToolbarItem {
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

    private var presentation: WorkspacePresentationState {
        WorkspacePresentationState(
            workItems: appModel.workItems,
            selectedAccountID: appModel.selectedAccountID,
            selectedOrganizationID: appModel.selectedOrganizationID,
            organizationAccess: appModel.selectedOrganizationAccess,
            hasSSOAuthorizationHeader: appModel.ssoAuthorizationHeader != nil,
            isRefreshing: appModel.isRefreshing,
            refreshError: appModel.refreshError,
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
