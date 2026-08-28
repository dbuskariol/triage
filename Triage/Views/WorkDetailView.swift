import SwiftUI

struct WorkDetailView: View {
    let item: WorkItem?
    @State private var showsInspector = false

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
        .toolbar {
            ToolbarItem {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show Inspector")
            }
        }
        .inspector(isPresented: $showsInspector) {
            if let item {
                WorkInspectorView(item: item)
            }
        }
    }

    private struct WorkInspectorView: View {
        let item: WorkItem

        var body: some View {
            Form {
                Section("Triage") {
                    LabeledContent("Status", value: item.workflow.status.rawValue.capitalized)
                    LabeledContent("Priority", value: priorityTitle)
                    if item.workflow.isPinned {
                        Label("Pinned", systemImage: "pin.fill")
                    }
                    if let snoozedUntil = item.workflow.snoozedUntil {
                        LabeledContent("Snoozed until", value: snoozedUntil.formatted())
                    }
                    if let followUpAt = item.workflow.followUpAt {
                        LabeledContent("Follow up", value: followUpAt.formatted())
                    }
                }
                if !item.attentionReasons.isEmpty {
                    Section("Evidence") {
                        ForEach(item.attentionReasons) { reason in
                            Text(reason.title)
                        }
                    }
                }
                Section {
                    Text("Triage status is stored locally and does not change GitHub.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Inspector")
        }

        private var priorityTitle: String {
            switch item.workflow.priority {
            case .low: "Low"
            case .normal: "Normal"
            case .high: "High"
            }
        }
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
