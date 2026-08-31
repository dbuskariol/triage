import AppKit
import SwiftUI

/// Keeps menu-bar labels compact without discarding the full source title from
/// the main work surface or its accessibility label.
enum TriageMenuLabel {
    static func abbreviated(_ title: String, limit: Int = 30) -> String {
        precondition(limit >= 0, "A menu title limit cannot be negative.")
        guard limit > 0 else { return "" }

        let normalized = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard normalized.count > limit else { return normalized }
        guard limit > 1 else { return "…" }
        return String(normalized.prefix(limit - 1)) + "…"
    }
}

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
                    Text(selectionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(summary)
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
                .accessibilityHint("Opens the chosen local Triage work view.")

                ForEach(topItems) { item in
                    Button {
                        navigation.section = .inbox
                        appModel.selectedWorkItemID = item.id
                        openMainWindow()
                    } label: {
                        Text(TriageMenuLabel.abbreviated(item.title))
                    }
                    .accessibilityLabel(item.title)
                    .accessibilityHint("Opens this item in Triage. It does not change GitHub.")
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
            .accessibilityHint("Opens the local Triage Inbox window.")

            Button("Settings…") {
                navigation.openSettings(.general)
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Refresh GitHub Work") {
                Task {
                    await appModel.refreshSelectedOrganizationAfterAccessCheck()
                }
            }
            .disabled(appModel.selectedOrganization == nil || appModel.isRefreshing)
            .accessibilityHint("Refreshes read-only GitHub data for the selected organization.")

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
        let account = appModel.accounts.first(where: { $0.id == appModel.selectedAccountID })
        let accountName = account?.displayName ?? account?.login
        let organization = appModel.selectedOrganization?.displayName ?? appModel.selectedOrganization?.login
        let counts = "\(highPriority) priority · \(inboxItems.count) inbox"
        let selection = [accountName, organization].compactMap { $0 }.joined(separator: " · ")
        return selection.isEmpty ? counts : "\(selection) · \(counts)"
    }

    private var selectionSummary: String {
        TriageMenuLabel.abbreviated(summary)
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
