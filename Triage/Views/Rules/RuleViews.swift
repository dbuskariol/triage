import SwiftUI

extension EnvironmentValues {
    /// The signed-in GitHub login, for rule previews that depend on it
    /// (e.g. "review requested from me directly").
    @Entry var triageViewerLogin = ""
}

/// Live "this rule matches N items" preview against current work.
struct RulePreview: View {
    let rule: TriageRule?
    let entries: [TriageEntry]
    @Environment(\.triageViewerLogin) private var viewer

    var body: some View {
        let matches = rule.map { rule in entries.filter { rule.query.matches($0, viewer: viewer) } } ?? []
        VStack(alignment: .leading, spacing: 6) {
            Label(
                rule == nil
                    ? "Add a filter to see what this rule matches"
                    : "Matches \(matches.count) current item\(matches.count == 1 ? "" : "s")",
                systemImage: rule == nil ? "exclamationmark.circle" : "line.3.horizontal.decrease.circle"
            )
            .font(.callout.weight(.medium))
            ForEach(matches.prefix(4)) { entry in
                Text("• \(entry.item.title)")
                    .lineLimit(1)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if matches.count > 4 {
                Text("and \(matches.count - 4) more").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A rule being created or edited. From an item, `suggestions` holds
/// filters taken from it, shown as checkboxes.
struct RuleDraft: Identifiable {
    let id = UUID()
    var rule: TriageRule
    var suggestions: [SearchToken] = []
    var isNew = true
    /// Shown above the form, e.g. the item the rule was started from.
    var context: String?
}

/// The one rule editor, used from items and from Settings:
/// When (a filter) → Then (one action), with a live preview.
struct RuleEditorSheet: View {
    @State private var rule: TriageRule
    @State private var queryText: String
    private let suggestions: [SearchToken]
    private let isNew: Bool
    private let context: String?
    let entries: [TriageEntry]
    let onSave: (TriageRule) -> Void
    @Environment(\.dismiss) private var dismiss

    init(draft: RuleDraft, entries: [TriageEntry], onSave: @escaping (TriageRule) -> Void) {
        _rule = State(initialValue: draft.rule)
        _queryText = State(initialValue: draft.rule.query.description)
        suggestions = draft.suggestions
        isNew = draft.isNew
        context = draft.context
        self.entries = entries
        self.onSave = onSave
    }

    private var parsed: Result<TriageQuery, TriageQueryError> {
        Result { () throws(TriageQueryError) in try TriageQuery(parsing: queryText) }
    }

    private var draftRule: TriageRule? {
        guard case .success(let query) = parsed else { return nil }
        var value = rule
        value.query = query
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if let context {
                    Section {
                        Label(context, systemImage: "doc.text.magnifyingglass")
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Section {
                    ForEach(suggestions) { token in
                        Toggle(isOn: suggestionBinding(token)) {
                            Label(token.title, systemImage: token.systemImage)
                        }
                    }
                    TextField("Filter", text: $queryText, prompt: Text("e.g. is:review status:failing -author:@me"))
                        .font(.body.monospaced())
                        .accessibilityHint("A search filter. Combine with OR, parentheses, and minus to exclude.")
                    if case .failure(let error) = parsed {
                        Label(error.message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("When work matches")
                } footer: {
                    Text(suggestions.isEmpty
                         ? "Uses the same filters as search. Combine with OR, parentheses, and - to exclude."
                         : "Suggested from this item. Check more for a narrower rule, or edit the filter.")
                }
                Section("Then") {
                    Picker("Action", selection: $rule.action) {
                        Label(TriageRuleAction.exclude.title, systemImage: TriageRuleAction.exclude.systemImage)
                            .tag(TriageRuleAction.exclude)
                        Section("Move") {
                            ForEach(TriageRuleAction.Route.allCases, id: \.self) { route in
                                Label(TriageRuleAction.route(route).title, systemImage: TriageRuleAction.route(route).systemImage)
                                    .tag(TriageRuleAction.route(route))
                            }
                        }
                        Section("Rank") {
                            ForEach(TriageRuleAction.all.filter { $0.rankAdjustment != 0 }, id: \.self) { action in
                                Label(action.title, systemImage: action.systemImage).tag(action)
                            }
                        }
                    }
                    Text(actionExplanation).font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: $rule.name, prompt: Text(draftRule?.defaultName ?? "Optional"))
                    if !isNew { Toggle("Enabled", isOn: $rule.isEnabled) }
                }
                Section {
                    RulePreview(rule: draftRule, entries: entries)
                        .listRowInsets(EdgeInsets())
                }
            }
            .formStyle(.grouped)

            HStack {
                if isNew {
                    Text("Rules apply instantly and always win over Copilot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Rule" : "Save") {
                    guard let draftRule else { return }
                    onSave(draftRule)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draftRule == nil)
            }
            .padding(20)
        }
        .frame(width: 560, height: 620)
    }

    private var actionExplanation: String {
        switch rule.action {
        case .exclude: "Matching work is hidden everywhere — Inbox, Briefing, notifications — and kept in Hidden by Rules."
        case .route: "Matching work always goes here, whatever Copilot decides."
        case .rank: "Matching work moves up or down within its section. Rank rules add up, to a limit."
        }
    }

    private func suggestionBinding(_ token: SearchToken) -> Binding<Bool> {
        let term = TriageQuery.Node.qualifier(token.kind, token.value)
        return Binding(
            get: { (try? TriageQuery(parsing: queryText))?.terms.contains(term) == true },
            set: { _ in
                guard let current = try? TriageQuery(parsing: queryText) else {
                    queryText = TriageQuery(term).description
                    return
                }
                queryText = current.toggling(term)?.description ?? ""
            }
        )
    }
}
