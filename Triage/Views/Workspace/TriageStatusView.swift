import SwiftUI

struct TriageStatusView: View {
    let status: TriageStatus
    var credentialNotice: GitHubCredentialNotice?
    let actions: any WorkspaceActions

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
        }
    }
}
