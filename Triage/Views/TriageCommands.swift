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

        CommandGroup(after: .textEditing) {
            Button("Find…") { appModel.searchFocusRequest += 1 }
                .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("Go To") {
            Button("Briefing") { appModel.destination = .briefing }
                .keyboardShortcut("0", modifiers: .command)
            ForEach(Array(WorkspacePresentation.Section.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) {
                    appModel.destination = .section(section)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Button("Weekly Review") { appModel.destination = .review }
                .keyboardShortcut("9", modifiers: .command)
            Divider()
            Button(appModel.focusQueue == nil ? "Focus on This List" : "Exit Focus") {
                if appModel.focusQueue == nil { appModel.startFocus(appModel.visibleEntries) } else { appModel.focusQueue = nil }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(appModel.focusQueue == nil && appModel.visibleEntries.isEmpty)
            Divider()
            Button("Back") { appModel.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(appModel.backHistory.isEmpty)
            Button("Forward") { appModel.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(appModel.forwardHistory.isEmpty)
            Divider()
            Button("Next Item") { appModel.moveSelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Item") { appModel.moveSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
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
                appModel.snooze(entry, until: SnoozeOption.tomorrow.date())
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(appModel.selectedEntry == nil)

            Button("Draft Reply…") {
                guard let entry = appModel.selectedEntry else { return }
                appModel.beginDraft(for: entry)
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(appModel.selectedEntry == nil)

            Button("Create Rule…") {
                guard let entry = appModel.selectedEntry else { return }
                appModel.beginRule(from: entry, correcting: false)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
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
