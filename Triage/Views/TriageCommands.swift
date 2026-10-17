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

            InboxListLineMenu()
        }

        CommandGroup(before: .help) {
            Button("Setup Assistant…") {
                UserDefaults.triage.set(false, forKey: TriagePreferenceKeys.onboardingCompleted)
                appModel.openMainWindow?()
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
            let selected = appModel.selectedEntries
            Button("Mark Done") { appModel.markDone(selected) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(selected.isEmpty)

            Button("Snooze Until Tomorrow") { appModel.snooze(selected, until: SnoozeOption.tomorrow.date()) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(selected.isEmpty)

            let anyUnread = selected.contains(where: \.isUnread)
            Button(anyUnread || selected.isEmpty ? "Mark as Read" : "Mark as Unread") { appModel.setRead(selected, anyUnread) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(selected.isEmpty)

            Button("Mark All as Read") { appModel.setRead(appModel.visibleEntries, true) }
                .keyboardShortcut("u", modifiers: [.command, .option, .shift])
                .disabled(!appModel.visibleEntries.contains(where: \.isUnread))

            Divider()

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

            Button("Open on GitHub") { appModel.openOnGitHub(selected) }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(selected.isEmpty)
        }
    }
}

/// View menu choice for the line under each Inbox title.
struct InboxListLineMenu: View {
    @AppStorage(TriagePreferenceKeys.listLine) private var stored = InboxListLine.both.rawValue

    var body: some View {
        Menu("List Shows") {
            Picker("List Shows", selection: Binding(
                get: { InboxListLine(rawValue: stored) ?? .both },
                set: { stored = $0.rawValue }
            )) {
                ForEach(InboxListLine.allCases) { line in
                    Text(line.title).tag(line)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}
