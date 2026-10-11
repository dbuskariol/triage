import SwiftUI

/// Replaces an account's personal access token in place, keeping its
/// organizations, rules, and local data.
struct ReplaceTokenSheet: View {
    let account: GitHubAccount
    @EnvironmentObject private var appModel: TriageAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var hasSubmitted = false

    private var tokenSettingsURL: URL {
        account.authenticationKind == .fineGrainedPersonalAccessToken
            ? URL(string: "https://github.com/settings/personal-access-tokens")!
            : URL(string: "https://github.com/settings/tokens")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Replace Token for @\(account.login)")
                .font(.title2.weight(.semibold))
            Text("Regenerate the token on GitHub, or create a new one with the same access, then paste it here. Your organizations, rules, and Triage history are kept.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Manage Tokens on GitHub", destination: tokenSettingsURL)
            SecureField("New personal access token", text: $token)
                .onSubmit(submit)
            if hasSubmitted, !appModel.isConnecting, let error = appModel.connectionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if appModel.isConnecting { ProgressView().controlSize(.small) }
                Button("Replace Token", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.isEmpty || appModel.isConnecting)
            }
        }
        .padding(24)
        .frame(width: 460)
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
