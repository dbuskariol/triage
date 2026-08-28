import SwiftUI

struct WorkDetailView: View {
    let item: WorkItem?

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Label(item.sourceKind.rawValue, systemImage: sourceSymbol)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(item.title)
                            .font(.largeTitle.weight(.bold))
                        if let repository = item.repository {
                            Text(repository.fullName)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        if !item.attentionReasons.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Why this is here")
                                    .font(.headline)
                                ForEach(item.attentionReasons) { reason in
                                    Label(reason.explanation, systemImage: "exclamationmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !item.openActionItems.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Action Items")
                                    .font(.headline)
                                ForEach(item.openActionItems) { action in
                                    Label(action.title, systemImage: "circle")
                                }
                            }
                        }
                        if let sourceURL = item.sourceURL {
                            Link("Open on GitHub", destination: sourceURL)
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "Select work",
                    systemImage: "rectangle.stack",
                    description: Text("Choose an item to review its context and local workflow.")
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sourceSymbol: String {
        switch item?.sourceKind {
        case .issue: "exclamationmark.circle"
        case .pullRequest: "arrow.triangle.pull"
        case .discussion: "bubble.left.and.bubble.right"
        default: "circle"
        }
    }
}
