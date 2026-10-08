import SwiftUI

/// Model, reasoning effort, and long context. Effort and context appear only
/// when the chosen model supports them; changing models resets both.
struct CopilotModelChoiceRows: View {
    let choice: CopilotModelChoice
    let models: [CopilotModel]
    let isEnabled: Bool
    let onChange: (CopilotModelChoice) -> Void

    var body: some View {
        let model = models.first { $0.id == choice.modelID }
        let efforts = model?.supportedReasoningEfforts ?? []
        Picker("Model", selection: Binding(
            get: { choice.modelID ?? "auto" },
            set: { id in onChange(.init(modelID: id == "auto" ? nil : id, reasoningEffort: nil, contextTier: nil)) }
        )) {
            Text("Auto").tag("auto")
            ForEach(models) { Text($0.displayName).tag($0.id) }
        }
        .disabled(!isEnabled)
        if isEnabled, choice.modelID == nil {
            Text("Choose a specific model to adjust reasoning effort and context length.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if isEnabled, !efforts.isEmpty {
            Picker("Reasoning effort", selection: Binding(
                get: { choice.reasoningEffort ?? "" },
                set: { effort in
                    var updated = choice
                    updated.reasoningEffort = effort.isEmpty ? nil : effort
                    onChange(updated)
                }
            )) {
                Text(model?.defaultReasoningEffort.map { "Default (\($0.capitalized))" } ?? "Default").tag("")
                ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
            }
        }
        if isEnabled, model?.supportsLongContext == true {
            Toggle("Long context", isOn: Binding(
                get: { choice.contextTier == "long_context" },
                set: { isOn in
                    var updated = choice
                    updated.contextTier = isOn ? "long_context" : nil
                    onChange(updated)
                }
            ))
            .help("Gives Copilot a larger context window for long descriptions and discussions. May use more premium requests.")
        }
    }
}

/// Settings ▸ Copilot ▸ Draft Replies: the reply model and your writing style.
struct DraftReplySettingsSection: View {
    let consent: OrganizationAIConsent
    let models: [CopilotModel]
    /// Saves the reply model; `nil` means the same as prioritizing.
    let onChange: (CopilotModelChoice?) -> Void
    @AppStorage(TriagePreferenceKeys.writingStyle) private var writingStyle = ""

    var body: some View {
        Section {
            Picker("Model", selection: Binding(
                get: { consent.replyChoice == nil },
                set: { isSame in onChange(isSame ? nil : consent.triageChoice) }
            )) {
                Text("Same as prioritizing").tag(true)
                Text("Choose separately").tag(false)
            }
            .pickerStyle(.radioGroup)
            if let reply = consent.replyChoice {
                CopilotModelChoiceRows(choice: reply, models: models, isEnabled: true) { onChange($0) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Writing style")
                TextEditor(text: Binding(
                    get: { writingStyle },
                    set: { writingStyle = String($0.utf8.prefix(TriageRules.maximumInstructionBytes)) ?? writingStyle }
                ))
                .font(.body)
                .frame(minHeight: 80)
                .accessibilityLabel("Writing style")
                Text("\(writingStyle.utf8.count) of \(TriageRules.maximumInstructionBytes) bytes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Draft Replies")
        } footer: {
            Text("Draft Reply (⌥⌘D) writes a reply you edit, copy, and post yourself. Describe how you write, for example: \"Friendly and brief. No exclamation marks.\" A faster model is often enough for replies.")
        }
    }
}
