import SwiftUI

struct TriageWorkspaceCommands: Commands {
    @ObservedObject private var appModel: TriageAppModel

    init(appModel: TriageAppModel) {
        _appModel = ObservedObject(wrappedValue: appModel)
    }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Refresh Now") {
                appModel.refreshNow()
            }
            .keyboardShortcut("r", modifiers: .command)

            Menu("Sort By") {
                WorkspaceSortMenuContent()
            }
        }

        CommandMenu("Go To") {
            ForEach(Array(WorkspacePresentation.Section.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) {
                    appModel.selectedSection = section
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
            Button("Next Item") { appModel.moveSelection(by: 1) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Previous Item") { appModel.moveSelection(by: -1) }
                .keyboardShortcut("[", modifiers: .command)
        }

        CommandMenu("Item") {
            Button("Mark Done") {
                guard let entry = appModel.selectedEntry else { return }
                appModel.markDone(entry)
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(appModel.selectedEntry == nil)

            Button("Snooze Until Tomorrow") {
                guard let entry = appModel.selectedEntry else { return }
                appModel.snooze(entry, until: Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(appModel.selectedEntry == nil)

            Button("Open on GitHub") {
                guard let entry = appModel.selectedEntry else { return }
                appModel.openOnGitHub(entry)
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(appModel.selectedEntry == nil)
        }
    }
}
