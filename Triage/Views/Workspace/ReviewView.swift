import Charts
import SwiftUI

/// The weekly Review: what you got through, where work piles up, and what's slipping.
struct ReviewView: View {
    let presentation: WorkspacePresentation
    let actions: any WorkspaceActions
    @Environment(\.triageViewerLogin) private var viewer

    var body: some View {
        let review = WorkspaceReview(presentation: presentation, viewer: viewer, now: .now)
        DashboardPage(title: "Weekly Review", subtitle: dateRange(review)) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Week").font(.largeTitle.weight(.bold))
                Text("\(review.handledThisWeek) done in the last 7 days, \(review.inboxCount) still in your Inbox.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            StatTiles(stats: [
                .init(title: "Done", value: review.handledThisWeek.formatted(), systemImage: "checkmark.circle",
                      tint: .green, action: { actions.open(.section(.done), search: WorkspaceSearch()) }),
                .init(title: "Handled on GitHub", value: review.handledByYouThisWeek.formatted(),
                      systemImage: "arrow.up.forward.square"),
                .init(title: "In Inbox", value: review.inboxCount.formatted(), systemImage: "tray",
                      action: { actions.open(.section(.inbox), search: WorkspaceSearch()) }),
                .init(title: "Typical Wait on You", value: review.medianWaitingOnYouDays.map { "\($0)d" } ?? "–",
                      systemImage: "hourglass"),
            ])
            DashboardGrid {
                DashboardCard(title: "Done per Day", systemImage: "chart.bar") {
                    Chart(review.days) { day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Items", day.done))
                            .foregroundStyle(by: .value("How", "Marked done"))
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Items", day.handledByYou))
                            .foregroundStyle(by: .value("How", "Handled on GitHub"))
                    }
                    .chartForegroundStyleScale(["Marked done": Color.accentColor, "Handled on GitHub": Color.green])
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                        }
                    }
                    .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 200)
                    .accessibilityLabel("Work done per day over the last week")
                }
                DashboardCard(title: "Open Work by Repository", systemImage: "folder") {
                    if review.byRepository.isEmpty {
                        Text("No open work.").foregroundStyle(.secondary)
                    } else {
                        RepositoryBars(rows: review.byRepository) { repository in
                            actions.open(.section(.inbox), search: WorkspaceSearch(
                                tokens: [.init(kind: .repo, value: repository)], scope: .all
                            ))
                        }
                    }
                }
                entryCard("Waiting on You Longest", systemImage: "hourglass.bottomhalf.filled",
                          entries: review.longestWaiting,
                          footer: "Inbox items since anyone else last moved them.") {
                    actions.open(.section(.inbox), search: WorkspaceSearch())
                }
                entryCard("No Activity in \(WorkspaceReview.staleDays) Days", systemImage: "moon.zzz",
                          entries: review.stale,
                          footer: "Open work that has gone quiet. Close it, nudge someone, or mute it.")
            }
        }
    }

    @ViewBuilder
    private func entryCard(
        _ title: String, systemImage: String, entries: [TriageEntry], footer: String,
        showAll: (() -> Void)? = nil
    ) -> some View {
        if !entries.isEmpty {
            DashboardCard(title: title, systemImage: systemImage, count: entries.count, footer: footer,
                          onShowAll: entries.count > 5 ? showAll : nil) {
                DashboardEntryList(entries: Array(entries.prefix(5)), presentation: presentation, actions: actions)
            }
        }
    }

    private func dateRange(_ review: WorkspaceReview) -> String {
        guard let first = review.days.first?.date, let last = review.days.last?.date else { return "Last 7 days" }
        return (first..<last.addingTimeInterval(1)).formatted(.interval.month(.abbreviated).day())
    }
}

/// Clickable horizontal bars: each opens that repository's open work.
private struct RepositoryBars: View {
    let rows: [WorkspaceReview.RepositoryCount]
    let onSelect: (String) -> Void

    var body: some View {
        let maximum = max(rows.map(\.count).max() ?? 1, 1)
        VStack(spacing: 8) {
            ForEach(rows) { row in
                Button {
                    onSelect(row.repository)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.repository).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(row.count, format: .number).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Color.accentColor.gradient)
                                .frame(width: max(6, proxy.size.width * CGFloat(row.count) / CGFloat(maximum)))
                        }
                        .frame(height: 6)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Show open work in \(row.repository)")
                .accessibilityLabel("\(row.repository), \(row.count) open items")
            }
        }
    }
}
