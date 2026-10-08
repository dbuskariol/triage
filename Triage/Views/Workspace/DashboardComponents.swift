import SwiftUI

/// The scrolling, centered canvas shared by the Briefing and Weekly Review.
struct DashboardPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content()
            }
            .padding(28)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
    }
}

/// A titled card. `onShowAll` adds a Show All link to the full list.
struct DashboardCard<Content: View>: View {
    let title: String
    let systemImage: String
    var count: Int?
    var footer: String?
    var onShowAll: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                if let count {
                    Text(count, format: .number)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let onShowAll {
                    Button("Show All", action: onShowAll)
                        .buttonStyle(.link)
                        .font(.subheadline)
                }
            }
            content()
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
    }
}

/// Item rows inside a card. Clicking opens the item in its list with its details.
struct DashboardEntryList: View {
    let entries: [TriageEntry]
    let presentation: WorkspacePresentation
    let actions: any WorkspaceActions

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().padding(.leading, 20) }
                DashboardEntryButton(entry: entry, isHandled: presentation.setAsideIDs.contains(entry.id), actions: actions)
            }
        }
    }
}

private struct DashboardEntryButton: View {
    let entry: TriageEntry
    let isHandled: Bool
    let actions: any WorkspaceActions
    @State private var isHovered = false

    var body: some View {
        Button {
            actions.show(entry)
        } label: {
            TriageEntryRow(entry: entry)
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu { TriageEntryMenu(entries: [entry], setAsideIDs: isHandled ? [entry.id] : [], actions: actions) }
        .help("Show \(entry.item.reference)")
    }
}

/// A row of headline numbers; each can open the list behind it.
struct StatTiles: View {
    struct Stat: Identifiable {
        let title: String
        let value: String
        let systemImage: String
        var tint: Color = .secondary
        var action: (() -> Void)?
        var id: String { title }
    }

    let stats: [Stat]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(stats) { stat in
                if let action = stat.action {
                    Button(action: action) { tile(stat) }
                        .buttonStyle(.plain)
                        .help("Show \(stat.title)")
                } else {
                    tile(stat)
                }
            }
        }
    }

    private func tile(_ stat: Stat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(stat.title, systemImage: stat.systemImage)
                .font(.subheadline)
                .foregroundStyle(stat.tint)
                .lineLimit(1)
            Text(stat.value)
                .font(.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Two-up card layout that collapses to one column in narrow windows.
struct DashboardGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 20, alignment: .top)], alignment: .leading, spacing: 20) {
            content()
        }
    }
}
