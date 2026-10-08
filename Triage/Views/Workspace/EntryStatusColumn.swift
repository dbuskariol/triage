import SwiftUI

/// The trailing flag and time on every item row, in fixed slots so they
/// line up down the list: the flag's slot is reserved even when empty, and
/// the time is right-aligned in a fixed-width column.
struct EntryStatusColumn: View {
    let entry: TriageEntry
    /// On the selection highlight, use the highlight's foreground.
    var isSelected = false
    /// Fits the widest value ("11mo") and scales with the text size.
    @ScaledMetric(relativeTo: .caption) private var timeWidth: CGFloat = 30
    @ScaledMetric(relativeTo: .caption) private var flagWidth: CGFloat = 12

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "flag.fill")
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.orange))
                .frame(width: flagWidth)
                .opacity(needsAction ? 1 : 0)
                .help(needsAction ? "Needs your action" : "")
                .accessibilityHidden(!needsAction)
            Text(RelativeTime.compact(entry.item.updatedAt))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                .frame(width: timeWidth, alignment: .trailing)
                .help("Updated \(RelativeTime.exact(entry.item.updatedAt))")
        }
        .font(.caption.monospacedDigit())
    }

    private var needsAction: Bool { entry.decision?.disposition == .act }
}
