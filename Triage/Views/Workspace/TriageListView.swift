import SwiftUI

struct TriageListView: View {
    let presentation: WorkspacePresentation
    let section: WorkspacePresentation.Section
    @Binding var selectedEntryID: GitHubNodeID?
    let actions: any WorkspaceActions
    @AppStorage(TriagePreferenceKeys.sortField) private var sortField = WorkspaceSortField.recommended
    @AppStorage(TriagePreferenceKeys.sortAscending) private var sortAscending = false

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                List(selection: $selectedEntryID) {
                    ForEach(entries) { entry in
                        TriageEntryRow(entry: entry)
                            .tag(entry.id)
                            .contextMenu { actionMenu(for: entry) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                swipeActions(for: entry)
                            }
                    }
                }
                .listStyle(.inset)
                .scrollEdgeEffectStyle(.hard, for: .top)
                .accessibilityLabel("\(section.title) work")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .top) {
            TriageStatusView(status: presentation.status, actions: actions)
        }
        .navigationTitle(section.title)
    }

    private var entries: [TriageEntry] {
        presentation.entries(in: section, sortedBy: sortField, ascending: sortAscending)
    }

    @ViewBuilder
    private var emptyState: some View {
        if section == .inbox, isWorking {
            ContentUnavailableView {
                Label(workingTitle, systemImage: "sparkles")
            } description: {
                Text(WorkspaceViewPresentation.statusLine(presentation.status))
            } actions: {
                ProgressView().controlSize(.small)
            }
        } else {
            problemOrIdleState
        }
    }

    private var hasNeverRefreshed: Bool { presentation.status.lastRefreshAt == nil }

    private var workingTitle: String {
        if case .searching = presentation.status.phase { return "Finding your work on GitHub" }
        return "Copilot is reviewing your work"
    }

    @ViewBuilder
    private var problemOrIdleState: some View {
        switch presentation.status.problem {
        case .copilotUnavailable(let message):
            ContentUnavailableView {
                Label("Copilot needs attention", systemImage: "sparkles")
            } description: {
                Text(message)
            } actions: {
                Button("Open Copilot Settings") { actions.openCopilotSettings() }
            }
        case .gitHubUnavailable(let message):
            ContentUnavailableView {
                Label("GitHub is unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { actions.refreshNow() }
            }
        case .analysisFailed:
            ContentUnavailableView(
                "Copilot is reviewing your work",
                systemImage: "sparkles",
                description: Text("Some items will be retried automatically.")
            )
        case nil:
            if section == .inbox, hasNeverRefreshed {
                ContentUnavailableView(
                    "Getting ready",
                    systemImage: "sparkles",
                    description: Text("Triage will search GitHub for work that involves you.")
                )
            } else if section == .inbox {
                ContentUnavailableView(
                    "You’re all caught up",
                    systemImage: "checkmark.circle",
                    description: Text(lastUpdatedText)
                )
            } else {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: section.systemImage,
                    description: Text(emptyDescription)
                )
            }
        }
    }

    private var isWorking: Bool {
        switch presentation.status.phase {
        case .idle: false
        case .searching, .analyzing: true
        }
    }

    private var lastUpdatedText: String {
        guard let date = presentation.status.lastRefreshAt else {
            return "Copilot will show work here when it finds something for you."
        }
        return "Last updated \(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))."
    }

    private var emptyTitle: String {
        switch section {
        case .waiting: "Nothing is waiting on others"
        case .informational: "Nothing else needs your attention"
        case .analyzing: "Nothing is being analyzed"
        case .handled: "No completed or snoozed work"
        case .muted: "Nothing is muted"
        case .inbox: "You’re all caught up"
        }
    }

    private var emptyDescription: String {
        switch section {
        case .waiting: "Copilot will keep work here when the next step belongs to someone else."
        case .informational: "Copilot will keep low-priority updates here."
        case .analyzing: "New work will appear here while Copilot reviews it."
        case .handled: "Items you finish or snooze will stay here."
        case .muted: "Work matching your mute rules appears here. Manage rules in Settings."
        case .inbox: lastUpdatedText
        }
    }

    @ViewBuilder
    private func actionMenu(for entry: TriageEntry) -> some View {
        if section == .handled {
            Button("Restore") { actions.restore(entry) }
        } else {
            Button("Done") { actions.markDone(entry) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Menu("Snooze") {
                snoozeButtons(for: entry)
            }
            Divider()
            Button("Open on GitHub") { actions.openOnGitHub(entry) }
        }
        Divider()
        QuickRuleMenu(item: entry.item, actions: actions)
    }

    @ViewBuilder
    private func swipeActions(for entry: TriageEntry) -> some View {
        if section == .handled {
            Button("Restore") { actions.restore(entry) }
                .tint(.blue)
        } else {
            Button("Done") { actions.markDone(entry) }
                .tint(.green)
            Menu("Snooze") {
                snoozeButtons(for: entry)
            }
        }
    }

    @ViewBuilder
    private func snoozeButtons(for entry: TriageEntry) -> some View {
        Button("Later Today") { actions.snooze(entry, until: .now.addingTimeInterval(4 * 60 * 60)) }
        Button("Tomorrow") { actions.snooze(entry, until: .now.addingTimeInterval(24 * 60 * 60)) }
        Button("Next Week") { actions.snooze(entry, until: .now.addingTimeInterval(7 * 24 * 60 * 60)) }
    }
}

struct TriageEntryRow: View {
    let entry: TriageEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            priorityIndicator
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.item.title)
                    .font(.headline)
                    .lineLimit(1)

                Text("\(entry.item.reference) · \(entry.item.primaryRelationship?.title ?? "Related to you")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let analysis = WorkspaceViewPresentation.analysisLabel(entry.analysis) {
                    Text(analysis)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let decision = entry.decision {
                    Text(decision.reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let nextAction = decision.nextAction {
                        Text("→ \(nextAction)")
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }

                if !WorkspaceViewPresentation.badges(for: entry).isEmpty {
                    HStack(spacing: 5) {
                        ForEach(WorkspaceViewPresentation.badges(for: entry), id: \.self) { badge in
                            Text(badge)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }

            Spacer(minLength: 8)
            Text(entry.item.updatedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var priorityIndicator: some View {
        switch entry.decision?.disposition {
        case .act:
            Circle().fill(Color.accentColor).frame(width: 9, height: 9)
        case .review:
            Circle().stroke(Color.accentColor, lineWidth: 1.5).frame(width: 9, height: 9)
        default:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    private var accessibilityLabel: String {
        let priority = entry.decision.map { WorkspaceViewPresentation.priorityLabel($0.priority) } ?? "Pending"
        let reason = entry.decision?.reason ?? WorkspaceViewPresentation.analysisLabel(entry.analysis) ?? ""
        let nextAction = entry.decision?.nextAction.map { "Next action: \($0)" } ?? ""
        return [entry.item.title, "Priority \(priority)", reason, nextAction]
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }
}
