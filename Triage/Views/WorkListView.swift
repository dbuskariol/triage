import SwiftUI

struct WorkListView: View {
    private enum SearchScope: String, CaseIterable, Identifiable {
        case currentView
        case organization

        var id: Self { self }

        var title: String {
            switch self {
            case .currentView: "Current View"
            case .organization: "Selected Organization"
            }
        }
    }

    private enum SearchSort: String, CaseIterable, Identifiable {
        case relevance
        case attention
        case recent

        var id: Self { self }

        var title: String {
            switch self {
            case .relevance: "Relevance"
            case .attention: "Attention"
            case .recent: "Recent Activity"
            }
        }
    }

    @EnvironmentObject private var appModel: TriageAppModel
    @EnvironmentObject private var navigation: AppNavigationModel
    @State private var searchText = ""
    @State private var searchScope = SearchScope.currentView
    @State private var searchSort = SearchSort.relevance
    @State private var searchResults: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?

    var body: some View {
        List(selection: $appModel.selectedWorkItemID) {
            ForEach(filteredWorkItems) { item in
                WorkItemRow(item: item, highlightedQuery: searchText)
                    .tag(item.id)
            }
        }
        .navigationTitle(navigation.section.title)
        .searchable(text: $searchText, prompt: "Search work")
        .searchScopes($searchScope) {
            ForEach(SearchScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Menu("Search Options") {
                    Picker("Sort Results", selection: $searchSort) {
                        ForEach(SearchSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task(id: searchRequestID) {
            await updateSearchResults()
        }
        .onKeyPress(.escape) {
            guard !searchText.isEmpty else { return .ignored }
            searchText = ""
            return .handled
        }
        .overlay {
            if filteredWorkItems.isEmpty {
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
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return AttentionRanker().sort(currentViewItems, at: now)
        }

        let allowedItems = searchScope == .currentView ? currentViewItems : appModel.workItems
        let itemsByID = Dictionary(uniqueKeysWithValues: allowedItems.map { ($0.id, $0) })
        let resultRanks = Dictionary(
            uniqueKeysWithValues: searchResults.compactMap { result in
                result.workItemID.map { ($0, result.rank) }
            }
        )
        let matching = itemsByID.values.filter { resultRanks[$0.id] != nil }
        switch searchSort {
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

    private var searchRequestID: String {
        [
            appModel.selectedAccountID?.rawValue ?? "",
            appModel.selectedOrganizationID?.rawValue ?? "",
            searchText
        ].joined(separator: "\u{1F}")
    }

    private func updateSearchResults() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            searchError = nil
            isSearching = false
            return
        }

        isSearching = true
        searchError = nil
        do {
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
            searchResults = try await appModel.searchCachedWork(query)
        } catch is CancellationError {
            return
        } catch {
            searchResults = []
            searchError = "Triage could not search its encrypted cache."
        }
        isSearching = false
    }
}

private struct WorkItemRow: View {
    let item: WorkItem
    let highlightedQuery: String

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
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
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
        let repository = item.repository.map { " in \($0.fullName)" } ?? ""
        let reason = item.attentionReasons.max(by: { $0.strength < $1.strength }).map { ", \($0.title)" } ?? ""
        return "\(item.sourceKind.rawValue), \(item.title)\(repository)\(reason)"
    }
}
