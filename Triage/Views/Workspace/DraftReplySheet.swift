import AppKit
import SwiftUI

/// Copilot drafts a reply; you edit it, copy it, and post it on GitHub
/// yourself. Triage never posts.
struct DraftReplySheet: View {
    let entry: TriageEntry
    let generate: @MainActor () async throws -> String
    let openOnGitHub: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isGenerating = false
    @State private var error: String?
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Draft Reply").font(.title2.weight(.semibold))
                Text("\(entry.item.reference) · \(entry.item.title)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let goal = entry.decision?.nextAction {
                    Label(goal, systemImage: "arrow.right.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            ZStack {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.background.secondary, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .disabled(isGenerating)
                    .accessibilityLabel("Reply")
                if isGenerating {
                    ProgressView("Copilot is writing…")
                } else if let error, text.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't draft a reply", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await run() } }
                    }
                }
            }
            .frame(minHeight: 220)

            Text("Review before posting. Bracketed placeholders like [ETA] need your details. Copilot never posts for you.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    Task { await run() }
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .disabled(isGenerating)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(didCopy ? "Copied" : "Copy") { copy() }
                    .disabled(text.isEmpty || isGenerating)
                Button("Copy and Open on GitHub") {
                    copy()
                    openOnGitHub()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.isEmpty || isGenerating)
            }
        }
        .padding(20)
        .frame(width: 620, height: 460)
        .task { await run() }
    }

    private func run() async {
        isGenerating = true
        error = nil
        defer { isGenerating = false }
        do {
            text = try await generate()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Copilot is unavailable. Try again shortly."
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
    }
}
