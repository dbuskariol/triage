import SwiftUI

/// The detail column when several items are selected, like Mail and Finder:
/// how many, what they have in common, and the actions that apply to all.
struct MultipleSelectionView: View {
    let entries: [TriageEntry]
    let setAsideIDs: Set<GitHubNodeID>
    let actions: any WorkspaceActions
    /// Narrows the selection to one item.
    let select: (TriageEntry) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                actionBar
                summary
                list
                Text("⌘-click to add or remove items, ⇧-click to select a range, ⌘A to select all. Press Esc to keep only the first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                ForEach(0..<3, id: \.self) { layer in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.background.secondary)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                        .frame(width: 96, height: 64)
                        .rotationEffect(.degrees(Double(layer - 1) * 6))
                        .offset(y: CGFloat(1 - layer) * 4)
                }
                Image(systemName: "checklist")
                    .font(.title)
                    .foregroundStyle(.tint)
            }
            .frame(height: 90)
            .accessibilityHidden(true)
            Text("\(entries.count) Items Selected")
                .font(.title2.weight(.semibold))
        }
    }

    /// The same actions as the context menu, as buttons.
    private var actionBar: some View {
        let anyUnread = entries.contains(where: \.isUnread)
        let allSetAside = entries.allSatisfy { setAsideIDs.contains($0.id) }
        return HStack(spacing: 10) {
            if allSetAside {
                Button { actions.restore(entries) } label: { Label("Restore", systemImage: "tray.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
            } else {
                Button { actions.markDone(entries) } label: { Label("Done", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent)
                    .help("Mark all done (E)")
                Menu {
                    SnoozeMenuItems(entries: entries, actions: actions)
                } label: {
                    Label("Snooze", systemImage: "moon.zzz")
                }
                .fixedSize()
            }
            Button { actions.setRead(entries, anyUnread) } label: {
                Label(anyUnread ? "Mark as Read" : "Mark as Unread", systemImage: anyUnread ? "envelope.open" : "envelope.badge")
            }
            .help("U")
            Menu {
                Button("Open \(entries.count) on GitHub") { actions.openOnGitHub(entries) }
                Button("Focus on These") { actions.startFocus(entries) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .fixedSize()
        }
        .controlSize(.large)
    }

    private var summary: some View {
        let needsAction = entries.filter { $0.decision?.disposition == .act }.count
        let unread = entries.filter(\.isUnread).count
        let repositories = Set(entries.map(\.item.repository)).count
        let pullRequests = entries.filter { $0.item.kind == .pullRequest }.count
        return HStack(spacing: 12) {
            stat("\(needsAction)", "Need action", tint: .orange)
            stat("\(unread)", "Unread", tint: .accentColor)
            stat("\(pullRequests)", pullRequests == 1 ? "Pull request" : "Pull requests")
            stat("\(entries.count - pullRequests)", entries.count - pullRequests == 1 ? "Issue" : "Issues")
            stat("\(repositories)", repositories == 1 ? "Repository" : "Repositories")
        }
    }

    private func stat(_ value: String, _ title: String, tint: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    /// The selected items; click one to select just it.
    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider() }
                Button {
                    select(entry)
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(entry.isUnread ? Color.accentColor : .clear).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.item.title).lineLimit(1)
                            Text(entry.item.reference).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.decision?.disposition == .act {
                            Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange)
                        }
                        Text(RelativeTime.compact(entry.item.updatedAt))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Show only \(entry.item.reference)")
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }
}
