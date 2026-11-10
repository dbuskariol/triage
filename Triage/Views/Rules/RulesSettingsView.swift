import SwiftUI

/// Settings ▸ Rules: hard rules (always applied) and free-text instructions
/// for Copilot, for the selected organization.
struct RulesSettingsView: View {
    @EnvironmentObject private var appModel: TriageAppModel

    @State private var instructions = ""
    @State private var editingRule: RuleDraft?
    @State private var editingTopic: TriageTopic?
    @Environment(\.triageViewerLogin) private var viewer

    private static let examples = [
        "I’m a backend engineer. Production incidents and security fixes matter more than refactors.",
        "Treat security fixes and anything labeled security as urgent.",
        "Pull requests where I’m only one of many team reviewers are rarely urgent.",
        "Bot-authored dependency updates need no action unless checks fail.",
    ]

    var body: some View {
        Form {
            if appModel.selectedOrganization != nil {
                rulesSection
                topicsSection
                instructionsSection
            } else {
                Section {
                    Text("Select an organization in the main window to manage its rules.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { instructions = appModel.rules.instructions }
        .onChange(of: appModel.selectedOrganizationID) { instructions = appModel.rules.instructions }
        .onChange(of: appModel.rules.instructions) { _, saved in
            if instructions != saved, !hasUnsavedInstructions { instructions = saved }
        }
        .sheet(item: $editingTopic) { topic in
            TopicEditorSheet(topic: topic, isNew: !appModel.rules.topics.contains { $0.id == topic.id }, existing: appModel.rules.topics) { updated in
                var rules = appModel.rules
                if let index = rules.topics.firstIndex(where: { $0.id == updated.id }) {
                    let previous = rules.topics[index].trimmedName
                    rules.topics[index] = updated
                    if previous != updated.trimmedName {
                        for ruleIndex in rules.rules.indices {
                            rules.rules[ruleIndex].query = rules.rules[ruleIndex].query.renamingTopic(previous, to: updated.trimmedName)
                        }
                    }
                } else {
                    rules.topics.append(updated)
                }
                appModel.saveRules(rules)
            }
        }
        .sheet(item: $editingRule) { draft in
            RuleEditorSheet(draft: draft, entries: appModel.presentation.allEntries) { updated in
                var rules = appModel.rules
                if let index = rules.rules.firstIndex(where: { $0.id == updated.id }) {
                    rules.rules[index] = updated
                } else {
                    rules.rules.append(updated)
                }
                appModel.saveRules(rules)
            }
        }
    }

    // MARK: Rules

    private var rulesSection: some View {
        Section {
            if appModel.rules.rules.isEmpty {
                Text("No rules yet. Select any item and choose Create Rule… to start from it.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(appModel.rules.rules.enumerated()), id: \.element.id) { index, rule in
                ruleRow(rule, index: index)
            }
            HStack {
                Text("\(appModel.rules.rules.count) of \(TriageRules.maximumRules)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Add Rule…") {
                    editingRule = RuleDraft(rule: TriageRule(query: TriageQuery(.all([])), action: .exclude))
                }
            }
            if let error = appModel.rulesError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } header: {
            Text("Rules for \(appModel.selectedOrganization?.login ?? "")")
        } footer: {
            Text("Rules always win over Copilot and apply instantly. Hide work you never want to see, move work to a section, or rank it higher or lower. Hide wins over Move; the first matching Move wins; Rank rules add up.")
        }
    }

    private func ruleRow(_ rule: TriageRule, index: Int) -> some View {
        HStack(spacing: 12) {
            Toggle(rule.displayName, isOn: Binding(
                get: { rule.isEnabled },
                set: { enabled in update(rule) { $0.isEnabled = enabled } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            Image(systemName: rule.action.systemImage)
                .foregroundStyle(rule.isEnabled ? Color.accentColor : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.displayName).fontWeight(.medium).lineLimit(1)
                Text("When \(rule.query.description) → \(rule.action.title.lowercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .opacity(rule.isEnabled ? 1 : 0.55)

            Spacer(minLength: 8)

            let matches = appModel.presentation.allEntries.filter { rule.matches($0, viewer: viewer) }.count
            if rule.isEnabled {
                Text("\(matches) match\(matches == 1 ? "" : "es")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Menu {
                Button("Edit…") { editingRule = RuleDraft(rule: rule, isNew: false) }
                Button("Move Up") { move(index, by: -1) }.disabled(index == 0)
                Button("Move Down") { move(index, by: 1) }.disabled(index == appModel.rules.rules.count - 1)
                Divider()
                Button("Delete", role: .destructive) { delete(rule) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(rule.displayName)")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editingRule = RuleDraft(rule: rule, isNew: false) }
    }

    private func update(_ rule: TriageRule, _ change: (inout TriageRule) -> Void) {
        var rules = appModel.rules
        guard let index = rules.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        change(&rules.rules[index])
        appModel.saveRules(rules)
    }

    private func move(_ index: Int, by offset: Int) {
        var rules = appModel.rules
        let target = index + offset
        guard rules.rules.indices.contains(target) else { return }
        rules.rules.swapAt(index, target)
        appModel.saveRules(rules)
    }

    private func delete(_ rule: TriageRule) {
        var rules = appModel.rules
        rules.rules.removeAll { $0.id == rule.id }
        appModel.saveRules(rules)
    }

    // MARK: Topics

    private var topicsSection: some View {
        Section {
            if appModel.rules.topics.isEmpty {
                Text("No topics yet. Add one for anything Copilot should recognize, then use it in rules and search.")
                    .foregroundStyle(.secondary)
            }
            ForEach(appModel.rules.topics) { topic in
                HStack(spacing: 12) {
                    Image(systemName: "number").foregroundStyle(Color.accentColor).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.trimmedName).fontWeight(.medium)
                        Text(topic.trimmedDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    let tagged = appModel.presentation.allEntries.filter { $0.decision?.topics?.contains(topic.trimmedName) == true }.count
                    Text("\(tagged) tagged").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Menu {
                        Button("Edit…") { editingTopic = topic }
                        Button("Hide Work with This Topic…") {
                            editingRule = RuleDraft(rule: TriageRule(
                                query: TriageQuery(.qualifier(.topic, topic.trimmedName)), action: .exclude
                            ))
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            var rules = appModel.rules
                            rules.topics.removeAll { $0.id == topic.id }
                            appModel.saveRules(rules)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Actions for topic \(topic.trimmedName)")
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { editingTopic = topic }
            }
            HStack {
                Text("\(appModel.rules.topics.count) of \(TriageTopic.maximumCount)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Add Topic…") { editingTopic = TriageTopic(name: "", description: "") }
                    .disabled(appModel.rules.topics.count >= TriageTopic.maximumCount)
            }
        } header: {
            Text("Topics")
        } footer: {
            Text("Copilot tags work with your topics as it analyzes it. Use them in rules and search with topic:\"Name\" — for example, hide everything waiting on a compliance approval. Adding or changing a topic re-analyzes your work in the background.")
        }
    }

    // MARK: Instructions

    private var hasUnsavedInstructions: Bool { instructions != appModel.rules.instructions }
    private var instructionBytes: Int { instructions.utf8.count }

    private var instructionsSection: some View {
        Section {
            TextEditor(text: $instructions)
                .font(.body)
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if instructions.isEmpty {
                        Text("e.g. \(Self.examples[0])")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Instructions for Copilot")
            HStack {
                Menu("Insert Example") {
                    ForEach(Self.examples, id: \.self) { example in
                        Button(example) {
                            instructions += (instructions.isEmpty || instructions.hasSuffix("\n") ? "" : "\n") + example
                        }
                    }
                }
                .fixedSize()
                Spacer()
                Text("\(instructionBytes.formatted()) / \(TriageRules.maximumInstructionBytes.formatted())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(instructionBytes > TriageRules.maximumInstructionBytes ? .red : .secondary)
                Button("Revert") { instructions = appModel.rules.instructions }
                    .disabled(!hasUnsavedInstructions)
                Button("Save") {
                    var rules = appModel.rules
                    rules.instructions = instructions
                    appModel.saveRules(rules)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasUnsavedInstructions || instructionBytes > TriageRules.maximumInstructionBytes)
            }
        } header: {
            Text("Instructions for Copilot")
        } footer: {
            Text("Tell Copilot about your role and what matters to you. Copilot weighs these, but its safety policy and your rules take precedence, and text in GitHub can never change them. Saving re-analyzes affected work in the background.")
        }
    }

}

/// Adds or edits one topic: a short name and what Copilot should look for.
struct TopicEditorSheet: View {
    @State private var topic: TriageTopic
    let isNew: Bool
    let existing: [TriageTopic]
    let onSave: (TriageTopic) -> Void
    @Environment(\.dismiss) private var dismiss

    init(topic: TriageTopic, isNew: Bool, existing: [TriageTopic], onSave: @escaping (TriageTopic) -> Void) {
        _topic = State(initialValue: topic)
        self.isNew = isNew
        self.existing = existing
        self.onSave = onSave
    }

    private var problem: String? {
        if let problem = topic.problem { return problem }
        if existing.contains(where: { $0.id != topic.id && $0.trimmedName.caseInsensitiveCompare(topic.trimmedName) == .orderedSame }) {
            return "You already have a topic named “\(topic.trimmedName)”."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $topic.name, prompt: Text("e.g. Compliance approvals"))
                    TextField("What to look for", text: $topic.description, prompt: Text("e.g. Blocked on a FedRAMP or other compliance deployment approval"), axis: .vertical)
                        .lineLimit(3...5)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Describe it the way you'd explain it to a colleague. Copilot tags matching work; use topic:\"\(topic.trimmedName.isEmpty ? "Name" : topic.trimmedName)\" in rules and search.")
                        if let problem, !(topic.trimmedName.isEmpty && topic.trimmedDescription.isEmpty) {
                            Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Topic" : "Save") {
                    var saved = topic
                    saved.name = topic.trimmedName
                    saved.description = topic.trimmedDescription
                    onSave(saved)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
            .padding(20)
        }
        .frame(width: 480, height: 300)
    }
}
