import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var softwareUpdates: SoftwareUpdateController
    @EnvironmentObject private var appModel: TriageAppModel

    @State private var isPresentingAccountAddition = false
    @State private var isPresentingTokenSheet = false
    @State private var token = ""
    @State private var resourceOwnerOrganization = ""
    @State private var accountPendingRemoval: GitHubAccount?
    @State private var removalError: String?

    var body: some View {
        NavigationSplitView {
            List(supportedCategories, selection: Binding(
                get: { navigation.settingsCategory },
                set: { if let category = $0 { navigation.settingsCategory = category } }
            )) { category in
                Label(categoryTitle(category), systemImage: category.systemImage)
                    .tag(category)
            }
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(categoryTitle(navigation.settingsCategory))
                        .font(.largeTitle.weight(.bold))
                    selectedPage
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog(
            "Add a GitHub Account",
            isPresented: $isPresentingAccountAddition,
            titleVisibility: .visible
        ) {
            Button("Continue with GitHub") { connectWithGitHub() }
            Button("Use a Personal Access Token") { isPresentingTokenSheet = true }
        } message: {
            Text("Connect another GitHub account for a local Triage workspace.")
        }
        .sheet(isPresented: $isPresentingTokenSheet) {
            tokenSheet
        }
        .confirmationDialog(
            "Remove \(accountPendingRemoval?.login ?? "account")?",
            isPresented: Binding(
                get: { accountPendingRemoval != nil },
                set: { if !$0 { accountPendingRemoval = nil } }
            )
        ) {
            Button("Remove Account and Local Data", role: .destructive) {
                removePendingAccount()
            }
        } message: {
            Text("This removes credentials and encrypted local Triage data from this Mac. It never changes GitHub.")
        }
        .alert("Triage could not remove this account", isPresented: Binding(
            get: { removalError != nil },
            set: { if !$0 { removalError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalError ?? "")
        }
        .onAppear {
            preferences.refreshLaunchAtLoginStatus()
        }
    }

    private var supportedCategories: [SettingsCategory] {
        [.accounts, .organizations, .ai, .rules, .general, .updates, .about]
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch navigation.settingsCategory {
        case .accounts: accountsPage
        case .organizations: organizationsPage
        case .ai: aiPage
        case .rules: RulesSettingsView()
        case .general: generalPage
        case .updates: updatesPage
        case .about: aboutPage
        default: EmptyView()
        }
    }

    private var accountsPage: some View {
        SettingsSection("Connected Accounts") {
            Button("Add Account…") { isPresentingAccountAddition = true }
                .disabled(appModel.isConnecting)
            if appModel.accounts.isEmpty {
                Text("No GitHub accounts are connected.")
                    .foregroundStyle(.secondary)
            }
            ForEach(appModel.accounts) { account in
                HStack {
                    VStack(alignment: .leading) {
                        Text(account.login)
                        Text(account.authenticationKind.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Use") { appModel.selectAccount(account.id) }
                    Button("Remove…", role: .destructive) {
                        accountPendingRemoval = account
                    }
                    .disabled(appModel.isRemovingAccount(account.id))
                }
            }
            if !appModel.unavailableAccountIDs.isEmpty || !appModel.vaultRecoveryIssues.isEmpty {
                Label(
                    appModel.restorationError ?? "Some encrypted local account data needs recovery.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                Button("Try Again") { Task { await appModel.restoreAccounts() } }
            }
            if let error = appModel.connectionError {
                errorLabel(error)
            }
        }
    }

    private var organizationsPage: some View {
        SettingsSection("Organizations") {
            if appModel.organizations.isEmpty {
                Text("Connect a GitHub account to discover organizations.")
                    .foregroundStyle(.secondary)
            }
            ForEach(appModel.organizations) { organization in
                HStack {
                    VStack(alignment: .leading) {
                        Text(organization.displayName ?? organization.login)
                        Text(organization.login)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if organization.id == appModel.selectedOrganizationID {
                        Text("Current").foregroundStyle(.secondary)
                    } else {
                        Button("Select") { appModel.selectOrganization(organization.id) }
                    }
                }
            }
            Button("Refresh Now") { appModel.refreshNow() }
                .disabled(appModel.selectedOrganization == nil)
        }
    }

    private var aiPage: some View {
        SettingsSection("Copilot") {
            if let organization = appModel.selectedOrganization {
                let state = appModel.selectedOrganizationAISettings
                Toggle(
                    "Allow AI analysis for \(organization.displayName ?? organization.login)",
                    isOn: Binding(
                        get: { state?.consent.isEnabled ?? false },
                        set: { enabled in
                            Task { await appModel.recordSelectedOrganizationAIConsent(enabled) }
                        }
                    )
                )
                Text("Copilot reads your relevant issues and pull requests to prioritize them. It is review-only and never changes GitHub.")
                    .foregroundStyle(.secondary)

                Picker("Model", selection: Binding(
                    get: { state?.consent.selectedModelID ?? "auto" },
                    set: { id in
                        Task {
                            await appModel.selectSelectedOrganizationCopilotModel(
                                id == "auto" ? nil : id
                            )
                        }
                    }
                )) {
                    Text("Auto").tag("auto")
                    ForEach(state?.availableModels ?? []) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .disabled(state?.consent.isEnabled != true)

                runtimeControls
                HStack {
                    Text(state?.status ?? "Checking Copilot availability…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if appModel.isCopilotAuthenticationInProgress {
                        ProgressView()
                        Button("Cancel") { appModel.cancelSelectedCopilotAuthentication() }
                    } else {
                        Button("Connect Copilot") {
                            appModel.startSelectedCopilotAuthenticationAtUserRequest()
                        }
                        .disabled(state?.consent.isEnabled != true)
                    }
                }
                if let error = appModel.copilotAuthenticationError ?? appModel.copilotRuntimeOperationError {
                    errorLabel(error)
                }
            } else {
                Text("Select an organization before configuring Copilot.")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: appModel.selectedOrganizationID) {
            await appModel.refreshSelectedOrganizationAIStatus()
        }
    }

    @ViewBuilder
    private var runtimeControls: some View {
        switch appModel.selectedCopilotAuthorizationState.runtime {
        case .ready:
            Button("Remove Copilot Runtime", role: .destructive) {
                Task { await appModel.removeCopilotRuntimeAtUserRequest() }
            }
        case .corrupt:
            Button("Repair Copilot Runtime") {
                appModel.startCopilotRuntimeRepairAtUserRequest()
            }
        case .downloading, .verifying:
            HStack {
                ProgressView("Preparing Copilot runtime…")
                Button("Cancel") { appModel.cancelCopilotRuntimeOperation() }
            }
        case .missing, .unsupported:
            Button("Download Copilot Runtime") {
                appModel.startCopilotRuntimeAcquisitionAtUserRequest()
            }
            .disabled(appModel.isCopilotRuntimeOperationInProgress)
        }
    }

    private var generalPage: some View {
        SettingsSection("App") {
            Toggle("Show Triage in the menu bar", isOn: $preferences.showMenuBarExtra)
            Toggle("Launch at login", isOn: Binding(
                get: { preferences.launchAtLoginEnabled },
                set: { preferences.setLaunchAtLogin($0) }
            ))
        }
    }

    private var updatesPage: some View {
        SettingsSection("Automatic Updates") {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { softwareUpdates.automaticallyChecksForUpdates },
                set: { softwareUpdates.setAutomaticallyChecksForUpdates($0) }
            ))
            Button("Check Now") { softwareUpdates.checkForUpdates() }
                .disabled(!softwareUpdates.canCheckForUpdates)
        }
    }

    private var aboutPage: some View {
        SettingsSection("Triage") {
            Text("A native macOS 26 application.")
            Text("Triage is private by default and does not collect tracking data.")
                .foregroundStyle(.secondary)
        }
    }

    private func categoryTitle(_ category: SettingsCategory) -> String {
        category == .ai ? "AI" : category.title
    }

    private func connectWithGitHub() {
        guard let window = NSApp.keyWindow else {
            appModel.recordConnectionWindowError()
            return
        }
        Task { await appModel.connectGitHub(presentationAnchor: window) }
    }

    private func removePendingAccount() {
        guard let account = accountPendingRemoval else { return }
        accountPendingRemoval = nil
        Task {
            do {
                try await appModel.removeAccount(account.id)
            } catch {
                removalError = "The account and its encrypted local data were not removed. Try again."
            }
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
    }

    private var tokenSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Use a Personal Access Token")
                .font(.title2.weight(.semibold))
            SecureField("GitHub personal access token", text: $token)
            TextField("Resource owner organization (fine-grained token)", text: $resourceOwnerOrganization)
            if let error = appModel.connectionError {
                errorLabel(error)
            }
            HStack {
                Button("Cancel") { isPresentingTokenSheet = false }
                Spacer()
                Button("Connect") {
                    let submittedToken = token
                    let organization = resourceOwnerOrganization.isEmpty ? nil : resourceOwnerOrganization
                    token = ""
                    Task {
                        await appModel.connectPersonalAccessToken(
                            submittedToken,
                            resourceOwnerOrganization: organization
                        )
                        if appModel.connectionError == nil {
                            isPresentingTokenSheet = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(token.isEmpty || appModel.isConnecting)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
