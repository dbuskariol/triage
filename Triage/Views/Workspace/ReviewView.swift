import Charts
import SwiftUI

/// The weekly Review: what you got through, where work piles up, and what's slipping.
struct ReviewView: View {
    let presentation: WorkspacePresentation
    @Binding var selectedEntryID: GitHubNodeID?
    let actions: any WorkspaceActions
    @Environment(\.triageViewerLogin) private var viewer
    @FocusState private var isFocused: Bool

    var body: some View {
        let review = WorkspaceReview(presentation: presentation, viewer: viewer, now: .now)
        List(selection: $selectedEntryID) {
            Section {
                StatTiles(stats: [
                    .init(title: "Done", value: review.handledThisWeek, systemImage: "checkmark.circle"),
                    .init(title: "On GitHub", value: review.handledByYouThisWeek, systemImage: "arrow.up.forward.square"),
                    .init(title: "In Inbox", value: review.inboxCount, systemImage: "tray"),
                    .init(title: "Typical Wait", text: review.medianWaitingOnYouDays.map { "\($0)d" } ?? "–",
                          systemImage: "hourglass"),
                ])
                .listRowSeparator(.hidden)
            }

            Section {
                Chart(review.days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Items", day.done))
                        .foregroundStyle(by: .value("How", "Marked done"))
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Items", day.handledByYou))
                        .foregroundStyle(by: .value("How", "Handled on GitHub"))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 160)
                .padding(.vertical, 6)
                .accessibilityLabel("Work done per day over the last week")
                .listRowSeparator(.hidden)
            } header: {
                SectionHeader(title: "Done per Day", systemImage: "chart.bar")
            }

            if !review.byRepository.isEmpty {
                Section {
                    Chart(review.byRepository) { row in
                        BarMark(x: .value("Open items", row.count), y: .value("Repository", row.repository))
                            .annotation(position: .trailing) {
                                Text(row.count, format: .number).font(.caption).foregroundStyle(.secondary)
                            }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(review.byRepository.count) * 26 + 10)
                    .padding(.vertical, 6)
                    .listRowSeparator(.hidden)
                } header: {
                    SectionHeader(title: "Open Work by Repository", systemImage: "folder")
                }
            }

            entrySection("Waiting on You Longest", systemImage: "hourglass.bottomhalf.filled",
                         entries: review.longestWaiting)
            entrySection("No Activity in \(WorkspaceReview.staleDays) Days", systemImage: "moon.zzz",
                         entries: review.stale)
        }
        .listStyle(.inset)
        .focused($isFocused)
        .onAppear { isFocused = true }
        .triageListKeys(entries: review.orderedEntries, selection: $selectedEntryID,
                        handledIDs: presentation.handledIDs, actions: actions)
        .accessibilityLabel("Weekly Review")
        .navigationTitle("Weekly Review")
        .navigationSubtitle("Last 7 days")
    }

    @ViewBuilder
    private func entrySection(_ title: String, systemImage: String, entries: [TriageEntry]) -> some View {
        if !entries.isEmpty {
            Section {
                TriageEntryRows(entries: Array(entries.prefix(5)), selectedEntryID: selectedEntryID,
                                handledIDs: presentation.handledIDs, actions: actions)
            } header: {
                SectionHeader(title: title, systemImage: systemImage, count: entries.count)
            }
        }
    }
}
