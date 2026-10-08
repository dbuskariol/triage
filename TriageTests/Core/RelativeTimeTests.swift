import Foundation
import Testing
@testable import Triage

struct RelativeTimeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func compactUsesOneUnit() {
        func ago(_ seconds: TimeInterval) -> String { RelativeTime.compact(now.addingTimeInterval(-seconds), now: now) }
        #expect(ago(20) == "now")
        #expect(ago(25 * 60) == "25m")
        #expect(ago(2 * 3_600) == "2h")
        #expect(ago(5 * 86_400) == "5d")
        #expect(ago(29 * 86_400) == "29d")
        #expect(ago(65 * 86_400) == "2mo")
        #expect(ago(800 * 86_400) == "2y")
        #expect(RelativeTime.compact(now.addingTimeInterval(7_200), now: now) == "in 2h")
    }
}
