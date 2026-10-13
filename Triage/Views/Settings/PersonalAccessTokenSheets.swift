import SwiftUI

/// What a personal access token needs, with links that open GitHub's token
/// page with exactly that access selected. `kind` limits it to one token type.
struct TokenRequirementsSection: View {
    var organization: String?
    var kind: AuthenticationKind?

    private func list(_ permissions: [GitHubTokenRequirements.Permission]) -> String {
        ListFormatter.localizedString(byJoining: permissions.map(\.title))
    }

    var body: some View {
        Section {
            if kind != .classicPersonalAccessToken {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fine-grained token (recommended)").fontWeight(.medium)
                    Text("Resource owner: \(organization.flatMap { $0.isEmpty ? nil : $0 } ?? "your organization"). Repository access: all repositories, or the ones you work in.")
                    Text("Repository permissions, read-only: \(list(GitHubTokenRequirements.repositoryPermissions)).")
                    Text("Organization permissions, read-only: \(list(GitHubTokenRequirements.organizationPermissions)).")
                    Link("Create a Fine-grained Token on GitHub",
                         destination: GitHubTokenRequirements.fineGrainedTokenURL(organization: organization))
                        .padding(.top, 2)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
            if kind != .fineGrainedPersonalAccessToken {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Classic token").fontWeight(.medium)
                    Text("Scopes: \(ListFormatter.localizedString(byJoining: GitHubTokenRequirements.classicScopes)). If your organization uses SAML single sign-on, authorize the token for it after creating it.")
                    Link("Create a Classic Token on GitHub", destination: GitHubTokenRequirements.classicTokenURL)
                        .padding(.top, 2)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("What the token needs")
        } footer: {
            Text("Triage only reads from GitHub and never posts for you. The token is stored in your Keychain.")
        }
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
                TextField("Organization", text: $resourceOwnerOrganization, prompt: Text("Required for fine-grained tokens"))
                SecureField("Token", text: $token)
                    .onSubmit(submit)
            } header: {
                Text("Use a Personal Access Token")
            }
            TokenRequirementsSection(organization: resourceOwnerOrganization)
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
            Section {
                SecureField("New token", text: $token)
                    .onSubmit(submit)
                Link("Regenerate an Existing Token on GitHub",
                     destination: GitHubTokenRequirements.tokenSettingsURL(for: account.authenticationKind))
            } header: {
                Text("Replace Token for @\(account.login)")
            } footer: {
                Text("Regenerating keeps the token's access. Your organizations, rules, and Triage history are kept.")
            }
            TokenRequirementsSection(organization: organization)
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
