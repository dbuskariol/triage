import SwiftUI

enum OnboardingStep: Int, CaseIterable, Hashable {
    case identity
    case organization
    case workflow
    case notifications
    case aiConsent
}

enum OnboardingAIAccess: Equatable {
    case consentRequired
    case unavailable(String)
}

enum AIConsentPresentation {
    static func disclosure(
        account: GitHubAccount?,
        organization: GitHubOrganization?
    ) -> String {
        let accountName = account?.displayName ?? account?.login ?? "your selected GitHub account"
        let organizationName = organization?.displayName ?? organization?.login ?? "the selected organization"
        let authenticationMethod = account?.authenticationKind.title ?? "the selected authentication method"
        return "If enabled for \(organizationName), Triage sends normalized relevant conversation content from \(accountName) to GitHub Copilot using \(authenticationMethod). This can include Work Item titles and state, deterministic trigger reasons, bounded relevant body text and conversation excerpts, timestamps, participant role aliases, and relevant labels and project fields. Model selection is organization-specific. Triage keeps organization-scoped AI caches locally; turning AI off cancels active analysis, prevents helper launch, and removes that organization’s AI caches while preserving deterministic rules and user-created action items. The dashboard works without AI."
    }
}

/// Copy for restoration failures is deliberately derived from a failure class,
/// never from a vault, Keychain, or filesystem error. The recovery UI must not
/// disclose local account identifiers or private storage paths.
enum LocalAccountRecoveryPresentation: Equatable {
    /// A stored account identity remains only as opaque local recovery state
    /// because its encryption key is unavailable.
    case unavailableVaultKey
    /// Account restoration failed before Triage could determine which local
    /// account data, if any, needs recovery.
    case encryptedLocalDataUnavailable

    var title: String {
        switch self {
        case .unavailableVaultKey:
            "Recover encrypted local account data"
        case .encryptedLocalDataUnavailable:
            "Encrypted local account data is unavailable"
        }
    }

    var detail: String {
        switch self {
        case .unavailableVaultKey:
            "Triage cannot open encrypted local data for one or more saved accounts. In Account Settings, remove each unavailable account’s local data. This removes data stored on this Mac only; it does not change GitHub. Then reconnect to GitHub to resync."
        case .encryptedLocalDataUnavailable:
            "Triage could not restore encrypted local account data. Try again after local storage is available. Triage has not identified an account that is safe to remove, so no local data will be deleted automatically."
        }
    }

    /// Only the keyless recovery path has an opaque account identity that the
    /// Settings view can remove. A generic restoration failure must remain a
    /// retry-only state; offering account removal there would be misleading
    /// and could imply a destructive recovery path that does not exist.
    var canOpenAccountSettings: Bool {
        self == .unavailableVaultKey
    }

    var systemImage: String {
        switch self {
        case .unavailableVaultKey:
            "externaldrive.badge.exclamationmark"
        case .encryptedLocalDataUnavailable:
            "lock.trianglebadge.exclamationmark"
        }
    }

    var accessibilityLabel: String {
        "\(title). \(detail)"
    }
}

enum OnboardingAccessRecovery: Equatable {
    case ssoRequired(isPartial: Bool)
    case approvalRequired
    case accessLimited

    var title: String {
        switch self {
        case .ssoRequired: "Authorize organization access"
        case .approvalRequired: "Organization approval required"
        case .accessLimited: "Organization access is limited"
        }
    }

    var detail: String {
        switch self {
        case .ssoRequired(let isPartial):
            isPartial
                ? "Some resources still need SSO authorization before Triage can refresh them."
                : "Authorize this account with your organization before Triage can refresh its work."
        case .approvalRequired:
            "Your organization must approve this account or application before all work can synchronize."
        case .accessLimited:
            "This account cannot access all organization work. Triage will only show work available to this account."
        }
    }

    var systemImage: String {
        switch self {
        case .ssoRequired: "lock.shield"
        case .approvalRequired: "person.badge.key"
        case .accessLimited: "exclamationmark.shield"
        }
    }

    var accessibilityLabel: String {
        "\(title). \(detail)"
    }
}

enum OnboardingRoute: Equatable {
    case localAccountRecovery(LocalAccountRecoveryPresentation)
    case connection
    case identityConfirmation
    case organizationSelection
    case accessRecovery(OnboardingAccessRecovery)
    case synchronization
    case workflowExplanation
    case notificationOffer
    case aiConsent
    case complete

    var accessibilityLabel: String {
        switch self {
        case .localAccountRecovery:
            "Local account recovery required before setup"
        case .connection: "Step 1 of 7: connect a GitHub account"
        case .identityConfirmation: "Step 2 of 7: confirm your GitHub identity"
        case .organizationSelection: "Step 3 of 7: select an organization"
        case .accessRecovery: "Step 4 of 7: recover organization access"
        case .synchronization: "Step 4 of 7: synchronize organization work"
        case .workflowExplanation: "Step 5 of 7: understand your local workflow"
        case .notificationOffer: "Step 6 of 7: review notifications"
        case .aiConsent: "Step 7 of 7: review AI access"
        case .complete: "Onboarding complete"
        }
    }
}

struct OnboardingPresentationState: Equatable {
    let account: GitHubAccount?
    let organizations: [GitHubOrganization]
    let selectedOrganizationID: OrganizationID?
    let organizationAccess: OrganizationAccess?
    let isConnecting: Bool
    let isSynchronizing: Bool
    let connectionError: String?
    let refreshError: String?
    let aiAccess: OnboardingAIAccess
    /// A browser authorization control is meaningful only when GitHub supplied
    /// a trusted `required; url=` SSO header for this selected organization.
    let hasSSOAuthorizationURL: Bool
    /// A sanitized, locally actionable failure class. It intentionally
    /// excludes the underlying restoration error and any local identifiers.
    let localAccountRecovery: LocalAccountRecoveryPresentation?

    init(
        accounts: [GitHubAccount],
        selectedAccountID: AccountID?,
        organizations: [GitHubOrganization],
        selectedOrganizationID: OrganizationID?,
        organizationAccess: OrganizationAccess?,
        isConnecting: Bool,
        isSynchronizing: Bool,
        connectionError: String?,
        refreshError: String?,
        aiAccess: OnboardingAIAccess,
        localAccountRecovery: LocalAccountRecoveryPresentation? = nil,
        hasSSOAuthorizationURL: Bool = false
    ) {
        account = accounts.first(where: { $0.id == selectedAccountID }) ?? accounts.first
        self.organizations = organizations
        self.selectedOrganizationID = selectedOrganizationID
        self.organizationAccess = organizationAccess
        self.isConnecting = isConnecting
        self.isSynchronizing = isSynchronizing
        self.connectionError = connectionError
        self.refreshError = refreshError
        self.aiAccess = aiAccess
        self.localAccountRecovery = localAccountRecovery
        self.hasSSOAuthorizationURL = hasSSOAuthorizationURL
    }

    var selectedOrganization: GitHubOrganization? {
        organizations.first(where: { $0.id == selectedOrganizationID })
    }

    func route(completedSteps: Set<OnboardingStep>) -> OnboardingRoute {
        guard account != nil else {
            if let localAccountRecovery {
                return .localAccountRecovery(localAccountRecovery)
            }
            return .connection
        }
        guard completedSteps.contains(.identity) else { return .identityConfirmation }
        guard selectedOrganization != nil else { return .organizationSelection }
        guard completedSteps.contains(.organization) else { return .organizationSelection }
        if let recovery = accessRecovery {
            return .accessRecovery(recovery)
        }
        if isSynchronizing || refreshError != nil {
            return .synchronization
        }
        guard completedSteps.contains(.workflow) else { return .workflowExplanation }
        guard completedSteps.contains(.notifications) else { return .notificationOffer }
        guard completedSteps.contains(.aiConsent) else { return .aiConsent }
        return .complete
    }

    private var accessRecovery: OnboardingAccessRecovery? {
        guard let organizationAccess else { return nil }
        return switch organizationAccess.state {
        case .ssoAuthorizationRequired:
            .ssoRequired(isPartial: false)
        case .partialSSOAuthorization:
            .ssoRequired(isPartial: true)
        case .organizationApprovalRequired, .oauthApplicationApprovalRequired:
            .approvalRequired
        case .organizationPolicyBlocked, .insufficientPermission, .inaccessible, .credentialExpired:
            .accessLimited
        case .available, .unknown:
            nil
        }
    }

    func shouldOfferSSOAuthorization(for recovery: OnboardingAccessRecovery) -> Bool {
        guard hasSSOAuthorizationURL else { return false }
        if case .ssoRequired = recovery {
            return true
        }
        return false
    }
}

struct OnboardingActions {
    let beginOAuth: @MainActor () async -> Void
    let submitPersonalAccessToken: @MainActor (_ token: String, _ resourceOwnerOrganization: String?) async -> Bool
    let selectOrganization: @MainActor (OrganizationID) -> Void
    let authorizeSSO: @MainActor () -> Void
    let retryAccessCheck: @MainActor () async -> Void
    let beginInitialSynchronization: @MainActor () async -> Void
    let openNotificationSettings: @MainActor () -> Void
    let recordAIConsent: @MainActor (_ isEnabled: Bool) -> Void
    /// These recovery actions are required so the keyless-vault recovery page
    /// cannot render controls that silently do nothing.
    let openAccountSettings: @MainActor () -> Void
    let retryLocalAccountRestoration: @MainActor () async -> Void
}

struct OnboardingPersonalAccessTokenForm: Equatable {
    let token: String
    let tokenKind: PersonalAccessTokenKind?
    let resourceOwnerOrganization: String

    var needsResourceOwnerOrganization: Bool {
        tokenKind == .fineGrained
    }

    var canSubmit: Bool {
        tokenKind != nil && (!needsResourceOwnerOrganization || !resourceOwnerOrganization.isEmpty)
    }
}

/// A PAT sheet owns its post-submit error, so a retained OAuth configuration
/// error from the parent surface must not be repeated behind it.
enum PersonalAccessTokenErrorPresentation {
    static func sharedConnectionError(
        _ error: String?,
        isPresentingPersonalAccessToken: Bool
    ) -> String? {
        isPresentingPersonalAccessToken ? nil : error
    }
}

struct OnboardingFlowView: View {
    let state: OnboardingPresentationState
    let actions: OnboardingActions
    let onComplete: () -> Void
    @State private var completedSteps = Set<OnboardingStep>()
    @State private var isPresentingPersonalAccessToken = false
    @State private var isRetryingLocalAccountRestoration = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Triage setup", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer()
                Text(route.accessibilityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(.bar)

            ScrollView {
                HStack(alignment: .top) {
                    Spacer(minLength: 0)
                    pageContent
                        .frame(maxWidth: 560, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(route.accessibilityLabel)
        .sheet(isPresented: $isPresentingPersonalAccessToken) {
            OnboardingPersonalAccessTokenSheet(
                isSubmitting: state.isConnecting,
                error: state.connectionError,
                onSubmit: actions.submitPersonalAccessToken
            )
        }
    }

    private var route: OnboardingRoute {
        state.route(completedSteps: completedSteps)
    }

    private var visibleConnectionError: String? {
        PersonalAccessTokenErrorPresentation.sharedConnectionError(
            state.connectionError,
            isPresentingPersonalAccessToken: isPresentingPersonalAccessToken
        )
    }

    @ViewBuilder
    private var pageContent: some View {
        switch route {
        case .localAccountRecovery(let recovery):
            localAccountRecoveryContent(recovery)
        case .connection:
            connectionContent
        case .identityConfirmation:
            identityContent
        case .organizationSelection:
            organizationContent
        case .accessRecovery(let recovery):
            accessRecoveryContent(recovery)
        case .synchronization:
            synchronizationContent
        case .workflowExplanation:
            workflowContent
        case .notificationOffer:
            notificationsContent
        case .aiConsent:
            aiConsentContent
        case .complete:
            completionContent
        }
    }

    private func localAccountRecoveryContent(
        _ recovery: LocalAccountRecoveryPresentation
    ) -> some View {
        OnboardingPage(title: recovery.title, message: recovery.detail) {
            Label(recovery.title, systemImage: recovery.systemImage)
                .foregroundStyle(.orange)
                .accessibilityLabel(recovery.accessibilityLabel)

            if recovery.canOpenAccountSettings {
                Button("Open Account Settings…") {
                    actions.openAccountSettings()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Opens the local account recovery controls.")
            }

            if isRetryingLocalAccountRestoration {
                ProgressView("Checking encrypted local account data…")
                    .controlSize(.small)
                    .accessibilityLabel("Checking encrypted local account data")
            } else {
                Button("Try Again") {
                    isRetryingLocalAccountRestoration = true
                    Task {
                        await actions.retryLocalAccountRestoration()
                        isRetryingLocalAccountRestoration = false
                    }
                }
                .accessibilityHint("Checks whether local account data can now be restored.")
            }
        }
    }

    private var connectionContent: some View {
        OnboardingPage(
            title: "Connect GitHub",
            message: "Triage builds an organization-scoped work inbox from the GitHub account you choose."
        ) {
            Button("Continue with GitHub") {
                Task {
                    await actions.beginOAuth()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(state.isConnecting)

            Button("Use a Personal Access Token") {
                isPresentingPersonalAccessToken = true
            }
            .disabled(state.isConnecting)

            Text("OAuth is the default. Use a personal access token only when your organization requires it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = visibleConnectionError {
                OnboardingErrorLabel(error)
            }
        }
    }

    private var identityContent: some View {
        OnboardingPage(
            title: "Confirm your identity",
            message: "Triage will use this GitHub identity to scope local work and access checks."
        ) {
            if let account = state.account {
                LabeledContent("GitHub account", value: account.login)
                LabeledContent("Connection", value: account.authenticationKind.title)
            }
            Button("Continue") {
                completedSteps.insert(.identity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var organizationContent: some View {
        OnboardingPage(
            title: "Select an organization",
            message: "Work and access checks remain scoped to the organization selected here."
        ) {
            if state.organizations.isEmpty {
                Label("No organizations are available for this account.", systemImage: "building.2")
                    .foregroundStyle(.secondary)
                Button("Check Access Again") {
                    Task {
                        await actions.retryAccessCheck()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.isConnecting)
            } else {
                Picker(
                    "Organization",
                    selection: Binding(
                        get: { state.selectedOrganizationID },
                        set: {
                            if let organizationID = $0 {
                                actions.selectOrganization(organizationID)
                            }
                        }
                    )
                ) {
                    ForEach(state.organizations) { organization in
                        Text(organization.displayName ?? organization.login)
                            .tag(Optional(organization.id))
                    }
                }

                Button("Use Selected Organization") {
                    completedSteps.insert(.organization)
                    Task {
                        await actions.beginInitialSynchronization()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(state.selectedOrganization == nil || state.isSynchronizing)
            }
        }
    }

    private func accessRecoveryContent(_ recovery: OnboardingAccessRecovery) -> some View {
        OnboardingPage(title: recovery.title, message: recovery.detail) {
            Label(recovery.title, systemImage: recovery.systemImage)
                .foregroundStyle(.orange)
                .accessibilityLabel(recovery.accessibilityLabel)

            if state.shouldOfferSSOAuthorization(for: recovery) {
                Button("Authorize in Browser") {
                    actions.authorizeSSO()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Button("Check Access Again") {
                    Task {
                        await actions.retryAccessCheck()
                    }
                }
            } else {
                Button("Check Access Again") {
                    Task {
                        await actions.retryAccessCheck()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }

            if let error = state.refreshError ?? visibleConnectionError {
                OnboardingErrorLabel(error)
            }
        }
    }

    private var synchronizationContent: some View {
        OnboardingPage(
            title: "Synchronizing your work",
            message: "Triage is refreshing only the selected organization’s locally stored work."
        ) {
            if state.isSynchronizing {
                ProgressView("Synchronizing GitHub work…")
                    .controlSize(.regular)
                Text("You can keep Triage open while synchronization finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = state.refreshError {
                OnboardingErrorLabel(error)
                Button("Try Synchronization Again") {
                    Task {
                        await actions.beginInitialSynchronization()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var workflowContent: some View {
        OnboardingPage(
            title: "A calm, local workflow",
            message: "Inbox highlights work needing attention. My Work and Reviews focus your responsibilities; Waiting and Snoozed preserve work until it is ready."
        ) {
            Text("Pin, prioritize, snooze, and archive are stored locally. Triage does not change GitHub work or notification state.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Continue") {
                completedSteps.insert(.workflow)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var notificationsContent: some View {
        OnboardingPage(
            title: "Review notifications",
            message: "Notifications are optional and are quiet by default."
        ) {
            Button("Review Notification Settings…") {
                actions.openNotificationSettings()
            }
            Button("Not Now") {
                completedSteps.insert(.notifications)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var aiConsentContent: some View {
        switch state.aiAccess {
        case .consentRequired:
            OnboardingPage(
                title: "Optional AI analysis",
                message: "Copilot analysis is disabled until you explicitly enable it for this organization."
            ) {
                Text(AIConsentPresentation.disclosure(
                    account: state.account,
                    organization: state.selectedOrganization
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                Button("Enable Copilot Analysis") {
                    actions.recordAIConsent(true)
                    completedSteps.insert(.aiConsent)
                }
                .buttonStyle(.borderedProminent)
                Button("Keep Copilot Analysis Off") {
                    actions.recordAIConsent(false)
                    completedSteps.insert(.aiConsent)
                }
                .keyboardShortcut(.defaultAction)
            }
        case .unavailable(let detail):
            OnboardingPage(
                title: "AI analysis is unavailable",
                message: detail
            ) {
                Text("Triage will continue without AI analysis. You can review availability later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Finish Setup") {
                    completedSteps.insert(.aiConsent)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var completionContent: some View {
        OnboardingPage(
            title: "Triage is ready",
            message: "Your selected organization is ready for its local work inbox."
        ) {
            Button("Open Triage") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct OnboardingPage<Content: View>: View {
    let title: String
    let message: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.largeTitle.weight(.bold))
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingErrorLabel: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .accessibilityLabel("Connection error. \(message)")
    }
}

private struct OnboardingPersonalAccessTokenSheet: View {
    @Environment(\.dismiss) private var dismiss
    let isSubmitting: Bool
    let error: String?
    let onSubmit: @MainActor (_ token: String, _ resourceOwnerOrganization: String?) async -> Bool
    @State private var token = ""
    @State private var resourceOwnerOrganization = ""
    @State private var hasSubmitted = false

    private var form: OnboardingPersonalAccessTokenForm {
        OnboardingPersonalAccessTokenForm(
            token: token,
            tokenKind: try? PersonalAccessToken(rawValue: token).kind,
            resourceOwnerOrganization: resourceOwnerOrganization
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Use a Personal Access Token")
                .font(.title2.weight(.semibold))
            Text("Triage validates the token through its connection service. This view does not store the token.")
                .foregroundStyle(.secondary)
            SecureField("GitHub personal access token", text: $token)
                .textFieldStyle(.roundedBorder)
            if form.needsResourceOwnerOrganization {
                TextField("Resource owner organization", text: $resourceOwnerOrganization)
                    .textFieldStyle(.roundedBorder)
                Text("Fine-grained tokens may need the organization selected when the token was created.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Fine-grained tokens are preferred. Classic tokens should include `repo` and `read:org`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The parent connection page can retain a prior OAuth setup error.
            // It is unrelated to PAT authentication, so this sheet only shows
            // errors produced after its own submission attempt.
            if hasSubmitted, let error {
                OnboardingErrorLabel(error)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    token = ""
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    let submittedToken = token
                    let organization = form.needsResourceOwnerOrganization ? resourceOwnerOrganization : nil
                    hasSubmitted = true
                    token = ""
                    Task {
                        if await onSubmit(submittedToken, organization) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!form.canSubmit || isSubmitting)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
