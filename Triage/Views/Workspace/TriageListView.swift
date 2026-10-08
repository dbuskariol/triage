import SwiftUI

struct TriageListView: View {
    let presentation: WorkspacePresentation
    let section: WorkspacePresentation.Section
    /// When set, the list shows this saved search instead of `section`.
    var savedSearch: SavedSearch?
    @Binding var selectedEntryID: GitHubNodeID?
    let actions: any WorkspaceActions
    @Binding var search: WorkspaceSearch
    var searchFocusRequest = 0
    @Environment(\.triageViewerLogin) private var viewer
    @AppStorage(TriagePreferenceKeys.sortField) private var sortField = WorkspaceSortField.recommended
    @AppStorage(TriagePreferenceKeys.sortAscending) private var sortAscending = false
    @AppStorage(TriagePreferenceKeys.grouping) private var grouping = WorkspaceGrouping.none
    @FocusState private var isListFocused: Bool
    @State private var statusNow = Date.now
    @Binding var handledFilter: HandledFilter
    @State private var isNamingSavedSearch = false
    @State private var savedSearchName = ""

    private var statusSubtitle: String {
        if effectiveSearch.isActive {
            let count = entries.count
            return "\(count) result\(count == 1 ? "" : "s")\(effectiveSearch.scope == .all ? " in all work" : "")"
        }
        return WorkspaceViewPresentation.statusLine(presentation.status, now: statusNow)
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                List(selection: $selectedEntryID) {
                    ForEach(Array(grouping.groups(entries).enumerated()), id: \.offset) { _, group in
                        if grouping == .none {
                            rows(group.entries)
                        } else {
                            Section {
                                rows(group.entries)
                            } header: {
                                HStack {
                                    Text(group.title)
                                    Spacer()
                                    Text(group.entries.count, format: .number).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollEdgeEffectStyle(.hard, for: .top)
                .accessibilityLabel("\(savedSearch?.name ?? section.title) work")
                .focused($isListFocused)
                .onAppear {
                    isListFocused = true
                    if selectedEntryID == nil { selectedEntryID = entries.first?.id }
                }
                .triageListKeys(entries: entries, selection: $selectedEntryID,
                                handledIDs: handledIDs, actions: actions)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .top) {
            VStack(spacing: 0) {
                WorkspaceSearchBar(
                    search: $search, focusRequest: searchFocusRequest,
                    suggestionSource: presentation.allEntries, actions: actions,
                    onExit: { isListFocused = true },
                    onSave: {
                        savedSearchName = effectiveSearch.summary
                        isNamingSavedSearch = true
                    }
                )
                if presentation.status.problem != nil {
                    TriageStatusView(status: presentation.status, actions: actions)
                }
                if section == .handled, !search.isActive {
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
        .navigationTitle(savedSearch?.name ?? section.title)
        .alert("Save Search", isPresented: $isNamingSavedSearch) {
            TextField("Name", text: $savedSearchName)
            Button("Save") { actions.saveSearch(named: savedSearchName) }
                .disabled(savedSearchName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The search appears in the sidebar and stays up to date.")
        }
        .navigationSubtitle(statusSubtitle)
        .task(id: presentation.status) {
            // Keep "Updated N minutes ago" current while idle.
            while !Task.isCancelled {
                statusNow = .now
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func rows(_ group: [TriageEntry]) -> some View {
        TriageEntryRows(
            entries: group, selectedEntryID: selectedEntryID, handledIDs: handledIDs, actions: actions,
            sectionLabel: { entry in
                effectiveSearch.isActive && effectiveSearch.scope == .all
                    ? presentation.section(containing: entry)?.title : nil
            }
        )
    }

    private var handledIDs: Set<GitHubNodeID> { presentation.handledIDs }

    /// A saved search refined by the field, or the field alone.
    private var effectiveSearch: WorkspaceSearch {
        savedSearch.map { $0.search.refined(by: search) } ?? search
    }

    private var entries: [TriageEntry] {
        presentation.visibleEntries(
            section: section, search: effectiveSearch, handledFilter: handledFilter,
            sortedBy: sortField, ascending: sortAscending, grouping: grouping, viewer: viewer
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        if effectiveSearch.isActive {
            ContentUnavailableView.search(text: search.text)
        } else {
            sectionEmptyState
        }
    }

    @ViewBuilder
    private var sectionEmptyState: some View {
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
}

struct TriageEntryRow: View {
    let entry: TriageEntry
    /// On the selection highlight, tinted content switches to the
    /// highlight's foreground so it stays legible.
    var isSelected = false
    /// Shown when searching all work, so you know where a result lives.
    var sectionLabel: String?

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
            if let sectionLabel {
                Text(sectionLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(secondary)
                    .padding(.horizontal, 5)
                    .background(.quaternary, in: Capsule())
            }
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
        if let effort = entry.decision?.effort, entry.decision?.nextAction != nil, entry.handledEvidence == nil {
            Label(effort.title, systemImage: effort.systemImage)
                .font(.caption)
                .foregroundStyle(secondary)
                .help(effort.detail)
        }
        if entry.handledEvidence != nil {
            Label("Handled by you", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(Color.green))
        }
        if !badges.isEmpty {
            HStack(spacing: 10) {
                ForEach(badges, id: \.self) { badge in
                    Label(badge.title, systemImage: badge.systemImage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : Self.style(for: badge))
                }
            }
            .lineLimit(1)
        }
    }

    private var secondary: AnyShapeStyle {
        isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary)
    }

    static func style(for badge: WorkspaceViewPresentation.Badge) -> AnyShapeStyle {
        if badge.isSevere { return AnyShapeStyle(Color.red) }
        return badge.isBlocking ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary)
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
