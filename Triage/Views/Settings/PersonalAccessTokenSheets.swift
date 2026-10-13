import SwiftUI

/// The ways to get a token on GitHub, one per row, each opening GitHub's
/// token page with the read-only access Triage needs already selected.
struct TokenSourcesSection: View {
    var title: String
    var organization: String?
    /// When replacing, offers regenerating the account's current token first.
    var regenerating: AuthenticationKind?
    @Environment(\.openURL) private var openURL

    private func list(_ items: [String]) -> String { ListFormatter.localizedString(byJoining: items) }

    private var fineGrainedDetail: String {
        let owner = organization.flatMap { $0.isEmpty ? nil : $0 } ?? "your organization"
        let repository = list(GitHubTokenRequirements.repositoryPermissions.map(\.title))
        let organizationPermissions = list(GitHubTokenRequirements.organizationPermissions.map(\.title))
        return "For \(owner). Read-only: \(repository); organization \(organizationPermissions)."
    }

    var body: some View {
        Section {
            if let regenerating {
                row("Regenerate your current token",
                    detail: "Easiest. GitHub issues a new value with the same access.",
                    action: "Regenerate…", url: GitHubTokenRequirements.tokenSettingsURL(for: regenerating))
            }
            row("Create a fine-grained token",
                detail: fineGrainedDetail,
                badge: "Recommended",
                action: "Create…", url: GitHubTokenRequirements.fineGrainedTokenURL(organization: organization))
            row("Create a classic token",
                detail: "Scopes: \(list(GitHubTokenRequirements.classicScopes)). Authorize it for SAML single sign-on if your organization uses it.",
                action: "Create…", url: GitHubTokenRequirements.classicTokenURL)
        } header: {
            Text(title)
        } footer: {
            Text("Triage only reads from GitHub and never posts for you.")
        }
    }

    private func row(_ title: String, detail: String, badge: String? = nil, action: String, url: URL) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if let badge {
                        Text(badge)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action) { openURL(url) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Connects a GitHub account with a personal access token.
struct PersonalAccessTokenSheet: View {
    @EnvironmentObject private var appModel: TriageAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var resourceOwnerOrganization = ""
    @State private var hasSubmitted = false

    var body: some View {
        Form {
            Section {
                TextField("Organization", text: $resourceOwnerOrganization, prompt: Text("e.g. acme"))
            } header: {
                Text("Connect with a Personal Access Token")
            } footer: {
                Text("The organization whose work you want to see. Required for fine-grained tokens.")
            }
            TokenSourcesSection(title: "Get a token on GitHub", organization: resourceOwnerOrganization)
            Section {
                SecureField("Token", text: $token)
                    .onSubmit(submit)
            } header: {
                Text("Paste the token")
            } footer: {
                Text("Stored in your Keychain.")
            }
            if hasSubmitted, !appModel.isConnecting, let error = appModel.connectionError {
                ErrorText(message: error)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { token = ""; dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Connect", action: submit)
                    .disabled(token.isEmpty || appModel.isConnecting)
            }
        }
    }

    private func submit() {
        guard !token.isEmpty, !appModel.isConnecting else { return }
        let submitted = token
        let organization = resourceOwnerOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
        token = ""
        hasSubmitted = true
        Task {
            await appModel.connectPersonalAccessToken(submitted, resourceOwnerOrganization: organization.isEmpty ? nil : organization)
            if appModel.connectionError == nil { dismiss() }
        }
    }
}

/// Replaces an account's personal access token in place, keeping its
/// organizations, rules, and local data.
struct ReplaceTokenSheet: View {
    let account: GitHubAccount
    @EnvironmentObject private var appModel: TriageAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var hasSubmitted = false

    /// The organization Triage shows for this account, used as the new token's resource owner.
    private var organization: String? {
        account.id == appModel.selectedAccountID ? appModel.selectedOrganization?.login : nil
    }

    var body: some View {
        Form {
            TokenSourcesSection(
                title: "Get a new token for @\(account.login)",
                organization: organization,
                regenerating: account.authenticationKind
            )
            Section {
                SecureField("Token", text: $token)
                    .onSubmit(submit)
            } header: {
                Text("Paste the new token")
            } footer: {
                Text("Your organizations, rules, and Triage history are kept. The token is stored in your Keychain.")
            }
            if hasSubmitted, !appModel.isConnecting, let error = appModel.connectionError {
                ErrorText(message: error)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Replace Token", action: submit)
                    .disabled(token.isEmpty || appModel.isConnecting)
            }
        }
    }

    private func submit() {
        guard !token.isEmpty, !appModel.isConnecting else { return }
        let submitted = token
        token = ""
        hasSubmitted = true
        Task {
            await appModel.replacePersonalAccessToken(submitted, for: account)
            if appModel.connectionError == nil { dismiss() }
        }
    }
}
