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
    @Environment(\.openWindow) private var openWindow
    @AppStorage("interface.onboarding.completed") private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            switch AppStartupPresentation(
                hasCompletedOnboarding: hasCompletedOnboarding,
                hasRestoredAccounts: appModel.hasRestoredAccounts,
                hasConnectedAccount: appModel.hasConnectedAccount
            ) {
            case .workspace:
                if let queue = appModel.focusQueue {
                    FocusView(presentation: appModel.presentation, queue: queue, actions: appModel) {
                        appModel.focusQueue = nil
                    }
                } else {
                    WorkspaceView()
                }
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
            appModel.openMainWindow = {
                openWindow(id: WorkspaceWindowRestoration.mainWindowFrameIdentifier)
                NSApp.activate()
            }
        }
    }
}

/// The main window: the sidebar, then either a full-width dashboard
/// (Briefing, Weekly Review) or a list beside the selected item's details.
private struct WorkspaceView: View {
    @EnvironmentObject private var appModel: TriageAppModel
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebarView(
                presentation: appModel.presentation,
                selection: $appModel.destination,
                savedSearches: appModel.savedSearches,
                onRenameSavedSearch: appModel.renameSavedSearch,
                onDeleteSavedSearch: appModel.deleteSavedSearch
            ) {
                WorkspacePickers()
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch appModel.destination {
                case .briefing:
                    BriefingView(presentation: appModel.presentation, actions: appModel,
                                 followUpDays: appModel.followUpDays)
                case .review:
                    ReviewView(presentation: appModel.presentation, actions: appModel)
                case .section, .savedSearch:
                    WorkspaceListAndDetail()
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    ControlGroup {
                        Button { appModel.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                            .disabled(appModel.backHistory.isEmpty)
                            .help("Back (⌘[)")
                        Button { appModel.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                            .disabled(appModel.forwardHistory.isEmpty)
                            .help("Forward (⌘])")
                    }
                    .controlGroupStyle(.navigation)
                }
            }
        }
        .onChange(of: appModel.search) { appModel.selectFirstEntry() }
        .sheet(item: $appModel.draftEntry) { entry in
            DraftReplySheet(entry: entry, generate: { try await appModel.draftReply(for: entry) }) {
                appModel.openOnGitHub(entry)
            }
        }
        .sheet(item: $appModel.ruleDraft) { draft in
            RuleEditorSheet(draft: draft, entries: appModel.presentation.allEntries) { appModel.addRule($0) }
                .environment(\.triageViewerLogin, appModel.selectedAccount?.login ?? "")
        }
        .environment(\.triageViewerLogin, appModel.selectedAccount?.login ?? "")
        .onChange(of: appModel.destination) { appModel.selectFirstEntry() }
        .onChange(of: preferences.refreshIntervalMinutes) { _, minutes in appModel.setRefreshInterval(minutes: minutes) }
    }
}

/// A list section or saved search beside the selected item's details.
private struct WorkspaceListAndDetail: View {
    @EnvironmentObject private var appModel: TriageAppModel

    var body: some View {
        HSplitView {
            TriageListView(
                presentation: appModel.presentation,
                section: appModel.selectedSection,
                savedSearch: appModel.selectedSavedSearch,
                selectedEntryID: $appModel.selectedEntryID,
                actions: appModel,
                search: $appModel.search,
                searchFocusRequest: appModel.searchFocusRequest,
                doneFilter: $appModel.doneFilter
            )
            .frame(minWidth: 320, idealWidth: 400, maxWidth: 560)
            TriageDetailView(
                entry: appModel.selectedEntry,
                inboxIsEmpty: appModel.presentation.count(in: .inbox) == 0,
                allEntries: appModel.presentation.allEntries,
                actions: appModel
            )
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
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
