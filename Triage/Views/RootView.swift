import SwiftUI

/// Startup routing: configured users land in the workspace immediately;
/// onboarding appears only when no account has been set up.
enum AppStartupPresentation: Equatable {
    case workspace, restoring, onboarding

    init(hasCompletedOnboarding: Bool, hasRestoredAccounts: Bool, hasConnectedAccount: Bool) {
        if !hasRestoredAccounts {
            // Don't wait for encrypted restoration to show a configured workspace.
            self = hasCompletedOnboarding ? .workspace : .restoring
        } else {
            self = hasCompletedOnboarding && hasConnectedAccount ? .workspace : .onboarding
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var appModel: TriageAppModel
    @EnvironmentObject private var navigation: AppNavigationModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage("interface.onboarding.completed") private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            switch AppStartupPresentation(
                hasCompletedOnboarding: hasCompletedOnboarding,
                hasRestoredAccounts: appModel.hasRestoredAccounts,
                hasConnectedAccount: appModel.hasConnectedAccount
            ) {
            case .workspace:
                WorkspaceView()
            case .restoring:
                ProgressView("Opening Triage")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .onboarding:
                OnboardingFlowView { hasCompletedOnboarding = true }
            }
        }
        .onAppear {
            appModel.openSettings = { category in
                navigation.openSettings(category)
                openSettings()
            }
        }
    }
}

/// The main window: AI sections, the selected section's list, and Copilot's
/// recommendation for the selected item.
private struct WorkspaceView: View {
    @EnvironmentObject private var appModel: TriageAppModel
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebarView(
                presentation: appModel.presentation,
                selection: $appModel.selectedSection
            ) {
                WorkspacePickers()
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } content: {
            TriageListView(
                presentation: appModel.presentation,
                section: appModel.selectedSection,
                selectedEntryID: $appModel.selectedEntryID,
                actions: appModel,
                search: $appModel.search,
                searchFocusRequest: appModel.searchFocusRequest,
                handledFilter: $appModel.handledFilter
            )
            .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 560)
        } detail: {
            TriageDetailView(
                entry: appModel.selectedEntry,
                inboxIsEmpty: appModel.presentation.count(in: .inbox) == 0,
                allEntries: appModel.presentation.allEntries,
                actions: appModel
            )
        }
        .onChange(of: appModel.search) { appModel.selectFirstEntry() }
        .sheet(item: $appModel.ruleDraft) { draft in
            RuleEditorSheet(draft: draft, entries: appModel.presentation.allEntries) { appModel.addRule($0) }
                .environment(\.triageViewerLogin, appModel.selectedAccount?.login ?? "")
        }
        .environment(\.triageViewerLogin, appModel.selectedAccount?.login ?? "")
        .onChange(of: appModel.selectedSection) { appModel.selectFirstEntry() }
        .onChange(of: preferences.refreshIntervalMinutes) { _, minutes in appModel.setRefreshInterval(minutes: minutes) }
    }
}

/// Account and organization pickers shown at the top of the sidebar.
private struct WorkspacePickers: View {
    @EnvironmentObject private var appModel: TriageAppModel

    var body: some View {
        if appModel.accounts.count > 1 {
            Picker("Account", selection: Binding(
                get: { appModel.selectedAccountID },
                set: { if let id = $0 { appModel.selectAccount(id) } }
            )) {
                ForEach(appModel.accounts) { account in
                    Text(account.displayName ?? account.login).tag(Optional(account.id))
                }
            }
        }
        if appModel.organizations.count > 1 {
            Picker("Organization", selection: Binding(
                get: { appModel.selectedOrganizationID },
                set: { if let id = $0 { appModel.selectOrganization(id) } }
            )) {
                ForEach(appModel.organizations) { organization in
                    Text(organization.displayName ?? organization.login).tag(Optional(organization.id))
                }
            }
        }
    }
}
