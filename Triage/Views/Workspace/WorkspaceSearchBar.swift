import AppKit
import SwiftUI

/// The list column's header: a full-width native search field with Sort and
/// Refresh, then filter chips and suggestions while searching.
struct WorkspaceSearchBar: View {
    @Binding var search: WorkspaceSearch
    let focusRequest: Int
    let suggestionSource: [TriageEntry]
    let actions: any WorkspaceActions
    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                NativeSearchField(text: $search.text, focusRequest: focusRequest, isFocused: $isFocused)
                    .frame(maxWidth: .infinity)
                WorkspaceSortToolbarMenu()
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .fixedSize()
                Button {
                    actions.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Search GitHub for new and changed work now (⌘R)")
                .accessibilityLabel("Refresh")
            }

            if search.isActive || isFocused {
                HStack(spacing: 6) {
                    Picker("Scope", selection: $search.scope) {
                        Text("This Section").tag(WorkspaceSearch.Scope.section)
                        Text("All Work").tag(WorkspaceSearch.Scope.all)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(search.tokens) { token in
                                chip(token, isApplied: true)
                            }
                            ForEach(search.suggestions(from: suggestionSource, limit: 6)) { token in
                                chip(token, isApplied: false)
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.snappy(duration: 0.2), value: search.isActive || isFocused)
    }

    private func chip(_ token: SearchToken, isApplied: Bool) -> some View {
        Button {
            if isApplied {
                search.tokens.removeAll { $0 == token }
            } else {
                search.text = search.textWithoutLastWord
                search.tokens.append(token)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isApplied ? "xmark.circle.fill" : token.systemImage)
                    .imageScale(.small)
                Text(token.title)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(isApplied ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quinary), in: Capsule())
            .foregroundStyle(isApplied ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(isApplied ? "Remove filter" : "Add filter")
    }
}

/// `NSSearchField`: native look, Esc to clear, recent searches, and focus
/// on Edit ▸ Find (⌘F).
private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search  ·  repo:  author:  is:review  status:conflicts"
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.recentsAutosaveName = "TriageWorkspaceSearch"
        field.controlSize = .large
        field.setAccessibilityLabel("Search work")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        var lastFocusRequest: Int

        init(_ parent: NativeSearchField) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.isFocused = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.isFocused = false }
    }
}
