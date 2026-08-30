import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var appModel: TriageAppModel
    @EnvironmentObject private var softwareUpdates: SoftwareUpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Triage")
                        .font(.headline)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            if appModel.hasConnectedAccount {
                SynchronizationStatusLabel(
                    status: presentation.synchronizationStatus,
                    detail: presentation.synchronizationDetail
                )

                Menu("Open Work View") {
                    ForEach(AppSection.allCases) { section in
                        Button(section.title) {
                            navigation.section = section
                            openMainWindow()
                        }
                    }
                }

                ForEach(topItems) { item in
                    Button {
                        navigation.section = .inbox
                        appModel.selectedWorkItemID = item.id
                        openMainWindow()
                    } label: {
                        Text(item.title)
                            .lineLimit(1)
                    }
                }
                if !topItems.isEmpty {
                    Divider()
                }
            } else {
                Label("No GitHub account connected", systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
                Text("Open Triage to connect an account and choose an organization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
            }

            Button("Open Triage") {
                navigation.section = .inbox
                openMainWindow()
            }
            .keyboardShortcut("o")

            Button("Settings…") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")

            Button("Refresh GitHub Work") {
                Task {
                    await appModel.refreshSelectedOrganizationAfterAccessCheck()
                }
            }
            .disabled(appModel.selectedOrganization == nil || appModel.isRefreshing)

            Button("Check for Updates…") {
                softwareUpdates.checkForUpdates()
            }
            .disabled(!softwareUpdates.canCheckForUpdates)

            Divider()

            Button("Quit Triage") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 250)
    }

    private var inboxItems: [WorkItem] {
        let now = Date()
        return AttentionRanker().sort(
            appModel.workItems.filter {
                InboxEligibilityRule().disposition(for: $0, at: now) == .inbox
            },
            at: now
        )
    }

    private var topItems: ArraySlice<WorkItem> {
        inboxItems.prefix(5)
    }

    private var summary: String {
        guard appModel.hasConnectedAccount else {
            return "No account connected"
        }
        let highPriority = inboxItems.filter { $0.workflow.priority == .high }.count
        let organization = appModel.selectedOrganization?.displayName ?? appModel.selectedOrganization?.login
        let counts = "\(highPriority) priority · \(inboxItems.count) inbox"
        return organization.map { "\($0) · \(counts)" } ?? counts
    }

    private var presentation: WorkspacePresentationState {
        WorkspacePresentationState(
            workItems: appModel.workItems,
            selectedAccountID: appModel.selectedAccountID,
            selectedOrganizationID: appModel.selectedOrganizationID,
            organizationAccess: appModel.selectedOrganizationAccess,
            hasSSOAuthorizationHeader: appModel.ssoAuthorizationHeader != nil,
            isRefreshing: appModel.isRefreshing,
            refreshError: appModel.refreshError,
            now: Date()
        )
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
