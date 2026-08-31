import SwiftUI

struct WorkListView: View {
    @EnvironmentObject private var appModel: TriageAppModel
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var workspaceAccessibility: WorkspaceAccessibilityCoordinator
    @State private var searchText = ""
    @State private var searchResults: [SearchResult] = []
    @State private var searchResultsRequest: WorkListSearchRequest?
    @State private var isSearching = false
    @State private var searchError: String?
    @FocusState private var searchFocus: Bool

    var body: some View {
        List(selection: $appModel.selectedWorkItemID) {
            ForEach(filteredWorkItems) { item in
                WorkItemRow(
                    item: item,
                    highlightedQuery: searchText,
                    onWorkflowOperation: applyContextMenuOperation
                )
                    .tag(item.id)
            }
        }
        .navigationTitle(navigation.section.title)
        .searchable(text: $searchText, prompt: "Search work")
        .focused($searchFocus)
        .focusedSceneValue(
            \.triageSearchFocus,
            Binding(
                get: { searchFocus },
                set: { searchFocus = $0 }
            )
        )
        .searchScopes(searchScope) {
            ForEach(WorkspaceSearchScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Menu("List Options") {
                    Picker("Filter", selection: listFilter) {
                        ForEach(WorkspaceListFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }

                    Divider()

                    Picker("Sort Results", selection: searchSort) {
                        ForEach(WorkspaceSearchSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .accessibilityHint("Filters and sorts only the local Triage work queue.")
            }
        }
        .task(id: searchRequest) { [request = searchRequest] in
            await updateSearchResults(for: request)
        }
        .task(id: selectionRestorationRequest) {
            restoreSelectedWorkItem()
        }
        .onChange(of: appModel.selectedWorkItemID) { _, workItemID in
            persistSelectedWorkItem(workItemID)
        }
        .onChange(of: workspaceAccessibility.requestedFocus) { _, _ in
            consumeAccessibilityFocusRequest()
        }
        .task {
            consumeAccessibilityFocusRequest()
        }
        .onKeyPress(.escape) {
            guard !searchText.isEmpty else { return .ignored }
            searchText = ""
            return .handled
        }
        .overlay {
            if !isSearching, filteredWorkItems.isEmpty {
                ContentUnavailableView(
                    navigation.section == .inbox ? "Inbox zero" : "No work",
                    systemImage: navigation.section.systemImage,
                    description: Text(emptyDescription)
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            if appModel.isRefreshing {
                ProgressView("Refreshing GitHub work…")
                    .controlSize(.small)
                    .padding(8)
            } else if isSearching {
                ProgressView("Searching encrypted cache…")
                    .controlSize(.small)
                    .padding(8)
            } else if let searchError {
                Text(searchError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else if let refreshError = appModel.refreshError {
                HStack(spacing: 10) {
                    Text(refreshError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let header = appModel.ssoAuthorizationHeader,
                       case .authorizationRequired = header
                    {
                        Button("Authorize in Browser") {
                            _ = SSOAuthorizationCoordinator().authorizeInBrowser(header)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(8)
            }
        }
    }

    private var filteredWorkItems: [WorkItem] {
        let now = Date()
        let currentViewItems = appModel.workItems.filter { item in
            switch navigation.section {
            case .inbox:
                InboxEligibilityRule().disposition(for: item, at: now) == .inbox
            case .waiting:
                InboxEligibilityRule().disposition(for: item, at: now) == .waiting
            case .snoozed:
                InboxEligibilityRule().disposition(for: item, at: now) == .snoozed
            case .myWork:
                item.relations.contains { $0.kind == .assigned || $0.kind == .authored }
            case .reviews:
                item.relations.contains {
                    $0.kind == .reviewRequestedDirectly || $0.kind == .reviewRequestedFromTeam
                }
            case .allWork:
                true
            }
        }.filter(matchesListFilter)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return AttentionRanker().sort(currentViewItems, at: now)
        }

        let allowedItems = navigation.searchScope == .currentView
            ? currentViewItems
            : appModel.workItems.filter(matchesListFilter)
        let itemsByID = Dictionary(uniqueKeysWithValues: allowedItems.map { ($0.id, $0) })
        // Results only belong to the exact query and workspace that produced
        // them. This prevents an old query (or another organization with an
        // overlapping work-item ID) from rendering during a new debounce.
        guard WorkListPresentation.shouldUseSearchResults(
            producedFor: searchResultsRequest,
            currentRequest: searchRequest
        ) else {
            return []
        }
        let resultRanks = Dictionary(
            uniqueKeysWithValues: searchResults.compactMap { result in
                result.workItemID.map { ($0, result.rank) }
            }
        )
        let matching = itemsByID.values.filter { resultRanks[$0.id] != nil }
        switch navigation.searchSort {
        case .relevance:
            return matching.sorted {
                let lhsRank = resultRanks[$0.id] ?? .greatestFiniteMagnitude
                let rhsRank = resultRanks[$1.id] ?? .greatestFiniteMagnitude
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return $0.id.rawValue < $1.id.rawValue
            }
        case .attention:
            return AttentionRanker().sort(matching, at: now)
        case .recent:
            return matching.sorted {
                if $0.lastRelevantActivityAt != $1.lastRelevantActivityAt {
                    return $0.lastRelevantActivityAt > $1.lastRelevantActivityAt
                }
                return $0.id.rawValue < $1.id.rawValue
            }
        }
    }

    private var emptyDescription: String {
        if !searchText.isEmpty {
            return "No cached work in this organization matches “\(searchText)”."
        }
        return navigation.section == .inbox
            ? "Nothing currently needs your attention."
            : "No synchronized work matches this view."
    }

    private var searchRequest: WorkListSearchRequest {
        WorkListSearchRequest(
            accountID: appModel.selectedAccountID,
            organizationID: appModel.selectedOrganizationID,
            query: searchText
        )
    }

    private var searchScope: Binding<WorkspaceSearchScope> {
        Binding(
            get: { navigation.searchScope },
            set: { navigation.searchScope = $0 }
        )
    }

    private var searchSort: Binding<WorkspaceSearchSort> {
        Binding(
            get: { navigation.searchSort },
            set: { navigation.searchSort = $0 }
        )
    }

    private var listFilter: Binding<WorkspaceListFilter> {
        Binding(
            get: { navigation.listFilter },
            set: { navigation.listFilter = $0 }
        )
    }

    private var selectionRestorationRequest: WorkListSelectionRestorationRequest {
        WorkListSelectionRestorationRequest(
            accountID: appModel.selectedAccountID,
            organizationID: appModel.selectedOrganizationID,
            validWorkItemIDs: Set(appModel.workItems.map(\.id))
        )
    }

    private func matchesListFilter(_ item: WorkItem) -> Bool {
        switch navigation.listFilter {
        case .all:
            true
        case .pinned:
            item.workflow.isPinned
        case .highPriority:
            item.workflow.priority == .high
        case .openActionItems:
            !item.openActionItems.isEmpty
        }
    }

    private func restoreSelectedWorkItem() {
        guard let accountID = appModel.selectedAccountID,
              let organizationID = appModel.selectedOrganizationID
        else {
            appModel.selectedWorkItemID = nil
            return
        }

        appModel.selectedWorkItemID = navigation.validatedSelectedWorkItem(
            accountID: accountID,
            organizationID: organizationID,
            validWorkItemIDs: selectionRestorationRequest.validWorkItemIDs
        )
    }

    private func consumeAccessibilityFocusRequest() {
        guard workspaceAccessibility.requestedFocus == .search else { return }
        searchFocus = true
        workspaceAccessibility.consumeFocusRequest(.search)
    }

    private func persistSelectedWorkItem(_ workItemID: WorkItemID?) {
        guard let accountID = appModel.selectedAccountID,
              let organizationID = appModel.selectedOrganizationID
        else {
            return
        }

        navigation.setSelectedWorkItem(
            workItemID,
            accountID: accountID,
            organizationID: organizationID
        )
    }

    private func updateSearchResults(for request: WorkListSearchRequest) async {
        let query = request.query
        guard !query.isEmpty else {
            searchResults = []
            searchResultsRequest = nil
            searchError = nil
            isSearching = false
            return
        }

        // Clear immediately, before the debounce and database await. The
        // request identity remains a second line of defence if cancellation
        // is observed after a newer task has begun.
        searchResults = []
        searchResultsRequest = nil
        isSearching = true
        searchError = nil
        do {
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
            let results = try await appModel.searchCachedWork(query)
            guard WorkListPresentation.shouldApplySearchResult(
                for: request,
                currentRequest: searchRequest,
                isCancelled: Task.isCancelled
            ) else {
                return
            }
            searchResults = results
            searchResultsRequest = request
        } catch is CancellationError {
            return
        } catch {
            guard WorkListPresentation.shouldApplySearchResult(
                for: request,
                currentRequest: searchRequest,
                isCancelled: Task.isCancelled
            ) else {
                return
            }
            searchResults = []
            searchResultsRequest = request
            searchError = "Triage could not search its encrypted cache."
        }
        guard WorkListPresentation.shouldApplySearchResult(
            for: request,
            currentRequest: searchRequest,
            isCancelled: Task.isCancelled
        ) else {
            return
        }
        isSearching = false
    }

    private func applyContextMenuOperation(
        _ operation: WorkItemContextMenuOperation,
        to item: WorkItem
    ) {
        // The contextual row, rather than an older list selection, is the
        // action target. The List keeps that explicit selection after the
        // local workflow update whenever the row remains visible.
        appModel.selectedWorkItemID = item.id
        let action = operation.workflowAction(now: Date())
        Task {
            await appModel.applyWorkflowAction(action, to: item)
        }
    }
}

private struct WorkItemRow: View {
    let item: WorkItem
    let highlightedQuery: String
    let onWorkflowOperation: (WorkItemContextMenuOperation, WorkItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                highlightedTitle
                    .lineLimit(1)
                Spacer(minLength: 8)
                if item.workflow.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
            }
            HStack(spacing: 6) {
                if let repository = item.repository {
                    Text(repository.fullName)
                }
                if let reason = item.attentionReasons.max(by: { $0.strength < $1.strength }) {
                    Text(reason.title)
                }
                if !item.openActionItems.isEmpty {
                    Text("\(item.openActionItems.count) action\(item.openActionItems.count == 1 ? "" : "s")")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            WorkItemRowMetadata(item: item)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .contextMenu {
            WorkItemContextMenu(
                item: item,
                onOperation: onWorkflowOperation
            )
        }
    }

    private var symbol: String {
        switch item.sourceKind {
        case .issue: "exclamationmark.circle"
        case .pullRequest: "arrow.triangle.pull"
        case .discussion: "bubble.left.and.bubble.right"
        default: "circle"
        }
    }

    private var highlightedTitle: Text {
        let terms = highlightedQuery
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(12)
            .map(String.init)
        guard !terms.isEmpty else { return Text(item.title) }

        var result = Text("")
        var cursor = item.title.startIndex
        while cursor < item.title.endIndex {
            let matches = terms.compactMap { term -> Range<String.Index>? in
                item.title.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: cursor..<item.title.endIndex
                )
            }
            guard let match = matches.min(by: { lhs, rhs in
                if lhs.lowerBound != rhs.lowerBound { return lhs.lowerBound < rhs.lowerBound }
                return lhs.upperBound > rhs.upperBound
            }) else {
                result = Text("\(result)\(Text(String(item.title[cursor...])))")
                break
            }
            result = Text("\(result)\(Text(String(item.title[cursor..<match.lowerBound])))")
            result = Text("\(result)\(Text(String(item.title[match])).bold())")
            cursor = match.upperBound
        }
        return result
    }

    private var accessibilityLabel: String {
        WorkListPresentation.accessibilityLabel(for: item, at: Date())
    }
}

private struct WorkItemRowMetadata: View {
    let item: WorkItem

    var body: some View {
        let metadata = WorkListPresentation.visibleMetadata(for: item, at: Date())
        if !metadata.isEmpty {
            HStack(spacing: 6) {
                ForEach(metadata, id: \.self) { value in
                    Text(value)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .accessibilityHidden(true)
        }
    }
}

private struct WorkItemContextMenu: View {
    let item: WorkItem
    let onOperation: (WorkItemContextMenuOperation, WorkItem) -> Void

    private var policy: WorkItemContextMenuPolicy {
        WorkItemContextMenuPolicy(item: item)
    }

    var body: some View {
        if let archiveOperation = policy.archiveOperation {
            Button(archiveOperation == .archive ? "Archive in Triage" : "Restore in Triage") {
                apply(archiveOperation)
            }
            .accessibilityHint(WorkItemContextMenuPolicy.localOnlyAccessibilityHint)
        }

        Button(item.workflow.isPinned ? "Unpin in Triage" : "Pin in Triage") {
            apply(policy.pinOperation)
        }
        .accessibilityHint(WorkItemContextMenuPolicy.localOnlyAccessibilityHint)

        Menu("Set Priority") {
            ForEach(policy.priorityOperations.indices, id: \.self) { index in
                let operation = policy.priorityOperations[index]
                Button(priorityTitle(for: operation)) {
                    apply(operation)
                }
                .accessibilityHint(WorkItemContextMenuPolicy.localOnlyAccessibilityHint)
            }
        }
        .accessibilityHint(WorkItemContextMenuPolicy.localOnlyAccessibilityHint)

        if !policy.snoozeOperations.isEmpty || policy.clearSnoozeOperation != nil {
            Menu("Snooze") {
                ForEach(policy.snoozeOperations.indices, id: \.self) { index in
                    let operation = policy.snoozeOperations[index]
                    Button(snoozeTitle(for: operation)) {
                        apply(operation)
                    }
                    .accessibilityHint(WorkItemContextMenuPolicy.localOnlyAccessibilityHint)
                }
                if let clearSnoozeOperation = policy.clearSnoozeOperation {
                    if !policy.snoozeOperations.isEmpty {
                        Divider()
                    }
                    Button("End Snooze") {
                        apply(clearSnoozeOperation)
                    }
                    .accessibilityHint(WorkItemContextMenuPolicy.localOnlyAccessibilityHint)
                }
            }
            .accessibilityHint(WorkItemContextMenuPolicy.localOnlyAccessibilityHint)
        }

        if let waitingOperation = policy.waitingOperation {
            Button(waitingOperation == .markWaiting ? "Mark Waiting" : "Stop Waiting") {
                apply(waitingOperation)
            }
            .accessibilityHint(WorkItemContextMenuPolicy.localOnlyAccessibilityHint)
        }
    }

    private func apply(_ operation: WorkItemContextMenuOperation) {
        onOperation(operation, item)
    }

    private func priorityTitle(for operation: WorkItemContextMenuOperation) -> String {
        guard case let .setPriority(priority) = operation else { return "Priority" }
        return switch priority {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }

    private func snoozeTitle(for operation: WorkItemContextMenuOperation) -> String {
        switch operation {
        case .snooze(.oneHour): "Snooze for One Hour"
        case .snooze(.tomorrow): "Snooze Until Tomorrow"
        case .snooze(.nextWeek): "Snooze Until Next Week"
        default: "Snooze"
        }
    }
}
