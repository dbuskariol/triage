import SwiftUI

/// The detail column: what the item is, what Copilot recommends, and the
/// GitHub facts behind that recommendation.
struct TriageDetailView: View {
    let entry: TriageEntry?
    let inboxIsEmpty: Bool
    /// Every current entry, for live rule previews.
    var allEntries: [TriageEntry] = []
    let actions: any WorkspaceActions

    var body: some View {
        if let entry {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DetailHeader(item: entry.item)
                    DetailActionBar(entry: entry, actions: actions)
                    // Wide windows get a GitHub-style two-column layout; narrow
                    // windows fall back to a single readable column.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 28) {
                            primaryColumn(entry)
                                .frame(minWidth: 460, idealWidth: 460, maxWidth: .infinity, alignment: .leading)
                            secondaryColumn(entry, tileColumns: 1)
                                .frame(width: 280, alignment: .leading)
                        }
                        VStack(alignment: .leading, spacing: 20) {
                            RecommendationCard(entry: entry, allEntries: allEntries, actions: actions)
                            secondaryColumn(entry, tileColumns: nil)
                            DescriptionSection(text: entry.item.body)
                            ActivitySection(activity: entry.item.recentActivity)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 1_120, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .id(entry.id)
        } else {
            ContentUnavailableView(
                inboxIsEmpty ? "You’re all caught up" : "No Selection",
                systemImage: inboxIsEmpty ? "checkmark.circle" : "sparkles",
                description: Text(inboxIsEmpty
                    ? "Copilot will bring new work here when it needs you."
                    : "Select an item to see Copilot’s recommendation.")
            )
        }
    }
}

extension TriageDetailView {
    private func primaryColumn(_ entry: TriageEntry) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            RecommendationCard(entry: entry, allEntries: allEntries, actions: actions)
            DescriptionSection(text: entry.item.body)
            ActivitySection(activity: entry.item.recentActivity)
        }
    }

    private func secondaryColumn(_ entry: TriageEntry, tileColumns: Int?) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let facts = entry.item.pullRequest {
                PullRequestStatusGrid(facts: facts, columns: tileColumns)
            }
            PeopleSection(item: entry.item, isCompact: tileColumns != nil)
            RelatedSection(related: WorkInsights.relatedEntries(allEntries)[entry.id] ?? [], actions: actions)
        }
    }
}

/// Other work this item references or is referenced by.
private struct RelatedSection: View {
    let related: [TriageEntry]
    let actions: any WorkspaceActions

    var body: some View {
        if !related.isEmpty {
            DetailSection("Related") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(related.prefix(8)) { entry in
                        Button {
                            actions.show(entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.item.title).lineLimit(1)
                                Text(entry.item.reference).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show \(entry.item.reference)")
                    }
                }
            }
        }
    }
}

// MARK: - Header

private struct DetailHeader: View {
    let item: PersonalWorkItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StateBadge(item: item)
                Text(item.reference)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text(item.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Text(metadata)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var metadata: String {
        let kind = item.kind == .pullRequest ? "Pull request" : "Issue"
        let author = item.author.map { " by \($0)" } ?? ""
        let opened = item.createdAt.formatted(date: .abbreviated, time: .omitted)
        let updated = item.updatedAt.formatted(.relative(presentation: .named))
        return "\(kind)\(author) · Opened \(opened) · Updated \(updated)"
    }
}

private struct StateBadge: View {
    let item: PersonalWorkItem

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.gradient, in: Capsule())
    }

    private var isDraft: Bool { item.pullRequest?.isDraft == true && item.state == .open }

    private var title: String {
        if isDraft { return "Draft" }
        switch item.state {
        case .open: return "Open"
        case .closed: return "Closed"
        case .merged: return "Merged"
        }
    }

    private var symbol: String {
        if item.kind == .issue {
            return item.state == .open ? "circle.circle" : "checkmark.circle"
        }
        switch item.state {
        case .open: return isDraft ? "pencil.circle" : "arrow.triangle.pull"
        case .closed: return "xmark.circle"
        case .merged: return "arrow.triangle.merge"
        }
    }

    private var tint: Color {
        if isDraft { return .gray }
        switch item.state {
        case .open: return .green
        case .closed: return item.kind == .issue ? .purple : .red
        case .merged: return .purple
        }
    }
}

// MARK: - Actions

private struct DetailActionBar: View {
    let entry: TriageEntry
    let actions: any WorkspaceActions

    var body: some View {
        HStack(spacing: 10) {
            Button {
                actions.openOnGitHub(entry)
            } label: {
                Label("Open on GitHub", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
            .help("Open on GitHub (⌘O)")

            if isHandled {
                Button {
                    actions.restore(entry)
                } label: {
                    Label("Move to Inbox", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button {
                    actions.markDone(entry)
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .help("Mark done until something changes (⌘E)")

                Menu {
                    SnoozeMenuItems(entry: entry, actions: actions)
                } label: {
                    Label("Snooze", systemImage: "moon.zzz")
                }
                .fixedSize()
                .help("Hide until later")
            }

            Button {
                actions.beginDraft(for: entry)
            } label: {
                Label("Draft Reply…", systemImage: "sparkles")
            }
            .help("Have Copilot draft a reply you can edit (⌥⌘D)")

            Button {
                actions.beginRule(from: entry, correcting: false)
            } label: {
                Label("Create Rule…", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Create a rule for work like this (⌥⌘R)")

            Spacer(minLength: 0)

            ShareLink(item: entry.item.url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .help("Share or copy the GitHub link")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var isHandled: Bool {
        if case .active = entry.local { return false }
        return true
    }

}

// MARK: - Copilot recommendation

private struct RecommendationCard: View {
    let entry: TriageEntry
    let allEntries: [TriageEntry]
    let actions: any WorkspaceActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(heading, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(tint)
                Spacer()
                Label("Copilot", systemImage: "sparkles")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let evidence = entry.handledEvidence {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Handled by you").fontWeight(.semibold)
                        Text(evidence).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Button("Move Back to Inbox") { actions.restore(entry) }
                        .controlSize(.small)
                }
                .padding(10)
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if let decision = entry.decision {
                Text(decision.summary)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let nextAction = decision.nextAction {
                    Label {
                        Text(nextAction).fontWeight(.medium)
                    } icon: {
                        Image(systemName: "arrow.forward.circle.fill").foregroundStyle(tint)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Why").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Text(decision.reason)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                HStack(spacing: 24) {
                    Meter(title: "Priority", label: WorkspaceViewPresentation.priorityLabel(decision.priority),
                          value: Double(decision.priority) / 100, tint: tint)
                    Meter(title: "Confidence", label: WorkspaceViewPresentation.confidenceLabel(decision.confidence),
                          value: decision.confidence, tint: .secondary)
                    if let effort = decision.effort {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Effort").font(.caption).foregroundStyle(.secondary)
                            Label(effort.title, systemImage: effort.systemImage)
                                .font(.caption.weight(.medium))
                                .help(effort.detail)
                        }
                    }
                }

                attribution(decision)

                HStack {
                    if let pending = WorkspaceViewPresentation.analysisLabel(entry.analysis) {
                        Label("Updated facts are being re-analyzed · \(pending)", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Analyzed \(decision.decidedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Not right?") { actions.beginRule(from: entry, correcting: true) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Teach Triage how to handle work like this")
                }
            } else {
                HStack(spacing: 10) {
                    if case .pending = entry.analysis { ProgressView().controlSize(.small) }
                    Text(WorkspaceViewPresentation.analysisLabel(entry.analysis) ?? "Waiting for Copilot")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.07))
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        }
    }

    private var disposition: TriageDisposition? { entry.decision?.disposition }

    /// Shows exactly which of the user's preferences shaped this result.
    @ViewBuilder
    private func attribution(_ decision: TriageDecision) -> some View {
        if !entry.appliedRules.isEmpty || decision.instructionNote != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !entry.appliedRules.isEmpty {
                    Label {
                        Text("Your rule\(entry.appliedRules.count == 1 ? "" : "s"): ").foregroundStyle(.secondary)
                            + Text(entry.appliedRules.joined(separator: ", ")).fontWeight(.medium)
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(tint)
                    }
                }
                if let note = decision.instructionNote {
                    Label {
                        Text("Your instructions: ").foregroundStyle(.secondary) + Text(note)
                    } icon: {
                        Image(systemName: "text.quote").foregroundStyle(tint)
                    }
                }
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture { actions.openRulesSettings() }
            .help("Manage rules in Settings")
        }
    }

    private var heading: String {
        disposition.map(WorkspaceViewPresentation.dispositionLabel) ?? "Copilot is reviewing this"
    }

    private var symbol: String {
        switch disposition {
        case .some(.act): "exclamationmark.circle.fill"
        case .some(.review): "eye.circle.fill"
        case .some(.wait): "hourglass.circle.fill"
        case .some(.none): "checkmark.circle.fill"
        case nil: "sparkles"
        }
    }

    private var tint: Color {
        switch disposition {
        case .some(.act): .orange
        case .some(.review): .blue
        case .some(.wait): .yellow
        case .some(.none): .green
        case nil: .secondary
        }
    }
}

private struct Meter: View {
    let title: String
    let label: String
    let value: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(label).fontWeight(.medium)
            }
            .font(.caption)
            ProgressView(value: min(max(value, 0), 1))
                .progressViewStyle(.linear)
                .tint(tint)
        }
        .frame(maxWidth: 200)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(label)")
    }
}

// MARK: - Pull request status

private struct PullRequestStatusGrid: View {
    let facts: PullRequestFacts
    /// Fixed column count for a narrow sidebar; `nil` adapts to the width.
    let columns: Int?

    private var gridItems: [GridItem] {
        if let columns { return Array(repeating: GridItem(.flexible(), spacing: 10), count: columns) }
        return [GridItem(.adaptive(minimum: 160), spacing: 10)]
    }

    var body: some View {
        DetailSection("Status") {
            LazyVGrid(columns: gridItems, spacing: 8) {
                StatusTile(title: "Checks", value: checks.text, symbol: checks.symbol, tint: checks.tint)
                StatusTile(title: "Review", value: review.text, symbol: review.symbol, tint: review.tint)
                StatusTile(title: "Merge", value: merge.text, symbol: merge.symbol, tint: merge.tint)
                StatusTile(
                    title: "Threads",
                    value: facts.unresolvedReviewThreads == 0 ? "All resolved" : "\(facts.unresolvedReviewThreads) unresolved",
                    symbol: facts.unresolvedReviewThreads == 0 ? "bubble.left.and.bubble.right" : "bubble.left.and.exclamationmark.bubble.right",
                    tint: facts.unresolvedReviewThreads == 0 ? .secondary : .orange
                )
                DiffTile(additions: facts.additions, deletions: facts.deletions)
            }
        }
    }

    private typealias Fact = (text: String, symbol: String, tint: Color)

    private var checks: Fact {
        switch facts.checks {
        case .success: ("Passing", "checkmark.circle.fill", .green)
        case .failure, .error: ("Failing", "xmark.circle.fill", .red)
        case .pending, .expected: ("Running", "clock.fill", .yellow)
        case nil: ("Not reported", "minus.circle", .secondary)
        }
    }

    private var review: Fact {
        switch facts.reviewDecision {
        case .approved: ("Approved", "checkmark.seal.fill", .green)
        case .changesRequested: ("Changes requested", "exclamationmark.bubble.fill", .red)
        case .reviewRequired: ("Review required", "person.badge.clock", .orange)
        case nil: ("No review needed", "person", .secondary)
        }
    }

    private var merge: Fact {
        switch facts.mergeable?.uppercased() {
        case "MERGEABLE": ("No conflicts", "arrow.triangle.merge", .green)
        case "CONFLICTING": ("Conflicts", "exclamationmark.triangle.fill", .red)
        default: ("Checking", "questionmark.circle", .secondary)
        }
    }
}

private struct StatusTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.medium)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct DiffTile: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plusminus.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("Size").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("+\(additions.formatted())").foregroundStyle(.green)
                    Text("−\(deletions.formatted())").foregroundStyle(.red)
                }
                .font(.callout.weight(.medium).monospacedDigit())
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Size: \(additions) additions, \(deletions) deletions")
    }
}

// MARK: - People and labels

private struct PeopleSection: View {
    let item: PersonalWorkItem
    let isCompact: Bool

    var body: some View {
        DetailSection("Why you’re seeing this") {
            if isCompact {
                VStack(alignment: .leading, spacing: 12) { rows }
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) { rows }
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        Group {
                row("You") {
                    FlowLayout {
                        ForEach(relationships, id: \.self) { Chip(text: $0.title, symbol: symbol(for: $0), tint: .accentColor) }
                    }
                }
                if !item.assignees.isEmpty {
                    row("Assignees") { FlowLayout { ForEach(item.assignees, id: \.self) { PersonChip(login: $0) } } }
                }
                if let facts = item.pullRequest, !facts.requestedReviewers.isEmpty {
                    row("Reviewers") { FlowLayout { ForEach(facts.requestedReviewers, id: \.self) { PersonChip(login: $0) } } }
                }
                if let facts = item.pullRequest, !facts.latestReviews.isEmpty {
                    row("Reviews") {
                        FlowLayout {
                            ForEach(Array(facts.latestReviews.enumerated()), id: \.offset) { _, review in
                                PersonChip(login: review.author, state: review.state)
                            }
                        }
                    }
                }
                if !item.labels.isEmpty {
                    row("Labels") { FlowLayout { ForEach(item.labels, id: \.self) { Chip(text: $0, symbol: "tag", tint: .secondary) } } }
                }
        }
    }

    private var relationships: [WorkRelationship] {
        item.relationships.sorted { $0.urgencyRank < $1.urgencyRank }
    }

    @ViewBuilder
    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                content()
            }
        } else {
            GridRow {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                content()
            }
        }
    }

    private func symbol(for relationship: WorkRelationship) -> String {
        switch relationship {
        case .reviewRequested: "eye"
        case .assigned: "person.crop.circle.badge.checkmark"
        case .authored: "pencil"
        case .mentioned: "at"
        case .commented: "text.bubble"
        }
    }
}

private struct Chip: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint == .secondary ? Color.primary : tint)
    }
}

private struct PersonChip: View {
    let login: String
    var state: String?

    var body: some View {
        HStack(spacing: 6) {
            InitialAvatar(text: login, size: 18)
            Text(login).font(.callout)
            if let stateSymbol {
                Image(systemName: stateSymbol.name).foregroundStyle(stateSymbol.tint).font(.caption)
            }
        }
        .padding(.leading, 3)
        .padding(.trailing, 9)
        .padding(.vertical, 3)
        .background(.quinary, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.map { "\(login), \($0.lowercased().replacingOccurrences(of: "_", with: " "))" } ?? login)
    }

    private var stateSymbol: (name: String, tint: Color)? {
        switch state?.uppercased() {
        case "APPROVED": ("checkmark.circle.fill", .green)
        case "CHANGES_REQUESTED": ("exclamationmark.circle.fill", .red)
        case "COMMENTED": ("text.bubble.fill", .secondary)
        case "DISMISSED": ("xmark.circle", .secondary)
        case nil: nil
        default: ("circle", .secondary)
        }
    }
}

// MARK: - Description and activity

private struct DescriptionSection: View {
    let text: String
    @State private var isExpanded = false
    @State private var contentHeight: CGFloat = 0
    private let collapsedHeight: CGFloat = 240

    var body: some View {
        if !text.isEmpty {
            DetailSection("Description") {
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownText(source: text)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                        .frame(maxHeight: isCollapsible && !isExpanded ? collapsedHeight : nil, alignment: .top)
                        .clipped()
                        .mask {
                            if isCollapsible && !isExpanded {
                                LinearGradient(stops: [.init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                                               startPoint: .top, endPoint: .bottom)
                            } else {
                                Rectangle()
                            }
                        }
                    if isCollapsible {
                        Button(isExpanded ? "Show Less" : "Show More") {
                            withAnimation(.snappy) { isExpanded.toggle() }
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(14)
                .background(.quinary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var isCollapsible: Bool { contentHeight > collapsedHeight + 40 }
}

private struct ActivitySection: View {
    let activity: [ActivityFact]

    var body: some View {
        if !activity.isEmpty {
            DetailSection("Recent activity") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(activity.reversed().enumerated()), id: \.offset) { index, fact in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 0) {
                                InitialAvatar(text: fact.author, size: 26)
                                if index < activity.count - 1 {
                                    Rectangle().fill(.quaternary).frame(width: 2).frame(maxHeight: .infinity)
                                }
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(fact.author).font(.callout.weight(.semibold))
                                    Text(fact.createdAt.formatted(.relative(presentation: .named)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                MarkdownText(source: fact.excerpt)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Building blocks

private struct DetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
