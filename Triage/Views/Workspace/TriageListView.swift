import SwiftUI

struct TriageListView: View {
    let presentation: WorkspacePresentation
    let section: WorkspacePresentation.Section
    @Binding var selectedEntryID: GitHubNodeID?
    let actions: any WorkspaceActions
    @AppStorage(TriagePreferenceKeys.sortField) private var sortField = WorkspaceSortField.recommended
    @AppStorage(TriagePreferenceKeys.sortAscending) private var sortAscending = false
    @FocusState private var isListFocused: Bool
    @State private var statusNow = Date.now
    @State private var handledFilter = HandledFilter.all

    enum HandledFilter: String, CaseIterable, Identifiable {
        case all = "All", byYou = "Handled by You", done = "Done", snoozed = "Snoozed"
        var id: Self { self }

        func includes(_ entry: TriageEntry) -> Bool {
            switch (self, entry.local) {
            case (.all, _): true
            case (.byYou, .done): entry.handledEvidence != nil
            case (.done, .done): entry.handledEvidence == nil
            case (.snoozed, .snoozed): true
            default: false
            }
        }
    }

    private var statusSubtitle: String {
        WorkspaceViewPresentation.statusLine(presentation.status, now: statusNow)
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                List(selection: $selectedEntryID) {
                    ForEach(entries) { entry in
                        TriageEntryRow(entry: entry, isSelected: entry.id == selectedEntryID)
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
                .focused($isListFocused)
                .onAppear {
                    isListFocused = true
                    if selectedEntryID == nil { selectedEntryID = entries.first?.id }
                }
                // ↑/↓ are native. Mail- and Superhuman-style keys on top:
                .onKeyPress(characters: ["j", "k"]) { press in
                    move(by: press.characters == "j" ? 1 : -1)
                    return .handled
                }
                .onKeyPress(keys: [.delete, .deleteForward, "e"]) { _ in
                    guard let entry = selectedEntry else { return .ignored }
                    section == .handled ? actions.restore(entry) : actions.markDone(entry)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard let entry = selectedEntry else { return .ignored }
                    actions.openOnGitHub(entry)
                    return .handled
                }
                .onKeyPress(characters: ["s"]) { _ in
                    guard let entry = selectedEntry, section != .handled else { return .ignored }
                    actions.snooze(entry, until: SnoozeOption.tomorrow.date())
                    return .handled
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .top) {
            VStack(spacing: 0) {
                if presentation.status.problem != nil {
                    TriageStatusView(status: presentation.status, actions: actions)
                }
                if section == .handled {
                    Picker("Show", selection: $handledFilter) {
                        ForEach(HandledFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
            }
        }
        .navigationTitle(section.title)
        .navigationSubtitle(statusSubtitle)
        .task(id: presentation.status) {
            // Keep "Updated N minutes ago" current while idle.
            while !Task.isCancelled {
                statusNow = .now
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var selectedEntry: TriageEntry? {
        selectedEntryID.flatMap { id in entries.first { $0.id == id } }
    }

    private func move(by offset: Int) {
        guard !entries.isEmpty else { return }
        guard let id = selectedEntryID, let index = entries.firstIndex(where: { $0.id == id }) else {
            selectedEntryID = (offset > 0 ? entries.first : entries.last)?.id
            return
        }
        selectedEntryID = entries[min(max(index + offset, 0), entries.count - 1)].id
    }


    private var entries: [TriageEntry] {
        let sorted = presentation.entries(in: section, sortedBy: sortField, ascending: sortAscending)
        return section == .handled ? sorted.filter(handledFilter.includes) : sorted
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
        SnoozeMenuItems(entry: entry, actions: actions)
    }
}

struct TriageEntryRow: View {
    let entry: TriageEntry
    /// On the selection highlight, tinted content switches to the
    /// highlight's foreground so it stays legible.
    var isSelected = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            priorityIndicator
                .frame(width: 10)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 5) {
                sourceLine
                Text(entry.item.title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                copilotLine
                chips
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Where it lives and why it's yours: the first thing the eye reads.
    private var sourceLine: some View {
        HStack(spacing: 5) {
            Text(repositoryName)
                .font(.subheadline.weight(.semibold))
            Text(verbatim: "#\(entry.item.number)")
                .font(.subheadline)
                .foregroundStyle(secondary)
            if let relationship = entry.item.primaryRelationship {
                Text("·").foregroundStyle(secondary)
                Text(relationship.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(secondary)
            }
            Spacer(minLength: 6)
            Text(entry.item.updatedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                .font(.caption)
                .foregroundStyle(secondary)
        }
        .lineLimit(1)
    }

    /// Copilot's single most useful line: the next step, else the reason.
    @ViewBuilder
    private var copilotLine: some View {
        if let decision = entry.decision {
            Text(decision.nextAction ?? decision.reason)
                .font(.subheadline)
                .foregroundStyle(secondary)
                .lineLimit(2)
            if let analysis = WorkspaceViewPresentation.analysisLabel(entry.analysis) {
                Label(entry.analysis == .pending ? "Re-checking…" : analysis, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
        } else if let analysis = WorkspaceViewPresentation.analysisLabel(entry.analysis) {
            Text(analysis)
                .font(.subheadline)
                .foregroundStyle(secondary)
                .lineLimit(2)
        }
    }

    /// Only what blocks progress gets color; everything else stays quiet.
    @ViewBuilder
    private var chips: some View {
        let badges = WorkspaceViewPresentation.badges(for: entry)
        if entry.handledEvidence != nil {
            Label("Handled by you", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(Color.green))
        }
        if !badges.isEmpty {
            HStack(spacing: 10) {
                ForEach(badges, id: \.self) { badge in
                    Label(badge, systemImage: Self.symbol(forBadge: badge))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : Self.style(forBadge: badge))
                }
            }
            .lineLimit(1)
        }
    }

    private var secondary: AnyShapeStyle {
        isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary)
    }

    static func symbol(forBadge badge: String) -> String {
        switch badge {
        case "Checks failing": "xmark.circle.fill"
        case "Conflicts": "exclamationmark.triangle.fill"
        case "Changes requested": "arrow.uturn.backward.circle.fill"
        default: "pencil.circle"
        }
    }

    static func style(forBadge badge: String) -> AnyShapeStyle {
        switch badge {
        case "Checks failing", "Conflicts": AnyShapeStyle(Color.red)
        case "Changes requested": AnyShapeStyle(Color.orange)
        default: AnyShapeStyle(.secondary)
        }
    }

    private var repositoryName: String {
        entry.item.repository.split(separator: "/").last.map(String.init) ?? entry.item.repository
    }

    @ViewBuilder
    private var priorityIndicator: some View {
        let color: Color = isSelected ? .white : .accentColor
        switch entry.decision?.disposition {
        case .act:
            Circle().fill(color).frame(width: 9, height: 9)
                .help("Needs your action")
        case .review:
            Circle().strokeBorder(color, lineWidth: 1.5).frame(width: 9, height: 9)
                .help("Worth a look")
        default:
            Color.clear.frame(width: 9, height: 9)
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
