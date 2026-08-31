import SwiftUI

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var softwareUpdates: SoftwareUpdateController
    @EnvironmentObject private var appModel: TriageAppModel
    @State private var accountReplacingToken: GitHubAccount?
    @State private var accountPendingRemoval: GitHubAccount?
    @State private var accountRemovalError: String?

    var body: some View {
        TabView(selection: selectedCategory) {
            settingsPage(.accounts) { accountsSettings }
            settingsPage(.organizations) { organizationSettings }
            settingsPage(.inbox) { inboxSettings }
            settingsPage(.notifications) { notificationSettings }
            settingsPage(.ai) { aiSettings }
            settingsPage(.general) { generalSettings }
            settingsPage(.updates) { updateSettings }
            settingsPage(.about) { aboutSettings }
        }
        .tabViewStyle(.sidebarAdaptable)
        .navigationTitle("Settings")
        .onAppear {
            preferences.refreshLaunchAtLoginStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            preferences.refreshLaunchAtLoginStatus()
        }
        .sheet(
            item: $accountReplacingToken,
            onDismiss: {
                guard !appModel.isConnecting else { return }
                Task {
                    await appModel.resumeSelectedOrganization()
                }
            }
        ) { account in
            PersonalAccessTokenSheet(
                account: account,
                isSubmitting: appModel.isConnecting,
                error: appModel.connectionError,
                onSubmit: { token, _ in
                    await appModel.replacePersonalAccessToken(token, for: account)
                    return appModel.connectionError == nil
                },
                onCancel: {
                    Task {
                        await appModel.resumeSelectedOrganization()
                    }
                }
            )
        }
        .confirmationDialog(
            removalConfirmationTitle,
            isPresented: Binding(
                get: { accountPendingRemoval != nil },
                set: { if !$0 { accountPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Account and Data", role: .destructive) {
                removePendingAccount()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                accountPendingRemoval = nil
            }
            .keyboardShortcut(.cancelAction)
        } message: {
            Text(removalConfirmationMessage)
        }
        .alert(
            "Triage could not remove this account",
            isPresented: Binding(
                get: { accountRemovalError != nil },
                set: { if !$0 { accountRemovalError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                accountRemovalError = nil
            }
        } message: {
            Text(accountRemovalError ?? "Try again after resolving any listed account or storage issue.")
        }
    }

    private var selectedCategory: Binding<SettingsCategory> {
        Binding(
            get: { navigation.settingsCategory },
            set: { navigation.settingsCategory = $0 }
        )
    }

    private func settingsPage<Content: View>(
        _ category: SettingsCategory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(categoryTitle(category))
                        .font(.largeTitle.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(categorySubtitle(for: category))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                content()
            }
            .scenePadding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .tabItem { Label(categoryTitle(category), systemImage: category.systemImage) }
        .tag(category)
    }

    private func categoryTitle(_ category: SettingsCategory) -> String {
        category == .ai ? "AI" : category.title
    }

    private func categorySubtitle(for category: SettingsCategory) -> String {
        switch category {
        case .accounts: "Manage GitHub identities and encrypted local account data."
        case .organizations: "Review organization access, capabilities, and synchronization coverage."
        case .inbox: "Control the local workflow rules that organize your work."
        case .notifications: "Choose which actionable changes can notify you."
        case .ai: "Copilot analysis is optional and enabled per organization."
        case .general: "Choose how Triage integrates with macOS."
        case .updates: "Keep Triage current through signed, verified updates."
        case .about: "Review this installation and its privacy baseline."
        }
    }

    private var accountsSettings: some View {
        SettingsCard(title: "Connected Accounts") {
            if appModel.accounts.isEmpty {
                Text("No GitHub accounts are connected.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appModel.accounts) { account in
                    SettingsValueRow(
                        title: account.login,
                        detail: account.authenticationKind.title,
                        systemImage: "person.crop.circle"
                    ) {
                        HStack(spacing: 10) {
                            Text(credentialStatusTitle(account.credentialStatus))
                                .foregroundStyle(.secondary)
                            accountCredentialAction(for: account)
                            Button("Remove…", role: .destructive) {
                                accountPendingRemoval = account
                            }
                            .disabled(appModel.isConnecting)
                            .accessibilityHint(
                                "Removes this account, its credentials, and encrypted local Triage data from this Mac. It does not change GitHub."
                            )
                        }
                    }
                }
            }
            if let error = appModel.connectionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let notice = appModel.credentialActionNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func accountCredentialAction(for account: GitHubAccount) -> some View {
        switch account.authenticationKind {
        case .oauth:
            Button("Reconnect") {
                guard let window = NSApp.keyWindow else {
                    appModel.recordConnectionWindowError()
                    return
                }
                appModel.selectAccount(account.id, activatesOrganization: false)
                Task {
                    await appModel.reconnectGitHub(account: account, presentationAnchor: window)
                }
            }
            .disabled(appModel.isConnecting)
        case .fineGrainedPersonalAccessToken, .classicPersonalAccessToken:
            Button("Replace Token") {
                appModel.selectAccount(account.id, activatesOrganization: false)
                accountReplacingToken = account
            }
            .disabled(appModel.isConnecting)
        }
    }

    private var organizationSettings: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Organizations") {
                if appModel.organizations.isEmpty {
                    Text("Connect an account to discover organizations.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appModel.organizations) { organization in
                        SettingsValueRow(
                            title: organization.displayName ?? organization.login,
                            detail: organization.login,
                            systemImage: "building.2"
                        ) {
                            if organization.id == appModel.selectedOrganizationID {
                                Text("Current")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let access = appModel.selectedOrganizationAccess {
                SettingsCard(title: "Access and Coverage") {
                    SettingsValueRow(
                        title: "Organization access",
                        detail: access.checkedAt.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "checkmark.shield"
                    ) {
                        Text(organizationAccessTitle(access.state))
                            .foregroundStyle(
                                access.state == .available ? Color.secondary : Color.orange
                            )
                    }

                    let capabilities = access.capabilities.sorted {
                        $0.capability.rawValue < $1.capability.rawValue
                    }
                    if !capabilities.isEmpty {
                        SettingsDivider()
                        ForEach(capabilities, id: \.capability) { capability in
                            SettingsValueRow(
                                title: capabilityTitle(capability.capability),
                                detail: capability.detail ?? "No additional detail is available.",
                                systemImage: "slider.horizontal.3"
                            ) {
                                Text(capabilityStatusTitle(capability.status))
                                    .foregroundStyle(capabilityTint(capability.status))
                            }
                        }
                    }
                }
            } else if appModel.selectedOrganization != nil {
                SettingsCard(title: "Access and Coverage") {
                    Label(
                        "Triage has not verified access for the selected organization yet. Refresh GitHub work to check available coverage.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var inboxSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Attention") {
                SettingsValueRow(
                    title: "Stale progress",
                    detail: "Owned work becomes stale after three business days without qualifying progress.",
                    systemImage: "clock.badge.exclamationmark"
                ) {
                    Text("3 days")
                        .foregroundStyle(.secondary)
                }
            }
            Label(
                "Triage workflow choices are stored locally and never modify GitHub.",
                systemImage: "lock"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Local workflow only. Triage workflow choices never modify GitHub.")
        }
    }

    private var notificationSettings: some View {
        SettingsCard(title: "Notifications") {
            Text("Notifications are quiet by default and never change GitHub notification state.")
                .foregroundStyle(.secondary)
        }
    }

    private var aiSettings: some View {
        SettingsCard(title: "Copilot") {
            SettingsValueRow(
                title: "Organization consent",
                detail: "Copilot analysis remains disabled until you explicitly enable it for an organization.",
                systemImage: "sparkles"
            ) {
                Text("Not enabled")
                    .foregroundStyle(.secondary)
            }
            if let capabilities = appModel.selectedAccountCapabilities {
                SettingsDivider()
                SettingsValueRow(
                    title: "Copilot entitlement",
                    detail: "Availability is checked separately from GitHub work synchronization.",
                    systemImage: "checkmark.shield"
                ) {
                    Text(capabilityStatusTitle(capabilities.status(for: .copilot)))
                        .foregroundStyle(capabilityTint(capabilities.status(for: .copilot)))
                }
            }
        }
    }

    private var generalSettings: some View {
        SettingsCard(title: "App") {
            SettingsToggleRow(
                title: "Show Triage in the menu bar",
                detail: "Keep Triage available without leaving the main window open.",
                systemImage: "menubar.rectangle",
                isOn: $preferences.showMenuBarExtra
            )
            SettingsDivider()
            SettingsToggleRow(
                title: "Launch at login",
                detail: "Make Triage available as soon as you sign in.",
                systemImage: "power",
                isOn: Binding(
                    get: { preferences.launchAtLoginEnabled },
                    set: { preferences.setLaunchAtLogin($0) }
                )
            )
            if let error = preferences.launchAtLoginError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 42)
            }
        }
    }

    private var updateSettings: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Automatic Updates") {
                SettingsToggleRow(
                    title: "Automatically check for updates",
                    detail: "Securely check the signed Triage release feed in the background.",
                    systemImage: "arrow.triangle.2.circlepath",
                    isOn: Binding(
                        get: { softwareUpdates.automaticallyChecksForUpdates },
                        set: { softwareUpdates.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                if softwareUpdates.automaticallyChecksForUpdates {
                    SettingsDivider()
                    SettingsValueRow(
                        title: "Check frequency",
                        detail: "How often Triage checks the signed update feed.",
                        systemImage: "calendar.badge.clock"
                    ) {
                        Picker(
                            "Frequency",
                            selection: Binding(
                                get: { softwareUpdates.updateCheckInterval },
                                set: { softwareUpdates.setUpdateCheckInterval($0) }
                            )
                        ) {
                            ForEach(AppUpdateCheckInterval.allCases) { interval in
                                Text(interval.title).tag(interval)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 110)
                    }
                    if softwareUpdates.allowsAutomaticUpdates {
                        SettingsDivider()
                        SettingsToggleRow(
                            title: "Download updates automatically",
                            detail: "Prepare verified updates so they are ready when you quit Triage.",
                            systemImage: "arrow.down.circle",
                            isOn: Binding(
                                get: { softwareUpdates.automaticallyDownloadsUpdates },
                                set: { softwareUpdates.setAutomaticallyDownloadsUpdates($0) }
                            )
                        )
                    }
                }
            }

            SettingsCard(title: "Current Version") {
                SettingsActionRow(
                    title: metadata.displayVersion,
                    detail: "Updates are signed and verified by Sparkle before installation.",
                    systemImage: "app.badge.checkmark"
                ) {
                    Button("Check Now") {
                        softwareUpdates.checkForUpdates()
                    }
                    .disabled(!softwareUpdates.canCheckForUpdates)
                }
            }
        }
    }

    private var aboutSettings: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Triage") {
                SettingsValueRow(
                    title: "Version \(metadata.displayVersion)",
                    detail: "A native macOS 26 application.",
                    systemImage: "app.badge.checkmark"
                ) {
                    Text(metadata.bundleIdentifier)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard(title: "Privacy") {
                SettingsValueRow(
                    title: "Private by default",
                    detail: "Triage declares no tracking and collects no data.",
                    systemImage: "hand.raised"
                ) {
                    Label("No Data", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var metadata: AppMetadata {
        AppMetadata()
    }

    private var removalConfirmationTitle: String {
        guard let account = accountPendingRemoval else { return "Remove account?" }
        return "Remove \(account.login)?"
    }

    private var removalConfirmationMessage: String {
        guard let account = accountPendingRemoval else {
            return "This removes the account and its encrypted local data from this Mac."
        }
        return "This removes \(account.login), its credentials, and all encrypted local Triage data from this Mac. GitHub content is not changed."
    }

    private func removePendingAccount() {
        guard let account = accountPendingRemoval else { return }
        accountPendingRemoval = nil
        Task {
            do {
                try await appModel.removeAccount(account.id)
            } catch {
                accountRemovalError = "The account and its encrypted local data were not removed. \(error.localizedDescription)"
            }
        }
    }

    private func credentialStatusTitle(_ status: CredentialStatus) -> String {
        switch status {
        case .active: "Active"
        case .expiring: "Expiring"
        case .expired: "Expired"
        case .revoked: "Revoked"
        case .missing: "Missing"
        case .capabilityLimited: "Limited"
        }
    }

    private func organizationAccessTitle(_ state: OrganizationAccessState) -> String {
        switch state {
        case .available: "Available"
        case .ssoAuthorizationRequired: "SSO required"
        case .partialSSOAuthorization: "Partial SSO"
        case .organizationApprovalRequired: "Approval required"
        case .oauthApplicationApprovalRequired: "OAuth approval"
        case .organizationPolicyBlocked: "Blocked by policy"
        case .insufficientPermission: "Insufficient access"
        case .inaccessible: "Inaccessible"
        case .credentialExpired: "Credential expired"
        case .unknown: "Not verified"
        }
    }

    private func capabilityTitle(_ capability: GitHubCapability) -> String {
        switch capability {
        case .privateRepositories: "Private repositories"
        case .visibleTeams: "Visible teams"
        case .issueAndPullRequestSearch: "Issue and PR search"
        case .pullRequestReviews: "Pull request reviews"
        case .pullRequestReviewThreads: "Review threads"
        case .issueTimeline: "Issue timeline"
        case .discussions: "Discussions"
        case .projects: "Projects"
        case .projectFields: "Project fields"
        case .notifications: "Notifications"
        case .copilot: "Copilot"
        case .copilotModels: "Copilot models"
        }
    }

    private func capabilityStatusTitle(_ status: CapabilityStatus) -> String {
        switch status {
        case .available: "Available"
        case .unavailable: "Unavailable"
        case .unknown: "Not verified"
        case .requiresSSO: "SSO required"
        case .requiresApproval: "Approval required"
        case .notApplicable: "Not applicable"
        }
    }

    private func capabilityTint(_ status: CapabilityStatus) -> Color {
        switch status {
        case .available: .secondary
        case .unavailable, .notApplicable, .unknown: .secondary
        case .requiresSSO, .requiresApproval: .orange
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                content
            }
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 42)
    }
}

private struct SettingsRowDescription: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsValueRow<Control: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let control: Control

    init(
        title: String,
        detail: String,
        systemImage: String,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 14) {
            SettingsRowDescription(title: title, detail: detail, systemImage: systemImage)
            control
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct SettingsActionRow<Control: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let control: Control

    init(
        title: String,
        detail: String,
        systemImage: String,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.control = control()
    }

    var body: some View {
        SettingsValueRow(title: title, detail: detail, systemImage: systemImage) {
            control
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsValueRow(title: title, detail: detail, systemImage: systemImage) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}
