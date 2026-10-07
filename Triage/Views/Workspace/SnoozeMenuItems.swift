import SwiftUI

/// Snooze choices for menus, showing exactly when each one ends.
struct SnoozeMenuItems: View {
    let entry: TriageEntry
    let actions: any WorkspaceActions

    var body: some View {
        ForEach(SnoozeOption.allCases) { option in
            Button {
                actions.snooze(entry, until: option.date())
            } label: {
                Text(option.title)
                Text(option.subtitle())
            }
        }
    }
}
