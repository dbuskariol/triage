import SwiftUI

/// Settings ▸ General ▸ Appearance. AppKit reads the scroll bar style at
/// launch, so a change applies the next time Triage opens.
struct ScrollBarSettingSection: View {
    @State private var choice = ScrollBarVisibility.saved()
    /// The style this launch is using.
    @State private var launched = ScrollBarVisibility.saved()

    var body: some View {
        Section {
            Picker("Show scroll bars", selection: $choice) {
                ForEach(ScrollBarVisibility.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: choice) { _, choice in choice.save() }
        } header: {
            Text("Appearance")
        } footer: {
            if choice != launched {
                Text("Takes effect the next time you open Triage.")
            } else {
                Text("Use System Setting follows System Settings ▸ Appearance, which shows scroll bars all the time when a mouse is connected. Choose When Scrolling to show them only while you scroll.")
            }
        }
    }
}
