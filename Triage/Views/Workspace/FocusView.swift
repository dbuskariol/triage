import SwiftUI

/// Focus: work through a list one item at a time, keyboard first.
/// Items you finish anywhere (here, on GitHub, or from another window)
/// drop out of the queue on their own.
struct FocusView: View {
    let presentation: WorkspacePresentation
    let queue: [GitHubNodeID]
    let actions: any WorkspaceActions
    let onExit: () -> Void
    @State private var index = 0

    var body: some View {
        let remaining = remainingEntries
        let current = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
        VStack(spacing: 0) {
            header(remaining: remaining, current: current)
            Divider()
            if let current {
                TriageDetailView(entry: current, inboxIsEmpty: false, allEntries: presentation.allEntries, actions: actions)
                    .id(current.id)
            } else {
                ContentUnavailableView {
                    Label("Focus complete", systemImage: "checkmark.circle")
                } description: {
                    Text("You worked through \(queue.count) item\(queue.count == 1 ? "" : "s").")
                } actions: {
                    Button("Back to Triage", action: onExit).keyboardShortcut(.defaultAction)
                }
            }
            Divider()
            controls(current: current, count: remaining.count)
        }
        .navigationTitle("Focus")
    }

    private func header(remaining: [TriageEntry], current: TriageEntry?) -> some View {
        let finished = queue.count - remaining.count
        return HStack(spacing: 12) {
            ProgressView(value: Double(finished), total: Double(max(queue.count, 1)))
                .frame(maxWidth: 240)
                .accessibilityLabel("\(finished) of \(queue.count) finished")
            Text("\(finished) of \(queue.count) finished")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Exit Focus", action: onExit)
                .keyboardShortcut(.cancelAction)
                .help("Exit Focus (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Real buttons with plain-key shortcuts, so the keys work wherever focus is
    /// and VoiceOver users get the same actions.
    private func controls(current: TriageEntry?, count: Int) -> some View {
        HStack(spacing: 8) {
            Button { move(by: -1, count: count) } label: { Label("Previous", systemImage: "chevron.left") }
                .keyboardShortcut("k", modifiers: [])
                .help("Previous (K)")
            Button { move(by: 1, count: count) } label: { Label("Next", systemImage: "chevron.right") }
                .keyboardShortcut("j", modifiers: [])
                .help("Next (J)")
            if current != nil {
                Text("\(min(index, count - 1) + 1) of \(count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            Spacer()
            Button { current.map { actions.snooze($0, until: SnoozeOption.tomorrow.date()) } } label: {
                Label("Snooze", systemImage: "moon.zzz")
            }
            .keyboardShortcut("s", modifiers: [])
            .help("Snooze until \(SnoozeOption.tomorrow.subtitle()) (S)")
            Button { current.map(actions.openOnGitHub) } label: {
                Label("Open on GitHub", systemImage: "arrow.up.forward.square")
            }
            .keyboardShortcut("o", modifiers: [])
            .help("Open on GitHub (O)")
            Button { current.map(actions.markDone) } label: { Label("Done", systemImage: "checkmark") }
                .keyboardShortcut("e", modifiers: [])
                .buttonStyle(.borderedProminent)
                .help("Done (E)")
        }
        .disabled(current == nil)
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// Queue entries that still need you, in their original order.
    private var remainingEntries: [TriageEntry] {
        let finished = presentation.handledIDs.union(presentation.entries(in: .muted).map(\.id))
        let byID = Dictionary(presentation.allEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return queue.compactMap { byID[$0] }.filter { !finished.contains($0.id) }
    }

    private func move(by offset: Int, count: Int) {
        guard count > 0 else { return }
        index = min(max(min(index, count - 1) + offset, 0), count - 1)
    }
}
