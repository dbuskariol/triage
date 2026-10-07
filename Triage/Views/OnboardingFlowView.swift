import AppKit
import SwiftUI

struct OnboardingFlowView: View {
    @EnvironmentObject private var appModel: TriageAppModel

    let onComplete: () -> Void

    @State private var isPresentingTokenSheet = false
    @State private var token = ""
    @State private var resourceOwnerOrganization = ""
    @State private var hasChosenOrganization = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("Welcome to Triage", systemImage: "tray.full")
                .font(.largeTitle.weight(.bold))

            if recoveryNoticeNeeded {
                recoveryNotice
            }

            if !appModel.hasConnectedAccount {
                connectGitHub
            } else if !hasChosenOrganization {
                chooseOrganization
            } else {
                enableCopilot
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(32)
        .sheet(isPresented: $isPresentingTokenSheet) {
            personalAccessTokenSheet
        }
    }

    private var recoveryNoticeNeeded: Bool {
        appModel.restorationError != nil
            || !appModel.vaultRecoveryIssues.isEmpty
            || !appModel.unavailableAccountIDs.isEmpty
    }

    private var recoveryNotice: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    appModel.restorationError ?? "Some encrypted local account data needs attention.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                Button("Try Again") {
                    Task { await appModel.restoreAccounts() }
                }
                .disabled(appModel.isRestoringAccounts)
                if appModel.isRestoringAccounts {
                    ProgressView("Restoring accounts…")
                        .controlSize(.small)
                }
            }
        }
    }

    private var connectGitHub: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect GitHub")
                .font(.title2.weight(.semibold))
            Text("Connect the GitHub account Triage should use for your local workspace.")
                .foregroundStyle(.secondary)
            Button("Continue with GitHub") {
                guard let window = NSApp.keyWindow else {
                    appModel.recordConnectionWindowError()
                    return
                }
                Task { await appModel.connectGitHub(presentationAnchor: window) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(appModel.isConnecting)
            Button("Use a Personal Access Token") {
                isPresentingTokenSheet = true
            }
            .disabled(appModel.isConnecting)
            if appModel.isConnecting {
                ProgressView("Connecting GitHub…")
            }
            if let error = appModel.connectionError {
                errorLabel(error)
            }
        }
    }

    private var chooseOrganization: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose an organization")
                .font(.title2.weight(.semibold))
            if appModel.organizations.isEmpty {
                Text("No organizations are available for the connected account.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Organization", selection: Binding(
                    get: { appModel.selectedOrganizationID },
                    set: { if let id = $0 { appModel.selectOrganization(id) } }
                )) {
                    ForEach(appModel.organizations) { organization in
                        Text(organization.displayName ?? organization.login)
                            .tag(Optional(organization.id))
                    }
                }
                Button("Continue") {
                    hasChosenOrganization = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.selectedOrganization == nil)
            }
        }
    }

    private var enableCopilot: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Turn on Copilot")
                .font(.title2.weight(.semibold))
            Text("Copilot reads your relevant issues and pull requests to prioritize them; it is review-only and never changes GitHub.")
                .foregroundStyle(.secondary)

            Toggle("Allow AI analysis", isOn: Binding(
                get: { appModel.selectedOrganizationAISettings?.consent.isEnabled ?? false },
                set: { enabled in
                    Task { await appModel.recordSelectedOrganizationAIConsent(enabled) }
                }
            ))

            copilotSetupControls

            Button("Set up later") {
                onComplete()
            }
            if let error = appModel.copilotAuthenticationError ?? appModel.copilotRuntimeOperationError {
                errorLabel(error)
            }
        }
    }

    @ViewBuilder
    private var copilotSetupControls: some View {
        if appModel.selectedOrganizationAISettings?.consent.isEnabled == true {
            if appModel.selectedCopilotAuthorizationState.runtime != .ready {
                Button(runtimeActionTitle) {
                    startRuntimeAction()
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.isCopilotRuntimeOperationInProgress)
                if appModel.isCopilotRuntimeOperationInProgress {
                    ProgressView("Preparing Copilot runtime…")
                }
            } else if appModel.isCopilotAuthenticationInProgress {
                ProgressView("Connecting Copilot…")
            } else {
                Button("Connect Copilot") {
                    appModel.startSelectedCopilotAuthenticationAtUserRequest()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var runtimeActionTitle: String {
        if case .corrupt = appModel.selectedCopilotAuthorizationState.runtime {
            "Repair Copilot Runtime"
        }
        return "Download Copilot Runtime"
    }

    private func startRuntimeAction() {
        if case .corrupt = appModel.selectedCopilotAuthorizationState.runtime {
            appModel.startCopilotRuntimeRepairAtUserRequest()
        } else {
            appModel.startCopilotRuntimeAcquisitionAtUserRequest()
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
    }

    private var personalAccessTokenSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Use a Personal Access Token")
                .font(.title2.weight(.semibold))
            SecureField("GitHub personal access token", text: $token)
            TextField("Resource owner organization (fine-grained token)", text: $resourceOwnerOrganization)
            if let error = appModel.connectionError {
                errorLabel(error)
            }
            HStack {
                Button("Cancel") {
                    token = ""
                    isPresentingTokenSheet = false
                }
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
