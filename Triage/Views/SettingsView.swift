import SwiftUI

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var softwareUpdates: SoftwareUpdateController
    @EnvironmentObject private var appModel: TriageAppModel
    @State private var accountReplacingToken: GitHubAccount?

    var body: some View {
        VStack(spacing: 0) {
            settingsNavigation
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    pageHeader
                    categoryContent
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
    }

    private var settingsNavigation: some View {
        HStack(spacing: 6) {
            ForEach(SettingsCategory.allCases) { category in
                Button {
                    navigation.settingsCategory = category
                } label: {
                    Label(category.title, systemImage: category.systemImage)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .background(
                            navigation.settingsCategory == category
                                ? Color.accentColor.opacity(0.16)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(navigation.settingsCategory == category ? .primary : .secondary)
                .accessibilityAddTraits(
                    navigation.settingsCategory == category ? .isSelected : []
                )
                .help(category.title)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
        .background(.bar)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(navigation.settingsCategory.title)
                .font(.largeTitle.weight(.bold))
            Text(categorySubtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var categorySubtitle: String {
        switch navigation.settingsCategory {
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

    @ViewBuilder
    private var categoryContent: some View {
        switch navigation.settingsCategory {
        case .accounts:
            accountsSettings
        case .organizations:
            organizationSettings
        case .inbox:
            inboxSettings
        case .notifications:
            notificationSettings
        case .ai:
            aiSettings
        case .general:
            generalSettings
        case .updates:
            updateSettings
        case .about:
            aboutSettings
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
                            Text(account.credentialStatus.rawValue.capitalized)
                                .foregroundStyle(.secondary)
                            accountCredentialAction(for: account)
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
                        Text(organization.id == appModel.selectedOrganizationID ? "Current" : "")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var inboxSettings: some View {
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
    }

    private var notificationSettings: some View {
        SettingsCard(title: "Notifications") {
            Text("Notifications are quiet by default and never change GitHub notification state.")
                .foregroundStyle(.secondary)
        }
    }

    private var aiSettings: some View {
        SettingsCard(title: "Copilot") {
            Text("Copilot analysis is disabled until you explicitly enable it for an organization.")
                .foregroundStyle(.secondary)
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
