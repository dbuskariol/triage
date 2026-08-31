import SwiftUI

struct WorkDetailView: View {
    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var workspaceAccessibility: WorkspaceAccessibilityCoordinator
    let item: WorkItem?
    @FocusState private var accessibilityFocus: WorkDetailPresentation.AccessibilityFocusTarget?
    @StateObject private var workflowUndo = LocalWorkflowUndoCoordinator()

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        DetailHeader(item: item)
                        DetailSourceBodySection(item: item)
                        DetailFreshnessSection(freshness: item.freshness)
                        DetailAttentionSection(reasons: item.attentionReasons)
                        DetailActionItemsSection(item: item)
                        DetailRelatedContentSection(item: item)
                        DetailReviewStateSection(item: item)
                        DetailProjectContextSection(item: item)
                        DetailTimelineSection(item: item)
                        DetailEvidenceSection(item: item)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("work-detail")
            } else {
                ContentUnavailableView(
                    "Select work",
                    systemImage: "rectangle.stack",
                    description: Text("Choose an item to review its context and local workflow.")
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    navigation.isInspectorVisible.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help(inspectorVisibility.wrappedValue ? "Hide Inspector" : "Show Inspector")
                .accessibilityLabel(inspectorVisibility.wrappedValue ? "Hide Inspector" : "Show Inspector")
                .accessibilityIdentifier("work-detail-inspector-toggle")
                .focused($accessibilityFocus, equals: .inspectorToggle)
                .disabled(!WorkDetailPresentation.inspectorIsAvailable(hasSelection: item != nil))
            }
        }
        .focusedSceneValue(\.triageInspectorVisibility, inspectorCommandBinding)
        .onChange(of: navigation.isInspectorVisible) { _, isPresented in
            accessibilityFocus = WorkDetailPresentation.inspectorFocusTarget(isPresented: isPresented)
        }
        .onChange(of: workspaceAccessibility.requestedFocus) { _, _ in
            consumeAccessibilityFocusRequest()
        }
        .onChange(of: item?.id) { _, _ in
            consumeAccessibilityFocusRequest()
        }
        .task {
            consumeAccessibilityFocusRequest()
        }
        .inspector(isPresented: inspectorVisibility) {
            if let item {
                WorkInspectorView(
                    item: item,
                    focus: $accessibilityFocus,
                    undoCoordinator: workflowUndo,
                    undoManager: undoManager
                )
                    .frame(minWidth: 280, idealWidth: 340)
            }
        }
    }

    private var inspectorVisibility: Binding<Bool> {
        Binding(
            get: {
                WorkDetailPresentation.inspectorIsAvailable(hasSelection: item != nil)
                    && navigation.isInspectorVisible
            },
            set: { isVisible in
                guard WorkDetailPresentation.inspectorIsAvailable(hasSelection: item != nil) else { return }
                navigation.isInspectorVisible = isVisible
            }
        )
    }

    private var inspectorCommandBinding: Binding<Bool>? {
        guard WorkDetailPresentation.inspectorIsAvailable(hasSelection: item != nil) else { return nil }
        return inspectorVisibility
    }

    private func consumeAccessibilityFocusRequest() {
        guard let request = workspaceAccessibility.requestedFocus, item != nil else { return }
        switch request {
        case .search:
            return
        case .inspectorToggle:
            accessibilityFocus = .inspectorToggle
        case .inspectorFirstWorkflowControl:
            navigation.isInspectorVisible = true
            accessibilityFocus = .inspectorFirstWorkflowAction
        }
        workspaceAccessibility.consumeFocusRequest(request)
    }
}

private struct DetailHeader: View {
    let item: WorkItem

    var body: some View {
        let primaryContent = item.members.first(where: { $0.id == item.primaryNodeID })?.content
        let actors = WorkDetailPresentation.actorNames(for: item)
        let labels = WorkDetailPresentation.labelTitles(for: item)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(WorkDetailPresentation.sourceTitle(item.sourceKind), systemImage: sourceSymbol)
                Text(item.state.rawValue.capitalized)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            Text(item.title)
                .font(.largeTitle.weight(.bold))
                .textSelection(.enabled)
                .accessibilityHeading(.h1)

            if let repository = item.repository {
                LabeledContent("Repository", value: repository.fullName)
                    .foregroundStyle(.secondary)
            }
            if let number = primaryContent?.number {
                LabeledContent("Number", value: "#\(number)")
                    .foregroundStyle(.secondary)
            }
            if !actors.isEmpty {
                LabeledContent("Actors", value: actors.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
            if !labels.isEmpty {
                LabeledContent("Labels", value: labels.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
            if let sourceURL = item.sourceURL {
                ConfirmedExternalLink(title: "Open on GitHub", destination: sourceURL)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceSymbol: String {
        switch item.sourceKind {
        case .issue: "exclamationmark.circle"
        case .pullRequest: "arrow.triangle.pull"
        case .discussion: "bubble.left.and.bubble.right"
        default: "circle"
        }
    }
}

private struct DetailSourceBodySection: View {
    @EnvironmentObject private var appModel: TriageAppModel
    let item: WorkItem
    @State private var source: WorkDetailSource?
    @State private var didLoad = false

    var body: some View {
        DetailSection("Source", systemImage: "doc.plaintext") {
            if let body = source?.bodyMarkdown,
               let conciseBody = WorkDetailPresentation.conciseSourceBody(body) {
                SafeGitHubMarkdown(source: conciseBody.markdown)
                    .textSelection(.enabled)
                if conciseBody.isTruncated {
                    Text("The locally stored source body is abbreviated here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if didLoad {
                Text("No source body is available in this normalized local record.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("Loading locally stored source")
                    .controlSize(.small)
            }

            if let source {
                LabeledContent("Source updated", value: timestamp(source.updatedAt))
                LabeledContent("Observed locally", value: timestamp(source.observedAt))
                LabeledContent("Evidence revision", value: source.sourceRevision)
                    .textSelection(.enabled)
            }
            Text("This untrusted Markdown is rendered from encrypted, normalized local data. It does not fetch content from GitHub.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: item.primaryNodeID) {
            didLoad = false
            source = await appModel.localDetailSource(for: item)
            guard !Task.isCancelled else { return }
            didLoad = true
        }
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct DetailFreshnessSection: View {
    let freshness: FreshnessState

    var body: some View {
        DetailSection("Sync and coverage", systemImage: "arrow.triangle.2.circlepath") {
            LabeledContent("Status", value: WorkDetailPresentation.freshnessTitle(freshness))
            Text(WorkDetailPresentation.freshnessDescription(freshness))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let lastSuccessfulSyncAt = freshness.lastSuccessfulSyncAt {
                LabeledContent("Last successful sync", value: timestamp(lastSuccessfulSyncAt))
            } else {
                LabeledContent("Last successful sync", value: "Unavailable")
            }
            if let nextRetryAt = freshness.nextRetryAt {
                LabeledContent("Next retry", value: timestamp(nextRetryAt))
            }
        }
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct DetailAttentionSection: View {
    let reasons: [AttentionReason]

    var body: some View {
        DetailSection("Why this is here", systemImage: "exclamationmark.circle") {
            if reasons.isEmpty {
                Text("No current deterministic attention reason is attached to this item.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(reasons) { reason in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(reason.title)
                            .font(.headline)
                        Text(reason.explanation)
                            .foregroundStyle(.secondary)
                        if reason.evidence.contains(where: { $0.confirmation == .provisional }) {
                            Label("Includes provisional source evidence", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct DetailActionItemsSection: View {
    @EnvironmentObject private var appModel: TriageAppModel
    @Environment(\.undoManager) private var undoManager
    let item: WorkItem
    @State private var actionItemBeingEdited: ActionItem?
    @StateObject private var actionUndo = LocalActionItemUndoCoordinator()

    var body: some View {
        DetailSection("Action items", systemImage: "checklist") {
            if item.openActionItems.isEmpty {
                Text("No open local action items.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(item.openActionItems) { action in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Button {
                                Task { await appModel.completeActionItem(action, in: item) }
                            } label: {
                                Label("Complete \(action.title)", systemImage: "circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Marks this local action item complete. It does not change GitHub.")
                            Button("Edit") {
                                actionItemBeingEdited = action
                            }
                            .accessibilityLabel("Edit local action item: \(action.title)")
                            .accessibilityHint("Edits only the encrypted local action item. It does not change GitHub.")
                            Spacer(minLength: 12)
                            Text(priorityTitle(action.priority))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let detail = action.detail, !detail.isEmpty {
                            SafeGitHubMarkdown(source: detail)
                                .font(.callout)
                        }
                        if let dueAt = action.dueAt {
                            Label("Due \(dueAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("Action items and their completion state are stored locally and do not modify GitHub.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let feedback = actionUndo.feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(feedback)
            }
        }
        .sheet(item: $actionItemBeingEdited) { action in
            LocalActionItemEditor(actionItem: action) { edit in
                Task {
                    await actionUndo.perform(
                        edit,
                        actionItem: action,
                        in: item,
                        appModel: appModel,
                        undoManager: undoManager
                    )
                }
            }
        }
    }

    private func priorityTitle(_ priority: WorkPriority) -> String {
        switch priority {
        case .low: "Low priority"
        case .normal: "Normal priority"
        case .high: "High priority"
        }
    }
}

private struct LocalActionItemEditor: View {
    let actionItem: ActionItem
    let save: (LocalActionItemEdit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var detail: String
    @State private var priority: WorkPriority
    @State private var hasDueDate: Bool
    @State private var dueAt: Date

    init(actionItem: ActionItem, save: @escaping (LocalActionItemEdit) -> Void) {
        self.actionItem = actionItem
        self.save = save
        _title = State(initialValue: actionItem.title)
        _detail = State(initialValue: actionItem.detail ?? "")
        _priority = State(initialValue: actionItem.priority)
        _hasDueDate = State(initialValue: actionItem.dueAt != nil)
        _dueAt = State(initialValue: actionItem.dueAt ?? .now)
    }

    var body: some View {
        Form {
            Section("Local action item") {
                TextField("Title", text: $title)
                    .accessibilityIdentifier("work-detail-action-title")
                TextEditor(text: $detail)
                    .frame(minHeight: 96)
                    .accessibilityLabel("Detail")
                    .accessibilityIdentifier("work-detail-action-detail")
                Picker("Priority", selection: $priority) {
                    ForEach(WorkPriority.allCases, id: \.self) { priority in
                        Text(priorityTitle(priority)).tag(priority)
                    }
                }
                Toggle("Due date", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker("Due", selection: $dueAt, displayedComponents: [.date, .hourAndMinute])
                }
            }
            Section {
                Text("These changes are stored only in Triage’s encrypted local workflow and do not modify GitHub.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 360)
        .navigationTitle("Edit Action Item")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let edit = LocalActionItemEdit(
                        title: title,
                        detail: detail,
                        priority: priority,
                        dueAt: hasDueDate ? dueAt : nil
                    ) else { return }
                    save(edit)
                    dismiss()
                }
                .disabled(LocalActionItemEdit(title: title, detail: detail, priority: priority, dueAt: hasDueDate ? dueAt : nil) == nil)
            }
        }
    }

    private func priorityTitle(_ priority: WorkPriority) -> String {
        switch priority {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }
}

private struct DetailRelatedContentSection: View {
    let item: WorkItem

    var body: some View {
        DetailSection("Related content", systemImage: "rectangle.3.group") {
            let groups = WorkDetailPresentation.relatedContentGroups(for: item)
            if groups.isEmpty {
                Text("No related normalized nodes are available in this local record.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                        ForEach(group.contents) { content in
                            DetailRelatedContentRow(content: content)
                        }
                    }
                }
            }
            Text("Timeline and review entries appear only after their source stream has normalized them. Missing entries are not treated as an empty history.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DetailRelatedContentRow: View {
    let content: GitHubContentSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(content.title)
            HStack(spacing: 6) {
                Text(WorkDetailPresentation.sourceTitle(content.kind))
                if let number = content.number {
                    Text("#\(number)")
                }
                Text(content.state.rawValue.capitalized)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DetailEvidenceSection: View {
    let item: WorkItem

    var body: some View {
        DetailSection("Evidence and provenance", systemImage: "doc.text.magnifyingglass") {
            let evidence = WorkDetailPresentation.allEvidence(for: item)
            Text(WorkDetailPresentation.availabilityTitle(for: item))
                .font(.headline)
            if evidence.isEmpty {
                Text("Triage does not infer source evidence when a normalized record has none.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(evidence) { reference in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(reference.source.rawValue)
                            Spacer()
                            Text(reference.confirmation == .confirmed ? "Confirmed" : "Provisional")
                                .foregroundStyle(
                                    reference.confirmation == .confirmed
                                        ? Color.secondary
                                        : Color.orange
                                )
                        }
                        .font(.caption)
                        Text(reference.locator.value)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        if let excerpt = reference.excerpt, !excerpt.isEmpty {
                            SafeGitHubMarkdown(source: excerpt)
                                .font(.callout)
                        }
                        Text("Observed \(reference.observedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct DetailReviewStateSection: View {
    let item: WorkItem

    var body: some View {
        DetailSection("Review state", systemImage: "checkmark.seal") {
            if hasNormalizedReviewContext {
                Text("Normalized review-context evidence is available.")
                ForEach(WorkDetailPresentation.reviewStateSummaries(for: item), id: \.self) { summary in
                    Text(summary)
                        .font(.callout)
                }
                Text("Triage shows only normalized review relationships and does not infer approval or any review state that is absent from this local record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No normalized review state is available for this item.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hasNormalizedReviewContext: Bool {
        item.members.contains { member in
            member.role == .review || member.role == .reviewThread
        } || item.relations.contains { relation in
            switch relation.kind {
            case .containsReview, .containsThread, .reviewed, .changesRequested,
                 .reviewRequestedDirectly, .reviewRequestedFromTeam:
                true
            default:
                false
            }
        }
    }
}

private struct DetailProjectContextSection: View {
    let item: WorkItem

    var body: some View {
        DetailSection("Project context", systemImage: "square.grid.2x2") {
            let projectLinks = item.contextLinks.filter {
                $0.relation == .projectContext || $0.relation == .projectWrapsContent
            }
            if projectLinks.isEmpty {
                Text("No normalized project context is available for this item.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(projectLinks) { link in
                    DetailRelatedContentRow(content: link.content)
                }
            }
        }
    }
}

private struct DetailTimelineSection: View {
    @EnvironmentObject private var appModel: TriageAppModel
    let item: WorkItem
    @State private var entries: [WorkDetailTimelineEntry] = []
    @State private var nextCursor: WorkDetailTimelineCursor?
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        DetailSection("Timeline", systemImage: "clock.arrow.circlepath") {
            if entries.isEmpty, didLoad {
                Text("No normalized chronology is available in this local record.")
                    .foregroundStyle(.secondary)
            } else if entries.isEmpty {
                ProgressView("Loading locally stored timeline")
                    .controlSize(.small)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(WorkDetailPresentation.timelineTitle(for: entry.event))
                            .lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(WorkDetailPresentation.timelineAccessibilityLabel(for: entry.event))
                }
            }
            if nextCursor != nil {
                Button("Show More Timeline") { loadNextPage() }
                    .disabled(isLoading)
                    .accessibilityHint("Loads another bounded page of already synchronized local timeline evidence. It does not contact GitHub.")
            }
            if isLoading, didLoad {
                ProgressView("Loading more locally stored timeline")
                    .controlSize(.small)
            }
            Text("Timeline pages are read incrementally from synchronized local evidence and cancel when this detail changes. Missing entries are not interpreted as an empty history.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { loadFirstPage() }
        .onChange(of: item.id) { _, _ in
            loadFirstPage()
        }
        .onDisappear { loadTask?.cancel() }
    }

    private func loadFirstPage() {
        loadTask?.cancel()
        entries = []
        nextCursor = nil
        didLoad = false
        loadPage(after: nil, replacing: true)
    }

    private func loadNextPage() {
        guard let nextCursor, !isLoading else { return }
        loadPage(after: nextCursor, replacing: false)
    }

    private func loadPage(after cursor: WorkDetailTimelineCursor?, replacing: Bool) {
        loadTask?.cancel()
        isLoading = true
        let requestedItem = item
        loadTask = Task { @MainActor in
            let page = await appModel.localTimelinePage(
                for: requestedItem,
                after: cursor,
                limit: WorkDetailPresentation.timelinePageSize
            )
            guard !Task.isCancelled else { return }
            isLoading = false
            didLoad = true
            guard let page else { return }
            if replacing {
                entries = page.entries
            } else {
                let existingIDs = Set(entries.map(\.id))
                entries += page.entries.filter { !existingIDs.contains($0.id) }
            }
            nextCursor = page.nextCursor
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .accessibilityHeading(.h2)
                content
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct WorkInspectorView: View {
    @EnvironmentObject private var appModel: TriageAppModel
    let item: WorkItem
    @FocusState.Binding var focus: WorkDetailPresentation.AccessibilityFocusTarget?
    @ObservedObject var undoCoordinator: LocalWorkflowUndoCoordinator
    let undoManager: UndoManager?
    @State private var followUpAt = WorkDetailPresentation.defaultFollowUpDate(from: .now)

    var body: some View {
        Form {
            Section("Local workflow") {
                LabeledContent("Status", value: item.workflow.status.rawValue.capitalized)
                LabeledContent("Priority", value: priorityTitle(item.workflow.priority))
                LabeledContent("Pin", value: item.workflow.isPinned ? "Pinned" : "Not pinned")
                if let snoozedUntil = item.workflow.snoozedUntil {
                    LabeledContent("Snoozed until", value: timestamp(snoozedUntil))
                }
                if let followUpAt = item.workflow.followUpAt {
                    LabeledContent("Follow up", value: timestamp(followUpAt))
                }
                Button(item.workflow.status == .archived ? "Unarchive in Triage" : "Archive in Triage") {
                    applyLocalWorkflowAction(item.workflow.status == .archived ? .unarchive : .archive)
                }
                .accessibilityIdentifier("work-inspector-archive")
                .accessibilityHint(WorkDetailPresentation.localWorkflowAccessibilityHint)
                .focused($focus, equals: .inspectorFirstWorkflowAction)
                Button(item.workflow.isPinned ? "Unpin" : "Pin") {
                    applyLocalWorkflowAction(.setPinned(!item.workflow.isPinned))
                }
                .accessibilityIdentifier("work-inspector-pin")
                .accessibilityHint(WorkDetailPresentation.localWorkflowAccessibilityHint)
                Menu("Priority") {
                    ForEach(WorkPriority.allCases, id: \.self) { priority in
                        Button(priorityTitle(priority)) {
                            applyLocalWorkflowAction(.setPriority(priority))
                        }
                        .accessibilityHint(WorkDetailPresentation.localWorkflowAccessibilityHint)
                        .disabled(priority == item.workflow.priority)
                    }
                }
                .accessibilityIdentifier("work-inspector-priority")
                .accessibilityHint(WorkDetailPresentation.localWorkflowAccessibilityHint)
                Menu("Snooze") {
                    Button("1 Hour") {
                        applyLocalWorkflowAction(.snooze(until: .now.addingTimeInterval(3_600)))
                    }
                    .accessibilityHint(WorkDetailPresentation.localWorkflowAccessibilityHint)
                    Button("Tomorrow") {
                        applyLocalWorkflowAction(.snooze(until: .now.addingTimeInterval(86_400)))
                    }
                    .accessibilityHint(WorkDetailPresentation.localWorkflowAccessibilityHint)
                    if item.workflow.snoozedUntil != nil {
                        Button("Clear Snooze") {
                            applyLocalWorkflowAction(.clearSnooze)
                        }
                        .accessibilityHint(WorkDetailPresentation.localWorkflowAccessibilityHint)
                    }
                }
                .accessibilityIdentifier("work-inspector-snooze")
                .accessibilityHint(WorkDetailPresentation.localWorkflowAccessibilityHint)

                if item.workflow.status == .active {
                    DatePicker(
                        "Follow up",
                        selection: $followUpAt,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .accessibilityIdentifier("work-inspector-follow-up")
                    .accessibilityHint(WorkDetailPresentation.localWorkflowAccessibilityHint)
                }

                Button(item.workflow.status == .waiting ? "Stop Waiting" : "Mark Waiting") {
                    guard let action = WorkDetailPresentation.waitingAction(
                        for: item.workflow,
                        followUpAt: item.workflow.status == .active ? followUpAt : nil
                    ) else { return }
                    applyLocalWorkflowAction(action)
                }
                .accessibilityIdentifier("work-inspector-waiting")
                .accessibilityHint(WorkDetailPresentation.localWorkflowAccessibilityHint)
                .disabled(item.workflow.status == .archived)
            }

            Section("Evidence") {
                LabeledContent("Availability", value: WorkDetailPresentation.availabilityTitle(for: item))
                LabeledContent("Freshness", value: WorkDetailPresentation.freshnessTitle(item.freshness))
                if let lastSuccessfulAt = item.freshness.lastSuccessfulSyncAt {
                    LabeledContent("Last sync", value: timestamp(lastSuccessfulAt))
                } else {
                    LabeledContent("Last sync", value: "Unavailable")
                }
            }

            Section("Why this is here") {
                if item.attentionReasons.isEmpty {
                    Text("No current deterministic attention reason is attached to this item.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(item.attentionReasons) { reason in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reason.title)
                            Text(reason.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section {
                Text("These controls change only Triage's encrypted local workflow state. They do not modify GitHub.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let feedback = undoCoordinator.feedback {
                Section("Local workflow history") {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(feedback)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Inspector")
        .accessibilityIdentifier("work-inspector")
    }

    private func priorityTitle(_ priority: WorkPriority) -> String {
        switch priority {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func applyLocalWorkflowAction(_ action: WorkflowAction) {
        Task {
            await undoCoordinator.perform(
                action,
                to: item,
                appModel: appModel,
                undoManager: undoManager
            )
        }
    }
}
