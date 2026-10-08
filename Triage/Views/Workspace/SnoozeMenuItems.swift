import SwiftUI

/// The snooze choices, shared by every snooze menu.
struct SnoozeMenuItems: View {
    let entries: [TriageEntry]
    let actions: any WorkspaceActions

    var body: some View {
        ForEach(SnoozeOption.allCases) { option in
            Button {
                actions.snooze(entries, until: option.date())
            } label: {
                Text(option.title)
                Text(option.subtitle())
            }
        }
    }
}
