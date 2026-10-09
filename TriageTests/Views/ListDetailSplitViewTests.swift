import AppKit
import SwiftUI
import XCTest
@testable import Triage

@MainActor
final class ListDetailSplitViewTests: XCTestCase {
    /// Regression: opening an item whose details are wide (a long title, a
    /// wide action bar) must not move the divider.
    func testDetailContentNeverResizesTheListColumn() throws {
        let host = NSHostingView(rootView: split(detailIdealWidth: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let splitView = try XCTUnwrap(Self.splitView(in: host))
        splitView.setPosition(470, ofDividerAt: 0)
        host.layoutSubtreeIfNeeded()
        let before = splitView.arrangedSubviews[0].frame.width

        host.rootView = split(detailIdealWidth: 2_000)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(splitView.arrangedSubviews[0].frame.width, before, accuracy: 0.5)

        host.rootView = split(detailIdealWidth: 120)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(splitView.arrangedSubviews[0].frame.width, before, accuracy: 0.5)
    }

    func testColumnsKeepTheirLimitsAndSavePosition() throws {
        let host = NSHostingView(rootView: split(detailIdealWidth: 300))
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 700)
        host.layoutSubtreeIfNeeded()
        let splitView = try XCTUnwrap(Self.splitView(in: host))
        XCTAssertEqual(splitView.autosaveName, ListDetailSplitView<EmptyView, EmptyView>.autosaveName)
        splitView.setPosition(5_000, ofDividerAt: 0)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(splitView.arrangedSubviews[0].frame.width, ListDetailSplitView<EmptyView, EmptyView>.listWidths.upperBound, accuracy: 0.5)
    }

    private func split(detailIdealWidth: CGFloat) -> ListDetailSplitView<Color, some View> {
        ListDetailSplitView {
            Color.clear
        } detail: {
            Text(String(repeating: "wide ", count: 40)).fixedSize().frame(idealWidth: detailIdealWidth)
        }
    }

    private static func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap(splitView(in:)).first
    }
}
