import SwiftUI

struct TriageStatusView: View {
    let status: TriageStatus
    let actions: any WorkspaceActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(WorkspaceViewPresentation.statusLine(status))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let problem = status.problem {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(problemText(problem))
                        .font(.subheadline)
                    Spacer(minLength: 8)
                    problemButton(problem)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func problemButton(_ problem: TriageStatus.Problem) -> some View {
        switch problem {
        case .copilotUnavailable:
            Button("Open Copilot Settings") { actions.openCopilotSettings() }
        case .gitHubUnavailable:
            Button("Retry") { actions.refreshNow() }
        case .analysisFailed:
            EmptyView()
        }
    }

    private func problemText(_ problem: TriageStatus.Problem) -> String {
        switch problem {
        case .copilotUnavailable(let text), .gitHubUnavailable(let text):
            text
        case .analysisFailed:
            "Some items will be retried automatically"
        }
    }
}
