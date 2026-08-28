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
        @EnvironmentObject private var appModel: TriageAppModel
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
                    Button(item.workflow.status == .archived ? "Unarchive in Triage" : "Archive in Triage") {
                        Task {
                            await appModel.applyWorkflowAction(
                                item.workflow.status == .archived ? .unarchive : .archive,
                                to: item
                            )
                        }
                    }
                    Button(item.workflow.isPinned ? "Unpin" : "Pin") {
                        Task {
                            await appModel.applyWorkflowAction(.setPinned(!item.workflow.isPinned), to: item)
                        }
                    }
                    Menu("Priority") {
                        ForEach(WorkPriority.allCases, id: \.self) { priority in
                            Button(priorityTitle(priority)) {
                                Task {
                                    await appModel.applyWorkflowAction(.setPriority(priority), to: item)
                                }
                            }
                        }
                    }
                    Menu("Snooze") {
                        Button("1 Hour") {
                            Task {
                                await appModel.applyWorkflowAction(
                                    .snooze(until: Date().addingTimeInterval(3_600)),
                                    to: item
                                )
                            }
                        }
                        Button("Tomorrow") {
                            Task {
                                await appModel.applyWorkflowAction(
                                    .snooze(until: Date().addingTimeInterval(86_400)),
                                    to: item
                                )
                            }
                        }
                    }
                    Button(item.workflow.status == .waiting ? "Stop Waiting" : "Mark Waiting") {
                        Task {
                            await appModel.applyWorkflowAction(
                                item.workflow.status == .waiting ? .clearWaiting : .markWaiting(followUpAt: nil),
                                to: item
                            )
                        }
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
            priorityTitle(item.workflow.priority)
        }

        private func priorityTitle(_ priority: WorkPriority) -> String {
            switch priority {
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
