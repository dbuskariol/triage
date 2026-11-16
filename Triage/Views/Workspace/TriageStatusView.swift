import SwiftUI

struct TriageStatusView: View {
    let status: TriageStatus
    var credentialNotice: GitHubCredentialNotice?
    let actions: any WorkspaceActions
    @Environment(\.openURL) private var openURL
    /// The permission advice the user dismissed, so the same advice stays hidden.
    @AppStorage(Self.dismissedPermissionAdviceKey) private var dismissedPermissionAdvice = ""
    static let dismissedPermissionAdviceKey = "github.dismissed-permission-advice"

    static func showsPermissionAdvice(_ status: TriageStatus, dismissed: String) -> Bool {
        !status.missingOptionalPermissions.isEmpty && status.missingOptionalPermissions.joined(separator: ",") != dismissed
    }

    private var permissionAdvice: String? {
        let missing = status.missingOptionalPermissions
        guard Self.showsPermissionAdvice(status, dismissed: dismissedPermissionAdvice) else { return nil }
        return "Add \(ListFormatter.localizedString(byJoining: missing)) (read-only) to your GitHub token to filter on individual checks. The token keeps its value."
    }

    /// The credential notice explains a rejected token better than the problem does.
    private var problem: TriageStatus.Problem? {
        guard let problem = status.problem else { return nil }
        return problem.isCredentialRejected && credentialNotice != nil ? nil : problem
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let credentialNotice {
                banner(credentialNotice.message, symbol: credentialNotice.isBlocking ? "key.slash" : "key", tint: .orange) {
                    Button(credentialNotice.actionTitle) { actions.replaceGitHubToken() }
                }
            }
            if let permissionAdvice {
                banner(permissionAdvice, symbol: "key", tint: .secondary) {
                    Button("Edit Token on GitHub") {
                        openURL(GitHubTokenRequirements.tokenSettingsURL(for: .fineGrainedPersonalAccessToken))
                    }
                    Button("Dismiss") {
                        dismissedPermissionAdvice = status.missingOptionalPermissions.joined(separator: ",")
                    }
                }
            }
            if let problem {
                banner(problemText(problem), symbol: "exclamationmark.triangle.fill", tint: .orange) {
                    problemButton(problem)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func banner(
        _ text: String, symbol: String, tint: Color, @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline)
            Spacer(minLength: 8)
            action()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func problemButton(_ problem: TriageStatus.Problem) -> some View {
        switch problem {
        case .copilotUnavailable:
            Button("Open Copilot Settings") { actions.openCopilotSettings() }
        case .relaunchRequired:
            Button("Quit Triage") { NSApp.terminate(nil) }
        case .gitHubUnavailable:
            Button("Retry") { actions.refreshNow() }
        case .gitHubCredentialRejected:
            Button("Open Account Settings") { actions.replaceGitHubToken() }
        case .gitHubSingleSignOnRequired(_, let url):
            Button("Authorize on GitHub") { openURL(GitHubTokenRequirements.singleSignOnAuthorizationURL(url)) }
            Button("Retry") { actions.refreshNow() }
        case .analysisFailed:
            EmptyView()
        }
    }

    private func problemText(_ problem: TriageStatus.Problem) -> String {
        switch problem {
        case .copilotUnavailable(let text), .relaunchRequired(let text), .gitHubUnavailable(let text):
            text
        case .analysisFailed(let text):
            text
        case .gitHubCredentialRejected:
            "GitHub no longer accepts this account's token. Replace it in Settings ▸ Accounts."
        case .gitHubSingleSignOnRequired(let organization, _):
            Self.singleSignOnMessage(organization)
        }
    }

    static func singleSignOnMessage(_ organization: String) -> String {
        "\(organization) uses SAML single sign-on, and your GitHub token isn't authorized for it, so GitHub hid its work. Authorize the token, then retry."
    }
}
