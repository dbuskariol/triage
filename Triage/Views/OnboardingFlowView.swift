import AppKit
import SwiftUI
import UserNotifications

/// First-launch Setup Assistant: connect GitHub, choose an organization, set
/// up Copilot, allow notifications, and fit Triage to your Mac. Every step
/// after the organization is optional and can be changed in Settings. Also
/// available later from Help ▸ Setup Assistant.
struct OnboardingFlowView: View {
    @EnvironmentObject private var appModel: TriageAppModel
    @EnvironmentObject private var preferences: AppPreferences

    let onComplete: () -> Void

    @State private var step = OnboardingStep.welcome
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var hasVisitedMac = false

    var body: some View {
        HStack(spacing: 0) {
            stepList
            Divider()
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    ScrollView {
                        page
                            .frame(maxWidth: 620, alignment: .leading)
                            .padding(.horizontal, 48)
                            .padding(.vertical, 40)
                            // Centered like Setup Assistant; scrolls when taller than the window.
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                }
                Divider()
                footer
            }
        }
        .frame(minWidth: 860, minHeight: 600)
        .task { notificationStatus = await NotificationPermission.status() }
        .onChange(of: step) { _, step in if step == .mac { hasVisitedMac = true } }
    }

    private var facts: OnboardingStep.Facts {
        .init(
            hasAccount: appModel.hasConnectedAccount,
            hasOrganization: appModel.selectedOrganization != nil,
            isCopilotReady: appModel.selectedOrganizationAISettings?.isEffectivelyAvailable == true,
            isNotificationsDecided: notificationStatus != .notDetermined,
            hasVisitedMac: hasVisitedMac
        )
    }

    // MARK: Step list

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
                .padding(.bottom, 12)
                .accessibilityHidden(true)
            ForEach(OnboardingStep.allCases) { item in
                Button {
                    step = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.isComplete(facts) && item != step ? "checkmark.circle.fill" : item.systemImage)
                            .foregroundStyle(item.isComplete(facts) && item != step ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                            .frame(width: 20)
                        Text(item.title)
                            .fontWeight(item == step ? .semibold : .regular)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(item == step ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!item.isReachable(facts))
                .accessibilityLabel("\(item.title)\(item.isComplete(facts) ? ", done" : "")")
                .accessibilityAddTraits(item == step ? .isSelected : [])
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 210, alignment: .leading)
        .background(.background.secondary)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let previous = step.previous {
                Button("Back") { step = previous }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
            }
            Spacer()
            if step == .ready {
                Button("Start Using Triage", action: finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else if let next = step.next {
                if isSkippable {
                    Button("Set Up Later") { step = next }
                }
                Button(step == .welcome ? "Get Started" : "Continue") { step = next }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!step.canContinue(facts))
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    /// Optional steps not yet done offer "Set Up Later" beside Continue.
    private var isSkippable: Bool {
        [.copilot, .notifications].contains(step) && !step.isComplete(facts)
    }

    private func finish() {
        appModel.destination = .briefing
        onComplete()
    }

    // MARK: Pages

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome: WelcomePage()
        case .github: ConnectGitHubPage()
        case .organization: OrganizationPage()
        case .copilot: CopilotPage()
        case .notifications: NotificationsPage(status: $notificationStatus)
        case .mac: MacPage()
        case .ready: ReadyPage(facts: facts)
        }
    }
}

// MARK: - Shared layout

/// A page heading: large symbol, title, and one-line explanation.
private struct PageHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.largeTitle.weight(.bold))
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 8)
    }
}

/// A checklist row: status, title, explanation, and an action.
private enum SetupState { case done, working, pending, problem }

private struct SetupRow<Action: View>: View {
    let state: SetupState
    let title: String
    let detail: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                switch state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .working: ProgressView().controlSize(.small)
                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .problem: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(.title3)
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action()
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

private struct ErrorText: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Welcome

private struct WelcomePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(
                systemImage: "tray.full",
                title: "Welcome to Triage",
                subtitle: "Your GitHub work, prioritized by Copilot. Setup takes about two minutes."
            )
            feature("sparkles", "Know what needs you", "Copilot reads the issues and pull requests that involve you and says what to do next, and why now.")
            feature("sun.horizon", "Start with a Briefing", "See what's blocked on you, quick wins, and follow-ups at a glance, then work through them in Focus.")
            feature("keyboard", "Move fast", "Mail-style keys, instant Done and Snooze, and replies Copilot drafts in your voice.")
            feature("lock.shield", "Private by design", "Your data stays encrypted on this Mac. Triage never changes anything on GitHub and has no telemetry.")
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - GitHub

private struct ConnectGitHubPage: View {
    @EnvironmentObject private var appModel: TriageAppModel
    @State private var isPresentingTokenSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                systemImage: "person.crop.circle.badge.checkmark",
                title: "Connect GitHub",
                subtitle: "Triage searches GitHub for work that involves you. It only reads; it never comments, merges, or changes anything."
            )
            if appModel.restorationError != nil || !appModel.vaultRecoveryIssues.isEmpty || !appModel.unavailableAccountIDs.isEmpty {
                recoveryNotice
            }
            if let account = appModel.selectedAccount {
                SetupRow(state: .done, title: "Connected as @\(account.login)",
                         detail: "Add more accounts later in Settings ▸ Accounts.") { EmptyView() }
            } else {
                SetupRow(
                    state: appModel.isConnecting ? .working : .pending,
                    title: "Sign in with GitHub",
                    detail: "Opens GitHub in your browser to approve read-only access. Your token is stored in the Keychain."
                ) {
                    Button("Continue with GitHub") {
                        guard let window = NSApp.keyWindow else {
                            appModel.recordConnectionWindowError()
                            return
                        }
                        Task { await appModel.connectGitHub(presentationAnchor: window) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appModel.isConnecting)
                }
                Button("Use a personal access token instead…") { isPresentingTokenSheet = true }
                    .buttonStyle(.link)
                    .disabled(appModel.isConnecting)
            }
            if let error = appModel.connectionError {
                ErrorText(message: error)
            }
        }
        .sheet(isPresented: $isPresentingTokenSheet) { PersonalAccessTokenSheet() }
    }

    private var recoveryNotice: some View {
        SetupRow(
            state: appModel.isRestoringAccounts ? .working : .problem,
            title: "Some local account data needs attention",
            detail: appModel.restorationError ?? "Triage couldn't open an encrypted account. Try again, or remove it in Settings ▸ Accounts."
        ) {
            Button("Try Again") { Task { await appModel.restoreAccounts() } }
                .disabled(appModel.isRestoringAccounts)
        }
    }
}

private struct PersonalAccessTokenSheet: View {
    @EnvironmentObject private var appModel: TriageAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var resourceOwnerOrganization = ""

    var body: some View {
        Form {
            Section {
                SecureField("Token", text: $token)
                TextField("Resource owner", text: $resourceOwnerOrganization, prompt: Text("Organization, for fine-grained tokens"))
            } header: {
                Text("Use a Personal Access Token")
            } footer: {
                Text("Needs read access to issues, pull requests, and organization membership. The token is stored in the Keychain.")
            }
            if let error = appModel.connectionError {
                ErrorText(message: error)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { token = ""; dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Connect") {
                    let submitted = token
                    let organization = resourceOwnerOrganization.isEmpty ? nil : resourceOwnerOrganization
                    token = ""
                    Task {
                        await appModel.connectPersonalAccessToken(submitted, resourceOwnerOrganization: organization)
                        if appModel.connectionError == nil { dismiss() }
                    }
                }
                .disabled(token.isEmpty || appModel.isConnecting)
            }
        }
    }
}

// MARK: - Organization

private struct OrganizationPage: View {
    @EnvironmentObject private var appModel: TriageAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                systemImage: "building.2",
                title: "Choose an organization",
                subtitle: "Triage shows your work in one organization at a time. Switch anytime from the top of the sidebar."
            )
            if appModel.organizations.isEmpty {
                SetupRow(state: .problem, title: "No organizations found",
                         detail: "The connected account isn't a member of an organization Triage can read, or access hasn't been granted. Check the account in Settings ▸ Accounts.") { EmptyView() }
            } else {
                VStack(spacing: 0) {
                    ForEach(appModel.organizations) { organization in
                        Button {
                            appModel.selectOrganization(organization.id)
                        } label: {
                            HStack(spacing: 12) {
                                InitialAvatar(text: organization.displayName ?? organization.login, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(organization.displayName ?? organization.login).font(.headline)
                                    Text(organization.login).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if organization.id == appModel.selectedOrganizationID {
                                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                                }
                            }
                            .padding(12)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(organization.id == appModel.selectedOrganizationID ? .isSelected : [])
                        if organization.id != appModel.organizations.last?.id { Divider().padding(.leading, 52) }
                    }
                }
                .background(.background.secondary, in: .rect(cornerRadius: 10))
            }
        }
    }
}

// MARK: - Copilot

private struct CopilotPage: View {
    @EnvironmentObject private var appModel: TriageAppModel

    var body: some View {
        let consent = appModel.selectedOrganizationAISettings?.consent.isEnabled == true
        let authorization = appModel.selectedCopilotAuthorizationState
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                systemImage: "sparkles",
                title: "Set up Copilot",
                subtitle: "Copilot decides what needs you and drafts replies. It uses your GitHub Copilot subscription and is review-only."
            )
            SetupRow(
                state: consent ? .done : .pending,
                title: "Allow Copilot for \(appModel.selectedOrganization?.displayName ?? appModel.selectedOrganization?.login ?? "this organization")",
                detail: "Copilot reads titles, descriptions, recent comments, and pull request status for work involving you. Nothing else leaves your Mac."
            ) {
                Toggle("Allow", isOn: Binding(
                    get: { consent },
                    set: { enabled in Task { await appModel.recordSelectedOrganizationAIConsent(enabled) } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            SetupRow(
                state: runtimeState(authorization.runtime),
                title: "Install the Copilot runtime",
                detail: runtimeDetail(authorization.runtime)
            ) {
                if consent, runtimeNeedsAction(authorization.runtime) {
                    Button(isCorrupt(authorization.runtime) ? "Repair" : "Download") {
                        isCorrupt(authorization.runtime)
                            ? appModel.startCopilotRuntimeRepairAtUserRequest()
                            : appModel.startCopilotRuntimeAcquisitionAtUserRequest()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appModel.isCopilotRuntimeOperationInProgress)
                }
            }
            SetupRow(
                state: authenticationState(authorization),
                title: "Sign in to Copilot",
                detail: authenticationDetail(authorization)
            ) {
                if consent, authorization.runtime == .ready, authorization.authentication != .authenticated,
                   !appModel.isCopilotAuthenticationInProgress {
                    Button("Sign In") { appModel.startSelectedCopilotAuthenticationAtUserRequest() }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let error = appModel.copilotAuthenticationError ?? appModel.copilotRuntimeOperationError {
                ErrorText(message: error)
            } else if consent, let status = appModel.selectedOrganizationAISettings?.status {
                Text(status).foregroundStyle(.secondary)
            }
            Text("Choose models, reasoning effort, and your writing style later in Settings ▸ Copilot.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .task(id: appModel.selectedOrganizationID) { await appModel.refreshSelectedOrganizationAIStatus() }
    }

    private func isCorrupt(_ runtime: CopilotRuntimeStatus) -> Bool {
        if case .corrupt = runtime { true } else { false }
    }

    private func runtimeNeedsAction(_ runtime: CopilotRuntimeStatus) -> Bool {
        switch runtime {
        case .missing, .corrupt: true
        default: false
        }
    }

    private func runtimeState(_ runtime: CopilotRuntimeStatus) -> SetupState {
        switch runtime {
        case .ready: .done
        case .downloading, .verifying: .working
        case .corrupt, .unsupported: .problem
        case .missing: appModel.isCopilotRuntimeOperationInProgress ? .working : .pending
        }
    }

    private func runtimeDetail(_ runtime: CopilotRuntimeStatus) -> String {
        switch runtime {
        case .ready: "Installed and verified."
        case .missing: "A one-time download of GitHub's signed Copilot CLI (about 50 MB), verified before use."
        case .downloading(let received, let expected):
            if let expected, expected > 0 {
                "Downloading… \(Int(Double(received) / Double(expected) * 100))%"
            } else {
                "Downloading…"
            }
        case .verifying: "Verifying GitHub's signature…"
        case .corrupt: "The installed runtime failed verification. Repair downloads a fresh copy."
        case .unsupported(let reason): reason
        }
    }

    private func authenticationState(_ authorization: CopilotAccountAuthorizationState) -> SetupState {
        switch authorization.authentication {
        case .authenticated: .done
        case .verifyingIdentity, .deviceLoginRequired: .working
        case .identityMismatch, .blocked, .failed: .problem
        case .signedOut: appModel.isCopilotAuthenticationInProgress ? .working : .pending
        }
    }

    private func authenticationDetail(_ authorization: CopilotAccountAuthorizationState) -> String {
        switch authorization.authentication {
        case .authenticated: "Signed in. Copilot will start prioritizing your work."
        case .deviceLoginRequired: "Finish signing in in your browser."
        case .verifyingIdentity: "Checking it's the same GitHub account…"
        case .identityMismatch: "Sign in to Copilot with the same GitHub account you connected."
        case .blocked(let message), .failed(let message): message
        case .signedOut: "Uses the GitHub account you connected. Opens your browser once."
        }
    }
}

// MARK: - Notifications

private struct NotificationsPage: View {
    @Binding var status: UNAuthorizationStatus
    @EnvironmentObject private var appModel: TriageAppModel
    @AppStorage(TriagePreferenceKeys.notifyNeedsAction) private var notifyNeedsAction = true
    @AppStorage(TriagePreferenceKeys.notifyFollowUps) private var notifyFollowUps = true
    @AppStorage(TriagePreferenceKeys.showDockBadge) private var showDockBadge = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                systemImage: "bell.badge",
                title: "Stay in the loop",
                subtitle: "Hear about work once, when it first needs you, and see what's waiting on the Dock icon. Notifications stay on this Mac."
            )
            SetupRow(state: permissionState, title: "Allow notifications", detail: permissionDetail) {
                switch status {
                case .notDetermined:
                    Button("Allow…") {
                        Task {
                            await NotificationPermission.request()
                            status = await NotificationPermission.status()
                            appModel.refreshAttention()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                case .denied:
                    Button("Open System Settings…") { NotificationPermission.openSystemSettings() }
                default:
                    EmptyView()
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Notify me when work newly needs my action", isOn: $notifyNeedsAction)
                    Toggle("Remind me daily about overdue follow-ups", isOn: $notifyFollowUps)
                    Toggle("Show how much needs my action on the Dock icon", isOn: $showDockBadge)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(status == .denied)
            Text("Set quiet hours and more in Settings ▸ Notifications.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onChange(of: showDockBadge) { appModel.refreshAttention() }
        // Pick up changes made in System Settings while this page is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { status = await NotificationPermission.status() }
        }
    }

    private var permissionState: SetupState {
        switch status {
        case .authorized, .provisional, .ephemeral: .done
        case .denied: .problem
        default: .pending
        }
    }

    private var permissionDetail: String {
        switch status {
        case .authorized, .provisional, .ephemeral: "Allowed. Change banner style and sounds in System Settings."
        case .denied: "Notifications and the Dock badge are turned off for Triage. Turn them on in System Settings ▸ Notifications."
        default: "macOS will ask once. Allow banners and badges to get the most from Triage."
        }
    }
}

// MARK: - Your Mac

private struct MacPage: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                systemImage: "macwindow",
                title: "Fit Triage to your Mac",
                subtitle: "Keep your work current without thinking about it."
            )
            Form {
                Section {
                    Toggle("Open Triage when you log in", isOn: Binding(
                        get: { preferences.launchAtLoginEnabled },
                        set: { preferences.setLaunchAtLogin($0) }
                    ))
                    if let error = preferences.launchAtLoginError {
                        ErrorText(message: error)
                    }
                    Toggle("Show Triage in the menu bar", isOn: $preferences.showMenuBarExtra)
                } footer: {
                    Text("The menu bar shows what needs you, even when the window is closed.")
                }
                Section {
                    Picker("Check GitHub", selection: $preferences.refreshIntervalMinutes) {
                        ForEach(AppPreferences.refreshIntervalChoices, id: \.self) { minutes in
                            Text(AppPreferences.refreshIntervalTitle(minutes)).tag(minutes)
                        }
                    }
                    Toggle("Refresh when Triage becomes active", isOn: $preferences.refreshWhenActive)
                } footer: {
                    Text("Shorter intervals use more of your GitHub API quota. Copilot re-checks only what changed.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
        }
        .onAppear { preferences.refreshLaunchAtLoginStatus() }
    }
}

// MARK: - Ready

private struct ReadyPage: View {
    let facts: OnboardingStep.Facts

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                systemImage: "checkmark.seal",
                title: facts.isCopilotReady ? "You're all set" : "Almost there",
                subtitle: facts.isCopilotReady
                    ? "Triage is finding your work now. Your Briefing fills in as Copilot reviews it."
                    : "Triage will list your work now. Finish setting up Copilot in Settings ▸ Copilot to get priorities, next steps, and drafts."
            )
            GroupBox("A few keys to know") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    shortcut("⌘0", "Briefing")
                    shortcut("J  K", "Next and previous item")
                    shortcut("E", "Done")
                    shortcut("S", "Snooze until tomorrow")
                    shortcut("⇧⌘F", "Focus on the current list")
                    shortcut("⌥⌘D", "Draft a reply")
                    shortcut("⌘F", "Search, with filters like is:review")
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Run this assistant again anytime from Help ▸ Setup Assistant.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func shortcut(_ keys: String, _ title: String) -> some View {
        GridRow {
            Text(keys)
                .font(.body.monospaced().weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: .rect(cornerRadius: 5))
                .gridColumnAlignment(.trailing)
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }
}
