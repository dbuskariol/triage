import AppKit
import SwiftUI

/// The list and detail columns as a native split view. The divider stays where
/// the user puts it:
/// - Pane content never sizes the columns (hosting `sizingOptions` is empty);
///   only the fixed minimums and maximums below apply.
/// - The divider position is saved with `autosaveName`, so it survives
///   switching sections, opening the Briefing, and relaunching.
/// - Resizing the window grows or shrinks the detail column, like Mail.
struct ListDetailSplitView<List: View, Detail: View>: NSViewControllerRepresentable {
    static var autosaveName: String { "Triage.ListDetail" }
    static var listWidths: ClosedRange<CGFloat> { 320...560 }
    static var defaultListWidth: CGFloat { 400 }
    static var detailMinimumWidth: CGFloat { 460 }

    private let list: List
    private let detail: Detail

    init(@ViewBuilder list: () -> List, @ViewBuilder detail: () -> Detail) {
        self.list = list()
        self.detail = detail()
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        controller.splitView.isVertical = true
        controller.splitView.dividerStyle = .thin
        // Must be set before items are added for the saved position to restore.
        controller.splitView.autosaveName = Self.autosaveName

        let listHost = Self.host(list, environment: context.environment)
        listHost.view.frame.size.width = Self.defaultListWidth
        let listItem = NSSplitViewItem(viewController: listHost)
        listItem.minimumThickness = Self.listWidths.lowerBound
        listItem.maximumThickness = Self.listWidths.upperBound
        listItem.holdingPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 1)
        listItem.canCollapse = false

        let detailItem = NSSplitViewItem(viewController: Self.host(detail, environment: context.environment))
        detailItem.minimumThickness = Self.detailMinimumWidth
        detailItem.holdingPriority = .defaultLow
        detailItem.canCollapse = false

        controller.addSplitViewItem(listItem)
        controller.addSplitViewItem(detailItem)
        return controller
    }

    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
        let items = controller.splitViewItems
        (items[0].viewController as? NSHostingController<AnyView>)?.rootView = AnyView(list.environment(\.self, context.environment))
        (items[1].viewController as? NSHostingController<AnyView>)?.rootView = AnyView(detail.environment(\.self, context.environment))
    }

    private static func host(_ content: some View, environment: EnvironmentValues) -> NSHostingController<AnyView> {
        let host = NSHostingController(rootView: AnyView(content.environment(\.self, environment)))
        // The root cause of columns jumping: by default a hosting controller
        // reports its content's ideal and minimum size to Auto Layout, so a
        // long title or wide action bar resized the split.
        host.sizingOptions = []
        return host
    }
}
