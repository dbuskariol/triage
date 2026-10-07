import SwiftUI

extension EnvironmentValues {
    /// The signed-in GitHub login, for rule previews that depend on it
    /// (e.g. "review requested from me directly").
    @Entry var triageViewerLogin = ""
}

/// One-click rules built from an item's facts, for context menus and the
/// detail view. Creating one is always an explicit user action.
struct QuickRuleMenu: View {
    let item: PersonalWorkItem
    let actions: any WorkspaceActions

    var body: some View {
        Menu("Create Rule") {
            if item.relationships.contains(.reviewRequested) {
                Section("Review requests") {
                    button(.lowerPriority, .relationship, TriageRuleCondition.Field.reviewRequestedTeam,
                           title: "Lower priority when only my team is requested")
                    button(.noAction, .relationship, TriageRuleCondition.Field.reviewRequestedTeam,
                           title: "No action when only my team is requested")
                    button(.needsAction, .relationship, TriageRuleCondition.Field.reviewRequestedDirect,
                           title: "Needs my action when I'm requested directly")
                    ForEach(teams, id: \.self) { team in
                        Menu("Team \(team)") {
                            button(.lowerPriority, .requestedTeam, team)
                            button(.noAction, .requestedTeam, team)
                            button(.mute, .requestedTeam, team)
                        }
                    }
                }
            }
            Section(item.repository) {
                button(.alwaysInbox, .repository, item.repository)
                button(.raisePriority, .repository, item.repository)
                button(.lowerPriority, .repository, item.repository)
                button(.mute, .repository, item.repository)
            }
            if let author = item.author {
                Section("Author \(author)") {
                    button(.alwaysInbox, .author, author)
                    button(.noAction, .author, author)
                    button(.mute, .author, author)
                }
            }
            if !item.labels.isEmpty {
                Menu("Label") {
                    ForEach(item.labels, id: \.self) { label in
                        Menu(label) {
                            button(.alwaysInbox, .label, label)
                            button(.raisePriority, .label, label)
                            button(.noAction, .label, label)
                            button(.mute, .label, label)
                        }
                    }
                }
            }
            Divider()
            Button("Manage Rules…") { actions.openRulesSettings() }
        }
    }

    private var teams: [String] {
        (item.pullRequest?.requestedReviewers ?? []).filter { $0.contains("/") }
    }

    private func button(
        _ effect: TriageRuleEffect, _ field: TriageRuleCondition.Field, _ value: String, title: String? = nil
    ) -> some View {
        Button {
            actions.addRule(.quick(effect, field, value))
        } label: {
            Label(title ?? effect.title, systemImage: effect.systemImage)
        }
    }
}

/// "Not right?" feedback: the user says where an item belongs and how widely
/// that should apply, and reviews the rule before it is created.
struct RuleFeedbackSheet: View {
    let entry: TriageEntry
    let allEntries: [TriageEntry]
    let actions: any WorkspaceActions
    @Environment(\.dismiss) private var dismiss

    @State private var effect: TriageRuleEffect = .alwaysInbox
    @State private var scope: TriageRuleCondition

    init(entry: TriageEntry, allEntries: [TriageEntry], actions: any WorkspaceActions) {
        self.entry = entry
        self.allEntries = allEntries
        self.actions = actions
        _scope = State(initialValue: TriageRuleCondition(field: .repository, value: entry.item.repository))
        _effect = State(initialValue: entry.decision?.disposition.isInbox == true ? .noAction : .alwaysInbox)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Teach Triage").font(.title2.weight(.semibold))
                Text("Create a rule so similar work is handled your way. Rules always apply, even when Copilot disagrees.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                Picker("This should be", selection: $effect) {
                    ForEach(TriageRuleEffect.allCases) { option in
                        Label(option.title, systemImage: option.systemImage).tag(option)
                    }
                }
                Picker("For", selection: $scope) {
                    ForEach(scopeOptions, id: \.self) { option in
                        Text(option.summary.prefix(1).uppercased() + option.summary.dropFirst()).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            RulePreview(rule: rule, entries: allEntries)

            HStack {
                Button("Edit Instructions Instead…") {
                    dismiss()
                    actions.openRulesSettings()
                }
                .buttonStyle(.link)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Rule") {
                    actions.addRule(rule)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var rule: TriageRule { TriageRule(name: "", conditions: [scope], effect: effect) }

    private var scopeOptions: [TriageRuleCondition] {
        var options: [TriageRuleCondition] = []
        if entry.item.relationships.contains(.reviewRequested) {
            options.append(.init(field: .relationship, value: TriageRuleCondition.Field.reviewRequestedTeam))
            options += (entry.item.pullRequest?.requestedReviewers ?? []).filter { $0.contains("/") }
                .prefix(3).map { .init(field: .requestedTeam, value: $0) }
        }
        options.append(TriageRuleCondition(field: .repository, value: entry.item.repository))
        if let author = entry.item.author { options.append(.init(field: .author, value: author)) }
        options += entry.item.labels.prefix(5).map { .init(field: .label, value: $0) }
        return options
    }
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

/// Create or edit a rule: When all conditions match → Then one effect.
struct RuleEditorSheet: View {
    @State var rule: TriageRule
    let entries: [TriageEntry]
    let onSave: (TriageRule) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Section {
                    TextField("Name", text: $rule.name, prompt: Text(rule.defaultName))
                }
                Section("When all of these match") {
                    ForEach($rule.conditions.indices, id: \.self) { index in
                        conditionRow(index)
                    }
                    Button {
                        rule.conditions.append(.init(field: .repository, value: ""))
                    } label: {
                        Label("Add Condition", systemImage: "plus")
                    }
                    .disabled(rule.conditions.count >= 5)
                }
                Section("Then") {
                    Picker("Action", selection: $rule.effect) {
                        ForEach(TriageRuleEffect.allCases) { option in
                            Label(option.title, systemImage: option.systemImage).tag(option)
                        }
                    }
                    Toggle("Enabled", isOn: $rule.isEnabled)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 320)

            RulePreview(rule: rule, entries: entries)
                .padding(.horizontal, 20)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(rule)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!rule.isValid)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 560)
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
            .frame(width: 150)

            if let choices = rule.conditions[index].field.choices {
                Picker("Value", selection: $rule.conditions[index].value) {
                    ForEach(choices, id: \.value) { Text($0.title).tag($0.value) }
                }
                .labelsHidden()
            } else {
                TextField("Value", text: $rule.conditions[index].value,
                          prompt: Text(rule.conditions[index].field.placeholder))
                    .labelsHidden()
            }

            Button {
                rule.conditions.remove(at: index)
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(rule.conditions.count == 1)
            .accessibilityLabel("Remove condition")
        }
    }
}
