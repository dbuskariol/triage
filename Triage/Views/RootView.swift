import SwiftUI

struct RootView: View {
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
        } else {
            OnboardingView()
        }
    }

}

private struct OnboardingView: View {
    @EnvironmentObject private var appModel: TriageAppModel

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
    }
}

private struct AppSidebar: View {
    @EnvironmentObject private var appModel: TriageAppModel
    @Binding var selection: AppSection

    var body: some View {
        VStack(spacing: 0) {
            if !appModel.organizations.isEmpty {
                Picker("Organization", selection: $appModel.selectedOrganizationID) {
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
