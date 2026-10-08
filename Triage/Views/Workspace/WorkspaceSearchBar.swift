import AppKit
import SwiftUI

/// The list column's header: a full-width native search field with Filter,
/// Sort, and Refresh. Scope and applied filters appear only while searching.
struct WorkspaceSearchBar: View {
    @Binding var search: WorkspaceSearch
    let focusRequest: Int
    let suggestionSource: [TriageEntry]
    let actions: any WorkspaceActions
    /// Called when the user leaves the field with Esc or Return.
    var onExit: () -> Void = {}
    /// Starts Focus on the list below.
    var focusOn: () -> Void = {}
    /// Saves the search to the sidebar; `nil` hides Save.
    var onSave: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                NativeSearchField(text: $search.text, focusRequest: focusRequest, onExit: onExit)
                    .frame(maxWidth: .infinity)
                filterMenu
                Button {
                    focusOn()
                } label: {
                    Image(systemName: "scope")
                }
                .buttonStyle(.borderless)
                .help("Work through this list one item at a time (⇧⌘F)")
                .accessibilityLabel("Focus")
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

            if search.isActive {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Picker("Scope", selection: $search.scope) {
                        Text("This Section").tag(WorkspaceSearch.Scope.section)
                        Text("All Work").tag(WorkspaceSearch.Scope.all)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    Spacer(minLength: 0)
                    if let onSave {
                        Button("Save", action: onSave)
                            .buttonStyle(.link)
                            .help("Save this search to the sidebar")
                    }
                    Button("Clear") { search = WorkspaceSearch(scope: search.scope) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
                if !search.tokens.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(search.tokens) { token in
                            appliedChip(token)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.snappy(duration: 0.2), value: search.isActive)
    }

    /// Every filter, grouped like GitHub's, plus values from current work.
    private var filterMenu: some View {
        Menu {
            ForEach([SearchToken.Kind.is, .status, .priority, .effort], id: \.self) { kind in
                Section(Self.sectionTitle(kind)) {
                    ForEach(SearchToken.knownValues[kind] ?? [], id: \.0) { value, title in
                        toggle(SearchToken(kind: kind, value: value), title: title)
                    }
                }
            }
            Divider()
            ForEach([SearchToken.Kind.repo, .author, .label, .team], id: \.self) { kind in
                let values = topValues(kind)
                if !values.isEmpty {
                    Menu(Self.sectionTitle(kind)) {
                        ForEach(values, id: \.self) { value in
                            toggle(SearchToken(kind: kind, value: value), title: value)
                        }
                    }
                }
            }
            if !search.tokens.isEmpty {
                Divider()
                Button("Remove All Filters") { search.tokens.removeAll() }
            }
        } label: {
            Image(systemName: search.tokens.isEmpty
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter")
        .accessibilityLabel("Filter")
    }

    private func toggle(_ token: SearchToken, title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { search.tokens.contains(token) },
            set: { isOn in
                if isOn { search.tokens.append(token) } else { search.tokens.removeAll { $0 == token } }
            }
        ))
    }

    private func topValues(_ kind: SearchToken.Kind) -> [String] {
        var counts: [String: Int] = [:]
        for entry in suggestionSource {
            let item = entry.item
            let values: [String] = switch kind {
            case .repo: [item.repository.split(separator: "/").last.map(String.init) ?? item.repository]
            case .author: item.author.map { [$0] } ?? []
            case .label: item.labels
            case .team: (item.pullRequest?.requestedReviewers ?? []).filter { $0.contains("/") }
            default: []
            }
            for value in values { counts[value, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(15).map(\.key)
    }

    private static func sectionTitle(_ kind: SearchToken.Kind) -> String {
        switch kind {
        case .is: "Type and relationship"
        case .status: "Pull request status"
        case .priority: "Priority"
        case .effort: "Effort"
        case .repo: "Repository"
        case .author: "Author"
        case .label: "Label"
        case .team: "Requested team"
        }
    }

    private func appliedChip(_ token: SearchToken) -> some View {
        Button {
            search.tokens.removeAll { $0 == token }
        } label: {
            HStack(spacing: 4) {
                Text(token.title)
                Image(systemName: "xmark").imageScale(.small)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help("Remove filter")
        .accessibilityLabel("Remove filter \(token.title)")
    }
}

/// `NSSearchField`: native look, Esc to clear, recent searches, and focus
/// on Edit ▸ Find (⌘F).
private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let onExit: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search, or try is:review status:conflicts"
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.recentsAutosaveName = "TriageWorkspaceSearch"
        field.controlSize = .large
        field.setAccessibilityLabel("Search work")
        context.coordinator.watchClicksOutside(field)
        return field
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.stopWatching()
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
        private var clickMonitor: Any?

        /// Any click elsewhere in the window ends editing (like Mail and
        /// Finder). The click itself still reaches whatever was clicked.
        func watchClicksOutside(_ field: NSSearchField) {
            clickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak field] event in
                guard let field, let window = field.window, event.window === window,
                      field.currentEditor() != nil
                else { return event }
                let point = field.convert(event.locationInWindow, from: nil)
                if !field.bounds.contains(point) {
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        func stopWatching() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }

        deinit { stopWatching() }

        init(_ parent: NativeSearchField) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        /// Esc clears the field; Esc on an empty field (or Return) leaves it,
        /// returning keyboard focus to the window so list keys work again.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? NSSearchField else { return false }
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                if field.stringValue.isEmpty {
                    field.window?.makeFirstResponder(nil)
                    parent.onExit()
                } else {
                    field.stringValue = ""
                    parent.text = ""
                }
                return true
            case #selector(NSResponder.insertNewline(_:)):
                field.window?.makeFirstResponder(nil)
                parent.onExit()
                return true
            default:
                return false
            }
        }
    }
}
