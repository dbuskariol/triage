import AppKit
import SwiftUI
@preconcurrency import UserNotifications

enum AccountRemovalPresentation {
    static let externalBackupDisclosure = "Triage cannot erase Time Machine backups, user-created copies, filesystem snapshots, or other external backups."

    static func confirmationMessage(accountLogin: String?) -> String {
        let localRemoval = if let accountLogin {
            "This removes \(accountLogin), its credentials, and all encrypted local Triage data from this Mac. GitHub content is not changed."
        } else {
            "This removes the account and its encrypted local data from this Mac."
        }
        return "\(localRemoval) \(externalBackupDisclosure)"
    }

    static let unavailableVaultRecoveryMessage = "This removes encrypted local Triage data whose vault key is unavailable. GitHub content is not changed. Afterward, reconnect to GitHub to resync. \(externalBackupDisclosure)"

    static func removalFailureMessage(isUnavailableVault: Bool) -> String {
        isUnavailableVault
            ? "The unavailable account’s encrypted local data were not removed. Try again after resolving the local storage issue."
            : "The account and its encrypted local data were not removed. Try again after resolving the local storage issue."
    }
}

private struct VerifiedMigrationBackupRestoreRequest: Identifiable {
    let accountID: AccountID
    let migrationID: String

    var id: String { "\(accountID.rawValue)-\(migrationID)" }
}

enum NotificationAuthorizationAction: Equatable {
    case requestAuthorization
    case openSystemSettings
    case unavailable
}

enum NotificationSettingsPresentation {
    static let systemNotificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    )!

    static func action(for status: UNAuthorizationStatus) -> NotificationAuthorizationAction {
        switch status {
        case .notDetermined, .ephemeral:
            .requestAuthorization
        case .denied:
            .openSystemSettings
        case .authorized, .provisional:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    static func organizationScopeName(displayName: String?, login: String) -> String {
        guard let displayName, !displayName.isEmpty, displayName != login else { return login }
        return "\(displayName) (@\(login))"
    }
}

enum SettingsSidebarLayout {
    static let minimumWidth: CGFloat = 240
    static let idealWidth: CGFloat = 260
    static let maximumWidth: CGFloat = 320
    static let titleAlignmentOffset: CGFloat = 18
    static let minimumWindowWidth: CGFloat = 800
    static let defaultWindowWidth: CGFloat = 860
}

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var notificationSettings: NativeNotificationSettings
    @EnvironmentObject private var notificationAuthorization: NotificationSystemAuthorization
    @EnvironmentObject private var softwareUpdates: SoftwareUpdateController
    @EnvironmentObject private var appModel: TriageAppModel
    @State private var accountReplacingToken: GitHubAccount?
    @State private var accountPendingRemoval: GitHubAccount?
    @State private var unavailableAccountPendingRemoval: AccountID?
    @State private var verifiedBackupPendingRestore: VerifiedMigrationBackupRestoreRequest?
    @State private var accountRemovalError: String?
    @State private var notificationSettingsOpenError: String?
    @State private var selectedNotificationConsentScope: NotificationScope?
    @State private var isSelectedOrganizationNotificationsEnabled = false
    @State private var isLoadingSelectedOrganizationNotificationConsent = false
    @State private var isSavingSelectedOrganizationNotificationConsent = false
    @State private var notificationConsentError: String?

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: sidebarSelection) { category in
                Label(categoryTitle(category), systemImage: category.systemImage)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .tag(category)
            }
            .listStyle(.sidebar)
            .padding(.top, SettingsSidebarLayout.titleAlignmentOffset)
            .accessibilityLabel("Settings sections")
            .navigationSplitViewColumnWidth(
                min: SettingsSidebarLayout.minimumWidth,
                ideal: SettingsSidebarLayout.idealWidth,
                max: SettingsSidebarLayout.maximumWidth
            )
        } detail: {
            selectedSettingsPage
        }
        .navigationSplitViewStyle(.balanced)
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
        .confirmationDialog(
            "Remove unavailable local account data?",
            isPresented: Binding(
                get: { unavailableAccountPendingRemoval != nil },
                set: { if !$0 { unavailableAccountPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Local Data", role: .destructive) {
                removeUnavailablePendingAccount()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                unavailableAccountPendingRemoval = nil
            }
            .keyboardShortcut(.cancelAction)
        } message: {
            Text(AccountRemovalPresentation.unavailableVaultRecoveryMessage)
        }
        .confirmationDialog(
            "Restore verified encrypted backup?",
            isPresented: Binding(
                get: { verifiedBackupPendingRestore != nil },
                set: { if !$0 { verifiedBackupPendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore Verified Backup") {
                restorePendingVerifiedBackup()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                verifiedBackupPendingRestore = nil
            }
            .keyboardShortcut(.cancelAction)
        } message: {
            Text("Triage will preserve the current encrypted database and restore this verified migration backup. GitHub will not be changed.")
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
        .alert(
            "Triage could not open macOS Notification Settings",
            isPresented: Binding(
                get: { notificationSettingsOpenError != nil },
                set: { if !$0 { notificationSettingsOpenError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                notificationSettingsOpenError = nil
            }
        } message: {
            Text(notificationSettingsOpenError ?? "Open System Settings, select Notifications, then allow Triage notifications.")
        }
    }

    private var selectedCategory: Binding<SettingsCategory> {
        Binding(
            get: { navigation.settingsCategory },
            set: { navigation.settingsCategory = $0 }
        )
    }

    private var sidebarSelection: Binding<SettingsCategory?> {
        Binding(
            get: { selectedCategory.wrappedValue },
            set: { category in
                guard let category else { return }
                selectedCategory.wrappedValue = category
            }
        )
    }

    @ViewBuilder
    private var selectedSettingsPage: some View {
        switch selectedCategory.wrappedValue {
        case .accounts: settingsPage(.accounts) { accountsSettings }
        case .organizations: settingsPage(.organizations) { organizationSettings }
        case .inbox: settingsPage(.inbox) { inboxSettings }
        case .notifications: settingsPage(.notifications) { notificationSettingsSection }
        case .ai: settingsPage(.ai) { aiSettings }
        case .general: settingsPage(.general) { generalSettings }
        case .updates: settingsPage(.updates) { updateSettings }
        case .about: settingsPage(.about) { aboutSettings }
        }
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
            if appModel.accounts.isEmpty,
               appModel.unavailableAccountIDs.isEmpty,
               appModel.vaultRecoveryIssues.isEmpty {
                Text("No GitHub accounts are connected.")
                    .foregroundStyle(.secondary)
            }
            if !appModel.accounts.isEmpty {
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
            if !appModel.unavailableAccountIDs.isEmpty {
                if !appModel.accounts.isEmpty {
                    SettingsDivider()
                }
                ForEach(appModel.unavailableAccountIDs.sorted { $0.rawValue < $1.rawValue }, id: \.self) { accountID in
                    SettingsValueRow(
                        title: "Unavailable local account",
                        detail: "Its encrypted vault key is unavailable. Remove local data, then reconnect to resync.",
                        systemImage: "lock.trianglebadge.exclamationmark"
                    ) {
                        Button("Remove Local Data…", role: .destructive) {
                            unavailableAccountPendingRemoval = accountID
                        }
                        .disabled(appModel.isConnecting)
                        .accessibilityHint(
                            "Removes this unavailable account's encrypted local data from this Mac. GitHub content is not changed."
                        )
                    }
                }
            }
            if !appModel.vaultRecoveryIssues.isEmpty {
                if !appModel.accounts.isEmpty || !appModel.unavailableAccountIDs.isEmpty {
                    SettingsDivider()
                }
                ForEach(
                    appModel.vaultRecoveryIssues.sorted { $0.accountID.rawValue < $1.accountID.rawValue },
                    id: \.accountID
                ) { issue in
                    SettingsValueRow(
                        title: "Encrypted local account needs repair",
                        detail: vaultRecoveryDetail(for: issue),
                        systemImage: "externaldrive.badge.exclamationmark"
                    ) {
                        HStack(spacing: 10) {
                            if !issue.verifiedBackupMigrationIDs.isEmpty {
                                Menu("Restore Verified Backup…") {
                                    ForEach(issue.verifiedBackupMigrationIDs, id: \.self) { migrationID in
                                        Button(migrationID) {
                                            verifiedBackupPendingRestore = .init(
                                                accountID: issue.accountID,
                                                migrationID: migrationID
                                            )
                                        }
                                    }
                                }
                                .accessibilityHint("Preserves the current encrypted database, then restores a verified migration backup.")
                            }
                            Button("Reconnect to GitHub…") {
                                reconnectToResync()
                            }
                            .accessibilityHint("Connects GitHub to resynchronize in a new local encrypted account. The affected encrypted data is not removed.")
                        }
                    }
                }
            }
            if let error = PersonalAccessTokenErrorPresentation.sharedConnectionError(
                appModel.connectionError,
                isPresentingPersonalAccessToken: accountReplacingToken != nil
            ) {
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
            SettingsCard(title: "Inbox") {
                SettingsValueRow(
                    title: "Default sort",
                    detail: "Sets the order of an unfiltered local Inbox. Search results keep their own selected order.",
                    systemImage: "arrow.up.arrow.down"
                ) {
                    Picker("Default Inbox sort", selection: $preferences.inboxDefaultSort) {
                        ForEach(InboxDefaultSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    .accessibilityHint("Changes the default order of local Inbox work.")
                }
            }
            SettingsCard(title: "Attention") {
                SettingsValueRow(
                    title: "Stale progress",
                    detail: "Owned work becomes stale after the selected number of working days without qualifying progress.",
                    systemImage: "clock.badge.exclamationmark"
                ) {
                    Stepper(
                        value: Binding(
                            get: { preferences.businessDayPolicy.staleAfterBusinessDays },
                            set: { preferences.setStaleAfterBusinessDays($0) }
                        ),
                        in: BusinessDayPolicyPreferences.minimumStaleAfterBusinessDays...BusinessDayPolicyPreferences.maximumStaleAfterBusinessDays
                    ) {
                        Text("\(preferences.businessDayPolicy.staleAfterBusinessDays) business days")
                    }
                    .accessibilityLabel("Stale progress threshold")
                    .accessibilityHint("Sets how many configured working days pass before owned work is marked stale.")
                }
                SettingsDivider()
                Text("Working days")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Only these weekdays count toward the stale-progress threshold. Public holidays are not inferred.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(WorkingWeekday.allCases, id: \.self) { weekday in
                    Toggle(weekday.title, isOn: Binding(
                        get: { preferences.businessDayPolicy.workingDays.contains(weekday) },
                        set: { preferences.setWorkingDay(weekday, enabled: $0) }
                    ))
                    .disabled(
                        preferences.businessDayPolicy.workingDays.count == 1
                            && preferences.businessDayPolicy.workingDays.contains(weekday)
                    )
                    .accessibilityHint(
                        preferences.businessDayPolicy.workingDays.count == 1
                            && preferences.businessDayPolicy.workingDays.contains(weekday)
                            ? "At least one working day is required."
                            : "Includes \(weekday.title) when calculating stale progress."
                    )
                }
            }
            SettingsCard(title: "Quick Snooze") {
                Text("These three durations appear in local workflow Snooze menus. They never change GitHub.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(InboxSnoozeSlot.allCases) { slot in
                    let durations = preferences.inboxSnoozeDurations
                    Stepper(
                        value: Binding(
                            get: { preferences.inboxSnoozeDurations.minutes(for: slot) },
                            set: { preferences.setInboxSnoozeDuration($0, for: slot) }
                        ),
                        in: snoozeDurationRange(for: slot, durations: durations),
                        step: 5
                    ) {
                        Text("\(slot.title): \(durations.minutes(for: slot)) minutes")
                    }
                    .accessibilityLabel(slot.title)
                    .accessibilityValue("\(durations.minutes(for: slot)) minutes")
                    .accessibilityHint("Sets a local quick-snooze duration. Each duration remains distinct and ordered.")
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

    private var notificationSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Notifications") {
                Toggle("Enable native notifications", isOn: Binding(
                    get: { notificationSettings.preferences.isEnabled },
                    set: { notificationSettings.setEnabled($0) }
                ))
                .accessibilityHint("Notifications remain disabled until enabled here and for an organization.")
                SettingsDivider()
                Picker("Lock Screen Content", selection: Binding(
                    get: { notificationSettings.preferences.privacy },
                    set: { notificationSettings.setPrivacy($0) }
                )) {
                    Text("Generic only").tag(NotificationPrivacy.generic)
                    Text("Show details").tag(NotificationPrivacy.showDetails)
                }
                .accessibilityHint("Showing details may reveal private GitHub content on the Lock Screen.")
                SettingsDivider()
                ForEach(NotificationReason.allCases, id: \.self) { reason in
                    Toggle(reason.notificationSettingsTitle, isOn: Binding(
                        get: { notificationSettings.preferences.enabledReasons.contains(reason) },
                        set: { notificationSettings.setReason(reason, enabled: $0) }
                    ))
                }
                if notificationSettings.isDeliverySettingsMutationPending {
                    ProgressView("Applying notification privacy settings…")
                        .controlSize(.small)
                }
                if let error = notificationSettings.deliverySettingsMutationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .disabled(notificationSettings.isDeliverySettingsMutationPending)

            SettingsCard(title: "Selected Organization") {
                if let accountID = appModel.selectedAccountID,
                   let organization = appModel.selectedOrganization
                {
                    let scope = NotificationScope(
                        accountID: accountID,
                        organizationID: organization.id
                    )
                    let organizationName = NotificationSettingsPresentation.organizationScopeName(
                        displayName: organization.displayName,
                        login: organization.login
                    )
                    Toggle(
                        "Allow notifications for \(organizationName)",
                        isOn: selectedOrganizationNotificationConsentBinding(for: scope)
                    )
                    .accessibilityLabel("Allow notifications for \(organizationName)")
                    .accessibilityHint("Permits Triage notifications for \(organizationName) only. It does not change GitHub notification settings.")
                    .disabled(
                        isLoadingSelectedOrganizationNotificationConsent
                            || isSavingSelectedOrganizationNotificationConsent
                    )
                    if isLoadingSelectedOrganizationNotificationConsent {
                        ProgressView("Loading notification permission…")
                            .controlSize(.small)
                    }
                    if let notificationConsentError {
                        Label(notificationConsentError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("Select an available organization before enabling its notifications.")
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: selectedNotificationScope) {
                guard let scope = selectedNotificationScope else {
                    selectedNotificationConsentScope = nil
                    isSelectedOrganizationNotificationsEnabled = false
                    isLoadingSelectedOrganizationNotificationConsent = false
                    return
                }
                await loadSelectedOrganizationNotificationConsent(for: scope)
            }

            SettingsCard(title: "Quiet Hours") {
                Toggle("Pause during quiet hours", isOn: Binding(
                    get: { notificationSettings.preferences.quietSchedule != nil },
                    set: { enabled in
                        notificationSettings.setQuietSchedule(enabled ? .init(startMinute: 1_320, endMinute: 420) : nil)
                    }
                ))
                if notificationSettings.preferences.quietSchedule != nil {
                    Picker("Start", selection: quietStartMinute) {
                        ForEach([0, 360, 480, 1_080, 1_320], id: \.self) { minute in
                            Text(quietHourTitle(minute)).tag(minute)
                        }
                    }
                    Picker("End", selection: quietEndMinute) {
                        ForEach([0, 360, 480, 1_080, 1_320], id: \.self) { minute in
                            Text(quietHourTitle(minute)).tag(minute)
                        }
                    }
                }
            }

            SettingsCard(title: "macOS Permission") {
                Text("Triage asks macOS separately before it can show notifications. Changing the controls above does not grant system permission.")
                    .foregroundStyle(.secondary)
                HStack {
                    Text(notificationAuthorization.status.notificationAuthorizationTitle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    notificationAuthorizationControl
                }
            }
        }
        .task { await notificationAuthorization.refresh() }
    }

    private var quietStartMinute: Binding<Int> {
        Binding(
            get: { notificationSettings.preferences.quietSchedule?.startMinute ?? 1_320 },
            set: { value in
                let end = notificationSettings.preferences.quietSchedule?.endMinute ?? 420
                notificationSettings.setQuietSchedule(.init(startMinute: value, endMinute: end))
            }
        )
    }

    private var selectedNotificationScope: NotificationScope? {
        guard let accountID = appModel.selectedAccountID,
              let organizationID = appModel.selectedOrganizationID
        else { return nil }
        return NotificationScope(accountID: accountID, organizationID: organizationID)
    }

    private func selectedOrganizationNotificationConsentBinding(
        for scope: NotificationScope
    ) -> Binding<Bool> {
        Binding(
            get: {
                selectedNotificationConsentScope == scope
                    && isSelectedOrganizationNotificationsEnabled
            },
            set: { isEnabled in
                guard !isLoadingSelectedOrganizationNotificationConsent,
                      !isSavingSelectedOrganizationNotificationConsent
                else { return }
                Task {
                    await setSelectedOrganizationNotificationConsent(isEnabled, for: scope)
                }
            }
        )
    }

    private func loadSelectedOrganizationNotificationConsent(
        for scope: NotificationScope
    ) async {
        selectedNotificationConsentScope = nil
        isSelectedOrganizationNotificationsEnabled = false
        isLoadingSelectedOrganizationNotificationConsent = true
        notificationConsentError = nil
        let isEnabled = await notificationSettings.isEnabled(for: scope)
        guard selectedNotificationScope == scope else { return }
        selectedNotificationConsentScope = scope
        isSelectedOrganizationNotificationsEnabled = isEnabled
        isLoadingSelectedOrganizationNotificationConsent = false
    }

    private func setSelectedOrganizationNotificationConsent(
        _ isEnabled: Bool,
        for scope: NotificationScope
    ) async {
        isSavingSelectedOrganizationNotificationConsent = true
        defer { isSavingSelectedOrganizationNotificationConsent = false }
        notificationConsentError = nil
        let didPersist = await notificationSettings.setEnabled(isEnabled, for: scope)
        guard selectedNotificationScope == scope else { return }
        guard didPersist else {
            await loadSelectedOrganizationNotificationConsent(for: scope)
            notificationConsentError = "Triage could not update this organization’s local notification permission."
            return
        }
        selectedNotificationConsentScope = scope
        isSelectedOrganizationNotificationsEnabled = isEnabled
    }

    @ViewBuilder
    private var notificationAuthorizationControl: some View {
        switch NotificationSettingsPresentation.action(for: notificationAuthorization.status) {
        case .requestAuthorization:
            Button("Allow Notifications") {
                Task { await notificationAuthorization.requestAuthorization() }
            }
            .accessibilityHint("Asks macOS to allow Triage notifications.")
        case .openSystemSettings:
            Button("Open macOS Notification Settings") {
                openMacOSNotificationSettings()
            }
            .accessibilityHint("Opens macOS Notification Settings so you can allow Triage notifications.")
        case .unavailable:
            EmptyView()
        }
    }

    private func openMacOSNotificationSettings() {
        guard NSWorkspace.shared.open(NotificationSettingsPresentation.systemNotificationSettingsURL) else {
            notificationSettingsOpenError = "macOS Notification Settings could not be opened. Open System Settings, select Notifications, then allow Triage notifications."
            return
        }
    }

    private var quietEndMinute: Binding<Int> {
        Binding(
            get: { notificationSettings.preferences.quietSchedule?.endMinute ?? 420 },
            set: { value in
                let start = notificationSettings.preferences.quietSchedule?.startMinute ?? 1_320
                notificationSettings.setQuietSchedule(.init(startMinute: start, endMinute: value))
            }
        )
    }

    private func quietHourTitle(_ minute: Int) -> String {
        let hour = minute / 60
        let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return "\(displayHour) \(hour < 12 ? "AM" : "PM")"
    }

    private var aiSettings: some View {
        SettingsCard(title: "Copilot") {
            let copilotState = appModel.selectedCopilotAuthorizationState
            SettingsValueRow(
                title: "Approved runtime",
                detail: copilotRuntimeDetail(copilotState.runtime),
                systemImage: copilotRuntimeImage(copilotState.runtime)
            ) {
                copilotRuntimeControl(
                    for: copilotState.runtime,
                    isOperationInProgress: appModel.isCopilotRuntimeOperationInProgress
                )
            }
            SettingsDivider()
            if let organization = appModel.selectedOrganization {
                let organizationName = NotificationSettingsPresentation.organizationScopeName(
                    displayName: organization.displayName,
                    login: organization.login
                )
                let state = appModel.selectedOrganizationAISettings
                Toggle("Allow AI analysis for \(organizationName)", isOn: Binding(
                    get: { state?.consent.isEnabled ?? false },
                    set: { enabled in
                        Task { await appModel.recordSelectedOrganizationAIConsent(enabled) }
                    }
                ))
                .accessibilityHint("AI authorization is local and organization-specific. Turning it off cancels analysis and erases only this organization's stored AI prompts, outputs, model cache, and AI action candidates.")
                Text(AIConsentPresentation.disclosure(
                    account: appModel.accounts.first(where: { $0.id == appModel.selectedAccountID }),
                    organization: organization
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                SettingsDivider()
                SettingsValueRow(
                    title: "Automatic action confidence",
                    detail: "Triage never creates an automatic action below 92% confidence. Raise this organization-specific threshold for a stricter Inbox.",
                    systemImage: "checkmark.seal"
                ) {
                    Stepper(
                        value: Binding(
                            get: {
                                state?.consent.automaticActionConfidenceThreshold
                                    ?? OrganizationAIConsent.minimumAutomaticActionConfidenceThreshold
                            },
                            set: { threshold in
                                Task {
                                    await appModel.setSelectedOrganizationAutomaticActionConfidenceThreshold(threshold)
                                }
                            }
                        ),
                        in: OrganizationAIConsent.minimumAutomaticActionConfidenceThreshold...OrganizationAIConsent.maximumAutomaticActionConfidenceThreshold,
                        step: 0.01
                    ) {
                        Text(state?.automaticActionConfidenceTitle ?? Self.automaticActionConfidenceTitle(
                            OrganizationAIConsent.minimumAutomaticActionConfidenceThreshold
                        ))
                    }
                    .disabled(!(state?.consent.isEnabled ?? false))
                    .accessibilityLabel("Automatic action confidence threshold")
                    .accessibilityValue(state?.automaticActionConfidenceTitle ?? Self.automaticActionConfidenceTitle(
                        OrganizationAIConsent.minimumAutomaticActionConfidenceThreshold
                    ))
                    .accessibilityHint("Raises the minimum confidence required before Copilot can create an automatic Inbox action for this organization. It cannot be set below 92 percent.")
                }
                SettingsDivider()
                SettingsValueRow(
                    title: "Selected model",
                    detail: state?.modelSelectionNotice
                        ?? "The current selection is persisted for this organization only.",
                    systemImage: "cpu"
                ) {
                    Menu {
                        Button("Auto") {
                            Task { await appModel.selectSelectedOrganizationCopilotModel(nil) }
                        }
                        if !(state?.availableModels.isEmpty ?? true) {
                            Divider()
                        }
                        ForEach(state?.availableModels ?? []) { model in
                            Button(model.displayName) {
                                Task { await appModel.selectSelectedOrganizationCopilotModel(model.id) }
                            }
                        }
                    } label: {
                        Text(state?.selectedModelTitle ?? "Auto")
                    }
                    .disabled(!(state?.consent.isEnabled ?? false))
                    .accessibilityLabel("Copilot model")
                    .accessibilityValue(state?.selectedModelTitle ?? "Auto")
                    .accessibilityHint(
                        "Choose Auto or an authenticated model available for this organization."
                    )
                }
                SettingsDivider()
                SettingsValueRow(
                    title: "Effective availability",
                    detail: state?.status ?? "Checking this organization's local AI authorization.",
                    systemImage: state?.isEffectivelyAvailable == true ? "checkmark.shield" : "xmark.shield"
                ) {
                    Text(state?.isEffectivelyAvailable == true ? "Available" : "Blocked")
                        .foregroundStyle(state?.isEffectivelyAvailable == true ? Color.secondary : Color.orange)
                }
                SettingsDivider()
                SettingsValueRow(
                    title: "Copilot account",
                    detail: copilotAuthenticationDetail(copilotState.authentication),
                    systemImage: "person.badge.key"
                ) {
                    if appModel.accounts.first(where: { $0.id == appModel.selectedAccountID })?.authenticationKind == .classicPersonalAccessToken {
                        Text("Unavailable")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Copilot is unavailable for classic personal access tokens")
                    } else {
                        Button("Authenticate Copilot") {
                            Task { await appModel.authenticateSelectedCopilotAccountAtUserRequest() }
                        }
                        .keyboardShortcut("a", modifiers: [.command, .option])
                        .disabled(!copilotState.hasOrganizationConsent || !copilotState.isEntitled)
                        .accessibilityHint("Verifies that Copilot is signed in as the selected Triage GitHub account.")
                    }
                }
                if let error = appModel.copilotAuthenticationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Copilot authentication error: \(error)")
                }
            } else {
                Text("Select an available organization before configuring AI analysis.")
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
        .task(id: appModel.selectedOrganizationID) {
            await appModel.refreshSelectedOrganizationAIStatus()
        }
    }

    @ViewBuilder
    private func copilotRuntimeControl(
        for status: CopilotRuntimeStatus,
        isOperationInProgress: Bool
    ) -> some View {
        switch status {
        case .missing, .unsupported:
            Button("Download") {
                appModel.startCopilotRuntimeAcquisitionAtUserRequest()
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(ifUnsupportedRuntime(status) || isOperationInProgress)
            .accessibilityHint("Downloads the pinned Copilot runtime only after this explicit request.")
        case .downloading, .verifying:
            Button("Cancel") { appModel.cancelCopilotRuntimeOperation() }
                .accessibilityLabel("Cancel Copilot runtime download")
                .accessibilityHint("Cancels the Copilot runtime download and removes its temporary files.")
        case .ready:
            Button("Remove", role: .destructive) {
                appModel.cancelCopilotRuntimeOperation()
                Task { await appModel.removeCopilotRuntimeAtUserRequest() }
            }
            .disabled(isOperationInProgress)
            .accessibilityHint("Removes the approved Copilot runtime from this Mac.")
        case .corrupt:
            Button("Repair") {
                appModel.startCopilotRuntimeRepairAtUserRequest()
            }
            .disabled(isOperationInProgress)
            .accessibilityHint("Removes and re-downloads the verified Copilot runtime.")
        }
    }

    private func ifUnsupportedRuntime(_ status: CopilotRuntimeStatus) -> Bool {
        if case .unsupported = status { return true }
        return false
    }

    private func copilotRuntimeDetail(_ status: CopilotRuntimeStatus) -> String {
        switch status {
        case .missing: return "Not installed. Triage never searches PATH or a user Copilot installation."
        case let .downloading(received, expected):
            if let expected { return "Downloading \(received) of \(expected) bytes from the pinned release." }
            return "Downloading \(received) bytes from the pinned release."
        case .verifying: return "Verifying the pinned runtime checksum, signature, and architecture."
        case .ready: return "Installed and revalidated before every use."
        case let .corrupt(message): return "The installed runtime failed validation (\(message)). Repair it before use."
        case let .unsupported(message): return message
        }
    }

    private func copilotRuntimeImage(_ status: CopilotRuntimeStatus) -> String {
        switch status {
        case .ready: "checkmark.shield"
        case .downloading, .verifying: "arrow.down.circle"
        case .corrupt, .unsupported: "exclamationmark.triangle"
        case .missing: "arrow.down.circle"
        }
    }

    private func copilotAuthenticationDetail(_ status: CopilotAuthenticationStatus) -> String {
        switch status {
        case .signedOut: "Not authenticated for this Triage account."
        case .deviceLoginRequired: "Copilot device login is unavailable in this build."
        case .verifyingIdentity: "Verifying the authenticated GitHub numeric user ID."
        case .authenticated: "Authenticated identity exactly matches the selected Triage account."
        case let .identityMismatch(expected, actual): "Blocked: Copilot user \(actual) does not match selected GitHub user \(expected)."
        case let .blocked(message), let .failed(message): message
        }
    }

    private static func automaticActionConfidenceTitle(_ threshold: Double) -> String {
        "\(Int((threshold * 100).rounded()))% minimum"
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            SettingsCard(title: "Appearance") {
                SettingsValueRow(
                    title: "List density",
                    detail: "Uses native macOS list sizing in the sidebar and work list.",
                    systemImage: "list.bullet"
                ) {
                    Picker("List density", selection: $preferences.appearanceDensity) {
                        ForEach(InterfaceAppearanceDensity.allCases) { density in
                            Text(density.title).tag(density)
                        }
                    }
                    .accessibilityHint("Changes native sidebar and work-list row density.")
                }
            }
            SettingsCard(title: "Refresh") {
                SettingsValueRow(
                    title: "Refresh behavior",
                    detail: "Automatic refresh checks when Triage launches, becomes active, wakes, and schedules local background work. Manual only leaves Refresh available in the toolbar and menu. Changes apply at the next launch.",
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    Picker("Refresh behavior", selection: $preferences.refreshBehavior) {
                        ForEach(RefreshBehavior.allCases) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }
                    .accessibilityHint("Controls automatic refreshes. Manual Refresh remains available.")
                }
            }
        }
    }

    private func snoozeDurationRange(
        for slot: InboxSnoozeSlot,
        durations: InboxSnoozeDurations
    ) -> ClosedRange<Int> {
        switch slot {
        case .first:
            InboxSnoozeDurations.minimumMinutes...(durations.secondMinutes - 1)
        case .second:
            (durations.firstMinutes + 1)...(durations.thirdMinutes - 1)
        case .third:
            (durations.secondMinutes + 1)...InboxSnoozeDurations.maximumMinutes
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
        AccountRemovalPresentation.confirmationMessage(accountLogin: accountPendingRemoval?.login)
    }

    private func removePendingAccount() {
        guard let account = accountPendingRemoval else { return }
        accountPendingRemoval = nil
        Task {
            do {
                try await appModel.removeAccount(account.id)
            } catch {
                accountRemovalError = AccountRemovalPresentation.removalFailureMessage(
                    isUnavailableVault: false
                )
            }
        }
    }

    private func removeUnavailablePendingAccount() {
        guard let accountID = unavailableAccountPendingRemoval else { return }
        unavailableAccountPendingRemoval = nil
        Task {
            do {
                try await appModel.removeAccount(accountID)
            } catch {
                accountRemovalError = AccountRemovalPresentation.removalFailureMessage(
                    isUnavailableVault: true
                )
            }
        }
    }

    private func restorePendingVerifiedBackup() {
        guard let request = verifiedBackupPendingRestore else { return }
        verifiedBackupPendingRestore = nil
        Task {
            await appModel.restoreVerifiedMigrationBackup(
                for: request.accountID,
                migrationID: request.migrationID
            )
        }
    }

    private func reconnectToResync() {
        guard let window = NSApp.keyWindow else {
            appModel.recordConnectionWindowError()
            return
        }
        Task {
            await appModel.connectGitHub(presentationAnchor: window)
        }
    }

    private func vaultRecoveryDetail(for issue: AccountVaultRecoveryIssue) -> String {
        let repair = switch issue.kind {
        case .databaseCorruption:
            "The encrypted database needs repair."
        case .migrationFailure:
            "An encrypted database migration needs repair."
        case .sqlCipherUnavailable:
            "Encrypted database support is unavailable for this local account."
        }
        if issue.verifiedBackupMigrationIDs.isEmpty {
            return "\(repair) No verified migration backup is available. The original encrypted data has not been removed. Reconnect to GitHub to resync."
        }
        return "\(repair) A verified migration backup is available. The original encrypted data has not been removed."
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
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
    }
}
