import SwiftUI

/// "Not right?" on a recommendation: say what should happen instead, in
/// plain words. Each choice either acts on this item now or opens the rule
/// editor for work like it, with the action already chosen.
struct NotRightSheet: View {
    let entry: TriageEntry
    let actions: TriageAppModel
    @State private var draft: RuleDraft?
    @Environment(\.dismiss) private var dismiss

    private var isInInbox: Bool { entry.decision?.disposition.isInbox == true }

    var body: some View {
        if let draft {
            RuleEditorSheet(draft: draft, entries: actions.presentation.allEntries, topics: actions.rules.topics) { actions.addRule($0) }
                .environment(\.triageViewerLogin, actions.selectedAccount?.login ?? "")
        } else {
            chooser
        }
    }

    private func rule(_ action: TriageRuleAction) {
        draft = actions.makeRuleDraft(from: entry, action: action)
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What should Triage do instead?").font(.title3.weight(.semibold))
                Text("\(entry.item.reference): \(entry.item.title)")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            VStack(spacing: 8) {
                choice("Don't show me work like this",
                       detail: "Create a rule that hides matching work everywhere.",
                       systemImage: "eye.slash") { rule(.exclude) }
                choice("Hide just this until I'm mentioned",
                       detail: "Mute this item. It returns when someone mentions you, requests your review, or assigns you.",
                       systemImage: "speaker.slash") {
                    actions.mute([entry])
                    dismiss()
                }
                HStack(spacing: 8) {
                    moveMenu
                    rankMenu
                }
            }

            HStack {
                Text("Rules apply instantly and always win over Copilot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func choice(_ title: String, detail: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(detail)
    }

    private var moveMenu: some View {
        Menu {
            ForEach(TriageRuleAction.Route.allCases, id: \.self) { route in
                Button(route.title) { rule(.route(route)) }
                    .disabled(route.disposition == entry.decision?.disposition)
            }
        } label: {
            Label("Move work like this…", systemImage: "arrow.right.circle")
                .frame(maxWidth: .infinity)
        }
        .help("Create a rule that always moves matching work to a section")
    }

    private var rankMenu: some View {
        Menu {
            Section("Higher") {
                ForEach(TriageRuleAction.Strength.allCases, id: \.self) { strength in
                    Button("\(strength.title) (+\(strength.points))") { rule(.rank(.higher, strength)) }
                }
            }
            Section("Lower") {
                ForEach(TriageRuleAction.Strength.allCases, id: \.self) { strength in
                    Button("\(strength.title) (−\(strength.points))") { rule(.rank(.lower, strength)) }
                }
            }
        } label: {
            Label(isInInbox ? "Rank work like this lower…" : "Rank work like this…", systemImage: "arrow.up.arrow.down.circle")
                .frame(maxWidth: .infinity)
        }
        .help("Create a rule that ranks matching work higher or lower")
    }
}
