import Testing
@testable import Triage

struct ListSelectionTests {
    private let order = ["a", "b", "c", "d", "e"]

    @Test func movingCollapsesToOneRowFromTheSelectionsEdge() {
        #expect(ListSelection.moved(["b", "d"], in: order, by: 1) == "e")
        #expect(ListSelection.moved(["b", "d"], in: order, by: -1) == "a")
        #expect(ListSelection.moved(["e"], in: order, by: 1) == "e")
        #expect(ListSelection.moved([], in: order, by: 1) == "a")
        #expect(ListSelection.moved([], in: order, by: -1) == "e")
        #expect(ListSelection.moved(["a"], in: [String](), by: 1) == nil)
    }

    @Test func removingSelectsTheNextRemainingRow() {
        #expect(ListSelection.afterRemoving(["b", "c"], from: ["b", "c"], in: order) == ["d"])
        #expect(ListSelection.afterRemoving(["d", "e"], from: ["e"], in: order) == ["c"])
        #expect(ListSelection.afterRemoving(["a"], from: ["c"], in: order) == ["c"])
        #expect(ListSelection.afterRemoving(Set(order), from: ["a"], in: order).isEmpty)
    }
}
