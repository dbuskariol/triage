import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var appModel: TriageAppModel

    var body: some View {
        if appModel.hasConnectedAccount {
            NavigationSplitView {
                AppSidebar(selection: $navigation.section)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 218, max: 260)
            } content: {
                WorkListView()
                    .navigationSplitViewColumnWidth(min: 320, ideal: 390, max: 520)
            } detail: {
                WorkDetailView(item: appModel.selectedWorkItem)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar {
                ToolbarItem {
                    Button {
                        Task {
                            await appModel.refreshSelectedOrganization()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(appModel.selectedOrganization == nil || appModel.isRefreshing)
                    .help("Refresh GitHub Work")
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, appModel.ssoAuthorizationHeader != nil else { return }
                Task {
                    await appModel.refreshSelectedOrganization()
                }
            }
        } else {
            OnboardingView()
        }
    }

}

private struct OnboardingView: View {
    @EnvironmentObject private var appModel: TriageAppModel
    @State private var isPresentingPersonalAccessToken = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Connect GitHub")
                .font(.largeTitle.weight(.bold))
            Text("Connect a GitHub account to build your organization-scoped work inbox.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Connect GitHub") {
                guard let window = NSApp.keyWindow else {
                    appModel.recordConnectionWindowError()
                    return
                }
                Task {
                    await appModel.connectGitHub(presentationAnchor: window)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(appModel.isConnecting)
            Button("Use a Personal Access Token") {
                isPresentingPersonalAccessToken = true
            }
            .buttonStyle(.link)
            .disabled(appModel.isConnecting)
            if let error = appModel.connectionError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Triage")
        .sheet(isPresented: $isPresentingPersonalAccessToken) {
            PersonalAccessTokenSheet()
                .environmentObject(appModel)
        }
    }
}

private struct PersonalAccessTokenSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: TriageAppModel
    @State private var tokenInput = ""
    @State private var resourceOwnerOrganization = ""

    private var tokenKind: PersonalAccessTokenKind? {
        try? PersonalAccessToken(rawValue: tokenInput).kind
    }

    private var needsResourceOwner: Bool {
        tokenKind == .fineGrained
    }

    private var canConnect: Bool {
        tokenKind != nil && (!needsResourceOwner || !resourceOwnerOrganization.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect a Personal Access Token")
                .font(.title2.weight(.semibold))
            Text("Triage stores the token only in your macOS Keychain and uses GitHub read APIs.")
                .foregroundStyle(.secondary)
            SecureField("GitHub personal access token", text: $tokenInput)
                .textFieldStyle(.roundedBorder)
            if needsResourceOwner {
                TextField("Resource owner organization", text: $resourceOwnerOrganization)
                    .textFieldStyle(.roundedBorder)
                Text("Fine-grained tokens may not appear in your organization list. Enter the organization selected when you created this token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Use a fine-grained token when possible. Classic tokens should include `repo` and `read:org`; Copilot requires a separate sign-in for classic tokens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = appModel.connectionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    tokenInput = ""
                    dismiss()
                }
                Button("Connect") {
                    let token = tokenInput
                    let organization = needsResourceOwner ? resourceOwnerOrganization : nil
                    tokenInput = ""
                    Task {
                        await appModel.connectPersonalAccessToken(
                            token,
                            resourceOwnerOrganization: organization
                        )
                        if appModel.hasConnectedAccount {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canConnect || appModel.isConnecting)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

private struct AppSidebar: View {
    @EnvironmentObject private var appModel: TriageAppModel
    @Binding var selection: AppSection

    var body: some View {
        VStack(spacing: 0) {
            if appModel.accounts.count > 1 {
                Picker("Account", selection: Binding(
                    get: { appModel.selectedAccountID },
                    set: { accountID in
                        if let accountID {
                            appModel.selectAccount(accountID)
                        }
                    }
                )) {
                    ForEach(appModel.accounts) { account in
                        Text(account.login)
                            .tag(Optional(account.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
            }
            if !appModel.organizations.isEmpty {
                Picker("Organization", selection: Binding(
                    get: { appModel.selectedOrganizationID },
                    set: { organizationID in
                        if let organizationID {
                            appModel.selectOrganization(organizationID)
                        }
                    }
                )) {
                    ForEach(appModel.organizations) { organization in
                        Text(organization.displayName ?? organization.login)
                            .tag(Optional(organization.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
            }
            VStack(spacing: 3) {
                ForEach(AppSection.allCases) { section in
                    sidebarButton(section)
                }
            }
            .padding(.horizontal, 9)
            .padding(.top, 8)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sidebarButton(_ section: AppSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.systemImage)
                    .frame(width: 17)
                Text(section.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .font(.body)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                isSelected ? Color.accentColor : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
