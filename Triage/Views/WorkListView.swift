import SwiftUI

struct WorkListView: View {
    @EnvironmentObject private var appModel: TriageAppModel
    @EnvironmentObject private var navigation: AppNavigationModel

    var body: some View {
        List(selection: $appModel.selectedWorkItemID) {
            ForEach(filteredWorkItems) { item in
                WorkItemRow(item: item)
                    .tag(item.id)
            }
        }
        .navigationTitle(navigation.section.title)
        .overlay {
            if filteredWorkItems.isEmpty {
                ContentUnavailableView(
                    navigation.section == .inbox ? "Inbox zero" : "No work",
                    systemImage: navigation.section.systemImage,
                    description: Text(emptyDescription)
                )
            }
        }
    }

    private var filteredWorkItems: [WorkItem] {
        let now = Date()
        let matching = appModel.workItems.filter { item in
            switch navigation.section {
            case .inbox:
                InboxEligibilityRule().disposition(for: item, at: now) == .inbox
            case .waiting:
                InboxEligibilityRule().disposition(for: item, at: now) == .waiting
            case .snoozed:
                InboxEligibilityRule().disposition(for: item, at: now) == .snoozed
            case .myWork:
                item.relations.contains { $0.kind == .assigned || $0.kind == .authored }
            case .reviews:
                item.relations.contains {
                    $0.kind == .reviewRequestedDirectly || $0.kind == .reviewRequestedFromTeam
                }
            case .allWork:
                true
            }
        }
        return AttentionRanker().sort(matching, at: now)
    }

    private var emptyDescription: String {
        navigation.section == .inbox
            ? "Nothing currently needs your attention."
            : "No synchronized work matches this view."
    }
}

private struct WorkItemRow: View {
    let item: WorkItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(item.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if item.workflow.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
            }
            HStack(spacing: 6) {
                if let repository = item.repository {
                    Text(repository.fullName)
                }
                if let reason = item.attentionReasons.max(by: { $0.strength < $1.strength }) {
                    Text(reason.title)
                }
                if !item.openActionItems.isEmpty {
                    Text("\(item.openActionItems.count) action\(item.openActionItems.count == 1 ? "" : "s")")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var symbol: String {
        switch item.sourceKind {
        case .issue: "exclamationmark.circle"
        case .pullRequest: "arrow.triangle.pull"
        case .discussion: "bubble.left.and.bubble.right"
        default: "circle"
        }
    }

    private var accessibilityLabel: String {
        let repository = item.repository.map { " in \($0.fullName)" } ?? ""
        let reason = item.attentionReasons.max(by: { $0.strength < $1.strength }).map { ", \($0.title)" } ?? ""
        return "\(item.sourceKind.rawValue), \(item.title)\(repository)\(reason)"
    }
}
