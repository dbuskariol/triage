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
    @State private var isConfirmingReanalysis = false

    var body: some View {
        TabView(selection: Binding(
            get: { navigation.settingsCategory },
            set: { navigation.settingsCategory = $0 }
        )) {
            ForEach(SettingsCategory.allCases) { category in
                page(category)
                    .formStyle(.grouped)
                    // A fixed size per tab lets the Settings window resize to each page.
                    .frame(width: 720, height: Self.idealHeight(category))
                    .tabItem { Label(category.title, systemImage: category.systemImage) }
                    .tag(category)
            }
        }
        .scenePadding(.bottom)
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
        .confirmationDialog(
            "Re-analyze all work with Copilot?",
            isPresented: $isConfirmingReanalysis
        ) {
            Button("Re-analyze All") { appModel.reanalyzeAll() }
        } message: {
            Text("Copilot reviews every item again in the background. Current decisions stay visible until each is replaced.")
        }
        .alert("Triage could not remove this account", isPresented: Binding(
            get: { removalError != nil },
            set: { if !$0 { removalError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalError ?? "")
        }
        .environment(\.triageViewerLogin, appModel.selectedAccount?.login ?? "")
        .onAppear {
            preferences.refreshLaunchAtLoginStatus()
        }
    }

    @ViewBuilder
    private func page(_ category: SettingsCategory) -> some View {
        switch category {
        case .general: generalPage
        case .inbox: inboxPage
        case .notifications: NotificationSettingsPage()
        case .accounts: accountsPage
        case .ai: aiPage
        case .rules: RulesSettingsView()
        case .updates: updatesPage
        }
    }

    private static func idealHeight(_ category: SettingsCategory) -> CGFloat {
        switch category {
        case .general: 900
        case .inbox: 800
        case .notifications: 560
        case .accounts: 640
        case .ai: 860
        case .rules: 760
        case .updates: 460
        }
    }

    // MARK: General

    private var generalPage: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { preferences.launchAtLoginEnabled },
                    set: { preferences.setLaunchAtLogin($0) }
                ))
                if let error = preferences.launchAtLoginError {
                    errorLabel(error)
                }
                Toggle("Show in menu bar", isOn: $preferences.showMenuBarExtra)
                Picker("Show on launch", selection: $launchDestination) {
                    ForEach(LaunchDestination.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Startup")
            }

            Section {
                Picker("Show scroll bars", selection: Binding(
                    get: { scrollBars },
                    set: { scrollBars = $0; $0.apply() }
                )) {
                    ForEach(ScrollBarVisibility.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Use System Setting follows System Settings ▸ Appearance, which shows scroll bars all the time when a mouse is connected. Choose When Scrolling to keep them hidden until you scroll.")
            }

            Section {
                Picker("Check GitHub", selection: $preferences.refreshIntervalMinutes) {
                    ForEach(AppPreferences.refreshIntervalChoices, id: \.self) { minutes in
                        Text(AppPreferences.refreshIntervalTitle(minutes)).tag(minutes)
                    }
                }
                Toggle("Refresh when Triage becomes active", isOn: $preferences.refreshWhenActive)
                LabeledContent("Last refreshed") {
                    Text(relative(appModel.presentation.status.lastRefreshAt) ?? "Not yet")
                }
                LabeledContent("Next refresh") {
                    Text(nextRefreshText)
                }
                HStack {
                    Spacer()
                    Button("Refresh Now") { appModel.refreshNow() }
                        .disabled(appModel.selectedOrganization == nil)
                }
            } header: {
                Text("Refresh")
            } footer: {
                Text("Each refresh searches GitHub for work involving you, then Copilot re-checks only what changed. Shorter intervals use more GitHub API quota.")
            }

            PrivacySettingsSections()

            Section("Keyboard Shortcuts") {
                shortcut("Next or previous item", "↓ ↑  or  j k")
                shortcut("Mark done", "E  or  ⌫")
                shortcut("Snooze until tomorrow", "S")
                shortcut("Mark as read or unread", "U  or  ⇧⌘U")
                shortcut("Open on GitHub", "↩  or  ⌘O")
                shortcut("Briefing", "⌘0")
                shortcut("Switch section", "⌘1 – ⌘7")
                shortcut("Weekly Review", "⌘9")
                shortcut("Focus on the current list", "⇧⌘F")
                shortcut("Refresh", "⌘R")
            }
        }
    }

    private var nextRefreshText: String {
        if preferences.refreshIntervalMinutes == 0 { return "Manual only" }
        return relative(appModel.presentation.status.nextRefreshAt) ?? "After the current refresh"
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) {
            Text(keys).font(.body.monospaced()).foregroundStyle(.secondary)
        }
    }

    @AppStorage(TriagePreferenceKeys.launchDestination) private var launchDestination = LaunchDestination.inbox
    @State private var scrollBars = ScrollBarVisibility.current()

    // MARK: Inbox

    @AppStorage(TriagePreferenceKeys.laterTodayHours) private var laterTodayHours = 3
    @AppStorage(TriagePreferenceKeys.tomorrowHour) private var tomorrowHour = 9
    @AppStorage(TriagePreferenceKeys.autoDoneHandled) private var autoDoneHandled = true
    @AppStorage(TriagePreferenceKeys.markReadPolicy) private var markReadPolicy = MarkReadPolicy.afterDelay
    @AppStorage(TriagePreferenceKeys.followUpDays) private var followUpDays = TriagePreferenceKeys.defaultFollowUpDays
    @AppStorage(TriagePreferenceKeys.sortField) private var sortField = WorkspaceSortField.recommended
    @AppStorage(TriagePreferenceKeys.sortAscending) private var sortAscending = false

    private var inboxPage: some View {
        Form {
            Section {
                Picker("Sort lists by", selection: Binding(
                    get: { sortField },
                    set: { sortField = $0; sortAscending = $0.defaultAscending }
                )) {
                    ForEach(WorkspaceSortField.allCases) { Text($0.title).tag($0) }
                }
                Picker("Order", selection: $sortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .disabled(!sortField.supportsDirection)
            } header: {
                Text("Sorting")
            } footer: {
                Text("Recommended uses Copilot’s priority in the Inbox and your relationship to the work elsewhere. You can also change this from the toolbar.")
            }

            Section {
                Picker("Later Today", selection: $laterTodayHours) {
                    ForEach([1, 2, 3, 4, 6], id: \.self) { Text("In \($0) hour\($0 == 1 ? "" : "s")").tag($0) }
                }
                Picker("Tomorrow and Next Week", selection: $tomorrowHour) {
                    ForEach(6...13, id: \.self) { hour in
                        Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)?
                            .formatted(date: .omitted, time: .shortened) ?? "\(hour):00").tag(hour)
                    }
                }
            } header: {
                Text("Snooze")
            } footer: {
                Text("Snoozed work returns to its section at this time. Anything new on the item brings it back sooner.")
            }

            Section {
                Picker("Suggest a follow-up after", selection: $followUpDays) {
                    ForEach([1, 2, 3, 5, 7, 14], id: \.self) { Text("\($0) day\($0 == 1 ? "" : "s")").tag($0) }
                }
            } header: {
                Text("Follow-ups")
            } footer: {
                Text("Work waiting on others with no movement for this long appears under Follow Up in the Briefing.")
            }

            Section {
                Toggle("Mark work done when you handle it", isOn: $autoDoneHandled)
                LabeledContent("Done work returns") { Text("When someone else responds") }
            } header: {
                Text("Done")
            } footer: {
                Text("When you comment, review, or push on an Inbox item, Copilot checks whether you completed its suggested next step. If so, the item moves to Done, labeled Handled by You, with Undo. Your own activity never brings done work back.")
            }

            Section {
                Picker("Mark items as read", selection: $markReadPolicy) {
                    ForEach(MarkReadPolicy.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Unread")
            } footer: {
                Text("A blue dot marks work you haven't seen. It returns when someone else comments, reviews, or pushes; your own activity never does. Press U to toggle.")
            }
        }
    }

    // MARK: Accounts

    private var accountsPage: some View {
        Form {
            Section {
                if appModel.accounts.isEmpty {
                    Text("No GitHub accounts are connected.").foregroundStyle(.secondary)
                }
                ForEach(appModel.accounts) { account in
                    HStack(spacing: 12) {
                        InitialAvatar(text: account.displayName ?? account.login, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(account.displayName ?? account.login).fontWeight(.medium)
                                if account.id == appModel.selectedAccountID {
                                    Text("Current")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.tint.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text("@\(account.login) · \(account.authenticationKind.title)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        credentialBadge(account.credentialStatus)
                        Menu {
                            Button("Use This Account") { appModel.selectAccount(account.id) }
                                .disabled(account.id == appModel.selectedAccountID)
                            Divider()
                            Button("Remove…", role: .destructive) { accountPendingRemoval = account }
                                .disabled(appModel.isRemovingAccount(account.id))
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Actions for \(account.login)")
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    Spacer()
                    Button("Add Account…") { isPresentingAccountAddition = true }
                        .disabled(appModel.isConnecting)
                }
            } header: {
                Text("GitHub Accounts")
            } footer: {
                Text("Credentials are stored in your Keychain. Each account has its own encrypted local data.")
            }

            Section {
                if appModel.organizations.isEmpty {
                    Text("Connect a GitHub account to discover organizations.").foregroundStyle(.secondary)
                }
                Picker("Show work from", selection: Binding(
                    get: { appModel.selectedOrganizationID },
                    set: { if let id = $0 { appModel.selectOrganization(id) } }
                )) {
                    ForEach(appModel.organizations) { organization in
                        Text(organization.displayName ?? organization.login).tag(Optional(organization.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text(appModel.selectedAccount.map { "Organizations for @\($0.login)" } ?? "Organizations")
            } footer: {
                Text("Triage shows work involving you in one organization at a time. Copilot and rules are configured separately for each organization.")
            }

            if !appModel.unavailableAccountIDs.isEmpty || !appModel.vaultRecoveryIssues.isEmpty || appModel.connectionError != nil {
                Section("Needs Attention") {
                    if !appModel.unavailableAccountIDs.isEmpty || !appModel.vaultRecoveryIssues.isEmpty {
                        errorLabel(appModel.restorationError ?? "Some encrypted local account data needs recovery.")
                        Button("Try Again") { Task { await appModel.restoreAccounts() } }
                    }
                    if let error = appModel.connectionError { errorLabel(error) }
                }
            }
        }
    }

    @ViewBuilder
    private func credentialBadge(_ status: CredentialStatus) -> some View {
        let (text, color): (String, Color) = switch status {
        case .active: ("Connected", .green)
        case .expiring: ("Expiring soon", .orange)
        case .expired: ("Expired", .red)
        case .revoked: ("Revoked", .red)
        case .missing: ("Sign in again", .red)
        case .capabilityLimited: ("Limited access", .orange)
        }
        Label(text, systemImage: "circle.fill")
            .labelStyle(StatusDotLabelStyle(color: color))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Organizations

    // MARK: Copilot

    private var aiPage: some View {
        Form {
            if let organization = appModel.selectedOrganization {
                let state = appModel.selectedOrganizationAISettings
                let authorization = appModel.selectedCopilotAuthorizationState
                Section {
                    LabeledContent("Status") {
                        Label(copilotStatusText(state, authorization), systemImage: "circle.fill")
                            .labelStyle(StatusDotLabelStyle(color: state?.isEffectivelyAvailable == true ? .green : .orange))
                    }
                    LabeledContent("Account") {
                        Text(appModel.selectedAccount.map { "@\($0.login)" } ?? "—")
                    }
                    LabeledContent("Runtime") { Text(runtimeText(authorization.runtime)) }
                    HStack {
                        Spacer()
                        if appModel.isCopilotAuthenticationInProgress {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { appModel.cancelSelectedCopilotAuthentication() }
                        } else if authorization.authentication != .authenticated {
                            Button("Connect Copilot…") { appModel.startSelectedCopilotAuthenticationAtUserRequest() }
                                .disabled(state?.consent.isEnabled != true)
                        }
                        runtimeControls
                    }
                    if let error = appModel.copilotAuthenticationError ?? appModel.copilotRuntimeOperationError {
                        errorLabel(error)
                    }
                } header: {
                    Text("Copilot")
                }

                Section {
                    Toggle("Use Copilot to prioritize work", isOn: Binding(
                        get: { state?.consent.isEnabled ?? false },
                        set: { enabled in Task { await appModel.recordSelectedOrganizationAIConsent(enabled) } }
                    ))
                    CopilotModelChoiceRows(
                        choice: state?.consent.triageChoice ?? .auto,
                        models: state?.availableModels ?? [],
                        isEnabled: state?.consent.isEnabled == true
                    ) { choice in
                        Task { await appModel.saveSelectedOrganizationCopilotChoice(choice, for: .triage) }
                    }
                    LabeledContent("Rules and instructions") {
                        Button("Edit…") { navigation.settingsCategory = .rules }
                    }
                    LabeledContent("Re-analyze all work") {
                        Button("Re-analyze…") { isConfirmingReanalysis = true }
                            .disabled(state?.isEffectivelyAvailable != true)
                    }
                } header: {
                    Text(organization.displayName ?? organization.login)
                } footer: {
                    Text("Copilot reads titles, descriptions, recent comments, and pull request status for work involving you. It is review-only and never changes anything on GitHub. Higher reasoning effort and long context can improve judgment on complex work but are slower and may use more of your Copilot allowance.")
                }
            } else {
                Section {
                    Text("Select an organization before configuring Copilot.").foregroundStyle(.secondary)
                }
            }

            if let state = appModel.selectedOrganizationAISettings, state.consent.isEnabled {
                DraftReplySettingsSection(consent: state.consent, models: state.availableModels) { choice in
                    Task { await appModel.saveSelectedOrganizationCopilotChoice(choice, for: .reply) }
                }
            }
        }
        .task(id: appModel.selectedOrganizationID) {
            await appModel.refreshSelectedOrganizationAIStatus()
        }
    }

    private func copilotStatusText(_ state: OrganizationAISettingsState?, _ authorization: CopilotAccountAuthorizationState) -> String {
        if state?.isEffectivelyAvailable == true { return "Prioritizing your work" }
        return state?.status ?? "Checking…"
    }

    private func runtimeText(_ runtime: CopilotRuntimeStatus) -> String {
        switch runtime {
        case .ready: "Installed"
        case .missing: "Not installed"
        case .downloading(let received, let expected):
            if let expected, expected > 0 { "Downloading \(Int(Double(received) / Double(expected) * 100))%" } else { "Downloading…" }
        case .verifying: "Verifying…"
        case .corrupt: "Needs repair"
        case .unsupported(let reason): "Unsupported: \(reason)"
        }
    }

    @ViewBuilder
    private var runtimeControls: some View {
        switch appModel.selectedCopilotAuthorizationState.runtime {
        case .ready:
            Button("Remove Runtime", role: .destructive) {
                Task { await appModel.removeCopilotRuntimeAtUserRequest() }
            }
        case .corrupt:
            Button("Repair Runtime") { appModel.startCopilotRuntimeRepairAtUserRequest() }
        case .downloading, .verifying:
            ProgressView().controlSize(.small)
            Button("Cancel") { appModel.cancelCopilotRuntimeOperation() }
        case .missing, .unsupported:
            Button("Download Runtime") { appModel.startCopilotRuntimeAcquisitionAtUserRequest() }
                .disabled(appModel.isCopilotRuntimeOperationInProgress)
        }
    }

    // MARK: Updates

    private var updatesPage: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { softwareUpdates.automaticallyChecksForUpdates },
                    set: { softwareUpdates.setAutomaticallyChecksForUpdates($0) }
                ))
                Picker("Check", selection: Binding(
                    get: { softwareUpdates.updateCheckInterval },
                    set: { softwareUpdates.setUpdateCheckInterval($0) }
                )) {
                    ForEach(AppUpdateCheckInterval.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!softwareUpdates.automaticallyChecksForUpdates)
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { softwareUpdates.automaticallyDownloadsUpdates },
                    set: { softwareUpdates.setAutomaticallyDownloadsUpdates($0) }
                ))
                .disabled(!softwareUpdates.automaticallyChecksForUpdates || !softwareUpdates.allowsAutomaticUpdates)
            } header: {
                Text("Automatic Updates")
            } footer: {
                Text("Updates are signed by the developer and verified before installing.")
            }
            Section {
                LabeledContent("Current version") { Text(AboutSettingsView.versionString) }
                LabeledContent("Last checked") {
                    Text(relative(softwareUpdates.lastUpdateCheckDate) ?? "Never")
                }
                HStack {
                    Spacer()
                    Button("Check for Updates…") { softwareUpdates.checkForUpdates() }
                        .disabled(!softwareUpdates.canCheckForUpdates)
                }
            }
        }
    }

    private func relative(_ date: Date?) -> String? {
        date.map { RelativeTime.phrase($0) }
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
