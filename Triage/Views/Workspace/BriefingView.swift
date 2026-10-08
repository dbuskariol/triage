import SwiftUI

/// The Briefing: what needs you right now, at a glance. Every item opens in
/// its list with its details, and every card leads to the full list.
struct BriefingView: View {
    let presentation: WorkspacePresentation
    let actions: any WorkspaceActions
    let followUpDays: Int
    @Environment(\.triageViewerLogin) private var viewer

    var body: some View {
        let briefing = WorkspaceBriefing(presentation: presentation, viewer: viewer, followUpDays: followUpDays, now: .now)
        DashboardPage(title: "Briefing", subtitle: Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())) {
            header(briefing)
            StatTiles(stats: [
                .init(title: "Need Your Action", value: briefing.needsActionCount.formatted(),
                      systemImage: "exclamationmark.circle", tint: .orange,
                      action: { open(.section(.inbox), [.init(kind: .is, value: "action")]) }),
                .init(title: "Quick Wins", value: briefing.quickWinCount.formatted(), systemImage: "bolt",
                      action: { open(.section(.inbox), [.init(kind: .effort, value: TriageEffort.quick.rawValue)]) }),
                .init(title: "Follow Ups", value: briefing.followUpCount.formatted(), systemImage: "arrowshape.turn.up.right",
                      action: { open(.section(.waiting)) }),
                .init(title: "In Inbox", value: presentation.count(in: .inbox).formatted(), systemImage: "tray",
                      action: { open(.section(.inbox)) }),
            ])
            if briefing.parts.isEmpty {
                ContentUnavailableView(
                    "Nothing needs you",
                    systemImage: "sun.max",
                    description: Text("Your Inbox is clear and nothing is overdue.")
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                DashboardGrid {
                    ForEach(briefing.parts) { part in
                        DashboardCard(
                            title: part.title, systemImage: part.systemImage, count: part.entries.count,
                            footer: part.footer,
                            onShowAll: part.entries.count > WorkspaceBriefing.partLimit ? showAll(part.kind) : nil
                        ) {
                            DashboardEntryList(
                                entries: Array(part.entries.prefix(WorkspaceBriefing.partLimit)),
                                presentation: presentation, actions: actions
                            )
                        }
                    }
                }
            }
        }
    }

    private func header(_ briefing: WorkspaceBriefing) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.largeTitle.weight(.bold))
                Text(summary(briefing))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let needsAction = briefing.parts.first(where: { $0.kind == .needsAction }) {
                Button {
                    actions.startFocus(needsAction.entries)
                } label: {
                    Label("Focus on What Needs You", systemImage: "scope")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Work through items needing your action one at a time (⇧⌘F)")
            }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    private func summary(_ briefing: WorkspaceBriefing) -> String {
        switch briefing.needsActionCount {
        case 0: "Nothing is blocked on you right now."
        case 1: "1 item needs your action."
        default: "\(briefing.needsActionCount) items need your action."
        }
    }

    private func showAll(_ kind: WorkspaceBriefing.Part.Kind) -> (() -> Void)? {
        switch kind {
        case .needsAction: { open(.section(.inbox), [.init(kind: .is, value: "action")]) }
        case .waitingOnYou: { open(.section(.inbox)) }
        case .quickWins: { open(.section(.inbox), [.init(kind: .effort, value: TriageEffort.quick.rawValue)]) }
        case .followUps: { open(.section(.waiting)) }
        case .handledToday: { open(.section(.done)) }
        case .newToday: nil
        }
    }

    private func open(_ destination: WorkspaceDestination, _ tokens: [SearchToken] = []) {
        actions.open(destination, search: WorkspaceSearch(tokens: tokens))
    }
}
