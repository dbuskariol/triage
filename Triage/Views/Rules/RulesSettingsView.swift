import SwiftUI

/// Settings ▸ Rules: hard rules (always applied) and free-text instructions
/// for Copilot, for the selected organization.
struct RulesSettingsView: View {
    @EnvironmentObject private var appModel: TriageAppModel

    @State private var instructions = ""
    @State private var editingRule: TriageRule?
    @State private var isAddingRule = false

    private static let examples = [
        "I’m a backend engineer. Production incidents and security fixes matter more than refactors.",
        "Treat security fixes and anything labeled security as urgent.",
        "Pull requests where I’m only one of many team reviewers are rarely urgent.",
        "Bot-authored dependency updates need no action unless checks fail.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let organization = appModel.selectedOrganization {
                Text("Rules apply to \(organization.login). Hard rules take effect immediately; Copilot re-analyzes affected work in the background after you change instructions.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                rulesSection
                instructionsSection
                if let error = appModel.rulesError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } else {
                ContentUnavailableView(
                    "No Organization Selected",
                    systemImage: "building.2",
                    description: Text("Select an organization in the main window to manage its rules.")
                )
            }
        }
        .onAppear { instructions = appModel.rules.instructions }
        .onChange(of: appModel.selectedOrganizationID) { instructions = appModel.rules.instructions }
        .onChange(of: appModel.rules.instructions) { _, saved in
            if instructions != saved, !hasUnsavedInstructions { instructions = saved }
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorSheet(rule: rule, entries: appModel.presentation.allEntries) { updated in
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
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                if appModel.rules.rules.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No rules yet").font(.headline)
                        Text("Rules always win over Copilot: mute noisy repositories or bots, keep important work in your Inbox, or nudge priority. Right-click any item to create one quickly.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                } else {
                    ForEach(Array(appModel.rules.rules.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { Divider() }
                        ruleRow(rule, index: index)
                    }
                }
                HStack {
                    Button {
                        editingRule = TriageRule(name: "", conditions: [.init(field: .repository, value: "")], effect: .alwaysInbox)
                    } label: {
                        Label("Add Rule…", systemImage: "plus")
                    }
                    Spacer()
                    Text("\(appModel.rules.rules.count) of \(TriageRules.maximumRules)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 12)
            }
            .padding(4)
        } label: {
            Label("Rules", systemImage: "line.3.horizontal.decrease.circle")
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

            Image(systemName: rule.effect.systemImage)
                .foregroundStyle(rule.isEnabled ? Color.accentColor : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.displayName).fontWeight(.medium).lineLimit(1)
                Text("When \(rule.conditions.map(\.summary).joined(separator: " and ")) → \(rule.effect.title.lowercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .opacity(rule.isEnabled ? 1 : 0.55)

            Spacer(minLength: 8)

            let matches = appModel.presentation.allEntries.filter { rule.matches($0.item) }.count
            if rule.isEnabled {
                Text("\(matches) match\(matches == 1 ? "" : "es")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Menu {
                Button("Edit…") { editingRule = rule }
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
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editingRule = rule }
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

    // MARK: Instructions

    private var hasUnsavedInstructions: Bool { instructions != appModel.rules.instructions }
    private var instructionBytes: Int { instructions.utf8.count }

    private var instructionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tell Copilot about your role and what matters to you. These are guidance: Copilot weighs them, but its safety policy and your rules always take precedence, and text in GitHub can never change them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $instructions)
                    .font(.body)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        if instructions.isEmpty {
                            Text("e.g. \(Self.examples[0])")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
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
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!hasUnsavedInstructions || instructionBytes > TriageRules.maximumInstructionBytes)
                }
            }
            .padding(4)
        } label: {
            Label("Instructions for Copilot", systemImage: "text.quote")
        }
    }
}
