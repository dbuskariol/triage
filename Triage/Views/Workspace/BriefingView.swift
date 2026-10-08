import SwiftUI

/// The Briefing: what needs you right now, in one calm list.
struct BriefingView: View {
    let presentation: WorkspacePresentation
    @Binding var selectedEntryID: GitHubNodeID?
    let actions: any WorkspaceActions
    let followUpDays: Int
    @Environment(\.triageViewerLogin) private var viewer
    @FocusState private var isFocused: Bool

    var body: some View {
        let briefing = WorkspaceBriefing(presentation: presentation, viewer: viewer, followUpDays: followUpDays, now: .now)
        Group {
            if briefing.parts.isEmpty {
                ContentUnavailableView(
                    "Nothing needs you",
                    systemImage: "sun.max",
                    description: Text("Your Inbox is clear and nothing is overdue.")
                )
            } else {
                List(selection: $selectedEntryID) {
                    Section {
                        StatTiles(stats: [
                            .init(title: "Need Action", value: briefing.needsActionCount, systemImage: "exclamationmark.circle"),
                            .init(title: "Quick Wins", value: briefing.quickWinCount, systemImage: "bolt"),
                            .init(title: "Follow Ups", value: briefing.followUpCount, systemImage: "arrowshape.turn.up.right"),
                        ])
                        .listRowSeparator(.hidden)
                        if let needsAction = briefing.parts.first(where: { $0.kind == .needsAction }) {
                            Button {
                                actions.startFocus(needsAction.entries)
                            } label: {
                                Label("Focus on \(needsAction.entries.count) Needing Action", systemImage: "scope")
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.large)
                            .buttonStyle(.borderedProminent)
                            .listRowSeparator(.hidden)
                        }
                    }
                    ForEach(briefing.parts) { part in
                        Section {
                            TriageEntryRows(
                                entries: Array(part.entries.prefix(WorkspaceBriefing.partLimit)),
                                selectedEntryID: selectedEntryID,
                                handledIDs: presentation.handledIDs,
                                actions: actions
                            )
                        } header: {
                            SectionHeader(title: part.title, systemImage: part.systemImage, count: part.entries.count)
                        } footer: {
                            Text(part.footer).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
                .focused($isFocused)
                .onAppear { isFocused = true }
                .triageListKeys(entries: briefing.orderedEntries, selection: $selectedEntryID,
                                handledIDs: presentation.handledIDs, actions: actions)
                .accessibilityLabel("Briefing")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Briefing")
        .navigationSubtitle(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
    }
}

/// A list section header with an icon and a count, shared by the Briefing and Review.
struct SectionHeader: View {
    let title: String
    let systemImage: String
    var count: Int?

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if let count {
                Text(count, format: .number).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

/// A row of headline numbers.
struct StatTiles: View {
    struct Stat: Identifiable {
        let title: String
        let value: String
        let systemImage: String
        var id: String { title }

        init(title: String, value: Int, systemImage: String) {
            self.init(title: title, text: value.formatted(), systemImage: systemImage)
        }

        init(title: String, text: String, systemImage: String) {
            self.title = title
            value = text
            self.systemImage = systemImage
        }
    }

    let stats: [Stat]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 4) {
                    Label(stat.title, systemImage: stat.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(stat.value)
                        .font(.title2.weight(.semibold).monospacedDigit())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}
