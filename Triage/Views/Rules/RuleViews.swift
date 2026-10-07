import SwiftUI

extension EnvironmentValues {
    /// The signed-in GitHub login, for rule previews that depend on it
    /// (e.g. "review requested from me directly").
    @Entry var triageViewerLogin = ""
}

/// Live "this rule matches N items" preview against current work.
struct RulePreview: View {
    let rule: TriageRule
    let entries: [TriageEntry]
    @Environment(\.triageViewerLogin) private var viewer

    var body: some View {
        let matches = entries.filter { rule.matches($0.item, viewer: viewer) }
        VStack(alignment: .leading, spacing: 6) {
            Label(
                rule.isValid
                    ? "Matches \(matches.count) current item\(matches.count == 1 ? "" : "s")"
                    : "Add a value to every condition",
                systemImage: rule.isValid ? "line.3.horizontal.decrease.circle" : "exclamationmark.circle"
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
    }
}

/// A rule being created or edited. From an item, `suggestions` holds
/// conditions taken from it, shown as checkboxes.
struct RuleDraft: Identifiable {
    let id = UUID()
    var rule: TriageRule
    var suggestions: [TriageRuleCondition] = []
    var isNew = true
    /// Shown above the form, e.g. the item the rule was started from.
    var context: String?
}

/// The one rule editor, used from items and from Settings:
/// When (suggested and custom conditions) → Then (one action), with a live preview.
struct RuleEditorSheet: View {
    @State private var rule: TriageRule
    private let suggestions: [TriageRuleCondition]
    private let isNew: Bool
    private let context: String?
    let entries: [TriageEntry]
    let onSave: (TriageRule) -> Void
    @Environment(\.dismiss) private var dismiss

    init(draft: RuleDraft, entries: [TriageEntry], onSave: @escaping (TriageRule) -> Void) {
        _rule = State(initialValue: draft.rule)
        suggestions = draft.suggestions
        isNew = draft.isNew
        context = draft.context
        self.entries = entries
        self.onSave = onSave
    }

    private var customIndices: [Int] {
        rule.conditions.indices.filter { !suggestions.contains(rule.conditions[$0]) }
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
                    ForEach(suggestions, id: \.self) { condition in
                        Toggle(capitalized(condition.summary), isOn: Binding(
                            get: { rule.conditions.contains(condition) },
                            set: { isOn in
                                if isOn { rule.conditions.append(condition) } else { rule.conditions.removeAll { $0 == condition } }
                            }
                        ))
                    }
                    ForEach(customIndices, id: \.self) { index in
                        conditionRow(index)
                    }
                    Button {
                        rule.conditions.append(.init(field: .repository, value: ""))
                    } label: {
                        Label(suggestions.isEmpty ? "Add Condition" : "Add Other Condition", systemImage: "plus")
                    }
                    .buttonStyle(.link)
                    .disabled(rule.conditions.count >= 5)
                } header: {
                    Text("When all of these match")
                } footer: {
                    if !suggestions.isEmpty {
                        Text("Suggested from this item. Choose more for a narrower rule.")
                    }
                }
                Section("Then") {
                    Picker("Action", selection: $rule.effect) {
                        ForEach(TriageRuleEffect.allCases) { option in
                            Label(option.title, systemImage: option.systemImage).tag(option)
                        }
                    }
                    TextField("Name", text: $rule.name, prompt: Text(rule.isValid ? rule.defaultName : "Optional"))
                    if !isNew { Toggle("Enabled", isOn: $rule.isEnabled) }
                }
                Section {
                    RulePreview(rule: rule, entries: entries)
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
                    onSave(rule)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!rule.isValid)
            }
            .padding(20)
        }
        .frame(width: 560, height: 600)
    }

    private func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    @ViewBuilder
    private func conditionRow(_ index: Int) -> some View {
        HStack {
            Picker("Field", selection: Binding(
                get: { rule.conditions[index].field },
                set: { field in
                    rule.conditions[index].field = field
                    rule.conditions[index].value = field.choices?.first?.value ?? ""
                }
            )) {
                ForEach(TriageRuleCondition.Field.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 170)

            if let choices = rule.conditions[index].field.choices {
                Picker("Value", selection: Binding(
                    get: { rule.conditions[index].value },
                    set: { rule.conditions[index].value = $0 }
                )) {
                    ForEach(choices, id: \.value) { Text($0.title).tag($0.value) }
                }
                .labelsHidden()
            } else {
                TextField("Value", text: Binding(
                    get: { rule.conditions[index].value },
                    set: { rule.conditions[index].value = $0 }
                ), prompt: Text(rule.conditions[index].field.placeholder))
                .labelsHidden()
            }

            Button {
                rule.conditions.remove(at: index)
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove condition")
        }
    }
}
